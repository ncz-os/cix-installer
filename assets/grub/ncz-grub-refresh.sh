#!/bin/bash
# ncz-grub-refresh.sh — (re)generate the AMD64 dual-kernel GRUB menu.
#
# AMD64 analogue of assets/refind/ncz-refind-refresh.sh. rEFInd (arm64/Sky1)
# hand-authors manual stanzas because GPU-accelerator selection (Mali vs
# Panthor) has to be a boot-time choice on that hardware. AMD64 has no such
# choice to make at boot -- GPU compute is a post-install apt concern
# (post-install/54-gpu-accel.sh), not a kernel/cmdline one -- so the ONLY
# real reason for two entries here is the two kernel LINES themselves:
#   stable = T2-unified (7.2.6, DEFAULT)
#   edge   = vanilla mainline (7.3-rc3, EXPERIMENTAL, kept, never deleted)
#
# Installed as an executable /etc/grub.d/09_ncz_kernels script rather than
# relying on stock 10_linux, because 10_linux puts only the NEWEST kernel at
# the top level and buries every other one under an "Advanced options"
# submenu -- and by plain version-string comparison the newest is the EDGE
# line (7.3 > 7.2.6), which would make the untested kernel the silent
# default. Hand-authored top-level entries, in order (stable first == GRUB's
# default), are the same "never let the newest thing become the default
# just because it sorts higher" discipline
# ~/.claude/rules/kernel-build-checklist.md's rescue-entry rule already
# encodes for rEFInd -- ported here, not reinvented.
#
# Shared by two callers, same pattern as ncz-refind-refresh.sh:
#   - post-install/70-bootloader.sh (install time): reads the KVER_LIST_AMD64
#     sidecar (one KVER per line, stable first) written by
#     post-install/10-amd64-kernel.sh.
#   - /etc/kernel/postinst.d/zz1-ncz-grub-refresh (future apt kernel
#     install/upgrade): re-derives the same list from /boot/vmlinuz-*.
#
# Both callers export KVER_STABLE, KVER_EDGE, BUILD_VERSION before invoking
# this script -- it does no sidecar-file reading of its own, matching
# ncz-refind-refresh.sh's contract exactly.
set -euo pipefail

echo "[grub-refresh] KVER_STABLE=${KVER_STABLE:-<none>} KVER_EDGE=${KVER_EDGE:-<none>}"

[ -n "${KVER_STABLE:-}" ] || { echo "ERROR: KVER_STABLE not set" >&2; exit 1; }

# Root UUID: GRUB entries pin root=UUID=... rather than a device path, which
# survives disk renumbering (NVMe vs SATA enumeration order is not stable
# across a firmware/BIOS update the way people assume).
ROOT_DEV="$(findmnt -n -o SOURCE / )"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
if [ -z "$ROOT_UUID" ]; then
    echo "ERROR: could not resolve UUID for root device $ROOT_DEV" >&2
    exit 1
fi

GRUB_D=/etc/grub.d
CUSTOM=/etc/grub.d/09_ncz_kernels
DISTRIB="NCZ-OS"
[ -f /usr/local/lib/cix-installer/RELEASE ] && . /usr/local/lib/cix-installer/RELEASE
VER="${NCZ_RELEASE_VERSION:-${BUILD_VERSION:-unknown}}"

emit_entry() {
    local title="$1" kver="$2"
    [ -s "/boot/vmlinuz-$kver" ] || { echo "  WARN: /boot/vmlinuz-$kver missing -- skipping entry '$title'" >&2; return; }
    cat <<ENTRY
menuentry '$title' {
    load_video
    insmod gzio
    insmod part_gpt
    insmod fat
    insmod ext2
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    echo 'Loading Linux $kver ...'
    linux /boot/vmlinuz-$kver root=UUID=$ROOT_UUID rw quiet
    echo 'Loading initial ramdisk ...'
    initrd /boot/initrd.img-$kver
}
ENTRY
}

{
    echo "#!/bin/sh"
    echo "exec cat <<'GRUBEOF'"
    emit_entry "$DISTRIB $VER - $KVER_STABLE (Default)" "$KVER_STABLE"
    [ -n "${KVER_EDGE:-}" ] && emit_entry "$DISTRIB $VER - $KVER_EDGE (Experimental / Edge)" "$KVER_EDGE"
    echo "GRUBEOF"
} > "$CUSTOM"
chmod 0755 "$CUSTOM"
echo "  wrote $CUSTOM"

# Stable is first == GRUB's positional default (menuentry index 0). Pin it
# explicitly anyway (GRUB_DEFAULT=0 relies on position, which a future
# 10_linux-generated entry appearing ABOVE this custom script would break) --
# saved-default is more resilient to grub.d ordering changes than a bare
# index, and matches the "explicit, not implicit" posture the rEFInd side
# already takes with its manual stanzas.
install -d -m 0755 /etc/default
if [ -f /etc/default/grub ]; then
    sed -i -e 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
           -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' \
           /etc/default/grub
    grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
    grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub || echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub
    grep -q '^GRUB_TIMEOUT=' /etc/default/grub || echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
fi

update-grub
grub-set-default "$DISTRIB $VER - $KVER_STABLE (Default)"
echo "[grub-refresh] grub.cfg regenerated, default pinned to stable ($KVER_STABLE)"
