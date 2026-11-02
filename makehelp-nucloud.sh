#!/usr/bin/env bash
# nucloud image repo helper. Stamped from IzumaNetworks/nucloud
# templates/makehelp.sh; identical in every repo. Reads nucloud.env:
#
#   REPO=<org>/<repo>
#   IMAGES=(                      # one entry per image this repo builds
#     "name|upstream_tag|dockerfile|context|target|release"
#   )   # target: Dockerfile stage or "-"; release: helm release on k3s, "-" for none,
#         # or "release=values.key" when the chart's tag key is not image.tag
#   SECRETS=(fa_token=FA_PRO_TOKEN)   # BuildKit secrets: id=ENVVAR
#   SSH=1                         # forward the ssh agent to the build
#   PLATFORM=linux/amd64
#   SMOKE_CMD=(...)               # command run by `make smoke`, default: none (image must start)
#   SMOKE_<name>=(...)            # per-image override; <name> with every non-alphanumeric as _ (SMOKE_iam_policies)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f nucloud.env ]] || { echo "error: nucloud.env missing" >&2; exit 1; }
REGISTRY=ghcr.io/izumanetworks
SECRETS=() SSH=0 PLATFORM=linux/amd64 SMOKE_CMD=()
# shellcheck disable=SC1091
source nucloud.env
ENV="${MACHINE:-${ENV:-k3s-cypress}}" ONLY="${ONLY:-}"
GIT_HEAD="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
# CI tags <upstream>-nucloud.<run number>. A local build tags
# <upstream>-nucloud.dev.<commit>, plus a hash of any uncommitted changes, so
# every changed tree deploys under a new tag and its pods restart.
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    SUFFIX="nucloud.$BUILD_NUMBER"
else
    BUILD_NUMBER=0 SUFFIX="nucloud.dev.${GIT_HEAD:0:7}"
    if [[ -n "$(git status --porcelain -- . ':!sbom-*' 2>/dev/null)" ]]; then
        SUFFIX+=".$({ git diff HEAD; git ls-files -o --exclude-standard -z -- . ':!sbom-*' | xargs -0 cat; } | git hash-object --stdin | cut -c1-7)"
    fi
fi

die() { echo "error: $*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

if [[ -n "${IMAGE_SUFFIX:-}" ]]; then
    [[ "$IMAGE_SUFFIX" =~ ^nucloud\.(dev\.[a-f0-9]{7,40}(\.[a-f0-9]{7})?|[0-9]+)$ ]] || die "invalid IMAGE_SUFFIX=$IMAGE_SUFFIX"
    case "${1:-}" in
        images|image-load|deploy-only|deploy|sbom|smoke) SUFFIX=$IMAGE_SUFFIX ;;
        *) die "IMAGE_SUFFIX selects existing images; omit it for builds and pushes" ;;
    esac
fi

each() { # each <fn>: call fn name tag dockerfile context target release ref
    local e name tag df ctx tgt rel
    for e in "${IMAGES[@]}"; do
        IFS='|' read -r name tag df ctx tgt rel <<<"$e"
        [[ -z "$ONLY" || "$ONLY" == "$name" ]] || continue
        "$1" "$name" "$tag" "$df" "$ctx" "$tgt" "$rel" "$REGISTRY/$name:$tag-$SUFFIX"
    done
}

guard_tag() { [[ "$1" == *-nucloud.* ]] || die "refusing $1: not a -nucloud.<n> tag"; }

i_list() { printf '%-50s %s\n' "$1" "$7"; }

i_build() {
    local name=$1 df=$3 ctx=$4 tgt=$5 ref=$7 args=() s
    guard_tag "$ref"
    for s in "${SECRETS[@]}"; do
        args+=(--secret "id=${s%%=*},env=${s#*=}")
    done
    [[ "$SSH" == 1 ]] && args+=(--ssh default)
    [[ "$tgt" != "-" && -n "$tgt" ]] && args+=(--target "$tgt")
    say "build $ref on $(docker context show) ($PLATFORM)"
    DOCKER_BUILDKIT=1 docker buildx build --load --platform "$PLATFORM" "${args[@]}" \
        --build-arg GIT_HEAD="$GIT_HEAD" --build-arg BUILD_NUMBER="$BUILD_NUMBER" \
        --label org.opencontainers.image.revision="$GIT_HEAD" \
        --label org.opencontainers.image.source="https://github.com/$REPO" \
        --label org.opencontainers.image.version="$2-$SUFFIX" \
        -f "$df" -t "$ref" "$ctx"
}

i_sbom() { syft "$7" -o spdx-json > "sbom-${1//\//_}.spdx.json"; say "sbom-${1//\//_}.spdx.json"; }

i_smoke() {
    local ref=$7 cid var="SMOKE_${1//[^A-Za-z0-9]/_}"
    local -a cmd=("${SMOKE_CMD[@]}")
    if declare -p "$var" >/dev/null 2>&1; then local -n per=$var; cmd=("${per[@]}"); fi
    if [[ ${#cmd[@]} -gt 0 ]]; then
        docker run --rm --platform "$PLATFORM" --entrypoint "${cmd[0]}" "$ref" "${cmd[@]:1}"
    else
        cid=$(docker run -d --platform "$PLATFORM" "$ref")
        sleep 8
        if [[ "$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' "$cid")" =~ ^(true|false\ 0) ]]; then
            say "$ref started"; docker rm -f "$cid" >/dev/null
        else
            docker logs --tail 20 "$cid" >&2; docker rm -f "$cid" >/dev/null; die "$ref exited"
        fi
    fi
}

stage_vm() { # the stage's incus remote and VM, "remote:guest": ./.iz and .izlocal through izmachine
    local hit
    command -v izmachine >/dev/null || die "izmachine is not on PATH; stage $ENV is resolved from .iz through it"
    [[ -f .iz ]] || die "no .iz in $PWD; stages are defined in .iz (make rollout in nucloud installs it)"
    hit=$(izmachine info "$ENV" --format json -f .iz 2>/dev/null | python3 -c '
import json, sys
want, raw = sys.argv[1], sys.stdin.read()
for g in (json.loads(raw).get("guests", []) if raw.strip() else []):
    if g.get("definition") == want and g.get("remote"):
        print(g["remote"] + ":" + g.get("guest", want)); break' "$ENV") || hit=
    [[ -n $hit ]] || die "stage $ENV is not defined in .iz or .izlocal"
    echo "$hit"
}

WORK=
work_dir() { [[ -n $WORK ]] || { WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; }; }

STAGE_KC=
stage_kubeconfig() { # fetch the stage's admin kubeconfig from its VM into $STAGE_KC (mode 600, removed on exit)
    local hit remote guest ip out
    [[ -z $STAGE_KC ]] || return 0
    hit=$(stage_vm); remote=${hit%%:*}; guest=${hit#*:}
    work_dir
    # the VM's own guest.ip is a CNI address on k3s; the default route's source is the LAN address
    ip=$(izmachine direct run "$guest" --provider incus --remote "$remote" --format json -- ip -4 route get 1.1.1.1 | python3 -c '
import json, re, sys
m = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)", json.load(sys.stdin).get("stdout", ""))
print(m.group(1) if m else "")') || ip=
    [[ -n $ip ]] || die "cannot read $guest's address on $remote; is the VM running? (izmachine list)"
    out="$WORK/$ENV.kubeconfig"
    izmachine direct run "$guest" --provider incus --remote "$remote" --format json -- cat /etc/rancher/k3s/k3s.yaml | python3 -c '
import json, re, sys
ip, stage = sys.argv[1:3]
d = json.load(sys.stdin)
if d.get("exit_code") != 0 or not d.get("stdout", "").startswith("apiVersion"):
    sys.exit("k3s.yaml not readable: " + d.get("stderr", "")[:200])
t = d["stdout"].replace("https://127.0.0.1:", "https://" + ip + ":")
t = re.sub(r"(?m)^(\s*(?:- )?(?:name|cluster|user)|current-context): default$", lambda m: m.group(1) + ": " + stage, t)
sys.stdout.write(t)' "$ip" "$ENV" > "$out" || die "cannot fetch $ENV's kubeconfig from $guest on $remote"
    chmod 600 "$out"
    STAGE_KC=$out
}

release_chart() { # release_chart <kubeconfig> <release> <namespace> <dir>: write the installed chart from its newest release record
    local rec="$WORK/$2.release.json" rc=0
    kubectl --kubeconfig "$1" get secret -n "$3" -l "owner=helm,name=$2" -o json > "$rec" || die "cannot read release $2 on $ENV"
    python3 -I - "$rec" "$4" <<'PYCHART' || rc=$?
import base64, gzip, json, os, sys
rec, dest = sys.argv[1:3]
items = json.load(open(rec))["items"]
if not items:
    sys.exit("no release record")
best = max(items, key=lambda i: int(i["metadata"]["labels"]["version"]))
raw = base64.b64decode(base64.b64decode(best["data"]["release"]))
if raw[:2] == b"\x1f\x8b":
    raw = gzip.decompress(raw)
rel = json.loads(raw)
chart = rel["chart"]
if ("# Source: %s/charts/" % chart["metadata"]["name"]) in rel.get("manifest", "") and not chart.get("dependencies"):
    sys.exit(3)  # the release rendered vendored subcharts, which Helm does not keep in its record

def put(root, rel, data):
    path = os.path.normpath(os.path.join(root, rel))
    if os.path.isabs(rel) or not path.startswith(os.path.normpath(root) + os.sep):
        sys.exit("unsafe path in release: " + rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(data)

def write(c, root):
    os.makedirs(root, exist_ok=True)
    meta = dict(c["metadata"])
    present = {d["metadata"]["name"] for d in c.get("dependencies") or []}
    if meta.get("dependencies"):  # a disabled subchart is absent from the record but still listed in Chart.yaml
        meta["dependencies"] = [r for r in meta["dependencies"] if (r.get("alias") or r["name"]) in present]
    put(root, "Chart.yaml", json.dumps(meta).encode())
    put(root, "values.yaml", json.dumps(c.get("values") or {}).encode())
    for f in (c.get("templates") or []) + (c.get("files") or []):
        put(root, f["name"], base64.b64decode(f.get("data") or ""))
    if c.get("schema"):
        put(root, "values.schema.json", base64.b64decode(c["schema"]))
    for d in c.get("dependencies") or []:
        write(d, os.path.join(root, "charts", d["metadata"]["name"]))

write(chart, dest)
PYCHART
    case $rc in 0) ;; 3) return 3 ;; *) die "cannot recover the chart of release $2" ;; esac
}
platform_chart() { # platform_chart <release> <chart name>: the chart directory in an izuma-dm-platform checkout
    local root="${NUCLOUD_PLATFORM:-$HOME/workspace/izuma/izuma-dm-platform}" dir
    dir=$(find "$root/charts" -name Chart.yaml -exec grep -l "^name: $2$" {} + 2>/dev/null | head -1 | xargs dirname 2>/dev/null) || dir=
    [[ -d "$dir" ]] || die "release $1 renders vendored subcharts that its cluster record does not keep; set NUCLOUD_PLATFORM to an izuma-dm-platform checkout holding chart $2"
    echo "$dir"
}

LOAD_REFS=()
i_load_ref() { LOAD_REFS+=("$7"); }
save_images() {
    local endpoint target port socket command wrapped
    endpoint=$(docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}')
    if [[ -z "${DOCKER_HOST:-}" && "$endpoint" == ssh://* ]]; then
        read -r target port socket < <(python3 - "$endpoint" <<'PYURL'
import sys
from urllib.parse import unquote, urlparse
u = urlparse(sys.argv[1])
target = (unquote(u.username) + '@' if u.username else '') + u.hostname
print(target, u.port or 22, unquote(u.path))
PYURL
        )
        local -a args=(docker)
        [[ -z "$socket" || "$socket" == / ]] || args+=(--host "unix://$socket")
        args+=(image save "${LOAD_REFS[@]}")
        printf -v command '%q ' "${args[@]}"
        printf -v wrapped 'bash -o pipefail -c %q' "$command | gzip -1"
        # Compress beside the engine before the SSH transfer to this checkout.
        ssh -o BatchMode=yes -p "$port" "$target" "$wrapped"
    else
        docker save "${LOAD_REFS[@]}" | gzip -1
    fi
}
load_images() {
    local vm
    LOAD_REFS=()
    each i_load_ref
    [[ ${#LOAD_REFS[@]} -gt 0 ]] || die "no images selected for import"
    local ref actual
    for ref in "${LOAD_REFS[@]}"; do
        actual=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref") || \
            die "missing existing image $ref; build first or set IMAGE_SUFFIX= to a completed build"
        [[ "$actual" == "$PLATFORM" ]] || die "$ref has platform $actual; expected $PLATFORM"
    done
    vm=$(stage_vm)
    say "import ${#LOAD_REFS[@]} image(s) into $vm"
    local try
    for try in 1 2; do
        if save_images | incus exec "$vm" -- k3s ctr images import -; then break; fi
        [[ $try == 1 ]] || die "image import into $vm failed twice"
        say "import into $vm failed; retrying once"
    done
}

DEPLOY_SETS=()  # "release|key=tag" collected per image, applied once per release
i_deploy() {
    # release field: "rel", "rel=values.key", or several joined by commas when
    # one image is set in more than one release ("mdscore=a.tag,mdsnotification=b.tag")
    local name=$1 ref=$7 m rel key
    [[ "$6" == "-" || -z "$6" ]] && { say "$name: no k3s release, skipped"; return; }
    for m in ${6//,/ }; do
        rel=${m%%=*} key=image.tag
        [[ "$m" == *=* ]] && key=${m#*=}
        DEPLOY_SETS+=("$rel|$key=${ref##*:}")
    done
}
deploy_wait() {
    local kc=$1 rel=$2 ns=${3:-default} workload_ns kind name recreate resources
    resources=$(kubectl --kubeconfig "$kc" get deploy,sts,ds --all-namespaces -o json | python3 -c '
import json,sys
rel,release_ns=sys.argv[1:3]
for obj in json.load(sys.stdin)["items"]:
    annotations=obj["metadata"].get("annotations",{})
    if annotations.get("meta.helm.sh/release-name") != rel or annotations.get("meta.helm.sh/release-namespace") != release_ns:
        continue
    spec=obj["spec"]; pod=spec["template"]["spec"]
    ports=pod.get("hostNetwork",False) or any(p.get("hostPort",0) for c in pod.get("containers",[]) for p in c.get("ports",[]))
    recreate=obj["kind"]=="Deployment" and spec.get("replicas",1)==1 and ports
    print(obj["metadata"]["namespace"],obj["kind"].lower(),obj["metadata"]["name"],"yes" if recreate else "no")
' "$rel" "$ns")
    while read -r workload_ns kind name recreate; do
        [[ -n "$kind" ]] || continue
        if [[ "$recreate" == yes ]]; then
            say "$rel: recreate single-replica host-port deployment $name"
            kubectl --kubeconfig "$kc" patch deployment "$name" -n "$workload_ns" --type merge \
                -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
        fi
        kubectl --kubeconfig "$kc" rollout status "$kind/$name" -n "$workload_ns" --timeout=10m
    done <<< "$resources"
}
deploy_apply() {
    # helm upgrade with the release's current user-supplied values re-sent as
    # a file: changes only this repo's image tags and keeps every other value,
    # including tags another repo's images set in a shared release (helmfile
    # apply would reset those to chart defaults). Not --reuse-values: helm 4
    # copies the previous values into the chart record too, and a stage's
    # values (600 KB of certificates) then overflow the 1 MiB release secret.
    local kc rel e args chart prev ns releases
    [[ ${#DEPLOY_SETS[@]} -gt 0 ]] || return 0
    stage_kubeconfig; kc=$STAGE_KC
    prev="$WORK/values.yaml"
    releases=$(KUBECONFIG="$kc" helm list --all-namespaces -o json)
    for rel in $(printf '%s\n' "${DEPLOY_SETS[@]}" | cut -d'|' -f1 | sort -u); do
        args=()
        for e in "${DEPLOY_SETS[@]}"; do [[ "${e%%|*}" == "$rel" ]] && args+=(--set "${e#*|}"); done
        ns=$(printf '%s' "$releases" | python3 -c '
import json,sys
matches=[r["namespace"] for r in json.load(sys.stdin) if r["name"]==sys.argv[1]]
if len(matches)!=1:
    sys.exit("release must have one installed namespace: "+sys.argv[1])
print(matches[0])' "$rel")
        chart="$WORK/chart-$rel"
        if ! release_chart "$kc" "$rel" "$ns" "$chart"; then
            chart=$(KUBECONFIG="$kc" helm get metadata "$rel" -n "$ns" -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["chart"])')
            chart=$(platform_chart "$rel" "$chart")
        fi
        KUBECONFIG="$kc" helm get values "$rel" -n "$ns" -o yaml > "$prev"
        say "helm upgrade $rel on $ENV ${args[*]}"
        KUBECONFIG="$kc" helm upgrade "$rel" "$chart" -n "$ns" -f "$prev" "${args[@]}" --timeout 10m
        deploy_wait "$kc" "$rel" "$ns"
    done
}

REL_LIST=()
i_rel() { # collect the helm releases this repo's images deploy to
    local m
    [[ "$6" == "-" || -z "$6" ]] && return
    for m in ${6//,/ }; do REL_LIST+=("${m%%=*}"); done
}
show_running() { # one line per release this repo deploys, then its workloads and the image each runs
    local kc rel
    each i_rel
    [[ ${#REL_LIST[@]} -gt 0 ]] || { say "no k3s release in this repo"; return 0; }
    stage_kubeconfig; kc=$STAGE_KC
    for rel in $(printf '%s\n' "${REL_LIST[@]}" | sort -u); do
        python3 -c '
import json, subprocess, sys
kc, rel = sys.argv[1:3]
def run(*a): return json.loads(subprocess.check_output(a, text=True))
hit = [r for r in run("helm", "--kubeconfig", kc, "list", "--all-namespaces", "-o", "json") if r["name"] == rel]
if not hit:
    print(rel + " not installed"); sys.exit(0)
r = hit[0]
print("%s %s rev %s %s" % (rel, r["namespace"], r["revision"], r["status"]))
for o in run("kubectl", "--kubeconfig", kc, "get", "deploy,sts,ds", "-A", "-o", "json")["items"]:
    a = o["metadata"].get("annotations", {})
    if a.get("meta.helm.sh/release-name") == rel and a.get("meta.helm.sh/release-namespace") == r["namespace"]:
        imgs = " ".join(c["image"] for c in o["spec"]["template"]["spec"]["containers"])
        st = o.get("status", {})
        print("  %s/%s %s/%s ready  %s" % (o["kind"].lower(), o["metadata"]["name"], st.get("readyReplicas", 0), o["spec"].get("replicas", st.get("desiredNumberScheduled", 1)), imgs))' "$kc" "$rel"
    done
}

i_push() {
    guard_tag "$7"
    [[ "$7" != *-nucloud.dev.* ]] || die "refusing $7: a local build; only CI pushes to GHCR"
    docker push "$7"
}

case "${1:-}" in
    images) each i_list ;;
    prereqs)
        for t in docker syft; do command -v "$t" >/dev/null || die "$t not installed"; done
        docker buildx version >/dev/null || die "docker buildx missing"
        for s in "${SECRETS[@]}"; do v="${s#*=}"; [[ -n "${!v:-}" ]] || die "secret ${s%%=*} needs \$$v set"; done
        say "context $(docker context show), ${#IMAGES[@]} image(s)" ;;
    image) each i_build ;;
    sbom) each i_sbom ;;
    test)
        IFS='|' read -r _ _ df _ <<<"${IMAGES[0]}"
        if grep -qiE '^FROM .* AS test( |$)' "$df"; then
            DOCKER_BUILDKIT=1 docker buildx build --platform "$PLATFORM" --target test \
                $([[ "$SSH" == 1 ]] && echo --ssh default) -f "$df" .
        else
            say "no test stage in $df"
        fi ;;
    smoke) each i_smoke ;;
    image-load) load_images ;;
    stage-check) stage_kubeconfig; say "$ENV answers at $(stage_vm)" ;;
    kubeconfig) stage_kubeconfig; cat "$STAGE_KC" ;;
    running) show_running ;;
    deploy-only) stage_kubeconfig; load_images; each i_deploy; deploy_apply ;;
    deploy) stage_kubeconfig; each i_deploy; deploy_apply ;;
    push) each i_push ;;
    run) shift; IFS='|' read -r n t _ <<<"${IMAGES[0]}"; docker run --rm -it "$REGISTRY/$n:$t-$SUFFIX" "$@" ;;
    *) echo "Usage: $0 {images|prereqs|image|sbom|test|smoke|image-load|stage-check|kubeconfig|running|deploy-only|deploy|push|run}" >&2; exit 1 ;;
esac
