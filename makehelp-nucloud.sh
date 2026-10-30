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
NUCLOUD_PLATFORM="${NUCLOUD_PLATFORM:-$HOME/workspace/izuma/izuma-dm-platform}"
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

stage_vm() { # the stage's incus remote and VM, from the platform repo's stage registry
    local reg="$NUCLOUD_PLATFORM/scripts/k3s-stage.sh" remote vm
    [[ -x $reg ]] || die "no stage registry at $reg (set NUCLOUD_PLATFORM to the izuma-dm-platform k3s checkout)"
    "$reg" require "$ENV" || die "ENV=$ENV is not a k3s stage"
    remote=$("$reg" show "$ENV" remote); vm=$("$reg" show "$ENV" vm)
    [[ -n $remote ]] || die "$ENV has no placement in the platform repo's .iz"
    echo "$remote:$vm"
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
    each i_load_ref
    [[ ${#LOAD_REFS[@]} -gt 0 ]] || die "no images selected for import"
    vm=$(stage_vm)
    say "import ${#LOAD_REFS[@]} image(s) into $vm"
    save_images | incus exec "$vm" -- k3s ctr images import -
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
    local kc=$1 rel=$2 kind name recreate resources
    resources=$(kubectl --kubeconfig "$kc" get deploy,sts,ds -n default -o json | python3 -c '
import json,sys
rel=sys.argv[1]
for obj in json.load(sys.stdin)["items"]:
    if obj["metadata"].get("annotations",{}).get("meta.helm.sh/release-name") != rel:
        continue
    spec=obj["spec"]; pod=spec["template"]["spec"]
    ports=pod.get("hostNetwork",False) or any(p.get("hostPort",0) for c in pod.get("containers",[]) for p in c.get("ports",[]))
    recreate=obj["kind"]=="Deployment" and spec.get("replicas",1)==1 and ports
    print(obj["kind"].lower(),obj["metadata"]["name"],"yes" if recreate else "no")
' "$rel")
    while read -r kind name recreate; do
        [[ -n "$kind" ]] || continue
        if [[ "$recreate" == yes ]]; then
            say "$rel: recreate single-replica host-port deployment $name"
            kubectl --kubeconfig "$kc" patch deployment "$name" -n default --type merge \
                -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
        fi
        kubectl --kubeconfig "$kc" rollout status "$kind/$name" -n default --timeout=10m
    done <<< "$resources"
}
deploy_apply() {
    # helm upgrade with the release's current user-supplied values re-sent as
    # a file: changes only this repo's image tags and keeps every other value,
    # including tags another repo's images set in a shared release (helmfile
    # apply would reset those to chart defaults). Not --reuse-values: helm 4
    # copies the previous values into the chart record too, and a stage's
    # values (600 KB of certificates) then overflow the 1 MiB release secret.
    local kc="$NUCLOUD_PLATFORM/$ENV.kubeconfig" rel e args chart prev
    prev=$(mktemp) && trap 'rm -f "$prev"' RETURN
    [[ ${#DEPLOY_SETS[@]} -gt 0 ]] || return 0
    [[ -f "$kc" ]] || die "no kubeconfig at $kc"
    for rel in $(printf '%s\n' "${DEPLOY_SETS[@]}" | cut -d'|' -f1 | sort -u); do
        args=()
        for e in "${DEPLOY_SETS[@]}"; do [[ "${e%%|*}" == "$rel" ]] && args+=(--set "${e#*|}"); done
        chart=$(KUBECONFIG="$kc" helm get metadata "$rel" -n default -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["chart"])')
        chart=$(find "$NUCLOUD_PLATFORM/charts" -name Chart.yaml -exec grep -l "^name: ${chart}$" {} + | head -1 | xargs dirname)
        [[ -d "$chart" ]] || die "chart for release $rel not found under $NUCLOUD_PLATFORM/charts"
        KUBECONFIG="$kc" helm get values "$rel" -n default -o yaml > "$prev"
        say "helm upgrade $rel on $ENV ${args[*]}"
        KUBECONFIG="$kc" helm upgrade "$rel" "$chart" -n default -f "$prev" "${args[@]}" --timeout 10m
        deploy_wait "$kc" "$rel"
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
    deploy) each i_deploy; deploy_apply ;;
    push) each i_push ;;
    run) shift; IFS='|' read -r n t _ <<<"${IMAGES[0]}"; docker run --rm -it "$REGISTRY/$n:$t-$SUFFIX" "$@" ;;
    *) echo "Usage: $0 {images|prereqs|image|sbom|test|smoke|image-load|deploy|push|run}" >&2; exit 1 ;;
esac
