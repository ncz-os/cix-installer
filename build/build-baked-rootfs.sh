#!/bin/bash
# build-baked-rootfs.sh — FULL BAKE: run the generic post-install hooks at BUILD
# time inside an arm64 chroot (network works, runs once, fails early), producing
# a fully-configured rootfs. The installer then only extracts this + runs the
# machine-specific hooks (fstab, bootloader, rescue, user). Replaces the fragile
# 30-hook in-chroot-at-install model.
#
# Run on ARGOS (x86 + qemu-aarch64-static + binfmt). Output: a baked rootfs.tar.zst.
set -uo pipefail
ROOT="${ROOT:-$HOME/cix-installer-build/cix-installer}"
BASE="${BASE:-$ROOT/assets/rootfs/rootfs-resolute-arm64.tar.zst}"
VARIANT="${VARIANT:-desktop}"
WORK="${WORK:-/tmp/ncz-bake}"
OUT="${OUT:-$ROOT/assets/rootfs/rootfs-resolute-arm64-baked.tar.zst}"
CHROOT="$WORK/chroot"
LOGDIR="$WORK/logs"

# Hooks to BAKE at build time (generic: drivers, desktop, agents, branding,
# apt-config). Machine-specific hooks stay at install: 09-diag-account (user),
# 33-network, 34-fstab (disk UUIDs), 37-failsafe, 38-recovery, 48-magnetar,
# 70-bootloader (ESP), 72-rescue-partition, 99-diagnostics, hostname/user-setup.
BAKE_HOOKS="10-our-kernel 12-sky1-firmware 15-mesa-sky1-pin 16-mesa-gpu-2613 \
20-desktop 22-display-fix 25-cix-proprietary 26-gpu-default-open 30-agents \
31-remote-access 32-quadlet-shim 35-fstrim-fix 35-ssh 36-telemetry 40-claude-code \
45-wallpaper-rotator 46-ncz-cli 46-python311 47-embedkit 47-llm-stack 50-brand \
56-icon-theme 60-plymouth 80-npu 92-buildkite-apt"

log(){ echo "[bake $(date +%H:%M:%S)] $*"; }
cleanup(){ for m in dev/pts dev proc sys run; do umount -lf "$CHROOT/$m" 2>/dev/null; done; }
trap cleanup EXIT

log "FULL BAKE start — variant=$VARIANT base=$BASE"
sudo rm -rf "$WORK"; mkdir -p "$CHROOT" "$LOGDIR"

log "extract base rootfs ($(du -h "$BASE"|cut -f1))..."
sudo tar -I 'zstd -d' -xpf "$BASE" -C "$CHROOT" || { log "FATAL extract"; exit 1; }

log "stage qemu + network + hooks + assets into chroot"
sudo cp /usr/bin/qemu-aarch64-static "$CHROOT/usr/bin/"
sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
sudo mkdir -p "$CHROOT/usr/local/lib/cix-installer"
sudo cp -a "$ROOT/post-install" "$CHROOT/usr/local/lib/cix-installer/"
sudo cp -a "$ROOT/assets" "$CHROOT/usr/local/lib/cix-installer/" 2>/dev/null || true
printf '%s' "$VARIANT" | sudo tee "$CHROOT/usr/local/lib/cix-installer/BUILD_VARIANT" >/dev/null

for m in proc sys dev dev/pts run; do sudo mkdir -p "$CHROOT/$m"; done
sudo mount -t proc proc "$CHROOT/proc"
sudo mount -t sysfs sys "$CHROOT/sys"
sudo mount --bind /dev "$CHROOT/dev"
sudo mount --bind /dev/pts "$CHROOT/dev/pts"
sudo mount -t tmpfs tmpfs "$CHROOT/run"

log "run BAKE hooks in chroot..."
FAILED=""
for h in $BAKE_HOOKS; do
  f="$CHROOT/usr/local/lib/cix-installer/post-install/$h.sh"
  [ -f "$f" ] || { log "  skip $h (absent)"; continue; }
  log "  -> $h"
  sudo chroot "$CHROOT" /bin/bash -c \
    "cd /usr/local/lib/cix-installer/post-install && DEBIAN_FRONTEND=noninteractive bash ./$h.sh" \
    > "$LOGDIR/$h.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then log "     ok"; else log "     FAILED rc=$rc (see $LOGDIR/$h.log)"; FAILED="$FAILED $h"; fi
done

log "clean chroot (apt cache, qemu, staging, logs)"
sudo chroot "$CHROOT" apt-get clean 2>/dev/null || true
sudo rm -f "$CHROOT/usr/bin/qemu-aarch64-static"
sudo rm -rf "$CHROOT/usr/local/lib/cix-installer/assets" "$CHROOT/var/lib/apt/lists/"* "$CHROOT/tmp/"* 2>/dev/null
cleanup

log "repack baked rootfs -> $OUT"
sudo tar -C "$CHROOT" -cpf - . | zstd -T0 -19 -o "$OUT" -f
log "DONE. baked=$(du -h "$OUT"|cut -f1)  FAILED_HOOKS:${FAILED:- none}"
[ -z "$FAILED" ]
