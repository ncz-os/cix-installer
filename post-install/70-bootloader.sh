#!/bin/bash
# 70-bootloader.sh — systemd-boot install + DUAL-kernel loader entries.
#
# Three loader entries:
#   1. cixmini-lts.conf   (default — Sky1 6.18.26 LTS)
#   2. cixmini-next.conf  ([BETA] Sky1 7.0.1 next — only if NEXT was baked)
#   3. cixmini-rescue.conf (rescue.target on LTS kernel)
#
# CRITICAL: systemd-boot's loader entry parser does NOT support
# backslash line-continuation — every line MUST be standalone. Earlier
# version tried multi-line `options \` and bootctl silently dropped
# half the cmdline.
set -euo pipefail

echo "[70] systemd-boot bootloader (DUAL kernel — LTS default + BETA)"

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

bootctl install --esp-path=/boot/efi --no-variables || \
    bootctl install --esp-path=/boot/efi || true

# ----------------------------------------------------------------------
# loader.conf
# ----------------------------------------------------------------------
mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/loader.conf <<'EOF'
default cixmini-lts
timeout 5
console-mode auto
editor yes
EOF

# ----------------------------------------------------------------------
# Discover root partition by PARTUUID
# ----------------------------------------------------------------------
ROOT_PARTUUID=$(blkid -s PARTUUID -o value $(findmnt -no SOURCE /))
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
MARTJOHNSON_CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30"

# Optional Plymouth splash flags (if 60-plymouth.sh ran)
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"

# ----------------------------------------------------------------------
# Stage kernels onto ESP — systemd-boot reads /boot/efi by default
# ----------------------------------------------------------------------
install -m 0644 "/boot/vmlinuz-$KVER_LTS" "/boot/efi/vmlinuz-$KVER_LTS"
echo "  staged /boot/efi/vmlinuz-$KVER_LTS"

if [ -n "$KVER_NEXT" ] && [ -f "/boot/vmlinuz-$KVER_NEXT" ]; then
    install -m 0644 "/boot/vmlinuz-$KVER_NEXT" "/boot/efi/vmlinuz-$KVER_NEXT"
    echo "  staged /boot/efi/vmlinuz-$KVER_NEXT"
fi

# ----------------------------------------------------------------------
# Entry 1 — cixmini-lts.conf (DEFAULT, production-stable)
# ----------------------------------------------------------------------
LTS_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE"
[ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"

cat > /boot/efi/loader/entries/cixmini-lts.conf <<EOF
title   nclawzero (cixmini) — kernel $KVER_LTS [LTS, default]
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $LTS_OPTIONS
EOF
echo "  wrote cixmini-lts.conf (default)"

# ----------------------------------------------------------------------
# Entry 2 — cixmini-next.conf ([BETA] — only if NEXT kernel was installed)
#
# Title is intentionally LOUD with [BETA] markers so the user cannot
# misclick this in the boot menu thinking it's the stable choice.
# Per Sky1-Linux issue #12 (MartJohnson 2026-04-30): kernel 7.0.1 boots
# on MS-R1 but has known SCMI transition errors and occasional boot
# freezes / shutdown crashes — the BIOS doesn't have the SCMI updates
# 7.0 expects yet. 6.18.26 LTS does NOT have these issues. This BETA
# entry is for A/B testing only; production users should pick LTS.
# ----------------------------------------------------------------------
if [ -n "$KVER_NEXT" ] && [ -f "/boot/efi/vmlinuz-$KVER_NEXT" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"

    cat > /boot/efi/loader/entries/cixmini-next.conf <<EOF
title   *** [BETA — UNSTABLE] nclawzero kernel $KVER_NEXT — KNOWN-BUGGY on MS-R1 ***
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $NEXT_OPTIONS
EOF
    echo "  wrote cixmini-next.conf (BETA — known SCMI errors on MS-R1)"
else
    echo "  skipping cixmini-next.conf (BETA kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 3 — cixmini-rescue.conf (rescue shell on LTS kernel)
#
# rescue.target boots multi-user services down (no graphical, no
# auto-mount of network FS) but leaves the system bootable + login-able
# for recovery. Useful when default cixmini-lts.conf wedges from a bad
# config + we need to roll something back.
# ----------------------------------------------------------------------
RESCUE_OPTIONS="$ROOT_OPTS $MARTJOHNSON_CMDLINE systemd.unit=rescue.target"

cat > /boot/efi/loader/entries/cixmini-rescue.conf <<EOF
title   SAFE rescue (cixmini) — kernel $KVER_LTS rescue.target
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $RESCUE_OPTIONS
EOF
echo "  wrote cixmini-rescue.conf"

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
