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
# ncz-refind-refresh — (re)generate the rEFInd ESP menu for whatever
# edge kernel is currently on disk.
#
# Shared by two callers, which differ only in HOW they determine which
# kernel version to stage:
#   - post-install/70-bootloader.sh (install time): reads the static
#     KVER_NEXT sidecar file baked into the ISO.
#   - /etc/kernel/postinst.d/zz1-ncz-refind-refresh (post-install, any
#     future `apt install`/`apt upgrade` of linux-image-cixmini):
#     discovers KVER_NEXT dynamically from /boot/vmlinuz-*.
#
# Both callers export KVER_NEXT, BUILD_VERSION before invoking
# this script -- it does no sidecar-file reading of its own, so it works
# identically at install time and on a live, already-installed system.
#
# Extracted unchanged from 70-bootloader.sh (r118-r192 rEFInd logic) --
# see that file's own history/comments for why each piece exists.
set -euo pipefail

echo "[ncz-refind-refresh] rEFInd bootloader (staged kernel menu)"

INSTALLER_META=/usr/local/lib/cix-installer
REFIND_SRC="$INSTALLER_META/assets/refind/refind_aa64.efi"
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

if [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_NEXT provided (edge kernel is the only supported channel)"
    exit 1
fi

echo "  KVER_NEXT=$KVER_NEXT"
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

NEXT_PREFLIGHT_READY=0
if [ -n "$KVER_NEXT" ]; then
    if [ -s "/boot/vmlinuz-$KVER_NEXT" ] && [ -s "/boot/initrd.img-$KVER_NEXT" ]; then
        verify_payload_readable "edge kernel" "/boot/vmlinuz-$KVER_NEXT"
        verify_payload_readable "edge initrd" "/boot/initrd.img-$KVER_NEXT"
        NEXT_PREFLIGHT_READY=1
        echo "  preflight OK: edge kernel/initrd present and readable for $KVER_NEXT"
    elif [ -s "/boot/vmlinuz-$KVER_NEXT" ] && [ ! -s "/boot/initrd.img-$KVER_NEXT" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_NEXT exists but /boot/initrd.img-$KVER_NEXT is missing or empty."
        echo "       Refusing to wipe the ESP without a complete edge kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_NEXT" ]; then
        echo "ERROR: incomplete edge kernel payload for $KVER_NEXT."
        echo "       Need non-empty /boot/vmlinuz-$KVER_NEXT and /boot/initrd.img-$KVER_NEXT before ESP wipe."
        exit 1
    else
        echo "  WARN: edge kernel payload for $KVER_NEXT missing — edge entry will be skipped"
    fi
fi
if [ "$NEXT_PREFLIGHT_READY" = "0" ]; then
    echo "ERROR: no edge kernel has both a non-empty vmlinuz and initrd in /boot."
    echo "       Refusing to wipe the ESP because there is nothing bootable to restage."
    exit 1
fi
echo "  preflight OK: edge kernel payload is present"

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
# (doctrine: serial console must work). The edge cmdline drops the base
# panic=30 because NEXT_CMDLINE_EXTRA sets panic=6 (edge wants fast panic) —
# carrying both was a confusing duplicate on one cmdline.
NEXT_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 $EFI_RT_WORKAROUND acpi=force systemd.condition_first_boot=false arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused module_blacklist=typec_rts5453,rts5453"

# The edge (NEXT) kernel needs board-specific PCIe/SCMI knobs that the stable
# kernel does not: the 7.2 forward-port was only ever metal-validated with
# these (r195 shipped edge WITHOUT them and the board hung at boot — the
# generic cmdline is NOT safe for 7.2 on Sky1). Also carve ramoops so an edge
# hang leaves a crash record, and prefer fast panic over a silent wedge.
NEXT_CMDLINE_EXTRA="pcie_aspm=off sky1_pcie_native=off pcie_pnp_en acpi_scmi_en=off loglevel=3 oops=panic panic=6 ramoops.mem_address=0x83d00000 ramoops.mem_size=0x100000 ramoops.record_size=0x40000 ramoops.console_size=0x80000 ramoops.ecc=0"
NEXT_CMDLINE_BASE="$NEXT_CMDLINE_BASE $NEXT_CMDLINE_EXTRA"

merge_module_blacklist() {
    _cmdline=$1
    _extra=$2
    case " $_cmdline " in
        *" module_blacklist="*)
            _prefix=${_cmdline%%module_blacklist=*}
            _rest=${_cmdline#*module_blacklist=}
            _blacklist=${_rest%% *}
            _suffix=${_rest#"$_blacklist"}
            printf '%smodule_blacklist=%s,%s%s\n' "$_prefix" "$_extra" "$_blacklist" "$_suffix"
            ;;
        *)
            printf '%s module_blacklist=%s\n' "$_cmdline" "$_extra"
            ;;
    esac
}

# Graphical-only cmdline (appended to the desktop entries, NOT rescue). Plymouth
# is not installed: the native KMS service paints after root is mounted, so the
# legacy `splash` flag only risks activating stale initramfs Plymouth wiring.
# loglevel=3 keeps known early Sky1 driver warnings/errors off the graphical VT
# while they remain fully available in dmesg, journal, pstore, and serial logs.
# Rescue intentionally remains verbose and keeps a normal cursor.
SPLASH="quiet loglevel=3 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false"
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

# No rootdelay= here: the ncz-rootdelay initramfs hook gives scripts/local a
# 90s poll-timeout FALLBACK without the unconditional init:235 sleep that
# rootdelay= on the cmdline costs every boot (measured: 94s -> 3.6s to GPU
# probe on O6N). The rescue entry uses rootwait alone for the same reason.
ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=$ROOT_FSTYPE rw"
if [ -n "$ROOT_SUBVOL" ]; then
    ROOT_OPTS="$ROOT_OPTS rootflags=subvol=$ROOT_SUBVOL"
fi

echo "  wiping stale ESP entries + kernel images..."
# PRESERVE OPERATOR-STAGED RESCUE KERNELS (/boot/efi/vmlinuz-<tag>-rescue).
#
# WHY (2026-08-18, measured on O6N): every menuentry this script emits points at
# the SAME /vmlinuz-$KVER_NEXT, so a same-kver kernel upgrade repoints the whole
# menu -- including the entries named "Recovery" and "Rescue Partition" -- at the
# new kernel. There is then no known-good kernel to fall back to, and the shipped
# cmdline carries `oops=panic panic=6`, so a bad kernel crash-loops.
#
# A rescue copy staged on the ESP by hand did not survive: this wipe deleted it,
# and not only on a kernel upgrade -- ANY apt transaction that triggers the
# initramfs hook runs this script. Installing waydroid was enough to remove it
# a second time. So the wipe must spare *-rescue, which the staging code below
# never writes and therefore cannot be stale.
for _esp_f in /boot/efi/vmlinuz-* /boot/efi/initrd.img-*; do
    [ -e "$_esp_f" ] || continue
    case "$_esp_f" in
        *-rescue) echo "  preserving operator rescue image ${_esp_f##*/}"; continue ;;
    esac
    rm -f "$_esp_f"
done
rm -rf /boot/efi/[0-9a-f]*  # Wipe 32-hex kernel-install machine-id dirs
rm -f /boot/efi/EFI/Linux/* 2>/dev/null
rm -rf /boot/efi/loader 2>/dev/null || true
rm -rf /boot/efi/EFI/systemd 2>/dev/null || true
# Capture the operator's current choices BEFORE deleting the file. This wipe
# is why the first attempt at preserving them failed: the learning read sat
# further down, by which point refind.conf no longer existed, so it always
# learned nothing and every apt run silently reset the boot default.
NCZ_LIVE_DEFAULT=""
NCZ_LIVE_TIMEOUT=""
if [ -r /boot/efi/EFI/BOOT/refind.conf ]; then
    NCZ_LIVE_DEFAULT=$(sed -n 's/^[[:space:]]*default_selection[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
        /boot/efi/EFI/BOOT/refind.conf | head -1)
    NCZ_LIVE_TIMEOUT=$(awk '$1 == "timeout" { print $2; exit }' /boot/efi/EFI/BOOT/refind.conf)
fi
rm -f /boot/efi/EFI/BOOT/refind.conf 2>/dev/null || true
echo "  ESP wiped — proceeding with kernel/initrd staging"

NEXT_AVAILABLE=0
NEXT_INITRD_AVAILABLE=0

if [ -n "$KVER_NEXT" ] && [ -s "/boot/vmlinuz-$KVER_NEXT" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_NEXT" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_NEXT exists but /boot/initrd.img-$KVER_NEXT is missing or empty."
        echo "       Refusing to write an edge loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_NEXT" "/boot/efi/vmlinuz-$KVER_NEXT"
    echo "  staged /boot/efi/vmlinuz-$KVER_NEXT"
    NEXT_AVAILABLE=1
    install -m 0644 "/boot/initrd.img-$KVER_NEXT" "/boot/efi/initrd.img-$KVER_NEXT"
    echo "  staged /boot/efi/initrd.img-$KVER_NEXT"
    NEXT_INITRD_AVAILABLE=1

elif [ -n "$KVER_NEXT" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_NEXT missing — edge entry will be SKIPPED"
fi

if [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: edge kernel not installed — system is unbootable."
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
    # The GPU choice is a sky1.gpu= token, plus an entry-specific cmdline
    # blacklist for the losing stack. The kernel honors only one
    # module_blacklist= token, so merge the GPU list into the existing typec
    # list rather than appending a second parameter that would be ignored or win
    # by ordering accident.
    # sky1.gpu= is spelled to match amazingfate's Sky1-Linux switcher so a
    # cmdline copied between the two distros keeps its meaning.
    MALI_GPU_BLACKLIST="panthor"
    PANTHOR_GPU_BLACKLIST="mali_kbase,memory_group_manager,protected_memory_allocator"
    MALI_OPTIONS="$(merge_module_blacklist "$NEXT_OPTIONS" "$MALI_GPU_BLACKLIST") sky1.gpu=vendor"
    PANTHOR_OPTIONS="$(merge_module_blacklist "$NEXT_OPTIONS" "$PANTHOR_GPU_BLACKLIST") sky1.gpu=mesa"
    # Panthor keeps acpi_scmi_en=off, same as Mali and SAFE. Metal-verified
    # on O6N 2026-07-31: the patched panthor-cix DKMS module powers on and
    # un-secures the GPU itself with SCMI off ("GPU power domain 21 powered
    # on via SMC SCMI" + "Sky1: GPU un-secured via ACPI power-supply (_PR0)",
    # then a clean Mali-G720 probe). Flipping acpi_scmi_en=on here was never
    # metal-proven, re-opens the known 7.2 Sky1 PCIe/NVMe boot-hang (the r195
    # regression this cmdline exists to prevent), and would run the kernel
    # SCMI stack alongside the module's raw-SMC power-on path.
fi

# Console keeps the vendor Mali/NPU/VPU accelerators available for headless
# diagnostics and compute. It blacklists only the open-source GPU drivers that
# would contend with the Mali stack selected by sky1.gpu=vendor.
#
# panthor stays out because it kills the GPU on the first user VM_BIND
# (cixtech#59); panfrost is the pre-CSF Mesa driver and would fight the blob
# for the same hardware. Neither is ever wanted on this SoC.
# Accelerator module names, as they actually appear in lsmod on Sky1 (verified
# on O6N 2026-08-16): GPU = panthor | mali_kbase + its two helpers, VPU = amvx,
# NPU = aipu. linlondp is the DISPLAY controller and is NEVER blacklisted -- it
# is the only video console on O6N, and disabling it is a permanent black screen.
CONSOLE_GPU_BLACKLIST="panthor,panfrost"
ALL_ACCEL_BLACKLIST="panthor,panfrost,mali_kbase,memory_group_manager,protected_memory_allocator,amvx,aipu"
# The rescue-partition fallback stays all-accelerators-off: it exists to
# get a shell on a machine whose drivers are suspect, so it deliberately
# loads nothing optional.
CONSOLE_EXTRA_BLACKLIST="$CONSOLE_GPU_BLACKLIST,armchina_npu,amvx,cix_vpu,linlon_vpu"

# (legacy 7.0.12 fallback entry removed 2026-08-21 — single-kernel release)

# 7.2 CONSOLE — reach a networked multi-user shell on the SHIPPING kernel
# when the graphical handoff fails (greeter/DKMS/Mesa).  No splash: this
# entry must stay verbose so a boot failure is diagnosable on ttyAMA0/tty0.
NEXT_CONSOLE_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_CONSOLE_EXISTING_BL=$(printf '%s\n' "$NEXT_CMDLINE_BASE" | tr ' ' '\n' | sed -n 's/^module_blacklist=//p' | paste -sd, -)
    NEXT_CONSOLE_CMDLINE_NOBL=$(printf '%s\n' "$NEXT_CMDLINE_BASE" | tr ' ' '\n' | grep -vE '^(module_blacklist=|$)' | paste -sd' ' -)
    # Operator 2026-08-16: the 7.2 console entry is a no-GUI entry, not a
    # no-hardware entry. It keeps the vendor Mali, VPU and NPU usable for
    # headless work; accelerator-free recovery is the RESCUE entry's job.
    [ -n "$NEXT_CONSOLE_EXISTING_BL" ] && NEXT_CONSOLE_MERGED_BL="$CONSOLE_GPU_BLACKLIST,$NEXT_CONSOLE_EXISTING_BL" || NEXT_CONSOLE_MERGED_BL="$CONSOLE_GPU_BLACKLIST"
    NEXT_CONSOLE_CMDLINE="$NEXT_CONSOLE_CMDLINE_NOBL module_blacklist=$NEXT_CONSOLE_MERGED_BL sky1.gpu=vendor"
    NEXT_CONSOLE_OPTIONS="$ROOT_OPTS $NEXT_CONSOLE_CMDLINE systemd.unit=multi-user.target"
fi

RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_OPTIONS=""
# Edge-only release (operator 2026-08-21): the rescue-partition entry boots
# the rescue rootfs with the edge kernel (the ONLY shipping kernel), so
# the precondition is just the rescue marker + the edge kernel.
if [ -f "$RESCUE_READY" ] && [ "$NEXT_AVAILABLE" = "1" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
    if [ -n "$RESCUEPART_PARTUUID" ]; then
        # rootwait (not rootdelay): rootwait blocks until the root device
        # actually appears, which is the correct mechanism and costs nothing
        # once it has; rootdelay=90 was an unconditional 90s sleep paid on
        # every rescue boot even when the disk was ready immediately.
        # Operator 2026-08-16: RESCUE runs with EVERY accelerator disabled --
        # GPU, VPU and NPU -- because it exists to recover a board those very
        # drivers may have wedged. It can no longer share the console cmdline,
        # which now deliberately keeps the accelerators.
        #
        # linlondp is NOT in the list: it is the display controller and the only
        # video console on O6N. Blacklisting it is a permanent black screen.
        #
        # sky1.gpu=none stops ncz-gpu-switcher trying to load a driver the
        # cmdline forbids, which would fail the unit on the one entry that must
        # never look broken.
        RESCUE_CMDLINE_NOBL=$(printf '%s\n' "$NEXT_CONSOLE_CMDLINE_NOBL" | tr ' ' '\n' | grep -vE '^(sky1\.gpu=|$)' | paste -sd' ' -)
        [ -n "$NEXT_CONSOLE_EXISTING_BL" ] && RESCUE_BL="$NEXT_CONSOLE_EXISTING_BL,$ALL_ACCEL_BLACKLIST" || RESCUE_BL="$ALL_ACCEL_BLACKLIST"
        RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootfstype=ext4 rw $RESCUE_CMDLINE_NOBL module_blacklist=$RESCUE_BL sky1.gpu=none systemd.unit=multi-user.target"
        echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — adding console-only rEFInd rescue-partition entry"
    else
        echo "ERROR: rescue-partition marker has no PARTUUID — refusing to ship without recovery"
        exit 1
    fi
else
    echo "ERROR: rescue partition is required but marker $RESCUE_READY or the shipping kernel is absent"
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
    # Must be UNIQUE across menu titles. rEFInd matches default_selection as a
    # substring -- a bare "Mali" would also match the Console entry's title
    # ("... Console (All Accelerators, Mali)"), leaving the default decided by
    # menu order rather than by intent. "Mali (Default)" appears in exactly
    # one title. Keep it that way when adding entries.
    DEFAULT_TOKEN="Mali (Default)"
else
    DEFAULT_TOKEN="edge"
fi
DESKTOP_COMPONENT_DISABLED=0
if [ "$NEXT_AVAILABLE" = "1" ]; then
    COMPONENTS_FILE=""
    for _cf in /usr/local/lib/cix-installer/COMPONENTS \
               /etc/cix-installer/COMPONENTS \
               /var/lib/cix-components/COMPONENTS; do
        [ -r "$_cf" ] && { COMPONENTS_FILE="$_cf"; break; }
    done
    if [ -n "$COMPONENTS_FILE" ]; then
        _components=$(tr -d ' \t\r\n' < "$COMPONENTS_FILE" 2>/dev/null || true)
        case ",$_components," in
            *",desktop,"*) : ;;
            *)
                DESKTOP_COMPONENT_DISABLED=1
                DEFAULT_TOKEN="Console (All Accelerators, Mali)"
                echo "  desktop component disabled; defaulting rEFInd to console entry"
                ;;
        esac
    fi
fi
# The policy-computed default, kept aside so a stored/learned override that
# turns out not to match any entry we actually write (see the validation
# after the file is written, below) has a known-good value to fall back to.
SAFE_DEFAULT_TOKEN="$DEFAULT_TOKEN"

REFIND_CONF=/boot/efi/EFI/BOOT/refind.conf

# ---------------------------------------------------------------------------
# PRESERVE THE OPERATOR'S CHOICES ACROSS REGENERATION.
#
# This script rewrites refind.conf from scratch, and it runs from the apt
# kernel hook -- so every package operation that touches a kernel silently
# reverted a hand-picked boot default back to DEFAULT_TOKEN and the timeout
# back to 10. Someone who set the machine to boot Panthor, or raised the
# timeout to pick entries on a slow console, lost it on the next apt run with
# no message. That is the "apt keeps breaking my rEFInd" complaint.
#
# Preferences live in /etc/ncz/refind-prefs.conf (shell assignments):
#     NCZ_REFIND_DEFAULT="7.2 Panthor (Experimental)"
#     NCZ_REFIND_TIMEOUT=30
#
# They are also LEARNED: if the live refind.conf carries a default_selection
# or timeout that we did not generate, adopt it into the prefs file before
# overwriting, so editing refind.conf directly sticks instead of lasting until
# the next apt run.
# ---------------------------------------------------------------------------
NCZ_PREFS=/etc/ncz/refind-prefs.conf
mkdir -p /etc/ncz 2>/dev/null || true

# Values captured before the ESP wipe above (refind.conf is long gone by now).
_live_default="$NCZ_LIVE_DEFAULT"
_live_timeout="$NCZ_LIVE_TIMEOUT"

# Load any stored preferences first.
NCZ_REFIND_DEFAULT=""
NCZ_REFIND_TIMEOUT=""
# shellcheck source=/dev/null
[ -r "$NCZ_PREFS" ] && . "$NCZ_PREFS"
if [ "$DESKTOP_COMPONENT_DISABLED" = "1" ]; then
    # Component selection is install-time policy, not an operator preference.
    # A baked or learned "Mali (Default)" preference must not override a real
    # desktop deselection from this install.
    NCZ_REFIND_DEFAULT=""
fi

# Learn from the live file when it disagrees with both the stored pref and the
# value this script would generate -- that means a human changed it.
if [ "$DESKTOP_COMPONENT_DISABLED" != "1" ] \
   && [ -n "$_live_default" ] && [ "$_live_default" != "$DEFAULT_TOKEN" ] \
   && [ "$_live_default" != "$NCZ_REFIND_DEFAULT" ]; then
    NCZ_REFIND_DEFAULT="$_live_default"
    echo "  learned operator default_selection: $NCZ_REFIND_DEFAULT"
fi
if [ -n "$_live_timeout" ] && [ "$_live_timeout" != "10" ] \
   && [ "$_live_timeout" != "$NCZ_REFIND_TIMEOUT" ]; then
    NCZ_REFIND_TIMEOUT="$_live_timeout"
    echo "  learned operator timeout: $NCZ_REFIND_TIMEOUT"
fi

REFIND_TIMEOUT="${NCZ_REFIND_TIMEOUT:-10}"
case "$REFIND_TIMEOUT" in
    ''|*[!0-9]*) REFIND_TIMEOUT=10 ;;
esac

# A stored default is only honoured if it still matches an entry we are about
# to write; otherwise it would point rEFInd at a menu title that no longer
# exists (e.g. after renaming an entry) and leave the machine booting
# whatever happens to be first.
if [ -n "$NCZ_REFIND_DEFAULT" ]; then
    DEFAULT_TOKEN="$NCZ_REFIND_DEFAULT"
fi

{
    printf 'NCZ_REFIND_DEFAULT="%s"\n' "$DEFAULT_TOKEN"
    printf 'NCZ_REFIND_TIMEOUT=%s\n' "$REFIND_TIMEOUT"
} > "$NCZ_PREFS" 2>/dev/null || true

{
    echo "# rEFInd — NCZ cixmini $BUILD_VERSION (generated by ncz-refind-refresh)"
    echo "# Kernels live on the FAT ESP; each kernel's initramfs mounts the"
    echo "# $ROOT_FSTYPE root. No btrfs/ext4 EFI driver is required."
    echo "timeout $REFIND_TIMEOUT"
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
    if [ "$NEXT_AVAILABLE" = "1" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.2 Mali (Default)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$MALI_OPTIONS\""
        echo "}"
        echo
        # Panthor entry, NOT default. History: this entry was deliberately
        # omitted on 2026-08-04 ("we ship mali, period") because panthor died on
        # the first user VM_BIND. That diagnosis was WRONG -- it was not the CSF
        # firmware and not an IDM bus-master revocation.
        #
        # ROOT CAUSE, found 2026-08-15: under ACPI there is no "stacks" clkdev
        # entry, so panthor never enabled the shader-stack clock and every
        # SHADER_PWRON wedged in SHADER_PWRTRANS (all ten cores stuck,
        # SHADER_READY=0x0 SHADER_PWRTRANS=0x550555). The VM_BIND timeout,
        # AS_ACTIVE stuck, soft-reset timeout and "Failed to boot MCU" were all
        # downstream. Fixed in the panthor DKMS source; see the commit
        # "panthor(sky1): enable the shader-stack clock under ACPI".
        #
        # With that fix, VERIFIED on O6N: panvk compute runs, glmark2 3162 FPS
        # at 1080p through the live compositor, Chromium fully hardware
        # accelerated (WebGL/WebGPU), and 4K60 AV1 playback smooth.
        #
        # It is offered but NOT default because mali/kbase remains the validated
        # shipping driver and panthor has not been soak-tested or benchmarked
        # against it. Making it default is a separate, deliberate change to
        # DEFAULT_TOKEN -- do not flip it as a side effect of this entry
        # existing.
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.2 Panthor (Experimental)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$PANTHOR_OPTIONS\""
        echo "}"
        echo
        # The no-initrd recovery entry (loaded the default kernel with no
        # initrd, proving nvme+btrfs are builtin) was DROPPED from the menu
        # 2026-08-19 to cut the operator-facing list down to four entries:
        # Mali, Panthor, Console, Rescue Partition. The underlying capability
        # it demonstrated is unchanged -- CONFIG_BLK_DEV_NVME=y,
        # CONFIG_NVME_CORE=y, CONFIG_BTRFS_FS=y, CONFIG_EXT4_FS=y are still
        # builtin -- only the standalone menu entry is gone. The RESCUE
        # entries below cover the same no-initrd boot path when needed.

        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.2 Console (All Accelerators, Mali)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$NEXT_CONSOLE_OPTIONS\""
        echo "}"
        echo
    fi
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        # Boots the SHIPPING (edge) kernel. KVER_NEXT is the only kernel
        # sidecar this script accepts.
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.2 Rescue Partition (Console)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$RESCUEPART_OPTIONS\""
        echo "}"
        echo
    fi
    # OPERATOR-STAGED RESCUE KERNELS. Preserved by the wipe above; without an
    # entry they would sit on the ESP unreachable from the menu, which is the
    # same as not having them.
    #
    # Boots initrd-less unless a matching initrd.img-<tag>-rescue was staged
    # too: btrfs, ext4 and nvme are all builtin on this hardware, so the
    # no-initrd path is proven independently of any other menu entry.
    #
    # `oops=panic panic=6` is STRIPPED here. On the normal entries an automatic
    # reboot is wanted; on a rescue entry it turns the one bootable fallback
    # into another 6-second reboot loop, so a panic must halt and stay on screen.
    for _rescue_img in /boot/efi/vmlinuz-*-rescue; do
        [ -e "$_rescue_img" ] || continue
        _rescue_file=${_rescue_img##*/}
        _rescue_tag=${_rescue_file#vmlinuz-}
        _rescue_tag=${_rescue_tag%-rescue}
        _rescue_options=$(printf '%s\n' "$MALI_OPTIONS" | tr ' ' '\n' \
            | grep -vE '^(oops=panic|panic=[0-9]+|quiet|)$' | paste -sd' ' -)
        echo "menuentry \"RESCUE  -  $_rescue_tag known-good kernel\" {"
        echo "    loader  /$_rescue_file"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ -e "/boot/efi/initrd.img-$_rescue_tag-rescue" ] && \
            echo "    initrd  /initrd.img-$_rescue_tag-rescue"
        echo "    options \"$_rescue_options\""
        echo "}"
        echo
    done
} > "$REFIND_CONF"
echo "  wrote $REFIND_CONF (default_selection=$DEFAULT_TOKEN)"

# VALIDATE the default actually landed on an entry, rather than trusting a
# stored/learned NCZ_REFIND_DEFAULT the way the code did until 2026-08-19.
# That trust was misplaced: a hand-edited default_selection using an old menu
# title (e.g. "Panthor, Experimental" from before entries were renamed to
# "Panthor (Experimental)") got LEARNED into the prefs file, then kept
# re-confirming itself every regeneration because the stored pref and the
# stale live file always agreed with each other -- silently pointing rEFInd
# at a title that no longer existed on every subsequent boot. Caught during
# the 2026-08-19 menu-title rename, but the same failure mode is reachable
# any time an entry title changes while an old default is stored.
if ! grep '^menuentry ' "$REFIND_CONF" | grep -qF -- "$DEFAULT_TOKEN"; then
    echo "  WARN: default_selection '$DEFAULT_TOKEN' matches no menu entry -- falling back to '$SAFE_DEFAULT_TOKEN'"
    DEFAULT_TOKEN="$SAFE_DEFAULT_TOKEN"
    sed -i "s/^default_selection \".*\"\$/default_selection \\\"$DEFAULT_TOKEN\\\"/" "$REFIND_CONF"
    {
        printf 'NCZ_REFIND_DEFAULT="%s"\n' "$DEFAULT_TOKEN"
        printf 'NCZ_REFIND_TIMEOUT=%s\n' "$REFIND_TIMEOUT"
    } > "$NCZ_PREFS" 2>/dev/null || true
    echo "  corrected $REFIND_CONF and $NCZ_PREFS to default_selection=$DEFAULT_TOKEN"
fi

if command -v efibootmgr >/dev/null 2>&1; then
    EFI_DEV=$(findmnt -no SOURCE /boot/efi)
    EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV" 2>/dev/null || true)
    EFI_PART="${EFI_DEV##*[!0-9]}"
    if [ -n "$EFI_DISK" ] && [ -n "$EFI_PART" ]; then
        # Prune stale/duplicate NVRAM rows before creating a fresh one so repeated
        # installs / kernel-refreshes on a board with writable EFI NVRAM (e.g. O6)
        # do not accumulate identical "nclawzero (rEFInd)" Boot#### entries. No-op
        # on boards without EFI runtime services (efibootmgr lists nothing).
        for _bn in $(efibootmgr 2>/dev/null | grep -F "nclawzero (rEFInd)" | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p"); do
            efibootmgr -b "$_bn" -B >/dev/null 2>&1 || true
        done
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
