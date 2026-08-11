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
BASE_TARBALL="${BASE_TARBALL:-$ROOT/assets/rootfs/rootfs-resolute-arm64.tar.zst}"
APT_SUITE="${APT_SUITE:-resolute}"
APT_COMPONENTS="${APT_COMPONENTS:-main}"
MIRROR_DIRS="${MIRROR_DIRS:-server-mirror resolute-mirror desktop-mirror}"
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

# Offline apt sources are profile-driven so a parallel Debian Testing build
# cannot accidentally consume a Resolute mirror.
mirror_available(){ local m; for m in $MIRROR_DIRS; do [ -d "$ROOT/build/$m/dists/$APT_SUITE" ] && return 0; done; return 1; }
apt_offline(){ local c="$1"
  sudo rm -f "$c/etc/apt/sources.list"
  for m in $MIRROR_DIRS; do
    [ -d "$ROOT/build/$m/dists/$APT_SUITE" ] || continue
    sudo mkdir -p "$c/mnt/$m"; sudo mount -o bind "$ROOT/build/$m" "$c/mnt/$m"
    echo "deb [trusted=yes] file:///mnt/$m $APT_SUITE $APT_COMPONENTS" | sudo tee -a "$c/etc/apt/sources.list" >/dev/null
  done
  sudo chroot "$c" apt-get update -y 2>&1 | tail -4 || true; }
apt_unmount(){ local c="$1"; for m in $MIRROR_DIRS; do sudo umount -lf "$c/mnt/$m" 2>/dev/null || true; done; }

# build a ROLE delta layer: overlay(base=lower) + apt-install the package set into
# the upperdir, then squash ONLY the upperdir (the delta). NO NCZ desktop hooks.
build_layer(){ local role="$1" manifest="$2"
  [ -f "$OUT/base.squashfs" ] || { echo "base.squashfs missing — build base first"; exit 1; }
  [ -f "$ROOT/$manifest" ] || { echo "manifest $manifest missing"; exit 1; }
  local L="$WORK/$role-lower" U="$WORK/$role-up" WK="$WORK/$role-wk" MG="$WORK/$role-mg"
  # A killed prior build may leave bind mounts below MG. Unmount children first;
  # removing the tree while a mirror or /dev is still mounted risks deleting or
  # modifying the host-side source through that live mount.
  apt_unmount "$MG"; umount_chroot "$MG"
  sudo umount -lf "$MG" 2>/dev/null || true
  sudo rm -rf "$L" "$U" "$WK" "$MG"
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
  if ! sudo chroot "$MG" apt-get install -y --no-install-recommends $pkgs 2>&1 | tail -6; then
    log "ERROR: $role package installation failed; refusing to publish an incomplete layer"
    apt_unmount "$MG"; umount_chroot "$MG"; sudo umount -lf "$MG" 2>/dev/null || true
    return 1
  fi
  if [ "$role" = "desktop" ]; then
    log "desktop: SINGULARITY desktop delta (Wayland-only; XFCE/X11 removed) + brand"
    # 26.7 "Maximilian": Singularity Desktop (labwc/wlroots, GTK4) REPLACES XFCE.
    # No user-session=xfce, no x-session-manager -> xfce4, no 60-ncz-xfce.conf.
    # GREETER = greetd + NATIVE singularity-greeter (in the payload) — NOT
    # lightdm. 20-desktop.sh (run as a brand hook below) does the real work:
    # extract /opt/singularity, install ncz-gpu-env/ncz-singularity + the
    # ncz-singularity-greeter wrapper, singularity.desktop (the ONLY session),
    # make greetd the DM, curate sessions, purge XFCE/Xorg remnants. 55-greeter
    # writes the greetd config + branding. Remove stale lightdm/XFCE pins.
    sudo rm -f "$MG/etc/lightdm/lightdm.conf.d/60-ncz-xfce.conf" \
               "$MG/etc/lightdm/lightdm.conf.d/60-ncz-singularity.conf" \
               "$MG/etc/X11/default-display-manager" 2>/dev/null || true
    # r166: refresh the post-install hook tree in the overlay from the current
    # repo. The brand hooks below run from base's staged post-install (baked at
    # base-build time), so an edited hook (e.g. 60-boot-splash's plymouth purge)
    # would NOT take effect on a desktop-only rebuild without this.
    sudo cp -a "$ROOT/post-install/." "$MG/usr/local/lib/cix-installer/post-install/" 2>/dev/null || true
    [ -s "$ROOT/release.conf" ] && \
      sudo install -m 0644 "$ROOT/release.conf" "$MG/usr/local/lib/cix-installer/RELEASE"
    # r166: stage the NCZ branding assets the brand hooks read. The base build
    # only staged cix-debs/kernel/mesa/gpu/firmware/refind/rescue — NOT branding —
    # so 45-wallpaper (needs assets/branding/wallpaper), 56-icon-theme (needs
    # assets/branding/icon-theme/NCZ) and 55-greeter (needs assets/branding/logo/
    # ncz.png) all silently used stock defaults. Copy branding into
    # the overlay before the hooks run. (Base list also gains "branding" for the
    # next base rebuild; this desktop-layer copy makes it work without one.)
    if [ -d "$ROOT/assets/branding" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/branding"
      sudo cp -a "$ROOT/assets/branding/." "$MG/usr/local/lib/cix-installer/assets/branding/" 2>/dev/null || true
      log "  staged branding assets ($(find "$ROOT/assets/branding" -type f | wc -l | tr -d ' ') files)"
    fi
    # Vivaldi is NOT shipped (operator, 2026-08-10). Its staging block lived on
    # after post-install/52-vivaldi.sh had already been deleted, so the ISO
    # still carried 125 MB+ of browser .deb that nothing installed -- and on the
    # build host a superseded 8.0 copy sat beside the 8.1 one, doubling it.
    # The launchers do not need it: 30-agents.sh and the MNEMOS entries already
    # Exec /usr/bin/chromium-ncz-sky1, and 20-desktop.sh already registers that
    # as x-www-browser at priority 200, so chromium-ncz-sky1 is the default
    # browser in practice regardless of the older "Vivaldi is default" comments.
    # Google Chrome installs via the offline desktop-mirror pool (same as
    # dropped ungoogled-chromium/XtraDeb stop-gap) -- see build/build-desktop-mirror.sh and
    # post-install/53-chrome.sh. No separate asset staging needed here.
    # 26.7 (updated 2026-07-26): the Singularity Desktop payload is NO LONGER
    # staged as a tarball here. post-install/20-desktop.sh installs it as a real
    # apt package (`apt-get install ncz-singularity-desktop`) from the offline
    # desktop-mirror pool (build/build-desktop-mirror.sh ->
    # build/desktop-mirror/pool/main/n/ncz-singularity-desktop/*.deb), which
    # apt_offline() above already bind-mounts into this chroot as a `file://`
    # apt source (see the "server-mirror resolute-mirror desktop-mirror" loop).
    # So nothing needs to be copied into the overlay for it -- just verify the
    # .deb is actually present in the pool, so a missing payload fails loudly
    # HERE with a clear remediation instead of deep inside 20-desktop.sh's
    # apt-get install. (build/build-singularity.sh still produces the
    # underlying singularity-opt.tgz, but that is now only an INPUT to
    # build/build-singularity-deb.sh, not something staged into a squashfs
    # layer -- see assets/singularity/README.md.)
    SINGULARITY_DEB=$(find "$ROOT/build/desktop-mirror/pool" -type f \
      -name 'ncz-singularity-desktop_*_arm64.deb' -print -quit 2>/dev/null || true)
    if [ -n "$SINGULARITY_DEB" ]; then
      log "  desktop-mirror has ncz-singularity-desktop: $(basename "$SINGULARITY_DEB")"
    else
      log "  WARN: no ncz-singularity-desktop_*.deb in $ROOT/build/desktop-mirror/pool — 20-desktop's 'apt-get install ncz-singularity-desktop' will FAIL (run build/build-singularity.sh && build/build-singularity-deb.sh && build/build-desktop-mirror.sh)"
    fi
    # 26.7 NATIVE STACK: the greeter (singularity-greeter) ships INSIDE the
    # /opt/singularity payload — no separate greeter binary to stage (regreet is
    # gone). Stage the native singularity-boot-splash as a FALLBACK asset so
    # 60-boot-splash can install it even if the payload predates the boot-splash
    # build (build-singularity.sh also folds it into singularity-opt.tgz).
    if [ -f "$ROOT/assets/singularity-boot-splash/singularity-boot-splash" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/singularity-boot-splash"
      sudo cp -a "$ROOT/assets/singularity-boot-splash/singularity-boot-splash" "$MG/usr/local/lib/cix-installer/assets/singularity-boot-splash/" 2>/dev/null || true
      log "  staged singularity-boot-splash ($(du -h "$ROOT/assets/singularity-boot-splash/singularity-boot-splash" | cut -f1))"
    else
      log "  note: assets/singularity-boot-splash absent — relying on the /opt/singularity payload for it"
    fi
    # 26.7: stage the native sinty-nm daemon (+ unit + D-Bus policy) so
    # 20-desktop installs /usr/bin/sinty-nmd and swaps out NetworkManager.
    # sinty-nmd is a gitignored build blob (build via singularityos-lab/sinty-nm;
    # fetch from .66:/home/jasonperlow/sinty-build/nm-build/out/sinty-nmd).
    if [ -f "$ROOT/assets/sinty-nm/sinty-nmd" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/sinty-nm"
      sudo cp -a "$ROOT/assets/sinty-nm/sinty-nmd" \
                 "$ROOT/assets/sinty-nm/sinty-nm.service" \
                 "$ROOT/assets/sinty-nm/org.freedesktop.NetworkManager.conf" \
                 "$MG/usr/local/lib/cix-installer/assets/sinty-nm/" 2>/dev/null || true
      log "  staged sinty-nm daemon ($(du -h "$ROOT/assets/sinty-nm/sinty-nmd" | cut -f1))"
    else
      log "  WARN: assets/sinty-nm/sinty-nmd ABSENT — 20-desktop falls back to NetworkManager (build singularityos-lab/sinty-nm)"
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
    # this hook runs on ALL variants (not just Server) since the
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
    # 26.7 Singularity brand-hook order. 20-desktop = the Singularity installer
    # (extracts /opt/singularity, curates sessions, purges XFCE/Xorg) — runs
    # FIRST so the Wayland desktop exists before the cosmetic hooks. 84-vpu-mpv
    # writes /etc/mpv HW-decode. 57-screensaver = NATIVE Wayland idle-lock
    # (swayidle + Singularity lockscreen; the X11 xscreensaver is purged) — no
    # longer dropped. 30-agents before 46-ncz-cli (dep order). 59-desktop-curate
    # LAST of the app hooks (after 20/30-agents/46-ncz-cli) so it sees
    # every app-creating hook's output when it curates the launcher.
    for bh in 20-desktop 22-display-fix 23-locale-env 50-brand 53-chrome 56-icon-theme 45-wallpaper-rotator 55-greeter 84-vpu-mpv 84-vpu-vaapi 57-qotd 30-agents 46-ncz-cli 57-screensaver 59-desktop-curate 60-boot-splash; do
      [ -f "$MG/usr/local/lib/cix-installer/post-install/$bh.sh" ] || { log "  skip $bh (absent)"; continue; }
      log "  desktop brand hook -> $bh"
      set +e
      sudo chroot "$MG" bash -c "cd /usr/local/lib/cix-installer/post-install && bash ./$bh.sh" 2>&1 | tail -3
      hook_rc=${PIPESTATUS[0]}
      set -e
      if [ "$hook_rc" -ne 0 ]; then
        case "$bh" in
          20-desktop|55-greeter|60-boot-splash)
            log "ERROR: ship-critical desktop hook $bh failed rc=$hook_rc; refusing to publish the layer"
            apt_unmount "$MG"; umount_chroot "$MG"; sudo umount -lf "$MG" 2>/dev/null || true
            return 1
            ;;
          *) log "  WARN $bh rc=$hook_rc" ;;
        esac
      fi
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
  # Preserve the overlay semantics in a sidecar consumed by the installer.
  # A raw upperdir contains both char-device 0:0 whiteouts and opaque directory
  # xattrs; ordinary unsquashfs understands neither when merging into a base.
  # Strip overlay-internal xattrs from the payload after recording them so they
  # do not contaminate the installed filesystem.
  log "$role: generate overlay operation manifest"
  sudo python3 - "$U" "$OUT/$role.overlay-manifest" <<'PYOVERLAY'
import os
import stat
import sys

root, output = sys.argv[1:]
operations = []
for directory, names, files in os.walk(root):
    names.sort()
    files.sort()
    relative_directory = os.path.relpath(directory, root)
    try:
        if os.getxattr(directory, "trusted.overlay.opaque") in (b"y", b"x"):
            operations.append(("opaque", relative_directory))
    except OSError:
        pass
    for name in names + files:
        path = os.path.join(directory, name)
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            continue
        if stat.S_ISCHR(metadata.st_mode) and os.major(metadata.st_rdev) == 0 and os.minor(metadata.st_rdev) == 0:
            operations.append(("whiteout", os.path.relpath(path, root)))

for operation, path in operations:
    if path in ("", ".") or path.startswith("/") or "\t" in path or "\n" in path:
        raise SystemExit(f"unsafe overlay manifest path: {path!r}")

with open(output, "w", encoding="utf-8") as stream:
    stream.write("# NCZ overlay manifest v1\n")
    for operation, path in sorted(set(operations)):
        stream.write(f"{operation}\t{path}\n")
PYOVERLAY
  log "$role: mksquashfs upperdir delta -> $OUT/$role.squashfs"
  sudo mksquashfs "$U" "$OUT/$role.squashfs" -comp zstd -Xcompression-level 15 \
    -xattrs-exclude '^trusted\.overlay\.' -noappend -no-progress 2>&1 | tail -2
  log "$role DONE: delta $(du -h "$OUT/$role.squashfs"|cut -f1)"
  sudo rm -rf "$L" "$MG" "$WK"
}

build_base(){
  log "BASE: extract resolute base"
  sudo rm -rf "$WORK/base"; mkdir -p "$WORK/base"
  sudo tar -I 'zstd -d' -xf "$BASE_TARBALL" -C "$WORK/base"
  mount_chroot "$WORK/base"
  # r190.2: same needrestart-hang fix as build_layer() below -- base hooks
  # (10-our-kernel etc) also apt-install packages and can hit the same
  # interactive "Pending kernel upgrade" whiptail hang.
  sudo mkdir -p "$WORK/base/etc/needrestart/conf.d"
  printf '$nrconf{kernelhints} = 0;\n' | sudo tee "$WORK/base/etc/needrestart/conf.d/99-squashfs-layer.conf" >/dev/null
  # base hooks are local-asset (dpkg/copy) — the apt mirror is only needed for the
  # desktop/server layers, so skip apt_offline here if the mirror isn't present.
  if mirror_available; then apt_offline "$WORK/base"; else log "no mirror for $APT_SUITE -> using base sources"; fi
  # stage the installer hook tree + assets the base hooks read
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer"
  sudo cp -a "$ROOT/post-install" "$WORK/base/usr/local/lib/cix-installer/"
  sudo install -m 0644 "$ROOT/release.conf" "$WORK/base/usr/local/lib/cix-installer/RELEASE"
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
  # `|| true`: a bare `[ -f x ] && cp` AND-list returns 1 when the test fails,
  # and under `set -e` that aborts the whole base build. With the single-tree
  # rc7 release there IS no assets/kernel/edge/KVER, so the second line would
  # kill an hour-long build over a file that is deliberately absent.
  [ -f "$ROOT/assets/kernel/stable/KVER" ] && sudo cp "$ROOT/assets/kernel/stable/KVER" "$WORK/base/usr/local/lib/cix-installer/KVER_LTS" || true
  [ -f "$ROOT/assets/kernel/edge/KVER" ]   && sudo cp "$ROOT/assets/kernel/edge/KVER"   "$WORK/base/usr/local/lib/cix-installer/KVER_NEXT" || true
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
  # r164 (updated 26.7): the resolute base tarball is a FULL GNOME desktop image
  # (gnome-shell + gdm3 + ubuntu-session + ubuntu-desktop, ~1.5-2GB). GNOME is too
  # heavy AND it Wayland-black-screens on the Mali panthor GPU, so it is purged
  # from the BASE (not just whiteout in the desktop delta) so the ISO actually
  # shrinks. NOTHING replaces it in base — the desktop delta installs
  # Singularity Desktop (labwc/wlroots, GTK4, Wayland-only; see
  # post-install/20-desktop.sh), NOT XFCE/LightDM (dropped in 26.7; historical
  # comment corrected 2026-07-26).
  # PROTECT the sky1 mesa GL/GLES/Vulkan userland (pinned by 15/16-mesa hooks
  # above) from autoremove by marking it manual first, so removing gnome orphans
  # can't drag the GPU userland out with it -- Singularity's Wayland compositor
  # and the desktop layer's GLES/Vulkan diagnostic tools (mesa-utils,
  # vulkan-tools, glmark2-*) still need it. Do NOT protect xserver-xorg/xinit:
  # Singularity is Wayland-only and needs no X11 server (only Xwayland, pulled
  # in separately by the desktop layer's `xwayland` package for X-app compat),
  # so let a bare X11 server autoremove cleanly instead of shipping dead weight.
  sudo chroot "$WORK/base" sh -c 'apt-mark manual $(dpkg-query -W -f="\${Package}\n" 2>/dev/null | grep -E "^(mesa-|libgl1|libglx|libegl|libgbm1|libglapi)") 2>/dev/null' || true
  log "BASE: purge GNOME desktop stack (Singularity Desktop installs in the desktop delta, not base) — mesa protected, X11 server allowed to autoremove"
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
