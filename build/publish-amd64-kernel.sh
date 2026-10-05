#!/bin/bash
# Publish a built amd64 STABLE kernel into the shared ARGONAS
# kernel-staging pool under the name build/stage-amd64-kernel.sh actually
# looks for.
#
# WHY THIS EXISTS (2026-09-28). There was no publisher: amd64 kernels were
# staged by hand, so the naming contract lived only inside the CONSUMER's
# glob (stage_line's "amd64-stable-" / "amd64-edge-" prefixes). Two real
# kernels built 2026-09-27 were published as
#     amd64-t2-7.2.8-1-t2-trixie-20260927
#     amd64-t2-7.3.0-rc5-1-t2-trixie-20260927
# which match NEITHER prefix, so stage-amd64-kernel.sh never saw them and a
# gate-passing image kept shipping the older 7.2.7. Worse, the freshness
# preflight reported "amd64-stable -- locally staged kernel matches the
# newest in the shared pool" because it too only looks at its own prefix: a
# guard cannot see what it does not glob.
#
# POLICY UPDATE (operator directive 2026-10-05): amd64 ships the 7.2.x
# stable line as the default plus one pinned EDGE kernel: the 7.3.0-rc6 T2
# build carrying the AER ANFE revert (7.3.0-rc6-1-t2-edge-aerfix). The
# publisher accepts `stable` and `edge`; an edge publication lands under the
# amd64-edge- prefix that build/stage-amd64-kernel.sh and
# build/preflight-freshness-gate.sh both glob. Publish the pin the repo
# commits in assets/kernel/amd64-edge/KVER (any other -rc is refused).
#
# Use this instead of mkdir+cp. It cannot produce a name the consumer will
# miss, because it builds the name from the same line identifier.
set -uo pipefail

usage() {
    cat >&2 <<EOF
usage: $0 <stable> <deb-dir> [YYYYMMDD]

  stable  the unified T2 line (v7.2.x + t2linux patches) -- serves BOTH T2
          Macs and regular PCs; the t2linux series is DMI/PCI-ID gated.
          This is the amd64 DEFAULT line.

  edge    the pinned amd64 edge line (operator directive 2026-10-05): the
          7.3.0-rc6 T2 build with the AER ANFE revert
          (7.3.0-rc6-1-t2-edge-aerfix). Publish the KVER the repo commits
          in assets/kernel/amd64-edge/KVER; any other -rc is out of policy.

  <deb-dir>  directory holding linux-image-*.deb and linux-headers-*.deb
             (and optionally config-*), as produced by the kernel build.

The published directory name is amd64-<line>-<kver>-<stamp>; both
build/stage-amd64-kernel.sh and build/preflight-freshness-gate.sh glob
amd64-stable-* and amd64-edge-*.
EOF
}

LINE="${1:-}"; DEBDIR="${2:-}"; STAMP="${3:-$(date -u +%Y%m%d)}"
case "$LINE" in
    stable|edge) ;;
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

# Edge is pinned: publishing an -rc that is not the committed pin would
# re-introduce the very drift stage-amd64-kernel.sh exists to prevent.
if [ "$LINE" = edge ]; then
    PIN_FILE="$ROOT/assets/kernel/amd64-edge/KVER"
    [ -s "$PIN_FILE" ] || { echo "ERROR: $PIN_FILE missing -- commit the pinned amd64 edge KVER before publishing edge" >&2; exit 1; }
    PINNED="$(tr -d '[:space:]' < "$PIN_FILE")"
    case "$KVER" in
        "$PINNED") ;;
        *) echo "ERROR: built edge KVER '$KVER' does not match the committed pin '$PINNED' (operator directive 2026-10-05)" >&2; exit 1 ;;
    esac
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
echo "[publish-amd64-kernel] stage it with: build/stage-amd64-kernel.sh $LINE"

# Prove the consumer can actually see it, rather than assuming the name is
# right -- this is the exact failure this script exists to prevent.
newest="$(ls -dt "$SHARED"/amd64-${LINE}-* 2>/dev/null | head -1)"
if [ "$newest" != "$DEST" ]; then
    echo "WARNING: $(basename "$newest") is newer by mtime; stage-amd64-kernel.sh will pick THAT, not what was just published" >&2
else
    echo "[publish-amd64-kernel] verified: stage-amd64-kernel.sh $LINE will select this build"
fi
