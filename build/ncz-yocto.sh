#!/usr/bin/env bash
# Bootstrap pinned Yocto layers locally and run BitBake with shared NFS
# downloads/sstate. Usage: ncz-yocto.sh [--name NAME] [--bootstrap-only] [--] [bitbake arguments]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$SCRIPT_DIR/yocto-layers.conf"
LAYERS_ROOT="${NCZ_YOCTO_LAYERS_DIR:-${HOME:?}/yocto-layers}"
BUILD_NAME="default"
BOOTSTRAP_ONLY=0
IMAGE="${NCZ_YOCTO_IMAGE:-ncz-yocto-y6:trixie}"
ENGINE="${NCZ_CONTAINER_ENGINE:-podman}"
SHARED_CONTAINER=/yocto-shared
LAYERS_CONTAINER=/workdir/layers
BUILD_CONTAINER=/workdir/build

while (($#)); do
    case "$1" in
        --name) BUILD_NAME="${2:?--name requires a value}"; shift 2 ;;
        --bootstrap-only) BOOTSTRAP_ONLY=1; shift ;;
        --) shift; break ;;
        -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
        *) break ;;
    esac
done
[[ "$BUILD_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid build name: $BUILD_NAME" >&2; exit 2; }
BITBAKE_ARGS=("${@:-coreutils-native}")

# Site settings (build/lib/ncz-site.sh): the shared Yocto export root
# (downloads/ + sstate-cache/), and optional authenticated git fallbacks.
. "$SCRIPT_DIR/lib/ncz-site.sh"
SHARED_ROOT="$(ncz_site_value NCZ_YOCTO_SHARED_DIR yocto-shared-dir)"
if [ -z "$SHARED_ROOT" ] || ! mountpoint -q "$SHARED_ROOT" || [ ! -d "$SHARED_ROOT/downloads" ] || [ ! -d "$SHARED_ROOT/sstate-cache" ]; then
    echo "ERROR: shared Yocto export not available: set NCZ_YOCTO_SHARED_DIR (or ~/.config/ncz/yocto-shared-dir) to a mounted directory holding downloads/ and sstate-cache/ (got '${SHARED_ROOT:-<unset>}')" >&2
    exit 1
fi
# Optional fallback git base for layers whose public URL is unreachable or lacks
# the pinned commit: "<base>/<layer>.git"; NCZ_YOCTO_FALLBACK_BASE or
# ~/.config/ncz/yocto-fallback-base. Its ssh command: NCZ_STORE_SSH_COMMAND or
# ~/.config/ncz/store-ssh-command (default: plain ssh).
FALLBACK_BASE="$(ncz_site_value NCZ_YOCTO_FALLBACK_BASE yocto-fallback-base)"
STORE_SSH="$(ncz_site_value NCZ_STORE_SSH_COMMAND store-ssh-command)"
STORE_SSH="${STORE_SSH:-ssh}"

command -v git >/dev/null || { echo "ERROR: git is required" >&2; exit 1; }
mkdir -p "$LAYERS_ROOT"

fetch_layer() {
    local name="$1" url="$2" fallback="$3" revision="$4" dir="$LAYERS_ROOT/$name"
    if [ -z "$fallback" ] && [ -n "$FALLBACK_BASE" ]; then fallback="${FALLBACK_BASE%/}/$name.git"; fi
    if [ -e "$dir" ] && [ ! -d "$dir/.git" ]; then
        echo "ERROR: $dir exists but is not a git checkout" >&2; return 1
    fi
    if [ ! -d "$dir/.git" ]; then
        echo "[ncz-yocto] clone $name"
        if ! git clone "$url" "$dir"; then
            [ -n "$fallback" ] || return 1
            echo "[ncz-yocto] primary unavailable; trying the configured fallback for $name"
            GIT_SSH_COMMAND="$STORE_SSH" git clone "$fallback" "$dir"
        fi
    fi
    [ -w "$dir/.git/objects" ] || {
        echo "ERROR: $dir/.git/objects is not writable (check for root-owned objects)" >&2; return 1
    }
    echo "[ncz-yocto] pin $name at $revision"
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
        echo "ERROR: $dir has tracked local changes; refusing to overwrite them" >&2; return 1
    fi
    if ! git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$dir" fetch --tags origin || true
    fi
    if ! git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null && [ -n "$fallback" ]; then
        echo "[ncz-yocto] pinned object absent from primary; fetching the configured fallback for $name"
        GIT_SSH_COMMAND="$STORE_SSH" \
            git -C "$dir" fetch "$fallback" '+refs/heads/*:refs/remotes/fallback/*'
    fi
    git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null || {
        echo "ERROR: pinned revision $revision not found for $name" >&2; return 1
    }
    git -C "$dir" checkout --detach "$revision"
}

while IFS='|' read -r name url fallback revision; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    fetch_layer "$name" "$url" "$fallback" "$revision"
done < "$MANIFEST"

BUILD_ROOT="${NCZ_YOCTO_BUILD_ROOT:-${HOME}/yocto-build}/$BUILD_NAME"
mkdir -p "$BUILD_ROOT/conf"
sed -e "s|@SHARED_CONTAINER@|$SHARED_CONTAINER|g" \
    -e "s|@BUILD_CONTAINER@|$BUILD_CONTAINER|g" \
    "$SCRIPT_DIR/yocto/local.conf.in" > "$BUILD_ROOT/conf/local.conf"
sed -e "s|@LAYERS_CONTAINER@|$LAYERS_CONTAINER|g" \
    "$SCRIPT_DIR/yocto/bblayers.conf.in" > "$BUILD_ROOT/conf/bblayers.conf"

echo "[ncz-yocto] shared DL_DIR:    $SHARED_ROOT/downloads ($SHARED_CONTAINER/downloads in container)"
echo "[ncz-yocto] shared SSTATE_DIR:$SHARED_ROOT/sstate-cache ($SHARED_CONTAINER/sstate-cache in container)"
echo "[ncz-yocto] local TMPDIR:     $BUILD_ROOT/tmp ($BUILD_CONTAINER/tmp in container)"
echo "[ncz-yocto] local layers:     $LAYERS_ROOT ($LAYERS_CONTAINER in container)"
(( BOOTSTRAP_ONLY == 0 )) || exit 0

command -v "$ENGINE" >/dev/null || { echo "ERROR: container engine '$ENGINE' is required" >&2; exit 1; }
RUNNER=("$ENGINE")
if [ "$ENGINE" = podman ] && ! podman unshare stat -f "$SHARED_ROOT" >/dev/null 2>&1; then
    if sudo -n podman info >/dev/null 2>&1; then
        RUNNER=(sudo -n podman)
        echo "[ncz-yocto] rootless Podman cannot stat this NFS mount; using rootful Podman"
    else
        echo "ERROR: rootless Podman cannot bind $SHARED_ROOT and passwordless sudo podman is unavailable" >&2
        exit 1
    fi
fi
if ! "${RUNNER[@]}" image exists "$IMAGE"; then
    echo "[ncz-yocto] building missing container image $IMAGE"
    "${RUNNER[@]}" build --build-arg BUILD_UID="$(id -u)" --build-arg BUILD_GID="$(id -g)" \
        -t "$IMAGE" -f "$REPO_ROOT/docker/Containerfile.yocto" "$REPO_ROOT/docker"
fi

printf -v bb_command '%q ' "${BITBAKE_ARGS[@]}"
exec "${RUNNER[@]}" run --rm --security-opt label=disable \
    -v "$LAYERS_ROOT:$LAYERS_CONTAINER:ro" \
    -v "$BUILD_ROOT:$BUILD_CONTAINER" \
    -v "$SHARED_ROOT:$SHARED_CONTAINER" \
    -w "$BUILD_CONTAINER" "$IMAGE" \
    "git config --global --add safe.directory '*' && source $LAYERS_CONTAINER/openembedded-core/oe-init-build-env $BUILD_CONTAINER >/dev/null && bitbake $bb_command"
