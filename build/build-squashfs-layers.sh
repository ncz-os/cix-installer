#!/bin/bash
# build-squashfs-layers.sh — NCZ-OS layered squashfs installer images.
#
# Produces (under assets/squashfs/):
#   base.squashfs      debootstrap resolute + CIX kernel/firmware/mesa + NM/bluez enabled
#   desktop.squashfs   DELTA: complete desktop package set (overlay upperdir only)
#   server.squashfs    DELTA: complete server package set (overlay upperdir only)
#
# Deliberately runs ONLY machine-AGNOSTIC hooks (kernel/firmware/mesa). The NCZ
# desktop-config hooks (20-desktop/33-network/brand/plymouth) are NOT run here —
# they corrupted net/BT/desktop in the chroot bake. Desktop/server content comes
# from a CLEAN apt-install (Ubuntu-live model). Machine-specific + branding run at
# install / first-boot, not baked.
#
# Runs on x86 ARGOS via qemu-aarch64-static + binfmt (same mechanism as the bake).
set -euo pipefail

ROOT="${ROOT:-$HOME/cix-installer-build/cix-installer}"
WORK="${WORK:-/tmp/ncz-sqfs}"
OUT="$ROOT/assets/squashfs"
BASE_TARBALL="$ROOT/assets/rootfs/rootfs-resolute-arm64.tar.zst"
MIRROR="$ROOT/build/resolute-mirror"          # offline apt source (deb + udeb)
QEMU="/usr/bin/qemu-aarch64-static"
STAGE="${1:-base}"                            # base | desktop | server | all

log(){ echo "[sqfs $(date -u +%H:%M:%S)] $*"; }
need(){ command -v "$1" >/dev/null || { echo "MISSING: $1"; exit 1; }; }
need mksquashfs; need debootstrap 2>/dev/null || true; [ -x "$QEMU" ] || { echo "no qemu-aarch64-static"; exit 1; }
mkdir -p "$OUT" "$WORK"

# machine-AGNOSTIC hooks safe to bake into base (NOT desktop-config)
BASE_HOOKS="10-our-kernel 12-sky1-firmware 15-mesa-sky1-pin 16-mesa-gpu-2613"

mount_chroot(){ local c="$1"
  sudo mount -t proc proc "$c/proc"; sudo mount -t sysfs sys "$c/sys";
  sudo mount -o bind /dev "$c/dev"; sudo mount -o bind /dev/pts "$c/dev/pts";
  sudo cp "$QEMU" "$c/usr/bin/"; sudo cp /etc/resolv.conf "$c/etc/resolv.conf" 2>/dev/null || true; }
umount_chroot(){ local c="$1"
  for m in dev/pts dev sys proc; do sudo umount -lf "$c/$m" 2>/dev/null || true; done; }

# offline apt sources -> point the chroot at the embedded resolute mirror served over file://
apt_offline(){ local c="$1"
  sudo mkdir -p "$c/mnt/mirror"
  sudo mount -o bind "$MIRROR" "$c/mnt/mirror"
  echo "deb [trusted=yes] file:///mnt/mirror resolute main universe" | sudo tee "$c/etc/apt/sources.list" >/dev/null
  sudo chroot "$c" apt-get update -y 2>&1 | tail -2 || true; }

build_base(){
  log "BASE: extract resolute base"
  sudo rm -rf "$WORK/base"; mkdir -p "$WORK/base"
  tar -I 'zstd -d' -xf "$BASE_TARBALL" -C "$WORK/base"
  mount_chroot "$WORK/base"; apt_offline "$WORK/base"
  # stage the installer hook tree + assets the base hooks read
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer"
  sudo cp -a "$ROOT/post-install" "$WORK/base/usr/local/lib/cix-installer/"
  for a in cix-debs kernel mesa gpu; do [ -d "$ROOT/assets/$a" ] && sudo cp -a "$ROOT/assets/$a" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true; done
  # policy-rc.d: block daemon starts in chroot
  echo -e '#!/bin/sh\nexit 101' | sudo tee "$WORK/base/usr/sbin/policy-rc.d" >/dev/null; sudo chmod +x "$WORK/base/usr/sbin/policy-rc.d"
  log "BASE: run machine-agnostic hooks: $BASE_HOOKS"
  for h in $BASE_HOOKS; do
    [ -f "$WORK/base/usr/local/lib/cix-installer/post-install/$h.sh" ] || { log "  skip $h (absent)"; continue; }
    log "  -> $h"
    sudo chroot "$WORK/base" bash -c "cd /usr/local/lib/cix-installer/post-install && bash ./$h.sh" 2>&1 | tail -3 || log "  WARN $h rc=$?"
  done
  # enable NetworkManager + bluetooth via presets (NOT the broken 33-network hook)
  sudo chroot "$WORK/base" systemctl enable NetworkManager bluetooth 2>/dev/null || true
  # cleanup
  sudo rm -f "$WORK/base/usr/sbin/policy-rc.d" "$WORK/base/usr/bin/qemu-aarch64-static"
  sudo chroot "$WORK/base" apt-get clean 2>/dev/null || true
  sudo rm -rf "$WORK/base/var/lib/apt/lists/"* "$WORK/base/tmp/"* 2>/dev/null || true
  sudo umount -lf "$WORK/base/mnt/mirror" 2>/dev/null || true; umount_chroot "$WORK/base"
  log "BASE: mksquashfs -> $OUT/base.squashfs"
  sudo mksquashfs "$WORK/base" "$OUT/base.squashfs" -comp zstd -Xcompression-level 15 -noappend -no-progress 2>&1 | tail -3
  log "BASE DONE: $(du -h "$OUT/base.squashfs"|cut -f1)"
}

case "$STAGE" in
  base) build_base ;;
  *) echo "usage: $0 base   (desktop/server layers land after base verifies)"; exit 2 ;;
esac
