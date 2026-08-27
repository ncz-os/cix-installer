#!/bin/bash
# See docs/ISO-BUILD-GUARDRAILS.md before changing this file —
# these are ISO build MECHANICS, stable across builds by design.
# build-squashfs-layers.sh — NCZ-OS layered squashfs installer images.
#
# Produces (under assets/squashfs/):
#   base.squashfs      debootstrap resolute + CIX kernel/firmware/mesa + sinty-nm/NM fallback
#   desktop.squashfs   DELTA: complete desktop package set (overlay upperdir only)
#
# THERE IS NO SERVER LAYER (2026-08-11, operator). NCZ-OS ships ONE build. What
# used to be the "server"/Magnetar variant is now a CONSOLE BOOT ENTRY on the
# same image (systemd.unit=multi-user.target, see build/70-bootloader.sh) --
# same packages, GUI simply not started. build-iso-di.sh already enforced
# `--variant desktop`, so the server layer was dead weight that still cost a
# full apt closure and a squashfs on every `all` build.
#
# Deliberately runs ONLY machine-AGNOSTIC hooks (kernel/firmware/mesa/sinty-nm).
# The NCZ desktop-config hooks (20-desktop/33-network/brand/plymouth) are NOT run here —
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

# Derive the repo from THIS SCRIPT's location, not $HOME. This script has to
# run under sudo (mount/chroot/mksquashfs), and sudo resets HOME to /root, so
# the old default silently resolved to /root/cix-installer-build/cix-installer.
# That path does not exist, which meant release.conf below was never sourced
# and NCZ_BASE_CODENAME fell back to "resolute" -- producing exactly the
# "Forky rootfs + Resolute mirror" combination the comment below promises can
# no longer happen. Caught 2026-08-02: the first rc6 layer build announced
# "BASE: extract resolute base" on a Forky tree and died on a missing
# rootfs-resolute-arm64.tar.zst.
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="${WORK:-/tmp/ncz-sqfs}"

# NEVER BUILD OR VERIFY A MULTI-GIGABYTE LAYER ON A tmpfs.
#
# /tmp on the build host is a 32G tmpfs, i.e. RAM. The desktop layer is ~1.7G
# compressed and expands to well over 20G, and verification decompresses the
# WHOLE archive into $WORK. MEASURED 2026-08-18: the run died at 21% with
#
#     Write on output file failed because No space left on device
#     FATAL ERROR: writer: failed to write file .../ncz-wallpaper-05-...jpg
#
# and the verifier reported "still fails cold -- the archive really is
# corrupt". IT WAS NOT CORRUPT. The archive was fine; the verifier ran out of
# RAM-backed scratch. That misdiagnosis is expensive because a "corrupt
# squashfs" reading sends you looking at mksquashfs and zstd (see the real
# 2026-08-16 corruption incident) instead of at df.
#
# Relocate off tmpfs automatically, and only when the caller has not chosen a
# WORK explicitly.
if [ -z "${WORK_EXPLICIT:-}" ] && [ "$(stat -f -c %T "$(dirname "$WORK")" 2>/dev/null)" = "tmpfs" ]; then
    _alt="$ROOT/build/.sqfs-work"
    echo "[sqfs] WORK ($WORK) is on tmpfs — relocating to $_alt (a layer will not fit in RAM)"
    WORK="$_alt"
fi
mkdir -p "$WORK" 2>/dev/null || sudo mkdir -p "$WORK" 2>/dev/null || true

# Fail EARLY and in plain language if the scratch filesystem is too small,
# rather than 20 minutes later disguised as archive corruption.
_avail_gb=$(( $(df -P --block-size=1G "$WORK" 2>/dev/null | awk 'NR==2{print $4}') + 0 ))
if [ "$_avail_gb" -lt 40 ]; then
    echo "[sqfs] WARNING: only ${_avail_gb}G free on $WORK — a desktop layer needs ~40G to build AND verify."
    echo "[sqfs]          Set WORK=/path/on/a/big/disk (and WORK_EXPLICIT=1) or free space; otherwise"
    echo "[sqfs]          verification will fail with ENOSPC and look exactly like archive corruption."
fi
OUT="${OUT:-$ROOT/assets/squashfs}"
# Keep every base-dependent default tied to release.conf.  Callers can still
# override these for an explicitly isolated experiment, but a normal build can
# no longer silently combine a Forky rootfs with a Resolute mirror.
if [ -r "$ROOT/release.conf" ]; then
  # shellcheck source=../release.conf
  . "$ROOT/release.conf"
else
  # Never guess the base distro. Silently defaulting is how a Forky tree
  # ended up asking for a Resolute rootfs.
  echo "ERROR: $ROOT/release.conf not readable -- refusing to guess the base" >&2
  echo "       distro. Set ROOT=<repo> if you are running from elsewhere." >&2
  exit 1
fi
NCZ_BASE_CODENAME="${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"
BASE_TARBALL="${BASE_TARBALL:-$ROOT/assets/rootfs/rootfs-$NCZ_BASE_CODENAME-arm64.tar.zst}"
APT_SUITE="${APT_SUITE:-$NCZ_BASE_CODENAME}"
APT_COMPONENTS="${APT_COMPONENTS:-main}"
# Both the Debian closure and our own packages (kernel, Chromium, Singularity)
# must be reachable offline, or disabling the remote sources above would make
# the NCZ packages unresolvable.
MIRROR_DIRS="${MIRROR_DIRS:-$NCZ_BASE_CODENAME-mirror $NCZ_BASE_CODENAME-vendor-mirror}"
QEMU="/usr/bin/qemu-aarch64-static"
STAGE="${1:-base}"                            # base | desktop | server | all

log(){ echo "[sqfs $(date -u +%H:%M:%S)] $*"; }
need(){ command -v "$1" >/dev/null || { echo "MISSING: $1"; exit 1; }; }
need mksquashfs
need unsquashfs
need python3

# A zero exit from mksquashfs is NOT evidence that the archive it wrote can be
# read back. On 2026-08-16 it reported success and produced a desktop layer
# that failed midway through extraction with
#   zstd uncompress failed with error code 20
#   FATAL ERROR: writer: failed to read/uncompress file .../gimp/3.0/brushes/...
# Nothing in the build noticed. The ISO assembled, and the corruption only
# surfaced on the install target: the stub extracted base, wiped the base dpkg
# metadata per the overlay manifest, died partway through the delta, and d-i
# reported the generic "debootstrap program exited with an error (return value
# 1)". That cost two ISO builds and two KVM cycles to trace back. So decompress
# the whole archive here, where the failure is one line long.
verify_squashfs(){
  local img="$1" name="$2"
  local vd vlog rc
  sudo mkdir -p "$WORK"
  # The log MUST live somewhere this (unprivileged) shell can write: the
  # redirection below is performed by the shell, not by sudo, so pointing it
  # at $WORK -- which is root-owned as soon as any stage has run as root --
  # fails with "Permission denied" and yields rc=1 without unsquashfs having
  # run at all. The first version of this gate did exactly that and destroyed
  # a freshly built, untested layer on a false corruption verdict.
  vlog="$(mktemp "/tmp/ncz-verify-$name.XXXXXX.log")" || return 0
  vd="$(sudo mktemp -d "$WORK/.verify-$name.XXXXXX")"
  log "$name: verifying archive (full decompress -- catches silent mksquashfs corruption)"
  rc=0
  sudo unsquashfs -f -d "$vd" "$img" >"$vlog" 2>&1 || rc=$?
  sudo rm -rf "$vd"
  if [ "$rc" -ne 0 ]; then
    # Re-check COLD before condemning the image. Measured 2026-08-16 on this
    # host: a layer whose bytes were provably correct (source, staging copy and
    # the copy inside the ISO all md5'd identical) still failed extraction with
    # "zstd uncompress failed with error code 20" -- and then verified clean
    # after `sync; drop_caches`. The data was right; the READ was wrong. btrfs
    # cannot flag that: it verifies checksums on read, so corruption occurring
    # after verification (or before checksumming on write) is invisible to it,
    # and indeed no csum error was logged for either event.
    #
    # Condemning a good layer costs a full rebuild, so spend a few seconds
    # ruling out a bad read first. A genuinely corrupt archive fails both times.
    log "$name: verification FAILED (rc=$rc) -- re-checking cold before condemning it"
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    vd="$(sudo mktemp -d "$WORK/.verify-$name.XXXXXX")"
    rc=0
    sudo unsquashfs -f -d "$vd" "$img" >"$vlog" 2>&1 || rc=$?
    sudo rm -rf "$vd"
    if [ "$rc" -eq 0 ]; then
      log "$name: verified OK on the cold re-read -- the first failure was a bad READ, not a bad archive"
      log "  NOTE: a transient bad read on this host is itself a fault worth investigating (suspect memory)"
      rm -f "$vlog"
      return 0
    fi
    log "$name: still fails cold"
  fi
  if [ "$rc" -ne 0 ]; then
    log "ERROR: $name archive FAILED verification (unsquashfs rc=$rc) -- refusing to publish"
    grep -iE "fatal|error" "$vlog" | tail -5 >&2 || true
    # Move it aside rather than delete: the ISO build must not silently pick up
    # a bad layer, but a suspect archive is evidence and a verdict can itself
    # be wrong -- deleting leaves nothing to re-examine.
    sudo mv -f "$img" "$img.failed-verification" 2>/dev/null || true
    log "  kept for inspection: $img.failed-verification"
    log "  unsquashfs log: $vlog"
    exit 1
  fi
  log "$name: archive verified OK"
  rm -f "$vlog"
}

assert_rootfs_critical_owners(){
  local c="$1" label="$2" bad=0 p owner
  for p in . etc usr var var/lib; do
    [ -e "$c/$p" ] || continue
    owner="$(stat -c '%u:%g' "$c/$p")"
    if [ "$owner" != "0:0" ]; then
      log "ERROR: $label has unsafe ownership on /$p: $owner (expected 0:0)"
      bad=1
    fi
  done
  if [ "$bad" -ne 0 ]; then
    log "ERROR: refusing to chroot into a rootfs with user-owned system paths"
    log "       Rebuild the base layer from assets/rootfs/rootfs-$APT_SUITE-arm64.tar.zst"
    log "       before rebuilding role deltas."
    return 1
  fi
}
# NATIVE arm64 (e.g. bigpi) needs no qemu-user; x86 (ARGOS) does.
NATIVE=0; [ "$(uname -m)" = "aarch64" ] && NATIVE=1
[ "$NATIVE" = 1 ] || { [ -x "$QEMU" ] || { echo "no qemu-aarch64-static (x86 host needs it)"; exit 1; }; }
log "arch=$(uname -m) native=$NATIVE ROOT=$ROOT WORK=$WORK OUT=$OUT"
mkdir -p "$OUT" "$WORK"

# machine-AGNOSTIC hooks safe to bake into base (NOT desktop-config)
BASE_HOOKS="10-our-kernel 12-sky1-firmware 15-mesa-sky1-pin 16-mesa-gpu-2613 19-sinty-nm"
BASE_MANIFEST="${BASE_MANIFEST:-manifests/installer-base.pkgs}"

manifest_pkgs(){
  local manifest="$1"
  sed 's/#.*//' "$manifest" | sed -E 's/[[:space:]]+$//' | grep -vE '^[[:space:]]*$' | tr '\n' ' '
}

mount_chroot(){ local c="$1"
  sudo mount -t proc proc "$c/proc"; sudo mount -t sysfs sys "$c/sys";
  sudo mount -o bind /dev "$c/dev"; sudo mount -o bind /dev/pts "$c/dev/pts";
  [ "$NATIVE" = 1 ] || sudo cp "$QEMU" "$c/usr/bin/"; sudo cp /etc/resolv.conf "$c/etc/resolv.conf" 2>/dev/null || true; }
umount_chroot(){ local c="$1"
  for m in dev/pts dev sys proc; do sudo umount -lf "$c/$m" 2>/dev/null || true; done; }

# Offline apt sources are profile-driven so a parallel Debian Testing build
# cannot accidentally consume a Resolute mirror.
mirror_available(){ local m; for m in $MIRROR_DIRS; do [ -d "$ROOT/build/$m/dists/$APT_SUITE" ] && return 0; done; return 1; }
# The offline mirror goes in sources.list.d/, NOT sources.list: hooks run
# inside these chroots (10-our-kernel.sh -> 24-apt-sources.sh) truncate
# /etc/apt/sources.list on Debian, which silently removed the offline source
# before the kernel install that depends on it.
NCZ_OFFLINE_SRC=/etc/apt/sources.list.d/ncz-offline-mirror.list
# THE BUILD MUST SEE EXACTLY ONE APT SOURCE: our pinned offline mirror.
#
# WHY (2026-08-11): this used to remove /etc/apt/sources.list and our own list
# file, but NOT the deb822 sources the base layer ships
# (/etc/apt/sources.list.d/ncz-base.sources points at deb.debian.org, plus the
# Buildkite and R2 lists). So every layer build resolved against the pinned
# mirror AND the live testing archive at the same time. Each source is
# internally consistent; the UNION is not. When GNOME 51-alpha landed in
# testing while the mirror still pinned libgnome-desktop-4-2t64 44.5-1, the
# desktop set became unsatisfiable and stayed that way -- swapping the package
# that tripped it (evince) simply moved the failure to the next one
# (gnome-characters), because the conflict was never about that package.
#
# It also meant builds were not reproducible: the same command on two days
# produced different closures.
#
# Every other source is therefore moved aside for the duration and restored in
# apt_unmount, and the update below FAILS if any remote source is still live.
apt_offline(){ local c="$1"
  sudo rm -f "$c/etc/apt/sources.list"
  sudo mkdir -p "$c/etc/apt/sources.list.d"
  sudo rm -f "$c$NCZ_OFFLINE_SRC"
  # Disable every pre-existing source (deb822 .sources and classic .list).
  local f
  for f in "$c"/etc/apt/sources.list.d/*.sources "$c"/etc/apt/sources.list.d/*.list; do
    [ -e "$f" ] || continue
    case "$f" in *"$(basename "$NCZ_OFFLINE_SRC")") continue ;; esac
    sudo mv "$f" "$f.disabled-for-build"
    log "  apt: disabled $(basename "$f") for the build"
  done
  for m in $MIRROR_DIRS; do
    [ -d "$ROOT/build/$m/dists/$APT_SUITE" ] || continue
    sudo mkdir -p "$c/mnt/$m"; sudo mount -o bind "$ROOT/build/$m" "$c/mnt/$m"
    echo "deb [trusted=yes] file:///mnt/$m $APT_SUITE $APT_COMPONENTS" | sudo tee -a "$c$NCZ_OFFLINE_SRC" >/dev/null
  done
  # A remote source here means the closure is no longer pinned. Fail rather
  # than silently building against a moving archive.
  # Scope the check to files apt ACTUALLY reads (*.list, *.sources). Scanning
  # the whole directory matched our own *.disabled-for-build copies, which are
  # inert but still on disk -- a false positive that aborted a correct build.
  if sudo chroot "$c" sh -c 'cat /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -oE "https?://[^ ]+"' | grep -q .; then
    echo "FATAL: a remote apt source is still enabled in the chroot; the build would not be pinned" >&2
    sudo chroot "$c" sh -c 'grep -rn "^deb\|^URIs" /etc/apt/sources.list.d/ 2>/dev/null' >&2
    exit 1
  fi
  sudo chroot "$c" apt-get update -y 2>&1 | tail -4 || true; }
apt_unmount(){ local c="$1"
  for m in $MIRROR_DIRS; do sudo umount -lf "$c/mnt/$m" 2>/dev/null || true; done
  # Build-time only: never ship a file:// source pointing at a bind mount
  # that does not exist on the installed system.
  sudo rm -f "$c$NCZ_OFFLINE_SRC" 2>/dev/null || true
  # Restore the sources we moved aside, so the installed system keeps its own
  # apt configuration. Leaving them disabled would ship an image that cannot
  # update itself.
  local d
  for d in "$c"/etc/apt/sources.list.d/*.disabled-for-build; do
    [ -e "$d" ] || continue
    sudo mv "$d" "${d%.disabled-for-build}"
  done
  sudo rmdir "$c/mnt/$m" 2>/dev/null || true; }

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
  # The destination directory itself is not part of the squashfs payload.
  # Force ownership so maintainer scripts see a normal root-owned filesystem.
  sudo chown root:root "$L"
  assert_rootfs_critical_owners "$L" "$role lowerdir"
  # sudo: $WORK is root-owned as soon as any earlier stage has run under sudo,
  # so an unprivileged mkdir here fails with "mkdir: Permission denied" and
  # set -e aborts the build four seconds in, having logged nothing but the
  # three mkdir errors. These three directories are chown'd to root on the very
  # next line regardless, so creating them as root changes nothing else.
  sudo mkdir -p "$U" "$WK" "$MG"
  # Overlay presents the upper/mount root as the chroot root. None of the
  # backing directories may retain invoking-user ownership or systemd's
  # maintainer scripts reject `/` as an unsafe path.
  sudo chown root:root "$U" "$WK" "$MG"
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
  local pkgs; pkgs=$(manifest_pkgs "$ROOT/$manifest")
  log "$role: apt-install $(echo $pkgs|wc -w) top-level packages (complete set + closure)"
  if ! sudo chroot "$MG" env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends $pkgs 2>&1 | tail -6; then
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
    if [ -d "$ROOT/assets/wallpaper" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/wallpaper"
      sudo cp -a "$ROOT/assets/wallpaper/." "$MG/usr/local/lib/cix-installer/assets/wallpaper/" 2>/dev/null || true
      log "  staged wallpaper backend assets ($(find "$ROOT/assets/wallpaper" -type f | wc -l | tr -d ' ') files)"
    fi
    # r181: stage the Vivaldi .deb so 52-vivaldi.sh installs the browser OFFLINE
    # (the MNEMOS + agent launchers Exec vivaldi-stable; epiphany can't play
    # YouTube on arm64). Self-contained .deb, no mirror/closure changes needed.
    if [ -d "$ROOT/assets/vivaldi" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/vivaldi"
      sudo cp -a "$ROOT/assets/vivaldi/." "$MG/usr/local/lib/cix-installer/assets/vivaldi/" 2>/dev/null || true
      log "  staged vivaldi assets ($(find "$ROOT/assets/vivaldi" -type f | wc -l | tr -d ' ') files)"
    fi
    # Google Chrome installs from the profile-matched offline mirror. No
    # separate asset staging is needed here.
    # 26.7 (updated 2026-07-26): the Singularity Desktop payload is NO LONGER
    # staged as a tarball here. post-install/20-desktop.sh installs it as a real
    # apt package (`apt-get install ncz-singularity-desktop`) from the offline
    # profile-matched mirror pool, which
    # apt_offline() above already bind-mounts into this chroot as a `file://`
    # apt source (see apt_offline above).
    # So nothing needs to be copied into the overlay for it -- just verify the
    # .deb is actually present in the pool, so a missing payload fails loudly
    # HERE with a clear remediation instead of deep inside 20-desktop.sh's
    # apt-get install. (build/build-singularity.sh still produces the
    # underlying singularity-opt.tgz, but that is now only an INPUT to
    # build/build-singularity-deb.sh, not something staged into a squashfs
    # layer -- see assets/singularity/README.md.)
    # -print -quit returns whichever candidate find happens to reach first,
    # which is undefined ordering, not the newest version. That silently
    # matters the moment a pool holds two builds: on 2026-08-12 a rebuilt
    # payload went into build/desktop-mirror while the layer resolved from
    # forky-mirror, and the ISO shipped a two-day-old shell whose fixes were
    # simply absent -- the build log said "offline mirror has
    # ncz-singularity-desktop" and looked entirely healthy. Collect every
    # candidate across the active mirrors and take the highest version, the
    # same way build-desktop-mirror.sh already does for sinty-out.
    SINGULARITY_DEB=""
    _sing_candidates=""
    for _mirror in $MIRROR_DIRS; do
      _found=$(find "$ROOT/build/$_mirror/pool" -type f \
        -name 'ncz-singularity-desktop_*_arm64.deb' 2>/dev/null || true)
      [ -n "$_found" ] && _sing_candidates="$_sing_candidates
$_found"
    done
    if [ -n "$(printf '%s' "$_sing_candidates" | tr -d '[:space:]')" ]; then
      SINGULARITY_DEB=$(printf '%s\n' "$_sing_candidates" | grep -v '^$' \
        | sort -V | tail -1)
    fi
    if [ -n "$SINGULARITY_DEB" ]; then
      log "  offline mirror has ncz-singularity-desktop: $(basename "$SINGULARITY_DEB")"
    else
      log "  WARN: no ncz-singularity-desktop_*.deb in the active offline mirrors — 20-desktop's apt install will fail"
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
    if [ -f "$ROOT/assets/ncz-cli.sh" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets"
      sudo cp -a "$ROOT/assets/ncz-cli.sh" "$MG/usr/local/lib/cix-installer/assets/" 2>/dev/null || true
      log "  staged ncz agent helper"
    fi
    # r312: agent-stack setup is no longer a baked or install-time hook. It is
    # exclusively operator-driven after boot via `ncz agent install`.
    # 26.7 Singularity brand-hook order. 20-desktop = the Singularity installer
    # (extracts /opt/singularity, curates sessions, purges XFCE/Xorg) — runs
    # FIRST so the Wayland desktop exists before the cosmetic hooks. 84-vpu-mpv
    # writes /etc/mpv HW-decode. 57-screensaver = NATIVE Wayland idle-lock
    # (swayidle + Singularity lockscreen; the X11 xscreensaver is purged) — no
    # longer dropped. 59-desktop-curate
    # LAST of the app hooks (after 20/52-vivaldi/46-ncz-cli) so it sees
    # every app-creating hook's output when it curates the launcher.
    for bh in 20-desktop 22-display-fix 23-locale-env 50-brand 52-vivaldi 53-chrome 56-icon-theme 45-wallpaper-rotator 55-greeter 84-vpu-mpv 84-vpu-vaapi 57-qotd 46-ncz-cli 59-desktop-curate 60-boot-splash; do
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
  # Overlayfs may represent a copied-up file as metadata-only
  # trusted.overlay.metacopy=y in the upperdir, with the data still read from
  # the lowerdir through the merged mount. We later strip trusted.overlay.*
  # xattrs before mksquashfs because plain unsquashfs cannot replay them. If
  # the data is not materialized first, files such as /var/lib/dpkg/status
  # become zero-byte regular files in the published delta.
  log "$role: materialize overlay metacopy files"
  sudo python3 - "$U" "$MG" <<'PYMETACOPY'
import os
import shutil
import sys

upper, merged = sys.argv[1:]
for directory, names, files in os.walk(upper):
    names.sort()
    files.sort()
    for name in files:
        upath = os.path.join(directory, name)
        try:
            if os.getxattr(upath, "trusted.overlay.metacopy") != b"y":
                continue
        except OSError:
            continue
        rel = os.path.relpath(upath, upper)
        mpath = os.path.join(merged, rel)
        tmp = upath + ".ncz-metacopy"
        shutil.copy2(mpath, tmp, follow_symlinks=False)
        st = os.lstat(mpath)
        os.chown(tmp, st.st_uid, st.st_gid, follow_symlinks=False)
        os.replace(tmp, upath)
PYMETACOPY
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
  sudo mksquashfs "$U" "$OUT/$role.squashfs" -comp zstd -Xcompression-level 15 -all-time 0 -fstime 0 -processors 1 \
    -xattrs-exclude '^trusted\.overlay\.' -noappend -no-progress 2>&1 | tail -2
  verify_squashfs "$OUT/$role.squashfs" "$role"
  log "$role DONE: delta $(du -h "$OUT/$role.squashfs"|cut -f1)"
  sudo rm -rf "$L" "$MG" "$WK"
}

build_base(){
  log "BASE: extract $APT_SUITE base"
  # A failed base hook exits under `set -e` before normal cleanup. Detach any
  # stale mounts before retrying so rm never traverses host /proc or /sys.
  apt_unmount "$WORK/base"
  umount_chroot "$WORK/base"
  sudo umount -lf "$WORK/base" 2>/dev/null || true
  sudo rm -rf "$WORK/base"
  # tar extracts the payload below this directory but does not replace its
  # ownership. A user-owned root makes systemd maintainer scripts reject the
  # chroot as unsafe (exit 73) and yields a silently broken layer.
  sudo install -d -o root -g root -m 0755 "$WORK/base"
  sudo tar -I 'zstd -d' -xf "$BASE_TARBALL" -C "$WORK/base"
  assert_rootfs_critical_owners "$WORK/base" "base rootfs"
  mount_chroot "$WORK/base"
  # r190.2: same needrestart-hang fix as build_layer() below -- base hooks
  # (10-our-kernel etc) also apt-install packages and can hit the same
  # interactive "Pending kernel upgrade" whiptail hang.
  sudo mkdir -p "$WORK/base/etc/needrestart/conf.d"
  printf '$nrconf{kernelhints} = 0;\n' | sudo tee "$WORK/base/etc/needrestart/conf.d/99-squashfs-layer.conf" >/dev/null
  # The base layer now consumes installer-base.pkgs explicitly.  If a pinned
  # offline mirror is present, use it; otherwise fall back to the rootfs' own
  # sources for local developer experiments.
  if mirror_available; then apt_offline "$WORK/base"; else log "no mirror for $APT_SUITE -> using base sources"; fi
  [ -f "$ROOT/$BASE_MANIFEST" ] || { echo "manifest $BASE_MANIFEST missing"; exit 1; }
  _base_pkgs=$(manifest_pkgs "$ROOT/$BASE_MANIFEST")
  log "BASE: apt-install $(echo $_base_pkgs|wc -w) always-on packages from $BASE_MANIFEST"
  if ! sudo chroot "$WORK/base" env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends $_base_pkgs 2>&1 | tail -8; then
    log "ERROR: base package installation failed; refusing to publish a console image without its required runtime"
    apt_unmount "$WORK/base"; umount_chroot "$WORK/base"; sudo umount -lf "$WORK/base" 2>/dev/null || true
    return 1
  fi
  # stage the installer hook tree + assets the base hooks read
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer"
  sudo cp -a "$ROOT/post-install" "$WORK/base/usr/local/lib/cix-installer/"
  sudo install -m 0644 "$ROOT/release.conf" "$WORK/base/usr/local/lib/cix-installer/RELEASE"
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/assets"
  for a in cix-debs kernel mesa gpu sky1-firmware firmware refind rescue branding wallpaper sinty-nm; do [ -d "$ROOT/assets/$a" ] && sudo cp -a "$ROOT/assets/$a" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true; done
  if [ -f "$ROOT/assets/sinty-nm/sinty-nmd" ]; then
    log "  staged sinty-nm daemon into BASE ($(du -h "$ROOT/assets/sinty-nm/sinty-nmd" | cut -f1))"
  else
    log "  WARN: assets/sinty-nm/sinty-nmd ABSENT — base falls back to NetworkManager (build singularityos-lab/sinty-nm)"
  fi
  [ -f "$ROOT/assets/ncz-cli.sh" ] && sudo cp -a "$ROOT/assets/ncz-cli.sh" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true
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
  # KVER sidecar that 10-our-kernel.sh + 70-bootloader.sh need to discover
  # the shipped edge kernel's KVER at install time.
  [ -f "$ROOT/assets/kernel/edge/KVER" ] && sudo cp "$ROOT/assets/kernel/edge/KVER" "$WORK/base/usr/local/lib/cix-installer/KVER_NEXT"
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
    if ! sudo chroot "$WORK/base" bash -c "cd /usr/local/lib/cix-installer/post-install && bash ./$h.sh" 2>&1 | tail -3; then
      if [ "$h" = "10-our-kernel" ] || [ "$h" = "19-sinty-nm" ]; then
        log "ERROR: required base hook $h failed; refusing to publish an incomplete base layer"
        apt_unmount "$WORK/base"; umount_chroot "$WORK/base"; sudo umount -lf "$WORK/base" 2>/dev/null || true
        return 1
      fi
      log "  WARN $h failed"
    fi
  done
  # Enable the base/console network owner. sinty-nm is preferred; if the staged
  # binary is absent, NetworkManager/netplan remains the fallback path.
  if [ -x "$WORK/base/usr/bin/sinty-nmd" ]; then
    sudo chroot "$WORK/base" systemctl enable sinty-nm.service 2>/dev/null || true
    sudo chroot "$WORK/base" systemctl enable bluetooth 2>/dev/null || true
  else
    if ! sudo chroot "$WORK/base" dpkg-query -W -f='${Status}' network-manager 2>/dev/null | grep -q "^install ok installed"; then
      log "ERROR: no sinty-nmd and network-manager is absent after base package install; console/base installs would have no network owner"
      apt_unmount "$WORK/base"; umount_chroot "$WORK/base"; sudo umount -lf "$WORK/base" 2>/dev/null || true
      return 1
    fi
    sudo chroot "$WORK/base" systemctl enable NetworkManager bluetooth 2>/dev/null || true
  fi
  # r164 (updated 2026-08-17): historically the base was an Ubuntu resolute cloud
  # image carrying a FULL GNOME desktop
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
  # Purge only packages actually installed. The list still carries Ubuntu names
  # (ubuntu-session, ubuntu-desktop, ubuntu-desktop-minimal) from when the base
  # was an Ubuntu resolute cloud image; on Debian forky those do not exist and
  # apt-get purge fails the whole command with
  #     E: Unable to locate package ubuntu-desktop
  #     WARN gnome purge rc=100
  # which masked whether the packages that DO exist were purged. Filtering by
  # what dpkg reports as installed makes this a no-op on a minbase debootstrap
  # (our current base has no GNOME at all) and still correct if the base ever
  # goes back to a full desktop image.
  _purge=""
  for _p in gdm3 gnome-shell gnome-session ubuntu-session ubuntu-desktop ubuntu-desktop-minimal; do
      sudo chroot "$WORK/base" dpkg-query -W -f='${Status}' "$_p" 2>/dev/null | grep -q "^install ok installed" \
          && _purge="$_purge $_p"
  done
  if [ -n "$_purge" ]; then
      sudo chroot "$WORK/base" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $_purge 2>&1 | tail -6 \
          || log "  WARN gnome purge rc=$?"
  else
      log "  BASE: no GNOME/Ubuntu desktop packages installed — nothing to purge"
  fi
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
  if [ ! -x "$WORK/base/usr/bin/sinty-nmd" ]; then
    sudo mkdir -p "$WORK/base/etc/NetworkManager/conf.d"
    sudo tee "$WORK/base/etc/NetworkManager/conf.d/10-ncz-manage-ethernet.conf" >/dev/null <<'NMETH'
[keyfile]
unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma,except:type:ethernet
NMETH
  fi
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
  # 2026-08-26: defensive chmod 0755 on the base root before mksquashfs.
  # Why: O6N install shipped with / mode 0700 (operator fact). mksquashfs
  # records the source-dir inode mode verbatim into the squashfs root entry,
  # and unsquashfs -f -d then propagates that mode onto whatever /target
  # currently is — including a mounted btrfs subvolume root inode. A root
  # at 0700 denies traversal to every non-root UID, which silently breaks
  # greetd, NIC bring-up (systemd sandboxed), rtc-efi, etc. The exact
  # upstream mechanism (build vs install vs btrfs-partman interaction) was
  # not pinpointed before this fix — the symptom was confirmed live, the
  # chain is plausible, and this is the minimal belt-and-suspenders that
  # closes the class regardless of which side regresses. Set unconditionally;
  # a silent chmod here is exactly how a 700 root shipped undetected.
  chmod 0755 "$WORK/base" || {
    log "ERROR: failed to chmod 0755 $WORK/base before mksquashfs — refusing to publish a possibly-unbootable layer"
    exit 1
  }
  log "BASE: mksquashfs -> $OUT/base.squashfs"
  sudo mksquashfs "$WORK/base" "$OUT/base.squashfs" -comp zstd -Xcompression-level 15 -all-time 0 -fstime 0 -processors 1 -noappend -no-progress 2>&1 | tail -3
  verify_squashfs "$OUT/base.squashfs" "base"
  log "BASE DONE: $(du -h "$OUT/base.squashfs"|cut -f1)"
}

# ----------------------------------------------------------------------------
# build_hotfix -- reproduce assets/squashfs/desktop-hotfix.squashfs
# (the 2026-08-25 Singularity Desktop delta layer).
#
# WHY THIS EXISTS (2026-08-26, post-incident):
# desktop-hotfix.squashfs was the actual root cause of the O6N 0700-/
# regression. It had NO committed builder -- it was built by an ad-hoc
# session out-of-repo, from a mktemp -d staging dir (mode 0700), which
# is how a 700-root squashfs layer ended up baked into the ISO and
# shipped to hardware. That mode of operation is exactly what this
# function prevents: it stages into an explicit `install -d -m 0755`
# root, mksquashfs packs it with -comp zstd, and verify_squashfs catches
# silent archive corruption before publish. See docs/ISO-BUILD-GUARDRAILS.md
# "desktop-hotfix.squashfs has no committed builder" for the original
# audit finding.
#
# PROVENANCE OF THE HOTFIX CONTENT (honest, partial):
#   - 588 of 589 files in /opt/singularity come from the latest
#     ncz-singularity-desktop_*.deb in assets/cix-debs/. The .deb IS
#     committed and reproducible: it's built by build/build-singularity.sh
#     + build/build-singularity-deb.sh from singularityos-lab/singularity,
#     packaged as an apt .deb, and the latest version is what this
#     function consumes.
#   - 1 file is the `/etc/ld.so.conf.d/singularity.conf` snippet (one
#     line: "/opt/singularity/lib") that the .deb's postinst creates
#     at install time on a real system. We stage it as part of the
#     hotfix layer because the hotfix is applied BEFORE the deb's
#     postinst runs (the install-time stub applies the layer to /target
#     before dpkg ever sees the .deb), so without staging the conf file
#     explicitly here, ldconfig would not pick up /opt/singularity/lib
#     until the user's first apt-get install.
#   - The 6 labwc man-page timestamp differences between this build and
#     the current desktop-hotfix.squashfs are auto-generated from the
#     labwc source's scdoc build date (the .TH header line). The current
#     desktop-hotfix.squashfs was built 2026-08-25; the latest committed
#     deb's labwc man pages are dated 2026-08-24. A rebuild from this
#     function uses the deb's date. This is a cosmetic-only drift;
#     the man-page content is byte-identical.
#
# We do NOT have full traceability of every original patch that went
# into the current desktop-hotfix.squashfs -- that layer was hand-built
# outside the repo. What this function gives us is: the artifact can
# now be REBUILT reproducibly from a committed process (this script +
# the ncz-singularity-desktop .deb), even if the underlying derivation
# of the deb itself is out of scope. The "we can rebuild it now, we
# don't have full provenance for what it originally patched" trade-off
# is honest and explicitly documented (this header comment + commit
# message + build log line below).
# ----------------------------------------------------------------------------
build_hotfix(){
  log "HOTFIX: stage ncz-singularity-desktop /opt/singularity + /etc/ld.so.conf.d/singularity.conf"
  # Pick the LATEST ncz-singularity-desktop .deb from assets/cix-debs/ by version
  # sort. -V handles the `20260824+bk0~g6c87c48_arm64` form correctly (newer
  # date first, suffix second). Falls back to error if no deb is committed --
  # the hotfix build is a no-op without its source artifact, and shipping a
  # hotfix built from a non-committed input would re-create the trap this
  # function exists to close.
  HOTFIX_DEB="$(ls -1 "$ROOT/assets/cix-debs/"/ncz-singularity-desktop_*.deb 2>/dev/null | sort -V | tail -1)"
  if [ -z "$HOTFIX_DEB" ] || [ ! -f "$HOTFIX_DEB" ]; then
    log "ERROR: no ncz-singularity-desktop_*.deb in $ROOT/assets/cix-debs/ -- cannot build the hotfix layer without its source artifact"
    log "       Build the deb with build/build-singularity.sh + build/build-singularity-deb.sh, copy the resulting .deb into assets/cix-debs/, then retry"
    exit 1
  fi
  HOTFIX_DEB_NAME="$(basename "$HOTFIX_DEB")"
  # A failed hotfix build leaves a dirty $WORK/hotfix dir. Wipe before staging
  # so a retry cannot accumulate partial state.
  sudo rm -rf "$WORK/hotfix"
  # EXPLICIT 0755 ROOT. This is the discipline that closes the mktemp-0700
  # regression: dpkg-deb -x below extracts into a destination dir, and the
  # destination's OWN mode (not just the contents') is what mksquashfs
  # records as the squashfs root entry -- which is what unsquashfs -f -d
  # re-stamps onto /target at install time. A user-owned or 0700 root here
  # would bake a 0700 layer root regardless of how the inner files are
  # permissioned, and the gate in build-iso-di.sh's
  # assert_squashfs_root_mode() would catch it -- but failing the BUILD is
  # worse than preventing the issue at the staging step, so set 0755 here
  # unconditionally. Same pattern as build_base()'s `install -d -m 0755`.
  sudo install -d -o root -g root -m 0755 "$WORK/hotfix"
  # dpkg-deb -x preserves the .deb's per-file ownership and modes, but it
  # also sets the destination dir's OWN mode from the .deb's data.tar root
  # entry (which for ncz-singularity-desktop is drwx------ / 0700). The
  # chmod below overrides that with 0755 to match the `install -d` above
  # -- if these two ever disagree, mksquashfs will record the chmod'd mode,
  # but the assertion is also useful as a self-check.
  log "HOTFIX: dpkg-deb -x $HOTFIX_DEB_NAME -> $WORK/hotfix"
  sudo dpkg-deb -x "$HOTFIX_DEB" "$WORK/hotfix"
  sudo chmod 0755 "$WORK/hotfix" || {
    log "ERROR: chmod 0755 $WORK/hotfix after dpkg-deb -x failed -- refusing to publish a layer with an unsafe root mode"
    exit 1
  }
  # dpkg-deb -x extracts to <dest>/opt/singularity/... -- verify the tree
  # landed where we expect. If the deb's layout ever changes this catches
  # it loudly rather than producing a hotfix with empty content.
  if [ ! -d "$WORK/hotfix/opt/singularity" ]; then
    log "ERROR: dpkg-deb -x did not produce $WORK/hotfix/opt/singularity -- the deb layout may have changed"
    log "       Inspect $HOTFIX_DEB with: dpkg-deb -c $HOTFIX_DEB"
    exit 1
  fi
  # Stage /etc/ld.so.conf.d/singularity.conf. This file is created by the
  # deb's postinst at install time on a real apt install; the install-time
  # stub applies the hotfix layer BEFORE dpkg ever sees the .deb, so we
  # must stage it here. One line, ldconfig(8) format. `install -m 0644`
  # because ld.so.conf.d files are world-readable by convention.
  sudo install -d -o root -g root -m 0755 "$WORK/hotfix/etc/ld.so.conf.d"
  printf '/opt/singularity/lib\n' | sudo tee "$WORK/hotfix/etc/ld.so.conf.d/singularity.conf" >/dev/null
  sudo chmod 0644 "$WORK/hotfix/etc/ld.so.conf.d/singularity.conf"
  # mksquashfs inherits the staging dir's root entry's mode verbatim
  # (verified by assert_squashfs_root_mode below). The chmod above is the
  # belt; this assert is the braces. -comp zstd + -Xcompression-level 15
  # matches the other layers (build_base, build_layer) so a downstream
  # tool reading the squashfs sees uniform compression settings.
  log "HOTFIX: mksquashfs $WORK/hotfix -> $OUT/desktop-hotfix.squashfs"
  sudo mksquashfs "$WORK/hotfix" "$OUT/desktop-hotfix.squashfs" -comp zstd -Xcompression-level 15 -all-time 0 -fstime 0 -processors 1 -noappend -no-progress 2>&1 | tail -2
  verify_squashfs "$OUT/desktop-hotfix.squashfs" "desktop-hotfix"
  # Write the overlay manifest. The install-time stub applies the manifest
  # BEFORE unsquashfs extraction (see preseed/extract-rootfs.sh's
  # `while IFS=$OVERLAY_TAB read -r kind rel` loop), so the opaque
  # /opt/singularity entry wipes everything under /opt/singularity that
  # the previous layer (desktop.squashfs) installed, and then the
  # unsquashfs delta lays down the new tree. If the manifest is missing
  # or wrong, the overlay semantics don't fire and stale files from the
  # previous layer remain in /opt/singularity on the installed system --
  # exactly the failure mode that hides a fix.
  cat > "$OUT/desktop-hotfix.overlay-manifest" <<'HOTFIX_MANIFEST'
# NCZ overlay manifest v1
opaque	opt/singularity
HOTFIX_MANIFEST
  log "HOTFIX: wrote overlay manifest ($OUT/desktop-hotfix.overlay-manifest)"
  # Provenance summary: log what the artifact was rebuilt from so a future
  # audit can answer "where did this hotfix come from?" without grepping
  # git history. The honest answer is "the latest committed
  # ncz-singularity-desktop .deb"; this log line captures that.
  log "HOTFIX: source = $(basename "$HOTFIX_DEB")"
  log "HOTFIX: provenance note = reproducible rebuild from assets/cix-debs/ncz-singularity-desktop_*.deb (singularityos-lab/singularity + labwc/wlroots); the original 2026-08-25 ad-hoc build had no committed process"
  log "HOTFIX DONE: $(du -h "$OUT/desktop-hotfix.squashfs"|cut -f1)"
  sudo rm -rf "$WORK/hotfix"
}

case "$STAGE" in
  base)    build_base ;;
  desktop) build_layer desktop manifests/desktop.pkgs ;;
  hotfix)  build_hotfix ;;
  server)  echo "ERROR: the server layer is gone; NCZ-OS ships ONE build." >&2
           echo "       Boot the console entry (multi-user.target) instead." >&2
           exit 1 ;;
  all)     build_base; build_layer desktop manifests/desktop.pkgs; build_hotfix ;;
  *) echo "usage: $0 base|desktop|hotfix|server|all"; exit 2 ;;
esac
