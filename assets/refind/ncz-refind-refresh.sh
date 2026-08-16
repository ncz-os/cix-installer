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
LEGACY_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 $EFI_RT_WORKAROUND acpi=force systemd.condition_first_boot=false arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"
NEXT_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 $EFI_RT_WORKAROUND acpi=force systemd.condition_first_boot=false arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused module_blacklist=typec_rts5453,rts5453"

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

# No rootdelay= here: the ncz-rootdelay initramfs hook gives scripts/local a
# 90s poll-timeout FALLBACK without the unconditional init:235 sleep that
# rootdelay= on the cmdline costs every boot (measured: 94s -> 3.6s to GPU
# probe on O6N). The rescue entry uses rootwait alone for the same reason.
ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=$ROOT_FSTYPE rw"
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
    # The GPU choice is a sky1.gpu= token, NOT a module_blacklist. Both drivers
    # are blacklisted permanently in /etc/modprobe.d/ncz-gpu-drivers.conf and
    # ncz-gpu-switcher.service loads the selected one explicitly at boot, so the
    # kernel driver and the matching GL/Vulkan userspace always move together.
    #
    # Blacklisting a GPU driver here would reintroduce a SECOND source of truth
    # that modprobe.d can contradict -- exactly the bug this replaced. Measured
    # on O6N 2026-08-15: the cmdline blacklisted panthor while modprobe.d
    # blacklisted the kbase trio, so NEITHER driver loaded, /dev/mali0 was
    # absent, kbase probe returned -517 and the desktop ran on llvmpipe
    # (glmark2 35 against 2038 on a working stack).
    #
    # The typec_rts5453 blacklist is unrelated to the GPU and stays as it is.
    # sky1.gpu= is spelled to match amazingfate's Sky1-Linux switcher so a
    # cmdline copied between the two distros keeps its meaning.
    MALI_OPTIONS="$NEXT_OPTIONS sky1.gpu=vendor"
    PANTHOR_OPTIONS="$NEXT_OPTIONS sky1.gpu=mesa"
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
# Only the drivers that are actually harmful. "No GUI" is a statement about
# the compositor, not about compute: a headless 7.2 boot is the box you want
# for NPU inference (62.8 inf/s measured), VPU transcode (h264_vaapi at 13.2x
# realtime) AND GPU compute -- the libmali blob exposes Vulkan 1.3 and
# OpenCL 3.0 (10 CUs) on /dev/mali0 with no display server involved.
# Blacklisting the accelerators made this entry useless for exactly the
# workloads it is best at.
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
# The deeper fallbacks (legacy 7.0.12 and the rescue partition) stay
# all-accelerators-off: those exist to get a shell on a machine whose drivers
# are suspect, so they deliberately load nothing optional.
CONSOLE_EXTRA_BLACKLIST="$CONSOLE_GPU_BLACKLIST,armchina_npu,amvx,cix_vpu,linlon_vpu"

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
    # Operator 2026-08-16: the 7.2 console entry keeps ALL ACCELERATORS. It is a
    # no-GUI entry, not a no-hardware entry -- you reach a shell with the GPU,
    # VPU and NPU usable for headless work and for diagnosing the accelerators
    # themselves. Only the graphical target is dropped. Accelerator-free
    # recovery is the RESCUE entry's job.
    NEXT_CONSOLE_MERGED_BL="$NEXT_CONSOLE_EXISTING_BL"
    NEXT_CONSOLE_CMDLINE="$NEXT_CONSOLE_CMDLINE_NOBL module_blacklist=$NEXT_CONSOLE_MERGED_BL sky1.gpu=vendor"
    NEXT_CONSOLE_OPTIONS="$ROOT_OPTS $NEXT_CONSOLE_CMDLINE systemd.unit=multi-user.target"
fi

RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_OPTIONS=""
# One kernel is enough. This used to also require LEGACY_AVAILABLE, because the
# rescue-partition entry booted the rescue rootfs with the legacy kernel. With a
# single shipping kernel (operator 2026-08-11) that condition can never be met,
# and it FAILED CLOSED mid-refresh: on O6N the refresh wiped the ESP entries,
# then exited here before writing refind.conf, leaving the board with no boot
# configuration at all. The rescue partition now carries the shipping kernel's
# modules, so it boots with the same kernel as the system it recovers.
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
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 GUI (Mali, Default)\" {"
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
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 GUI (Panthor, Experimental)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$PANTHOR_OPTIONS\""
        echo "}"
        echo
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 Console (All Accelerators)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$NEXT_CONSOLE_OPTIONS\""
        echo "}"
        echo
    fi
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        # Boots the SHIPPING kernel, not the retired legacy one. With legacy gone
        # KVER_LEGACY is empty, which emitted a literal "loader /vmlinuz-" with
        # no version -- an entry that silently cannot boot. The title said
        # "7.0.12 ... legacy" while the options already pointed at the rescue
        # partition, so the menu was actively misleading about what it would do.
        echo "menuentry \"$NCZ_RELEASE_SHORT  ·  7.2 Rescue Partition (All Accelerators Disabled)\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
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
