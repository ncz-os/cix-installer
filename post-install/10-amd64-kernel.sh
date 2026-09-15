#!/bin/bash
# 10-amd64-kernel.sh — install BOTH AMD64 kernel lines (dpkg-tracked).
#
# AMD64 analogue of 10-our-kernel.sh (arm64/Sky1). Differs in one
# structural way: arm64 has exactly one shipping "edge" kernel, resolved
# via apt from the Buildkite repo. AMD64 has no apt repo for its kernels
# yet (both lines were just built on PROTEUS/CERBERUS this session, see
# docs/AMD64-PACKAGE-AUDIT.md) — so this hook installs the two staged
# .deb sets directly with dpkg, the same pattern 10-our-kernel.sh already
# uses for its *embedded-deb* fast path (local_deb()+dpkg -i), just
# without an apt-repo fallback because none exists.
#
# Both kernels are installed side by side on purpose: T2-unified-stable
# (7.2.6) as the DEFAULT, vanilla-edge (7.3-rc3) as the alternate GRUB
# entry. Do not prune one the way 10-our-kernel.sh prunes "not KVER_NEXT"
# — that pruning exists because arm64 ships exactly one kernel; here two
# are the intended end state.
set -euo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/kernel
INSTALLED_KERNELS=0

install_one(){
    local label="$1" dir="$2"
    local kver img hdr
    [ -d "$dir" ] || { echo "[10-amd64] WARN: $dir absent — skipping $label"; return 0; }
    kver=$(cat "$dir/KVER" 2>/dev/null || true)
    img=$(find "$dir" -maxdepth 1 -name 'linux-image-*.deb' | sort -V | tail -1)
    hdr=$(find "$dir" -maxdepth 1 -name 'linux-headers-*.deb' | sort -V | tail -1)
    if [ -z "$kver" ] || [ -z "$img" ]; then
        echo "[10-amd64] WARN: $label incomplete (kver='$kver' img='$img') — skipping"
        return 0
    fi
    echo "[10-amd64] installing $label kernel $kver"
    echo "    $(basename "$img")"
    [ -n "$hdr" ] && echo "    $(basename "$hdr")"
    # dpkg first (fast, no network); fix any unmet deps via apt against the
    # sources 24-apt-sources.sh already wired for the base manifest install.
    if ! dpkg -i "$img" ${hdr:+"$hdr"} 2>&1 | tail -20; then
        echo "    dpkg reported unmet deps — resolving via apt-get -f install"
        apt-get -f install -y 2>&1 | tail -20 || true
    fi
    if [ ! -s "/boot/vmlinuz-$kver" ]; then
        echo "[10-amd64] WARN: $label installed but /boot/vmlinuz-$kver missing" >&2
        ls -la /boot 2>&1
        return 0
    fi
    modcount=$(find "/usr/lib/modules/$kver" \( -name '*.ko' -o -name '*.ko.xz' \) 2>/dev/null | wc -l)
    if [ "$modcount" -lt 50 ]; then
        echo "[10-amd64] WARN: $label modules dir suspiciously small (.ko=$modcount)" >&2
        return 0
    fi
    echo "    OK: /boot/vmlinuz-$kver + $modcount .ko modules"
    INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
    depmod -a "$kver" 2>/dev/null || true
    echo "$kver" >> /usr/local/lib/cix-installer/KVER_LIST_AMD64
}

: > /usr/local/lib/cix-installer/KVER_LIST_AMD64

install_one "stable (T2-unified)" "$ASSETS/amd64-stable"
install_one "edge (vanilla 7.3-rc3)" "$ASSETS/amd64-edge"

if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "[10-amd64] ERROR: no AMD64 kernel installed — Phase 1 cannot continue." >&2
    exit 1
fi

# Debian's generic kernel is not needed once a real NCZ kernel line is in —
# same rationale as 10-our-kernel.sh's "we ship our own" removal.
apt-get remove -y --purge "linux-image-amd64" 2>/dev/null || true
apt-get autoremove -y --purge 2>/dev/null || true

echo "[10-amd64] kernel phase OK — $INSTALLED_KERNELS line(s) installed:"
cat /usr/local/lib/cix-installer/KVER_LIST_AMD64 2>/dev/null || true
