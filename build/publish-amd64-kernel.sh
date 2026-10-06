#!/bin/bash
# Publish a built amd64 kernel into the shared ARGONAS kernel-staging pool
# under the name build/stage-amd64-kernel.sh actually looks for.
#
# WHY THIS EXISTS (2026-09-28). There was no publisher: amd64 kernels were
# staged by hand, so the naming contract lived only inside the CONSUMER's
# glob. Use this instead of mkdir+cp; it cannot produce a name the consumer
# will miss, because it builds the name from the same line identifier.
#
# POLICY UPDATE (operator directive 2026-10-05, unified): amd64 ships ONE
# kernel, 7.3, as the default and the installer boot kernel. The retired
# 7.2.x line and the separate edge channel are gone. The publisher accepts
# `default` (alias `stable`) and validates the built KVER against the
# committed assets/kernel/amd64-stable/KVER pin and the 7.3 series before
# writing anything to the pool.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat >&2 <<EOF
usage: $0 <default|stable> <deb-dir> [YYYYMMDD]

  default the unified 7.3 T2-capable line (v7.3 + t2linux patches) that
          serves BOTH T2 Macs and regular PCs; the t2linux series is
          DMI/PCI-ID gated. This is the amd64 DEFAULT and installer kernel.
          (alias: stable)

  <deb-dir>  directory holding linux-image-*.deb and linux-headers-*.deb
             (and optionally config-*), as produced by the kernel build.

The published directory name is amd64-stable-<kver>-<stamp>;
build/stage-amd64-kernel.sh globs amd64-stable-* and amd64-t2-*/*/.
EOF
}

LINE="${1:-}"; DEBDIR="${2:-}"; STAMP="${3:-$(date -u +%Y%m%d)}"
case "$LINE" in
    default|stable) LINE="stable" ;;
    edge) echo "ERROR: the amd64 edge channel was retired (unified 7.3 policy, operator 2026-10-05)" >&2; usage; exit 2 ;;
    *) usage; exit 2 ;;
esac
[ -d "${DEBDIR:-}" ] || { echo "ERROR: deb-dir not found: ${DEBDIR:-<unset>}" >&2; usage; exit 2; }

SHARED=""
for candidate in /mnt/argonas/datapool/yocto-shared /mnt/argonas-yocto-shared /nfs-shared /mnt/yocto-shared; do
    [ -d "$candidate/kernel-staging" ] && SHARED="$candidate/kernel-staging" && break
done
[ -n "$SHARED" ] || { echo "ERROR: no ARGONAS yocto-shared/kernel-staging mount found on this host" >&2; exit 1; }

IMG="$(find "$DEBDIR" -maxdepth 1 -iname 'linux-image-*.deb' | sort -V | tail -1)"
[ -n "$IMG" ] || { echo "ERROR: no linux-image-*.deb in $DEBDIR" >&2; exit 1; }
HDR="$(find "$DEBDIR" -maxdepth 1 -iname 'linux-headers-*.deb' | sort -V | tail -1)"
[ -n "$HDR" ] || { echo "ERROR: no linux-headers-*.deb in $DEBDIR -- post-install/10-amd64-kernel.sh needs BOTH" >&2; exit 1; }

# KVER from the package's own control data, not from the filename: the
# filename carries the Debian version, the kernel's release string is what
# /lib/modules and the boot entry use.
KVER="$(dpkg-deb -f "$IMG" Package 2>/dev/null | sed 's/^linux-image-//')"
[ -n "$KVER" ] || { echo "ERROR: could not read KVER from $IMG" >&2; exit 1; }

case "$KVER" in
    7.3.*|7.3-*) ;;
    *) echo "ERROR: built KVER '$KVER' is not the unified 7.3 series (operator 2026-10-05)" >&2; exit 1 ;;
esac

# The publication is pinned: publishing something other than the committed
# KVER would re-introduce the very drift stage-amd64-kernel.sh exists to
# prevent.
PIN_FILE="$ROOT/assets/kernel/amd64-stable/KVER"
[ -s "$PIN_FILE" ] || { echo "ERROR: $PIN_FILE missing -- commit the pinned amd64 7.3 KVER before publishing" >&2; exit 1; }
PINNED="$(tr -d '[:space:]' < "$PIN_FILE")"
if [ "$KVER" != "$PINNED" ]; then
    echo "ERROR: built KVER '$KVER' does not match the committed pin '$PINNED' (operator directive 2026-10-05)" >&2
    exit 1
fi

DEST="$SHARED/amd64-${LINE}-${KVER}-${STAMP}"
[ -e "$DEST" ] && { echo "ERROR: already published: $DEST" >&2; exit 1; }

mkdir -p "$DEST"
cp -f "$IMG" "$HDR" "$DEST/"
for cfg in "$DEBDIR"/config-*; do [ -f "$cfg" ] && cp -f "$cfg" "$DEST/"; done
printf '%s\n' "$KVER" > "$DEST/KVER"
( cd "$DEST" && sha256sum ./* > SHA256SUMS 2>/dev/null )

echo "[publish-amd64-kernel] published: $(basename "$DEST")"
echo "[publish-amd64-kernel] KVER=$KVER"
echo "[publish-amd64-kernel] stage it with: build/stage-amd64-kernel.sh default"

# Prove the consumer can actually see it, rather than assuming the name is
# right -- this is the exact failure this script exists to prevent.
newest="$(ls -dt "$SHARED"/amd64-${LINE}-* 2>/dev/null | head -1)"
if [ "$newest" != "$DEST" ]; then
    echo "WARNING: $(basename "$newest") is newer by mtime; stage-amd64-kernel.sh may pick THAT, not what was just published" >&2
else
    echo "[publish-amd64-kernel] verified: stage-amd64-kernel.sh will select this build"
fi
