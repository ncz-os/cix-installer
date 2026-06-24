#!/bin/bash
# 72-rescue-partition.sh — populate the r130 dedicated RESCUE PARTITION.
#
# The partman recipe in preseed-ubuntu.cfg creates a 4 GiB ext4 partition
# (NCZRESCUE) with NO mountpoint on the main system. This hook fills it with
# the pre-built rescue rootfs (assets/rescue/rescue-rootfs.tar.zst) and the
# LTS kernel payload, then records a readiness marker.
#
# IMPORTANT — division of labour with 70-bootloader.sh:
#   This hook runs in Phase 2 (numbered hooks). 70-bootloader.sh runs LATER,
#   in run-all.sh's EXIT trap, and rewrites the ESP refind.conf + staged
#   vmlinuz-* every run. So the rEFInd "RESCUE PARTITION" menuentry is written
#   by 70-bootloader.sh (the sole ESP owner), gated on the RESCUE_READY marker
#   this hook leaves behind. Here we only touch the rescue PARTITION (never the
#   ESP), so nothing we do gets clobbered.
#
# r130.5 (operator): the dedicated rescue partition now ships the LTS 6.18
# kernel (assets/kernel/stable), NOT the edge 7.0.x. A recovery environment
# should be boring and reliable; the edge kernel's full accelerator/display
# probing caused "sloppy device startup". 70-bootloader.sh boots this partition
# with the same NPU/GPU/VPU/KMS module_blacklist as the rEFInd "rescue" entry.
set -uo pipefail   # NOT -e: optional Phase-2 hook, must fail soft

INSTALLER_META=/usr/local/lib/cix-installer
ASSETS_KERNEL="$INSTALLER_META/assets/kernel"
RESCUE_ASSETS="$INSTALLER_META/assets/rescue"
TARBALL="$RESCUE_ASSETS/rescue-rootfs.tar.zst"
MNT=/mnt/ncz-rescue
MARKER="$INSTALLER_META/RESCUE_READY"

echo "[72] rescue partition population"

# --- preconditions (skip soft) ---
KVER_LTS=""
[ -f "$INSTALLER_META/KVER_LTS" ] && KVER_LTS=$(cat "$INSTALLER_META/KVER_LTS" 2>/dev/null || true)
if [ -z "$KVER_LTS" ]; then
    echo "[72] no LTS kernel staged — cannot build a clean rescue partition; skipping"
    exit 0
fi
if [ ! -f "$TARBALL" ]; then
    echo "[72] $TARBALL not present (run build/build-rescue-rootfs.sh at bake time) — skipping"
    exit 0
fi
if [ ! -f "$ASSETS_KERNEL/stable/Image-cixmini.bin" ] || [ ! -f "$ASSETS_KERNEL/stable/modules-cixmini.tgz" ]; then
    echo "[72] LTS kernel assets missing under $ASSETS_KERNEL/stable — skipping"
    exit 0
fi
for t in blkid lsblk findmnt zstd tar depmod mkfs.ext4 e2label; do
    command -v "$t" >/dev/null 2>&1 || { echo "[72] missing tool $t — skipping rescue partition"; exit 0; }
done

# --- locate the rescue partition ---
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
ESP_SRC=$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)
echo "[72] root=$ROOT_SRC  esp=$ESP_SRC"

RESCUE_SRC=$(blkid -L NCZRESCUE 2>/dev/null || true)
if [ -z "$RESCUE_SRC" ]; then
    # by GPT partition label
    RESCUE_SRC=$(lsblk -rno NAME,PARTLABEL 2>/dev/null | awk '$2=="NCZRESCUE"{print "/dev/"$1}' | head -1)
fi
if [ -z "$RESCUE_SRC" ] && [ -n "$ROOT_SRC" ]; then
    # by elimination: a partition on the root disk that is neither / nor ESP
    DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
    if [ -n "$DISK" ]; then
        for p in $(lsblk -rno NAME,TYPE "/dev/$DISK" 2>/dev/null | awk '$2=="part"{print "/dev/"$1}'); do
            [ "$p" = "$ROOT_SRC" ] && continue
            [ "$p" = "$ESP_SRC" ] && continue
            RESCUE_SRC="$p"
            break
        done
    fi
fi
if [ -z "$RESCUE_SRC" ] || [ ! -b "$RESCUE_SRC" ]; then
    echo "[72] no rescue partition found (no NCZRESCUE, no spare partition) — skipping"
    echo "      block devices:"; lsblk 2>&1 | sed 's/^/        /' | head -20
    exit 0
fi
echo "[72] rescue partition = $RESCUE_SRC"

# Guard: never clobber the live root or ESP.
if [ "$RESCUE_SRC" = "$ROOT_SRC" ] || [ "$RESCUE_SRC" = "$ESP_SRC" ]; then
    echo "[72] refusing to use $RESCUE_SRC (it is the live root or ESP) — skipping"
    exit 0
fi

# --- ensure ext4 + label ---
FST=$(blkid -s TYPE -o value "$RESCUE_SRC" 2>/dev/null || true)
if [ "$FST" != "ext4" ]; then
    echo "[72] $RESCUE_SRC is '$FST' — formatting ext4 (NCZRESCUE)"
    mkfs.ext4 -F -L NCZRESCUE "$RESCUE_SRC" || { echo "[72] mkfs failed — skipping"; exit 0; }
else
    e2label "$RESCUE_SRC" NCZRESCUE 2>/dev/null || true
fi

# --- mount + extract rootfs ---
mkdir -p "$MNT"
umount "$MNT" 2>/dev/null || true
if ! mount "$RESCUE_SRC" "$MNT"; then
    echo "[72] mount $RESCUE_SRC failed — skipping"; exit 0
fi

echo "[72] extracting rescue rootfs -> $MNT"
if ! zstd -dc "$TARBALL" | tar -xpf - -C "$MNT" --numeric-owner; then
    echo "[72] rootfs extract failed — unmounting + skipping"
    umount "$MNT" 2>/dev/null || true
    exit 0
fi

# --- install EDGE kernel + modules into the rescue rootfs ---
# Modules MUST go in via --keep-directory-symlink (never plain -C /): the
# tarball carries a top-level lib/ entry, and on a usrmerge rootfs /lib is a
# symlink to usr/lib. A naive extract would clobber that symlink and orphan
# ld-linux — the exact failure mode this rescue env exists to repair.
echo "[72] installing LTS kernel $KVER_LTS into rescue rootfs"
install -D -m 0644 "$ASSETS_KERNEL/stable/Image-cixmini.bin" "$MNT/boot/vmlinuz-$KVER_LTS"
tar xzf "$ASSETS_KERNEL/stable/modules-cixmini.tgz" -C "$MNT/usr" --strip-components=0 --keep-directory-symlink
if [ ! -d "$MNT/usr/lib/modules/$KVER_LTS" ]; then
    echo "[72] WARN: modules tarball did not produce $MNT/usr/lib/modules/$KVER_LTS"
    ls "$MNT/usr/lib/modules/" 2>&1 | sed 's/^/        /'
else
    MODC=$(find "$MNT/usr/lib/modules/$KVER_LTS" -name '*.ko*' 2>/dev/null | wc -l)
    echo "[72] $MODC modules staged; running depmod"
    depmod -b "$MNT" "$KVER_LTS" 2>/dev/null || echo "[72] WARN: depmod returned non-zero"
fi

# initrd: reuse the main system's LTS initrd (generic; mounts root=PARTUUID).
# 70-bootloader.sh stages the ESP copy; this in-rootfs copy is for completeness.
if [ -s "/boot/initrd.img-$KVER_LTS" ]; then
    install -D -m 0644 "/boot/initrd.img-$KVER_LTS" "$MNT/boot/initrd.img-$KVER_LTS"
fi

# --- AGENTS.md (refresh from asset if present) ---
if [ -f "$RESCUE_ASSETS/AGENTS.md" ]; then
    install -m 0644 "$RESCUE_ASSETS/AGENTS.md" "$MNT/AGENTS.md"
    install -D -m 0644 "$RESCUE_ASSETS/AGENTS.md" "$MNT/root/AGENTS.md"
    echo "[72] AGENTS.md refreshed in rescue rootfs"
fi

# --- verify the usrmerge /lib symlink survived ---
if [ -L "$MNT/lib" ]; then
    echo "[72] OK: rescue /lib -> $(readlink "$MNT/lib") (usrmerge symlink intact)"
else
    echo "[72] WARN: rescue /lib is not a symlink — running fixlib"
    [ -x "$MNT/usr/local/sbin/ncz-rescue-fixlib" ] && chroot "$MNT" /usr/local/sbin/ncz-rescue-fixlib / 2>/dev/null || true
fi

# --- readiness marker for 70-bootloader.sh ---
RP_PARTUUID=$(blkid -s PARTUUID -o value "$RESCUE_SRC" 2>/dev/null || true)
{
    echo "PARTUUID=$RP_PARTUUID"
    echo "KVER=$KVER_LTS"
    echo "DEV=$RESCUE_SRC"
} > "$MARKER"
echo "[72] wrote marker $MARKER (PARTUUID=$RP_PARTUUID)"

# --- finish: sync, unmount, reclaim space ---
sync
umount "$MNT" 2>/dev/null || true
rm -f "$TARBALL" 2>/dev/null || true   # reclaim ~hundreds of MB on the main root
echo "[72] rescue partition ready — 70-bootloader.sh will add the loader entry"
exit 0
