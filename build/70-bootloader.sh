#!/bin/bash

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
# 70-bootloader.sh — systemd-boot install + EDGE-only kernel loader entries.
#
# Loader entries (ONE kernel binary on the ESP — edge; the rescue entry
# reuses the edge binary):
#   1. cixmini-next.conf      (DEFAULT — 7.2.0-sky1-ncz edge)
#   2. cixmini-console.conf   (no GUI, multi-user.target)
#   3. cixmini-rescue.conf    (rescue.target, edge kernel)
#   4. cixmini-safe.conf      (boot with GPU/NPU/etc blacklisted)
#
# CRITICAL: systemd-boot's loader entry parser does NOT support
# backslash line-continuation — every line MUST be standalone. Earlier
# version tried multi-line `options \` and bootctl silently dropped
# half the cmdline.
set -euo pipefail

echo "[70] systemd-boot bootloader (EDGE kernel — 7.2.0-sky1-ncz)"

INSTALLER_META=/usr/local/lib/cix-installer
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
[ -n "$KVER_NEXT" ] || { echo "ERROR: KVER_NEXT sidecar missing"; exit 1; }

BUILD_VERSION="(unknown)"
[ -f "$INSTALLER_META/BUILD_VERSION" ] && BUILD_VERSION=$(cat "$INSTALLER_META/BUILD_VERSION" 2>/dev/null || true)

echo "  KVER_NEXT=$KVER_NEXT"
echo "  BUILD_VERSION=$BUILD_VERSION"

# ----------------------------------------------------------------------
# Install systemd-boot + efibootmgr
# ----------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-boot efibootmgr || true

command -v bootctl >/dev/null || { echo "ERROR: bootctl not installed"; exit 1; }

# Validate /boot/efi is actually mounted as the ESP — without this, a
# missing ESP mount (e.g. preseed partman edge case) would let
# `bootctl install` write loader files into a plain directory on the
# rootfs, then we'd write entries that go nowhere, and the disk would
# boot to nothing. Fail fast with clear diagnostics.
if ! findmnt -no FSTYPE /boot/efi >/dev/null 2>&1; then
    echo "ERROR: /boot/efi is not mounted — cannot install systemd-boot."
    echo "  findmnt /boot/efi → not found"
    echo "  block devices:"
    lsblk 2>&1 | head -10 || true
    echo "  fstab entry for /boot/efi:"
    grep -E "/boot/efi" /etc/fstab 2>&1 || echo "  (no /boot/efi entry)"
    exit 1
fi
ESP_FSTYPE=$(findmnt -no FSTYPE /boot/efi)
if [ "$ESP_FSTYPE" != "vfat" ]; then
    echo "ERROR: /boot/efi is mounted as $ESP_FSTYPE, expected vfat (FAT32 ESP)."
    exit 1
fi
echo "  /boot/efi is mounted (vfat) — proceeding with systemd-boot install"

# Two-stage install — first try without efivar registration (works in
# chroot / QEMU without RW efivarfs), fall back to default if that
# rejects. If BOTH fail, that's a hard error; without bootctl install,
# /boot/efi/EFI/systemd/systemd-bootaa64.efi won't be on the ESP and
# anything we write under loader/ goes nowhere.
if ! bootctl install --esp-path=/boot/efi --no-variables 2>&1; then
    echo "  --no-variables install failed; retrying with efivar reg"
    if ! bootctl install --esp-path=/boot/efi 2>&1; then
        echo "ERROR: both bootctl install attempts failed."
        echo "  Check /boot/efi mount + writability + /sys/firmware/efi/efivars."
        exit 1
    fi
fi
# Verify the systemd-boot binary actually landed on the ESP
if [ ! -f /boot/efi/EFI/systemd/systemd-bootaa64.efi ]; then
    echo "ERROR: bootctl install reported success but"
    echo "       /boot/efi/EFI/systemd/systemd-bootaa64.efi is missing."
    ls -la /boot/efi/EFI/ 2>&1 | head -10 || true
    exit 1
fi
echo "  systemd-bootaa64.efi present on ESP"

# ----------------------------------------------------------------------
# WIPE STALE ESP STATE before writing fresh entries.
#
# Every prior install accumulated loader entry .conf files and
# vmlinuz copies on the ESP. systemd-boot reads ALL *.conf files in
# /boot/efi/loader/entries/ — leftover entries from r1/r2/r3 installs
# show up alongside the new ones, defaulting to whichever has the
# lowest sort name. This caused multiple "NCZ-OS (cixmini)"
# entries on cixmini.66 (r6 era + earlier) and confused systemd-boot's
# default selection.
#
# Wipe everything we own here. If the user has an out-of-band entry
# they want preserved, they can re-add it after install.
echo "  wiping stale ESP entries + kernel images..."
rm -f /boot/efi/loader/entries/*.conf
rm -f /boot/efi/vmlinuz-*
# Some installs put kernels in /boot/efi/EFI/Linux/ via systemd-boot's
# automatic discovery. Wipe those too.
rm -f /boot/efi/EFI/Linux/*.efi 2>/dev/null
echo "  ESP wiped — about to write fresh edge-only kernel entries"

# ----------------------------------------------------------------------
# loader.conf
# ----------------------------------------------------------------------
mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/loader.conf <<'EOF'
default cixmini-next
timeout 5
console-mode auto
editor yes
EOF

# ----------------------------------------------------------------------
# Discover root partition by PARTUUID
# ----------------------------------------------------------------------
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
echo "  root PARTUUID=$ROOT_PARTUUID"

# ----------------------------------------------------------------------
# Cmdline (MartJohnson 2026-04-30 working set for MS-R1, edge kernel)
#
#   loglevel=4                          — visible kernel msgs through boot
#   console=tty0 console=ttyAMA2,115200 — HDMI primary + serial mirror
#   $EFI_RT_WORKAROUND                  — efi=noruntime on MS-R1 only (see helper at top)
#   acpi=force                          — bypass DSDT preference checks
#   arm-smmu-v3.disable_bypass=0        — SMMUv3 IORT compatibility
#   audit_backlog_limit=8192            — early-boot audit subsystem doesn't drop msgs
#   clk_ignore_unused                   — Cix Sky1 SCMI requires this
#   keep_bootcon                        — early console persists through handoff
#   panic=30                            — 30s grace before reboot on panic
#
# NPU is config-disabled in MartJohnson configs (CONFIG_ARMCHINA_NPU=n)
# so cmdline module_blacklist=armchina_npu is unnecessary. We don't
# add module blacklists here — the configs already disable everything
# that would cause boot trouble on MS-R1.
# ----------------------------------------------------------------------
MARTJOHNSON_CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 $EFI_RT_WORKAROUND acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453 video=DP-4:1920x1080@60e"

# Optional splash cmdline flags (legacy; native singularity-boot-splash is a
# systemd/KMS service, not cmdline-driven — this stays empty unless a file exists)
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"

# ----------------------------------------------------------------------
# Stage kernel onto ESP — systemd-boot reads /boot/efi by default.
#
# Tolerant: if the kernel image is missing (because 10-our-kernel.sh
# couldn't install it), log a clear warning and skip writing that
# loader entry. Don't hard-fail the whole bootloader hook.
# ----------------------------------------------------------------------
NEXT_AVAILABLE=0

if [ -n "$KVER_NEXT" ] && [ -f "/boot/vmlinuz-$KVER_NEXT" ]; then
    install -m 0644 "/boot/vmlinuz-$KVER_NEXT" "/boot/efi/vmlinuz-$KVER_NEXT"
    echo "  staged /boot/efi/vmlinuz-$KVER_NEXT"
    NEXT_AVAILABLE=1
elif [ -n "$KVER_NEXT" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_NEXT missing — edge entry will be SKIPPED"
fi

if [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: edge kernel not installed — system is unbootable."
    echo "       Check 10-our-kernel.sh log for failures."
    exit 1
fi

# ----------------------------------------------------------------------
# Entry — cixmini-next.conf (DEFAULT — edge kernel 7.2.0-sky1-ncz)
#
# 7.2.0-sky1-ncz is the shipped headline kernel with the full Sky1
# stack in-tree (display/audio/NPU/etc.) and is the default boot target.
# ----------------------------------------------------------------------
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"

    # sort-key 1-next keeps the default edge kernel at the top of the menu.
    cat > /boot/efi/loader/entries/cixmini-next.conf <<EOF
title   NCZ-OS (cixmini) — kernel $KVER_NEXT [edge, default] — $BUILD_VERSION
sort-key 1-next
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $NEXT_OPTIONS
EOF
    echo "  wrote cixmini-next.conf (default, sort-key 1-next)"
fi

# ----------------------------------------------------------------------
# Entry — cixmini-safe.conf (boot with accelerators blacklisted)
#
# Boots the edge kernel but module_blacklists the heavy Sky1
# accelerator / display / audio / codec drivers that are the usual culprits
# for boot hangs (NPU, GPU, the Sky1 DPU/DP, VPUs, DSP, HDA/SOF audio).
# With no KMS driver bound, video falls back to the UEFI framebuffer
# (efifb/simplefb via SYSFB); networking, storage and filesystem drivers
# load normally. Reuses the edge kernel binary — no extra ESP space. Use this
# when a full boot wedges during GPU/display/NPU/DSP bring-up.
# ----------------------------------------------------------------------
if [ "$NEXT_AVAILABLE" = "1" ]; then
    # Module names normalize '-' to '_'. Keep networking/fb/fs OUT of this list.
    SAFE_BLACKLIST="armchina_npu,amphion_vpu,hantro_vpu,wave5,panthor,panfrost,mali_dp,sky1_drm,trilin_dpsub,cix_dsp,cix_dsp_rproc,snd_hda_cix_ipbloq,snd_sof_cix_common,snd_sof_cix_sky1"
    # The base cmdline already carries a module_blacklist= (typec). The kernel
    # honors only ONE module_blacklist= (last wins), so MERGE our list into the
    # existing param rather than appending a second one.
    if [[ "$MARTJOHNSON_CMDLINE" == *module_blacklist=* ]]; then
        SAFE_CMDLINE="${MARTJOHNSON_CMDLINE/module_blacklist=/module_blacklist=$SAFE_BLACKLIST,}"
    else
        SAFE_CMDLINE="$MARTJOHNSON_CMDLINE module_blacklist=$SAFE_BLACKLIST"
    fi
    SAFE_OPTIONS="$ROOT_OPTS $SAFE_CMDLINE nomodeset"

    cat > /boot/efi/loader/entries/cixmini-safe.conf <<EOF
title   SAFE graphics (cixmini) — kernel $KVER_NEXT [edge, accelerators disabled] — $BUILD_VERSION
sort-key 2-safe
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $SAFE_OPTIONS
EOF
    echo "  wrote cixmini-safe.conf (sort-key 2-safe, blacklist=$SAFE_BLACKLIST)"
fi

# ----------------------------------------------------------------------
# Entry — cixmini-console.conf (same image, no GUI)
#
# multi-user.target (not rescue.target): full multi-user boot with networking
# and all services, just no display manager. rescue.target below is a different
# thing -- single-user recovery with services down.
# ----------------------------------------------------------------------
if [ "$NEXT_AVAILABLE" = "1" ]; then
    CONSOLE_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE systemd.unit=multi-user.target"

    cat > /boot/efi/loader/entries/cixmini-console.conf <<EOF
title   NCZ-OS console (cixmini) — kernel $KVER_NEXT, no desktop — $BUILD_VERSION
sort-key 3-console
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $CONSOLE_OPTIONS
EOF
    echo "  wrote cixmini-console.conf (sort-key 3-console, multi-user.target)"
fi

# ----------------------------------------------------------------------
# Entry — cixmini-rescue.conf (rescue shell on the edge kernel)
#
# rescue.target boots multi-user services down (no graphical, no
# auto-mount of network FS) but leaves the system bootable + login-able
# for recovery. Useful when default cixmini-next.conf wedges from a bad
# config + we need to roll something back.
# ----------------------------------------------------------------------
RESCUE_KVER="$KVER_NEXT"

if [ -n "$RESCUE_KVER" ]; then
    RESCUE_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE systemd.unit=rescue.target"

    cat > /boot/efi/loader/entries/cixmini-rescue.conf <<EOF
title   rescue (cixmini) — kernel $RESCUE_KVER rescue.target — $BUILD_VERSION
sort-key 4-rescue
version $RESCUE_KVER
linux   /vmlinuz-$RESCUE_KVER
options $RESCUE_OPTIONS
EOF
    echo "  wrote cixmini-rescue.conf (sort-key 4-rescue)"
fi

# Default to the headline edge kernel (cixmini-next); fall back to the legacy
# kernel only if the headline kernel isn't present. Re-write loader.conf to match
# what's actually installed.
#
# r303: install-time component toggle (see preseed/component-selector.sh). When
# the operator opted OUT of the desktop, retarget the default rEFInd entry at
# cixmini-console (systemd.unit=multi-user.target). The cixmini-next entry is
# still written (operator can pick it manually from rEFInd for recovery), but
# the freshly-installed box boots straight to console on first power-on.
DEFAULT_ENTRY="cixmini-next"
COMP_FILE=/usr/local/lib/cix-installer/COMPONENTS
[ -r "$COMP_FILE" ] || COMP_FILE=/etc/cix-installer/COMPONENTS
[ -r "$COMP_FILE" ] || COMP_FILE=/var/lib/cix-components/COMPONENTS
if [ -r "$COMP_FILE" ]; then
    _ck=$(tr -d ' \t\r\n' < "$COMP_FILE" 2>/dev/null || true)
    case ",$_ck," in
        *",desktop,"*) : ;;
        *)
            if [ "$NEXT_AVAILABLE" = "1" ]; then
                DEFAULT_ENTRY="cixmini-console"
                echo "  component-selector: desktop OFF — default rEFInd entry -> cixmini-console"
            fi
            ;;
    esac
else
    # See run-all.sh: a missing COMPONENTS record means the selection was lost
    # in the pipeline, not that the operator wanted everything. Say so.
    echo "  WARNING: no COMPONENTS record found -- defaulting rEFInd to the DESKTOP entry."
    echo "           A deselected desktop would be silently ignored here."
fi
cat > /boot/efi/loader/loader.conf <<EOF
default $DEFAULT_ENTRY
timeout 5
console-mode auto
editor yes
EOF
echo "  loader.conf default = $DEFAULT_ENTRY"

# ----------------------------------------------------------------------
# Add a UEFI boot entry pointing at systemd-boot.
# Strip the trailing partition number off the source path
# (/dev/nvme0n1p2 → 2) — portable across the chroot's util-linux ver.
# ----------------------------------------------------------------------
EFI_DEV=$(findmnt -no SOURCE /boot/efi)
EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV")
EFI_PART="${EFI_DEV##*[!0-9]}"
efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
    -L "nclawzero" -l '\EFI\systemd\systemd-bootaa64.efi' || true

echo ""
echo "===== systemd-boot loader entries written ====="
ls -la /boot/efi/loader/entries/
echo ""
for entry in /boot/efi/loader/entries/cixmini-*.conf; do
    echo "--- $entry ---"
    cat "$entry"
    echo ""
done
echo ""
echo "bootctl status — Unknown-line warnings should be EMPTY:"
bootctl status 2>&1 | grep -E "Unknown line|without value" | head -5 || true
echo ""
echo "Final EFI boot entries:"
efibootmgr -v 2>&1 | head -10 || true
