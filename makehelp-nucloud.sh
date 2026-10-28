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
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f nucloud.env ]] || { echo "error: nucloud.env missing" >&2; exit 1; }
REGISTRY=ghcr.io/izumanetworks
SECRETS=() SSH=0 PLATFORM=linux/amd64 SMOKE_CMD=()
# shellcheck disable=SC1091
source nucloud.env
BUILD_NUMBER="${BUILD_NUMBER:-0}" ENV="${ENV:-k3s-dev}" ONLY="${ONLY:-}"
NUCLOUD_PLATFORM="${NUCLOUD_PLATFORM:-$HOME/workspace/izuma/izuma-dm-platform-k3s}"
GIT_HEAD="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

each() { # each <fn>: call fn name tag dockerfile context target release ref
    local e name tag df ctx tgt rel
    for e in "${IMAGES[@]}"; do
        IFS='|' read -r name tag df ctx tgt rel <<<"$e"
        [[ -z "$ONLY" || "$ONLY" == "$name" ]] || continue
        "$1" "$name" "$tag" "$df" "$ctx" "$tgt" "$rel" "$REGISTRY/$name:$tag-nucloud.$BUILD_NUMBER"
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
        --label org.opencontainers.image.version="$2-nucloud.$BUILD_NUMBER" \
        -f "$df" -t "$ref" "$ctx"
}

i_sbom() { syft "$7" -o spdx-json > "sbom-${1//\//_}.spdx.json"; say "sbom-${1//\//_}.spdx.json"; }

i_smoke() {
    local ref=$7 cid
    if [[ ${#SMOKE_CMD[@]} -gt 0 ]]; then
        docker run --rm --platform "$PLATFORM" --entrypoint "${SMOKE_CMD[0]}" "$ref" "${SMOKE_CMD[@]:1}"
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

stage_vm() {
    case "$ENV" in
        k3s-dev) echo "${INCUS_REMOTE:-cypressLinux}:k3s-dev" ;;
        k3s-dc)  echo "${INCUS_REMOTE:-D71}:k3s-dc" ;;
        *) die "ENV=$ENV is not a k3s stage" ;;
    esac
}

i_load() {
    local ref=$7 vm; vm=$(stage_vm)
    say "import $ref into $vm"
    docker save "$ref" | incus exec "$vm" -- k3s ctr images import -
}

i_deploy() {
    local name=$1 rel=${6%%=*} key=image.tag ref=$7 kc
    [[ "$6" == *=* ]] && key=${6#*=}
    [[ "$rel" == "-" || -z "$rel" ]] && { say "$name: no k3s release, skipped"; return; }
    kc="$NUCLOUD_PLATFORM/$ENV.kubeconfig"
    [[ -f "$kc" ]] || die "no kubeconfig at $kc"
    say "helmfile apply $rel on $ENV -> ${ref##*:}"
    ( cd "$NUCLOUD_PLATFORM" && KUBECONFIG="$kc" KUBE_STAGE="$ENV" REPO_ROOT="$NUCLOUD_PLATFORM" \
        helmfile -f helmfile.yaml -e "$ENV" -l "name=$rel" apply --skip-deps \
        --set "$key=${ref##*:}" )
}

i_push() { guard_tag "$7"; docker push "$7"; }

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
        grep -q '^FROM .* AS test' "$(IFS='|' read -r _ _ df _ <<<"${IMAGES[0]}"; echo "$df")" \
            && DOCKER_BUILDKIT=1 docker buildx build --platform "$PLATFORM" --target test . \
            || say "no test stage" ;;
    smoke) each i_smoke ;;
    image-load) each i_load ;;
    deploy) each i_deploy ;;
    push) each i_push ;;
    run) shift; IFS='|' read -r n t _ <<<"${IMAGES[0]}"; docker run --rm -it "$REGISTRY/$n:$t-nucloud.$BUILD_NUMBER" "$@" ;;
    *) echo "Usage: $0 {images|prereqs|image|sbom|test|smoke|image-load|deploy|push|run}" >&2; exit 1 ;;
esac
