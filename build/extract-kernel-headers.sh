#!/usr/bin/env bash
# extract-kernel-headers.sh — produce kernel-headers asset for one of LTS/NEXT
#
# r75 task #66: DKMS (NPU/GPU drivers) requires linux-headers-$KVER on the
# target. Cix's build-kernel.sh (`bindeb-pkg`) already produces a
# linux-headers-*.deb but the cix-installer pipeline never captured it.
#
# This script:
#   1. takes a built kernel source tree + KVER
#   2. produces an unprivileged tarball containing `lib/modules/$KVER/build/`
#      with the build infra DKMS needs (Makefile, scripts/, include/,
#      arch/<a>/include/, .config, Module.symvers, tools/objtool if present)
#   3. writes the tarball to assets/kernel/<lts|next>/headers-cixmini.tar.zst
#
# Why a tarball rather than the bindeb-pkg .deb:
#   - Matches the existing modules-cixmini.tgz pattern (10-our-kernel.sh
#     already does tar-extract into /usr; one more tar is trivial)
#   - .deb name embeds version + revision which drift between rebuilds
#   - Avoids the `dpkg -i` post-install failure modes if Apt sources lock
#   - Smaller (zstd vs gzip; ~25% smaller for typical header trees)
#
# Usage:
#   extract-kernel-headers.sh --kernel-src /path/to/cixmini-msr1-src/linux \
#                              --kver 6.18.26-cix-sky1-lts \
#                              --output assets/kernel/lts/headers-cixmini.tar.zst
set -euo pipefail

KSRC=""
KVER=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-src) KSRC="$2"; shift 2 ;;
        --kver)       KVER="$2"; shift 2 ;;
        --output)     OUT="$2";  shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -d "$KSRC" ]    || { echo "ERROR: --kernel-src not a dir: $KSRC" >&2; exit 1; }
[ -n "$KVER" ]    || { echo "ERROR: --kver required" >&2; exit 1; }
[ -n "$OUT" ]     || { echo "ERROR: --output required" >&2; exit 1; }
[ -f "$KSRC/Makefile" ]       || { echo "ERROR: $KSRC/Makefile missing" >&2; exit 1; }
[ -f "$KSRC/Module.symvers" ] || { echo "ERROR: $KSRC/Module.symvers missing — kernel not yet built?" >&2; exit 1; }
[ -f "$KSRC/.config" ]        || { echo "ERROR: $KSRC/.config missing — kernel not configured?" >&2; exit 1; }

for t in zstd tar find rsync; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done

ARCH="${ARCH:-arm64}"
STAGE=$(mktemp -d -t cix-headers-XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

ROOT="$STAGE/lib/modules/$KVER/build"
mkdir -p "$ROOT/arch/$ARCH"

echo "[extract] $KVER from $KSRC ($ARCH)"

# Top-level files DKMS Module.builder reads
for f in Makefile Kbuild Kconfig .config Module.symvers System.map; do
    if [ -e "$KSRC/$f" ]; then
        cp -a "$KSRC/$f" "$ROOT/$f"
    fi
done

# Top-level dirs DKMS needs
rsync -a --include='*/' \
    --include='Makefile' --include='Kbuild' --include='Kconfig*' \
    --include='*.h' --include='*.S' --include='*.s' \
    --include='*.lds' --include='*.lds.S' \
    --include='*.sh' --include='*.pl' --include='*.py' \
    --include='*.c' \
    --exclude='*' \
    "$KSRC/include/" "$ROOT/include/"

rsync -a --include='*/' \
    --include='Makefile' --include='Kbuild' --include='Kconfig*' \
    --include='*.h' --include='*.S' --include='*.s' \
    --include='*.lds' --include='*.lds.S' \
    --include='*.sh' --include='*.pl' \
    --exclude='*' \
    "$KSRC/arch/$ARCH/include/" "$ROOT/arch/$ARCH/include/"

# scripts/ — compiled scripts (mod, basic, kconfig binaries) used by DKMS
mkdir -p "$ROOT/scripts"
rsync -a "$KSRC/scripts/" "$ROOT/scripts/" \
    --exclude='*.o' \
    --exclude='*.cmd' \
    --exclude='*.tmp' \
    --exclude='.tmp_versions/'

# arch-specific tools
if [ -d "$KSRC/arch/$ARCH/tools" ]; then
    mkdir -p "$ROOT/arch/$ARCH/tools"
    rsync -a "$KSRC/arch/$ARCH/tools/" "$ROOT/arch/$ARCH/tools/" \
        --exclude='*.o' --exclude='*.cmd' --exclude='*.tmp'
fi

# tools/objtool (kernel >=4.20 needs this for some .ko builds)
if [ -d "$KSRC/tools/objtool" ]; then
    mkdir -p "$ROOT/tools"
    rsync -a "$KSRC/tools/" "$ROOT/tools/" \
        --include='objtool/***' \
        --include='build/***' \
        --include='include/***' \
        --include='Makefile*' \
        --include='lib/***' \
        --exclude='*'
fi

# /lib/modules/$KVER/source symlink isn't needed for DKMS rebuild; skip.
# /lib/modules/$KVER/build is the canonical target.

# Symlink build → ../../usr/src/linux-headers-$KVER pattern is what apt's
# linux-headers .deb does. We don't replicate that; DKMS reads
# /lib/modules/$KVER/build directly.

# Sanity: did we capture the basics?
[ -f "$ROOT/Makefile" ]                   || { echo "ERROR: post-stage Makefile missing" >&2; exit 1; }
[ -f "$ROOT/.config" ]                    || { echo "ERROR: post-stage .config missing" >&2; exit 1; }
[ -f "$ROOT/Module.symvers" ]             || { echo "ERROR: post-stage Module.symvers missing" >&2; exit 1; }
[ -f "$ROOT/scripts/Makefile" ] \
    || [ -f "$ROOT/scripts/Makefile.build" ] \
    || { echo "ERROR: post-stage scripts/ Makefiles missing" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
TMP_OUT="$OUT.tmp"
tar -C "$STAGE" \
    --owner=0 --group=0 \
    -cf - "lib/modules/$KVER/build" \
    | zstd -19 -T0 -q -o "$TMP_OUT"
mv "$TMP_OUT" "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
COUNT=$(find "$ROOT" -type f | wc -l)
echo "[extract] OK — $SIZE ($COUNT files) → $OUT"
