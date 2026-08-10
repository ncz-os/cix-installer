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
RELEASE_FILE=/etc/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE="$INSTALLER_META/RELEASE"
if [ ! -s "$RELEASE_FILE" ]; then
    echo "ERROR: NCZ release identity missing; refusing to write an ambiguously-versioned boot menu"
    exit 1
fi
# shellcheck disable=SC1090
. "$RELEASE_FILE"
NCZ_RELEASE_SHORT="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"

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

# console: serial (ttyAMA0) FIRST so tty0 stays the primary /dev/console (last
# console= wins) — plymouth + the graphical greeter own tty0, while the on-board
# UART still gets kernel messages AND a serial-getty for lockout recovery
# (doctrine: serial console must work). NEXT drops the base panic=30 because
# NEXT_CMDLINE_EXTRA sets panic=6 (edge wants fast panic) — carrying both was a
# confusing duplicate on one cmdline.
LTS_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 efi=noruntime acpi=force systemd.condition_first_boot=false arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"
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

# NCZ-OS 26.7: 7.2 ACROSS THE BOARD.  The image ships ONE kernel and every menu
# entry boots it; there is no second kernel series to fall back to.  7.0.12 was
# retired as the fallback because it is EOL and no longer even listed on
# kernel.org, and 7.1.x was rejected as a replacement because it is `stable`,
# not `longterm` -- it goes EOL shortly after 7.2 releases, which would buy
# weeks of maintenance for a full port.  The rescue path is the SAME kernel with
# the accelerators blacklisted, not a different kernel.
#
# Prefer the stable slot; fall back to edge only if stable is absent.
if [ "$LTS_AVAILABLE" = "1" ]; then
    MAIN_KVER="$KVER_LTS"; MAIN_INITRD="$LTS_INITRD_AVAILABLE"
else
    MAIN_KVER="$KVER_NEXT"; MAIN_INITRD="$NEXT_INITRD_AVAILABLE"
fi
# Display label derived from the kernel, never hardcoded: the previous menu said
# "7.0.12" and "7.2" in literal strings, which silently went stale the moment the
# slots were repointed.
MAIN_VER=$(printf '%s' "$MAIN_KVER" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
[ -n "$MAIN_VER" ] || MAIN_VER="$MAIN_KVER"
echo "  single-kernel menu: $MAIN_KVER (label \"$MAIN_VER\")"

# NCZ-OS 26.7 boot contract — three entries, ONE kernel:
#
#   Singularity        graphical, Mali DKMS (panthor blacklisted)
#   Console            SAME accelerators, no GUI (multi-user.target)
#   Rescue Partition   accelerators OFF, separate recovery rootfs
#
# Console deliberately keeps the accelerators ENABLED: it is a no-GUI shell for
# working on a machine whose desktop is broken, and the VPU/NPU/GPU are exactly
# what an operator needs to test there.  Only the rescue partition strips them,
# because that is the path that has to come up when a driver is what is wrong.
#
# Mali and Panthor are mutually exclusive DKMS stacks; the blacklist is part of
# the boot contract, not a modprobe accident. Userspace Mesa stays in both modes
# so the kernel driver choice never changes EGL/glvnd/ICD ownership across the
# greeter handoff.
MAIN_BASE="$NEXT_CMDLINE_BASE"
[ "$LTS_AVAILABLE" = "1" ] && [ "$NEXT_AVAILABLE" = "0" ] && MAIN_BASE="$LTS_CMDLINE_BASE"

# Accelerators ON (blacklist only the competing GPU stack).
ACCEL_ON_BL="panthor"
# Accelerators OFF (rescue): every CIX accelerator driver. The DISPLAY pipeline
# is deliberately NOT blacklisted so tty0 stays usable on O6.
ACCEL_OFF_BL="panthor,panfrost,mali,mali_kbase,memory_group_manager,protected_memory_allocator,bifrost,armchina_npu,amvx,cix_vpu,linlon_vpu"

# merge_bl <cmdline> <extra>  -> cmdline with extra appended to module_blacklist=
merge_bl() {
    _cl="$1"; _extra="$2"
    _existing=$(printf '%s\n' "$_cl" | tr ' ' '\n' | sed -n 's/^module_blacklist=//p' | paste -sd, -)
    _nobl=$(printf '%s\n' "$_cl" | tr ' ' '\n' | grep -vE '^(module_blacklist=|$)' | paste -sd' ' -)
    if [ -n "$_existing" ]; then printf '%s module_blacklist=%s' "$_nobl" "$_existing,$_extra"
    else printf '%s module_blacklist=%s' "$_nobl" "$_extra"; fi
}

ACCEL_ON_CMDLINE=$(merge_bl "$MAIN_BASE" "$ACCEL_ON_BL")
ACCEL_OFF_CMDLINE=$(merge_bl "$MAIN_BASE" "$ACCEL_OFF_BL")

SINGULARITY_OPTIONS="$ROOT_OPTS $ACCEL_ON_CMDLINE"
[ -n "$SPLASH" ] && SINGULARITY_OPTIONS="$SINGULARITY_OPTIONS $SPLASH"
CONSOLE_OPTIONS="$ROOT_OPTS $ACCEL_ON_CMDLINE systemd.unit=multi-user.target"

RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_OPTIONS=""
if [ -f "$RESCUE_READY" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
    if [ -n "$RESCUEPART_PARTUUID" ]; then
        # Same kernel as every other entry, accelerators OFF. This is the only
        # entry that strips them, so a broken GPU/VPU/NPU driver still lands a
        # networked shell.
        RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootdelay=90 rootfstype=ext4 rw $ACCEL_OFF_CMDLINE systemd.unit=multi-user.target"
        echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — accelerators blacklisted"
    else
        echo "ERROR: rescue-partition marker has no PARTUUID — refusing to ship without recovery"
        exit 1
    fi
else
    echo "ERROR: rescue partition is required but marker $RESCUE_READY is absent"
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

# Release policy: the graphical Singularity entry is the default.  rEFInd matches
# default_selection as a SUBSTRING of the menu title, so this token must appear
# in one -- the previous value was "Mali", which after the 7.2-across-the-board
# retitle matched NO entry at all and would have silently fallen through to
# whatever rEFInd listed first.
DEFAULT_TOKEN="Singularity"

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
    echo "menuentry \"$NCZ_RELEASE_SHORT  ·  $MAIN_VER Singularity\" {"
    echo "    loader  /vmlinuz-$MAIN_KVER"
    [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
    [ "$MAIN_INITRD" = "1" ] && echo "    initrd  /initrd.img-$MAIN_KVER"
    echo "    options \"$SINGULARITY_OPTIONS\""
    echo "}"
    echo
    echo "menuentry \"$NCZ_RELEASE_SHORT  ·  $MAIN_VER Console\" {"
    echo "    loader  /vmlinuz-$MAIN_KVER"
    [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
    [ "$MAIN_INITRD" = "1" ] && echo "    initrd  /initrd.img-$MAIN_KVER"
    echo "    options \"$CONSOLE_OPTIONS\""
    echo "}"
    echo
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  $MAIN_VER Rescue Partition\" {"
        echo "    loader  /vmlinuz-$MAIN_KVER"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$MAIN_INITRD" = "1" ] && echo "    initrd  /initrd.img-$MAIN_KVER"
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
