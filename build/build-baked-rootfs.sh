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
sudo mkdir -p "$CHROOT/usr/local/lib/cix-installer/assets"
for _d in cix-debs kernel rescue refind branding models python311 gpu mgmt diag npu plymouth wallpaper; do
  [ -d "$ROOT/assets/$_d" ] && sudo cp -a "$ROOT/assets/$_d" "$CHROOT/usr/local/lib/cix-installer/assets/" 2>/dev/null || true
done   # deliberately EXCLUDES assets/rootfs (base tarballs + baked output)
# stage install-time-hook binaries that live OUTSIDE assets/ in the repo so the
# baked image is self-contained (70-bootloader needs refind_aa64.efi in /target).
sudo mkdir -p "$CHROOT/usr/local/lib/cix-installer/assets/refind"
[ -f "$ROOT/build/refind-bin/refind_aa64.efi" ] && sudo cp "$ROOT/build/refind-bin/refind_aa64.efi" "$CHROOT/usr/local/lib/cix-installer/assets/refind/" || true
printf '%s' "$VARIANT" | sudo tee "$CHROOT/usr/local/lib/cix-installer/BUILD_VARIANT" >/dev/null
# stage kernel-version sidecars so 10-our-kernel finds them (build-iso.sh stages
# these at ISO time; the bake must too).
KM="$CHROOT/usr/local/lib/cix-installer"
[ -f "$KM/assets/kernel/stable/KVER" ] && sudo cp "$KM/assets/kernel/stable/KVER" "$KM/KVER_LTS"
[ -f "$KM/assets/kernel/edge/KVER" ]   && sudo cp "$KM/assets/kernel/edge/KVER"   "$KM/KVER_NEXT"

for m in proc sys dev dev/pts run; do sudo mkdir -p "$CHROOT/$m"; done
sudo mount -t proc proc "$CHROOT/proc"
sudo mount -t sysfs sys "$CHROOT/sys"
sudo mount --bind /dev "$CHROOT/dev"
sudo mount --bind /dev/pts "$CHROOT/dev/pts"
sudo mount -t tmpfs tmpfs "$CHROOT/run"

# Set up apt sources (ports.ubuntu.com) + update BEFORE the hooks so the first
# hook (10-our-kernel) can apt-get install initramfs-tools etc. The base rootfs
# ships no usable sources; 20-desktop set them up itself but runs after kernel.
log "configure apt sources in chroot (ports.ubuntu.com) + update"
sudo chroot "$CHROOT" /bin/bash -c 'cat > /etc/apt/sources.list <<APT
deb http://ports.ubuntu.com/ubuntu-ports resolute main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-security main universe restricted multiverse
APT
DEBIAN_FRONTEND=noninteractive apt-get update' > "$LOGDIR/00-apt-setup.log" 2>&1 || log "  WARN apt-get update issues (see 00-apt-setup.log)"

# codex: block daemon starts during bake (postinst scripts try systemctl start)
printf '#!/bin/sh\nexit 101\n' | sudo tee "$CHROOT/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$CHROOT/usr/sbin/policy-rc.d"

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

# codex: a failed REQUIRED hook must NOT produce a shippable image.
for req in 10-our-kernel 12-sky1-firmware 33-network ; do
  case " $FAILED " in *" $req "*) log "ABORT: required hook $req failed; not packing"; exit 2 ;; esac
done
log "clean chroot (apt cache, qemu, staging, logs)"
sudo chroot "$CHROOT" apt-get clean 2>/dev/null || true
sudo rm -f "$CHROOT/usr/bin/qemu-aarch64-static" "$CHROOT/usr/sbin/policy-rc.d"
# codex CRITICAL: reset cloned identity so every installed machine is unique.
sudo chroot "$CHROOT" /bin/sh -c '\
  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub ; \
  : > /etc/machine-id ; rm -f /var/lib/dbus/machine-id ; \
  rm -f /var/lib/systemd/random-seed /var/lib/urandom/random-seed /var/lib/NetworkManager/secret_key ; \
  rm -rf /var/lib/dhcp/* /var/lib/NetworkManager/*.lease /tmp/* /var/tmp/* ; \
  find /var/log -type f -delete 2>/dev/null ; true'
# first-boot identity regen (ssh host keys regenerate via ssh-keygen -A; machine-id via systemd).
sudo mkdir -p "$CHROOT/usr/local/lib/ncz"
printf '#!/bin/sh\n[ -s /etc/machine-id ] || systemd-machine-id-setup\nssh-keygen -A 2>/dev/null\nsystemctl disable ncz-firstboot-identity.service 2>/dev/null\n' | sudo tee "$CHROOT/usr/local/lib/ncz/firstboot-identity.sh" >/dev/null
sudo chmod 0755 "$CHROOT/usr/local/lib/ncz/firstboot-identity.sh"
printf '[Unit]\nDescription=NCZ first-boot identity regen\nBefore=ssh.service\nConditionFirstBoot=yes\n[Service]\nType=oneshot\nExecStart=/usr/local/lib/ncz/firstboot-identity.sh\n[Install]\nWantedBy=multi-user.target\n' | sudo tee "$CHROOT/etc/systemd/system/ncz-firstboot-identity.service" >/dev/null
sudo chroot "$CHROOT" systemctl enable ncz-firstboot-identity.service 2>/dev/null || true
# drop the build-host resolver (installed system manages its own).
sudo rm -f "$CHROOT/etc/resolv.conf"
# PRESERVE machine-hook assets (70-bootloader needs assets/refind; 72-rescue needs rescue+kernel);
# drop only the bulky cix-debs already dpkg-installed at bake.
A="$CHROOT/usr/local/lib/cix-installer/assets"
for _g in cix-debs models python311 gpu mgmt npu wallpaper branding plymouth; do sudo rm -rf "$A/$_g" 2>/dev/null; done
# strip stale kernel backups, keep the active Image/KVER/modules for 72-rescue
sudo find "$A/kernel" -name "*.pre-*" -o -name "*.bak*" 2>/dev/null | sudo xargs -r rm -f 2>/dev/null || true
sudo rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/tmp/"* 2>/dev/null
cleanup

# mark the rootfs as fully-baked so run-all.sh runs only machine-specific hooks at install.
echo "baked $(date -u +%Y-%m-%dT%H:%M:%SZ) by build-baked-rootfs.sh" | sudo tee "$CHROOT/usr/local/lib/cix-installer/BAKED" >/dev/null

log "repack baked rootfs -> $OUT"
sudo tar -C "$CHROOT" -cpf - . | zstd -T0 -19 -o "$OUT" -f
log "DONE. baked=$(du -h "$OUT"|cut -f1)  FAILED_HOOKS:${FAILED:- none}"
[ -z "$FAILED" ]
