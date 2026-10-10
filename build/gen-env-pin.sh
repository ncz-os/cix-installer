#!/bin/bash
# gen-env-pin.sh -- generate manifests/env.pin from the ACTUAL build
# environment on this host, so the environment pin can be committed and
# verified by preflight (build/lib/envpin.sh).
#
#   build/gen-env-pin.sh [--out manifests/env.pin] \
#       [--imagebuild localhost/ncz-imagebuild:trixie] \
#       [--payload-image debian:forky] [--check]
#
# --check: do not write; regenerate in memory and diff against the committed
#          file; exit 4 with the diff if they differ (like gen-base-pin --check).
#
# The imagebuild container digest is host-independent ONLY when every builder
# loads the SAME `podman save | podman load` tar.  The header records that
# requirement; preflight will FAIL if a host's local digest differs.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib/envpin.sh"

OUT="$ROOT/manifests/env.pin"
IMAGEBUILD="${NCZ_IMAGEBUILD_TAG:-localhost/ncz-imagebuild:trixie}"
PAYLOAD_IMAGE="${NCZ_BASE_IMAGE:-debian:forky}"
CHECK=0
IMAGEBUILD_DIGEST=""; PAYLOAD_DIGEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --imagebuild) IMAGEBUILD="$2"; shift 2 ;;
        --imagebuild-digest) IMAGEBUILD_DIGEST="$2"; shift 2 ;;
        --payload-image) PAYLOAD_IMAGE="$2"; shift 2 ;;
        --payload-digest) PAYLOAD_DIGEST="$2"; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "gen-env-pin: unknown argument: $1" >&2; exit 2 ;;
    esac
done

eng="$(ncz_envpin_engine || true)"
digest_of() {  # digest_of <image>
    local img="$1"
    [ -n "$eng" ] || { echo ""; return; }
    "$eng" image inspect --format '{{.Digest}}' "$img" 2>/dev/null \
      || "$eng" images --digests --no-trunc --format '{{.Digest}}' "$img" 2>/dev/null | head -1
}

emit() {  # emit <scope> <key> <value>
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

build_pin() {
    cat <<'HDR'
# manifests/env.pin -- the BUILD ENVIRONMENT pin.
#
# Determinism contract (docs/IMAGE-BUILD-PROCESS.md SS5): same git commit +
# same recorded pins => bit-identical artifacts.  This file supplies the
# missing half of "recorded pins": the ENVIRONMENT that produces the bytes.
#
# Two builds whose container digests or toolchain versions differ are NOT the
# same build, even at the same git SHA.  preflight (build/build-image.sh) runs
# build/lib/envpin.sh against this file and FAILS with a per-key diff on any
# mismatch; a build that cannot prove its environment is not reproducible.
#
# Columns: TAB-separated  scope<TAB>key<TAB>value
#   container  observed INSIDE the pinned container (host-independent, because
#              the container is pinned by digest)
#   host       observed on the build host (artifact-affecting host tools)
#   env        locale / TZ / umask
#   flag       a boolean assertion enforced by build/test-hermetic.sh
#   sde        the SOURCE_DATE_EPOCH derivation rule
#
# The imagebuild + payload container digests are host-independent ONLY if every
# builder loads the same `podman save | sudo podman load` tar.  A differing
# local digest is a preflight FAIL, not a warning: it means the build host is
# not the one the pin was taken from.
#
# Regenerate with: build/gen-env-pin.sh   (then commit).  It is a deliberate
# act: a toolchain bump is a new build-environment identity.
HDR
    # Container identity by DIGEST is the primary host-independent pin: a
    # digest-pinned image fixes its whole toolchain, so per-tool probing inside
    # it is redundant.  (The digest is host-independent only if every builder
    # loads the same `podman save | podman load` tar.)
    emit container imagebuild_image "$IMAGEBUILD"
    emit container imagebuild_digest "${IMAGEBUILD_DIGEST:-$(digest_of "$IMAGEBUILD")}"
    emit container payload_image "$PAYLOAD_IMAGE"
    emit container payload_image_digest "${PAYLOAD_DIGEST:-$(digest_of "$PAYLOAD_IMAGE")}"
    local key
    for key in mksquashfs unsquashfs mke2fs sgdisk sfdisk dpkg dpkg_deb gcc meson ninja python3 uname_m nproc; do
        local v; v="$(ncz_envpin_actual host "$key" "" 2>/dev/null)"
        [ -n "$v" ] && emit host "$key" "$v"
    done
    emit env LC_ALL C
    emit env TZ UTC
    emit env umask 022
    emit flag forbid_march_native 1
    emit flag jobs_independent 1
    emit sde source "git-commit-time else snapshot-epoch (build/lib/reproducible.py)"
}

if [ "$CHECK" = 1 ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/ncz-envpin-gen.XXXXXX")"
    build_pin > "$tmp"
    if ! diff -u "$OUT" "$tmp" >&2; then
        echo "gen-env-pin: $OUT is STALE (diff above); regenerate and commit it" >&2
        rm -f "$tmp"; exit 4
    fi
    rm -f "$tmp"
    echo "gen-env-pin: $OUT is current"
    exit 0
fi

build_pin > "$OUT"
echo "gen-env-pin: wrote $OUT ($(grep -cvE '^\s*#|^\s*$' "$OUT") keys)"
