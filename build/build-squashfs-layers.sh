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
  # r190.2: disable needrestart kernel hints -- same fix already applied in
  # build-baked-rootfs.sh and build-iso-di.sh, but never here. Without it,
  # needrestart pops an interactive whiptail "Pending kernel upgrade" msgbox
  # mid apt-get-install (the chroot's kernel version differs from the host's
  # running kernel) with no tty reader available, hanging the build
  # indefinitely (found 2026-07-05, desktop.squashfs rebuild #2 stalled ~30min
  # until manually killed).
  sudo mkdir -p "$MG/etc/needrestart/conf.d"
  printf '$nrconf{kernelhints} = 0;\n' | sudo tee "$MG/etc/needrestart/conf.d/99-squashfs-layer.conf" >/dev/null
  # r190.1: strip inline trailing comments too, not just whole-line ones --
  # a `pkg  # comment` line used to be passed to apt-get install VERBATIM
  # (comment text included), which corrupted the whole batch install and
  # silently dropped unrelated packages (librsvg2-bin, in the 2026-07-05
  # incident this fixes -- see project_cix_buildkite_mirror_2026_07_05).
  local pkgs; pkgs=$(sed 's/#.*//' "$ROOT/$manifest" | sed -E 's/[[:space:]]+$//' | grep -vE '^[[:space:]]*$' | tr '\n' ' ')
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
    log "desktop: SINGULARITY desktop delta (Wayland-only; XFCE/X11 removed) + brand"
    # 26.7 "Maximilian": Singularity Desktop (labwc/wlroots, GTK4) REPLACES XFCE.
    # No user-session=xfce, no x-session-manager -> xfce4, no 60-ncz-xfce.conf.
    # GREETER = greetd + regreet (GTK4, Mali) — NOT lightdm. 20-desktop.sh (run
    # as a brand hook below) does the real work: extract /opt/singularity,
    # install ncz-gpu-env/ncz-singularity + regreet binary/wrapper,
    # singularity.desktop (the ONLY session), make greetd the DM, curate
    # sessions, purge XFCE/Xorg remnants. 55-greeter writes the greetd/regreet
    # config. Remove any stale lightdm/XFCE pin from an earlier overlay base.
    sudo rm -f "$MG/etc/lightdm/lightdm.conf.d/60-ncz-xfce.conf" \
               "$MG/etc/lightdm/lightdm.conf.d/60-ncz-singularity.conf" \
               "$MG/etc/X11/default-display-manager" 2>/dev/null || true
    # r166: refresh the post-install hook tree in the overlay from the current
    # repo. The brand hooks below run from base's staged post-install (baked at
    # base-build time), so an edited hook (e.g. 60-plymouth's non-fatal apt
    # guard) would NOT take effect on a desktop-only rebuild without this.
    sudo cp -a "$ROOT/post-install/." "$MG/usr/local/lib/cix-installer/post-install/" 2>/dev/null || true
    # r166: stage the NCZ branding assets the brand hooks read. The base build
    # only staged cix-debs/kernel/mesa/gpu/firmware/refind/rescue — NOT branding —
    # so 45-wallpaper (needs assets/branding/wallpaper), 56-icon-theme (needs
    # assets/branding/icon-theme/NCZ) and 60-plymouth (needs assets/branding/logo/
    # nclawzero-lockup.jpg) all silently used stock defaults. Copy branding into
    # the overlay before the hooks run. (Base list also gains "branding" for the
    # next base rebuild; this desktop-layer copy makes it work without one.)
    if [ -d "$ROOT/assets/branding" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/branding"
      sudo cp -a "$ROOT/assets/branding/." "$MG/usr/local/lib/cix-installer/assets/branding/" 2>/dev/null || true
      log "  staged branding assets ($(find "$ROOT/assets/branding" -type f | wc -l | tr -d ' ') files)"
    fi
    # r181: stage the Vivaldi .deb so 52-vivaldi.sh installs the browser OFFLINE
    # (the MNEMOS + agent launchers Exec vivaldi-stable; epiphany can't play
    # YouTube on arm64). Self-contained .deb, no mirror/closure changes needed.
    if [ -d "$ROOT/assets/vivaldi" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/vivaldi"
      sudo cp -a "$ROOT/assets/vivaldi/." "$MG/usr/local/lib/cix-installer/assets/vivaldi/" 2>/dev/null || true
      log "  staged vivaldi assets ($(find "$ROOT/assets/vivaldi" -type f | wc -l | tr -d ' ') files)"
    fi
    # 26.7: stage the Singularity Desktop payload so 20-desktop.sh extracts
    # /opt/singularity into the overlay and bakes it into desktop.squashfs. The
    # blob is gitignored (build/build-singularity.sh produces it; supplied via
    # assets/singularity/ on the build host or NFS/ARGONAS).
    if [ -f "$ROOT/assets/singularity/singularity-opt.tgz" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/singularity"
      sudo cp -a "$ROOT/assets/singularity/singularity-opt.tgz" "$MG/usr/local/lib/cix-installer/assets/singularity/" 2>/dev/null || true
      log "  staged singularity payload ($(du -h "$ROOT/assets/singularity/singularity-opt.tgz" | cut -f1))"
    else
      log "  WARN: assets/singularity/singularity-opt.tgz ABSENT — 20-desktop will FAIL (run build/build-singularity.sh)"
    fi
    # 26.7: stage the regreet greeter binary so 20-desktop installs it to
    # /opt/regreet/bin. Gitignored build blob (fetch from .66:/tmp/regreet).
    if [ -f "$ROOT/assets/regreet/regreet" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/regreet"
      sudo cp -a "$ROOT/assets/regreet/regreet" "$MG/usr/local/lib/cix-installer/assets/regreet/" 2>/dev/null || true
      log "  staged regreet greeter ($(du -h "$ROOT/assets/regreet/regreet" | cut -f1))"
    else
      log "  WARN: assets/regreet/regreet ABSENT — greetd greeter will have NO UI (fetch .66:/tmp/regreet)"
    fi
    # r189.5: stage assets/cix-py/ so 46-ncz-cli.sh's /opt/cix/npu_embed_v2.py
    # install actually lands -- it was only ever looking at /cdrom, which
    # doesn't exist in this chroot (install-media-only mount), so this was
    # silently skipped on every baked image.
    if [ -d "$ROOT/assets/cix-py" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/cix-py"
      sudo cp -a "$ROOT/assets/cix-py/." "$MG/usr/local/lib/cix-installer/assets/cix-py/" 2>/dev/null || true
      log "  staged cix-py assets ($(find "$ROOT/assets/cix-py" -type f | wc -l | tr -d ' ') files)"
    fi
    # r189.6: stage assets/mgmt/ncz-mgmt-rootfs.tar.zst so 38-recovery-container.sh
    # can extract the ncz-recovery nspawn container. Per its own r138 comment
    # this hook runs on ALL variants (not just Magnetar/server) since the
    # 2026-06-25 desktop-host lockout showed the failure mode is variant-
    # agnostic; the asset was never staged so the hook always hard-failed.
    if [ -f "$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/mgmt"
      sudo cp -a "$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst" "$MG/usr/local/lib/cix-installer/assets/mgmt/" 2>/dev/null || true
      log "  staged mgmt rootfs ($(du -h "$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst" | cut -f1))"
    fi
    # r189.2: dropped the r181 zoder-binary staging block. 30-agents.sh no
    # longer installs a staged binary at all -- it now always installs zoder
    # via the official GitLab installer (post-install/30-agents.sh, commits
    # d73d581/8d75ea5), so assets/zoder/ was dead weight this hook silently
    # skipped every build anyway (the directory hasn't existed since
    # 2026-07-05).
    # r172: apply the desktop-config + branding hooks now that the desktop is
    # XFCE. 22-display-fix is CRITICAL on Sky1 metal: the SoC exposes ~6 DRM
    # cards (card0=panthor render + card1-5=linlondp display pipes), and Xorg
    # with no card pin dies "Cannot run in framebuffer mode, specify busIDs" →
    # NO DESKTOP (observed r171 on .66 metal — qemu has 1 card so it never
    # surfaced). The hook installs the cix-detect-display boot service +
    # /etc/X11/xorg.conf.d/10-cixmini-primary-display.conf that pins the
    # connected linlondp display card each boot (handles card-renumber races).
    # 50-brand/56-icon/45-wallpaper/55-greeter follow (cosmetic, best-effort).
    # r181: 30-agents + 46-ncz-cli were EXCLUDED here (same bug class as the
    # r172 22-display-fix exclusion) — so /etc/skel/Desktop shipped EMPTY on .66
    # metal: no "ncz" CLI, no "NCZ CLI" launcher, no "⭐ Install AI Agents &
    # MNEMOS" launcher (operator report). They write the desktop launchers + the
    # ncz operator CLI, so BAKE them here. 30-agents (set +e, no apt purge) MUST
    # precede 46-ncz-cli (which overwrites /usr/local/bin/ncz with the unified CLI
    # that execs the agent helper 30-agents stages at /usr/local/lib/ncz-agent-cli).
    # 55-greeter = new dark+magenta LightDM greeter (the safe cosmetic subset of
    # 20-desktop.sh's greeter config; 20-desktop is deliberately NOT baked here —
    # its `apt purge --auto-remove` corrupted the user DB in the overlay, the
    # r166-r170 saga). 60-plymouth LAST (rebuilds the initramfs, heaviest step).
    # 26.7 Singularity brand-hook order. 20-desktop = the Singularity installer
    # (extracts /opt/singularity, curates sessions, purges XFCE/Xorg) — runs
    # FIRST so the Wayland desktop exists before the cosmetic hooks. 84-vpu-mpv
    # writes /etc/mpv HW-decode. 57-screensaver DROPPED (X11 xscreensaver — the
    # desktop is Wayland-only now). 30-agents before 46-ncz-cli (dep order).
    for bh in 20-desktop 22-display-fix 50-brand 52-vivaldi 56-icon-theme 45-wallpaper-rotator 55-greeter 84-vpu-mpv 57-qotd 30-agents 46-ncz-cli 60-plymouth; do
      [ -f "$MG/usr/local/lib/cix-installer/post-install/$bh.sh" ] || { log "  skip $bh (absent)"; continue; }
      log "  desktop brand hook -> $bh"
      sudo chroot "$MG" bash -c "cd /usr/local/lib/cix-installer/post-install && bash ./$bh.sh" 2>&1 | tail -3 || log "  WARN $bh rc=$?"
    done
    # Belt-and-braces: whiteout any X11-session .desktop remnants so the MERGED
    # /target has NO X11 desktop session. FILE-only removal (no apt purge in the
    # overlay — the r166-r170 saga: a broad purge --auto-remove here ran ~80
    # maintainer scripts that truncated the target's user DB). XFCE is never
    # installed anyway (desktop.pkgs dropped xubuntu-core/xfce4-*), so there is
    # nothing to purge; just guarantee no xsessions ship. Xwayland is KEPT
    # (/usr/bin/Xwayland from the xwayland pkg, not an X11 session).
    sudo rm -rf "$MG/usr/share/xsessions" "$MG/usr/share/xsessions.disabled" 2>/dev/null || true
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
  # r190.2: same needrestart-hang fix as build_layer() below -- base hooks
  # (10-our-kernel etc) also apt-install packages and can hit the same
  # interactive "Pending kernel upgrade" whiptail hang.
  sudo mkdir -p "$WORK/base/etc/needrestart/conf.d"
  printf '$nrconf{kernelhints} = 0;\n' | sudo tee "$WORK/base/etc/needrestart/conf.d/99-squashfs-layer.conf" >/dev/null
  # base hooks are local-asset (dpkg/copy) — the apt mirror is only needed for the
  # desktop/server layers, so skip apt_offline here if the mirror isn't present.
  if [ -d "$ROOT/build/server-mirror/dists/resolute" ] || [ -d "$ROOT/build/resolute-mirror/dists/resolute" ]; then apt_offline "$WORK/base"; else log "no mirror -> skipping apt_offline"; fi
  # stage the installer hook tree + assets the base hooks read
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer"
  sudo cp -a "$ROOT/post-install" "$WORK/base/usr/local/lib/cix-installer/"
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/assets"
  for a in cix-debs kernel mesa gpu sky1-firmware firmware refind rescue branding; do [ -d "$ROOT/assets/$a" ] && sudo cp -a "$ROOT/assets/$a" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true; done
  # prune dev-only junk from the staged asset tree (backup kernels, retired
  # channels) -- it otherwise ships inside base.squashfs as dead weight
  sudo rm -rf "$WORK/base/usr/local/lib/cix-installer/assets/kernel/"retired-* 2>/dev/null || true
  sudo find "$WORK/base/usr/local/lib/cix-installer/assets" \( -name "*.pre-*" -o -name "*.bak" -o -name "*.r57-bak" \) -delete 2>/dev/null || true
  # test/validation debs are SKIPPED by 25-cix-proprietary at install time
  # (see its DEBS filter) and consumed by nothing else -- do not bake ~2.2G
  # of dead weight into base.squashfs
  sudo rm -f "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-unit-test_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-ltp_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-gpu-test_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-vpu-test_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-npu-onnxruntime_*.deb 2>/dev/null || true
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
  # r164: make NetworkManager manage ETHERNET too. The Ubuntu desktop base ships
  # /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf =
  #   unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma
  # i.e. NM handles ONLY wifi and leaves ethernet to systemd-networkd — which we
  # just disabled (de-cloud, above). Net result on real hardware: the wired NIC
  # is 'unmanaged' and never gets DHCP (wifi works, ethernet dead — observed .66).
  # Override so NM also manages ethernet; NM-only model, no networkd needed.
  sudo mkdir -p "$WORK/base/etc/NetworkManager/conf.d"
  sudo tee "$WORK/base/etc/NetworkManager/conf.d/10-ncz-manage-ethernet.conf" >/dev/null <<'NMETH'
[keyfile]
unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma,except:type:ethernet
NMETH
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
