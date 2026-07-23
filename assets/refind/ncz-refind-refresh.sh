#!/bin/bash
# ncz-refind-refresh — (re)generate the rEFInd ESP menu for whatever
# LTS/NEXT kernels are currently on disk.
#
# Shared by two callers, which differ only in HOW they determine which
# kernel versions to stage:
#   - post-install/70-bootloader.sh (install time): reads the static
#     KVER_LTS/KVER_NEXT sidecar files baked into the ISO.
#   - /etc/kernel/postinst.d/zz1-ncz-refind-refresh (post-install, any
#     future `apt install`/`apt upgrade` of linux-image-cixmini-*):
#     discovers KVER_LTS/KVER_NEXT dynamically from /boot/vmlinuz-*.
#
# Both callers export KVER_LTS, KVER_NEXT, BUILD_VERSION before invoking
# this script -- it does no sidecar-file reading of its own, so it works
# identically at install time and on a live, already-installed system.
#
# Extracted unchanged from 70-bootloader.sh (r118-r192 rEFInd logic) --
# see that file's own history/comments for why each piece exists.
set -euo pipefail

echo "[ncz-refind-refresh] rEFInd bootloader (staged kernel menu)"

INSTALLER_META=/usr/local/lib/cix-installer
REFIND_SRC="$INSTALLER_META/assets/refind/refind_aa64.efi"
: "${KVER_LTS:=}"
: "${KVER_NEXT:=}"
: "${BUILD_VERSION:=(unknown)}"

if [ -z "$KVER_LTS" ] && [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_LTS or KVER_NEXT provided"
    exit 1
fi

echo "  KVER_LTS=$KVER_LTS"
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

LTS_PREFLIGHT_READY=0
NEXT_PREFLIGHT_READY=0
if [ -n "$KVER_LTS" ]; then
    if [ -s "/boot/vmlinuz-$KVER_LTS" ] && [ -s "/boot/initrd.img-$KVER_LTS" ]; then
        verify_payload_readable "LTS kernel" "/boot/vmlinuz-$KVER_LTS"
        verify_payload_readable "LTS initrd" "/boot/initrd.img-$KVER_LTS"
        LTS_PREFLIGHT_READY=1
        echo "  preflight OK: LTS kernel/initrd present and readable for $KVER_LTS"
    elif [ -s "/boot/vmlinuz-$KVER_LTS" ] && [ ! -s "/boot/initrd.img-$KVER_LTS" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LTS exists but /boot/initrd.img-$KVER_LTS is missing or empty."
        echo "       Refusing to wipe the ESP without a complete LTS kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_LTS" ]; then
        echo "ERROR: incomplete LTS kernel payload for $KVER_LTS."
        echo "       Need non-empty /boot/vmlinuz-$KVER_LTS and /boot/initrd.img-$KVER_LTS before ESP wipe."
        exit 1
    else
        echo "  WARN: LTS kernel payload for $KVER_LTS missing — LTS entry will be skipped"
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
if [ "$LTS_PREFLIGHT_READY" = "0" ] && [ "$NEXT_PREFLIGHT_READY" = "0" ]; then
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

LTS_CMDLINE_BASE="console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"
NEXT_CMDLINE_BASE="console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"

# The edge (NEXT) kernel needs board-specific PCIe/SCMI knobs that the stable
# kernel does not: the 7.2 forward-port was only ever metal-validated with
# these (r195 shipped edge WITHOUT them and the board hung at boot — the
# generic cmdline is NOT safe for 7.2 on Sky1). Also carve ramoops so an edge
# hang leaves a crash record, and prefer fast panic over a silent wedge.
NEXT_CMDLINE_EXTRA="pcie_aspm=off sky1_pcie_native=off pcie_pnp_en acpi_scmi_en=off loglevel=3 oops=panic panic=6 ramoops.mem_address=0x83d00000 ramoops.mem_size=0x100000 ramoops.record_size=0x40000 ramoops.console_size=0x80000 ramoops.ecc=0"
NEXT_CMDLINE_BASE="$NEXT_CMDLINE_BASE $NEXT_CMDLINE_EXTRA"

SPLASH="quiet splash"
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

LTS_AVAILABLE=0
NEXT_AVAILABLE=0
LTS_INITRD_AVAILABLE=0
NEXT_INITRD_AVAILABLE=0

if [ -n "$KVER_LTS" ] && [ -s "/boot/vmlinuz-$KVER_LTS" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_LTS" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LTS exists but /boot/initrd.img-$KVER_LTS is missing or empty."
        echo "       Refusing to write an LTS loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_LTS" "/boot/efi/vmlinuz-$KVER_LTS"
    echo "  staged /boot/efi/vmlinuz-$KVER_LTS"
    LTS_AVAILABLE=1
    install -m 0644 "/boot/initrd.img-$KVER_LTS" "/boot/efi/initrd.img-$KVER_LTS"
    echo "  staged /boot/efi/initrd.img-$KVER_LTS"
    LTS_INITRD_AVAILABLE=1
elif [ -n "$KVER_LTS" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_LTS missing — LTS entry will be SKIPPED"
else
    echo "  LTS kernel not staged — skipping LTS fallback entry"
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

if [ "$LTS_AVAILABLE" = "0" ] && [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: NEITHER kernel installed — system is unbootable."
    exit 1
fi

LTS_OPTIONS=""
if [ "$LTS_AVAILABLE" = "1" ]; then
    LTS_OPTIONS="$ROOT_OPTS $LTS_CMDLINE_BASE"
    [ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"
fi

NEXT_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $NEXT_CMDLINE_BASE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"
fi

# 26.7 dual GPU stack — ONE 7.2 kernel image (both GPU drivers built in), two
# boot entries differing only by which GPU kernel driver is blacklisted:
#   Mali    = blacklist panthor    -> mali_kbase (DKMS) binds  -> libmali OpenCL
#   Panthor = blacklist mali_kbase -> panthor (in-tree) binds   -> Mesa/PanVK Vulkan
# Userspace stays Mesa in BOTH modes — no per-boot EGL/glvnd/ICD swap, so we
# never repeat the libEGL_cix greeter wedge (2026-07-22). Panthor mode gets
# hardware GL + Vulkan 1.4 via Mesa/PanVK on the panthor DRM node; Mali mode
# renders the desktop on llvmpipe (software) and exposes libmali OpenCL for GPU
# compute. Both are functional; Mali is default per 26.7 policy (mali primary,
# panthor fallback). The kbase trio (mali_kbase + memory_group_manager +
# protected_memory_allocator) is blacklisted together for a clean Panthor bind.
MALI_OPTIONS=""
PANTHOR_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    MALI_OPTIONS=$(printf '%s' "$NEXT_OPTIONS" | sed 's/module_blacklist=typec_rts5453,rts5453/module_blacklist=typec_rts5453,rts5453,panthor/')
    PANTHOR_OPTIONS=$(printf '%s' "$NEXT_OPTIONS" | sed 's/module_blacklist=typec_rts5453,rts5453/module_blacklist=typec_rts5453,rts5453,mali_kbase,memory_group_manager,protected_memory_allocator/')
fi

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

RESCUE_PIN=""
RESCUE_OPTIONS=""
RESCUE_HAS_INITRD=0
if [ -n "$RESCUE_KVER" ]; then
    RESCUE_PIN="${RESCUE_KVER}-rescue"
    if [ ! -s "/boot/efi/vmlinuz-$RESCUE_KVER" ]; then
        echo "ERROR: /boot/efi/vmlinuz-$RESCUE_KVER is missing or empty — cannot pin a clean rescue kernel."
        exit 1
    fi
    install -m 0644 "/boot/efi/vmlinuz-$RESCUE_KVER" "/boot/efi/vmlinuz-$RESCUE_PIN"
    echo "  staged pinned clean/rescue kernel /boot/efi/vmlinuz-$RESCUE_PIN"
    if { [ "$RESCUE_KVER" = "$KVER_LTS" ] && [ "$LTS_INITRD_AVAILABLE" = "1" ]; } || \
       { [ "$RESCUE_KVER" = "$KVER_NEXT" ] && [ "$NEXT_INITRD_AVAILABLE" = "1" ]; }; then
        install -m 0644 "/boot/efi/initrd.img-$RESCUE_KVER" "/boot/efi/initrd.img-$RESCUE_PIN"
        echo "  staged pinned clean/rescue initrd /boot/efi/initrd.img-$RESCUE_PIN"
        RESCUE_HAS_INITRD=1
    fi

    RESCUE_EXTRA_BLACKLIST="armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu,trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display"
    RESCUE_EXISTING_BL=$(printf '%s\n' "$RESCUE_CMDLINE_BASE" \
        | tr ' ' '\n' | sed -n 's/^module_blacklist=//p' | paste -sd, -)
    RESCUE_CMDLINE_NOBL=$(printf '%s\n' "$RESCUE_CMDLINE_BASE" \
        | tr ' ' '\n' | grep -vE '^(module_blacklist=|$)' | paste -sd' ' -)
    if [ -n "$RESCUE_EXISTING_BL" ]; then
        RESCUE_MERGED_BL="$RESCUE_EXISTING_BL,$RESCUE_EXTRA_BLACKLIST"
    else
        RESCUE_MERGED_BL="$RESCUE_EXTRA_BLACKLIST"
    fi
    RESCUE_CMDLINE_SAFE="$RESCUE_CMDLINE_NOBL module_blacklist=$RESCUE_MERGED_BL"
    RESCUE_OPTIONS="$ROOT_OPTS $RESCUE_CMDLINE_SAFE systemd.unit=rescue.target"
fi

RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_OPTIONS=""
if [ -f "$RESCUE_READY" ] && [ "$LTS_AVAILABLE" = "1" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
    if [ -n "$RESCUEPART_PARTUUID" ]; then
        RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootdelay=90 rootfstype=ext4 rw $LTS_CMDLINE_BASE"
        echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — adding rEFInd rescuepart entry (LTS + normal display cmdline)"
    else
        echo "  rescue-partition marker present but no PARTUUID — skipping rescuepart entry"
    fi
else
    echo "  no rescue-partition marker ($RESCUE_READY) or no LTS kernel — skipping rescuepart entry"
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

# 26.7 policy: default to the 7.2 (Mali) entry — 26.7 IS the 7.2 release, so
# 7.2 boots by default; 7.0.12 stays as "stable" fallback + rescue partition.
# If 7.2 is somehow absent, fall back to stable. Both remain one arrow-key away
# (10s timeout). The token "Mali" uniquely matches the 7.2 (Mali) menuentry
# title (absent from stable/panthor/rescue titles), so default_selection is
# unambiguous — the rEFInd-ambiguity boot failure mode does not apply here.
if [ "$NEXT_AVAILABLE" = "1" ]; then
    DEFAULT_TOKEN="Mali"
elif [ "$LTS_AVAILABLE" = "1" ]; then
    DEFAULT_TOKEN="stable"
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
    if [ "$LTS_AVAILABLE" = "1" ]; then
        echo "menuentry \"NCZ-OS 26.7  ·  stable — kernel $KVER_LTS\" {"
        echo "    loader  /vmlinuz-$KVER_LTS"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$LTS_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_LTS"
        echo "    options \"$LTS_OPTIONS\""
        echo "}"
        echo
    fi
    if [ "$NEXT_AVAILABLE" = "1" ]; then
        # 26.7 ships Mali-only. The 7.2 (Panthor) entry is DELIBERATELY not
        # emitted: panthor on 7.2 hangs at boot flooding "IDM: GPU secure
        # access" — with acpi_scmi_en=off (required for PCIe/nvme) the SCMI
        # power-domain that un-secures the GPU is unavailable, so panthor
        # touches a secured GPU (metal-confirmed 2026-07-22). The clock
        # con_id fix (patch 0086) is in-tree and correct, but the GPU
        # power-domain work is a follow-up UPDATE, which re-adds this entry.
        # PANTHOR_OPTIONS is still computed above so the update only needs to
        # restore the menuentry once the power-domain fix lands.
        echo "menuentry \"NCZ-OS 26.7  ·  7.2 (Mali) — kernel $KVER_NEXT [DEFAULT]\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$MALI_OPTIONS\""
        echo "}"
        echo
    fi
    if [ -n "$RESCUE_PIN" ]; then
        echo "menuentry \"NCZ-OS 26.7  ·  rescue — $RESCUE_PIN (safe: no NPU/GPU/VPU/KMS)\" {"
        echo "    loader  /vmlinuz-$RESCUE_PIN"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$RESCUE_HAS_INITRD" = "1" ] && echo "    initrd  /initrd.img-$RESCUE_PIN"
        echo "    options \"$RESCUE_OPTIONS\""
        echo "}"
        echo
    fi
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        echo "menuentry \"NCZ-OS 26.7  ·  RESCUE PARTITION — stable $KVER_LTS, full toolset (telnet/dropbear/ssh)\" {"
        echo "    loader  /vmlinuz-$KVER_LTS"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$LTS_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_LTS"
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
