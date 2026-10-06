#!/bin/bash

# ncz-refind-refresh-amd64.sh — (re)generate the rEFInd ESP menu for the
# AMD64/x86_64 target (T2 Macs + generic PC UEFI hardware, unified stable
# kernel line + a separate experimental edge line).
#
# Standardized on rEFInd to match arm64/Sky1 rather than diverging on GRUB
# (operator directive, 2026-09-16: "standardize on rEFInd on amd64, we
# should not diverge" -- same boot menu shape, same branding/art, same
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
#   - console=ttyS0,115200 (standard PC/T2 UART) instead of ttyAMA0.
#   - NO MS-R1 efi=noruntime DMI workaround -- that is a specific Sky1
#     board's firmware bug, meaningless on generic x86/T2 hardware.
#   - NO Mali-vs-Panthor GPU-driver menu split, no sky1.gpu=, no
#     accelerator module_blacklist juggling -- amd64 has no Sky1-style
#     DKMS GPU choice; i915/amdgpu/nvidia are in-tree kernel drivers,
#     selected by the hardware itself, not a boot-menu decision. The
#     Stable-vs-Edge KERNEL LINE choice takes that split's place instead
#     (see 70-bootloader.sh's run_refind_amd64()), matching what
#     run_grub_amd64() already did before this file replaced it.
#   - Rescue-kernel auto-promotion, operator timeout/default-selection
#     preference learning, banner/icon staging, and the NVRAM
#     firmware-fallback path are all KEPT verbatim -- none of that is
#     Sky1-specific.
set -euo pipefail

echo "[ncz-refind-refresh-amd64] rEFInd bootloader (staged kernel menu)"

INSTALLER_META=/usr/local/lib/cix-installer
REFIND_SRC="$INSTALLER_META/assets/refind/refind_x64.efi"
: "${KVER_STABLE:=}"
: "${KVER_EDGE:=}"
: "${BUILD_VERSION:=(unknown)}"

# Operator directive 2026-10-05: the amd64 T2 EDGE entry boots with
# pcie_ports=compat, the PCIe mode the T2 Linux community runs as its
# baseline on T2 Macs, alongside the AER ANFE revert the edge kernel
# already carries. compat leaves the firmware _OSC grant intact but makes
# the OS assume control of the PCIe port services without the port driver
# claiming them: no AER handler, no PME, no native hotplug service is
# registered (measured on MEDUSA: "pcie_portdrv_init returned -13" and an
# empty /sys/bus/pci_express/devices). ACPI hotplug still works; native
# Thunderbolt hotplug may behave differently. Applied to the amd64 EDGE
# entry ONLY, and ONLY on Apple T2 hardware -- never the stable,
# stable-console or rescue entries. See
# docs/reports/2026-10-05-amd64-edge-pcie-ports-compat.md.
#
# The x86 kernel is UNIFIED (one family for T2 Macs and generic PCs), so this
# is decided here, on the target machine, via DMI (ncz_is_t2_hardware in
# assets/refind/ncz-t2-detect.sh): a generic workstation/server must keep the
# native AER/PME/hotplug port services. The detection helper is sourced from
# the same staged assets tree, and if it is absent we fail closed to no token.
#
# Markers below let build/test-amd64-edge-compat.sh extract this block
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

NCZ_T2_EDGE_EXTRA_CMDLINE=""
if ncz_is_t2_hardware; then
    NCZ_T2_EDGE_EXTRA_CMDLINE="pcie_ports=compat"
    echo "  T2 hardware detected ($(ncz_t2_detect_detail)); amd64 edge entry gets the T2 compat cmdline"
else
    echo "  not T2 hardware ($(ncz_t2_detect_detail)); amd64 edge entry keeps default PCIe services"
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

if [ -z "$KVER_STABLE" ]; then
    echo "ERROR: no KVER_STABLE provided (the stable kernel line is required)"
    exit 1
fi

# Operator directive 2026-10-04 (Cygnus 26.10 kernel purity): the default
# rEFInd entry must load our 7.2.9 T2 kernel, never a Debian-archive kernel.
# Reject the two shapes a Debian kernel can arrive in: an -rcN prerelease, and
# a Debian-named/versioned kernel (versioned Debian kernels end in -amd64 and
# the forky line is 7.1.x; NCZ's amd64 kernel ends in -t2-trixie). The
# /etc/kernel/postinst.d classifier already filters /boot to *-t2-trixie*, but
# this generator can be invoked with an explicit KVER, so fail closed here too.
case "$KVER_STABLE" in
    *-rc[0-9]*)
        echo "ERROR: KVER_STABLE='$KVER_STABLE' is a release-candidate (-rcN); the amd64 stable line MUST be a release kernel (directive 2026-09-30)." >&2
        echo "       Refusing to write an rEFInd menu that would boot -rc as the default." >&2
        exit 1
        ;;
    *-amd64|7.1.*|7.1-*)
        echo "ERROR: KVER_STABLE='$KVER_STABLE' names a Debian-archive kernel (amd64/7.1.x);" >&2
        echo "       the stable line MUST be the NCZ 7.2.9 T2 kernel (directive 2026-10-04)." >&2
        echo "       Refusing to write an rEFInd menu that would boot Debian as the default." >&2
        exit 1
        ;;
esac

# Operator directive 2026-10-05: amd64 edge channel is pinned to 7.3.0-rc6,
# the validated T2 kernel with the AER ANFE revert
# (7.3.0-rc6-1-t2-edge-aerfix). A KVER_EDGE that is not that pinned line is
# ignored (defence in depth alongside the build-time policy gate
# build/verify-kernel-default-policy.sh and the classify() function in
# zz1-ncz-refind-refresh-amd64, which only surfaces the pinned line). The
# kernel itself may still be installed (operator apt install), but the
# rEFInd menu must not offer an unpinned -rc as a bootable edge entry.
case "$KVER_EDGE" in
    "")
        ;;
    7.3.0-rc6-[0-9]-t2-edge-aerfix|7.3.0-rc6-[0-9][0-9]-t2-edge-aerfix)
        echo "  KVER_EDGE='$KVER_EDGE' accepted (amd64 edge channel is pinned to 7.3.0-rc6, operator 2026-10-05)"
        ;;
    *)
        echo "  WARN: KVER_EDGE='$KVER_EDGE' ignored -- not the pinned amd64 edge 7.3.0-rc6-<N>-t2-edge-aerfix (operator 2026-10-05; amd64 edge channel is pinned to 7.3.0-rc6)"
        KVER_EDGE=""
        ;;
esac

echo "  KVER_STABLE=$KVER_STABLE"
echo "  KVER_EDGE=${KVER_EDGE:-<none>}"
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
    if [ -s "/boot/vmlinuz-$KVER_STABLE" ] && [ -s "/boot/initrd.img-$KVER_STABLE" ]; then
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
if [ "$STABLE_PREFLIGHT_READY" = "0" ]; then
    echo "ERROR: no stable kernel has both a non-empty vmlinuz and initrd in /boot."
    echo "       Refusing to wipe the ESP because there is nothing bootable to restage."
    exit 1
fi
echo "  preflight OK: stable kernel payload is present"

# Recovery is part of the release contract, but validate it before touching
# the ESP.  This check used to run after stale kernels and refind.conf had
# already been deleted, so the deterministic AMD64 rescue-hook failure turned
# an otherwise recoverable ESP into an unbootable one before returning rc=1.
RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_PARTUUID=""
if [ -f "$RESCUE_READY" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
fi
if [ -z "$RESCUEPART_PARTUUID" ]; then
    echo "ERROR: rescue partition is required but $RESCUE_READY has no PARTUUID"
    echo "       Refusing to modify the ESP until recovery is ready."
    exit 1
fi
echo "  preflight OK: rescue partition PARTUUID=$RESCUEPART_PARTUUID"

# Preflight (above) validated inputs under `set -euo pipefail`. The ESP is
# vfat (no ownership/perms). The write section below tolerates vfat quirks
# (cp ownership warnings, grep-no-match, best-effort efibootmgr). Under
# strict errexit/pipefail those non-fatal ops could abort BEFORE
# BOOTX64.EFI was written -> unbootable. Relax here; the write section
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

# console: serial (ttyS0, standard PC/T2 UART) FIRST so tty0 stays the
# primary /dev/console (last console= wins) — plymouth + the graphical
# greeter own tty0, while a real serial port still gets kernel messages AND
# a serial-getty for lockout recovery (doctrine: serial console must work,
# same as arm64).
STABLE_CMDLINE_BASE="console=ttyS0,115200 console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"

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
# LIVE DEFECT this guard closes (MEDUSA, T2 Mac, 2026-10-04): the promotion loop
# took the first non-rescue ESP kernel whose kver was neither KVER_STABLE nor
# KVER_EDGE, with NO prerelease classification. After purging the old stable
# linux-image-7.2.8-3 the hook ran with KVER_EDGE=7.3.0-rc5-9; the ESP still
# held a staged stock-Edge kernel 7.3.0-rc5-10-t2-trixie-revhid (not equal to
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

# amd64 stable-class: the NCZ T2 stable line (<ver>-N-t2-trixie), release only.
# A stock/Debian/edge kernel is never eligible for the rescue slot.
is_stable_class() {
    is_prerelease "$1" && return 1
    case "$1" in
        *-t2-trixie*) return 0 ;;
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
        # 2026-10-04 MEDUSA incident.
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

# EDGE — the second, experimental kernel line (v7.3-rc3). Absence is not
# fatal, only the stable line is required above.
EDGE_AVAILABLE=0
EDGE_INITRD_AVAILABLE=0
if [ -n "${KVER_EDGE:-}" ] && [ -s "/boot/vmlinuz-$KVER_EDGE" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_EDGE" ]; then
        echo "  WARN: /boot/vmlinuz-$KVER_EDGE exists but /boot/initrd.img-$KVER_EDGE is missing -- edge entry SKIPPED"
    else
        install -m 0644 "/boot/vmlinuz-$KVER_EDGE" "/boot/efi/vmlinuz-$KVER_EDGE"
        echo "  staged /boot/efi/vmlinuz-$KVER_EDGE"
        EDGE_AVAILABLE=1
        install -m 0644 "/boot/initrd.img-$KVER_EDGE" "/boot/efi/initrd.img-$KVER_EDGE"
        echo "  staged /boot/efi/initrd.img-$KVER_EDGE"
        EDGE_INITRD_AVAILABLE=1
    fi
elif [ -n "${KVER_EDGE:-}" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_EDGE missing — edge entry will be SKIPPED"
fi

if [ "$STABLE_AVAILABLE" = "0" ]; then
    echo "ERROR: stable kernel not installed — system is unbootable."
    exit 1
fi

# NCZ-EDGE-OPTIONS-BEGIN
STABLE_OPTIONS=""
if [ "$STABLE_AVAILABLE" = "1" ]; then
    STABLE_OPTIONS="$ROOT_OPTS $STABLE_CMDLINE_BASE"
    [ -n "$SPLASH" ] && STABLE_OPTIONS="$STABLE_OPTIONS $SPLASH"
fi

# Console entry — reach a networked multi-user shell on the SHIPPING kernel
# when the graphical handoff fails. No splash: this entry must stay verbose
# so a boot failure is diagnosable on ttyS0/tty0.
STABLE_CONSOLE_OPTIONS=""
if [ "$STABLE_AVAILABLE" = "1" ]; then
    STABLE_CONSOLE_OPTIONS="$ROOT_OPTS $STABLE_CMDLINE_BASE systemd.unit=multi-user.target"
fi

# EDGE — v7.3-rc3, EXPERIMENTAL kernel, CONSOLE-ONLY. Exists to prove the
# kernel/initrd itself boots on real hardware; not a graphical-default
# choice. Same treatment as arm64's edge entry.
EDGE_OPTIONS=""
if [ "$EDGE_AVAILABLE" = "1" ]; then
    EDGE_OPTIONS="$ROOT_OPTS console=ttyS0,115200 console=tty0 systemd.unit=multi-user.target"
    # Operator directive 2026-10-05: append the T2 edge extra cmdline
    # (pcie_ports=compat). The guard keeps this idempotent -- if the token
    # is already present it is never added a second time -- and appending
    # preserves every option already in EDGE_OPTIONS. It is deliberately
    # scoped to this one branch: the stable, stable-console and rescue
    # option strings above/below are untouched.
    # NCZ-EDGE-GUARD-BEGIN
    if [ -n "$NCZ_T2_EDGE_EXTRA_CMDLINE" ]; then
        case " $EDGE_OPTIONS " in
            *" $NCZ_T2_EDGE_EXTRA_CMDLINE "*) ;;
            *) EDGE_OPTIONS="$EDGE_OPTIONS $NCZ_T2_EDGE_EXTRA_CMDLINE" ;;
        esac
    fi
    # NCZ-EDGE-GUARD-END
fi

RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootfstype=ext4 rw console=ttyS0,115200 console=tty0 systemd.unit=multi-user.target"
echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — adding console-only rEFInd rescue-partition entry"
# NCZ-EDGE-OPTIONS-END

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

# Release policy: the stable kernel is the default graphical entry. Edge is
# always an explicit console-only experiment.
if [ "$STABLE_AVAILABLE" = "1" ]; then
    # Must be UNIQUE across menu titles -- rEFInd matches default_selection
    # as a substring, same trap arm64's own comment documents. "Stable
    # (Default)" appears in exactly one title; keep it that way when adding
    # entries.
    DEFAULT_TOKEN="Stable (Default)"
else
    DEFAULT_TOKEN="edge"
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
                DEFAULT_TOKEN="Stable Console"
                echo "  desktop component disabled; defaulting rEFInd to console entry"
                ;;
        esac
    fi
fi
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
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  Stable (Default)\" {"
        echo "    loader  /vmlinuz-$KVER_STABLE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$STABLE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_STABLE"
        echo "    options \"$STABLE_OPTIONS\""
        echo "}"
        echo

        echo "menuentry \"$NCZ_RELEASE_SHORT  -  Stable Console\" {"
        echo "    loader  /vmlinuz-$KVER_STABLE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$STABLE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_STABLE"
        echo "    options \"$STABLE_CONSOLE_OPTIONS\""
        echo "}"
        echo
    fi
    if [ "$EDGE_AVAILABLE" = "1" ]; then
        echo "menuentry \"$NCZ_RELEASE_SHORT  -  Edge / Experimental Kernel (Console)\" {"
        echo "    loader  /vmlinuz-$KVER_EDGE"
        [ -n "$REFIND_ICON" ] && echo "    icon    /EFI/BOOT/$REFIND_ICON"
        [ "$EDGE_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_EDGE"
        echo "    options \"$EDGE_OPTIONS\""
        echo "}"
        echo
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
    # OPERATOR-STAGED RESCUE KERNELS. Preserved by the wipe above.
    for _rescue_img in /boot/efi/vmlinuz-*-rescue; do
        [ -e "$_rescue_img" ] || continue
        _rescue_file=${_rescue_img##*/}
        _rescue_tag=${_rescue_file#vmlinuz-}
        _rescue_tag=${_rescue_tag%-rescue}
        _rescue_options=$(printf '%s\n' "$STABLE_OPTIONS" | tr ' ' '\n' \
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
        for _bn in $(efibootmgr 2>/dev/null | grep -F "nclawzero (rEFInd)" | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p"); do
            efibootmgr -b "$_bn" -B >/dev/null 2>&1 || true
        done
        efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
            -L "nclawzero (rEFInd)" -l '\EFI\BOOT\BOOTX64.EFI' >/dev/null 2>&1 || true
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
