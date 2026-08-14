#!/bin/bash
# build-kernel-debs.sh — debianize the staged cixmini kernels for APT/OTA.
#
# Produces three .debs under build/kernel-debs/:
#   cixmini-boot_<ver>_arm64.deb           — OTA-safe systemd-boot entry hook
#   linux-image-cixmini-legacy_<KVER>_arm64.deb
#   linux-image-cixmini-edge_<KVER>_arm64.deb
#   linux-image-cixmini-lts_<KVER>_arm64.deb   (empty transitional package)
#
# These are the OTA-upgradable form of post-install/10-our-kernel.sh +
# build/70-bootloader.sh. The bootloader hook is initrd-less and never wipes
# the ESP — it only adds/updates entries for currently-installed kernels,
# matching the validated r97/r98 boot exactly.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"   # cix-installer/
ASSETS="$REPO/assets/kernel"
NPU="$REPO/assets/npu"
OUT="$REPO/build/kernel-debs"
# Default revision must never be older than what is already published, or the
# "new" kernel is a DOWNGRADE and apt silently keeps the installed one. r211 is
# the published rc7 build (2026-08-11); bump this when the kernel is rebuilt.
BUILD_REV="${BUILD_REV:-r212}"

# cixmini-boot package version. BUMP THIS whenever the bootloader helper or the
# shipped rEFInd generator (assets/refind/ncz-refind-refresh.sh) changes: apt only
# unpacks cixmini-boot if its version is newer, and the kernel packages can upgrade
# independently. Without a bump an installed board keeps running the STALE
# /usr/local/sbin/ncz-refind-refresh, which rewrites refind.conf with the old
# hard-coded efi=noruntime and re-breaks the O6/O6N RTC on every kernel refresh.
# 1.1: board-gated efi=noruntime + generator shipped through the OTA path.
CIXMINI_BOOT_VER="1.1+$BUILD_REV"
MAINT="NCZ <nczero@nclawzero.dev>"

# KVER comes from the ASSET WE ARE ABOUT TO PACKAGE, not from a previous
# ISO staging run. build/iso-staging-di/ is a build OUTPUT dir: after a
# kernel bump it still holds the PREVIOUS KVER until an ISO is rebuilt, so
# preferring it made this script package the new Image under the old
# version string. Confirmed 2026-08-02 on the rc5 -> rc6 bump: it announced
# "[edge] 7.2.0-rc5-sky1-ncz" against an rc6 Image and then died with a bare
# "install: No such file or directory" when the rc5 config was gone.
# assets/kernel/<ch>/KVER is written by the kernel build itself and is the
# only source of truth here; the staging sidecar stays as a fallback.
# Falling back to the staging sidecar is still allowed (a caller may package
# from a tree with no built kernel assets), but it must never be SILENT --
# a silent fallback re-creates exactly the stale-KVER mismatch this block
# exists to prevent. Say which source won.
resolve_kver() {   # <channel-dir> <sidecar-name> <default>
    local asset="$REPO/assets/kernel/$1/KVER"
    local sidecar="$REPO/build/iso-staging-di/cixmini/$2"
    local v
    if [ -s "$asset" ]; then
        v=$(tr -d " \t\r\n" < "$asset")
        [ -n "$v" ] && { printf %s "$v"; return 0; }
    fi
    if [ -s "$sidecar" ]; then
        v=$(tr -d " \t\r\n" < "$sidecar")
        if [ -n "$v" ]; then
            echo "WARN: $asset absent/empty -- falling back to the ISO-staging sidecar" >&2
            echo "      $sidecar = $v" >&2
            echo "      That directory is a build OUTPUT and can hold a PREVIOUS KVER." >&2
            echo "      Build the kernel assets, or pass KVER_$3 explicitly, to be sure." >&2
            printf %s "$v"; return 0
        fi
    fi
    echo "WARN: no KVER for channel '$1' (neither $asset nor $sidecar) -- using default" >&2
    printf %s "$4"
}
KVER_LEGACY="${KVER_LEGACY:-$(resolve_kver legacy KVER_LEGACY LEGACY 7.0.12-cix-sky1-next)}"
KVER_NEXT="${KVER_NEXT:-$(resolve_kver edge KVER_NEXT NEXT 7.0.12-cix-sky1-next)}"
KVER_LEGACY=$(printf %s "$KVER_LEGACY" | tr -d " \t\r\n")
KVER_NEXT=$(printf %s "$KVER_NEXT" | tr -d " \t\r\n")

echo "== build-kernel-debs =="
echo "   LTS=$KVER_LEGACY  NEXT=$KVER_NEXT  rev=$BUILD_REV"
echo "   out=$OUT"

# Drift guard: verify the kernel/NPU manifest invariants before packaging the
# kernels. Catches e.g. an NPU module whose vermagic != the kernel KVER (the
# armchina_npu.ko is vermagic-locked). Non-fatal by default because the edge/next
# kernel may legitimately be ahead of its NPU rebuild; set STRICT_MANIFEST=1 to
# make any drift abort the build (recommended for release/CI).
if [ -f "$REPO/build/kernel-manifest.py" ]; then
    if ! python3 "$REPO/build/kernel-manifest.py" check; then
        if [ "${STRICT_MANIFEST:-0}" = 1 ]; then
            echo "ERROR: kernel manifest drift (STRICT_MANIFEST=1) — aborting" >&2
            exit 1
        fi
        echo "WARN: kernel manifest drift detected (continuing; set STRICT_MANIFEST=1 to enforce)" >&2
    fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------
# Shared: the OTA-safe bootloader helper (ported from 70-bootloader.sh).
# ----------------------------------------------------------------------
write_bootloader_helper() {
    local dst="$1"
    install -d "$(dirname "$dst")"
    cat > "$dst" <<'HELPER'
#!/bin/bash
# cixmini-update-bootloader — OTA-safe systemd-boot entry generator.
# Faithful to the installer's build/70-bootloader.sh, but:
#   1. NEVER wipes the ESP (no destructive clear of loader/entries).
#   2. Only adds/updates entries for currently-installed cixmini kernels.
#   3. initrd-less, exactly like the validated r97/r98 boot (Sky1 kernel
#      has ext4/nvme/smmu built-in and roots directly via root=PARTUUID).
set -uo pipefail

ESP=/boot/efi
[ -d "$ESP" ] || { echo "cixmini-boot: no ESP at $ESP; skipping"; exit 0; }
command -v bootctl >/dev/null 2>&1 || { echo "cixmini-boot: bootctl missing; skipping"; exit 0; }
if ! findmnt -no FSTYPE "$ESP" 2>/dev/null | grep -qi vfat; then
    echo "cixmini-boot: $ESP not a vfat ESP; skipping"; exit 0
fi

# Idempotent: install systemd-boot only if not already present on the ESP.
bootctl is-installed >/dev/null 2>&1 || \
    bootctl install --esp-path="$ESP" --no-variables >/dev/null 2>&1 || true
mkdir -p "$ESP/loader/entries"

ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC" 2>/dev/null)
[ -n "$ROOT_PARTUUID" ] || { echo "cixmini-boot: cannot determine root PARTUUID; aborting"; exit 0; }

# MartJohnson 2026-04-30 working set for MS-R1 (identical LTS+NEXT), kept in
# lockstep with build/70-bootloader.sh.
# ----------------------------------------------------------------------
# efi=noruntime is an MS-R1 firmware workaround, NOT a Sky1-wide one.
#
# Gate it on the actual board. MS-R1's EFI runtime services are buggy, but
# every other Sky1 target (Radxa Orion O6/O6N, Orange Pi 6 / 6 Plus) needs
# EFI runtime ENABLED or it boots with no RTC at all: those boards' RTCs are
# firmware-owned and reachable only through UEFI GetTime/SetTime. On O6N the
# clock sits behind ACPI Device (ERTC), _HID "ERTC0000", _STA = Zero (so Linux
# never enumerates it), bit-banging a Cadence I2C at 0x04040000 that is not
# among the buses exposed to Linux. CONFIG_RTC_DRV_EFI=y is built in, but
# drivers/firmware/efi/efi.c registers the "rtc-efi" platform device only when
# efi_rt_services_supported(EFI_RT_SUPPORTED_TIME_SERVICES) is true -- which
# efi=noruntime makes false. Metal-verified on O6N under BOTH 7.2.0-rc6 and
# 7.0.12: /dev/rtc0 appears, driver rtc-efi, hctosys=1, clean boot.
#
# Gate on the board, not the kernel channel: every Sky1 board runs both 7.2
# and 7.0.12, so a per-channel split is wrong in both directions.
#
# Fail-safe: if DMI is unreadable we cannot prove we are NOT on an MS-R1, so
# emit the workaround and favour a bootable system over a working clock.
# ----------------------------------------------------------------------
# NOTE: duplicated verbatim in assets/refind/ncz-refind-refresh.sh,
# build/70-bootloader.sh and build/build-kernel-debs.sh. KEEP ALL THREE IN SYNC.
#
# Why not a sourced library: all three copies execute ON THE TARGET, detached from
# this repo -- ncz-refind-refresh is installed standalone to /usr/local/sbin, and the
# build-kernel-debs.sh copy is emitted inside a quoted heredoc into the standalone
# /usr/lib/cixmini/cixmini-update-bootloader. A shared library would therefore need
# its own packaging and delivery path, and a stale-or-missing copy of THAT is exactly
# the failure mode that already bit us once with the rEFInd generator. Self-contained
# duplication trades DRY for a delivery path that cannot silently go stale.
ncz_efi_rt_workaround() {
    local pn vendor
    pn=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    if [ -z "$pn" ] && [ -z "$vendor" ]; then
        # No DMI: a chroot or build context with /sys unmounted. We cannot prove
        # we are not on an MS-R1, so fail safe -- but say so, because on an O6/O6N
        # this costs the RTC until the on-target run corrects it.
        echo "ncz_efi_rt_workaround: DMI unreadable (/sys not mounted?); assuming MS-R1" >&2
        echo "efi=noruntime"; return
    fi
    # Known-good boards first: these need EFI runtime for their RTC, and the
    # allow-list must win over the vendor fallback below so an odd/shared
    # vendor string can never take the RTC away from them.
    case "$pn" in
        *"Orion O6"*|*"Orange Pi 6"*|*"OrangePi 6"*) echo ""; return ;;
    esac
    case "$vendor" in
        *Radxa*|*Xunlong*|*"Shenzhen Xunlong"*) echo ""; return ;;
    esac
    case "$pn" in
        MS-R1*) echo "efi=noruntime"; return ;;
    esac
    case "$vendor" in
        *"Micro Computer (HK)"*) echo "efi=noruntime"; return ;;
    esac
    echo ""
}
EFI_RT_WORKAROUND="$(ncz_efi_rt_workaround)"

CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 $EFI_RT_WORKAROUND acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453 video=DP-4:1920x1080@60e"
ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"
SPLASH=""; [ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)
VER="ncz-ota"; [ -f /usr/local/lib/cix-installer/BUILD_VERSION ] && VER=$(cat /usr/local/lib/cix-installer/BUILD_VERSION)

# Discover installed cixmini kernels (must have BOTH a module tree and a vmlinuz).
LTS=""; NEXT=""
for k in $(ls /usr/lib/modules 2>/dev/null); do
    [ -f "/boot/vmlinuz-$k" ] || continue
    case "$k" in
        *-ncz-lts)       LTS="$k" ;;
        *-cix-sky1-next) NEXT="$k" ;;
    esac
done

write_entry() {
    local name="$1" sk="$2" title="$3" k="$4" extra="$5"
    local opts="$ROOT_OPTS $CMDLINE"
    [ -n "$SPLASH" ] && opts="$opts $SPLASH"
    [ -n "$extra" ] && opts="$opts $extra"
    cat > "$ESP/loader/entries/$name.conf" <<EOF
title   $title
sort-key $sk
version $k
linux   /vmlinuz-$k
options $opts
EOF
}

# LTS channel
if [ -n "$LTS" ]; then
    rm -f "$ESP"/vmlinuz-*-ncz-lts 2>/dev/null || true
    install -m 0644 "/boot/vmlinuz-$LTS" "$ESP/vmlinuz-$LTS"
    write_entry cixmini-legacy 1-legacy "nclawzero (cixmini) — kernel $LTS [legacy, default] — $VER" "$LTS" ""
    echo "cixmini-boot: staged LTS $LTS"
else
    rm -f "$ESP/loader/entries/cixmini-legacy.conf" "$ESP/loader/entries/cixmini-lts.conf" "$ESP"/vmlinuz-*-ncz-lts 2>/dev/null || true
fi

# NEXT/edge channel
if [ -n "$NEXT" ]; then
    rm -f "$ESP"/vmlinuz-*-cix-sky1-next 2>/dev/null || true
    install -m 0644 "/boot/vmlinuz-$NEXT" "$ESP/vmlinuz-$NEXT"
    write_entry cixmini-next 2-next "*** [BETA — UNSTABLE] nclawzero kernel $NEXT — $VER ***" "$NEXT" ""
    echo "cixmini-boot: staged NEXT $NEXT"
else
    rm -f "$ESP/loader/entries/cixmini-next.conf" "$ESP"/vmlinuz-*-cix-sky1-next 2>/dev/null || true
fi

# Rescue prefers LTS, falls back to NEXT.
RESCUE="${LTS:-$NEXT}"
if [ -n "$RESCUE" ]; then
    write_entry cixmini-rescue 3-rescue "SAFE rescue (cixmini) — kernel $RESCUE rescue.target — $VER" "$RESCUE" "systemd.unit=rescue.target"
else
    rm -f "$ESP/loader/entries/cixmini-rescue.conf"
fi

# Safety: never leave the ESP with a default pointing at nothing.
if [ -z "$LTS$NEXT" ]; then
    echo "cixmini-boot: no cixmini kernels installed; leaving loader.conf untouched"
    exit 0
fi
DEFAULT_ENTRY="cixmini-legacy"; [ -z "$LTS" ] && DEFAULT_ENTRY="cixmini-next"
cat > "$ESP/loader/loader.conf" <<EOF
default $DEFAULT_ENTRY
timeout 5
console-mode auto
editor yes
EOF
echo "cixmini-update-bootloader: LTS=${LTS:-none} NEXT=${NEXT:-none} default=$DEFAULT_ENTRY"
HELPER
    chmod 0755 "$dst"
}

# ----------------------------------------------------------------------
# Package 1: cixmini-boot
# ----------------------------------------------------------------------
build_cixmini_boot() {
    local root="$WORK/cixmini-boot"
    local ver="$CIXMINI_BOOT_VER"
    rm -rf "$root"
    install -d "$root/DEBIAN" "$root/usr/lib/cixmini" \
        "$root/etc/kernel/postinst.d" "$root/etc/kernel/postrm.d"

    write_bootloader_helper "$root/usr/lib/cixmini/cixmini-update-bootloader"

    # Ship the rEFInd generator through the OTA path too.
    # post-install/70-bootloader.sh installs assets/refind/ncz-refind-refresh.sh
    # to /usr/local/sbin/ncz-refind-refresh, but post-install only runs at
    # INSTALL time. On an already-installed system the wrapper that apt invokes
    # calls that persistent path, so without shipping it here an apt kernel
    # upgrade would rerun the STALE generator and rewrite refind.conf with the
    # old hard-coded efi=noruntime -- silently re-breaking the O6/O6N RTC that
    # this package's own cmdline gating just fixed.
    # Staged under /usr/lib (dpkg must not own /usr/local); postinst syncs it
    # into place.
    if [ -f "$REPO/assets/refind/ncz-refind-refresh.sh" ]; then
        install -m 0755 "$REPO/assets/refind/ncz-refind-refresh.sh" \
            "$root/usr/lib/cixmini/ncz-refind-refresh"
    else
        echo "build-kernel-debs: WARNING: assets/refind/ncz-refind-refresh.sh missing;" \
             "cixmini-boot will not refresh the installed rEFInd generator" >&2
    fi

    # Standard kernel hooks so any future linux-image-* install triggers us too.
    cat > "$root/etc/kernel/postinst.d/zz-cixmini-bootloader" <<'EOF'
#!/bin/sh
set -e
[ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
EOF
    cat > "$root/etc/kernel/postrm.d/zz-cixmini-bootloader" <<'EOF'
#!/bin/sh
set -e
[ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
EOF
    chmod 0755 "$root/etc/kernel/postinst.d/zz-cixmini-bootloader" \
               "$root/etc/kernel/postrm.d/zz-cixmini-bootloader"

    cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    # Refresh the installed rEFInd generator before regenerating entries, so an
    # OTA upgrade picks up cmdline changes (e.g. the board-gated efi=noruntime)
    # instead of rerunning a stale copy from the original install.
    if [ -f /usr/lib/cixmini/ncz-refind-refresh ]; then
        mkdir -p /usr/local/sbin
        if install -m 0755 /usr/lib/cixmini/ncz-refind-refresh \
                /usr/local/sbin/.ncz-refind-refresh.new; then
            mv -f /usr/local/sbin/.ncz-refind-refresh.new \
                /usr/local/sbin/ncz-refind-refresh \
                || echo "cixmini-boot: WARNING: could not install ncz-refind-refresh" >&2
        else
            rm -f /usr/local/sbin/.ncz-refind-refresh.new
            echo "cixmini-boot: WARNING: staging ncz-refind-refresh failed" >&2
        fi
    fi
    # This distro boots rEFInd, not systemd-boot. post-install/11-fix-cixmini-boot.sh
    # keeps a stable copy of the rEFInd wrapper at
    # /usr/local/sbin/.ncz-cixmini-update-bootloader and redirects
    # /usr/lib/cixmini/cixmini-update-bootloader at it -- but dpkg has just
    # overwritten that path with OUR packaged systemd-boot helper. An apt
    # Post-Invoke hook does restore and rerun the wrapper at end of transaction,
    # so refind.conf is eventually correct; prefer the wrapper directly here
    # anyway rather than depend on hook ordering, and so refind.conf is refreshed
    # even if that hook is ever absent.
    # Restore the redirect over /usr/lib BEFORE invoking it. dpkg has just
    # overwritten that path with our packaged systemd-boot helper, and when
    # cixmini-boot and a linux-image-cixmini-* upgrade in the same transaction
    # cixmini-boot is configured FIRST (the kernel depends on it) -- so every
    # later kernel postinst would call the /usr/lib path and refresh only inert
    # systemd-boot entries, leaving the real refind.conf stale. Putting the
    # wrapper back here fixes it for the whole rest of the transaction and does
    # not rely on the installer's DPkg::Post-Invoke hook being present.
    if [ -s /usr/local/sbin/.ncz-cixmini-update-bootloader ]; then
        # temp + atomic rename: never leave a half-written wrapper visible to a
        # concurrently-configuring kernel postinst
        if install -m 0755 /usr/local/sbin/.ncz-cixmini-update-bootloader \
                /usr/lib/cixmini/.cixmini-update-bootloader.new; then
            mv -f /usr/lib/cixmini/.cixmini-update-bootloader.new \
                /usr/lib/cixmini/cixmini-update-bootloader \
                || echo "cixmini-boot: WARNING: could not restore the rEFInd wrapper" >&2
        else
            rm -f /usr/lib/cixmini/.cixmini-update-bootloader.new
            echo "cixmini-boot: WARNING: staging the rEFInd wrapper failed" >&2
        fi
    fi
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
fi
exit 0
EOF
    chmod 0755 "$root/DEBIAN/postinst"

    local isize
    isize=$(du -sk "$root" | cut -f1)
    cat > "$root/DEBIAN/control" <<EOF
Package: cixmini-boot
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: admin
Priority: optional
Installed-Size: $isize
Depends: systemd, efibootmgr, util-linux, kmod
Description: NCZ cixmini systemd-boot entry generator (OTA-safe)
 Idempotent bootloader hook that stages installed cixmini kernels to the ESP
 and writes systemd-boot loader entries (lts/next/rescue) without ever wiping
 the ESP. Invoked automatically on kernel install/upgrade/removal.
EOF
    dpkg-deb --root-owner-group --build "$root" \
        "$OUT/cixmini-boot_${ver}_arm64.deb"
}

# ----------------------------------------------------------------------
# linux-image-cixmini-<channel>
# ----------------------------------------------------------------------
build_kernel_deb() {
    local channel="$1"   # legacy | edge
    local kver="$2"
    local label="$3"     # legacy | edge (asset subdir)
    local with_npu="$4"  # path to OOT npu .ko, or ""

    # ONE KERNEL, ONE NAME (operator 2026-08-11: "we do not use LTS or edge,
    # we are 7.2 only now"). The channel suffix is gone: the package is simply
    # linux-image-cixmini. The channel argument survives only to pick the asset
    # subdirectory and label the build log.
    local pkg="linux-image-cixmini"
    local ver="$kver+$BUILD_REV"
    local root="$WORK/$pkg"
    rm -rf "$root"
    install -d "$root/DEBIAN" "$root/boot" "$root/usr"

    echo "  [$channel] $kver -> $pkg ($ver)"
    install -D -m 0644 "$ASSETS/$label/Image-cixmini.bin" "$root/boot/vmlinuz-$kver"
    install -D -m 0644 "$ASSETS/$label/config-$kver"       "$root/boot/config-$kver"

    # Modules: tgz has top-level lib/modules/... -> extract into /usr so it
    # lands at /usr/lib/modules/$kver (usrmerge-safe; see 10-our-kernel.sh).
    tar xzf "$ASSETS/$label/modules-cixmini.tgz" -C "$root/usr" --keep-directory-symlink
    [ -d "$root/usr/lib/modules/$kver" ] || { echo "ERROR: modules tgz did not yield $kver"; exit 1; }
    local mc
    # SHIP THE OUT-OF-TREE GPU MODULES WITH THE KERNEL THAT MATCHES THEM.
    #
    # WHY (2026-08-11, cost a working desktop): this package OWNS
    # /usr/lib/modules/$kver, so installing it over an existing board with the
    # SAME kernel version string replaces that tree wholesale -- deleting
    # everything DKMS had put in updates/. On O6N that silently removed
    # mali_kbase, memory_group_manager and protected_memory_allocator. Result:
    # /dev/mali0 gone, ncz-gpu-env fell back to llvmpipe/pixman, the whole
    # desktop went software-rendered, and Chromium consequently dropped
    # hardware video decode (V4L2VideoDecoder -> VpxVideoDecoder) so 4K video
    # crawled. Nothing reported an error; the box just got slow.
    #
    # DKMS is NOT installed on these images, so nothing rebuilds them. The
    # kernel and its GPU modules are one unit and must ship together, keyed on
    # the exact $kver they were built against. Same reasoning as the NPU module
    # installed just below, which already worked this way.
    #
    # /updates matches assets/kernel/mali/dkms.conf DEST_MODULE_LOCATION, so a
    # DKMS-built module lands in the same place and overrides cleanly.
    if [ -d "$ASSETS/mali/$kver" ]; then
        gm=0
        for _ko in "$ASSETS/mali/$kver"/*.ko; do
            [ -e "$_ko" ] || continue
            install -D -m 0644 "$_ko" "$root/usr/lib/modules/$kver/updates/$(basename "$_ko")"
            gm=$((gm + 1))
        done
        echo "  [$channel] staged $gm out-of-tree GPU module(s) into updates/"
        [ "$gm" -ge 3 ] || echo "  WARN: [$channel] expected 3 GPU modules (mali_kbase, memory_group_manager, protected_memory_allocator), staged $gm -- the GPU will not initialise without all three (kbase defers with -517 'Memory group manager is not ready')"
    else
        echo "  WARN: [$channel] no prebuilt GPU modules at $ASSETS/mali/$kver -- the installed system will have NO GPU and fall back to software rendering"
    fi

    mc=$(find "$root/usr/lib/modules/$kver" \( -name '*.ko' -o -name '*.ko.xz' \) | wc -l)
    [ "$mc" -ge 50 ] || { echo "ERROR: suspiciously few modules ($mc) for $kver"; exit 1; }

    if [ -n "$with_npu" ]; then
        local vm
        vm=$(modinfo -F vermagic "$with_npu" 2>/dev/null | awk '{print $1}')
        [ "$vm" = "$kver" ] || { echo "ERROR: NPU ko vermagic '$vm' != '$kver'"; exit 1; }
        install -D -m 0644 "$with_npu" "$root/usr/lib/modules/$kver/extra/armchina_npu.ko"
        echo "    baked OOT armchina_npu.ko (vermagic $vm)"
    fi

    # Drop stale dep maps; postinst regenerates with depmod on target.
    rm -f "$root/usr/lib/modules/$kver"/modules.dep* \
          "$root/usr/lib/modules/$kver"/modules.alias* \
          "$root/usr/lib/modules/$kver"/modules.symbols* 2>/dev/null || true

    cat > "$root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
KVER="$kver"
# Guard against an empty KVER: a bare "/usr/lib/modules/" in the postrm
# would rm -rf every kernel's modules. Bail if the version is missing.
[ -n "\$KVER" ] || exit 0
if [ "\$1" = configure ]; then
    depmod -a "\$KVER" || true
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -c -k "\$KVER" 2>/dev/null || update-initramfs -u -k "\$KVER" 2>/dev/null || true
    fi
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
fi
exit 0
EOF
    cat > "$root/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
KVER="$kver"
# Guard against an empty KVER: a bare "/usr/lib/modules/" here would
# rm -rf every kernel's modules. Bail if the version is missing.
[ -n "\$KVER" ] || exit 0
case "\$1" in
  remove|purge)
    rm -f "/boot/initrd.img-\$KVER" "/boot/efi/vmlinuz-\$KVER" "/boot/efi/initrd.img-\$KVER" 2>/dev/null || true
    rm -rf "/usr/lib/modules/\$KVER" 2>/dev/null || true
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
    ;;
esac
exit 0
EOF
    chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

    local isize
    isize=$(du -sk "$root" | cut -f1)
    cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: kernel
Priority: optional
Installed-Size: $isize
Depends: cixmini-boot (>= $CIXMINI_BOOT_VER), kmod, initramfs-tools, systemd
Description: NCZ cixmini Linux kernel ($kver)
 Prebuilt linux-cix-sky1 kernel image + modules for the NCZ cixmini (MS-R1).
 Installs vmlinuz, the module tree$( [ -n "$with_npu" ] && echo " (incl. armchina_npu)") and config,
 then refreshes the systemd-boot entry via cixmini-boot.
EOF
    # Renamed-package handoff. linux-image-cixmini-legacy ships the same
    # /boot and /usr/lib/modules paths the old linux-image-cixmini-lts did,
    # so without Replaces dpkg refuses to unpack it over a pre-rename board
    # ("trying to overwrite ... which is also in package ..."). VERSIONED,
    # and Breaks rather than Conflicts, because the old NAME survives as the
    # empty transitional package built below -- an unversioned Conflicts
    # would make that transitional package impossible to install alongside
    # the very package it depends on.
    # Take over from EVERY name this kernel was ever published under. Without
    # this dpkg refuses to unpack over an existing board ("trying to overwrite
    # ... which is also in package ...") because the file paths are identical,
    # and an upgrade would strand the old package installed alongside.
    # CONFLICTS, not Breaks. Breaks means "deconfigure the other package",
    # which dpkg refuses on its own -- MEASURED on O6N: "installing
    # linux-image-cixmini would break linux-image-cixmini-edge, and
    # deconfiguration is not permitted (--auto-deconfigure might help)".
    # Provides+Replaces+Conflicts is the canonical take-over triple: apt REMOVES
    # the retired name and installs this in its place. The old lts->legacy
    # handoff used Breaks correctly because that name survived as a transitional
    # package; these names are retired outright, so nothing is left to
    # deconfigure.
    # ONE field each, comma-separated. dpkg-deb rejects a control file with the
    # same field repeated ("duplicate value for 'Replaces' field"), so these
    # cannot be emitted one relation per line.
    # Also take over the RAW kernel package name, linux-image-<kver>. The Yocto
    # build publishes one and it ships the identical /boot/vmlinuz-<kver> and
    # config-<kver> paths, so a board that ever installed it directly (every
    # kernel test board does) would otherwise hit "trying to overwrite ...
    # which is also in package linux-image-<kver>". Declaring it beats the
    # --force-overwrite that post-install/10-our-kernel.sh has been using to
    # push past exactly this collision.
    _OLD_NAMES="linux-image-cixmini-edge, linux-image-cixmini-lts, linux-image-cixmini-legacy, linux-image-$kver"
    printf 'Replaces: %s\n' "$_OLD_NAMES" >> "$root/DEBIAN/control"
    printf 'Conflicts: %s\n' "$_OLD_NAMES" >> "$root/DEBIAN/control"
    printf 'Provides: %s\n' "$_OLD_NAMES" >> "$root/DEBIAN/control"
    dpkg-deb --root-owner-group --build "$root" "$OUT/${pkg}_${ver}_arm64.deb"
}

# ---------------------------------------------------------------------------
# MANDATORY KERNEL BOOT GATE (operator directive, 2026-08-14).
#
# No kernel gets packaged without being booted first. r236 shipped a kernel
# that panicked at 1.2s into every boot of the installed system
# (cdns3_pci_probe NULL deref, PID 1, reboot loop) -- the installer booted
# fine, so nothing downstream of this script could have caught it.
#
# The gate boots the staged Image under qemu/KVM and additionally refuses any
# builtin driver whose PCI match table collides with an ID Sky1 itself
# presents. See build/kvm-kernel-gate.sh for why both halves are needed.
# ---------------------------------------------------------------------------
if [ -s "$ASSETS/edge/Image-cixmini.bin" ]; then
    echo ""
    echo "== kernel boot gate =="
    "$REPO/build/kvm-kernel-gate.sh" "$ASSETS/edge/Image-cixmini.bin" \
        || { echo "ERROR: kernel boot gate failed -- refusing to package this kernel." >&2; exit 1; }
    echo ""
fi

build_cixmini_boot

# ONE KERNEL TREE (operator, 2026-08-10): 26.7 ships 7.2.0-rc7-sky1-ncz and only
# that; 7.0.12-cix-sky1-next ("legacy") is superseded and its assets are gone.
#
# Guard on the ASSETS, not on KVER: resolve_kver falls back to the ISO-staging
# sidecar when assets/kernel/legacy/KVER is missing, so KVER_LEGACY still
# resolved to a stale 7.0.12 and the build died trying to package a kernel that
# is no longer on disk. A retired channel must be skipped, not resurrected from
# a leftover sidecar.
if [ -s "$ASSETS/legacy/Image-cixmini.bin" ]; then
    build_kernel_deb legacy "$KVER_LEGACY" legacy ""  # NPU in-tree since 7.0.12
else
    echo "  [legacy] no kernel staged in $ASSETS/legacy — skipping (single-tree release)"
fi
build_kernel_deb edge "$KVER_NEXT" edge   ""

# ----------------------------------------------------------------------
# Transitional package: linux-image-cixmini-lts
#
# 7.0.12-cix-sky1-next was published for months as "linux-image-cixmini-lts".
# It is not an LTS -- it is an EOL kernel we support temporarily while 7.2
# goes through its release process -- so the real package is now
# linux-image-cixmini-legacy. Dropping the old name outright would leave every
# already-installed board holding a package that no longer exists in the repo,
# silently receiving no further kernel updates. This empty package depends on
# the new one so `apt upgrade` migrates them automatically.
#
# Delete this once no supported board still has the old name installed.
# ----------------------------------------------------------------------
build_transitional_lts() {
    local pkg=linux-image-cixmini-lts
    # SINGLE-TREE (2026-08-10): this package's whole job is to keep boards that
    # still carry the OLD "linux-image-cixmini-lts" name receiving kernel
    # updates. It depended unconditionally on linux-image-cixmini-legacy -- but
    # legacy is retired, so that produced an UNINSTALLABLE package depending on
    # something no longer in the repo, stranding precisely the boards it exists
    # to rescue. Migrate them to whichever channel is actually shipped.
    local migrate_to ver
    if [ -s "$ASSETS/legacy/Image-cixmini.bin" ]; then
        migrate_to=linux-image-cixmini-legacy
        ver="$KVER_LEGACY+$BUILD_REV"
    else
        migrate_to=linux-image-cixmini-edge
        ver="$KVER_NEXT+$BUILD_REV"
    fi
    echo "  [transitional] $pkg -> Depends: $migrate_to ($ver)"
    local root="$WORK/$pkg"
    rm -rf "$root"
    install -d "$root/DEBIAN"
    cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: all
Maintainer: $MAINT
Section: oldlibs
Priority: optional
Installed-Size: 0
Depends: $migrate_to
Description: transitional package -- renamed to $migrate_to
 The 7.0.12 kernel channel was renamed from "lts" to "legacy": 7.0.12 is an
 EOL kernel supported only until the 7.2 channel finishes its release process,
 so calling it LTS was wrong. This empty package exists purely so existing
 installs migrate to linux-image-cixmini-legacy on upgrade. It can be removed
 once nothing references the old name.
EOF
    chmod 0755 "$root/DEBIAN"
    dpkg-deb --root-owner-group --build "$root" "$OUT/${pkg}_${ver}_all.deb"
    # (the accurate line is printed above, before the control file is written)
}

# build_transitional_lts is NOT called any more: linux-image-cixmini now
# Provides/Replaces that name directly, so a board still carrying it upgrades
# without an intermediate empty package.

echo ""
echo "== built debs =="
ls -lh "$OUT"
echo ""
echo "== control summaries =="
for d in "$OUT"/*.deb; do
    echo "--- $d ---"
    dpkg-deb -f "$d" Package Version Architecture Depends Installed-Size
done
