#!/bin/bash

# ncz-refind-refresh-amd64.sh — (re)generate the rEFInd ESP menu for the
# AMD64/x86_64 target (T2 Macs + generic PC UEFI hardware). Unified 7.3
# policy (2026-10-05): ONE kernel, no edge line; the rescue entry
# boots that same kernel with the accelerators blacklisted.
#
# Standardized on rEFInd to match arm64/Sky1 rather than diverging on GRUB
# (design rule, 2026-09-16: standardize on rEFInd on amd64, do not
# diverge -- same boot menu shape, same branding/art, same
# preference-learning and rescue-promotion mechanics as
# assets/refind/ncz-refind-refresh.sh). This is a SEPARATE file rather than
# a parameterized shared one, matching that script's own stated philosophy
# (see its header): both run standalone on the target, detached from this
# repo, so a shared library would need its own packaging/delivery path, and
# duplication trades DRY for a delivery path that cannot silently go stale.
#
# Real differences from the arm64 script, and why:
#   - refind_x64.efi (this repo's assets/refind/refind_x64.efi, extracted
#     from Debian's own `refind` package -- NOT present in forky yet, only
#     trixie/sid, so it is vendored as a build-time repo asset exactly the
#     way refind_aa64.efi already is, never apt-installed on the target)
#     instead of refind_aa64.efi; BOOTX64.EFI instead of BOOTAA64.EFI.
#   - console=ttyS0,115200 (standard PC/T2 UART) instead of ttyAMA0, and
#     only when ttyS0 is a real UART (NCZ-SERIAL-CONSOLE block below).
#   - NO MS-R1 efi=noruntime DMI workaround -- that is a specific Sky1
#     board's firmware bug, meaningless on generic x86/T2 hardware.
#   - NO Mali-vs-Panthor GPU-driver menu split, no sky1.gpu=. The single
#     7.3 kernel is the default; the redefined rescue entry blacklists the
#     accelerator stacks (target-aware: amdgpu is kept on T2 Macs because
#     the internal panel is on the AMD dGPU).
#   - Rescue-kernel auto-promotion, operator timeout/default-selection
#     preference learning, banner/icon staging, and the NVRAM
#     firmware-fallback path are all KEPT verbatim -- none of that is
#     Sky1-specific.
set -euo pipefail

# NCZ-ADDONLY-HOOK-BEGIN
# Verbs (2026-11-02). Until now this tool had no modes: every run WIPED the
# ESP and regenerated the whole menu, and the /etc/kernel/postinst.d/zz1 hook
# ran it on every kernel install. The consequence, proven on CHIMERA and
# PEGASUS on 2026-11-02, is that installing any newer kernel silently made it
# the DEFAULT on the next reboot. The menu is now written by three verbs:
#
#   (default)  install-time generation, UNCHANGED: wipes and regenerates the
#              first-install menu (Default / Console / Rescue / Rescue
#              Partition). Only post-install/70-bootloader.sh calls it.
#   --add      the postinst.d hook path: STAGES the new kernel/initrd on the
#              ESP (never overwriting a file already there) and APPENDS one
#              menuentry. It never wipes, never rewrites default_selection or
#              timeout, and never touches the rescue entries.
#   --promote  operator/kernel-side pin: rewrite ONLY the first
#              default_selection line (forced or persisted by the zz2 guard).
#
# Exit codes for --add/--promote (the hooks zz1/zz2 map them 1:1):
#   0  done (also: nothing to do)
#   1  refused -- unsafe/unreadable input, nothing on the ESP was modified
#   2  misuse -- unknown verb or argument
# build/test-refind-addonly.sh pins all of this against a fixture ESP.
NCZ_VERB=generate
case "${1:-}" in
    "")        NCZ_VERB=generate ;;
    --add)     NCZ_VERB=add ;;
    --stage)   NCZ_VERB=stage ;;   # alias: --add stages first, so --stage == --add
    --promote) NCZ_VERB=promote
               shift
               NCZ_PROMOTE_SELECTION="${1:-}"
               [ -n "$NCZ_PROMOTE_SELECTION" ] || {
                   echo "ERROR: --promote needs the entry title to select" >&2; exit 2; }
               NCZ_PROMOTE_FORCE=0
               if [ "${2:-}" = "--force" ]; then NCZ_PROMOTE_FORCE=1; shift; fi
               ;;
    -h|--help)
        sed -n '2,6p' "$0" >&2
        echo "usage: ${0##*/} [--add|--stage|--promote '<entry title>' [--force]]" >&2
        exit 0 ;;
    *) echo "ERROR: unknown argument '${1}'; expected --add, --stage or --promote" >&2; exit 2 ;;
esac
# On the installed system the generator lives in two places (70-bootloader.sh
# installs it to $GENERATOR_DST), so the refuse/act decisions below log the
# name once and reuse it. Kept short deliberately: the hook's own output.
NCZ_GEN="${NCZ_REFRESH_NAME:-ncz-refind-refresh-amd64}"
# NCZ-STAGING-MARKERS-BEGIN
NCZ_STAGE_TAG=ncz-staged
NCZ_HOOK_TAG="# ncz-hook-entry:"
# The ESP holds kernels at its ROOT under the exact /boot names (layout=other;
# nothing else copies them there -- the .deb does not and neither did this
# tool). The ESP is vfat: 8.3-safe names matter only for /EFI, so /vmlinuz-*
# and /initrd.img-* are fine. 64-bit LFN, 512-byte sectors, FAT32 limits.
NCZ_ESP_MAX_FILE_BYTES=$((4 * 1024 * 1024 * 1024 - 1))
NCZ_ESP_MAX_FILES_IN_ROOT=510
# NCZ-STAGING-MARKERS-END
echo "[ncz-refind-refresh-amd64] rEFInd bootloader (staged kernel menu; verb=$NCZ_VERB)"
# NCZ-ADDONLY-HOOK-END

INSTALLER_META=/usr/local/lib/cix-installer
REFIND_SRC="$INSTALLER_META/assets/refind/refind_x64.efi"
: "${KVER_STABLE:=}"
: "${KVER_EDGE:=}"
: "${BUILD_VERSION:=(unknown)}"
# NCZ-UNIFIED-KERNEL-73: ONE kernel (7.3) is the default, the installer kernel
# and the rescue kernel. KVER_STABLE carries that single pin; any KVER_EDGE is
# ignored (the edge channel was retired 2026-10-05).

# Target-machine Apple T2 detection (DMI, assets/refind/ncz-t2-detect.sh). The
# x86 kernel is unified for T2 Macs and generic PCs, so anything T2-specific in
# the boot menu is decided here, on the target. Today that is:
#   * the RESCUE accelerator blacklist below (amdgpu kept on a T2 Mac); and
#   * mce=nobootlog on the DEFAULT (graphical) entry only -- see below.
# If the helper is absent we fail closed to "not T2".
#
# mce=nobootlog on the T2 default entry (2026-10-11). The Apple firmware on
# these Coffee Lake-H T2 Macs (T2 Mac A, MacBookPro16,1, i9-9980HK, cpu 906ed)
# leaves a stale Machine Check record in MCA banks 12/13 that Linux logs at
# boot ("mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 12 ..."). It is a
# left-over from before the kernel booted, not a runtime fault, and the same
# status/MISC signature is reported on unrelated Intel desktops (Arch forum
# bbs.archlinux.org/viewtopic.php?id=266210). The kernel prints MCE records via
# pr_emerg (arch/x86/kernel/cpu/mce/core.c __print_mce), so quiet loglevel=3
# cannot hide them; mce=nobootlog makes __mcheck_cpu_init_prepare_banks() skip
# the boot-time poll/log while STILL clearing every MCi_STATUS, and runtime
# machine checks stay logged and handled. The Console and Rescue entries
# deliberately do NOT carry it, so a technician still sees the raw record.
# Rationale, evidence and trade-off: build/test-t2-mce-nobootlog.sh.
#
# The earlier pcie_ports=compat on the T2 default entry (2026-10-05, defence in
# depth against the 7.3 T2 power cut) was removed on 2026-10-06: the kernel now
# carries the plain upstream revert of eddba19b8b5f and nothing else for it
# (amd64 rc6-4 AER 9010 notes, 2026-10-06).
#
# Markers below let build/test-amd64-t2-detect.sh extract this block
# byte-exactly instead of pattern-matching its shape.
# NCZ-T2-CMDLINE-BEGIN
NCZ_T2_DETECT_LIB="$INSTALLER_META/assets/refind/ncz-t2-detect.sh"
if [ -r "$NCZ_T2_DETECT_LIB" ]; then
    # shellcheck source=/dev/null
    . "$NCZ_T2_DETECT_LIB"
else
    ncz_is_t2_hardware() { return 1; }
    ncz_t2_detect_detail() { printf 'T2 detection helper missing at %s (fail closed)' "$NCZ_T2_DETECT_LIB"; }
fi
# Default entry only: suppress the boot-time left-over MCE log on a T2 Mac
# (a firmware artifact on these Coffee Lake-H parts; see
# build/test-t2-mce-nobootlog.sh). The Console and Rescue entries keep the
# record visible on purpose. Empty on non-T2 and when the helper is absent.
NCZ_T2_MCE_CMDLINE=""
if ncz_is_t2_hardware; then
    NCZ_T2_MCE_CMDLINE="mce=nobootlog"
    echo "  T2 hardware detected ($(ncz_t2_detect_detail)); rescue entry keeps amdgpu; default entry adds mce=nobootlog"
else
    echo "  not T2 hardware ($(ncz_t2_detect_detail))"
fi
# NCZ-T2-CMDLINE-END

RELEASE_FILE=/etc/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE="$INSTALLER_META/RELEASE"
if [ ! -s "$RELEASE_FILE" ]; then
    echo "ERROR: NCZ release identity missing; refusing to write an ambiguously-versioned boot menu"
    exit 1
fi
# shellcheck disable=SC1090
. "$RELEASE_FILE"
# Full release identity (product + version + codename) so the installed rEFInd
# titles read "NCZ-OS 26.10 Cygnus" consistently with GRUB/.disk/info/motd.
NCZ_RELEASE_SHORT="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"

if [ -z "$KVER_STABLE" ] && [ "$NCZ_VERB" != promote ]; then
    echo "ERROR: no KVER_STABLE provided (the stable kernel line is required)"
    exit 1
fi

# Kernel-purity rule 2026-10-04 (Cygnus 26.10), updated
# 2026-10-05: the default rEFInd entry must load our NCZ 7.3 kernel, never a
# Debian-archive kernel. An -rcN is permitted as the default while the unified
# policy allows it (RC_DEFAULT_ALLOWED=1; 7.3.0 final removes it), so only the
# Debian shapes are refused here. Versioned Debian kernels end in -amd64 and
# the forky line is 7.1.x; the /etc/kernel/postinst.d classifier already
# filters /boot, but this generator can be invoked with an explicit KVER, so
# fail closed here too. The build-time gate build/verify-kernel-default-policy.sh
# enforces the 7.3 series and the rc-allowance rules.
case "${KVER_STABLE:-}" in
    *-amd64|7.1.*|7.1-*)
        echo "ERROR: KVER_STABLE='$KVER_STABLE' names a Debian-archive kernel (amd64/7.1.x);" >&2
        echo "       the default MUST be the NCZ 7.3 T2 kernel (unified 7.3 policy)." >&2
        echo "       Refusing to write an rEFInd menu that would boot Debian as the default." >&2
        exit 1
        ;;
esac

# The edge channel was retired in the unified 7.3 policy: any KVER_EDGE passed
# in (legacy hook data, an operator apt install) is ignored and never gets a
# menu entry. Only the single default KVER is bootable here.
if [ -n "${KVER_EDGE:-}" ]; then
    echo "  WARN: KVER_EDGE='$KVER_EDGE' ignored -- the edge channel was retired (unified 7.3 policy, 2026-10-05)"
    KVER_EDGE=""
fi

echo "  KVER_STABLE=$KVER_STABLE"
echo "  KVER_EDGE=${KVER_EDGE:-<none>}"
echo "  BUILD_VERSION=$BUILD_VERSION"

# Prevent systemd-boot deb postinst from double-staging kernels to the ESP.
# Add-only verbs never write it: the install-time generator already did, and a
# kernel hook must not write outside the ESP (a read-only or full root here
# used to abort the whole run before the menu logic could even report).
if [ "$NCZ_VERB" = generate ]; then
    mkdir -p /etc/kernel
    echo "layout=other" > /etc/kernel/install.conf
    echo "  /etc/kernel/install.conf set to layout=other (disables double-staging)"
fi

if [ "$NCZ_VERB" = generate ]; then
# rEFInd binary + the /boot/efi mount check are GENERATE-mode preconditions:
# add-only verbs never (re)install the bootloader binary and never write outside
# the ESP, and they have their own preflights (esp_is_vfat, ncz_add_only).
if [ ! -s "$REFIND_SRC" ]; then
    echo "ERROR: rEFInd binary missing/empty at $REFIND_SRC"
    echo "       cannot install a bootloader."
    exit 1
fi
echo "  rEFInd binary present: $REFIND_SRC ($(du -h "$REFIND_SRC" | cut -f1))"
command -v efibootmgr >/dev/null 2>&1 || echo "  note: efibootmgr not present — relying on /EFI/BOOT/BOOTX64.EFI fallback"

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

STABLE_PREFLIGHT_READY=0
if [ -n "$KVER_STABLE" ]; then
    if [ -z "${KVER_STABLE_SRC:-}" ] && [ -s "/boot/vmlinuz-$KVER_STABLE" ] && [ -s "/boot/initrd.img-$KVER_STABLE" ]; then
        verify_payload_readable "stable kernel" "/boot/vmlinuz-$KVER_STABLE"
        verify_payload_readable "stable initrd" "/boot/initrd.img-$KVER_STABLE"
        STABLE_PREFLIGHT_READY=1
        echo "  preflight OK: stable kernel/initrd present and readable for $KVER_STABLE"
    elif [ -s "/boot/vmlinuz-$KVER_STABLE" ] && [ ! -s "/boot/initrd.img-$KVER_STABLE" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_STABLE exists but /boot/initrd.img-$KVER_STABLE is missing or empty."
        echo "       Refusing to wipe the ESP without a complete stable kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_STABLE" ]; then
        echo "ERROR: incomplete stable kernel payload for $KVER_STABLE."
        echo "       Need non-empty /boot/vmlinuz-$KVER_STABLE and /boot/initrd.img-$KVER_STABLE before ESP wipe."
        exit 1
    fi
fi
# Add-only verbs carry the pair's paths (KVER_STABLE_SRC/INITRD) because their
# main loop runs with the generator's /boot replaced by the caller's paths;
# only the install-time generator has to find them by name in /boot.
if [ "$STABLE_PREFLIGHT_READY" = "0" ] && [ -z "${KVER_STABLE_SRC:-}" ]; then
    echo "ERROR: no stable kernel has both a non-empty vmlinuz and initrd in /boot."
    echo "       Refusing to wipe the ESP because there is nothing bootable to restage."
    exit 1
fi
echo "  preflight OK: stable kernel payload is present"

# A selected rescue partition is validated before touching the ESP.
# This check used to run after stale kernels and refind.conf had
# already been deleted, so the deterministic AMD64 rescue-hook failure turned
# an otherwise recoverable ESP into an unbootable one before returning rc=1.
# NCZ-RESCUE-PREFLIGHT-BEGIN
# Rescue partition (install-time component "rescue-partition"). It is required
# only when it was selected. The selection is read from the same COMPONENTS
# record, in the same order, that post-install/run-all.sh uses to decide whether
# 72-rescue-partition.sh runs, so the two can never disagree. With no record at
# all (an install that predates the component selector) the partition stays
# required. When it is required, nothing on the ESP is touched until
# 72-rescue-partition.sh has written RESCUE_READY with a PARTUUID. When it was
# not selected there is no rescue-partition menu entry.
# build/test-install-options.sh extracts this block between its markers.
RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_PARTUUID=""
if [ -f "$RESCUE_READY" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
fi
RESCUEPART_REQUIRED=1
RESCUEPART_RECORD=""
for _rcf in "$INSTALLER_META/COMPONENTS" /etc/cix-installer/COMPONENTS /var/lib/cix-components/COMPONENTS; do
    [ -r "$_rcf" ] || continue
    RESCUEPART_RECORD="$_rcf"
    _rcomponents=$(tr -d ' \t\r\n' < "$_rcf" 2>/dev/null || true)
    case ",$_rcomponents," in
        *",rescue-partition,"*) RESCUEPART_REQUIRED=1 ;;
        *)                      RESCUEPART_REQUIRED=0 ;;
    esac
    break
done
if [ -n "$RESCUEPART_PARTUUID" ]; then
    echo "  preflight OK: rescue partition PARTUUID=$RESCUEPART_PARTUUID"
fi
if [ -z "$RESCUEPART_PARTUUID" ] && [ "$RESCUEPART_REQUIRED" = "1" ] && [ -s "$INSTALLER_META/INSTALL_IN_PROGRESS" ] \
     && [ "$(cat "$INSTALLER_META/INSTALL_IN_PROGRESS" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]; then
    # Called by a package hook while the install is still running (see
    # NCZ-INSTALL-IN-PROGRESS in post-install/run-all.sh): RESCUE_READY is
    # written later by 72-rescue-partition.sh and 70-bootloader.sh writes the
    # boot menu at the end. Leave the ESP alone now.
    echo "  rescue partition selected and not populated yet (install in progress): ESP left to 70-bootloader.sh"
    exit 0
elif [ -z "$RESCUEPART_PARTUUID" ] && [ "$RESCUEPART_REQUIRED" = "1" ]; then
    echo "ERROR: rescue partition is required but $RESCUE_READY has no PARTUUID"
    echo "       Refusing to modify the ESP until recovery is ready."
    exit 1
elif [ -z "$RESCUEPART_PARTUUID" ]; then
    echo "  preflight OK: rescue partition not selected ($RESCUEPART_RECORD); no rescue-partition entry"
fi
# NCZ-RESCUE-PREFLIGHT-END
# This `fi` closes the `if [ "$NCZ_VERB" = generate ]; then` opened above the
# rEFInd-binary check (~line 206), NOT the rescue-partition if/elif chain that
# ends on the previous line. Two consecutive `fi`s are correct here and both
# are required: removing either one yields "syntax error: unexpected end of
# file". A review has flagged this dangle twice; build/test-refind-addonly.sh
# case 0 parses this file (and both hooks) so the claim is settled by a test
# result, not by reading the diff without its context.
fi   # end of the GENERATE-only preconditions (rEFInd binary, /boot/efi, rescue)

# Preflight (above) validated inputs under `set -euo pipefail`. The ESP is
# vfat (no ownership/perms). The write section below tolerates vfat quirks
# (cp ownership warnings, grep-no-match, best-effort efibootmgr). Under
# strict errexit/pipefail those non-fatal ops could abort BEFORE
# BOOTX64.EFI was written -> unbootable. Relax here; the write section
# keeps its OWN explicit guards.
set +e +u +o pipefail

# Generate-only: it exists to decide the root= stanzas of a menu this run is
# about to WRITE. The add-only verbs reuse the previous run's options verbatim,
# and must not run (or fail on) root probing at all.
if [ "$NCZ_VERB" = generate ]; then
# NCZ-ROOT-PARTUUID-BEGIN
# Every normal entry boots root=PARTUUID=<root>. The initramfs waits for
# /dev/disk/by-partuuid/<root>, which udev creates from the same libblkid
# probe blkid runs here, so an empty answer is a boot that hangs ("Expecting
# device dev-disk-by\x2dpartuuid.device", seen on a Macmini5,1 whose root
# partition still carried an ext4 superblock under the new btrfs: the probe is
# ambivalent and reports nothing). The GPT entry is read directly (sfdisk,
# then sgdisk) to name the partition in the error and to cover a blkid cache
# miss; an ambivalent probe always fails, before anything on the ESP changes.
# build/test-install-options.sh extracts this block between its markers.
ncz_gpt_partuuid() {   # <partition device> -> the GPT unique GUID, lower case
    local _dev _name _disk _num _u=""
    _dev=$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")
    _name=${_dev##*/}
    _num=$(cat "/sys/class/block/$_name/partition" 2>/dev/null)
    _disk=$(basename "$(readlink -f "/sys/class/block/$_name/.." 2>/dev/null)" 2>/dev/null)
    if [ -n "$_num" ] && [ -n "$_disk" ] && [ -b "/dev/$_disk" ]; then
        _u=$(sfdisk --part-uuid "/dev/$_disk" "$_num" 2>/dev/null)
        [ -n "$_u" ] || _u=$(sgdisk -i "$_num" "/dev/$_disk" 2>/dev/null | sed -n 's/^Partition unique GUID: //p')
    fi
    printf '%s' "$_u" | tr 'A-F' 'a-f' | tr -d ' \r\n'
}
ROOT_SRC=$(findmnt -no SOURCE --nofsroot /)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC" 2>/dev/null)
if [ -z "$ROOT_PARTUUID" ]; then
    ROOT_GPT_PARTUUID=$(ncz_gpt_partuuid "$ROOT_SRC")
    ROOT_PROBE_RC=0
    ROOT_PROBE=$(blkid -p -o udev "$ROOT_SRC" 2>&1) || ROOT_PROBE_RC=$?
    case "$ROOT_PROBE" in
        *ambivalent*|*ID_FS_AMBIVALENT*)
            echo "ERROR: the root partition $ROOT_SRC carries more than one filesystem signature (blkid: ambivalent result)."
            echo "       udev cannot create /dev/disk/by-partuuid/${ROOT_GPT_PARTUUID:-?} for it, so the system would hang in the initramfs."
            echo "       'wipefs -n $ROOT_SRC' lists the signatures; the installer clears old signatures before partitioning."
            echo "       Refusing to modify the ESP."
            exit 1 ;;
    esac
    if [ "$ROOT_PROBE_RC" -ne 0 ]; then
        echo "ERROR: the root filesystem probe failed (blkid rc=$ROOT_PROBE_RC)."
        echo "       A GPT GUID alone cannot establish a readable root filesystem."
        echo "       Refusing to modify the ESP."
        exit 1
    fi
    if [ -n "$ROOT_GPT_PARTUUID" ]; then
        ROOT_PARTUUID="$ROOT_GPT_PARTUUID"
        echo "  root PARTUUID read from the GPT entry ($ROOT_PARTUUID): blkid returned none"
    fi
fi
case "$ROOT_PARTUUID" in
    [0-9a-fA-F]*-*-*-*-*) : ;;
    *)
        echo "ERROR: no PARTUUID for the root partition ${ROOT_SRC:-?} (blkid and the GPT entry gave '${ROOT_PARTUUID}')."
        echo "       Refusing to write boot entries with an empty root=PARTUUID= and to modify the ESP."
        exit 1 ;;
esac
# NCZ-ROOT-PARTUUID-END
fi   # end of the root= probe (generate only)

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

# console: serial (ttyS0, standard PC/T2 UART) FIRST so tty0 stays the
# primary /dev/console (last console= wins) — plymouth + the graphical
# greeter own tty0, while a real serial port still gets kernel messages AND
# a serial-getty for lockout recovery (doctrine: serial console must work,
# same as arm64).
#
# ...but ONLY when ttyS0 is a real UART. The 8250 driver registers ttyS0-3 as
# placeholders on every PC, so /sys/class/tty/ttyS0 exists on machines with no
# serial port at all; console=ttyS0 then makes systemd start serial-getty@ttyS0,
# which fails "agetty: failed to get terminal attributes: Input/output error"
# in a restart loop (28 per boot on the GU502LV laptop, also on a T2 Mac). The port type
# tells them apart: 0 (PORT_UNKNOWN) is a placeholder, anything else (4 =
# 16550A, QEMU's ISA serial included, so the KVM gate keeps its console) is a
# UART that answered the probe. The installer media entries are generated
# elsewhere (build/iso/build-refind-esp.py) and keep their serial console.
# NCZ-SERIAL-CONSOLE-BEGIN
ncz_serial_console_present() {   # 0 when ttyS0 is a real UART
    _ncz_sys="${NCZ_SYSFS_ROOT:-/sys}"
    _ncz_proc="${NCZ_PROC_ROOT:-/proc}"
    case "${NCZ_SERIAL_CONSOLE:-auto}" in
        on|force|1)  return 0 ;;
        off|none|0)  return 1 ;;
    esac
    if [ -r "$_ncz_sys/class/tty/ttyS0/type" ]; then
        _ncz_t=$(tr -d '[:space:]' < "$_ncz_sys/class/tty/ttyS0/type" 2>/dev/null)
        case "$_ncz_t" in
            ''|*[!0-9]*) ;;
            0) return 1 ;;
            *) return 0 ;;
        esac
    fi
    # Fallback (root only): "0: uart:16550A port:000003F8 ..." vs "uart:unknown".
    if [ -r "$_ncz_proc/tty/driver/serial" ]; then
        if grep -Eq '^0:[[:space:]]+uart:' "$_ncz_proc/tty/driver/serial" 2>/dev/null; then
            grep -Eq '^0:[[:space:]]+uart:unknown' "$_ncz_proc/tty/driver/serial" 2>/dev/null && return 1
            return 0
        fi
    fi
    return 1
}
NCZ_SERIAL_CONSOLE_ARG=""
if ncz_serial_console_present; then
    NCZ_SERIAL_CONSOLE_ARG="console=ttyS0,115200 "
    echo "  serial console: ttyS0 is a real UART -> console=ttyS0,115200 on every entry"
else
    echo "  serial console: no UART behind ttyS0 -> no console=ttyS0 (avoids the agetty I/O-error loop)"
fi
# NCZ-SERIAL-CONSOLE-END
STABLE_CMDLINE_BASE="${NCZ_SERIAL_CONSOLE_ARG:-}console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
# NCZ-NOUVEAU-RUNPM-BEGIN
# nouveau.runpm=0 on the default and console entries (the rescue entries
# blacklist nouveau outright). On 7.3-rc5+ nouveau's runtime suspend oopses in
# nvkm_gsp_gcx_ready() on Turing/Ampere GPUs without GSP-RM firmware (NULL
# gsp->rm; the GU502LV laptop, RTX 2060 Mobile, 2026-10-06), leaving the dGPU stuck in
# "suspending" so every later PCI config read (lspci, udev) hangs. Fixed
# upstream by 4d0e27041185 (drm-misc-fixes), carried as amd64-kernel-t2 9012.
# preseed/late.sh writes the same option to /etc/modprobe.d; this copy covers
# an initramfs that loads nouveau before /etc is read. Inert when the
# proprietary NVIDIA driver is in use (nouveau is then blacklisted), so it is
# kept: if that driver's DKMS build ever fails, nouveau must not oops.
NCZ_NOUVEAU_CMDLINE="nouveau.runpm=0"
case " $STABLE_CMDLINE_BASE " in
    *" $NCZ_NOUVEAU_CMDLINE "*) ;;
    *) STABLE_CMDLINE_BASE="$STABLE_CMDLINE_BASE $NCZ_NOUVEAU_CMDLINE" ;;
esac
# NCZ-NOUVEAU-RUNPM-END

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

# Graphical-only cmdline (appended to the desktop entry, NOT rescue). Same
# reasoning as arm64: no Plymouth, native KMS paints after root mounts, and
# loglevel=3 keeps known early driver warnings off the graphical VT while
# staying fully available in dmesg/journal/pstore/serial. Rescue stays
# verbose with a normal cursor.
SPLASH="quiet loglevel=3 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false"
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=$ROOT_FSTYPE rw"
if [ -n "$ROOT_SUBVOL" ]; then
    ROOT_OPTS="$ROOT_OPTS rootflags=subvol=$ROOT_SUBVOL"
fi

# NCZ-ADDONLY-FUNCS-BEGIN
# ---------------------------------------------------------------------------
# Add-only kernel install (2026-11-02). Used by the /etc/kernel/postinst.d
# hooks, never by the install itself. Everything here is a REFUSAL unless it
# can prove the ESP afterwards holds exactly one more complete, untouched-by-
# us kernel pair plus one appended menuentry.
#
# Why staging lives here (lesson from the amd64-kernel-t2 lane): neither the
# .deb nor the kernel-postinst contract copies vmlinuz/initrd onto this ESP
# (layout=other), so an --add that only appended an entry would point at
# files that do not exist there. --add therefore stages first, and it refuses
# when it cannot (missing /boot files, ESP full, an ESP file present with
# other content -- that is never overwritten).
ESP_DIR="${NCZ_ESP_DIR:-/boot/efi}"
ESP_CONF="$ESP_DIR/EFI/BOOT/refind.conf"
#
# The marker comments below are read back on every run, so changing them
# re-classifies every previously written entry as unowned. Keep in sync with
# the shell tests: build/test-refind-addonly.sh.
# ---------------------------------------------------------------------------

esp_is_vfat() {
    [ -n "${NCZ_ESP_DIR:-}" ] && return 0   # fixture tree in the tests
    local fstype
    fstype=$(findmnt -no FSTYPE "$ESP_DIR" 2>/dev/null || true)
    [ "$fstype" = vfat ]
}

# Same shell-glob-escape as the generated-entry helper: an option value with a
# quote or backslash must not be able to end the quoted rEFInd options string.
ncz_quote_option_value() {
    local v=$1
    v=$(printf '%s' "$v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    v=${v//\$/\$\$}
    v=${v//\`/\'\`}
    printf '%s' "$v"
}

# ncz_esp_kernel_present <kver> -- 0 when BOTH files for kver exist on the ESP
# with content.
ncz_esp_kernel_present() {
    [ -s "$ESP_DIR/vmlinuz-$1" ] && [ -s "$ESP_DIR/initrd.img-$1" ]
}

# ncz_esp_file_count -- files needed to know whether a FAT root can take more;
# the root directory of a FAT32 volume is capped at 510 8.3-style slots.
ncz_esp_file_count() {
    find "$ESP_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
}

# ncz_stage_pair <kver> <vmlinuz-source> <initrd-source>
# Stage the pair onto the ESP without ever overwriting an existing ESP file.
# Each half is copied to a private temp name on the ESP first, then recorded as
# STAGED-BY-US and renamed. A crash between the two renames leaves at most one
# half behind, and the next run re-stages the missing half (the temp name is
# never the final name). rc 1 (refuse) for: missing/unreadable source, no room,
# ESP file with different content already present.
ncz_stage_pair() {
    local kver=$1 src_v=$2 src_i=$3 half src dst tmp staged_here=0
    for half in vmlinuz initrd.img; do
        case "$half" in
            vmlinuz)    src=$src_v ;;
            initrd.img) src=$src_i ;;
        esac
        dst="$ESP_DIR/$half-$kver"
        if [ -e "$dst" ]; then
            if [ ! -s "$dst" ]; then
                echo "ERROR: $dst exists on the ESP but is empty; refusing to guess what it should hold" >&2
                return 1
            fi
            if cmp -s "$src" "$dst"; then
                echo "  $half-$kver already staged on the ESP (identical), left as-is"
                continue
            fi
            echo "ERROR: $dst already exists on the ESP with DIFFERENT content;" >&2
            echo "       add-only never overwrites an existing ESP file. Remove it by hand" >&2
            echo "       if the ESP copy is known-bad, then re-run the kernel hook." >&2
            return 1
        fi
        tmp="$ESP_DIR/.$half-$kver.$NCZ_STAGE_TAG.$$"
        rm -f "$tmp" 2>/dev/null || true
        if ! cp -f "$src" "$tmp" 2>/dev/null || [ ! -s "$tmp" ] || ! cmp -s "$src" "$tmp"; then
            rm -f "$tmp" 2>/dev/null || true
            echo "ERROR: could not stage $src to $tmp (ESP full or unwritable); nothing was added" >&2
            return 1
        fi
        if ! mv -f "$tmp" "$dst" 2>/dev/null; then
            rm -f "$tmp" 2>/dev/null || true
            echo "ERROR: could not rename $tmp to $dst; nothing was added" >&2
            return 1
        fi
        echo "  staged $half-$kver on the ESP"
        staged_here=$((staged_here + 1))
    done
    # --stage/--add: record that WE put these bytes there, so a later identical
    # replacement is allowed and a different one is refused. The record is the
    # single source of truth for "we own this ESP file", so it is written even
    # when both halves were already identical (staged_here=0): an --add that
    # finds its own earlier bytes must still leave a record that a later
    # refresh can match. ncz_staged_by_us reads it back field-for-field, so the
    # order here (kver, vmlinuz-sha, initrd-sha) is the contract.
    printf '%s/%s/%s\n' "$kver" "$(sha256sum "$src_v" | cut -d' ' -f1)" \
        "$(sha256sum "$src_i" | cut -d' ' -f1)" > "$ESP_DIR/$NCZ_STAGE_TAG-$kver" 2>/dev/null || true
    return 0
}

# ncz_staged_by_us <kver> -- 0 when the staging record proves this tool wrote
# the ESP files for <kver>.
# The record is a single line "<kver>/<vmlinuz-sha>/<initrd-sha>" written by
# ncz_stage_pair. It records WHICH kernel we own and WHICH bytes we wrote there
# at that time. A refresh happens precisely because /boot now differs from the
# ESP copy, so the recorded shas can never equal the incoming ones -- ownership
# is therefore decided by a well-formed record naming this kver, not by sha
# equality with the new /boot content. (Comparing the record against the new
# shas made every staged kernel look foreign, so the add-only path refused to
# refresh its own files and reported them as not staged.)
ncz_staged_by_us() {
    local rec="$ESP_DIR/$NCZ_STAGE_TAG-$1" rec_kver rec_v rec_i
    [ -s "$rec" ] || return 1
    IFS=/ read -r rec_kver rec_v rec_i < "$rec" 2>/dev/null || return 1
    [ "$rec_kver" = "$1" ] || return 1
    # Both hashes must be present and well-formed (64 hex chars, as sha256sum
    # emits); a truncated or hand-edited record is not proof of ownership.
    ncz_is_sha256 "$rec_v" || return 1
    ncz_is_sha256 "$rec_i" || return 1
    return 0
}

ncz_restore_conf() {   # used by callers that rewrote refind.conf and failed
    local bak=$1
    [ -n "$bak" ] && [ -s "$bak" ] && cp -f "$bak" "$ESP_CONF" 2>/dev/null
    rm -f "$bak" 2>/dev/null || true
}

# ncz_is_sha256 <string> -- 0 when <string> is exactly 64 lowercase hex
# characters, i.e. the shape sha256sum emits. Guards the staging record against
# truncated or hand-edited values.
ncz_is_sha256() {
    case "$1" in
        *[!0-9a-f]*) return 1 ;;
        ????????????????????????????????????????????????????????????????) ;;
        *) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

# ncz_conf_escape <string> -- printf replacement text that inserts <string>
# literally into a later printf format.
ncz_conf_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'
}

# ncz_options_from_menu -- echo the `options` string of the FIRST menuentry
# that carries one. --add reuses it verbatim: it runs no root= probe (that is
# generate-only), so building options itself would emit root=PARTUUID= (empty)
# -- a stanza that hangs in the initramfs. Reusing the live string keeps the
# new entry bootable by construction and keeps this tool out of cmdline policy.
ncz_options_from_menu() {
    awk '
        /^menuentry / { inentry = 1; next }
        inentry && /^[[:space:]]*options[[:space:]]+"/ {
            line = $0
            sub(/^[[:space:]]*options[[:space:]]+"/, "", line)
            sub(/"[[:space:]]*$/, "", line)
            print line
            exit
        }
    ' "$ESP_CONF" 2>/dev/null
}

# ncz_options_have_root <options> -- 0 when <options> carries a root= the
# kernel can mount. --add never probes the root filesystem (that is
# generate-only, and probing it from a kernel postinst would be both slow and
# wrong), so it reuses the live menu's options verbatim -- but reusing them
# blind is not enough: a menu whose options carry no root= yields an appended
# entry that cannot boot. Refuse that instead of writing it.
#
# A root= keyword is bare when it opens the string or follows whitespace; a
# "root=" inside another word is not one. Values that hand off to something
# else (root=PARTUUID=empty, root=LABEL=) are not a usable spec.
ncz_options_have_root() {
    local word val found=0
    for word in $1; do
        case "$word" in
            root=*)
                val=${word#root=}
                case "$val" in
                    ""|LABEL=|UUID=|PARTLABEL=|PARTUUID=) continue ;;
                esac
                found=1
                break
                ;;
        esac
    done
    [ "$found" = 1 ]
}

# ncz_menu_title_token <kver> -- the UNIQUE substring that names an entry for
# this kernel. rEFInd matches default_selection as a substring, so the kver
# itself is the token: it appears in no other entry title, and the title never
# contains "(Default)"/"Console"/"Rescue" markers.
ncz_menu_title_token() { printf '%s' "$1"; }

# The entry title this tool writes, and the ONLY title the uniqueness check
# accepts as its own. One definition, so the appended line and the check cannot
# drift apart.
# ncz_menu_title_for <tag> -- echo the entry title for <tag>.
ncz_menu_title_for() { printf '7.3 Kernel %s' "$1"; }

# ncz_entry_append <kver|tag> <loader> <initrd> <options> <title-token>
# Append one menuentry to refind.conf. Every append is rolled back when the
# written file no longer holds the previous content verbatim.
#
# Uniqueness is checked BEFORE the file is replaced: an append that would make
# the token name a second entry is refused while the original menu is still
# intact. It must be checked here rather than after `mv` because the backup is
# unlinked once the replace succeeds -- a post-mv failure to restore would
# leave the duplicate entry on the ESP while still reporting failure, which is
# exactly what the append-once claim forbids.
#
# The check is LITERAL and whole-title, never a regex: a kver is a pattern to
# grep (`7.3.0-rc8-t2-ncz` has dots, and any char in it could be a regex
# operator), so `grep -c "^menuentry .*$token"` would match a different kernel
# whose name merely fits as a pattern (7x3y0-rc8...). Both the pre-existing
# menus and the text we are about to write are compared the same way.
ncz_entry_append() {
    local tag=$1 loader=$2 initrd=$3 options=$4 token=$5
    local bak new before_size after_size
    local title existing matches ours
    bak="$(mktemp "${TMPDIR:-/var/tmp}/refind-conf.XXXXXX")" || {
        echo "ERROR: cannot allocate a backup for $ESP_CONF; nothing was added" >&2; return 1; }
    cp -f "$ESP_CONF" "$bak" || { rm -f "$bak"; echo "ERROR: cannot read $ESP_CONF; nothing was added" >&2; return 1; }
    before_size=$(wc -c < "$bak" | tr -d ' ')
    if [ "$before_size" -gt 0 ] && [ "$(tail -c 1 "$bak" | od -An -c | tr -d ' ')" != '\n' ]; then
        echo "" >> "$bak"
    fi
    new="$bak.new"
    cp -f "$bak" "$new" || { rm -f "$bak" "$new"; echo "ERROR: cannot copy $ESP_CONF; nothing was added" >&2; return 1; }
    {
        printf '\n'
        printf '%s %s\n' "$NCZ_HOOK_TAG" "$tag"
        printf '%s "%s" {\n' "menuentry" "$(ncz_menu_title_for "$tag")"
        printf '%s /%s\n' "    loader " "$loader"
        [ -n "$REFIND_ICON" ] && printf '%s /EFI/BOOT/%s\n' "    icon   " "$REFIND_ICON"
        [ -n "$initrd" ] && printf '%s /%s\n' "    initrd " "$initrd"
        printf '%s "%s"\n' "    options" "$(ncz_quote_option_value "$options")"
        printf '%s\n' "}"
    } >> "$new" || { rm -f "$bak" "$new"; echo "ERROR: cannot write $ESP_CONF; nothing was added" >&2; return 1; }
    after_size=$(wc -c < "$new" 2>/dev/null | tr -d ' ')
    if [ -z "$after_size" ] || [ "$after_size" -le "$before_size" ] \
       || ! head -c "$before_size" "$new" | cmp -s - "$bak"; then
        rm -f "$bak" "$new" 2>/dev/null || true
        echo "ERROR: appending to $ESP_CONF did not round-trip; ESP left unchanged" >&2
        return 1
    fi
    # Decide uniqueness on the CANDIDATE file, before it replaces the menu.
    # The candidate already holds the entry written above, so it is the final
    # menu: exactly one title may carry the token, and it must be the one this
    # tool wrote. Anything else (a second match, or a title that merely
    # contains the token without being ours) is refused while the real menu is
    # still untouched.
    title=$(ncz_menu_title_for "$tag")
    existing=$(awk -v tok="$token" -v want="$title" '
            /^menuentry[[:space:]]+"/ {
                line = $0
                sub(/^menuentry[[:space:]]+"/, "", line)
                sub(/"[[:space:]]*\{.*$/, "", line)
                if (index(line, tok) > 0) { n++; if (line == want) exact++ }
            }
            END { print (n + 0) "/" (exact + 0) }
        ' "$new" 2>/dev/null || true)
    matches=${existing%%/*}
    ours=${existing##*/}
    if [ "${matches:-0}" != "1" ] || [ "${ours:-0}" != "1" ]; then
        rm -f "$bak" "$new" 2>/dev/null || true
        echo "ERROR: appending an entry for '$token' would not leave exactly one match in $ESP_CONF" >&2
        echo "       (titles carrying it=${matches:-0}, this tool's title=${ours:-0}); ESP left unchanged" >&2
        return 1
    fi
    if ! mv -f "$new" "$ESP_CONF"; then
        rm -f "$new" "$bak" 2>/dev/null || true
        echo "ERROR: cannot replace $ESP_CONF; ESP left unchanged" >&2
        return 1
    fi
    rm -f "$bak" 2>/dev/null || true
    # Last line of defence: the installed menu must still hold exactly one
    # match. From here on the previous bytes are gone (the backup is unlinked
    # above), so a failure here cannot be rolled back -- it is reported as a
    # corrupt menu, which is why the decision above is made pre-replace.
    local hits
    hits=$(grep '^menuentry ' "$ESP_CONF" 2>/dev/null | grep -cF -- "$token" || true)
    if [ "${hits:-0}" != "1" ]; then
        echo "ERROR: $ESP_CONF now holds ${hits:-0} entries matching '$token' (expected 1);" >&2
        echo "       the append could not be rolled back -- reinstall or regenerate the menu" >&2
        return 1
    fi
    return 0
}
# NCZ-ADDONLY-FUNCS-END

# ---------------------------------------------------------------------------
# --promote "<entry title>": the ONLY thing allowed to change
# default_selection outside install-time generation. It rewrites the
# default_selection line and nothing else; the zz2 guard calls it.
# ---------------------------------------------------------------------------
ncz_promote() {
    local sel="$NCZ_PROMOTE_SELECTION" cur tmp bak hits
    if [ ! -s "$ESP_CONF" ]; then
        echo "ERROR: no menu at $ESP_CONF; nothing to promote" >&2
        return 1
    fi
    hits=$(grep '^menuentry ' "$ESP_CONF" | grep -cF -- "$sel" || true)
    if [ "${hits:-0}" = "0" ]; then
        echo "ERROR: --promote '$sel' matches no menuentry in $ESP_CONF" >&2
        return 1
    fi
    cur=$(sed -n 's/^[[:space:]]*default_selection[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ESP_CONF" | head -1)
    if [ "$cur" = "$sel" ] && [ "$NCZ_PROMOTE_FORCE" != "1" ]; then
        echo "  default_selection is already '$sel'"
        return 0
    fi
    bak="$(mktemp "${TMPDIR:-/var/tmp}/refind-conf.XXXXXX")" || return 1
    cp -f "$ESP_CONF" "$bak" || { rm -f "$bak"; return 1; }
    tmp="$bak.new"
    if [ -z "$cur" ]; then
        { printf 'default_selection "%s"\n' "$sel"; cat "$bak"; } > "$tmp"
    else
        sed "s|^[[:space:]]*default_selection[[:space:]]*\"[^\"]*\"[[:space:]]*$|default_selection \"$(printf '%s' "$sel" | sed 's/[&|\\]/\\&/g')\"|" "$bak" > "$tmp"
    fi
    # Only the default_selection line may differ.
    if ! diff <(grep -v '^[[:space:]]*default_selection' "$bak") \
              <(grep -v '^[[:space:]]*default_selection' "$tmp") >/dev/null 2>&1; then
        rm -f "$bak" "$tmp"
        echo "ERROR: --promote would change more than default_selection; refused" >&2
        return 1
    fi
    if ! mv -f "$tmp" "$ESP_CONF"; then
        rm -f "$bak" "$tmp"
        echo "ERROR: cannot replace $ESP_CONF; unchanged" >&2
        return 1
    fi
    rm -f "$bak"
    echo "  default_selection '$cur' -> '$sel' in $ESP_CONF"
    return 0
}

# NCZ-ADDONLY-DISPATCH-BEGIN
# ---------------------------------------------------------------------------
# --add / --stage: stage the new kernel/initrd on the ESP and append ONE
# menuentry. Never wipes, never rewrites default_selection or timeout, never
# removes or edits anything already in refind.conf.
# ---------------------------------------------------------------------------
ncz_add_only() {
    local kver="$KVER_STABLE" src_v src_i sha_v sha_i title token
    local icon="$REFIND_ICON"

    if [ -z "$kver" ]; then
        echo "ERROR: --add needs KVER_STABLE (or the zz1 hook's trigger version)" >&2
        return 1
    fi
    case "$kver" in
        *-amd64|7.1.*|7.1-*)
            echo "ERROR: --add refuses Debian-archive kernel '$kver' (NCZ 7.3 policy)" >&2
            return 1 ;;
    esac
    if ! esp_is_vfat; then
        echo "ERROR: $ESP_DIR is not a mounted vfat ESP; refusing to touch it" >&2
        return 1
    fi
    if [ ! -s "$ESP_CONF" ]; then
        echo "ERROR: no generated menu at $ESP_CONF; the install-time generator" >&2
        echo "       (70-bootloader.sh) has not written one -- refusing to invent a menu" >&2
        return 1
    fi
    if ! grep -q '^menuentry ' "$ESP_CONF" 2>/dev/null; then
        echo "ERROR: $ESP_CONF has no menuentry; refusing to append to a menu that cannot boot" >&2
        return 1
    fi

    src_v="${KVER_STABLE_SRC:-/boot/vmlinuz-$kver}"
    src_i="${KVER_STABLE_INITRD:-/boot/initrd.img-$kver}"
    if [ ! -s "$src_v" ] || [ ! -s "$src_i" ]; then
        echo "ERROR: $kver has no complete kernel pair in /boot (need $src_v and $src_i);" >&2
        echo "       add-only stages only what is already installed, and never fabricates a kernel" >&2
        return 1
    fi
    sha_v=$(sha256sum "$src_v" | cut -d' ' -f1)
    sha_i=$(sha256sum "$src_i" | cut -d' ' -f1)

    # Bounded ESP: a kernel pair that does not fit must fail here, before the
    # first byte is copied, not half-way through a stage.
    local need avail
    need=$(( $(stat -c %s "$src_v") + $(stat -c %s "$src_i") ))
    if [ "$(stat -c %s "$src_v")" -gt "$NCZ_ESP_MAX_FILE_BYTES" ] \
       || [ "$(stat -c %s "$src_i")" -gt "$NCZ_ESP_MAX_FILE_BYTES" ]; then
        echo "ERROR: $kver payload exceeds the FAT32 4 GiB per-file limit; cannot stage it" >&2
        return 1
    fi
    avail=$(df -Pk "$ESP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }')
    if [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
        echo "ERROR: ESP has $avail bytes free, $kver needs $need; nothing was added" >&2
        return 1
    fi

    if ! ncz_esp_kernel_present "$kver"; then
        ncz_stage_pair "$kver" "$src_v" "$src_i" || return 1
    else
        echo "  $kver already staged on the ESP"
        # Reconcile an ESP copy that differs from /boot only when WE put the
        # current bytes there; anything else is an operator/foreign file.
        local half dst src sha_now
        for half in vmlinuz initrd.img; do
            case "$half" in
                vmlinuz)    src=$src_v; sha_now=$sha_v ;;
                initrd.img) src=$src_i; sha_now=$sha_i ;;
            esac
            dst="$ESP_DIR/$half-$kver"
            cmp -s "$src" "$dst" && continue
            if ncz_staged_by_us "$kver"; then
                echo "  refreshing $half-$kver (staged by this tool, content changed in /boot)"
                cp -f "$src" "$ESP_DIR/.$half-$kver.$NCZ_STAGE_TAG.$$" 2>/dev/null \
                    && cmp -s "$src" "$ESP_DIR/.$half-$kver.$NCZ_STAGE_TAG.$$" \
                    && mv -f "$ESP_DIR/.$half-$kver.$NCZ_STAGE_TAG.$$" "$dst" \
                    || { rm -f "$ESP_DIR/.$half-$kver.$NCZ_STAGE_TAG.$$"; \
                         echo "ERROR: could not refresh $dst; nothing was added" >&2; return 1; }
            else
                echo "ERROR: $dst differs from $src and was not staged by this tool;" >&2
                echo "       add-only never overwrites an existing ESP file" >&2
                return 1
            fi
        done
        printf '%s/%s/%s\n' "$kver" "$sha_v" "$sha_i" > "$ESP_DIR/$NCZ_STAGE_TAG-$kver" 2>/dev/null || true
    fi
    if [ "$(ncz_esp_file_count)" -gt "$NCZ_ESP_MAX_FILES_IN_ROOT" ]; then
        echo "WARN: the ESP root already holds $NCZ_ESP_MAX_FILES_IN_ROOT+ files; a FAT32 root can" >&2
        echo "      reject new entries. This add was attempted, but check the ESP contents." >&2
    fi

    token=$(ncz_menu_title_token "$kver")
    if grep -qF -- "$NCZ_HOOK_TAG $kver" "$ESP_CONF" 2>/dev/null; then
        echo "  $kver already has a hook-written entry in $ESP_CONF; menu left as-is"
        echo "  default_selection stays '$(sed -n 's/^[[:space:]]*default_selection[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ESP_CONF" | head -1)'"
        return 0
    fi
    # A generator-written entry for this exact kernel (a re-install of the
    # running kernel, or a hand-run generator) already names it: do not add a
    # duplicate, and do not touch it.
    if grep '^menuentry ' "$ESP_CONF" | grep -qF -- "$token"; then
        echo "  $ESP_CONF already names kernel $kver; no entry appended"
        return 0
    fi

    title="$NCZ_RELEASE_SHORT  -  7.3 Kernel $kver"
    # Reuse the live menu's options verbatim (see ncz_options_from_menu): --add
    # never probes root= and must not invent a cmdline.
    local opts
    opts="$(ncz_options_from_menu)"
    if [ -z "$opts" ]; then
        echo "ERROR: $ESP_CONF has no menuentry with an options string to reuse;" >&2
        echo "       refusing to append an entry that would not boot (add-only)" >&2
        return 1
    fi
    # Reusing the live options is only safe when they actually name a root.
    # Without one the appended entry cannot mount the root filesystem, so an
    # "add-only" run would produce a menu entry that never boots -- worse than
    # not adding it, because the entry LOOKS usable.
    if ! ncz_options_have_root "$opts"; then
        echo "ERROR: the options string in $ESP_CONF names no usable root=" >&2
        echo "       (reused verbatim by --add: '$opts');" >&2
        echo "       refusing to append an entry that would not boot (add-only)" >&2
        return 1
    fi
    ncz_entry_append "$kver" "vmlinuz-$kver" "initrd.img-$kver" \
        "$opts" "$token" || return 1
    echo "  appended menuentry \"$title\" to $ESP_CONF"
    echo "  default_selection unchanged: '$(sed -n 's/^[[:space:]]*default_selection[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ESP_CONF" | head -1)'"
    echo "  timeout unchanged: $(awk '$1 == "timeout" { print $2; exit }' "$ESP_CONF")"
    echo "  rescue entries untouched: $(grep -c '^menuentry .*\(Rescue\|RESCUE\)' "$ESP_CONF" 2>/dev/null || echo 0)"
    return 0
}

# NCZ-ADDONLY-DISPATCH-END

# Dispatch the add-only verbs BEFORE the first destructive statement: every
# helper and both menu editors are defined above this point, and nothing below
# it may run for --add/--stage/--promote (reaching the wipe from the hook path
# is exactly the defect the add-only design exists to prevent).
if [ "$NCZ_VERB" = add ] || [ "$NCZ_VERB" = stage ]; then
    ncz_add_only
    exit $?
fi
if [ "$NCZ_VERB" = promote ]; then
    ncz_promote
    exit $?
fi

echo "  wiping stale ESP entries + kernel images..."

# ---------------------------------------------------------------------------
# RESCUE PROMOTION GUARD (item RRH, 2026-10-04).
#
# PRESERVE OPERATOR-STAGED RESCUE KERNELS + AUTO-PROMOTE the outgoing kernel to
# a rescue image before deleting it. Identical reasoning to arm64: every
# menuentry this script emits points at the same /vmlinuz-$KVER_STABLE, so a
# same-kver upgrade repoints the whole menu including any rescue entry -- there
# must always be a real known-good fallback that this wipe cannot touch. Only
# one rescue image is kept (previous one replaced).
#
# LIVE DEFECT this guard closes (T2 Mac B, T2 Mac, 2026-10-04): the promotion loop
# took the first non-rescue ESP kernel whose kver was neither KVER_STABLE nor
# KVER_EDGE, with NO prerelease classification. After purging the old stable
# linux-image-7.2.8-3 the hook ran with KVER_EDGE=7.3.0-rc5-9; the ESP still
# held a staged stock-Edge kernel 7.3.0-rc5-10-t2-ncz-revhid (not equal to
# KVER_EDGE), so IT was promoted to RESCUE after the known-good 7.2.8-3 rescue
# pair had already been deleted -- a RESCUE entry booting an -rc kernel that
# power-cuts. Three invariants now hold:
#   1. a pre-release (-rcN) kernel is NEVER promoted to the rescue slot;
#   2. the candidate must be a stable-class NCZ release kernel;
#   3. the existing rescue is deleted only AFTER a complete new pair has been
#      copied to temp names, so a failed copy leaves it byte-identical; if no
#      stable-class candidate exists, the existing rescue is kept as-is.
# ---------------------------------------------------------------------------

# A kernel is PRERELEASE if its version carries an -rcN component. Same test the
# /etc/kernel/postinst.d/zz1-ncz-refind-refresh-amd64 classifier uses.
is_prerelease() {
    case "$1" in *-rc[0-9]*) return 0 ;; *) return 1 ;; esac
}

# amd64 stable-class: the NCZ T2 stable line (<ver>-t2-ncz), release only.
# A stock/Debian/edge kernel is never eligible for the rescue slot.
is_stable_class() {
    is_prerelease "$1" && return 1
    case "$1" in
        *-t2-ncz*) return 0 ;;
        *)            return 1 ;;
    esac
}

# ncz_promote_outgoing_rescue <esp-dir> <primary-kver> [edge-kver]
#
# Promote the outgoing kernel already staged on the ESP to the single -rescue
# slot before the wipe, but ONLY when it is a stable-class release kernel.
# Extracted as a function so build/test-refind-rescue-promotion.sh can drive the
# real code against a fixture ESP tree.
ncz_promote_outgoing_rescue() {
    local ESP="$1" PRIMARY="$2" EDGE_KVER="${3:-}"
    local _esp_k _out_kver _tmp_v _tmp_i _r existing_rescue="" promoted=""

    [ -n "$ESP" ] || return 0
    [ -n "$PRIMARY" ] || return 0

    # What rescue (if any) is currently staged?
    for _r in "$ESP"/vmlinuz-*-rescue; do
        [ -e "$_r" ] || continue
        existing_rescue=${_r##*/vmlinuz-}
        existing_rescue=${existing_rescue%-rescue}
        break
    done

    for _esp_k in "$ESP"/vmlinuz-*; do
        [ -e "$_esp_k" ] || continue
        case "$_esp_k" in *-rescue) continue ;; esac
        _out_kver=${_esp_k##*/vmlinuz-}

        # Never promote either kernel we're about to stage (the primary stable
        # or the edge line), nor a same-line variant of the primary: a variant
        # would make the rescue entry point at the very kernel it replaces.
        # Fixed 2026-09-16 before this ever shipped: the arm64 script this was
        # copied from had exactly this bug checking ONLY the primary
        # (KVER_NEXT there, KVER_STABLE here) line, never the second (edge)
        # line.
        case "$_out_kver" in
            "$PRIMARY")   continue ;;
            "$PRIMARY"-*) continue ;;
            "$EDGE_KVER") [ -n "$EDGE_KVER" ] && continue ;;
        esac

        # Never promote a pre-release (-rcN)/edge-class kernel: this is the
        # 2026-10-04 T2 Mac B incident.
        if is_prerelease "$_out_kver"; then
            echo "  NOT promoting $_out_kver to rescue -- prerelease (-rcN) kernel, not stable-class"
            continue
        fi
        if ! is_stable_class "$_out_kver"; then
            echo "  NOT promoting $_out_kver to rescue -- not an NCZ stable-class kernel"
            continue
        fi

        [ -s "$_esp_k" ] || continue
        [ -s "$ESP/initrd.img-$_out_kver" ] || {
            echo "  WARN: not promoting $_out_kver to rescue -- its initrd is missing on the ESP"
            continue
        }

        # Copy to temporary names FIRST; only replace the current rescue once
        # BOTH halves are complete, so a failed copy leaves the old rescue
        # intact.
        _tmp_v="$ESP/.vmlinuz-$_out_kver-rescue.new.$$"
        _tmp_i="$ESP/.initrd.img-$_out_kver-rescue.new.$$"
        rm -f "$_tmp_v" "$_tmp_i" 2>/dev/null || true
        if cp -f "$_esp_k" "$_tmp_v" &&
           cp -f "$ESP/initrd.img-$_out_kver" "$_tmp_i" &&
           [ -s "$_tmp_v" ] && [ -s "$_tmp_i" ]; then
            rm -f "$ESP"/vmlinuz-*-rescue "$ESP"/initrd.img-*-rescue 2>/dev/null || true
            existing_rescue=""   # the old rescue is gone now; do not log it as kept
            if mv -f "$_tmp_v" "$ESP/vmlinuz-$_out_kver-rescue" &&
               mv -f "$_tmp_i" "$ESP/initrd.img-$_out_kver-rescue"; then
                echo "  promoted outgoing stable kernel $_out_kver to rescue image"
                promoted=1
            else
                rm -f "$_tmp_v" "$_tmp_i" 2>/dev/null || true
                echo "  WARN: could not promote $_out_kver to a rescue image"
            fi
        else
            rm -f "$_tmp_v" "$_tmp_i" 2>/dev/null || true
            echo "  WARN: could not promote $_out_kver to a rescue image"
        fi
        break
    done

    if [ -z "$promoted" ]; then
        if [ -n "$existing_rescue" ]; then
            echo "  kept existing rescue image $existing_rescue (no stable-class outgoing candidate)"
        else
            echo "  no rescue image staged (no stable-class outgoing candidate)"
        fi
    fi
    return 0
}

ncz_promote_outgoing_rescue /boot/efi "$KVER_STABLE" "${KVER_EDGE:-}"


for _esp_f in /boot/efi/vmlinuz-* /boot/efi/initrd.img-*; do
    [ -e "$_esp_f" ] || continue
    case "$_esp_f" in
        *-rescue) echo "  preserving rescue image ${_esp_f##*/}"; continue ;;
    esac
    rm -f "$_esp_f"
done
rm -rf /boot/efi/[0-9a-f]*  # Wipe 32-hex kernel-install machine-id dirs
rm -f /boot/efi/EFI/Linux/* 2>/dev/null
rm -rf /boot/efi/loader 2>/dev/null || true
rm -rf /boot/efi/EFI/systemd 2>/dev/null || true
# Capture the operator's current choices BEFORE deleting the file (same
# reasoning as arm64 — this wipe is why the first attempt at preserving
# them has to read BEFORE deletion, not after).
NCZ_LIVE_DEFAULT=""
NCZ_LIVE_TIMEOUT=""
if [ -r /boot/efi/EFI/BOOT/refind.conf ]; then
    NCZ_LIVE_DEFAULT=$(sed -n 's/^[[:space:]]*default_selection[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
        /boot/efi/EFI/BOOT/refind.conf | head -1)
    NCZ_LIVE_TIMEOUT=$(awk '$1 == "timeout" { print $2; exit }' /boot/efi/EFI/BOOT/refind.conf)
fi
rm -f /boot/efi/EFI/BOOT/refind.conf 2>/dev/null || true
echo "  ESP wiped — proceeding with kernel/initrd staging"

STABLE_AVAILABLE=0
STABLE_INITRD_AVAILABLE=0

if [ -n "$KVER_STABLE" ] && [ -s "/boot/vmlinuz-$KVER_STABLE" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_STABLE" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_STABLE exists but /boot/initrd.img-$KVER_STABLE is missing or empty."
        echo "       Refusing to write a stable loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_STABLE" "/boot/efi/vmlinuz-$KVER_STABLE"
    echo "  staged /boot/efi/vmlinuz-$KVER_STABLE"
    STABLE_AVAILABLE=1
    install -m 0644 "/boot/initrd.img-$KVER_STABLE" "/boot/efi/initrd.img-$KVER_STABLE"
    echo "  staged /boot/efi/initrd.img-$KVER_STABLE"
    STABLE_INITRD_AVAILABLE=1
fi

if [ "$STABLE_AVAILABLE" = "0" ]; then
    echo "ERROR: default kernel not installed — system is unbootable."
    exit 1
fi

# NCZ-DEFAULT-OPTIONS-BEGIN
STABLE_OPTIONS=""
if [ "$STABLE_AVAILABLE" = "1" ]; then
    STABLE_OPTIONS="$ROOT_OPTS $STABLE_CMDLINE_BASE"
    [ -n "$SPLASH" ] && STABLE_OPTIONS="$STABLE_OPTIONS $SPLASH"
    # T2 only: keep the boot-time left-over MCE record off THIS entry's console.
    # Set by the NCZ-T2-CMDLINE block above; empty on non-T2 and when the
    # detection helper is absent (fail closed). Never added to the Console or
    # Rescue entries -- a technician must still see the raw record there.
    [ -n "${NCZ_T2_MCE_CMDLINE:-}" ] && STABLE_OPTIONS="$STABLE_OPTIONS $NCZ_T2_MCE_CMDLINE"
fi

# Console entry — reach a networked multi-user shell on the SHIPPING kernel
# when the graphical handoff fails. No splash: this entry must stay verbose
# so a boot failure is diagnosable on ttyS0/tty0.
STABLE_CONSOLE_OPTIONS=""
if [ "$STABLE_AVAILABLE" = "1" ]; then
    STABLE_CONSOLE_OPTIONS="$ROOT_OPTS $STABLE_CMDLINE_BASE systemd.unit=multi-user.target"
fi

# RESCUE, redefined under the unified 7.3 policy (2026-10-05): the
# SAME default kernel with the accelerator drivers blacklisted, not an old
# known-good kernel. The list is target-aware because the amd64 kernel is
# unified for T2 Macs and generic PCs:
#   - on a T2 Mac the internal panel is wired to the AMD dGPU, so amdgpu is
#     KEPT (blacklisting it would be a black screen) and only the other
#     GPU/compute stacks are dropped;
#   - on a generic PC all discrete GPU stacks are dropped and the console
#     stays up via simpledrm/efifb/fbdev (or an unblacklisted iGPU).
# is_t2_hardware() is defined by the sourced ncz-t2-detect.sh above (fails
# closed to non-T2 when the helper is absent).
# NCZ-RESCUE-ACCEL-BEGIN
RESCUE_ACCEL_BLACKLIST="amdgpu,radeon,nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
if ncz_is_t2_hardware; then
    RESCUE_ACCEL_BLACKLIST="nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nouveau,radeon"
fi
# NCZ-RESCUE-ACCEL-END
RESCUE_CMDLINE_BASE="${NCZ_SERIAL_CONSOLE_ARG:-}console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
RESCUE_OPTIONS="$ROOT_OPTS $RESCUE_CMDLINE_BASE module_blacklist=$RESCUE_ACCEL_BLACKLIST systemd.unit=multi-user.target"

RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootfstype=ext4 rw ${NCZ_SERIAL_CONSOLE_ARG:-}console=tty0 module_blacklist=$RESCUE_ACCEL_BLACKLIST systemd.unit=multi-user.target"
if [ -n "${RESCUEPART_PARTUUID:-}" ]; then
    echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — same 7.3 kernel, accelerators blacklisted ($RESCUE_ACCEL_BLACKLIST)"
else
    # Rescue partition not selected at install time (see the preflight): no entry.
    RESCUEPART_OPTIONS=""
    echo "  no rescue partition on this install: rescue-partition entry omitted"
fi
# NCZ-DEFAULT-OPTIONS-END

install -d -m 0755 /boot/efi/EFI/BOOT
install -m 0644 "$REFIND_SRC" /boot/efi/EFI/BOOT/BOOTX64.EFI
if [ ! -s /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
    echo "ERROR: failed to install rEFInd to /boot/efi/EFI/BOOT/BOOTX64.EFI"
    exit 1
fi
echo "  rEFInd installed → /boot/efi/EFI/BOOT/BOOTX64.EFI (firmware fallback path)"

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

# Cygnus 26.10 theme: a single 1920x1080 background (banner_scale fillscreen),
# selection art and the Cygnus entry icon.  Staged under EFI/BOOT/themes/cygnus
# and pulled in with an `include` line after the generated banner lines.
# The design is GOP-mode independent -- no panel probing, no per-resolution
# files (see docs/REFIND-THEME.md).  Optional: when the asset dir is absent the
# generated NCZ banner/icon above stay in force.
CYGNUS_SRC="$INSTALLER_META/assets/refind/cygnus"
REFIND_THEME=""
if [ -s "$CYGNUS_SRC/theme.conf" ] && [ -s "$CYGNUS_SRC/background-1920x1080.png" ]; then
    rm -rf /boot/efi/EFI/BOOT/themes/cygnus
    mkdir -p /boot/efi/EFI/BOOT/themes/cygnus
    cp -r "$CYGNUS_SRC"/. /boot/efi/EFI/BOOT/themes/cygnus/
    if [ -s "$CYGNUS_SRC/os_ncz.png" ]; then
        install -m 0644 "$CYGNUS_SRC/os_ncz.png" /boot/efi/EFI/BOOT/ncz.png
        REFIND_ICON="ncz.png"
    fi
    REFIND_THEME="themes/cygnus/theme.conf"
    echo "  rEFInd Cygnus theme installed → /boot/efi/EFI/BOOT/themes/cygnus"
fi

# Release policy (unified 7.3, 2026-10-05): the single 7.3 kernel is
# the default graphical entry. There is no edge entry.
if [ "$STABLE_AVAILABLE" = "1" ]; then
    # Must be UNIQUE across menu titles -- rEFInd matches default_selection
    # as a substring, same trap arm64's own comment documents. "7.3 (Default)"
    # appears in exactly one title; keep it that way when adding entries.
    DEFAULT_TOKEN="7.3 (Default)"
else
    DEFAULT_TOKEN="7.3"
fi
DESKTOP_COMPONENT_DISABLED=0
if [ "$STABLE_AVAILABLE" = "1" ]; then
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
                DEFAULT_TOKEN="7.3 Console"
                echo "  desktop component disabled; defaulting rEFInd to console entry"
                ;;
        esac
    fi
fi
# NCZ-MENU-VARIANT-BEGIN
# MAGNETAR(server): which menu to write -- the server menu is Console + Rescue
# Partition only. NCZ_VARIANT (environment) wins when a caller sets it; the
# install (70-bootloader.sh) and every later caller (the kernel postinst.d
# hook, ncz-refind-refresh run by hand) leave it unset, so fall back to the
# marker preseed/late.sh writes ONLY when the install came from a Magnetar
# server medium. BUILD_VARIANT is deliberately NOT used: a desktop medium's
# install with the desktop component off records BUILD_VARIANT=server too, and
# that install keeps the full menu.
# Wrapped in a function (2026-11-02) so the add-only verbs append entries with
# the SAME variant/title rule the generated menu uses, without duplicating it.
ncz_apply_menu_variant() {
NCZ_MENU_VARIANT="${NCZ_VARIANT:-}"
if [ -z "$NCZ_MENU_VARIANT" ] && [ -r /usr/local/lib/cix-installer/MEDIUM_VARIANT ]; then
    case "$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/MEDIUM_VARIANT 2>/dev/null)" in
        server) NCZ_MENU_VARIANT=server ;;
    esac
fi
[ -n "$NCZ_MENU_VARIANT" ] || NCZ_MENU_VARIANT=desktop
# The server menu titles name the edition (post-install/lib/ncz-brand.sh, the
# one place that spells it), never the desktop release codename. A desktop
# menu keeps NCZ_RELEASE_SHORT exactly as computed above.
if [ "$NCZ_MENU_VARIANT" = server ]; then
    if [ -r /usr/local/lib/cix-installer/post-install/lib/ncz-brand.sh ] \
       && . /usr/local/lib/cix-installer/post-install/lib/ncz-brand.sh; then
        NCZ_RELEASE_SHORT=$(ncz_brand_label server "$NCZ_RELEASE_SHORT" "${NCZ_PRODUCT_NAME:-NCZ-OS}" "${NCZ_RELEASE_VERSION:-}")
    else
        echo "  WARN: server medium but no post-install/lib/ncz-brand.sh; menu titles keep '$NCZ_RELEASE_SHORT'"
    fi
    # The legacy ncz-banner.png carries an old release name in its pixels; the
    # theme hides it, but it would show whenever the theme is absent. A server
    # menu never references it.
    REFIND_BANNER=""
fi
if [ "$NCZ_MENU_VARIANT" != desktop ] && [ "$STABLE_AVAILABLE" = "1" ]; then
    DEFAULT_TOKEN="7.3 Console"
    echo "  server medium: Console + Rescue Partition menu"
fi
}
ncz_apply_menu_variant
# NCZ-MENU-VARIANT-END
SAFE_DEFAULT_TOKEN="$DEFAULT_TOKEN"

REFIND_CONF=/boot/efi/EFI/BOOT/refind.conf


# PRESERVE THE OPERATOR'S CHOICES ACROSS REGENERATION — same mechanism as
# arm64: stored prefs in /etc/ncz/refind-prefs.conf, plus learning from a
# live refind.conf that disagrees with both the stored pref and the
# would-generate value.
NCZ_PREFS=/etc/ncz/refind-prefs.conf
mkdir -p /etc/ncz 2>/dev/null || true

_live_default="$NCZ_LIVE_DEFAULT"
_live_timeout="$NCZ_LIVE_TIMEOUT"

NCZ_REFIND_DEFAULT=""
NCZ_REFIND_TIMEOUT=""
# shellcheck source=/dev/null
[ -r "$NCZ_PREFS" ] && . "$NCZ_PREFS"
if [ "$DESKTOP_COMPONENT_DISABLED" = "1" ]; then
    NCZ_REFIND_DEFAULT=""
fi

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

if [ -n "$NCZ_REFIND_DEFAULT" ]; then
    DEFAULT_TOKEN="$NCZ_REFIND_DEFAULT"
fi

{
    printf 'NCZ_REFIND_DEFAULT="%s"\n' "$DEFAULT_TOKEN"
    printf 'NCZ_REFIND_TIMEOUT=%s\n' "$REFIND_TIMEOUT"
} > "$NCZ_PREFS" 2>/dev/null || true

{
    echo "# rEFInd — NCZ AMD64 $BUILD_VERSION (generated by ncz-refind-refresh-amd64)"
    echo "# Kernels live on the FAT ESP; each kernel's initramfs mounts the"
    echo "# $ROOT_FSTYPE root. No btrfs/ext4 EFI driver is required."
    echo "timeout $REFIND_TIMEOUT"
    echo "log_level 0"
    echo "use_nvram false"
    echo "resolution max"
    [ -n "$REFIND_BANNER" ] && echo "banner $REFIND_BANNER"
    [ -n "$REFIND_BANNER" ] && echo "banner_scale noscale"
    [ -n "$REFIND_THEME" ] && echo "include $REFIND_THEME"
    echo "showtools shell,reboot,shutdown,firmware"
    echo "scanfor manual"
    echo "scan_all_linux_kernels false"
    echo "default_selection \"$DEFAULT_TOKEN\""
    echo
    if [ "$STABLE_AVAILABLE" = "1" ]; then
        # MAGNETAR(server): the server menu is Console + Rescue Partition only.
        if [ "$NCZ_MENU_VARIANT" = "desktop" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.3 (Default)\" {"
        echo "    loader  /vmlinuz-$KVER_STABLE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$STABLE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_STABLE"
        echo "    options \"$STABLE_OPTIONS\""
        echo "}"
        echo
        fi

        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.3 Console\" {"
        echo "    loader  /vmlinuz-$KVER_STABLE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$STABLE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_STABLE"
        echo "    options \"$STABLE_CONSOLE_OPTIONS\""
        echo "}"
        echo

        # REDEFINED RESCUE (2026-10-05): the SAME 7.3 kernel with the
        # accelerator drivers blacklisted. This replaces the old
        # "rescue = an older known-good kernel" definition.
        if [ "$NCZ_MENU_VARIANT" = "desktop" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  7.3 Rescue / No Accelerators (Console)\" {"
        echo "    loader  /vmlinuz-$KVER_STABLE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$STABLE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_STABLE"
        echo "    options \"$RESCUE_OPTIONS\""
        echo "}"
        echo
        fi
    fi
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  Rescue Partition (Console)\" {"
        echo "    loader  /vmlinuz-$KVER_STABLE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$STABLE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_STABLE"
        echo "    options \"$RESCUEPART_OPTIONS\""
        echo "}"
        echo
    fi
    # OPERATOR-STAGED RESCUE KERNELS. Preserved by the wipe above. Under the
    # unified policy these also boot with the accelerators blacklisted.
    for _rescue_img in /boot/efi/vmlinuz-*-rescue; do
        [ -e "$_rescue_img" ] || continue
        _rescue_file=${_rescue_img##*/}
        _rescue_tag=${_rescue_file#vmlinuz-}
        _rescue_tag=${_rescue_tag%-rescue}
        _rescue_options=$(printf '%s\n' "$RESCUE_OPTIONS" | tr ' ' '\n' \
            | grep -vE '^(quiet|)$' | paste -sd' ' -)
        echo "menuentry \"RESCUE  -  $_rescue_tag known-good kernel\" {"
        echo "    loader  /$_rescue_file"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ -e "/boot/efi/initrd.img-$_rescue_tag-rescue" ] && \
            echo "    initrd  /initrd.img-$_rescue_tag-rescue"
        echo "    options \"$_rescue_options\""
        echo "}"
        echo
    done
} > "$REFIND_CONF"
echo "  wrote $REFIND_CONF (default_selection=$DEFAULT_TOKEN)"

# VALIDATE the default actually landed on an entry -- same trap/fix as
# arm64 (2026-08-19): never trust a stored/learned default blindly.
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
        # NCZ-EFI-BOOTENTRY-BEGIN
        # One NVRAM row for rEFInd, labelled "NCZ-OS". Images before 2026-10-26
        # labelled it "nclawzero (rEFInd)". Delete every row carrying EITHER
        # label (exact label match, so another OS's row is never touched)
        # before creating the fresh one, so repeated installs / kernel refreshes
        # and upgraded machines do not keep stale or duplicate Boot#### rows.
        # No-op on boards without EFI runtime services (efibootmgr lists nothing).
        _ncz_efi_label="NCZ-OS"
        _ncz_efi_old_label="nclawzero (rEFInd)"
        for _bn in $(efibootmgr 2>/dev/null | awk -v new="$_ncz_efi_label" -v old="$_ncz_efi_old_label" '
                /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][* ] / {
                    l = substr($0, 11); sub(/\t.*/, "", l); sub(/ +$/, "", l)
                    if (l == new || l == old) print substr($0, 5, 4)
                }'); do
            efibootmgr -b "$_bn" -B >/dev/null 2>&1 || true
        done
        efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
            -L "$_ncz_efi_label" -l '\EFI\BOOT\BOOTX64.EFI' >/dev/null 2>&1 || true
        # NCZ-EFI-BOOTENTRY-END
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
