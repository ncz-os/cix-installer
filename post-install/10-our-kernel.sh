#!/bin/bash
# 10-our-kernel.sh — install the staged linux-cix-sky1 kernel payload.
# full/thin ISOs stage LTS+NEXT; netinstall stages NEXT only.
#
# Source layout (from build-iso.sh staging):
#   /usr/local/lib/cix-installer/assets/kernel/
#     KVER_LTS                            (full/thin)
#     KVER_NEXT                           (full/thin/netinstall)
#     lts/Image-cixmini.bin
#     lts/modules-cixmini.tgz
#     next/Image-cixmini.bin              (optional — only if BETA was baked)
#     next/modules-cixmini.tgz
#
# Result on target:
#   /boot/vmlinuz-$KVER_LTS                (if LTS was baked)
#   /boot/vmlinuz-$KVER_NEXT               (if NEXT was baked)
#   /usr/lib/modules/$KVER_LTS/            (if LTS was baked)
#   /usr/lib/modules/$KVER_NEXT/           (if NEXT was baked)
set -euo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/kernel
INSTALLER_META=/usr/local/lib/cix-installer

# Pull KVERs from sidecars staged by build-iso.sh
KVER_LTS=""
if [ -f "$INSTALLER_META/KVER_LTS" ]; then
    KVER_LTS=$(cat "$INSTALLER_META/KVER_LTS" 2>/dev/null || true)
fi
KVER_NEXT=""
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
fi

if [ -z "$KVER_LTS" ] && [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_LTS or KVER_NEXT sidecar present"
    exit 1
fi
if [ -n "$KVER_LTS" ]; then
    [ -f "$ASSETS/lts/Image-cixmini.bin" ]   || { echo "ERROR: LTS kernel binary missing"; exit 1; }
    [ -f "$ASSETS/lts/modules-cixmini.tgz" ] || { echo "ERROR: LTS modules tarball missing"; exit 1; }
fi

echo "[10] installing kernel payload — LTS=${KVER_LTS:-(not present)}  NEXT=${KVER_NEXT:-(not present)}"

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

    # Headers for DKMS (NPU/GPU drivers). Optional asset — if missing,
    # warn loudly because any DKMS rebuild on target will then fail.
    if [ -f "$ASSETS/$label/headers-cixmini.tar.zst" ]; then
        if ! command -v zstd >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends zstd
        fi
        zstd -dc "$ASSETS/$label/headers-cixmini.tar.zst" \
            | tar -xf - -C / --keep-directory-symlink
        if [ -d "/lib/modules/$kver/build" ] && [ -f "/lib/modules/$kver/build/Makefile" ]; then
            local hdrcount
            hdrcount=$(find "/lib/modules/$kver/build/include" -name '*.h' 2>/dev/null | wc -l)
            echo "    extracted $hdrcount header files → /lib/modules/$kver/build/"
        else
            echo "    WARN: $label headers tarball present but /lib/modules/$kver/build/Makefile missing — DKMS will fail" >&2
        fi
    else
        echo "    WARN: $label headers asset missing ($ASSETS/$label/headers-cixmini.tar.zst) — DKMS rebuild blocked on target" >&2
    fi

    depmod -a "$kver"
}

INSTALLED_KERNELS=0

if [ -n "$KVER_LTS" ]; then
    install_kernel lts "$KVER_LTS"
    INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
else
    echo "  [lts] not present in ISO — skipping"
fi

if [ -n "$KVER_NEXT" ] && \
   [ -f "$ASSETS/next/Image-cixmini.bin" ] && \
   [ -f "$ASSETS/next/modules-cixmini.tgz" ]; then
    install_kernel next "$KVER_NEXT"
    INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
else
    echo "  [next] BETA kernel not present in ISO — skipping"
fi

if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "[10] ERROR: no staged kernel assets were installed"
    exit 1
fi

# Remove Debian's default linux-image-arm64 — we ship our own.
apt-get remove -y --purge "linux-image-arm64" || true
apt-get autoremove -y --purge || true

echo ""
echo "Kernel summary:"
[ -n "$KVER_LTS" ] && ls -lh "/boot/vmlinuz-$KVER_LTS" 2>/dev/null || true
[ -n "$KVER_NEXT" ] && ls -lh "/boot/vmlinuz-$KVER_NEXT" 2>/dev/null || true
echo ""
echo "Module trees:"
[ -n "$KVER_LTS" ] && [ -d "/lib/modules/$KVER_LTS" ] && \
    { echo "  --- lts ---"; ls "/lib/modules/$KVER_LTS" | head -5; } || true
[ -n "$KVER_NEXT" ] && [ -d "/lib/modules/$KVER_NEXT" ] && \
    { echo "  --- next ---"; ls "/lib/modules/$KVER_NEXT" | head -5; } || true
