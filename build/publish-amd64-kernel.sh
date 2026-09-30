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
# POLICY UPDATE (operator directive 2026-09-30, .66 incident): amd64 ships
# ONLY the stable 7.2.x line. There is no validated amd64 7.3 kernel, so
# the publisher is now stable-only -- the `edge` argument is preserved as
# a hard-fail exit so any operator muscle-memory invocation surfaces the
# policy gap loudly. The kernel-default-policy verifier would otherwise
# refuse the build further downstream and the operator would have to
# back-track to find why the directory re-appeared.
#
# Use this instead of mkdir+cp. It cannot produce a name the consumer will
# miss, because it builds the name from the same line identifier.
set -uo pipefail

usage() {
    cat >&2 <<EOF
usage: $0 <stable> <deb-dir> [YYYYMMDD]

  stable  the unified T2 line (v7.2.x + t2linux patches) -- serves BOTH T2
          Macs and regular PCs; the t2linux series is DMI/PCI-ID gated.
          amd64 ships ONLY this line (operator directive 2026-09-30).

  <deb-dir>  directory holding linux-image-*.deb and linux-headers-*.deb
             (and optionally config-*), as produced by the kernel build.

Note: publishing an "edge" build is no longer supported here. amd64-edge-*
builds sitting in the pool will fail preflight-freshness-gate.sh as
orphans and block the build -- prune or rename them if you find any.
EOF
}

LINE="${1:-}"; DEBDIR="${2:-}"; STAMP="${3:-$(date -u +%Y%m%d)}"
case "$LINE" in
    stable) ;;
    edge)
        # Operator policy 2026-09-30: amd64 ships NO edge kernel. Refuse
        # to publish one rather than silently re-introduce the channel.
        echo "ERROR: amd64 ships NO edge kernel (operator directive 2026-09-30, .66 incident). 'edge' is reserved for arm64 only." >&2
        echo "       To publish a 7.2.x stable line instead, run: build/publish-amd64-kernel.sh stable <deb-dir>" >&2
        exit 64
        ;;
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
