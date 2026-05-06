#!/bin/bash
# 10-our-kernel.sh — install BOTH our linux-cix-sky1 6.18.26 LTS kernel
# (default) and linux-cix-sky1-next 7.0.1 BETA kernel (alongside).
#
# Source layout (from build-iso.sh staging):
#   /usr/local/lib/cix-installer/assets/kernel/
#     KVER_LTS                            (single-line file written by build-iso.sh)
#     KVER_NEXT
#     lts/Image-cixmini.bin
#     lts/modules-cixmini.tgz
#     next/Image-cixmini.bin              (optional — only if BETA was baked)
#     next/modules-cixmini.tgz
#
# Result on target:
#   /boot/vmlinuz-$KVER_LTS                (always)
#   /boot/vmlinuz-$KVER_NEXT               (if NEXT was baked)
#   /usr/lib/modules/$KVER_LTS/            (always)
#   /usr/lib/modules/$KVER_NEXT/           (if NEXT was baked)
#
# 70-bootloader.sh wires these into systemd-boot loader entries with
# LTS as default and NEXT marked [BETA].
set -euo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/kernel
INSTALLER_META=/usr/local/lib/cix-installer

# Pull KVERs from sidecars staged by build-iso.sh
[ -f "$INSTALLER_META/KVER_LTS" ] || { echo "ERROR: KVER_LTS sidecar missing"; exit 1; }
KVER_LTS=$(cat "$INSTALLER_META/KVER_LTS")
KVER_NEXT=""
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
fi

[ -n "$KVER_LTS" ] || { echo "ERROR: KVER_LTS empty"; exit 1; }
[ -f "$ASSETS/lts/Image-cixmini.bin" ]   || { echo "ERROR: LTS kernel binary missing"; exit 1; }
[ -f "$ASSETS/lts/modules-cixmini.tgz" ] || { echo "ERROR: LTS modules tarball missing"; exit 1; }

echo "[10] installing dual kernel — LTS=$KVER_LTS  NEXT=${KVER_NEXT:-(not present)}"

# Ensure kmod (depmod, modprobe, lsmod) is present.
apt-get install -y --no-install-recommends kmod

install_kernel() {
    local label=$1            # lts or next
    local kver=$2

    echo "  [$label] $kver"
    install -D -m 0644 "$ASSETS/$label/Image-cixmini.bin" "/boot/vmlinuz-$kver"

    # Extract modules into /usr/lib/modules/$kver/ (usrmerge-aware path).
    # CAREFUL: the tarball has a top-level `lib/` directory entry. On
    # a usrmerge target (Debian bookworm+), `/lib` is a SYMLINK to
    # `/usr/lib`. `tar xzf -C /` would replace that symlink with a
    # real dir, orphaning `/lib/ld-linux-aarch64.so.1` and breaking
    # every dynamically linked binary in `/sbin` (depmod -> /bin/kmod,
    # which loads ld-linux).
    # Extract into /usr instead: `lib/` lands at `/usr/lib/` (already
    # a real dir) and modules end up at `/usr/lib/modules/$kver/`.
    #
    # NOTE: do NOT pre-create /usr/lib/modules/$kver before extracting.
    # If the tarball is malformed (wrong KVER root), the dir-already-
    # exists state would let depmod -a "$kver" succeed with zero
    # modules — silent failure → unbootable kernel. Let tar create it,
    # then verify content count.
    tar xzf "$ASSETS/$label/modules-cixmini.tgz" -C /usr --strip-components=0 --keep-directory-symlink
    if [ ! -d "/usr/lib/modules/$kver" ]; then
        echo "[10] ERROR: $label tarball did not produce /usr/lib/modules/$kver/"
        echo "       found instead under /usr/lib/modules/:"
        ls /usr/lib/modules/ 2>&1
        return 1
    fi
    local modcount
    modcount=$(find "/usr/lib/modules/$kver" -name '*.ko' 2>/dev/null | wc -l)
    if [ "$modcount" -lt 50 ]; then
        echo "[10] ERROR: $label modules dir suspiciously small (.ko count=$modcount, expected hundreds)"
        return 1
    fi
    echo "    extracted $modcount .ko modules → /usr/lib/modules/$kver/"
    depmod -a "$kver"
}

install_kernel lts "$KVER_LTS"

if [ -n "$KVER_NEXT" ] && \
   [ -f "$ASSETS/next/Image-cixmini.bin" ] && \
   [ -f "$ASSETS/next/modules-cixmini.tgz" ]; then
    install_kernel next "$KVER_NEXT"
else
    echo "  [next] BETA kernel not present in ISO — skipping"
fi

# Remove Debian's default linux-image-arm64 — we ship our own.
apt-get remove -y --purge "linux-image-arm64" || true
apt-get autoremove -y --purge || true

echo ""
echo "Kernel summary:"
ls -lh "/boot/vmlinuz-$KVER_LTS"
[ -n "$KVER_NEXT" ] && ls -lh "/boot/vmlinuz-$KVER_NEXT" 2>/dev/null || true
echo ""
echo "Module trees:"
ls "/lib/modules/$KVER_LTS" | head -5
[ -n "$KVER_NEXT" ] && [ -d "/lib/modules/$KVER_NEXT" ] && \
    { echo "  --- next ---"; ls "/lib/modules/$KVER_NEXT" | head -5; } || true
