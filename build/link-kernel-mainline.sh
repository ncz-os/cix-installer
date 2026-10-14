#!/bin/bash
# link-kernel-mainline.sh -- create assets/kernel/mainline, the build-local link
# to the staged Sky1 kernel release named in assets/kernel/mainline.release.
#
# The release (rNNN-<kver>-sky1-ncz-<date>) is tracked; where the kernel-staging
# pool is mounted is a site setting, so the link is generated per build tree
# and is never committed (.gitignore) or copied into an image layer
# (build/build-squashfs-layers.sh removes it from the base copy):
#   pool = $NCZ_KERNEL_STAGING_DIR, else <NCZ_YOCTO_SHARED_DIR>/kernel-staging
#          (build/lib/ncz-site.sh; docs/BUILD-SITE-CONFIG.md)
#   link = assets/kernel/mainline -> <pool>/<release>
#
# Usage: build/link-kernel-mainline.sh [--root DIR] [--check]
#   --root DIR  tree to act on (default: this script's repository)
#   --check     print what the link is or would be; change nothing
# Exit: 0 linked (or already correct), 1 no pool configured / release
#       directory missing, 2 usage or tree error.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."; CHECK=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "link-kernel-mainline: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
# shellcheck source=lib/ncz-site.sh
. "$HERE/lib/ncz-site.sh"
REL_FILE="$ROOT/assets/kernel/mainline.release"
LINK="$ROOT/assets/kernel/mainline"
[ -r "$REL_FILE" ] || { echo "link-kernel-mainline: $REL_FILE missing" >&2; exit 2; }
REL="$(sed 's/#.*//' "$REL_FILE" | tr -d '[:space:]')"
case "$REL" in
    r[0-9]*-*-sky1-ncz-[0-9]*) ;;
    *) echo "link-kernel-mainline: '$REL' in $REL_FILE is not rNNN-<kver>-sky1-ncz-<date>" >&2; exit 2 ;;
esac
case "$REL" in */*|.*) echo "link-kernel-mainline: release must be a plain directory name" >&2; exit 2 ;; esac

if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "link-kernel-mainline: $LINK is a real directory; left as is"
    exit 0
fi
POOL="${NCZ_KERNEL_STAGING_DIR:-}"
if [ -z "$POOL" ]; then
    ysd="$(ncz_site_value NCZ_YOCTO_SHARED_DIR yocto-shared-dir)"
    [ -n "$ysd" ] && POOL="${ysd%/}/kernel-staging"
fi
if [ -z "$POOL" ]; then
    if [ -L "$LINK" ]; then
        echo "link-kernel-mainline: no kernel-staging pool configured; keeping $LINK -> $(readlink "$LINK")"
        exit 0
    fi
    echo "link-kernel-mainline: no kernel-staging pool: set NCZ_YOCTO_SHARED_DIR (or ~/.config/ncz/yocto-shared-dir) or NCZ_KERNEL_STAGING_DIR" >&2
    exit 1
fi
TARGET="${POOL%/}/$REL"
if [ "$CHECK" = 1 ]; then
    echo "assets/kernel/mainline -> $TARGET$([ -d "$TARGET" ] || echo ' (missing)')"
    [ -d "$TARGET" ] && exit 0 || exit 1
fi
if [ ! -d "$TARGET" ]; then
    echo "link-kernel-mainline: staged release $TARGET not found" >&2
    exit 1
fi
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; then
    echo "assets/kernel/mainline -> $TARGET (unchanged)"
    exit 0
fi
ln -sfn "$TARGET" "$LINK" || { echo "link-kernel-mainline: cannot create $LINK" >&2; exit 2; }
echo "assets/kernel/mainline -> $TARGET"
