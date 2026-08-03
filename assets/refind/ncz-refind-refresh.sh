#!/bin/bash
# ncz-refind-refresh — (re)generate the rEFInd ESP menu for whatever
# legacy/NEXT kernels are currently on disk.
#
# Shared by two callers, which differ only in HOW they determine which
# kernel versions to stage:
#   - post-install/70-bootloader.sh (install time): reads the static
#     KVER_LEGACY/KVER_NEXT sidecar files baked into the ISO.
#   - /etc/kernel/postinst.d/zz1-ncz-refind-refresh (post-install, any
#     future `apt install`/`apt upgrade` of linux-image-cixmini-*):
#     discovers KVER_LEGACY/KVER_NEXT dynamically from /boot/vmlinuz-*.
#
# Both callers export KVER_LEGACY, KVER_NEXT, BUILD_VERSION before invoking
# this script -- it does no sidecar-file reading of its own, so it works
# identically at install time and on a live, already-installed system.
#
# Extracted unchanged from 70-bootloader.sh (r118-r192 rEFInd logic) --
# see that file's own history/comments for why each piece exists.
set -euo pipefail

echo "[ncz-refind-refresh] rEFInd bootloader (staged kernel menu)"

INSTALLER_META=/usr/local/lib/cix-installer
REFIND_SRC="$INSTALLER_META/assets/refind/refind_aa64.efi"
: "${KVER_LEGACY:=}"
: "${KVER_NEXT:=}"
: "${BUILD_VERSION:=(unknown)}"
RELEASE_FILE=/etc/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE="$INSTALLER_META/RELEASE"
if [ ! -s "$RELEASE_FILE" ]; then
    echo "ERROR: NCZ release identity missing; refusing to write an ambiguously-versioned boot menu"
    exit 1
fi
# shellcheck disable=SC1090
. "$RELEASE_FILE"
NCZ_RELEASE_SHORT="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"

if [ -z "$KVER_LEGACY" ] && [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_LEGACY or KVER_NEXT provided"
    exit 1
fi

echo "  KVER_LEGACY=$KVER_LEGACY"
echo "  KVER_NEXT=${KVER_NEXT:-(not present)}"
echo "  BUILD_VERSION=$BUILD_VERSION"

# Prevent systemd-boot deb postinst from double-staging kernels to the ESP
mkdir -p /etc/kernel
echo "layout=other" > /etc/kernel/install.conf
echo "  /etc/kernel/install.conf set to layout=other (disables double-staging)"

if [ ! -s "$REFIND_SRC" ]; then
    echo "ERROR: rEFInd binary missing/empty at $REFIND_SRC"
    echo "       cannot install a bootloader."
    exit 1
fi
echo "  rEFInd binary present: $REFIND_SRC ($(du -h "$REFIND_SRC" | cut -f1))"
command -v efibootmgr >/dev/null 2>&1 || echo "  note: efibootmgr not present — relying on /EFI/BOOT/BOOTAA64.EFI fallback"

if ! findmnt -no FSTYPE /boot/efi >/dev/null 2>&1; then
    echo "ERROR: /boot/efi is not mounted — cannot install the bootloader."
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
echo "  /boot/efi is mounted (vfat) — proceeding with rEFInd install"

verify_payload_readable() {
    local label="$1"
    local path="$2"

    if [ ! -r "$path" ]; then
        echo "ERROR: $label payload $path is not readable."
        echo "       Refusing to wipe the ESP until the source payload can be staged."
        exit 1
    fi
    if ! dd if="$path" of=/dev/null bs=1M status=none; then
        echo "ERROR: failed read probe for $label payload $path."
        echo "       Refusing to wipe the ESP until the source payload can be copied."
        exit 1
    fi
}

LEGACY_PREFLIGHT_READY=0
NEXT_PREFLIGHT_READY=0
if [ -n "$KVER_LEGACY" ]; then
    if [ -s "/boot/vmlinuz-$KVER_LEGACY" ] && [ -s "/boot/initrd.img-$KVER_LEGACY" ]; then
        verify_payload_readable "legacy kernel" "/boot/vmlinuz-$KVER_LEGACY"
        verify_payload_readable "legacy initrd" "/boot/initrd.img-$KVER_LEGACY"
        LEGACY_PREFLIGHT_READY=1
        echo "  preflight OK: legacy kernel/initrd present and readable for $KVER_LEGACY"
    elif [ -s "/boot/vmlinuz-$KVER_LEGACY" ] && [ ! -s "/boot/initrd.img-$KVER_LEGACY" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LEGACY exists but /boot/initrd.img-$KVER_LEGACY is missing or empty."
        echo "       Refusing to wipe the ESP without a complete legacy kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_LEGACY" ]; then
        echo "ERROR: incomplete legacy kernel payload for $KVER_LEGACY."
        echo "       Need non-empty /boot/vmlinuz-$KVER_LEGACY and /boot/initrd.img-$KVER_LEGACY before ESP wipe."
        exit 1
    else
        echo "  WARN: legacy kernel payload for $KVER_LEGACY missing — legacy entry will be skipped"
    fi
fi
if [ -n "$KVER_NEXT" ]; then
    if [ -s "/boot/vmlinuz-$KVER_NEXT" ] && [ -s "/boot/initrd.img-$KVER_NEXT" ]; then
        verify_payload_readable "NEXT kernel" "/boot/vmlinuz-$KVER_NEXT"
        verify_payload_readable "NEXT initrd" "/boot/initrd.img-$KVER_NEXT"
        NEXT_PREFLIGHT_READY=1
        echo "  preflight OK: NEXT kernel/initrd present and readable for $KVER_NEXT"
    elif [ -s "/boot/vmlinuz-$KVER_NEXT" ] && [ ! -s "/boot/initrd.img-$KVER_NEXT" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_NEXT exists but /boot/initrd.img-$KVER_NEXT is missing or empty."
        echo "       Refusing to wipe the ESP without a complete NEXT kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_NEXT" ]; then
        echo "ERROR: incomplete NEXT kernel payload for $KVER_NEXT."
        echo "       Need non-empty /boot/vmlinuz-$KVER_NEXT and /boot/initrd.img-$KVER_NEXT before ESP wipe."
        exit 1
    else
        echo "  WARN: NEXT kernel payload for $KVER_NEXT missing — NEXT entry will be skipped"
    fi
fi
if [ "$LEGACY_PREFLIGHT_READY" = "0" ] && [ "$NEXT_PREFLIGHT_READY" = "0" ]; then
    echo "ERROR: no declared kernel has both a non-empty vmlinuz and initrd in /boot."
    echo "       Refusing to wipe the ESP because there is nothing bootable to restage."
    exit 1
fi
echo "  preflight OK: at least one complete declared kernel payload is present"

# Preflight (above) validated inputs under `set -euo pipefail`. The ESP is
# vfat (no ownership/perms). The write section below tolerates vfat quirks
# (cp ownership warnings, grep-no-match, best-effort efibootmgr). Under
# strict errexit/pipefail those non-fatal ops could abort BEFORE
# BOOTAA64.EFI was written -> unbootable. Relax here; the write section
# keeps its OWN explicit guards.
set +e +u +o pipefail

ROOT_SRC=$(findmnt -no SOURCE --nofsroot /)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC")
ROOT_FSTYPE=$(findmnt -no FSTYPE /)
ROOT_SUBVOL=""
if [ "$ROOT_FSTYPE" = "btrfs" ]; then
    ROOT_FSROOT=$(findmnt -no FSROOT / 2>/dev/null || echo "/")
    case "$ROOT_FSROOT" in
        ""|"/") ROOT_SUBVOL="" ;;
        *)      ROOT_SUBVOL="${ROOT_FSROOT#/}" ;;
    esac
fi
echo "  root source=$ROOT_SRC PARTUUID=$ROOT_PARTUUID fstype=$ROOT_FSTYPE subvol=${ROOT_SUBVOL:-(none)}"

# console: serial (ttyAMA0) FIRST so tty0 stays the primary /dev/console (last
# console= wins) — plymouth + the graphical greeter own tty0, while the on-board
# UART still gets kernel messages AND a serial-getty for lockout recovery
# (doctrine: serial console must work). NEXT drops the base panic=30 because
# NEXT_CMDLINE_EXTRA sets panic=6 (edge wants fast panic) — carrying both was a
# confusing duplicate on one cmdline.
LEGACY_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 efi=noruntime acpi=force systemd.condition_first_boot=false arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"
NEXT_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 efi=noruntime acpi=force systemd.condition_first_boot=false arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused module_blacklist=typec_rts5453,rts5453"

# The edge (NEXT) kernel needs board-specific PCIe/SCMI knobs that the stable
# kernel does not: the 7.2 forward-port was only ever metal-validated with
# these (r195 shipped edge WITHOUT them and the board hung at boot — the
# generic cmdline is NOT safe for 7.2 on Sky1). Also carve ramoops so an edge
# hang leaves a crash record, and prefer fast panic over a silent wedge.
NEXT_CMDLINE_EXTRA="pcie_aspm=off sky1_pcie_native=off pcie_pnp_en acpi_scmi_en=off loglevel=3 oops=panic panic=6 ramoops.mem_address=0x83d00000 ramoops.mem_size=0x100000 ramoops.record_size=0x40000 ramoops.console_size=0x80000 ramoops.ecc=0"
NEXT_CMDLINE_BASE="$NEXT_CMDLINE_BASE $NEXT_CMDLINE_EXTRA"

# Graphical-only cmdline (appended to the desktop entries, NOT rescue). Plymouth
# is not installed: the native KMS service paints after root is mounted, so the
# legacy `splash` flag only risks activating stale initramfs Plymouth wiring.
# loglevel=3 keeps known early Sky1 driver warnings/errors off the graphical VT
# while they remain fully available in dmesg, journal, pstore, and serial logs.
# Rescue intentionally remains verbose and keeps a normal cursor.
SPLASH="quiet loglevel=3 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false"
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootdelay=90 rootfstype=$ROOT_FSTYPE rw"
if [ -n "$ROOT_SUBVOL" ]; then
    ROOT_OPTS="$ROOT_OPTS rootflags=subvol=$ROOT_SUBVOL"
fi

echo "  wiping stale ESP entries + kernel images..."
rm -f /boot/efi/vmlinuz-*
rm -f /boot/efi/initrd.img-*
rm -rf /boot/efi/[0-9a-f]*  # Wipe 32-hex kernel-install machine-id dirs
rm -f /boot/efi/EFI/Linux/* 2>/dev/null
rm -rf /boot/efi/loader 2>/dev/null || true
rm -rf /boot/efi/EFI/systemd 2>/dev/null || true
rm -f /boot/efi/EFI/BOOT/refind.conf 2>/dev/null || true
echo "  ESP wiped — proceeding with kernel/initrd staging"

LEGACY_AVAILABLE=0
NEXT_AVAILABLE=0
LEGACY_INITRD_AVAILABLE=0
NEXT_INITRD_AVAILABLE=0

if [ -n "$KVER_LEGACY" ] && [ -s "/boot/vmlinuz-$KVER_LEGACY" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_LEGACY" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LEGACY exists but /boot/initrd.img-$KVER_LEGACY is missing or empty."
        echo "       Refusing to write a legacy loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_LEGACY" "/boot/efi/vmlinuz-$KVER_LEGACY"
    echo "  staged /boot/efi/vmlinuz-$KVER_LEGACY"
    LEGACY_AVAILABLE=1
    install -m 0644 "/boot/initrd.img-$KVER_LEGACY" "/boot/efi/initrd.img-$KVER_LEGACY"
    echo "  staged /boot/efi/initrd.img-$KVER_LEGACY"
    LEGACY_INITRD_AVAILABLE=1
elif [ -n "$KVER_LEGACY" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_LEGACY missing — legacy entry will be SKIPPED"
else
    echo "  legacy kernel not staged — skipping legacy fallback entry"
fi

if [ -n "$KVER_NEXT" ] && [ -s "/boot/vmlinuz-$KVER_NEXT" ]; then
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

if [ "$LEGACY_AVAILABLE" = "0" ] && [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: NEITHER kernel installed — system is unbootable."
    exit 1
fi

NEXT_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $NEXT_CMDLINE_BASE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"
fi

# NCZ-OS 26.7 GPU policy: 7.2 is the *only* graphical kernel.  It has two
# mutually exclusive DKMS driver choices.  The blacklist is part of each
# boot contract, not a user-selectable modprobe accident:
#   Mali DKMS       = blacklist Panthor
#   Panthor DKMS    = blacklist the complete Mali kbase stack
# Keep userspace Mesa in both modes so changing kernel driver never changes
# EGL/glvnd/ICD ownership during the greeter handoff.
MALI_OPTIONS=""
PANTHOR_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    MALI_OPTIONS=$(printf '%s' "$NEXT_OPTIONS" | sed 's/module_blacklist=typec_rts5453,rts5453/module_blacklist=typec_rts5453,rts5453,panthor/')
    PANTHOR_OPTIONS=$(printf '%s' "$NEXT_OPTIONS" | sed 's/module_blacklist=typec_rts5453,rts5453/module_blacklist=typec_rts5453,rts5453,mali_kbase,memory_group_manager,protected_memory_allocator/')
    # Panthor keeps acpi_scmi_en=off, same as Mali and SAFE. Metal-verified
    # on O6N 2026-07-31: the patched panthor-cix DKMS module powers on and
    # un-secures the GPU itself with SCMI off ("GPU power domain 21 powered
    # on via SMC SCMI" + "Sky1: GPU un-secured via ACPI power-supply (_PR0)",
    # then a clean Mali-G720 probe). Flipping acpi_scmi_en=on here was never
    # metal-proven, re-opens the known 7.2 Sky1 PCIe/NVMe boot-hang (the r195
    # regression this cmdline exists to prevent), and would run the kernel
    # SCMI stack alongside the module's raw-SMC power-on path.
fi

# Shared by both console entries (7.0.12 and 7.2): every CIX GPU/NPU/VPU
# driver is blacklisted.  The display pipeline (linlondp) is deliberately
# NOT in this list so tty0 stays usable on O6/O6N.
CONSOLE_EXTRA_BLACKLIST="panthor,panfrost,mali,mali_kbase,memory_group_manager,protected_memory_allocator,bifrost,armchina_npu,amvx,cix_vpu,linlon_vpu"

# 7.0.12 is deliberately a console-only recovery kernel. It is an EOL
# kernel we carry only until the 7.2 channel finishes its release
# process -- hence "legacy", not "LTS".  Do not expose a
# graphical or GPU variant of it: the legacy contract is a networked
# multi-user shell with every available CIX GPU driver blacklisted.  Keep the
# display pipeline out of this blacklist so tty0 remains usable on O6.
LEGACY_CONSOLE_OPTIONS=""
LEGACY_CONSOLE_CMDLINE=""
if [ "$LEGACY_AVAILABLE" = "1" ]; then
    LEGACY_CONSOLE_EXTRA_BLACKLIST="$CONSOLE_EXTRA_BLACKLIST"
    LEGACY_CONSOLE_EXISTING_BL=$(printf '%s\n' "$LEGACY_CMDLINE_BASE" | tr ' ' '\n' | sed -n 's/^module_blacklist=//p' | paste -sd, -)
    LEGACY_CONSOLE_CMDLINE_NOBL=$(printf '%s\n' "$LEGACY_CMDLINE_BASE" | tr ' ' '\n' | grep -vE '^(module_blacklist=|$)' | paste -sd' ' -)
    [ -n "$LEGACY_CONSOLE_EXISTING_BL" ] && LEGACY_CONSOLE_MERGED_BL="$LEGACY_CONSOLE_EXISTING_BL,$LEGACY_CONSOLE_EXTRA_BLACKLIST" || LEGACY_CONSOLE_MERGED_BL="$LEGACY_CONSOLE_EXTRA_BLACKLIST"
    LEGACY_CONSOLE_CMDLINE="$LEGACY_CONSOLE_CMDLINE_NOBL module_blacklist=$LEGACY_CONSOLE_MERGED_BL"
    LEGACY_CONSOLE_OPTIONS="$ROOT_OPTS $LEGACY_CONSOLE_CMDLINE systemd.unit=multi-user.target"
fi

# 7.2 CONSOLE — same console-only contract as the 7.0.12 entry, but on the
# 7.2 kernel.  Purpose: reach a networked multi-user shell on the SHIPPING
# kernel when the graphical handoff fails (greeter/DKMS/Mesa), without
# falling back to the 7.0.12 recovery kernel.  No splash: this entry must
# stay verbose so a boot failure is diagnosable on ttyAMA0/tty0.
NEXT_CONSOLE_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_CONSOLE_EXISTING_BL=$(printf '%s\n' "$NEXT_CMDLINE_BASE" | tr ' ' '\n' | sed -n 's/^module_blacklist=//p' | paste -sd, -)
    NEXT_CONSOLE_CMDLINE_NOBL=$(printf '%s\n' "$NEXT_CMDLINE_BASE" | tr ' ' '\n' | grep -vE '^(module_blacklist=|$)' | paste -sd' ' -)
    [ -n "$NEXT_CONSOLE_EXISTING_BL" ] && NEXT_CONSOLE_MERGED_BL="$NEXT_CONSOLE_EXISTING_BL,$CONSOLE_EXTRA_BLACKLIST" || NEXT_CONSOLE_MERGED_BL="$CONSOLE_EXTRA_BLACKLIST"
    NEXT_CONSOLE_CMDLINE="$NEXT_CONSOLE_CMDLINE_NOBL module_blacklist=$NEXT_CONSOLE_MERGED_BL"
    NEXT_CONSOLE_OPTIONS="$ROOT_OPTS $NEXT_CONSOLE_CMDLINE systemd.unit=multi-user.target"
fi

RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_OPTIONS=""
if [ -f "$RESCUE_READY" ] && [ "$LEGACY_AVAILABLE" = "1" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
    if [ -n "$RESCUEPART_PARTUUID" ]; then
        RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootdelay=90 rootfstype=ext4 rw $LEGACY_CONSOLE_CMDLINE systemd.unit=multi-user.target"
        echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — adding console-only rEFInd rescue-partition entry"
    else
        echo "ERROR: rescue-partition marker has no PARTUUID — refusing to ship without recovery"
        exit 1
    fi
else
    echo "ERROR: 7.0.12 rescue partition is required but marker $RESCUE_READY or legacy kernel is absent"
    exit 1
fi

install -d -m 0755 /boot/efi/EFI/BOOT
install -m 0644 "$REFIND_SRC" /boot/efi/EFI/BOOT/BOOTAA64.EFI
if [ ! -s /boot/efi/EFI/BOOT/BOOTAA64.EFI ]; then
    echo "ERROR: failed to install rEFInd to /boot/efi/EFI/BOOT/BOOTAA64.EFI"
    exit 1
fi
echo "  rEFInd installed → /boot/efi/EFI/BOOT/BOOTAA64.EFI (firmware fallback path)"

BANNER_SRC="$INSTALLER_META/assets/refind/ncz-banner.png"
REFIND_BANNER=""
if [ -s "$BANNER_SRC" ]; then
    install -m 0644 "$BANNER_SRC" /boot/efi/EFI/BOOT/ncz-banner.png
    REFIND_BANNER="ncz-banner.png"
    echo "  rEFInd banner installed → /boot/efi/EFI/BOOT/ncz-banner.png"
else
    echo "  note: rEFInd banner asset absent ($BANNER_SRC) — using default rEFInd art"
fi

ICON_SRC="$INSTALLER_META/assets/refind/ncz.png"
REFIND_ICON=""
if [ -s "$ICON_SRC" ]; then
    install -m 0644 "$ICON_SRC" /boot/efi/EFI/BOOT/ncz.png
    REFIND_ICON="ncz.png"
    echo "  rEFInd entry icon installed → /boot/efi/EFI/BOOT/ncz.png"
fi

ICONS_SRC="$INSTALLER_META/assets/refind/icons"
if [ -d "$ICONS_SRC" ]; then
    rm -rf /boot/efi/EFI/BOOT/icons
    cp -r "$ICONS_SRC" /boot/efi/EFI/BOOT/icons
    echo "  rEFInd icons/ installed → /boot/efi/EFI/BOOT/icons ($(ls /boot/efi/EFI/BOOT/icons 2>/dev/null | wc -l | tr -d ' ') files)"
else
    echo "  WARN: rEFInd icons/ asset absent ($ICONS_SRC) → menu will render TEXT-ONLY (no banner)"
fi

# Release policy: 7.2 Mali is the default graphical entry.  7.0.12 is always
# an explicit console-only recovery choice; Panthor is an explicit experiment.
if [ "$NEXT_AVAILABLE" = "1" ]; then
    DEFAULT_TOKEN="Mali"
elif [ "$LEGACY_AVAILABLE" = "1" ]; then
    DEFAULT_TOKEN="console"
else
    DEFAULT_TOKEN="edge"
fi

REFIND_CONF=/boot/efi/EFI/BOOT/refind.conf
{
    echo "# rEFInd — NCZ cixmini $BUILD_VERSION (generated by ncz-refind-refresh)"
    echo "# Kernels live on the FAT ESP; each kernel's initramfs mounts the"
    echo "# $ROOT_FSTYPE root. No btrfs/ext4 EFI driver is required."
    echo "timeout 10"
    echo "log_level 0"
    echo "use_nvram false"
    echo "resolution max"
    [ -n "$REFIND_BANNER" ] && echo "banner $REFIND_BANNER"
    [ -n "$REFIND_BANNER" ] && echo "banner_scale noscale"
    echo "showtools shell,reboot,shutdown,firmware"
    echo "scanfor manual"
    echo "scan_all_linux_kernels false"
    echo "default_selection \"$DEFAULT_TOKEN\""
    echo
    if [ "$LEGACY_AVAILABLE" = "1" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.0.12 CONSOLE — legacy fallback, no GPU, no GUI\" {"
        echo "    loader  /vmlinuz-$KVER_LEGACY"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$LEGACY_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_LEGACY"
        echo "    options \"$LEGACY_CONSOLE_OPTIONS\""
        echo "}"
        echo
    fi

    if [ "$NEXT_AVAILABLE" = "1" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 MALI DKMS — graphical [DEFAULT]\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$MALI_OPTIONS\""
        echo "}"
        echo
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 PANTHOR DKMS — graphical [EXPERIMENTAL]\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$PANTHOR_OPTIONS\""
        echo "}"
        echo
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 CONSOLE — networked, no GPU, no GUI\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$NEXT_CONSOLE_OPTIONS\""
        echo "}"
        echo
    fi
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.0.12 RESCUE PARTITION — legacy, console, automatic networking\" {"
        echo "    loader  /vmlinuz-$KVER_LEGACY"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$LEGACY_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_LEGACY"
        echo "    options \"$RESCUEPART_OPTIONS\""
        echo "}"
        echo
    fi
} > "$REFIND_CONF"
echo "  wrote $REFIND_CONF (default_selection=$DEFAULT_TOKEN)"

if command -v efibootmgr >/dev/null 2>&1; then
    EFI_DEV=$(findmnt -no SOURCE /boot/efi)
    EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV" 2>/dev/null || true)
    EFI_PART="${EFI_DEV##*[!0-9]}"
    if [ -n "$EFI_DISK" ] && [ -n "$EFI_PART" ]; then
        efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
            -L "nclawzero (rEFInd)" -l '\EFI\BOOT\BOOTAA64.EFI' >/dev/null 2>&1 || true
    fi
fi

echo ""
echo "===== rEFInd installed — refind.conf ====="
cat "$REFIND_CONF"
echo ""
echo "ESP contents:"
ls -la /boot/efi/ 2>&1 | sed 's/^/  /' | head -25
echo "  EFI/BOOT:"
ls -la /boot/efi/EFI/BOOT/ 2>&1 | sed 's/^/    /'
