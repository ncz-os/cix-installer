#!/bin/bash
# 70-bootloader.sh — systemd-boot install + staged kernel loader entries.
# r79 (2026-05-20): LTS is now DEFAULT (working NPU + MNEMOS embedkit).
# NEXT is opt-in [EXPERIMENTAL — NPU WIP]. Supersedes r75 K3 NEXT-default.
#
# Loader entries (in menu order when all staged kernels exist):
#   1. cixmini-lts+3-0.conf  (DEFAULT — Sky1 linux-cix-sky1-lts 6.18.x + NPU)
#   2. cixmini-next.conf     (EXPERIMENTAL — Sky1 linux-cix-sky1-next 7.0.x)
#   3. cixmini-rescue.conf   (rescue.target — defaults to LTS kernel)
#
# CRITICAL: systemd-boot's loader entry parser does NOT support
# backslash line-continuation — every line MUST be standalone. Earlier
# version tried multi-line `options \` and bootctl silently dropped
# half the cmdline.
set -euo pipefail

echo "[70] systemd-boot bootloader (staged kernel payload)"

INSTALLER_META=/usr/local/lib/cix-installer
KVER_LTS=""
[ -f "$INSTALLER_META/KVER_LTS" ] && KVER_LTS=$(cat "$INSTALLER_META/KVER_LTS" 2>/dev/null || true)
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)

if [ -z "$KVER_LTS" ] && [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_LTS or KVER_NEXT sidecar present"
    exit 1
fi

BUILD_VERSION="(unknown)"
[ -f "$INSTALLER_META/BUILD_VERSION" ] && BUILD_VERSION=$(cat "$INSTALLER_META/BUILD_VERSION" 2>/dev/null || true)

echo "  KVER_LTS=$KVER_LTS"
echo "  KVER_NEXT=${KVER_NEXT:-(not present)}"
echo "  BUILD_VERSION=$BUILD_VERSION"

# ----------------------------------------------------------------------
# Install systemd-boot + efibootmgr.
#
# NCZ offline media carries systemd-boot in the local resolute/main mirror.
# Do not try to add universe or run a broad apt-get update when the cdrom
# source is active: offline installs have only main, and the local source is
# installed under sources.list.d/cixmini-cdrom.list rather than sources.list.
# ----------------------------------------------------------------------
OFFLINE_APT=0
if grep -RqsE '^[[:space:]]*deb\b.*file:///cdrom[[:space:]]+resolute[[:space:]]+main\b' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    OFFLINE_APT=1
fi

if [ "$OFFLINE_APT" = "1" ]; then
    echo "[70] offline cdrom apt source active; skipping universe enablement"
elif ! grep -qE '^\s*deb\b[^#]* resolute [^-].*\buniverse\b' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    if [ -f /etc/apt/sources.list ] && grep -qE ' resolute main$' /etc/apt/sources.list; then
        echo "[70] adding universe to sources.list for online fallback"
        sed -i 's/ resolute main$/ resolute main universe/' /etc/apt/sources.list
        apt-get update -qq 2>&1 | tail -2
    else
        echo "[70] universe not enabled; proceeding with existing apt sources"
    fi
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-boot efibootmgr

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

# 2026-05-08 take22 (per .66 take21 install: target booted into UEFI menu,
# manual boot-from-drive fell back to UEFI menu — firmware found no
# bootable EFI binary at the default fallback path):
#
# Cix Sky1 / MS-R1 firmware (and most arm64 UEFI firmwares) WILL boot
# from the well-known fallback path EFI/BOOT/BOOTAA64.EFI without
# needing an NVRAM EFI variable entry. `bootctl install --no-variables`
# (which we use to avoid efivar write issues in d-i chroot) does NOT
# write that fallback. We must copy it explicitly.
#
# Without this copy, install completes cleanly but the firmware sees
# no bootable target → returns to the UEFI menu after every "boot from
# drive" attempt.
install -d -m 0755 /boot/efi/EFI/BOOT
cp /boot/efi/EFI/systemd/systemd-bootaa64.efi /boot/efi/EFI/BOOT/BOOTAA64.EFI
if [ ! -f /boot/efi/EFI/BOOT/BOOTAA64.EFI ]; then
    echo "ERROR: failed to install firmware fallback EFI/BOOT/BOOTAA64.EFI"
    exit 1
fi
echo "  EFI/BOOT/BOOTAA64.EFI fallback installed (firmware-default path)"

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
default cixmini-lts*
timeout 5
console-mode auto
editor yes
EOF

# ----------------------------------------------------------------------
# Discover root partition. Prefer PARTUUID for stable systemd-boot root=,
# fall back to filesystem UUID if the block device lacks a PARTUUID.
# ----------------------------------------------------------------------
ROOT_SOURCE=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_DEV="${ROOT_SOURCE%%[*}"
if [ -z "$ROOT_DEV" ]; then
    echo "ERROR: could not determine root mount source"
    exit 1
fi
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEV" 2>/dev/null || true)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
if [ -n "$ROOT_PARTUUID" ]; then
    ROOT_SPEC="PARTUUID=$ROOT_PARTUUID"
    echo "  root PARTUUID=$ROOT_PARTUUID"
elif [ -n "$ROOT_UUID" ]; then
    ROOT_SPEC="UUID=$ROOT_UUID"
    echo "  root PARTUUID unavailable; falling back to root UUID=$ROOT_UUID"
else
    echo "ERROR: could not derive PARTUUID or UUID for root device $ROOT_DEV"
    exit 1
fi

# ----------------------------------------------------------------------
# Cmdline (MartJohnson 2026-04-30 working set for MS-R1, both LTS+NEXT)
#
#   loglevel=4                          — visible kernel msgs through boot
#   console=tty0 console=ttyAMA0,115200 — HDMI primary + serial mirror
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
# r79: LTS is the boot-counted default, so it requires EFI runtime.
# systemd-bless-boot must be able to read LoaderBootCountPath and write
# the successful boot state; disabling EFI runtime would burn the LTS
# +N-M counter to .failed even after successful boots.
#
# NEXT is manual-selection only and does not require EFI runtime for
# boot-counting semantics. The r74-era rationale for putting
# efi=noruntime on LTS was written when NEXT was the default and LTS was
# the non-counted fallback; those roles are now reversed.
LTS_CMDLINE_BASE="loglevel=4 console=tty0 acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"
NEXT_CMDLINE_BASE="loglevel=4 console=tty0 acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"

# Optional Plymouth splash flags (if 60-plymouth.sh ran)
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null || echo ext4)
if [ "$ROOT_FSTYPE" = "btrfs" ]; then
    ROOT_SUBVOL=$(findmnt -no OPTIONS / 2>/dev/null | tr "," "\n" | grep "^subvol=" | head -1 | sed "s/subvol=//" || true)
    if [ -z "$ROOT_SUBVOL" ]; then
        ROOT_FSROOT=$(findmnt -no FSROOT / 2>/dev/null || true)
        if [ -n "$ROOT_FSROOT" ] && [ "$ROOT_FSROOT" != "/" ]; then
            ROOT_SUBVOL="$ROOT_FSROOT"
        fi
    fi
    if [ -n "$ROOT_SUBVOL" ]; then
        ROOT_OPTS="root=$ROOT_SPEC rootwait rootfstype=btrfs rootflags=subvol=$ROOT_SUBVOL rw"
    else
        ROOT_OPTS="root=$ROOT_SPEC rootwait rootfstype=btrfs rw"
    fi
else
    ROOT_OPTS="root=$ROOT_SPEC rootwait rootfstype=${ROOT_FSTYPE:-ext4} rw"
fi

# ----------------------------------------------------------------------
# Stage kernels/initrds onto ESP — systemd-boot reads /boot/efi by default.
#
# Tolerant only for an absent kernel image: if a KVER sidecar exists but
# that kernel was not installed, log a clear warning and skip that entry.
# A present kernel without a present initrd is a hard error, because it means
# the required 10-our-kernel.sh initramfs step failed.
# ----------------------------------------------------------------------
LTS_AVAILABLE=0
NEXT_AVAILABLE=0
LTS_INITRD_AVAILABLE=0
NEXT_INITRD_AVAILABLE=0

if [ -n "$KVER_LTS" ] && [ -f "/boot/vmlinuz-$KVER_LTS" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_LTS" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LTS exists but /boot/initrd.img-$KVER_LTS is missing or empty."
        echo "       Refusing to write an LTS loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_LTS" "/boot/efi/vmlinuz-$KVER_LTS"
    echo "  staged /boot/efi/vmlinuz-$KVER_LTS"
    LTS_AVAILABLE=1
    # Stage initrd (NPU SSDT override is prepended by 80-npu.sh)
    install -m 0644 "/boot/initrd.img-$KVER_LTS" "/boot/efi/initrd.img-$KVER_LTS"
    echo "  staged /boot/efi/initrd.img-$KVER_LTS"
    LTS_INITRD_AVAILABLE=1
elif [ -n "$KVER_LTS" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_LTS missing — LTS entry will be SKIPPED"
else
    echo "  LTS kernel not staged — skipping LTS fallback entry"
fi

if [ -n "$KVER_NEXT" ] && [ -f "/boot/vmlinuz-$KVER_NEXT" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_NEXT" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_NEXT exists but /boot/initrd.img-$KVER_NEXT is missing or empty."
        echo "       Refusing to write a NEXT loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_NEXT" "/boot/efi/vmlinuz-$KVER_NEXT"
    echo "  staged /boot/efi/vmlinuz-$KVER_NEXT"
    NEXT_AVAILABLE=1
    install -m 0644 "/boot/initrd.img-$KVER_NEXT" "/boot/efi/initrd.img-$KVER_NEXT"
    echo "  staged /boot/efi/initrd.img-$KVER_NEXT"
    NEXT_INITRD_AVAILABLE=1
elif [ -n "$KVER_NEXT" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_NEXT missing — BETA entry will be SKIPPED"
fi

if [ "$LTS_AVAILABLE" = "0" ] && [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: NEITHER kernel installed — system is unbootable."
    echo "       Check 10-our-kernel.sh log for failures."
    exit 1
fi

# ----------------------------------------------------------------------
# Entry 1 — cixmini-lts.conf (DEFAULT, production-stable, only if LTS available)
# ----------------------------------------------------------------------
if [ "$LTS_AVAILABLE" = "1" ]; then
    LTS_OPTIONS="$ROOT_OPTS $LTS_CMDLINE_BASE"
    [ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"

    # sort-key forces menu-order (systemd-boot 252+).
    # Order (per RULE 2026-05-20 update — supersedes 2026-05-03):
    #   LTS (6.18) first/default with working NPU stack for MNEMOS appliance
    #   NEXT (7.x) second/experimental — GPU stable, NPU still in progress
    #   rescue last
    # Rationale: NPU is required for MNEMOS embedkit hybrid inference;
    # armchina_npu builds in-tree for 6.18.26-lts with known-good Compass
    # NN + ONNX runtime paths. NEXT 7.x has newer panthor GPU but NPU
    # power-on still depends on BIOS v1.2 + SCMI proto 13 (not yet shipped
    # by Minisforum). Production = LTS; dev/A-B = NEXT.
    #
    # LTS now uses +3-0 boot-counting suffix (was NEXT-only). Rollback
    # target on .failed = the NEXT entry (sort-key 2-next).
    cat > /boot/efi/loader/entries/cixmini-lts+3-0.conf <<EOF
title   nclawzero (cixmini) — kernel $KVER_LTS [LTS, default] — $BUILD_VERSION
sort-key 1-lts
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $LTS_OPTIONS
EOF
    if [ "$LTS_INITRD_AVAILABLE" = "1" ]; then
        # Insert initrd line after "linux" — required for NPU SSDT override
        sed -i "/^linux /a initrd  /initrd.img-$KVER_LTS" /boot/efi/loader/entries/cixmini-lts+3-0.conf
        echo "  added initrd line to cixmini-lts+3-0.conf"
    fi
    echo "  wrote cixmini-lts+3-0.conf (sort-key 1-lts, default, 3-try rollback to NEXT)"
else
    echo "  skipping cixmini-lts.conf (LTS kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 2 — cixmini-next.conf ([EXPERIMENTAL] — only if NEXT kernel was installed)
#
# Title is intentionally LOUD with [EXPERIMENTAL — NPU WIP] markers so
# the user cannot misclick this in the boot menu thinking it's the stable
# choice. Per Sky1-Linux issue #12 (MartJohnson 2026-04-30): kernel 7.0.1
# boots on MS-R1 but has known SCMI transition errors and occasional boot
# freezes / shutdown crashes — the BIOS doesn't have the SCMI updates
# 7.0 expects yet. 6.18.26 LTS does NOT have these issues.
#
# Role: NEXT entry exists for newer panthor GPU stack (7.0.9 mali_csffw)
# and A/B kernel testing. NPU on NEXT is in-progress (armchina_npu module
# is built but power-on path still depends on BIOS v1.2). Production users
# select LTS for working NPU + MNEMOS embedkit appliance.
#
# NEXT is no longer boot-counted (manual selection only). The LTS entry
# is the boot-counted default; on .failed it rolls back to NEXT.
# ----------------------------------------------------------------------
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $NEXT_CMDLINE_BASE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"

    cat > /boot/efi/loader/entries/cixmini-next.conf <<EOF
title   nclawzero (cixmini) — kernel $KVER_NEXT [NEXT EXPERIMENTAL — NPU WIP] — $BUILD_VERSION
sort-key 2-next
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $NEXT_OPTIONS
EOF
    if [ "$NEXT_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$KVER_NEXT" /boot/efi/loader/entries/cixmini-next.conf
        echo "  added initrd line to cixmini-next.conf"
    fi
    # systemd-bless-boot is now driven by the LTS entry's +3-0 boot-counting
    # filename. NEXT is opt-in via menu pick; no boot-counting.
    if systemctl list-unit-files systemd-bless-boot.service systemd-boot-check-no-failures.service 2>/dev/null | grep -q "^systemd-bless"; then
        echo "  systemd-bless-boot.service is in unit-files set — generator path active"
    else
        echo "  systemd-bless-boot.service not in list-unit-files (likely generator-pulled at boot — typical) — proceeding"
    fi
    echo "  wrote cixmini-next.conf (sort-key 2-next, experimental, no boot-counting)"
else
    echo "  skipping cixmini-next.conf (NEXT kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 3 — cixmini-rescue.conf (rescue shell on LTS kernel)
#
# OPERATOR RULE: THIS ENTRY IS MANDATORY AND PROTECTED.
# NEVER remove, rename, or disable cixmini-rescue.conf at runtime.
# There must always be a rescue kernel choice. Violation = reinstall.
#
# rescue.target boots multi-user services down (no graphical, no
# auto-mount of network FS) but leaves the system bootable + login-able
# for recovery. Useful when default cixmini-lts.conf wedges from a bad
# config + we need to roll something back.
# ----------------------------------------------------------------------
# Rescue uses LTS by preference, falls back to NEXT if LTS missing.
if [ "$LTS_AVAILABLE" = "1" ]; then
    RESCUE_KVER="$KVER_LTS"
    RESCUE_CMDLINE_BASE="$LTS_CMDLINE_BASE"
elif [ "$NEXT_AVAILABLE" = "1" ]; then
    RESCUE_KVER="$KVER_NEXT"
    RESCUE_CMDLINE_BASE="$NEXT_CMDLINE_BASE"
else
    RESCUE_KVER=""
    RESCUE_CMDLINE_BASE=""
fi

if [ -n "$RESCUE_KVER" ]; then
    RESCUE_OPTIONS="$ROOT_OPTS $RESCUE_CMDLINE_BASE systemd.unit=rescue.target"

    cat > /boot/efi/loader/entries/cixmini-rescue.conf <<EOF
title   SAFE rescue (cixmini) — kernel $RESCUE_KVER rescue.target — $BUILD_VERSION
sort-key 3-rescue
version $RESCUE_KVER
linux   /vmlinuz-$RESCUE_KVER
options $RESCUE_OPTIONS
EOF
    # Rescue entry uses initrd if available for the chosen kernel
    if [ "$RESCUE_KVER" = "$KVER_LTS" ] && [ "$LTS_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$RESCUE_KVER" /boot/efi/loader/entries/cixmini-rescue.conf
    elif [ "$RESCUE_KVER" = "$KVER_NEXT" ] && [ "$NEXT_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$RESCUE_KVER" /boot/efi/loader/entries/cixmini-rescue.conf
    fi
    echo "  wrote cixmini-rescue.conf (sort-key 3-rescue)"
fi

# r79 (2026-05-20): LTS is DEFAULT with boot-counted rollback to NEXT.
# Working NPU stack lives on LTS 6.18.26 (armchina_npu in-tree + Compass
# NN + ONNX runtime) — required for MNEMOS embedkit appliance. NEXT 7.x
# has newer panthor GPU but NPU power-on still gated on BIOS v1.2.
#
# LTS entry uses systemd-boot boot-counting (cixmini-lts+3-0.conf); after
# 3 failed boots the entry .failed-renames and systemd-boot falls back
# to cixmini-next.conf (sort-key 2-next). If only NEXT is staged
# (netinstall path), NEXT becomes default.
if [ "$LTS_AVAILABLE" = "1" ]; then
    # cixmini-lts* glob matches the +N-M.conf boot-counter rotations
    # written by systemd-bless-boot. Per Codex round-4: trust the
    # systemd generator; do not gate on systemctl enable success.
    DEFAULT_ENTRY="cixmini-lts*"
elif [ "$NEXT_AVAILABLE" = "1" ]; then
    DEFAULT_ENTRY="cixmini-next"
else
    echo "ERROR: NEITHER kernel installed — cannot set default loader entry"
    exit 1
fi
cat > /boot/efi/loader/loader.conf <<EOF
default $DEFAULT_ENTRY
timeout 5
console-mode auto
editor yes
EOF
echo "  loader.conf default = $DEFAULT_ENTRY"

# Verify the default actually resolves to a written entry. systemd-boot
# treats default as a glob; for cixmini-lts* match either the canonical
# +3-0.conf (boot-counter) or any later +N-M rotation.
if [ "$DEFAULT_ENTRY" = "cixmini-lts*" ]; then
    if ! ls /boot/efi/loader/entries/cixmini-lts*.conf >/dev/null 2>&1; then
        echo "ERROR: loader.conf default=cixmini-lts* but no cixmini-lts*.conf in entries/" >&2
        ls /boot/efi/loader/entries/ 2>&1 | sed 's/^/  /'
        exit 1
    fi
else
    if ! [ -f "/boot/efi/loader/entries/${DEFAULT_ENTRY}.conf" ]; then
        echo "ERROR: loader.conf default=$DEFAULT_ENTRY but ${DEFAULT_ENTRY}.conf not in entries/" >&2
        exit 1
    fi
fi
echo "  loader.conf default resolves to a real entry — verified"

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

# UEFI NVRAM fallback per 2026-05-04 codex review: some UEFI implementations
# (esp. older firmware) don't persist NVRAM entries written via efibootmgr.
# Drop a copy of systemd-bootaa64.efi at the canonical removable-media fallback
# path /EFI/BOOT/BOOTAA64.EFI so the device boots even with empty BootOrder.
if [ -f /boot/efi/EFI/systemd/systemd-bootaa64.efi ]; then
    install -D -m 0644 /boot/efi/EFI/systemd/systemd-bootaa64.efi \
        /boot/efi/EFI/BOOT/BOOTAA64.EFI
    echo "  /EFI/BOOT/BOOTAA64.EFI fallback installed (NVRAM-independent boot)"
else
    echo "  WARN: /boot/efi/EFI/systemd/systemd-bootaa64.efi missing — no fallback installed"
fi

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
