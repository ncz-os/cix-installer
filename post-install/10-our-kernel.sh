#!/bin/bash
# 10-our-kernel.sh — install the single unified 7.3 kernel via apt (dpkg-tracked).
#
# 26.6-r193: rewritten. Previously this hook raw-copied the kernel
# (install -D + tar xzf) straight from medium assets into /boot and
# /usr/lib/modules -- completely bypassing dpkg. Result: apt/dpkg had
# ZERO record any kernel package was installed (`apt-cache policy
# linux-image-cixmini` showed "Installed: (none)" even on a running
# system using that exact kernel), so `apt upgrade` could never pull a
# new kernel -- there was nothing dpkg thought needed upgrading. This
# directly broke the documented "apt upgrade pulls new kernels, no
# reinstall" OTA story (confirmed live on the MS-R1 test board, 2026-07-06).
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
# 2026-08-21: the legacy kernel channel was retired; since 2026-10-05 one
# unified 7.3 kernel ships and the KVER_NEXT sidecar is the only one read here.
#
# Bootloader wiring for the newly-installed kernel (refind.conf) happens
# via post-install/70-bootloader.sh later in this same run (install time)
# and via /etc/kernel/postinst.d/zz1-ncz-refind-refresh (any future
# apt-driven kernel install/upgrade) -- see that hook + assets/refind/
# ncz-refind-refresh.sh for why raw-copying broke that path too.
# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set -euo pipefail
# Install feedback (lib/progress-msg.sh): one honest status line while this runs.
_pm="$(dirname "$0")/lib/progress-msg.sh"; [ -r "$_pm" ] || _pm=/usr/local/lib/cix-installer/post-install/lib/progress-msg.sh
[ -r "$_pm" ] && . "$_pm"
command -v ncz_msg >/dev/null 2>&1 && ncz_msg "Kernel: installing the NCZ kernel and building its modules (a few minutes; log: /var/log/cix-install/10-our-kernel.log)"

INSTALLER_META=/usr/local/lib/cix-installer
HERE="$(dirname "$0")"

# Debian-kernel blocking policy (since 2026-10-04). The apt
# preferences pin MUST be installed before ANY apt operation -- including the
# 24-apt-sources.sh call below, which runs `apt-get update` while the Debian
# base repo is live. The `apt-get remove --purge` at the bottom stays as
# belt-and-braces; this pin is the actual guarantee against apt re-pulling it.
# shellcheck source=lib/kernel-purity.sh
. "$HERE/lib/kernel-purity.sh"
ncz_write_kernel_purity_pin

# 2026-09-15: this hook had NO arch guard, the same bug class already
# found and fixed on 10-amd64-kernel.sh's side (see that hook's own
# header for the ARM64 mirror image of this incident). Being REQUIRED and
# run-all.sh's MACHINE_HOOKS_RE having no arch axis (filenames only), this
# ran unconditionally on AMD64 too -- and genuinely tried
# `apt-get install linux-image-cixmini` (the Sky1 arm64 kernel package)
# on an amd64 target. That's a required-hook failure, which run-all.sh's
# EXIT trap correctly treats as fatal-enough to skip 70-bootloader.sh
# entirely (never wipe the ESP after a failed required step) -- so the
# install silently shipped with a completely empty ESP and no bootloader,
# surfacing only as "sh /cdrom/ncz-payload/late.sh failed" at the very end.
# Same detection pattern as 10-amd64-kernel.sh/21-flatpak-arch-filter.sh/
# 52-vivaldi.sh: env var first, then the late.sh-stamped BUILD_ARCH file,
# then dpkg as a last-resort fallback.
NCZ_SYSTEM_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_SYSTEM_ARCH" ] && [ -r "$INSTALLER_META/BUILD_ARCH" ]; then
    NCZ_SYSTEM_ARCH=$(tr -d '[:space:]' < "$INSTALLER_META/BUILD_ARCH")
fi
NCZ_SYSTEM_ARCH="${NCZ_SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
if [ "$NCZ_SYSTEM_ARCH" != "arm64" ]; then
    echo "[10-our-kernel] NCZ_SYSTEM_ARCH=$NCZ_SYSTEM_ARCH -- not arm64, skipping (AMD64 uses 10-amd64-kernel.sh)"
    exit 0
fi

KVER_NEXT=""
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
fi

if [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_NEXT sidecar present (the mainline kernel is the only shipping channel)"
    exit 1
fi

# KVER_NEXT is the historical sidecar name; under the unified 7.3 policy it
# carries the one shipping kernel KVER, packaged as linux-image-cixmini. The
# retired KVER_EDGE sidecar (a second experimental kernel line) is gone.

echo "[10] installing kernel via apt — default=$KVER_NEXT"

local_deb() {
    pattern="$1"
    # Guard the directory existence check OUTSIDE the pipeline. Under
    # `set -euo pipefail` (active in this script), `find` on a missing
    # /cdrom/pool/main (the normal case at squashfs-layer BUILD time --
    # /cdrom only exists when running from the install medium) exits
    # non-zero; pipefail then makes the whole `find | sort -V | tail -1`
    # pipeline non-zero, which `set -e` treats as a fatal error on the
    # `VAR=$(local_deb ...)` assignment -- silently killing the hook with
    # no error message (the real find error was swallowed by 2>/dev/null).
    # Every caller already treats an empty result as "no local deb, fall
    # back to apt" -- that was always the intent; this makes the function
    # actually honor it instead of aborting the script. Discovered
    # 2026-09-13 rebuilding base.squashfs for the r271 kernel channel: the
    # hook had silently never been able to complete since /cdrom stopped
    # existing at build time, for any commit after this pattern landed.
    [ -d /cdrom/pool/main ] || return 0
    find /cdrom/pool/main -maxdepth 1 -type f -name "$pattern" 2>/dev/null | sort -V | tail -1
}

# Wire the Buildkite apt source + refresh the index. Idempotent (safe to
# call again later at its normal position). Needed now because the
# linux-image-cixmini package lives only on Buildkite, not the Debian
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
    # Pinned to KVER_NEXT (the mainline sidecar), never "newest in the pool":
    # local_deb() takes the sort -V maximum, so a leftover 7.3.0-rc5 deb in
    # the pool would otherwise beat 7.2.8 (2026-09-28 vendor-mirror incident).
    HEADERS_DEB=$(local_deb "linux-headers-cixmini_${KVER_NEXT}+*.deb")
    IMAGE_DEB=$(local_deb "linux-image-cixmini_${KVER_NEXT}+*.deb")
    echo "  [kernel] apt-get install linux-image-cixmini"
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
        echo "    WARN: embedded kernel deb set incomplete — falling back to apt, pinned to $KVER_NEXT"
        # Pinned like the embedded path: a bare package name would take the
        # newest linux-image-cixmini any configured source offers, which is
        # how a test rc kernel reaches a shipping install.
        _pin_ver=$(apt-cache madison linux-image-cixmini 2>/dev/null \
            | awk -F'|' '{gsub(/ /, "", $2); print $2}' \
            | grep -F -- "${KVER_NEXT}+r" | sort -V | tail -1 || true)
        if [ -n "$_pin_ver" ]; then
            apt-get install -y --no-install-recommends \
                -o Dpkg::Options::=--force-overwrite "linux-image-cixmini=$_pin_ver"
        else
            echo "    WARN: no linux-image-cixmini ${KVER_NEXT}+r* in any apt source — not installing an unpinned kernel"
        fi
    fi
    edge_ok=1
    if [ ! -s "/boot/vmlinuz-$KVER_NEXT" ]; then
        echo "WARN: linux-image-cixmini installed, but /boot/vmlinuz-$KVER_NEXT is missing"
        echo "      (KVER_NEXT sidecar / Buildkite package drift). /boot contents:"; ls -la /boot 2>&1
        edge_ok=0
    else
        modcount=$(find "/usr/lib/modules/$KVER_NEXT" \( -name '*.ko' -o -name '*.ko.xz' \) 2>/dev/null | wc -l)
        [ "$modcount" -lt 50 ] && { echo "WARN: [kernel] modules dir suspiciously small (.ko=$modcount) — kernel unusable"; edge_ok=0; }
    fi
    if [ "$edge_ok" = 1 ]; then
        echo "    OK: /boot/vmlinuz-$KVER_NEXT + $modcount .ko modules"
        INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
    else
        # r201: this is the only kernel. A drifted/broken kernel package
        # must NOT abort Phase 1 (that would skip the bootloader + ALL
        # Phase-2 software and leave an unbootable install). Drop the
        # KVER_NEXT sidecar so 70-bootloader makes no entry pointing at a
        # missing kernel and the post-install fails the kernel guard below.
        echo "WARN: kernel unavailable — Phase 1 cannot continue."
        rm -f "$INSTALLER_META/KVER_NEXT" /etc/cix-installer/KVER_NEXT 2>/dev/null || true
        KVER_NEXT=""
    fi
else
    echo "  [kernel] not present on the medium — skipping"
fi

# r201: Phase-1 kernel guard — the install needs AT LEAST ONE working kernel.
# The kernel above may have failed (so a single drifted package
# never bricks the whole install), but zero installed kernels IS fatal:
# there is nothing to boot, and letting the bootloader write entries for a
# kernel-less system would produce an unbootable install that looks
# successful.
if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "ERROR: no kernel installed (kernel install failed) — Phase 1 cannot continue."
    exit 1
fi
echo "[10] kernel phase OK — kernel='${KVER_NEXT:-none}'"

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
#   assets/kernel/mainline/headers-cixmini.tar.zst -> KVER_NEXT (the one 7.3 kernel)
# Each unpacks to lib/modules/$KVER/build/ (Makefile, scripts/, include/,
# arch/arm64/include/, .config, Module.symvers), which is exactly what DKMS
# needs. This is the same tar-into-/usr pattern the module tarball already
# uses.
#
# 2026-08-02: this consumption step did not exist. extract-kernel-headers.sh
# was written for r75 task #66 and then never wired to a caller, so every
# install shipped with /lib/modules/$KVER/build absent and the hook only
# warned. That is a real contradiction of the all-DKMS driver rule -- CIX
# drivers are DKMS by design, and DKMS cannot rebuild any of them against a
# kernel whose build tree is missing. Confirmed on O6N: WARN for
# 7.2.0-sky1-ncz.
install_kernel_headers() {
    local kver="$1" channel="$2" tarball="" d
    [ -z "$kver" ] && return 0
    [ -f "/lib/modules/$kver/build/Makefile" ] && return 0
    for d in "$INSTALLER_META/assets/kernel/$channel" "/cdrom/ncz-payload/assets/kernel/$channel"; do
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
# >>> ncz_prepare_pristine (keep identical in build/build-kernel-debs.sh,
# post-install/79-dkms-prep.sh and post-install/10-our-kernel.sh;
# build/test-headers-prepare-pristine.sh checks that they match)
#
# Rebuild the kernel host tools (fixdep, modpost, genksyms) with
# `make modules_prepare` WITHOUT letting it change the kernel configuration the
# header tree describes. modules_prepare re-runs Kconfig (syncconfig) whenever
# the compiler differs from the one that built the kernel, which on these
# trees is always (OE gcc built the kernel, Debian gcc builds DKMS). Kconfig
# then re-derives every toolchain-dependent symbol for the NEW compiler and
# rewrites .config, include/config/auto.conf and include/generated/autoconf.h.
# Every DKMS module is compiled against that autoconf.h, so a dropped symbol
# changes the module ABI. 2026-10-26 (r292): on a host without pahole,
# CONFIG_PAHOLE_VERSION became 0, CONFIG_DEBUG_INFO_BTF_MODULES disappeared,
# struct module shrank from 0x500 to 0x4c0, and the kernel refused the Mali
# modules built there ("section size must match"). On O6N the same step also
# dropped CONFIG_GCC_PLUGINS and prompted for new symbols on the terminal.
# So: snapshot the Kconfig output, run modules_prepare with stdin closed (a new
# symbol takes its default instead of waiting for an answer on a terminal
# during an apt run), put the snapshot back, and verify it is byte-identical.
#
# tools/bpf/resolve_btfids fails to build here ("linux/kasan-checks.h: No such
# file or directory": the header tree carries no tools/ sources). DKMS does not
# need it: it is only used to add BTF to a module when vmlinux is present, and
# the header tree has no vmlinux, so kbuild prints "Skipping BTF generation"
# and the module loads without BTF. That failure, like the missing
# kernel/bounds.s and asm-offsets sources, is why make runs with -k.
#
# A listed file that make creates (the shipped tree has no
# include/config/auto.conf.cmd) is removed again, so the tree ends as shipped.
#
# Safe under set -e whether or not the caller tests its status.
#
# ncz_prepare_pristine <build-dir> <log>
#   returns 0 when make was clean, make's status when it was not (expected for
#   this trimmed tree; check the tools instead), 3 when the configuration could
#   not be restored (do NOT build modules against that tree).
NCZ_KCONFIG_FILES=".config include/config/auto.conf include/config/auto.conf.cmd include/generated/autoconf.h include/generated/rustc_cfg include/config/kernel.release include/generated/utsrelease.h"
ncz_prepare_pristine() {
    _np_b=$1; _np_log=$2
    _np_snap=$(mktemp -d) || return 3
    for _np_f in $NCZ_KCONFIG_FILES; do
        [ -f "$_np_b/$_np_f" ] || continue
        mkdir -p "$_np_snap/$(dirname "$_np_f")" && cp -p "$_np_b/$_np_f" "$_np_snap/$_np_f" \
            || { rm -rf "$_np_snap"; return 3; }
    done
    _np_off=$(($({ wc -c <"$_np_log"; } 2>/dev/null || echo 0) + 1))
    _np_rc=0
    make -k -C "$_np_b" -j"$(nproc 2>/dev/null || echo 2)" modules_prepare </dev/null >>"$_np_log" 2>&1 || _np_rc=$?
    _np_bad=0
    for _np_f in $NCZ_KCONFIG_FILES; do
        if [ ! -f "$_np_snap/$_np_f" ]; then
            [ -e "$_np_b/$_np_f" ] || continue
            echo "ncz_prepare_pristine: Kconfig created $_np_f; removed it (the kernel's tree has none)" >>"$_np_log"
            rm -rf "${_np_b:?}/$_np_f" 2>>"$_np_log"
            if [ -e "$_np_b/$_np_f" ]; then _np_bad=1; fi
            continue
        fi
        if cmp -s "$_np_snap/$_np_f" "$_np_b/$_np_f" 2>/dev/null; then continue; fi
        echo "ncz_prepare_pristine: Kconfig rewrote $_np_f; restored the kernel's copy" >>"$_np_log"
        # a path make turned into a directory: remove it so the copy can land
        if [ -d "$_np_b/$_np_f" ]; then rm -rf "${_np_b:?}/$_np_f"; fi
        cp -p "$_np_snap/$_np_f" "$_np_b/$_np_f" 2>>"$_np_log" || _np_bad=1
        cmp -s "$_np_snap/$_np_f" "$_np_b/$_np_f" 2>/dev/null || _np_bad=1
    done
    rm -rf "$_np_snap"
    if tail -c +"$_np_off" "$_np_log" 2>/dev/null | grep -q 'resolve_btfids'; then
        echo "ncz_prepare_pristine: tools/bpf/resolve_btfids not built (no tools/ sources in the header tree); not needed for DKMS: without vmlinux kbuild skips module BTF" >>"$_np_log"
    fi
    [ "$_np_bad" = 0 ] || return 3
    return "$_np_rc"
}
# <<< ncz_prepare_pristine

rebuild_host_tools() {
    local kver="$1" b="/lib/modules/$1/build" prep_rc=0
    [ -f "$b/Makefile" ] || return 0
    command -v make >/dev/null 2>&1 || {
        echo "    WARN: make absent — cannot rebuild kernel host tools; DKMS will fail" >&2; return 1; }
    ncz_prepare_pristine "$b" /var/log/ncz-kernel-host-tools.log || prep_rc=$?
    if [ "$prep_rc" = 3 ]; then
        echo "    WARN: modules_prepare changed the kernel configuration in $b and it could not be restored;" \
             "DKMS modules built against it would not load (see /var/log/ncz-kernel-host-tools.log)" >&2
        return 1
    elif [ "$prep_rc" != 0 ]; then
        echo "    modules_prepare returned $prep_rc (expected: the headers omit some generated sources);" \
             "see /var/log/ncz-kernel-host-tools.log"
    fi
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

install_kernel_headers "$KVER_NEXT" mainline || true

# Unified 7.3 policy (2026-10-05): only the 7.3 series may ship.
# A 7.2.x sidecar is refused here so the install fails closed rather than
# silently booting a retired kernel. (The build-time verifier is the primary
# gate; this is defence in depth on the target.)
case "$KVER_NEXT" in
    7.3.*|7.3-*) ;;
    *)
        echo "ERROR: KVER_NEXT='$KVER_NEXT' is not the unified 7.3 series (policy 2026-10-05)." >&2
        echo "       Refusing to install a retired kernel." >&2
        exit 1 ;;
esac

for kver in $KVER_NEXT; do
    [ -z "$kver" ] && continue
    if [ -f "/lib/modules/$kver/build/Makefile" ]; then
        echo "    headers OK for $kver (/lib/modules/$kver/build present — DKMS can rebuild)"
    else
        echo "    WARN: no kernel headers for $kver (/lib/modules/$kver/build/Makefile absent)" \
             "— DKMS rebuild blocked on target." >&2
        echo "          Remediation: build/extract-kernel-headers.sh --kernel-src <tree> --kver $kver" \
             "--output assets/kernel/mainline/headers-cixmini.tar.zst, then rebuild the image." >&2
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
    { echo "  --- $KVER_NEXT ---"; ls "/lib/modules/$KVER_NEXT" | head -5; } || true
