#!/bin/bash
# 10-our-kernel.sh — install the edge kernel via apt (dpkg-tracked).
#
# 26.6-r193: rewritten. Previously this hook raw-copied the kernel
# (install -D + tar xzf) straight from ISO assets into /boot and
# /usr/lib/modules -- completely bypassing dpkg. Result: apt/dpkg had
# ZERO record any kernel package was installed (`apt-cache policy
# linux-image-cixmini` showed "Installed: (none)" even on a running
# system using that exact kernel), so `apt upgrade` could never pull a
# new kernel -- there was nothing dpkg thought needed upgrading. This
# directly broke the documented "apt upgrade pulls new kernels, no
# reinstall" OTA story (confirmed live on .66, 2026-07-06).
#
# Fix: install via `apt-get install linux-image-cixmini` from
# the same Buildkite repo (ncz-os/ncz) the OTA channel already uses, so
# dpkg tracks the kernel like any other package and a later `apt upgrade`
# works as documented. This needs the Buildkite apt source wired +
# indexed BEFORE we can resolve these packages -- normally done by
# 24-apt-sources.sh, which sorts numerically AFTER this hook (10 < 24), so
# we invoke it directly here rather than relying on hook ordering
# (24-apt-sources.sh is idempotent -- safe to call twice; it still runs
# again later in its normal position for the machine-gated hooks).
#
# Operator 2026-08-21: legacy kernel channel retired. Edge is the only
# shipping kernel and the KVER_NEXT sidecar is the only one read here.
#
# Bootloader wiring for the newly-installed kernel (refind.conf) happens
# via post-install/70-bootloader.sh later in this same run (install time)
# and via /etc/kernel/postinst.d/zz1-ncz-refind-refresh (any future
# apt-driven kernel install/upgrade) -- see that hook + assets/refind/
# ncz-refind-refresh.sh for why raw-copying broke that path too.
set -euo pipefail

INSTALLER_META=/usr/local/lib/cix-installer
HERE="$(dirname "$0")"

KVER_NEXT=""
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
fi

if [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_NEXT sidecar present (edge kernel is the only shipping channel)"
    exit 1
fi

echo "[10] installing kernel via apt — edge=$KVER_NEXT"

local_deb() {
    pattern="$1"
    find /cdrom/pool/main -maxdepth 1 -type f -name "$pattern" 2>/dev/null | sort -V | tail -1
}

# Wire the Buildkite apt source + refresh the index. Idempotent (safe to
# call again later at its normal position). Needed now because the
# linux-image-cixmini package lives only on Buildkite, not the Ubuntu
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
ZSTD_DEB=$(local_deb 'zstd_*.deb')
ZLIB_DEB=$(local_deb 'zlib1g_*.deb')
LIBGCC_DEB=$(local_deb 'libgcc-s1_*.deb')
LIBLZ4_DEB=$(local_deb 'liblz4-1_*.deb')
LIBLZMA_DEB=$(local_deb 'liblzma5_*.deb')
LIBSTDCXX_DEB=$(local_deb 'libstdc++6_*.deb')
if [ -n "$ZSTD_DEB" ] && [ -n "$ZLIB_DEB" ] && [ -n "$LIBGCC_DEB" ] && \
   [ -n "$LIBLZ4_DEB" ] && [ -n "$LIBLZMA_DEB" ] && [ -n "$LIBSTDCXX_DEB" ]; then
    echo "  [deps] using embedded zstd deb: $(basename "$ZSTD_DEB")"
    dpkg -i "$LIBGCC_DEB" "$LIBLZ4_DEB" "$LIBLZMA_DEB" "$LIBSTDCXX_DEB" "$ZLIB_DEB" "$ZSTD_DEB"
else
    apt-get install -y --no-install-recommends kmod initramfs-tools zstd
fi

INSTALLED_KERNELS=0

if [ -n "$KVER_NEXT" ]; then
    CIXBOOT_DEB=$(local_deb 'cixmini-boot_*.deb')
    USBRECOVERY_DEB=$(local_deb 'ncz-usb-recovery_*.deb')
    HEADERS_DEB=$(local_deb 'linux-headers-cixmini_*.deb')
    IMAGE_DEB=$(local_deb 'linux-image-cixmini_*.deb')
    echo "  [edge] apt-get install linux-image-cixmini"
    # r203: --force-overwrite. Edge kernel packages can transiently ship
    # the SAME versioned /boot files (e.g. a baked edge at 7.2.0-sky1-ncz+rN
    # and an incoming edge at 7.2.0-sky1-ncz+rN+1 both own
    # /boot/config-7.2.0-sky1-ncz), so dpkg aborts the unpack with a
    # cross-package overwrite error — which, under `set -e`, killed the
    # whole hook -> REQUIRED_PHASE_OK=0 -> 70-bootloader skipped -> empty ESP
    # -> r174 "not bootable" -> "late.sh failed". The package is first-party
    # and the colliding file is a benign kernel config/vmlinuz whose final
    # owner is correct once both versions settle, so force-overwrite is safe.
    if [ -n "$CIXBOOT_DEB" ] && [ -n "$USBRECOVERY_DEB" ] && \
       [ -n "$HEADERS_DEB" ] && [ -n "$IMAGE_DEB" ]; then
        echo "    installing embedded kernel debs with dpkg:"
        echo "      $(basename "$CIXBOOT_DEB")"
        echo "      $(basename "$USBRECOVERY_DEB")"
        echo "      $(basename "$HEADERS_DEB")"
        echo "      $(basename "$IMAGE_DEB")"
        dpkg -i --force-overwrite --force-depends \
            "$USBRECOVERY_DEB" "$CIXBOOT_DEB" "$HEADERS_DEB" "$IMAGE_DEB"
    else
        echo "    WARN: embedded kernel deb set incomplete — falling back to apt package name"
        apt-get install -y --no-install-recommends \
            -o Dpkg::Options::=--force-overwrite linux-image-cixmini
    fi
    edge_ok=1
    if [ ! -s "/boot/vmlinuz-$KVER_NEXT" ]; then
        echo "WARN: linux-image-cixmini installed, but /boot/vmlinuz-$KVER_NEXT is missing"
        echo "      (KVER_NEXT sidecar / Buildkite package drift). /boot contents:"; ls -la /boot 2>&1
        edge_ok=0
    else
        modcount=$(find "/usr/lib/modules/$KVER_NEXT" \( -name '*.ko' -o -name '*.ko.xz' \) 2>/dev/null | wc -l)
        [ "$modcount" -lt 50 ] && { echo "WARN: [edge] modules dir suspiciously small (.ko=$modcount) — edge unusable"; edge_ok=0; }
    fi
    if [ "$edge_ok" = 1 ]; then
        echo "    OK: /boot/vmlinuz-$KVER_NEXT + $modcount .ko modules"
        INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
    else
        # r201: EDGE is the only kernel. A drifted/broken edge package
        # must NOT abort Phase 1 (that would skip the bootloader + ALL
        # Phase-2 software and leave an unbootable install). Drop the
        # KVER_NEXT sidecar so 70-bootloader makes no entry pointing at a
        # missing kernel and the post-install fails the kernel guard below.
        echo "WARN: edge kernel unavailable — Phase 1 cannot continue."
        rm -f "$INSTALLER_META/KVER_NEXT" /etc/cix-installer/KVER_NEXT 2>/dev/null || true
        KVER_NEXT=""
    fi
else
    echo "  [edge] not present in ISO — skipping"
fi

# r201: Phase-1 kernel guard — the install needs AT LEAST ONE working kernel.
# The edge kernel above may have failed (so a single drifted package
# never bricks the whole install), but zero installed kernels IS fatal:
# there is nothing to boot, and letting the bootloader write entries for a
# kernel-less system would produce an unbootable install that looks
# successful.
if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "ERROR: no kernel installed (edge failed) — Phase 1 cannot continue."
    exit 1
fi
echo "[10] kernel phase OK — edge='${KVER_NEXT:-none}'"

# r196c: prune orphaned /usr/lib/modules/<ver> trees that don't match
# the kernel this hook actually installed. Confirmed 2026-07-18 on O6N:
# a stale 6.6.10-cix-build-generic/ tree (pre-dates this apt-managed-kernel
# rewrite, never dpkg-tracked, never cleaned across base-image rebuilds)
# shipped rtl_btusb.ko built against that old kernel. It can never load
# against KVER_NEXT (vermagic mismatch) and was never going to be needed
# anyway -- btusb+btrtl already cover Bluetooth for the real kernel --
# but kmod still tries it on every boot and logs the mismatch, which
# reads as a broken driver rather than harmless dead weight. Only
# KVER_NEXT is ever legitimate on this image (see comment at top of
# file); anything else under /usr/lib/modules is leftover cruft.
echo "[10] pruning orphaned /usr/lib/modules/* trees (not KVER_NEXT)"
for moddir in /usr/lib/modules/*/; do
    kver="$(basename "$moddir")"
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
# noise buries real initramfs errors. Only KVER_NEXT is ever legitimate on
# this image.
#
# Fail-safe: this prune's correctness depends on at least one expected KVER
# being non-empty. That is already guaranteed by the INSTALLED_KERNELS==0 guard
# further up (which exits 1), but a deletion loop must not rely on a check 35
# lines away — if KVER_NEXT were ever empty, NOTHING would match and this would
# remove every kernel payload under /boot, including the one about to boot.
# Make the invariant local and explicit.
if [ -z "$KVER_NEXT" ]; then
    echo "[10] WARN: KVER_NEXT is empty — SKIPPING the /boot prune" >&2
    echo "[10]       (refusing to delete kernel payloads with nothing to compare against)" >&2
else
    echo "[10] pruning orphaned /boot kernel payloads (not KVER_NEXT)"
    for vmlinuz in /boot/vmlinuz-*; do
        [ -e "$vmlinuz" ] || continue
        kver="${vmlinuz#/boot/vmlinuz-}"
        [ "$kver" = "$KVER_NEXT" ] && continue
        echo "    removing orphaned boot payload: $kver"
        rm -f "/boot/vmlinuz-$kver" "/boot/initrd.img-$kver" \
              "/boot/System.map-$kver" "/boot/config-$kver"
    done
fi

[ -n "$KVER_NEXT" ] && depmod -a "$KVER_NEXT" 2>/dev/null || true

if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "[10] ERROR: no kernel packages were installed"
    exit 1
fi

# Headers for DKMS (NPU/GPU/panthor drivers). There is still no
# linux-headers-cixmini package on Buildkite, so the headers ship as a
# tarball produced by build/extract-kernel-headers.sh:
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
# kernel whose build tree is missing. Confirmed on O6N: WARN for
# 7.2.0-sky1-ncz.
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
        rebuild_host_tools "$kver"
        return 0
    fi
    echo "    WARN: failed to unpack $tarball" >&2
    return 1
}

# The kernel build tree ships SOURCES for its host tools, not binaries, because
# a Yocto build links them against its uninative sysroot:
#   interpreter: /ybuild/tmp/sysroots-uninative/aarch64-linux/lib/ld-linux-aarch64.so.1
# That path exists only inside the build container. On a target the binary is
# present, executable and the right architecture, yet every exec fails with
#   /bin/sh: 1: .../scripts/basic/fixdep: not found
# because the LOADER is missing -- and DKMS reports it as "Error 127" on the
# first object file, which looks exactly like a source incompatibility and is
# not one. Measured on O6N 2026-08-17 against 7.2 final: all six accelerator
# modules failed this way, and all six built after the tools were rebuilt here.
#
# modules_prepare is the canonical target that produces scripts/basic/fixdep
# and scripts/mod/modpost. It may still exit non-zero afterwards on a generated
# file this trimmed tree does not carry; that is tolerated, because the two
# tools DKMS needs are produced before that point. What matters is whether they
# exist and run, which is what we check.
rebuild_host_tools() {
    local kver="$1" b="/lib/modules/$1/build"
    [ -f "$b/Makefile" ] || return 0
    command -v make >/dev/null 2>&1 || {
        echo "    WARN: make absent — cannot rebuild kernel host tools; DKMS will fail" >&2; return 1; }
    make -C "$b" modules_prepare >/dev/null 2>&1 || true
    local ok=1
    for t in scripts/basic/fixdep scripts/mod/modpost; do
        if [ -x "$b/$t" ] && ! "$b/$t" 2>&1 | grep -q "not found"; then :; else ok=0; fi
    done
    if [ "$ok" = 1 ]; then
        echo "    host tools rebuilt for $kver (fixdep + modpost run natively — DKMS can build)"
    else
        echo "    WARN: kernel host tools for $kver are not runnable; DKMS builds will fail with Error 127" >&2
    fi
}

install_kernel_headers "$KVER_NEXT" edge   || true

for kver in "$KVER_NEXT"; do
    [ -z "$kver" ] && continue
    if [ -f "/lib/modules/$kver/build/Makefile" ]; then
        echo "    headers OK for $kver (/lib/modules/$kver/build present — DKMS can rebuild)"
    else
        echo "    WARN: no kernel headers for $kver (/lib/modules/$kver/build/Makefile absent)" \
             "— DKMS rebuild blocked on target." >&2
        echo "          Remediation: build/extract-kernel-headers.sh --kernel-src <tree> --kver $kver" \
             "--output assets/kernel/edge/headers-cixmini.tar.zst, then rebuild the ISO." >&2
    fi
done

# Remove Debian's default linux-image-arm64 — we ship our own.
apt-get remove -y --purge "linux-image-arm64" || true
apt-get autoremove -y --purge || true

echo ""
echo "Kernel summary:"
[ -n "$KVER_NEXT" ] && ls -lh "/boot/vmlinuz-$KVER_NEXT" 2>/dev/null || true
echo ""
echo "Module trees:"
[ -n "$KVER_NEXT" ] && [ -d "/lib/modules/$KVER_NEXT" ] && \
    { echo "  --- edge ---"; ls "/lib/modules/$KVER_NEXT" | head -5; } || true
