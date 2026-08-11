#!/bin/bash
# 10-our-kernel.sh — install the LTS/NEXT kernel via apt (dpkg-tracked).
#
# 26.6-r193: rewritten. Previously this hook raw-copied the kernel
# (install -D + tar xzf) straight from ISO assets into /boot and
# /usr/lib/modules -- completely bypassing dpkg. Result: apt/dpkg had
# ZERO record any kernel package was installed (`apt-cache policy
# linux-image-cixmini-lts` showed "Installed: (none)" even on a running
# system using that exact kernel), so `apt upgrade` could never pull a
# new kernel -- there was nothing dpkg thought needed upgrading. This
# directly broke the documented "apt upgrade pulls new kernels, no
# reinstall" OTA story (confirmed live on .66, 2026-07-06).
#
# Fix: install via `apt-get install linux-image-cixmini-{lts,edge}` from
# the same Buildkite repo (ncz-os/ncz) the OTA channel already uses, so
# dpkg tracks the kernel like any other package and a later `apt upgrade`
# works as documented. This needs the Buildkite apt source wired +
# indexed BEFORE we can resolve these packages -- normally done by
# 24-apt-sources.sh, which sorts numerically AFTER this hook (10 < 24), so
# we invoke it directly here rather than relying on hook ordering
# (24-apt-sources.sh is idempotent -- safe to call twice; it still runs
# again later in its normal position for the machine-gated hooks).
#
# What variant to install is still decided by the KVER_LEGACY/KVER_NEXT
# sidecars staged by build-iso.sh (full/thin ISOs stage both; netinstall
# stages NEXT only) -- that decision is about which ISO variant this is,
# not about how the kernel lands on disk, so it's unchanged.
#
# Bootloader wiring for the newly-installed kernel (refind.conf) happens
# via post-install/70-bootloader.sh later in this same run (install time)
# and via /etc/kernel/postinst.d/zz1-ncz-refind-refresh (any future
# apt-driven kernel install/upgrade) -- see that hook + assets/refind/
# ncz-refind-refresh.sh for why raw-copying broke that path too.
set -euo pipefail

INSTALLER_META=/usr/local/lib/cix-installer
HERE="$(dirname "$0")"

KVER_LEGACY=""
# KVER_LTS is the pre-rename sidecar name. An ISO built before the 7.0.12
# channel was renamed from "lts" to "legacy" wrote that file, and systems
# installed from those ISOs still have it, so accept either. Drop the
# fallback once no supported image writes the old name.
if [ -f "$INSTALLER_META/KVER_LEGACY" ]; then
    KVER_LEGACY=$(cat "$INSTALLER_META/KVER_LEGACY" 2>/dev/null || true)
elif [ -f "$INSTALLER_META/KVER_LTS" ]; then
    KVER_LEGACY=$(cat "$INSTALLER_META/KVER_LTS" 2>/dev/null || true)
    echo "[10] note: read the pre-rename KVER_LTS sidecar ($KVER_LEGACY)"
fi
KVER_NEXT=""
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
fi

if [ -z "$KVER_LEGACY" ] && [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_LEGACY or KVER_NEXT sidecar present"
    exit 1
fi

echo "[10] installing kernel via apt — LTS=${KVER_LEGACY:-(not present)}  NEXT=${KVER_NEXT:-(not present)}"

# Wire the Buildkite apt source + refresh the index. Idempotent (safe to
# call again later at its normal position). Needed now because the
# linux-image-cixmini-* packages live only on Buildkite, not the Ubuntu
# archive.
if [ -x "$HERE/24-apt-sources.sh" ]; then
    "$HERE/24-apt-sources.sh"
else
    echo "ERROR: $HERE/24-apt-sources.sh missing — cannot wire the apt source needed to install the kernel"
    exit 1
fi

# zstd is this hook's OWN dependency: the kernel-headers tarball is
# zstd-compressed and install_kernel_headers() below refuses to unpack
# without it. The base squashfs layer is a plain Debian rootfs that does
# not ship zstd, so the headers were being silently skipped there --
# staged on disk, never installed, DKMS still broken. desktop.pkgs seeds
# zstd for the desktop layer, but this hook runs in the BASE layer too.
apt-get install -y --no-install-recommends kmod initramfs-tools zstd

INSTALLED_KERNELS=0

if [ -n "$KVER_LEGACY" ]; then
    echo "  [legacy] apt-get install linux-image-cixmini"
    # r203: --force-overwrite. The lts + edge channel packages can transiently
    # ship the SAME versioned /boot files (e.g. a baked edge at
    # 7.0.12-cix-sky1-next+r98 and an incoming lts at 7.0.12-cix-sky1-next+r202
    # both own /boot/config-7.0.12-cix-sky1-next), so dpkg aborts the unpack
    # with a cross-package overwrite error — which, under `set -e`, killed the
    # whole hook -> REQUIRED_PHASE_OK=0 -> 70-bootloader skipped -> empty ESP ->
    # r174 "not bootable" -> "late.sh failed". Both packages are first-party and
    # the colliding file is a benign kernel config/vmlinuz whose final owner is
    # correct once both channels settle on distinct unames (lts=7.0.12-next,
    # edge=7.2.0-rc5), so force-overwrite is safe here.
    apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-overwrite linux-image-cixmini
    lts_ok=1
    if [ ! -s "/boot/vmlinuz-$KVER_LEGACY" ]; then
        echo "WARN: linux-image-cixmini installed, but /boot/vmlinuz-$KVER_LEGACY is missing"
        echo "      (KVER_LEGACY sidecar / Buildkite package drift). /boot contents:"; ls -la /boot 2>&1
        lts_ok=0
    else
        modcount=$(find "/usr/lib/modules/$KVER_LEGACY" \( -name '*.ko' -o -name '*.ko.xz' \) 2>/dev/null | wc -l)
        [ "$modcount" -lt 50 ] && { echo "WARN: [legacy] modules dir suspiciously small (.ko=$modcount) — LTS unusable"; lts_ok=0; }
    fi
    if [ "$lts_ok" = 1 ]; then
        echo "    OK: /boot/vmlinuz-$KVER_LEGACY + $modcount .ko modules"
        INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
    else
        # r201: a broken/drifted kernel package must NOT abort Phase 1 — that
        # skips the bootloader + ALL Phase-2 software and leaves an unbootable
        # install. Drop this kernel's sidecar so 70-bootloader makes no entry
        # pointing at a missing vmlinuz, then continue. The guard after the edge
        # block enforces that at least one kernel actually installed.
        echo "WARN: LTS kernel unavailable — suppressing its boot entry, continuing."
        rm -f "$INSTALLER_META/KVER_LEGACY" /etc/cix-installer/KVER_LEGACY 2>/dev/null || true
        KVER_LEGACY=""
    fi
else
    echo "  [legacy] not present in ISO — skipping"
fi

if [ -n "$KVER_NEXT" ]; then
    echo "  [next] apt-get install linux-image-cixmini"
    # r203: same --force-overwrite rationale as the lts block above (transient
    # cross-channel /boot filename overlap must not abort the required phase).
    apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-overwrite linux-image-cixmini
    edge_ok=1
    if [ ! -s "/boot/vmlinuz-$KVER_NEXT" ]; then
        echo "WARN: linux-image-cixmini installed, but /boot/vmlinuz-$KVER_NEXT is missing"
        echo "      (KVER_NEXT sidecar / Buildkite package drift). /boot contents:"; ls -la /boot 2>&1
        edge_ok=0
    else
        modcount=$(find "/usr/lib/modules/$KVER_NEXT" \( -name '*.ko' -o -name '*.ko.xz' \) 2>/dev/null | wc -l)
        [ "$modcount" -lt 50 ] && { echo "WARN: [next] modules dir suspiciously small (.ko=$modcount) — edge unusable"; edge_ok=0; }
    fi
    if [ "$edge_ok" = 1 ]; then
        echo "    OK: /boot/vmlinuz-$KVER_NEXT + $modcount .ko modules"
        INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
    else
        # r201: EDGE (beta/NEXT) is NOT required for a bootable system — LTS is
        # the safety net. A drifted/broken edge package must not abort Phase 1
        # (see the LTS block). Drop the KVER_NEXT sidecar so 70-bootloader makes
        # no edge entry pointing at a missing kernel (LTS becomes the default),
        # and continue so Phase-2 software + the bootloader still run.
        echo "WARN: EDGE kernel unavailable — suppressing its boot entry; LTS remains bootable. Continuing."
        rm -f "$INSTALLER_META/KVER_NEXT" /etc/cix-installer/KVER_NEXT 2>/dev/null || true
        KVER_NEXT=""
    fi
else
    echo "  [next] BETA kernel not present in ISO — skipping"
fi

# r201: Phase-1 kernel guard — the install needs AT LEAST ONE working kernel.
# Individual LTS/edge failures above are non-fatal (so a single drifted package
# never bricks the whole install), but zero installed kernels IS fatal: there is
# nothing to boot, and letting the bootloader write entries for a kernel-less
# system would produce an unbootable install that looks successful.
if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "ERROR: no kernel installed (both LTS and EDGE failed) — Phase 1 cannot continue."
    exit 1
fi
echo "[10] kernel phase OK — $INSTALLED_KERNELS kernel(s) installed (LTS='${KVER_LEGACY:-none}' NEXT='${KVER_NEXT:-none}')"

# r196c: prune orphaned /usr/lib/modules/<ver> trees that don't match
# either kernel this hook actually installed. Confirmed 2026-07-18 on O6N:
# a stale 6.6.10-cix-build-generic/ tree (pre-dates this apt-managed-kernel
# rewrite, never dpkg-tracked, never cleaned across base-image rebuilds)
# shipped rtl_btusb.ko built against that old kernel. It can never load
# against KVER_LEGACY/KVER_NEXT (vermagic mismatch) and was never going to be
# needed anyway -- btusb+btrtl already cover Bluetooth for the real
# kernel -- but kmod still tries it on every boot and logs the mismatch,
# which reads as a broken driver rather than harmless dead weight. Only
# KVER_LEGACY/KVER_NEXT are ever legitimate on this image (see comment at
# top of file); anything else under /usr/lib/modules is leftover cruft.
echo "[10] pruning orphaned /usr/lib/modules/* trees (not KVER_LEGACY/KVER_NEXT)"
for moddir in /usr/lib/modules/*/; do
    kver="$(basename "$moddir")"
    [ "$kver" = "$KVER_LEGACY" ] && continue
    [ "$kver" = "$KVER_NEXT" ] && continue
    echo "    removing orphaned module tree: $kver"
    rm -rf "$moddir"
done
# 2026-08-02: prune orphaned /boot payloads the same way. The module-tree prune
# above has existed since r196c, but nothing ever removed the matching
# /boot/vmlinuz-<ver> + initrd.img-<ver>, so a superseded kernel left a vmlinuz
# behind with NO module tree. Found on the rc5 -> rc6 bump: the baked base
# rootfs still carried vmlinuz-7.2.0-rc5-sky1-ncz, and every subsequent
# update-initramfs run in the layer build emitted
#   cat: .../lib/modules/7.2.0-rc5-sky1-ncz/modules.builtin: No such file
#   depmod: WARNING: could not open modules.order at .../7.2.0-rc5-sky1-ncz
# A vmlinuz with no modules is unbootable if anything ever selects it, and the
# noise buries real initramfs errors. Only KVER_LEGACY/KVER_NEXT are ever
# legitimate on this image.
#
# Fail-safe: this prune's correctness depends on at least one expected KVER
# being non-empty. That is already guaranteed by the INSTALLED_KERNELS==0 guard
# further up (which exits 1), but a deletion loop must not rely on a check 35
# lines away — if both were ever empty, NOTHING would match and this would
# remove every kernel payload under /boot, including the one about to boot.
# Make the invariant local and explicit.
if [ -z "$KVER_LEGACY" ] && [ -z "$KVER_NEXT" ]; then
    echo "[10] WARN: both KVER_LEGACY and KVER_NEXT are empty — SKIPPING the /boot prune" >&2
    echo "[10]       (refusing to delete kernel payloads with nothing to compare against)" >&2
else
    echo "[10] pruning orphaned /boot kernel payloads (not KVER_LEGACY/KVER_NEXT)"
    for vmlinuz in /boot/vmlinuz-*; do
        [ -e "$vmlinuz" ] || continue
        kver="${vmlinuz#/boot/vmlinuz-}"
        [ -n "$KVER_LEGACY" ]  && [ "$kver" = "$KVER_LEGACY" ]  && continue
        [ -n "$KVER_NEXT" ] && [ "$kver" = "$KVER_NEXT" ] && continue
        echo "    removing orphaned boot payload: $kver"
        rm -f "/boot/vmlinuz-$kver" "/boot/initrd.img-$kver" \
              "/boot/System.map-$kver" "/boot/config-$kver"
    done
fi

[ -n "$KVER_LEGACY" ] && depmod -a "$KVER_LEGACY" 2>/dev/null || true
[ -n "$KVER_NEXT" ] && depmod -a "$KVER_NEXT" 2>/dev/null || true

if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "[10] ERROR: no kernel packages were installed"
    exit 1
fi

# Headers for DKMS (NPU/GPU/panthor drivers). There is still no
# linux-headers-cixmini-* package on Buildkite, so the headers ship as a
# tarball produced by build/extract-kernel-headers.sh:
#   assets/kernel/legacy/headers-cixmini.tar.zst  -> KVER_LEGACY
#   assets/kernel/edge/headers-cixmini.tar.zst    -> KVER_NEXT
# Each unpacks to lib/modules/$KVER/build/ (Makefile, scripts/, include/,
# arch/arm64/include/, .config, Module.symvers), which is exactly what DKMS
# needs. This is the same tar-into-/usr pattern the module tarball already
# uses.
#
# 2026-08-02: this consumption step did not exist. extract-kernel-headers.sh
# was written for r75 task #66 and then never wired to a caller, so every
# install shipped with /lib/modules/$KVER/build absent and the hook only
# warned. That is a real contradiction of the all-DKMS driver rule -- CIX
# drivers are DKMS by directive, and DKMS cannot rebuild any of them against a
# kernel whose build tree is missing. Confirmed on O6N: WARN for BOTH
# 7.0.12-cix-sky1-next and 7.2.0-rc5-sky1-ncz.
install_kernel_headers() {
    local kver="$1" channel="$2" tarball="" d
    [ -z "$kver" ] && return 0
    [ -f "/lib/modules/$kver/build/Makefile" ] && return 0
    for d in "$INSTALLER_META/assets/kernel/$channel" "/cdrom/cixmini/assets/kernel/$channel"; do
        [ -f "$d/headers-cixmini.tar.zst" ] || continue
        tarball="$d/headers-cixmini.tar.zst"
        break
    done
    [ -n "$tarball" ] || return 1
    if ! command -v zstd >/dev/null 2>&1; then
        echo "    WARN: $tarball present but zstd is missing — cannot unpack kernel headers" >&2
        return 1
    fi
    # The tarball carries lib/modules/$KVER/build/... . Extract under /usr with
    # --keep-directory-symlink: on a usr-merged root /lib IS a symlink to
    # usr/lib, and a plain `tar -C /` of a member named lib/ replaces that
    # symlink with a real directory -- the exact class of breakage that took a
    # board out in the initrd-overlay incident. Never relax this.
    if zstd -dc "$tarball" 2>/dev/null | tar -C /usr --keep-directory-symlink -xf - 2>/dev/null; then
        echo "    installed kernel headers for $kver from $(basename "$(dirname "$tarball")")/$(basename "$tarball")"
        return 0
    fi
    echo "    WARN: failed to unpack $tarball" >&2
    return 1
}

install_kernel_headers "$KVER_LEGACY"  legacy || true
install_kernel_headers "$KVER_NEXT" edge   || true

for kver in "$KVER_LEGACY" "$KVER_NEXT"; do
    [ -z "$kver" ] && continue
    if [ -f "/lib/modules/$kver/build/Makefile" ]; then
        echo "    headers OK for $kver (/lib/modules/$kver/build present — DKMS can rebuild)"
    else
        echo "    WARN: no kernel headers for $kver (/lib/modules/$kver/build/Makefile absent)" \
             "— DKMS rebuild blocked on target." >&2
        echo "          Remediation: build/extract-kernel-headers.sh --kernel-src <tree> --kver $kver" \
             "--output assets/kernel/<legacy|edge>/headers-cixmini.tar.zst, then rebuild the ISO." >&2
    fi
done

# Remove Debian's default linux-image-arm64 — we ship our own.
apt-get remove -y --purge "linux-image-arm64" || true
apt-get autoremove -y --purge || true

echo ""
echo "Kernel summary:"
[ -n "$KVER_LEGACY" ] && ls -lh "/boot/vmlinuz-$KVER_LEGACY" 2>/dev/null || true
[ -n "$KVER_NEXT" ] && ls -lh "/boot/vmlinuz-$KVER_NEXT" 2>/dev/null || true
echo ""
echo "Module trees:"
[ -n "$KVER_LEGACY" ] && [ -d "/lib/modules/$KVER_LEGACY" ] && \
    { echo "  --- lts ---"; ls "/lib/modules/$KVER_LEGACY" | head -5; } || true
[ -n "$KVER_NEXT" ] && [ -d "/lib/modules/$KVER_NEXT" ] && \
    { echo "  --- next ---"; ls "/lib/modules/$KVER_NEXT" | head -5; } || true
