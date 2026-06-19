#!/bin/bash
# 70-bootloader.sh — systemd-boot install + DUAL-kernel loader entries.
#
# Loader entries (only TWO kernel binaries on the ESP — LTS + NEXT; the
# safe/rescue entries reuse the LTS binary):
#   1. cixmini-next.conf      (DEFAULT — homegrown Sky1 7.0.12, headline kernel)
#   2. cixmini-lts.conf       (fallback — CIX BSP Sky1 6.18.26-cix-sky1-lts, stable)
#   3. cixmini-lts-safe.conf  (safe graphics — LTS w/ Sky1 accelerators blacklisted)
#   4. cixmini-rescue.conf    (rescue.target on LTS kernel)
#
# CRITICAL: systemd-boot's loader entry parser does NOT support
# backslash line-continuation — every line MUST be standalone. Earlier
# version tried multi-line `options \` and bootctl silently dropped
# half the cmdline.
set -euo pipefail

echo "[70] systemd-boot bootloader (DUAL kernel — 7.0.12 default + 6.18 LTS fallback)"

INSTALLER_META=/usr/local/lib/cix-installer
[ -f "$INSTALLER_META/KVER_LTS" ] || { echo "ERROR: KVER_LTS sidecar missing"; exit 1; }
KVER_LTS=$(cat "$INSTALLER_META/KVER_LTS")
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)

BUILD_VERSION="(unknown)"
[ -f "$INSTALLER_META/BUILD_VERSION" ] && BUILD_VERSION=$(cat "$INSTALLER_META/BUILD_VERSION" 2>/dev/null || true)

echo "  KVER_LTS=$KVER_LTS"
echo "  KVER_NEXT=${KVER_NEXT:-(not present)}"
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
# lowest sort name. This caused multiple "nclawzero (cixmini)"
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
echo "  ESP wiped — about to write fresh dual-kernel entries"

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
# Cmdline (MartJohnson 2026-04-30 working set for MS-R1, both LTS+NEXT)
#
#   loglevel=4                          — visible kernel msgs through boot
#   console=tty0 console=ttyAMA2,115200 — HDMI primary + serial mirror
#   efi=noruntime                       — disable buggy MS-R1 EFI runtime services
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
MARTJOHNSON_CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453 video=DP-4:1920x1080@60e"

# Optional Plymouth splash flags (if 60-plymouth.sh ran)
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"

# ----------------------------------------------------------------------
# Stage kernels onto ESP — systemd-boot reads /boot/efi by default.
#
# Tolerant: if a kernel image is missing (because 10-our-kernel.sh
# couldn't install it), log a clear warning and skip writing that
# loader entry. Don't hard-fail the whole bootloader hook.
# ----------------------------------------------------------------------
LTS_AVAILABLE=0
NEXT_AVAILABLE=0

if [ -f "/boot/vmlinuz-$KVER_LTS" ]; then
    install -m 0644 "/boot/vmlinuz-$KVER_LTS" "/boot/efi/vmlinuz-$KVER_LTS"
    echo "  staged /boot/efi/vmlinuz-$KVER_LTS"
    LTS_AVAILABLE=1
else
    echo "  WARN: /boot/vmlinuz-$KVER_LTS missing — LTS entry will be SKIPPED"
fi

if [ -n "$KVER_NEXT" ] && [ -f "/boot/vmlinuz-$KVER_NEXT" ]; then
    install -m 0644 "/boot/vmlinuz-$KVER_NEXT" "/boot/efi/vmlinuz-$KVER_NEXT"
    echo "  staged /boot/efi/vmlinuz-$KVER_NEXT"
    NEXT_AVAILABLE=1
elif [ -n "$KVER_NEXT" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_NEXT missing — BETA entry will be SKIPPED"
fi

if [ "$LTS_AVAILABLE" = "0" ] && [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: NEITHER kernel installed — system is unbootable."
    echo "       Check 10-our-kernel.sh log for failures."
    exit 1
fi

# ----------------------------------------------------------------------
# Entry — cixmini-lts.conf (FALLBACK — CIX BSP 6.18.26-cix-sky1-lts, stable)
# ----------------------------------------------------------------------
if [ "$LTS_AVAILABLE" = "1" ]; then
    LTS_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE"
    [ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"

    # sort-key forces menu-order (systemd-boot 252+). LTS is the stable
    # fallback so it sorts below the default 7.0.12 headline entry.
    cat > /boot/efi/loader/entries/cixmini-lts.conf <<EOF
title   nclawzero (cixmini) — kernel $KVER_LTS [LTS — CIX BSP, stable fallback] — $BUILD_VERSION
sort-key 2-lts
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $LTS_OPTIONS
EOF
    echo "  wrote cixmini-lts.conf (fallback, sort-key 2-lts)"
else
    echo "  skipping cixmini-lts.conf (LTS kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry — cixmini-lts-safe.conf (SAFE GRAPHICS — 6.18 LTS, accelerators off)
#
# Boots the 6.18 LTS (CIX BSP) kernel but module_blacklists the heavy Sky1
# accelerator / display / audio / codec drivers that are the usual culprits
# for boot hangs (NPU, GPU, the Sky1 DPU/DP, VPUs, DSP, HDA/SOF audio).
# With no KMS driver bound, video falls back to the UEFI framebuffer
# (efifb/simplefb via SYSFB); networking, storage and filesystem drivers
# load normally. Reuses the LTS kernel binary — no extra ESP space. Use this
# when a full boot wedges during GPU/display/NPU/DSP bring-up.
# ----------------------------------------------------------------------
if [ "$LTS_AVAILABLE" = "1" ]; then
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

    cat > /boot/efi/loader/entries/cixmini-lts-safe.conf <<EOF
title   SAFE graphics (cixmini) — kernel $KVER_LTS [6.18 LTS, accelerators disabled] — $BUILD_VERSION
sort-key 3-lts-safe
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $SAFE_OPTIONS
EOF
    echo "  wrote cixmini-lts-safe.conf (sort-key 3-lts-safe, blacklist=$SAFE_BLACKLIST)"
else
    echo "  skipping cixmini-lts-safe.conf (LTS kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry — cixmini-next.conf (DEFAULT — homegrown headline kernel 7.0.12)
#
# 7.0.12 is the homegrown headline kernel with the full Sky1 stack in-tree
# (display/audio/NPU/etc.) and is the default boot target. The earlier
# [BETA] warning applied to 7.0.1 (Sky1-Linux #12: SCMI transition errors /
# boot freezes before the BIOS SCMI updates); 7.0.12 is the validated
# default. The CIX BSP 6.18 LTS remains as the conservative fallback entry.
# ----------------------------------------------------------------------
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"

    # sort-key 1-next keeps the default headline kernel at the top of the menu.
    cat > /boot/efi/loader/entries/cixmini-next.conf <<EOF
title   nclawzero (cixmini) — kernel $KVER_NEXT [headline, default] — $BUILD_VERSION
sort-key 1-next
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $NEXT_OPTIONS
EOF
    echo "  wrote cixmini-next.conf (default, sort-key 1-next)"
else
    echo "  skipping cixmini-next.conf (headline kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 3 — cixmini-rescue.conf (rescue shell on LTS kernel)
#
# rescue.target boots multi-user services down (no graphical, no
# auto-mount of network FS) but leaves the system bootable + login-able
# for recovery. Useful when default cixmini-lts.conf wedges from a bad
# config + we need to roll something back.
# ----------------------------------------------------------------------
# Rescue uses LTS by preference, falls back to NEXT if LTS missing.
if [ "$LTS_AVAILABLE" = "1" ]; then
    RESCUE_KVER="$KVER_LTS"
elif [ "$NEXT_AVAILABLE" = "1" ]; then
    RESCUE_KVER="$KVER_NEXT"
else
    RESCUE_KVER=""
fi

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

# Default to the headline 7.0.12 (cixmini-next); fall back to the CIX BSP 6.18
# LTS only if the headline kernel isn't present. Re-write loader.conf to match
# what's actually installed.
if [ "$NEXT_AVAILABLE" = "1" ]; then
    DEFAULT_ENTRY="cixmini-next"
else
    DEFAULT_ENTRY="cixmini-lts"
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
