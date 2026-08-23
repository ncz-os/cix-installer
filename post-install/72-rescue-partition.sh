#!/bin/bash
# 72-rescue-partition.sh — populate the r130 dedicated RESCUE PARTITION.
#
# The partman recipe in preseed.cfg creates a 4 GiB ext4 partition
# (NCZRESCUE) with NO mountpoint on the main system. This hook fills it with
# the pre-built rescue rootfs (assets/rescue/rescue-rootfs.tar.zst) and the
# shipping kernel payload, then records a readiness marker.
#
# IMPORTANT — division of labour with 70-bootloader.sh:
#   This hook runs in Phase 2 (numbered hooks). 70-bootloader.sh runs LATER,
#   in run-all.sh's EXIT trap, and rewrites the ESP refind.conf + staged
#   vmlinuz-* every run. So the rEFInd "RESCUE PARTITION" menuentry is written
#   by 70-bootloader.sh (the sole ESP owner), gated on the RESCUE_READY marker
#   this hook leaves behind. Here we only touch the rescue PARTITION (never the
#   ESP), so nothing we do gets clobbered.
#
# 2026-08-11 (operator: "we are 7.2 only now"): the rescue partition ships
# the SHIPPING (edge) kernel from assets/kernel/edge. It used to ship
# legacy 7.0.12 on the "a recovery env should be boring" principle, which
# was right while two kernels existed. With one kernel that rule would leave
# the rescue partition carrying modules for a kernel no longer built --
# exactly the state found on O6N, where the rescue partition held only 7.0.12
# modules.
#
# 70-bootloader.sh boots this partition with the NORMAL cmdline (display
# drivers KEPT) so the local console is usable; we do NOT apply the
# rescue.target KMS/display blacklist here (that earlier left the rescue
# screen blank).
set -uo pipefail

INSTALLER_META=/usr/local/lib/cix-installer
ASSETS_KERNEL="$INSTALLER_META/assets/kernel"
RESCUE_ASSETS="$INSTALLER_META/assets/rescue"
TARBALL="$RESCUE_ASSETS/rescue-rootfs.tar.zst"
MNT=/mnt/ncz-rescue
MARKER="$INSTALLER_META/RESCUE_READY"

echo "[72] rescue partition population"

# --- preconditions (skip soft) ---
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
if [ -z "$KVER_NEXT" ]; then
    echo "[72] ERROR: no KVER_NEXT sidecar — cannot build a rescue partition" >&2
    exit 1
fi
if [ ! -f "$TARBALL" ]; then
    echo "[72] ERROR: $TARBALL not present (run build/build-rescue-rootfs.sh at bake time)" >&2
    exit 1
fi
if [ ! -f "$ASSETS_KERNEL/edge/Image-cixmini.bin" ] || [ ! -f "$ASSETS_KERNEL/edge/modules-cixmini.tgz" ]; then
    echo "[72] ERROR: shipping kernel assets missing under $ASSETS_KERNEL/edge" >&2
    exit 1
fi
for t in blkid lsblk findmnt zstd tar depmod; do
    command -v "$t" >/dev/null 2>&1 || { echo "[72] ERROR: missing required tool $t" >&2; exit 1; }
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
    echo "[72] ERROR: no rescue partition found (no NCZRESCUE, no spare partition)" >&2
    echo "      block devices:"; lsblk 2>&1 | sed 's/^/        /' | head -20
    exit 1
fi
echo "[72] rescue partition = $RESCUE_SRC"

# Guard: never clobber the live root or ESP.
if [ "$RESCUE_SRC" = "$ROOT_SRC" ] || [ "$RESCUE_SRC" = "$ESP_SRC" ]; then
    echo "[72] ERROR: refusing to use $RESCUE_SRC (it is the live root or ESP)" >&2
    exit 1
fi

# --- ensure ext4 + label ---
FST=$(blkid -s TYPE -o value "$RESCUE_SRC" 2>/dev/null || true)
if [ "$FST" != "ext4" ]; then
    command -v mkfs.ext4 >/dev/null 2>&1 || {
        echo "[72] ERROR: $RESCUE_SRC is '$FST' and mkfs.ext4 is unavailable" >&2
        exit 1
    }
    echo "[72] $RESCUE_SRC is '$FST' — formatting ext4 (NCZRESCUE)"
    mkfs.ext4 -F -L NCZRESCUE "$RESCUE_SRC" || { echo "[72] ERROR: mkfs failed" >&2; exit 1; }
else
    command -v e2label >/dev/null 2>&1 && e2label "$RESCUE_SRC" NCZRESCUE 2>/dev/null || true
fi

# --- mount + extract rootfs ---
mkdir -p "$MNT"
umount "$MNT" 2>/dev/null || true
if ! mount "$RESCUE_SRC" "$MNT"; then
    echo "[72] ERROR: mount $RESCUE_SRC failed" >&2; exit 1
fi

echo "[72] extracting rescue rootfs -> $MNT"
if ! zstd -dc "$TARBALL" | tar -xpf - -C "$MNT" --numeric-owner; then
    echo "[72] rootfs extract failed — unmounting + skipping"
    umount "$MNT" 2>/dev/null || true
    exit 1
fi

# Every installed rescue partition needs its own D-Bus identity and SSH host
# keys. The golden archive deliberately carries neither, so keys from one NCZ
# device cannot impersonate another rescue environment.
echo "[72] generating per-device rescue machine-id + SSH host keys"
rm -f "$MNT/etc/machine-id" "$MNT/var/lib/dbus/machine-id" \
      "$MNT"/etc/ssh/ssh_host_*
if ! chroot "$MNT" systemd-machine-id-setup >/dev/null 2>&1 || \
   [ ! -s "$MNT/etc/machine-id" ]; then
    echo "[72] ERROR: could not generate rescue machine-id" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
mkdir -p "$MNT/var/lib/dbus"
ln -sf /etc/machine-id "$MNT/var/lib/dbus/machine-id"
if ! chroot "$MNT" ssh-keygen -A >/dev/null 2>&1 || \
   [ ! -s "$MNT/etc/ssh/ssh_host_ed25519_key" ]; then
    echo "[72] ERROR: could not generate rescue SSH host keys" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
echo "[72]   rescue identity and SSH host keys generated"

# --- auto-network + remote recovery access (operator directive 2026-07-29) ---
# A rescue partition that can't be reached over the network is useless when
# the failure being recovered from is a bricked main-kernel boot -- physical
# console access may not be available. The baked ncz-rescue-net units provide
# bounded DHCP plus a static fallback; ssh is also baked and enabled. This hook
# validates that release contract and removes stale competing networkd wiring.
echo "[72] verifying rescue rootfs auto-network + remote access"
# The rescue image already ships one authoritative, time-bounded network owner:
# ncz-rescue-net (dhclient/udhcpc) plus ncz-rescue-net-fallback. Do not also
# enable systemd-networkd for the same NIC; v17 shipped both and produced a DHCP
# ownership race. Remove any stale networkd wiring/config from an older image.
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
      "$MNT/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"
rm -f "$MNT/etc/systemd/network/20-wired-dhcp.network"
if [ ! -x "$MNT/usr/local/sbin/ncz-rescue-net" ] || \
   [ ! -x "$MNT/usr/local/sbin/ncz-rescue-net-fallback" ] || \
   [ ! -L "$MNT/etc/systemd/system/multi-user.target.wants/ncz-rescue-net.service" ] || \
   [ ! -L "$MNT/etc/systemd/system/multi-user.target.wants/ncz-rescue-net-fallback.service" ]; then
    echo "[72] ERROR: rescue rootfs lacks enabled ncz-rescue-net DHCP/fallback units" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
if [ -f "$MNT/usr/lib/systemd/system/ssh.service" ]; then
    mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/ssh.service "$MNT/etc/systemd/system/multi-user.target.wants/ssh.service"
    echo "[72]   ssh.service enabled"
else
    echo "[72] ERROR: ssh.service not present in rescue rootfs image" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
if [ -f "$MNT/usr/lib/systemd/system/inetd.service" ] || [ -x "$MNT/usr/sbin/telnetd" ] || [ -x "$MNT/usr/sbin/in.telnetd" ]; then
    mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    for svc in inetd.service telnet.socket; do
        [ -f "$MNT/usr/lib/systemd/system/$svc" ] && ln -sf "/usr/lib/systemd/system/$svc" "$MNT/etc/systemd/system/multi-user.target.wants/$svc"
    done
    echo "[72]   telnet available and enabled (console fallback, LAN-only per fleet doctrine)"
fi
echo "[72] auto-network + remote access verified (single owner: ncz-rescue-net)"

# --- install shipping kernel + modules into the rescue rootfs ---
# Modules MUST go in via --keep-directory-symlink (never plain -C /): the
# tarball carries a top-level lib/ entry, and on a usrmerge rootfs /lib is a
# symlink to usr/lib. A naive extract would clobber that symlink and orphan
# ld-linux — the exact failure mode this rescue env exists to repair.
echo "[72] installing shipping kernel $KVER_NEXT into rescue rootfs"
install -D -m 0644 "$ASSETS_KERNEL/edge/Image-cixmini.bin" "$MNT/boot/vmlinuz-$KVER_NEXT"
tar xzf "$ASSETS_KERNEL/edge/modules-cixmini.tgz" -C "$MNT/usr" --strip-components=0 --keep-directory-symlink
if [ ! -d "$MNT/usr/lib/modules/$KVER_NEXT" ]; then
    echo "[72] WARN: modules tarball did not produce $MNT/usr/lib/modules/$KVER_NEXT"
    ls "$MNT/usr/lib/modules/" 2>&1 | sed 's/^/        /'
else
    MODC=$(find "$MNT/usr/lib/modules/$KVER_NEXT" -name '*.ko*' 2>/dev/null | wc -l)
    echo "[72] $MODC modules staged; running depmod"
    depmod -b "$MNT" "$KVER_NEXT" 2>/dev/null || echo "[72] WARN: depmod returned non-zero"
fi

# initrd: reuse the main system's edge initrd (generic; mounts root=PARTUUID).
# 70-bootloader.sh stages the ESP copy; this in-rootfs copy is for completeness.
if [ -s "/boot/initrd.img-$KVER_NEXT" ]; then
    install -D -m 0644 "/boot/initrd.img-$KVER_NEXT" "$MNT/boot/initrd.img-$KVER_NEXT"
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
    echo "KVER=$KVER_NEXT"
    echo "DEV=$RESCUE_SRC"
} > "$MARKER"
echo "[72] wrote marker $MARKER (PARTUUID=$RP_PARTUUID)"

# --- hide the rescue partition from the desktop (udisks/gvfs/xfdesktop) ---
# It is an internal volume (HintSystem=true), so its auto-shown desktop icon
# cannot be mounted by an unprivileged click -- udisks polkit returns
# NotAuthorized (operator-reported 2026-06-25). UDISKS_IGNORE removes it from
# the volume list entirely; admins still sudo-mount it when needed.
install -d -m 0755 /etc/udev/rules.d
cat > /etc/udev/rules.d/99-ncz-rescue-hide.rules <<'UDEV'
# NCZ rescue partition: internal system volume, not user-mountable data.
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="NCZRESCUE", ENV{UDISKS_IGNORE}="1"
UDEV
echo "[72] udev rule installed: NCZRESCUE hidden from desktop (UDISKS_IGNORE)"

# --- finish: sync, unmount, reclaim space ---
sync
umount "$MNT" 2>/dev/null || true
rm -f "$TARBALL" 2>/dev/null || true   # reclaim ~hundreds of MB on the main root
echo "[72] rescue partition ready — 70-bootloader.sh will add the loader entry"
exit 0
