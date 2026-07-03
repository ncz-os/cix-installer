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
#
# ⚠ LAYER-COHERENCE RULE: the role deltas copy-up /var/lib/dpkg/status into
# their upperdir. If you change the PACKAGE SET of base.squashfs, the merged
# view keeps showing the OLD dpkg status from the delta — the new base
# packages become invisible to dpkg. Any apt/dpkg change to base REQUIRES
# rebuilding every role delta against the new base (config-only base changes
# in /etc are fine as long as the delta didn't copy-up the same file).
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
need mksquashfs
# NATIVE arm64 (e.g. bigpi) needs no qemu-user; x86 (ARGOS) does.
NATIVE=0; [ "$(uname -m)" = "aarch64" ] && NATIVE=1
[ "$NATIVE" = 1 ] || { [ -x "$QEMU" ] || { echo "no qemu-aarch64-static (x86 host needs it)"; exit 1; }; }
log "arch=$(uname -m) native=$NATIVE ROOT=$ROOT WORK=$WORK OUT=$OUT"
mkdir -p "$OUT" "$WORK"

# machine-AGNOSTIC hooks safe to bake into base (NOT desktop-config)
BASE_HOOKS="10-our-kernel 12-sky1-firmware 15-mesa-sky1-pin 16-mesa-gpu-2613"

mount_chroot(){ local c="$1"
  sudo mount -t proc proc "$c/proc"; sudo mount -t sysfs sys "$c/sys";
  sudo mount -o bind /dev "$c/dev"; sudo mount -o bind /dev/pts "$c/dev/pts";
  [ "$NATIVE" = 1 ] || sudo cp "$QEMU" "$c/usr/bin/"; sudo cp /etc/resolv.conf "$c/etc/resolv.conf" 2>/dev/null || true; }
umount_chroot(){ local c="$1"
  for m in dev/pts dev sys proc; do sudo umount -lf "$c/$m" 2>/dev/null || true; done; }

# offline apt sources -> bind BOTH mirrors (server-mirror has the base deps
# initramfs-tools/kmod that resolute-mirror lacks; build-iso prefers server-mirror
# for the base install). `resolute main` only (no universe component in the mirrors).
apt_offline(){ local c="$1"
  sudo rm -f "$c/etc/apt/sources.list"
  for m in server-mirror resolute-mirror desktop-mirror; do
    [ -d "$ROOT/build/$m/dists/resolute" ] || continue
    sudo mkdir -p "$c/mnt/$m"; sudo mount -o bind "$ROOT/build/$m" "$c/mnt/$m"
    echo "deb [trusted=yes] file:///mnt/$m resolute main" | sudo tee -a "$c/etc/apt/sources.list" >/dev/null
  done
  sudo chroot "$c" apt-get update -y 2>&1 | tail -4 || true; }
apt_unmount(){ local c="$1"; for m in server-mirror resolute-mirror desktop-mirror; do sudo umount -lf "$c/mnt/$m" 2>/dev/null || true; done; }

# build a ROLE delta layer: overlay(base=lower) + apt-install the package set into
# the upperdir, then squash ONLY the upperdir (the delta). NO NCZ desktop hooks.
build_layer(){ local role="$1" manifest="$2"
  [ -f "$OUT/base.squashfs" ] || { echo "base.squashfs missing — build base first"; exit 1; }
  [ -f "$ROOT/$manifest" ] || { echo "manifest $manifest missing"; exit 1; }
  local L="$WORK/$role-lower" U="$WORK/$role-up" WK="$WORK/$role-wk" MG="$WORK/$role-mg"
  sudo umount -lf "$MG" 2>/dev/null || true; sudo rm -rf "$L" "$U" "$WK" "$MG"
  log "$role: unsquash base as lowerdir"
  sudo unsquashfs -f -d "$L" "$OUT/base.squashfs" >/dev/null 2>&1
  mkdir -p "$U" "$WK" "$MG"
  sudo mount -t overlay overlay -o "lowerdir=$L,upperdir=$U,workdir=$WK" "$MG"
  mount_chroot "$MG"; apt_offline "$MG"
  echo -e '#!/bin/sh\nexit 101' | sudo tee "$MG/usr/sbin/policy-rc.d" >/dev/null; sudo chmod +x "$MG/usr/sbin/policy-rc.d"
  local pkgs; pkgs=$(grep -vE '^#|^[[:space:]]*$' "$ROOT/$manifest" | tr '\n' ' ')
  log "$role: apt-install $(echo $pkgs|wc -w) top-level packages (complete set + closure)"
  sudo chroot "$MG" apt-get install -y --no-install-recommends $pkgs 2>&1 | tail -6 || log "  WARN apt rc=$?"
  # r164: the resolute BASE ships the full GNOME desktop (gnome-shell + gdm3 +
  # ubuntu-session) and defaults /etc/X11/default-display-manager to gdm3, so
  # even after the XFCE manifest installs lightdm+xubuntu-core, gdm3 stays the
  # default DM and GNOME (heavy, and Wayland black-screens on Mali panthor per
  # 20-desktop.sh) is what boots. In the DESKTOP delta only, do what the excluded
  # 20-desktop.sh did: purge the GNOME stack + pin LightDM + default session XFCE.
  # This bakes an XFCE-default, GNOME-free desktop into desktop.squashfs (the
  # overlay whiteouts the base's gnome files, so the merged /target has no GNOME).
  if [ "$role" = "desktop" ]; then
    log "desktop: purge GNOME stack + pin LightDM + default session XFCE (r164)"
    sudo chroot "$MG" env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        gdm3 gnome-shell gnome-shell-common ubuntu-session gnome-session-bin \
        gnome-session-common ubuntu-desktop ubuntu-desktop-minimal 2>&1 | tail -4 || log "  WARN gnome purge rc=$?"
    sudo chroot "$MG" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge 2>&1 | tail -3 || true
    # Pin LightDM as the default display manager (debconf + the plain-file d-i reads).
    echo "/usr/sbin/lightdm" | sudo tee "$MG/etc/X11/default-display-manager" >/dev/null
    echo "set shared/default-x-display-manager select lightdm" | sudo chroot "$MG" debconf-set-selections 2>/dev/null || true
    echo "set lightdm shared/default-x-display-manager lightdm" | sudo chroot "$MG" debconf-set-selections 2>/dev/null || true
    sudo ln -sf /lib/systemd/system/lightdm.service "$MG/etc/systemd/system/display-manager.service"
    # Default session = XFCE for lightdm's greeter (autologin/user-session fallback).
    sudo mkdir -p "$MG/etc/lightdm/lightdm.conf.d"
    printf '[Seat:*]\nuser-session=xfce\n' | sudo tee "$MG/etc/lightdm/lightdm.conf.d/60-ncz-xfce.conf" >/dev/null
    # AccountsService per-user session is written at first login; the greeter
    # default above covers new users. update-alternatives keeps x-session-manager -> xfce4.
    sudo chroot "$MG" update-alternatives --set x-session-manager /usr/bin/xfce4-session 2>/dev/null || true
    # r164: apply NCZ branding hooks now that the desktop is XFCE. These are
    # cosmetic + best-effort (os-release/issue, wallpapers, XFCE icon theme, and
    # the plymouth spinner rebranded with the NCZ wordmark — operator wants the
    # xubuntu spinner kept, just NCZ-logo'd, which is exactly 60-plymouth's job).
    for bh in 50-brand 56-icon-theme 45-wallpaper-rotator 60-plymouth; do
      [ -f "$MG/usr/local/lib/cix-installer/post-install/$bh.sh" ] || { log "  skip $bh (absent)"; continue; }
      log "  desktop brand hook -> $bh"
      sudo chroot "$MG" bash -c "cd /usr/local/lib/cix-installer/post-install && bash ./$bh.sh" 2>&1 | tail -3 || log "  WARN $bh rc=$?"
    done
  fi
  sudo rm -f "$MG/usr/sbin/policy-rc.d"
  sudo chroot "$MG" apt-get clean 2>/dev/null || true
  apt_unmount "$MG"; umount_chroot "$MG"; sudo umount -lf "$MG" 2>/dev/null || true
  # clean transient from the UPPER delta only (keep dpkg status/alternatives copy-ups)
  sudo rm -rf "$U/var/lib/apt/lists/"* "$U/var/cache/apt/"* "$U/tmp/"* "$U/usr/bin/qemu-aarch64-static" 2>/dev/null || true
  log "$role: mksquashfs upperdir delta -> $OUT/$role.squashfs"
  sudo mksquashfs "$U" "$OUT/$role.squashfs" -comp zstd -Xcompression-level 15 -noappend -no-progress 2>&1 | tail -2
  log "$role DONE: delta $(du -h "$OUT/$role.squashfs"|cut -f1)"
  sudo rm -rf "$L" "$MG" "$WK"
}

build_base(){
  log "BASE: extract resolute base"
  sudo rm -rf "$WORK/base"; mkdir -p "$WORK/base"
  tar -I 'zstd -d' -xf "$BASE_TARBALL" -C "$WORK/base"
  mount_chroot "$WORK/base"
  # base hooks are local-asset (dpkg/copy) — the apt mirror is only needed for the
  # desktop/server layers, so skip apt_offline here if the mirror isn't present.
  if [ -d "$ROOT/build/server-mirror/dists/resolute" ] || [ -d "$ROOT/build/resolute-mirror/dists/resolute" ]; then apt_offline "$WORK/base"; else log "no mirror -> skipping apt_offline"; fi
  # stage the installer hook tree + assets the base hooks read
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer"
  sudo cp -a "$ROOT/post-install" "$WORK/base/usr/local/lib/cix-installer/"
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/assets"
  for a in cix-debs kernel mesa gpu sky1-firmware firmware refind rescue; do [ -d "$ROOT/assets/$a" ] && sudo cp -a "$ROOT/assets/$a" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true; done
  # KVER sidecars 10-our-kernel needs (build-iso normally derives these from assets/kernel/*/KVER)
  [ -f "$ROOT/assets/kernel/stable/KVER" ] && sudo cp "$ROOT/assets/kernel/stable/KVER" "$WORK/base/usr/local/lib/cix-installer/KVER_LTS"
  [ -f "$ROOT/assets/kernel/edge/KVER" ]   && sudo cp "$ROOT/assets/kernel/edge/KVER"   "$WORK/base/usr/local/lib/cix-installer/KVER_NEXT"
  # r160: stage the COMPLETE rEFInd asset set, falling back to build/refind-bin
  # for anything assets/refind didn't provide (on bigpi the NFS sync had only
  # build/refind-bin — assets/refind was absent, so r159's base shipped just the
  # binary and rEFInd rendered TEXT-ONLY without banner/icons; r128 lesson).
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/assets/refind"
  for f in refind_aa64.efi ncz.png ncz-banner.png; do
    [ -e "$WORK/base/usr/local/lib/cix-installer/assets/refind/$f" ] && continue
    [ -f "$ROOT/build/refind-bin/$f" ] && sudo cp "$ROOT/build/refind-bin/$f" "$WORK/base/usr/local/lib/cix-installer/assets/refind/"
  done
  if [ ! -d "$WORK/base/usr/local/lib/cix-installer/assets/refind/icons" ] && [ -d "$ROOT/build/refind-bin/icons" ]; then
    sudo cp -r "$ROOT/build/refind-bin/icons" "$WORK/base/usr/local/lib/cix-installer/assets/refind/"
  fi
  [ -f "$WORK/base/usr/local/lib/cix-installer/assets/refind/refind_aa64.efi" ] || log "  WARN: no refind_aa64.efi staged — 70-bootloader will fail at install"
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
  # r164: the resolute base tarball is a FULL GNOME desktop image (gnome-shell +
  # gdm3 + ubuntu-session + ubuntu-desktop, ~1.5-2GB). Operator decision: XFCE-only,
  # GNOME too heavy AND it Wayland-black-screens on the Mali panthor GPU. Purge the
  # GNOME desktop from the BASE (not just whiteout it in the desktop delta) so the
  # ISO actually shrinks. XFCE + LightDM are installed fresh in the desktop layer.
  # PROTECT the sky1 mesa + Xorg stack (pinned by 15/16-mesa hooks above) from
  # autoremove by marking it manual first, so removing gnome orphans can't drag
  # the GPU userland out with it.
  sudo chroot "$WORK/base" sh -c 'apt-mark manual $(dpkg-query -W -f="\${Package}\n" 2>/dev/null | grep -E "^(mesa-|libgl1|libglx|libegl|libgbm1|libglapi|xserver-xorg|xinit)") 2>/dev/null' || true
  log "BASE: purge GNOME desktop stack (XFCE-only, shrink ISO) — mesa/Xorg protected"
  sudo chroot "$WORK/base" env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
      gdm3 gnome-shell ubuntu-session ubuntu-desktop ubuntu-desktop-minimal 2>&1 | tail -6 || log "  WARN gnome purge rc=$?"
  sudo chroot "$WORK/base" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge 2>&1 | tail -4 || true
  # r160: DE-CLOUD the Ubuntu cloud rootfs (belt; the r160 install-time STUB
  # fixups are the braces — both are idempotent):
  #  - systemd-networkd (+ wait-online + dispatcher) is enabled alongside NM
  #    but has no .network config on NCZ → every boot stalls ~120s in
  #    systemd-networkd-wait-online. NM is the NCZ network manager.
  #  - 60-cloudimg-settings.conf forces PasswordAuthentication no; the fleet
  #    is LAN-only and requires the password fallback (doctrine: lockout
  #    recovery beats plaintext-on-LAN concerns). First-value-wins → 10-.
  sudo chroot "$WORK/base" systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service networkd-dispatcher.service 2>/dev/null || true
  sudo rm -f "$WORK/base/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
  sudo mkdir -p "$WORK/base/etc/ssh/sshd_config.d"
  printf 'PasswordAuthentication yes\n' | sudo tee "$WORK/base/etc/ssh/sshd_config.d/10-ncz-fleet.conf" >/dev/null
  # GOLDEN-IMAGE identity reset: empty machine-id (systemd regenerates on 1st boot),
  # drop ssh host keys + random-seed so every install gets a unique identity.
  sudo truncate -s 0 "$WORK/base/etc/machine-id" 2>/dev/null || echo -n | sudo tee "$WORK/base/etc/machine-id" >/dev/null
  sudo rm -f "$WORK/base/var/lib/dbus/machine-id" 2>/dev/null || true
  sudo ln -sf /etc/machine-id "$WORK/base/var/lib/dbus/machine-id" 2>/dev/null || true
  sudo rm -f "$WORK/base"/etc/ssh/ssh_host_* "$WORK/base/var/lib/systemd/random-seed" 2>/dev/null || true
  # cleanup
  sudo rm -f "$WORK/base/usr/sbin/policy-rc.d" "$WORK/base/usr/bin/qemu-aarch64-static"
  sudo chroot "$WORK/base" apt-get clean 2>/dev/null || true
  sudo rm -rf "$WORK/base/var/lib/apt/lists/"* "$WORK/base/tmp/"* 2>/dev/null || true
  apt_unmount "$WORK/base"; umount_chroot "$WORK/base"
  log "BASE: mksquashfs -> $OUT/base.squashfs"
  sudo mksquashfs "$WORK/base" "$OUT/base.squashfs" -comp zstd -Xcompression-level 15 -noappend -no-progress 2>&1 | tail -3
  log "BASE DONE: $(du -h "$OUT/base.squashfs"|cut -f1)"
}

case "$STAGE" in
  base)    build_base ;;
  desktop) build_layer desktop manifests/desktop.pkgs ;;
  server)  build_layer server  manifests/server.pkgs ;;
  all)     build_base; build_layer desktop manifests/desktop.pkgs; build_layer server manifests/server.pkgs ;;
  *) echo "usage: $0 base|desktop|server|all"; exit 2 ;;
esac
