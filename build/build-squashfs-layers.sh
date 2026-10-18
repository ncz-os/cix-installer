#!/bin/bash
# Read the image build guardrails before changing this file —
# these are image build MECHANICS, stable across builds by design.
# build-squashfs-layers.sh — NCZ-OS layered squashfs install-image layers.
#
# Produces (under assets/squashfs/), for NCZ_TARGET_ARCH (arm64 or amd64):
#   base.squashfs            the Debian forky base rootfs tarball
#                            (assets/rootfs/rootfs-forky-<arch>.tar.zst, produced by
#                            build/build-base-rootfs.sh with mmdebstrap) extracted,
#                            plus the machine-agnostic hooks (NCZ kernel, firmware,
#                            mesa, sinty-nm/NetworkManager) and installer-base*.pkgs
#   desktop.squashfs         DELTA: complete desktop package set (overlay upperdir only)
#   desktop-hotfix.squashfs  DELTA: the Singularity payload on top of desktop
#
# THERE IS NO SERVER LAYER (2026-08-11). NCZ-OS ships ONE build. What
# used to be the "server"/Magnetar variant is now a CONSOLE BOOT ENTRY on the
# same image (systemd.unit=multi-user.target, see build/70-bootloader.sh) --
# same packages, GUI simply not started. The server layer was dead weight
# that still cost a full apt closure and a squashfs on every `all` build.
#
# Deliberately runs ONLY machine-AGNOSTIC hooks (kernel/firmware/mesa/sinty-nm).
# The NCZ desktop-config hooks (20-desktop/33-network/brand/plymouth) are NOT run here —
# they corrupted net/BT/desktop in the chroot bake. Desktop content comes
# from a CLEAN apt-install. Machine-specific + branding run at
# install / first-boot, not baked.
#
# Runs natively on a build host of the target arch (aarch64 for arm64,
# x86_64 for amd64); a cross-arch host needs qemu-user-static + binfmt.
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

# --- Preflight freshness gate (2026-09-21, design rule) -------------
# Refuse to start a build against a stale checkout, a stale kernel-staging
# pool, or a downstream Singularity patch that no longer applies. See
# preflight-freshness-gate.sh's own header for the three real incidents
# (silent stale-commit build, silently-shipped-old-kernel, wasted parallel
# rebuild) this exists to catch mechanically instead of by memory.
# NCZ_SKIP_FRESHNESS_GATE=1 is the explicit, acknowledged escape hatch --
# not a default, and never silent (it prints why it's skipping).
if [ "${NCZ_SKIP_FRESHNESS_GATE:-0}" != "1" ]; then
    if ! "$ROOT/build/preflight-freshness-gate.sh"; then
        echo "[sqfs] ABORT: preflight-freshness-gate.sh failed -- see above." >&2
        echo "[sqfs]        Set NCZ_SKIP_FRESHNESS_GATE=1 to build anyway (not recommended)." >&2
        exit 1
    fi
else
    echo "[sqfs] WARNING: NCZ_SKIP_FRESHNESS_GATE=1 -- skipping freshness gate, building against whatever is on disk"
fi

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
# amd64 support added 2026-09-15 for the AMD64 pipeline (amd64 build hosts) --
# mirrors the NCZ_TARGET_ARCH pattern already used by
# build-baked-rootfs.sh. Defaults to the host's own arch, so a native build
# host builds its own arch with no extra setting.
NCZ_TARGET_ARCH="${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}"
case "$NCZ_TARGET_ARCH" in
  arm64) HOST_NATIVE_ARCH=aarch64; QEMU_BIN=qemu-aarch64-static ;;
  amd64) HOST_NATIVE_ARCH=x86_64;  QEMU_BIN=qemu-x86-64-static ;;
  *) echo "ERROR: unsupported NCZ_TARGET_ARCH=$NCZ_TARGET_ARCH (expected arm64 or amd64)" >&2; exit 1 ;;
esac

# --- Layer plan (build/build-image.sh) -------------------------------------
# build/lib/layerplan.py is the single implementation of a layer's input
# FINGERPRINT (every pin, package list, hook, asset tree and kernel/payload sha
# that feeds the layer, plus the layers below it).  build-image.sh passes
# NCZ_LAYER_PLAN="base=rebuild,desktop=reuse,..." so a quick respin rebuilds
# only what changed.  Absent (standalone invocation) behaviour is unchanged:
# base reuses on a matching in-layer stamp, desktop/hotfix always rebuild.
NCZ_LAYERPLAN_PY="$ROOT/build/lib/layerplan.py"
ncz_layer_fingerprint() {
  python3 -I "$NCZ_LAYERPLAN_PY" fingerprint --layer "$1" --arch "$NCZ_TARGET_ARCH" \
    --root "$ROOT" --pin "${NCZ_PIN_FILE:-$ROOT/manifests/base.pin}" 2>/dev/null
}
ncz_layer_decision() {   # layer -> rebuild|reuse|"" (default)
  [ -n "${NCZ_LAYER_PLAN:-}" ] || return 0
  printf '%s' "$NCZ_LAYER_PLAN" | tr ',' '\n' \
    | awk -F= -v L="$1" '$1==L{print $2; found=1} END{if(!found) print ""}'
}
ncz_layer_artifact() {   # layer -> squashfs path
  case "$1" in
    base)    printf '%s\n' "$OUT/base.squashfs" ;;
    desktop) printf '%s\n' "$OUT/desktop.squashfs" ;;
    hotfix)  printf '%s\n' "$OUT/desktop-hotfix.squashfs" ;;
    *)       printf '\n' ;;
  esac
}
ncz_layer_reuse_ok() {   # layer -> 0 when the artifact + matching stamp exist
  local l="$1" art stamp
  art="$(ncz_layer_artifact "$l")"; stamp="$OUT/$l.build-fingerprint"
  [ -n "$art" ] && [ -s "$art" ] || return 1
  [ -s "$stamp" ] || return 1
  [ "$(cat "$stamp")" = "$(ncz_layer_fingerprint "$l")" ]
}
ncz_layer_stamp_write() { ncz_layer_fingerprint "$1" > "$OUT/$1.build-fingerprint"; }

# Pinned, gitignored inputs (recovery rootfs, rescue rootfs, python311, wallpaper debs): staged from
# the build-inputs store and checksum-verified before anything is built (r201: a missing
# ncz-mgmt-rootfs.tar.zst made post-install/38-recovery-container.sh fail on every image).
bash "$ROOT/build/stage-build-inputs.sh" --arch "$NCZ_TARGET_ARCH" || exit 1
BASE_TARBALL="${BASE_TARBALL:-$ROOT/assets/rootfs/rootfs-$NCZ_BASE_CODENAME-$NCZ_TARGET_ARCH.tar.zst}"
APT_SUITE="${APT_SUITE:-$NCZ_BASE_CODENAME}"
APT_COMPONENTS="${APT_COMPONENTS:-main}"
# Both the Debian closure and our own packages (kernel, Chromium, Singularity)
# must be reachable offline, or disabling the remote sources above would make
# the NCZ packages unresolvable.
if [ -n "${MIRROR_DIRS+x}" ]; then
  MIRROR_DIRS_EXPLICIT=1
else
  MIRROR_DIRS_EXPLICIT=0
  MIRROR_DIRS="$NCZ_BASE_CODENAME-mirror $NCZ_BASE_CODENAME-vendor-mirror"
fi
STAGE="${1:-base}"                            # base | desktop | server | all | hotfix

# Pre-flight (2026-10-05 mandatory-install item): the mirror the
# desktop role delta actually installs from must carry ncz-screensavers at the
# version floor in build/screensavers-version.env. Run this BEFORE we touch the
# chroot, so a stale or misconfigured mirror produces a one-line "missing
# package" failure instead of a 20-minute run that dies partway through
# 59-ncz-screensavers-pkg.sh.
#
# Only the desktop and `all` stages build a desktop layer; base, server and
# hotfix do not install the screensaver package set, so they skip this. The
# mirror list must match build_layer() below: when the operator did not
# override MIRROR_DIRS, the desktop layer selects desktop-mirror -- NOT the
# default suite/vendor mirrors, which feed the base role and do not carry
# ncz-screensavers. Checking the default list here would abort a healthy
# desktop build and, worse, never check the mirror that actually ships the
# package. A missing mirror directory means this host builds live (non-
# reproducible); the install hook still enforces the package, so it is a note,
# not an abort.
case "$STAGE" in
  desktop|all)
    _ss_effective="$MIRROR_DIRS"
    if [ "$MIRROR_DIRS_EXPLICIT" -eq 0 ]; then
      _ss_effective="desktop-mirror"
    fi
    _ss_mirrors=""
    for m in $_ss_effective; do
      [ -d "$ROOT/build/$m" ] || continue
      _ss_mirrors="$_ss_mirrors --mirror $ROOT/build/$m --label $m"
    done
    if [ -n "$_ss_mirrors" ]; then
      # Phase 2: required-ness and the version floor come from the registry.
      # The assert script still reads screensavers-version.env; refuse here
      # if the registry disagrees, before the chroot is touched.
      _ss_reg_req="$(python3 "$ROOT/build/components.py" --root "$ROOT" query --name ncz-screensavers --kind staged-deb --field required 2>/dev/null || true)"
      _ss_reg_floor="$(python3 "$ROOT/build/components.py" --root "$ROOT" query --name ncz-screensavers --kind staged-deb --field version_floor 2>/dev/null || true)"
      # shellcheck disable=SC1090
      . "$ROOT/build/screensavers-version.env"
      if [ "$_ss_reg_req" != yes ] || [ "$_ss_reg_floor" != "${NCZ_SCREENSAVERS_MIN_VERSION:-}" ]; then
        echo "[sqfs] ABORT: registry ncz-screensavers staged-deb required='${_ss_reg_req}' floor='${_ss_reg_floor}' disagrees with screensavers-version.env (${NCZ_SCREENSAVERS_MIN_VERSION:-empty})." >&2
        exit 1
      fi
      # shellcheck disable=SC2086
      if ! "$ROOT/build/assert-mirror-has-screensavers.sh" $_ss_mirrors --arch "$NCZ_TARGET_ARCH"; then
        echo "[sqfs] ABORT: offline mirror does not carry ncz-screensavers at the required version floor." >&2
        echo "[sqfs]        (policy 2026-10-05: 'If we are distributing screensavers as Deb they need to be apt installed during installation.')" >&2
        echo "[sqfs]        Rebuild the mirror with build/build-desktop-mirror.sh (now mandatory there too)." >&2
        exit 1
      fi
    else
      echo "[sqfs] NOTE: no populated offline mirror under build/ ($_ss_effective); this host builds live, and 59-ncz-screensavers-pkg still enforces the package at install time." >&2
    fi
    ;;
  *) : ;;
esac
QEMU="/usr/bin/$QEMU_BIN"

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
  vlog="$(mktemp "${TMPDIR:-/tmp}/ncz-verify-$name.XXXXXX.log")" || return 0
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
    log "       Rebuild the base layer from assets/rootfs/rootfs-$APT_SUITE-$NCZ_TARGET_ARCH.tar.zst"
    log "       before rebuilding role deltas."
    return 1
  fi
}
# NATIVE: host arch matches the TARGET arch (e.g. arm64-target on an arm64 host,
# or amd64-target on an amd64 host) needs no qemu-user; a genuine
# cross-arch host does.
NATIVE=0; [ "$(uname -m)" = "$HOST_NATIVE_ARCH" ] && NATIVE=1
[ "$NATIVE" = 1 ] || { [ -x "$QEMU" ] || { echo "no $QEMU_BIN (cross-arch host needs it)"; exit 1; }; }
log "arch=$(uname -m) native=$NATIVE ROOT=$ROOT WORK=$WORK OUT=$OUT"
mkdir -p "$OUT" "$WORK"

# machine-AGNOSTIC hooks safe to bake into base (NOT desktop-config)
# Fingerprint of the small, hand-edited asset dirs and manifests that build_base copies into base.squashfs. The
# `all` mode reuses an existing base.squashfs; that reuse used to ask only "does the file exist" (then, in a later
# fix, "does it still carry the staged amd64 kernel"), so a change to assets/gpu, assets/audio, assets/refind ...
# never reached the image: on 2026-09-29 an image shipped an audio daemon without the HDA analog fallback and no
# ncz-gpu-hw-present because base.squashfs pre-dated both. The stamp is written into the layer and compared on reuse.
BASE_STAMP_REL=usr/local/lib/cix-installer/BASE-ASSETS.sha256
base_assets_stamp() {
  # Fingerprint of EVERY input of the base layer, computed by the one shared
  # implementation (build/lib/layerplan.py).  This is a strict SUPERSET of the
  # old hand-rolled find-over-asset-dirs: the r202 report found the old stamp
  # missed assets/wallpaper/ and post-install/ (two fixes lived exactly there
  # and never reached a reused base.squashfs).  The registry now covers the
  # asset dirs, the wallpaper packs, the installer hooks, the base package
  # lists, the kernel channel LAYOUT + KVER, the pinned kernel-deb manifest and
  # the upstream/substrate pins -- and, through its `mirror` dependency, the
  # pinned apt closure.  A missing python3 fails loud (never silently reuses).
  ncz_layer_fingerprint base || { echo "ERROR: base_assets_stamp: layerplan fingerprint failed" >&2; exit 1; }
}
base_stamp_in_layer() {   # layer -> stamp or empty
  { unsquashfs -cat "$1" "$BASE_STAMP_REL" 2>/dev/null || true; } | tr -d '[:space:]'   # absent stamp (old layer) => empty => rebuild; must not trip set -e/pipefail
}

case "$NCZ_TARGET_ARCH" in
  amd64) BASE_HOOKS="10-amd64-kernel 19-sinty-nm" ;;
  *)     BASE_HOOKS="10-our-kernel 12-sky1-firmware 15-mesa-sky1-pin 16-mesa-gpu-2613 19-sinty-nm" ;;
esac
case "$NCZ_TARGET_ARCH" in
  amd64) BASE_MANIFEST="${BASE_MANIFEST:-manifests/installer-base-amd64.pkgs}"
         DESKTOP_MANIFEST="${DESKTOP_MANIFEST:-manifests/desktop-amd64.pkgs}" ;;
  *)     BASE_MANIFEST="${BASE_MANIFEST:-manifests/installer-base.pkgs}"
         DESKTOP_MANIFEST="${DESKTOP_MANIFEST:-manifests/desktop.pkgs}" ;;
esac

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
  local _mirror_found=0
  for m in $MIRROR_DIRS; do
    [ -d "$ROOT/build/$m/dists/$APT_SUITE" ] || continue
    _mirror_found=1
    sudo mkdir -p "$c/mnt/$m"; sudo mount -o bind "$ROOT/build/$m" "$c/mnt/$m"
    echo "deb [trusted=yes] file:///mnt/$m $APT_SUITE $APT_COMPONENTS" | sudo tee -a "$c$NCZ_OFFLINE_SRC" >/dev/null
  done
  # r202: reproducibility. The pinned offline mirror is a file:// repo, which
  # apt weights at priority 100 -- LOWER than any remote archive (500). Once a
  # base hook (24-apt-sources.sh) rewrites the runtime sources, apt therefore
  # prefers the live moving testing archive and the layer drifts off the pin.
  # Observed 2026-10-10: a live libpng16-16t64 1.6.59-1 landed in base while the
  # pinned mirrors and the desktop layer carried 1.6.58-1, and the desktop delta
  # then became unsatisfiable. Pin the offline mirror (empty origin == local
  # file://) above every remote source for the build only; packages absent from
  # the offline set still resolve remotely, but a package present in both can
  # never be taken from the moving archive.
  if [ "$_mirror_found" = 1 ]; then
    sudo install -d -m 0755 "$c/etc/apt/preferences.d"
    printf "Package: *\nPin: origin \"\"\nPin-Priority: 1001\n" | sudo tee "$c/etc/apt/preferences.d/00-ncz-build-offline-priority.pref" >/dev/null
  fi
  # No local mirror on this host: apt_offline() previously left the chroot
  # with ZERO apt sources in this case (every pre-existing one disabled
  # above, nothing re-added), which is fine for the reproducibility
  # contract but meant 20-desktop.sh's own apt-get install inside this
  # merged chroot always failed here -- confirmed 2026-09-14, hit for real
  # wiring build_layer()'s full production path on a host with no populated
  # mirror. Same graceful non-reproducible live-network fallback already
  # established in build_base() and build-role-delta-mkosi.sh: wire the
  # real NCZ sources + a real Debian archive source, loudly labeled
  # non-pinned, rather than leaving apt with nothing to install from at all.
  if [ "$_mirror_found" = 0 ]; then
    log "  apt_offline: no mirror for $APT_SUITE -- wiring live NCZ + base sources (non-reproducible fallback, matches build_base())"
    sudo install -d "$c/etc/apt/keyrings"
    if [ -f "$ROOT/post-install/buildkite-ncz-apt-keyring.asc" ] &&        gpg --dearmor < "$ROOT/post-install/buildkite-ncz-apt-keyring.asc" | sudo tee "$c/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg" >/dev/null 2>&1; then
      echo "deb [signed-by=/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg] https://packages.buildkite.com/ncz-os/ncz/any/ any main" |         sudo tee "$c/etc/apt/sources.list.d/ncz-os-apt-buildkite-live.list" >/dev/null
    fi
    # Exactly ONE NCZ repo (Buildkite, the superset) + the origin-separation pin,
    # same as the shipped image (post-install/lib/apt-separation.sh); R2 is no
    # longer wired as a second source (r201 apt separation).
    sudo bash -c '. "$1/post-install/lib/apt-separation.sh"; ncz_apt_write_separation_pin "$2"' _ "$ROOT" "$c"
    # A pinned snapshot.debian.org mirror (release.conf) expires its Release
    # file quickly -- without check-valid-until=no this apt-get update fails
    # closed the moment NCZ_BASE_MIRROR_SNAPSHOT is set.
    _mirror_opts="${NCZ_BASE_MIRROR_APT_OPTS:+[$NCZ_BASE_MIRROR_APT_OPTS] }"
    echo "deb ${_mirror_opts}$NCZ_BASE_MIRROR $NCZ_BASE_CODENAME $NCZ_BASE_COMPONENTS" |       sudo tee "$c/etc/apt/sources.list.d/ncz-base-live.list" >/dev/null
    sudo chroot "$c" apt-get update -y 2>&1 | tail -8 || true
    return 0
  fi
  # A remote source here means the closure is no longer pinned. Fail rather
  # than silently building against a moving archive.
  # Scope the check to files apt ACTUALLY reads (*.list, *.sources). Scanning
  # the whole directory matched our own *.disabled-for-build copies, which are
  # inert but still on disk -- a false positive that aborted a correct build.
  if sudo chroot "$c" sh -c 'cat /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -oE "https?://[^ ]+"' | grep >/dev/null .; then
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
  # Same build-time-only rule for apt_offline()'s no-mirror live fallback
  # (review finding, 2026-09-14): these are never meant to survive
  # into the shipped image -- restoring the disabled-for-build originals
  # just below would otherwise leave BOTH the restored originals AND these
  # live copies active, a duplicate/inconsistent apt configuration.
  sudo rm -f "$c/etc/apt/sources.list.d/ncz-os-apt-buildkite-live.list" \
             "$c/etc/apt/sources.list.d/ncz-os-apt-r2-live.list" \
             "$c/etc/apt/sources.list.d/ncz-base-live.list" 2>/dev/null || true
  sudo rm -f "$c/etc/apt/preferences.d/00-ncz-build-offline-priority.pref" 2>/dev/null || true
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
  # The desktop closure has its own complete, indexed repository.  The generic
  # suite/vendor mirrors are inputs for the base role and are not substitutes
  # for build/desktop-mirror.  Preserve an explicit operator override, but make
  # every normal desktop invocation (including `all`) select the role mirror.
  local MIRROR_DIRS="$MIRROR_DIRS"
  if [ "$role" = desktop ] && [ "$MIRROR_DIRS_EXPLICIT" -eq 0 ]; then
    MIRROR_DIRS="desktop-mirror"
  fi
  log "$role: apt mirror directories: $MIRROR_DIRS"
  [ -f "$OUT/base.squashfs" ] || { echo "base.squashfs missing — build base first"; exit 1; }
  [ -f "$ROOT/$manifest" ] || { echo "manifest $manifest missing"; exit 1; }
  local L="$WORK/$role-lower" U="$WORK/$role-up" WK="$WORK/$role-wk" MG="$WORK/$role-mg"
  local MKOUT="$WORK/$role-mkosi-out"
  # A killed prior build may leave bind mounts below MG. Unmount children first;
  # removing the tree while a mirror or /dev is still mounted risks deleting or
  # modifying the host-side source through that live mount.
  apt_unmount "$MG"; umount_chroot "$MG"
  sudo umount -lf "$MG" 2>/dev/null || true
  sudo rm -rf "$L" "$U" "$WK" "$MG" "$MKOUT"
  log "$role: unsquash base as lowerdir"
  sudo unsquashfs -f -d "$L" "$OUT/base.squashfs" >/dev/null 2>&1
  # The destination directory itself is not part of the squashfs payload.
  # Force ownership so maintainer scripts see a normal root-owned filesystem.
  sudo chown root:root "$L"
  assert_rootfs_critical_owners "$L" "$role lowerdir"
  # 2026-09-14: package installation for this layer is now produced by
  # build-role-delta-mkosi.sh (containerized mkosi, BaseTrees=$L +
  # Overlay=yes) instead of a hand-rolled mount+chroot+apt-get here -- see
  # that script's header for why (host-mount safety, the dpkg-status dedup
  # hazard its hooks close, the offline-mirror single-source contract it now
  # also enforces). It replaces ONLY package installation: the upperdir it
  # hands back becomes $U below, and everything after this point (the
  # brand-hook loop, metacopy materialization, overlay-manifest generation,
  # mksquashfs) is UNCHANGED from before -- those steps operate on $U's
  # content, not on how it was produced.
  MIRROR_DIRS="$MIRROR_DIRS" APT_SUITE="$APT_SUITE" APT_COMPONENTS="$APT_COMPONENTS" \
    WORK="$WORK/$role-mkosi-work" WORK_EXPLICIT=1 \
    "$ROOT/build/build-role-delta-mkosi.sh" "$role" "$ROOT/$manifest" "$L" "$MKOUT" "$NCZ_TARGET_ARCH" || {
    log "ERROR: $role mkosi delta build failed; refusing to publish an incomplete layer"
    sudo rm -rf "$L" "$MKOUT"
    return 1
  }
  sudo mv "$MKOUT/image" "$U"
  sudo rm -rf "$MKOUT"
  # sudo: $WORK is root-owned as soon as any earlier stage has run under sudo,
  # so an unprivileged mkdir here fails with "mkdir: Permission denied" and
  # set -e aborts the build four seconds in, having logged nothing but the
  # three mkdir errors. These three directories are chown'd to root on the very
  # next line regardless, so creating them as root changes nothing else.
  sudo mkdir -p "$U" "$WK" "$MG"
  # Overlay presents the upper/mount root as the chroot root. None of the
  # backing directories may retain invoking-user ownership or systemd's
  # maintainer scripts reject `/` as an unsafe path.
  sudo chown -R root:root "$U"
  sudo chown root:root "$WK" "$MG"
  # SECOND overlay mount, deliberately separate from mkosi's own internal one:
  # the brand-hook loop below chroots into a MERGED base+delta view to install
  # further packages (vivaldi, chrome, Artist Pack debs) and run installer
  # hooks -- $U alone (mkosi's static output) has no base binaries in it and
  # cannot be chrooted into on its own. See build-role-delta-mkosi.sh's
  # "Integration" section for the full reasoning.
  sudo mount -t overlay overlay -o "lowerdir=$L,upperdir=$U,workdir=$WK" "$MG"
  mount_chroot "$MG"
  # mkosi's Overlay=yes dedup pass strips /etc/ld.so.cache as a "duplicate
  # path" during the delta build (same hazard class as the dpkg-status
  # dedup issue the save/restore hooks in build-role-delta-mkosi.sh close --
  # confirmed 2026-09-14 wiring the real production path: labwc's runtime-
  # closure check failed on libdisplay-info.so.5 even though the .so file
  # AND /etc/ld.so.conf.d/singularity.conf were both genuinely present in
  # the delta's upperdir -- the merged chroot was just reading base's STALE
  # cache, built before singularity.conf existed). Rebuilding here (rather
  # than stashing/restoring the cache file like dpkg-status) is simpler and
  # can't go stale: it reflects whatever ld.so.conf.d files are actually in
  # the merged view at this exact point, base + delta combined.
  # WORKAROUND for a real packaging defect, not a pipeline bug: the
  # ncz-singularity-desktop .deb ships /etc/ld.so.conf.d/singularity.conf
  # listing only /opt/singularity/lib, but its own libraries (e.g.
  # libdisplay-info.so.5, confirmed 2026-09-14) actually live one level
  # deeper at /opt/singularity/lib/aarch64-linux-gnu -- ldconfig does NOT
  # recurse into subdirectories listed in ld.so.conf.d, so that path was
  # never in the cache regardless of how many times ldconfig ran. The
  # correct fix is the package's own conf file (build/build-singularity-deb.sh),
  # not here -- this just unblocks the test ISO in the meantime. Remove once
  # a corrected ncz-singularity-desktop package ships the right path itself.
  echo "/opt/singularity/lib/aarch64-linux-gnu" | sudo tee "$MG/etc/ld.so.conf.d/zz-singularity-multiarch-workaround.conf" >/dev/null
  sudo chroot "$MG" ldconfig
  # apt_offline still runs here: mkosi already installed the manifest's
  # top-level package set above, but the brand-hook loop's OWN apt/dpkg calls
  # (52-vivaldi, 53-chrome, 45-wallpaper-rotator staging Artist Pack debs)
  # need the same pinned offline source to resolve against.
  apt_offline "$MG"
  echo -e '#!/bin/sh\nexit 101' | sudo tee "$MG/usr/sbin/policy-rc.d" >/dev/null; sudo chmod +x "$MG/usr/sbin/policy-rc.d"
  # r190.2: disable needrestart kernel hints -- same fix already applied in
  # build-baked-rootfs.sh (and the retired ISO builder), but never here. Without it,
  # needrestart pops an interactive whiptail "Pending kernel upgrade" msgbox
  # mid apt-get-install (the chroot's kernel version differs from the host's
  # running kernel) with no tty reader available, hanging the build
  # indefinitely (found 2026-07-05, desktop.squashfs rebuild #2 stalled ~30min
  # until manually killed).
  sudo mkdir -p "$MG/etc/needrestart/conf.d"
  printf '$nrconf{kernelhints} = 0;\n' | sudo tee "$MG/etc/needrestart/conf.d/99-squashfs-layer.conf" >/dev/null
  if [ "$role" = "desktop" ]; then
    log "desktop: SINGULARITY desktop delta (Wayland-only; XFCE/X11 removed) + brand"
    # 26.10 "Cygnus": Singularity Desktop (labwc/wlroots, GTK4) REPLACES XFCE.
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
    sudo mkdir -p "$MG/usr/local/lib/cix-installer/manifests"
    sudo cp -a "$ROOT/manifests/." "$MG/usr/local/lib/cix-installer/manifests/" 2>/dev/null || true
    [ -s "$ROOT/release.conf" ] && \
      sudo install -m 0644 "$ROOT/release.conf" "$MG/usr/local/lib/cix-installer/RELEASE"
    # Refresh the screensaver version floor in the desktop layer too (base may
    # predate it): 59-ncz-screensavers-pkg reads it from the target at install
    # time, and the desktop overlay is what the finished image carries.
    sudo install -d -m 0755 "$MG/usr/local/lib/cix-installer/build"
    sudo install -m 0644 "$ROOT/build/screensavers-version.env" "$MG/usr/local/lib/cix-installer/build/"
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
    # Artist Pack .debs (build/build-wallpaper-contrib-deb.sh), gitignored
    # blobs staged onto the build host like assets/cix-debs -- 45-wallpaper
    # dpkg -i's whatever lands here, so a build without any staged is a
    # normal (not broken) desktop, just without the contributed art.
    if [ -d "$ROOT/assets/wallpaper-debs" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/wallpaper-debs"
      sudo cp -a "$ROOT/assets/wallpaper-debs/." "$MG/usr/local/lib/cix-installer/assets/wallpaper-debs/" 2>/dev/null || true
      log "  staged wallpaper Artist Pack debs ($(find "$ROOT/assets/wallpaper-debs" -type f -name '*.deb' | wc -l | tr -d ' ') packages)"
    fi
    # r181: stage the Vivaldi .deb so 52-vivaldi.sh installs the browser OFFLINE
    # (the MNEMOS + agent launchers Exec vivaldi-stable; epiphany can't play
    # YouTube on arm64). Self-contained .deb, no mirror/closure changes needed.
    # Only the deb that manifests/vendor-debs.tsv pins (exact version + sha256) is staged,
    # so a superseded deb left in the tree never reaches the image.
    if [ -d "$ROOT/assets/vivaldi" ]; then
      # shellcheck source=lib/vendor-deb-pin.sh
      . "$ROOT/build/lib/vendor-deb-pin.sh"
      _viv_deb="$(ncz_vendor_staged_deb "$ROOT" vivaldi-stable "$NCZ_TARGET_ARCH" assets/vivaldi)" || exit 1
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/vivaldi"
      sudo cp -a "$_viv_deb" "$MG/usr/local/lib/cix-installer/assets/vivaldi/"
      log "  staged $(basename "$_viv_deb") (pinned in manifests/vendor-debs.tsv)"
    fi
    # The OTA desktop update UI (KNOWN-ISSUES #2). 50-update-manager.sh looks
    # for /usr/local/lib/cix-installer/assets/update-manager and then
    # /cdrom/ncz-payload/assets/update-manager; on a raw-image install only
    # this copy exists, so without it the hook fails as optional on every
    # install. The USB/media path carries the same assets via the
    # asset_names tuple in build/iso/write-usb-image.py.
    if [ -d "$ROOT/assets/update-manager" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/update-manager"
      sudo cp -a "$ROOT/assets/update-manager/." "$MG/usr/local/lib/cix-installer/assets/update-manager/" 2>/dev/null || true
      log "  staged update-manager assets ($(find "$ROOT/assets/update-manager" -type f | wc -l | tr -d ' ') files)"
    fi
    # Stage NVIDIA's real cuda-keyring .deb so 54-gpu-accel.sh (AMD64) can
    # wire the official CUDA apt repo without a build-time network fetch --
    # small (~4KB) signing-key installer, committed directly rather than
    # gitignored like the large binary staging dirs above. AMD/Intel don't
    # need pre-staging: their signing keys are fetched at real INSTALL time
    # (54-gpu-accel.sh already handles that with its own validation), only
    # NVIDIA ships its key as an installable .deb rather than a bare key URL.
    if [ -d "$ROOT/assets/nvidia" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/nvidia"
      sudo cp -a "$ROOT/assets/nvidia/." "$MG/usr/local/lib/cix-installer/assets/nvidia/" 2>/dev/null || true
      log "  staged nvidia cuda-keyring asset ($(find "$ROOT/assets/nvidia" -type f | wc -l | tr -d ' ') files)"
    fi
    # AMD64 has no Buildkite-published ncz-singularity-desktop package yet
    # (arm64's real production path -- see the apt_offline()/offline-mirror
    # comment above), so stage the locally-built .deb the same way
    # 10-our-kernel.sh already stages kernel debs for the no-mirror case, and
    # let 20-desktop.sh's existing embedded-deb check (mirrors its
    # /cdrom/pool/main pattern) find it here too. This is a staging path,
    # not a new mechanism -- assets/cix-debs/*.deb is gitignored and
    # build-host-local by the project's own convention (see .gitignore).
    if [ -n "$(ls -1 "$ROOT/assets/cix-debs/"ncz-singularity-desktop_*_"$NCZ_TARGET_ARCH".deb 2>/dev/null)" ]; then
      sudo mkdir -p "$MG/usr/local/lib/cix-installer/assets/cix-debs"
      sudo cp -a "$ROOT/assets/cix-debs/"ncz-singularity-desktop_*_"$NCZ_TARGET_ARCH".deb "$MG/usr/local/lib/cix-installer/assets/cix-debs/" 2>/dev/null || true
      log "  staged ncz-singularity-desktop deb (no Buildkite package yet for $NCZ_TARGET_ARCH)"
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
    # layer --)
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
        -name "ncz-singularity-desktop_*_${NCZ_TARGET_ARCH}.deb" 2>/dev/null || true)
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
      sudo cp -a "$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst" "$MG/usr/local/lib/cix-installer/assets/mgmt/" \
        || { echo "FATAL: could not stage the mgmt rootfs into the layer" >&2; exit 1; }
      log "  staged mgmt rootfs ($(du -h "$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst" | cut -f1))"
    else
      # r201: this used to pass silently and 38-recovery-container.sh then failed on every
      # installed image. The rootfs is a pinned build input, not optional.
      echo "FATAL: assets/mgmt/ncz-mgmt-rootfs.tar.zst missing: run build/stage-build-inputs.sh --arch <arch>" >&2
      exit 1
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
    # writes /etc/mpv HW-decode. 59-ncz-screensavers-pkg installs the shipped
    # screensaver engine, idle timer and 74-title catalogue (the 0.8.9 deb ships
    # no plugin files; the Singularity plugin is a separate, not-yet-published
    # package). 59-desktop-curate
    # LAST of the app hooks (after 20/52-vivaldi/46-ncz-cli) so it sees
    # every app-creating hook's output when it curates the launcher.
    for bh in 20-desktop 22-display-fix 23-locale-env 50-brand 52-vivaldi 53-chrome 56-icon-theme 45-wallpaper-rotator 55-greeter 84-vpu-mpv 84-vpu-vaapi 57-qotd 46-ncz-cli 59-desktop-curate 60-boot-splash; do
      [ -f "$MG/usr/local/lib/cix-installer/post-install/$bh.sh" ] || { log "  skip $bh (absent)"; continue; }
      log "  desktop brand hook -> $bh"
      set +e
      sudo chroot "$MG" env NCZ_LAYER_BUILD=1 bash -c "cd /usr/local/lib/cix-installer/post-install && bash ./$bh.sh" 2>&1 | tail -3
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
  sudo rm -rf "$U/var/lib/apt/lists/"* "$U/var/cache/apt/"* "$U/tmp/"* "$U/usr/bin/$QEMU_BIN" 2>/dev/null || true
  # Preserve the overlay semantics in a sidecar consumed by the installer.
  # A raw upperdir contains both char-device 0:0 whiteouts and opaque directory
  # xattrs; ordinary unsquashfs understands neither when merging into a base.
  # Strip overlay-internal xattrs from the payload after recording them so they
  # do not contaminate the installed filesystem.
  strip_build_host_state "$U" "$role" || exit 1
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
  # -xattrs-exclude is REPEATED, not replaced: mksquashfs accepts the flag more
  # than once and the matches are OR'd.
  #   ^trusted\.overlay\.  -- overlayfs internals (opaque/metacopy/redundant
  #                          markers). Plain unsquashfs cannot replay them;
  #                          keep them out of the published archive.
  #   ^security\.selinux  -- HOST SELinux labels. NCZ-OS is a Debian image and
  #                          must not carry the build host's MAC labels: on a
  #                          Fedora Asahi host (or any podman-managed build)
  #                          these come from THIS machine's SELinux policy
  #                          (e.g. system_u:object_r:container_file_t:s0:c1022,
  #                          c1023 = podman per-container MCS categories), and
  #                          they are meaningless inside a Debian rootfs that
  #                          is never going to be evaluated by that policy.
  #                          Their presence also caused a false-positive
  #                          corruption verdict in verify_squashfs(): when the
  #                          verifier's extraction target cannot hold xattrs
  #                          (e.g. an overlayfs upperdir without user_xattr),
  #                          unsquashfs fails the restore with
  #                          "write_xattr: failed to write xattr
  #                          security.selinux ... extended attributes are not
  #                          supported by the destination filesystem" and
  #                          exits 2, condemning a perfectly good archive.
  #                          Other xattrs are NOT stripped wholesale:
  #                          security.capability (file caps, e.g. on /bin/ping)
  #                          is legitimate Debian content and must survive.
  # env -u SOURCE_DATE_EPOCH: mksquashfs >= 4.7 refuses SOURCE_DATE_EPOCH +
  # explicit -all-time/-fstime together; we keep the explicit epoch-0 form.
  sudo env -u SOURCE_DATE_EPOCH mksquashfs "$U" "$OUT/$role.squashfs" -comp zstd -Xcompression-level 15 -all-time 0 -fstime 0 -processors 1 \
    -xattrs-exclude '^trusted\.overlay\.' -xattrs-exclude '^security\.selinux' -noappend -no-progress 2>&1 | tail -2
  verify_squashfs "$OUT/$role.squashfs" "$role"
  log "$role DONE: delta $(du -h "$OUT/$role.squashfs"|cut -f1)"
  sudo rm -rf "$L" "$MG" "$WK"
}

ensure_base_tarball_fresh(){
  # The base tarball (assets/rootfs/rootfs-$APT_SUITE-arm64.tar.zst) is a
  # fixed mmdebstrap snapshot -- unlike base.squashfs, which build_base()
  # regenerates unconditionally every run, this INPUT can silently go stale
  # (missed security updates, drifted against the current apt mirror) with
  # nothing forcing a refresh. Never let it go stale unnoticed -- age-gate it
  # here and auto-regenerate past the limit, same as if it were simply
  # missing (which this also self-heals).
  local max_age_days="${BASE_TARBALL_MAX_AGE_DAYS:-5}"
  local need_regen=0 age_days
  if [ ! -f "$BASE_TARBALL" ]; then
    log "BASE: $BASE_TARBALL absent -- generating"
    need_regen=1
  else
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$BASE_TARBALL") ) / 86400 ))
    if [ "$age_days" -gt "$max_age_days" ]; then
      log "BASE: $BASE_TARBALL is ${age_days}d old (>${max_age_days}d limit) -- regenerating"
      need_regen=1
    else
      log "BASE: $BASE_TARBALL is ${age_days}d old (<=${max_age_days}d limit) -- reusing"
    fi
  fi
  [ "$need_regen" = 1 ] || return 0
  local gen="$ROOT/build/build-base-rootfs.sh"
  [ -x "$gen" ] || { log "ERROR: $BASE_TARBALL needs (re)generation but $gen is missing/not executable"; exit 1; }
  # No sudo: build-base-rootfs.sh runs mmdebstrap inside a podman container
  # as the invoking user -- running it under sudo would use root's podman
  # storage/config instead of this user's, which is a different (and here,
  # unpopulated) container storage backend.
  # Forward NCZ_TARGET_ARCH and the resolved BASE_TARBALL path -- without
  # these, build-base-rootfs.sh falls back to its own arm64-only defaults
  # (ARCH=${4:-arm64}, OUT filename hardcoded -arm64.tar.zst) regardless of
  # NCZ_TARGET_ARCH, silently producing an arm64 tarball under an amd64 run.
  # Found 2026-09-15 rebuilding the amd64 forky ISO: the regen step exited 0
  # having written rootfs-forky-arm64.tar, then failed the existence check
  # below because BASE_TARBALL correctly expected the -amd64 name.
  bash "$gen" "" "$BASE_TARBALL" "" "$NCZ_TARGET_ARCH" || { log "ERROR: base-rootfs regeneration failed"; exit 1; }
  [ -f "$BASE_TARBALL" ] || { log "ERROR: $gen ran but did not produce $BASE_TARBALL"; exit 1; }
}

build_base(){
  # Kernel default policy gate (design rule 2026-09-30). Refuses to
  # bake a base layer whose shipping kernel is -rcN, and refuses on amd64
  # if any amd64-edge payload remains staged (the amd64-edge directory
  # was removed from the repo; the check still fires if it is re-added).
  # Same gate as build/build-installer-image.sh -- duplicated here because
  # this script can also be invoked standalone (e.g. to rebuild just
  # base.squashfs without rebuilding the whole image) and must refuse to
  # ship a base layer that would, on next image build, install 7.3-rc5
  # as default.
  if [ -x "$ROOT/build/verify-kernel-default-policy.sh" ]; then
    # Gate the arch this run builds: NCZ_TARGET_ARCH is resolved and checked
    # (arm64|amd64) at the top of this script. Re-deriving it from release.conf
    # killed the build: release.conf has no NCZ_TARGET_ARCH line, so the grep
    # exits 1 and set -euo pipefail ends the script with no message, the first
    # time build_base runs in a tree without a reusable base.squashfs.
    "$ROOT/build/verify-kernel-default-policy.sh" --root "$ROOT" --arch "$NCZ_TARGET_ARCH" \
      || { echo "[build-squashfs-layers] FATAL: kernel default policy failed" >&2; return 1; }
  fi
  log "BASE: extract $APT_SUITE base"
  # r160b (2026-09-15): ensure the default NCZ wallpaper Artist Pack is
  # staged BEFORE the base asset-copy loop runs. This build-time step
  # existed in the old pipeline and was silently dropped when this one was
  # written -- post-install/45-wallpaper-rotator.sh has always had a
  # WARN-and-skip fallback for a missing assets/wallpaper-debs/ (so the
  # build itself never failed loudly), but the real effect is total: no
  # deb staged means no ncz-wallpapers-ncz package installed means no
  # wallpaper timer/service unit exists on the finished system at all --
  # confirmed live on O6N, systemctl list-unit-files came back with
  # zero wallpaper-rotation matches. Same root cause likely blocks the
  # Artist Pack install flow too (its polkit backend scripts install fine,
  # but read from this same directory to list/install packs).
  # Ship all five packs we own (cygnus-2610 is the default): ncz (required, has its own fail-loud gate
  # in 45-wallpaper-rotator.sh), singularity (repackages the upstream
  # singularity-wallpapers set as an installable pack so ncz-wallpaper-rotate
  # picks it up, distinct from the copy that ships inside /opt/singularity),
  # and the contributed Brandon Perlow and Alex Jay Brady packs. Only ncz
  # used to be auto-built here (as a fallback when NOTHING was staged), so a
  # from-scratch build silently shipped without the other three --
  # assets/wallpaper-debs/ is gitignored and build-wallpaper-contrib-deb.sh
  # was never invoked for them.
  mkdir -p "$ROOT/assets/wallpaper-debs"
  for pack in ncz cygnus-2610 singularity brandon-perlow alex-jay-brady; do
    if ls "$ROOT/assets/wallpaper-debs/ncz-wallpapers-${pack}_"*.deb >/dev/null 2>&1; then
      continue
    fi
    log "  wallpaper-debs: $pack not staged -- building"
    if bash "$ROOT/build/build-wallpaper-contrib-deb.sh" "$pack" >/dev/null 2>&1; then
      cp "$ROOT/build/wallpaper-debs/"*.deb "$ROOT/assets/wallpaper-debs/" 2>/dev/null || true
    elif [ "$pack" = ncz ]; then
      log "  WARN: build-wallpaper-contrib-deb.sh ncz failed -- shipping with NO default wallpaper (see post-install/45-wallpaper-rotator.sh)"
    else
      log "  WARN: build-wallpaper-contrib-deb.sh $pack failed -- shipping without the $pack Artist Pack"
    fi
  done
  log "  wallpaper-debs: staged $(ls "$ROOT/assets/wallpaper-debs/"*.deb 2>/dev/null | wc -l) pack(s)"
  ensure_base_tarball_fresh
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
  # Kernel purity (design rule 2026-10-04): pin Debian's kernels out of
  # the base layer BEFORE any apt operation. The early installer-base.pkgs
  # install below runs long before post-install/10-our-kernel.sh would write
  # the pin, and a package that Depends/Recommends linux-image-* must not be
  # able to pull the Debian kernel into the baked base rootfs. The preference
  # text is the single source of truth in the repo lib (same text the install
  # hooks write).
  if [ -r "$ROOT/post-install/lib/kernel-purity.sh" ]; then
    # shellcheck source=../post-install/lib/kernel-purity.sh
    . "$ROOT/post-install/lib/kernel-purity.sh"
    sudo install -d -m 0755 "$WORK/base/etc/apt/preferences.d"
    ncz_kernel_purity_pin_text | sudo tee "$WORK/base/etc/apt/preferences.d/00-ncz-kernel-purity.pref" >/dev/null
    sudo chmod 0644 "$WORK/base/etc/apt/preferences.d/00-ncz-kernel-purity.pref"
    log "  installed /etc/apt/preferences.d/00-ncz-kernel-purity.pref in the base layer"
  else
    log "  WARN: $ROOT/post-install/lib/kernel-purity.sh missing -- base layer has no Debian-kernel pin"
  fi
  # The base layer now consumes installer-base.pkgs explicitly.  If a pinned
  # offline mirror is present, use it; otherwise fall back to the rootfs' own
  # sources for local developer experiments.
  if mirror_available; then
    apt_offline "$WORK/base"
  else
    # 24-apt-sources.sh's own header says it must wire NCZ's apt source(s)
    # EARLY, before ANY hook that installs packages -- but nothing actually
    # ran it before the manifest-driven install below until now. Stage just
    # enough of the hook tree to run it here, before $_base_pkgs (which
    # includes NCZ-custom packages like linux-image-cixmini/cixmini-boot,
    # not just ordinary Debian ones). The full hook tree gets re-staged
    # again further down for the BASE_HOOKS loop -- that re-copy is
    # idempotent and harmless, it's just not early enough on its own.
    log "no mirror for $APT_SUITE -> wiring NCZ + base apt sources early (24-apt-sources)"
    sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer"
    sudo cp -a "$ROOT/post-install" "$WORK/base/usr/local/lib/cix-installer/"
    sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/manifests"
    sudo cp -a "$ROOT/manifests/." "$WORK/base/usr/local/lib/cix-installer/manifests/" 2>/dev/null || true
    sudo install -m 0644 "$ROOT/release.conf" "$WORK/base/usr/local/lib/cix-installer/RELEASE"
    if ! sudo chroot "$WORK/base" bash -c 'cd /usr/local/lib/cix-installer/post-install && bash ./24-apt-sources.sh' 2>&1 | tail -12; then
      log "ERROR: 24-apt-sources.sh failed with no local mirror available -- cannot resolve any base packages"
      apt_unmount "$WORK/base"; umount_chroot "$WORK/base"; sudo umount -lf "$WORK/base" 2>/dev/null || true
      return 1
    fi
  fi
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
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/manifests"
  sudo cp -a "$ROOT/manifests/." "$WORK/base/usr/local/lib/cix-installer/manifests/" 2>/dev/null || true
  sudo install -m 0644 "$ROOT/release.conf" "$WORK/base/usr/local/lib/cix-installer/RELEASE"
  # The screensaver version floor must travel with the image:
  # 59-ncz-screensavers-pkg sources it at install time from the target's own
  # /usr/local/lib/cix-installer/build/ tree, which holds exactly what this
  # staging puts there. Without this the mandatory-install hook FATALs on
  # every real install (env not found) -- the floor is defined once in the
  # repo and every consumer reads the same file.
  sudo install -d -m 0755 "$WORK/base/usr/local/lib/cix-installer/build"
  sudo install -m 0644 "$ROOT/build/screensavers-version.env" "$WORK/base/usr/local/lib/cix-installer/build/"
  sudo mkdir -p "$WORK/base/usr/local/lib/cix-installer/assets"
  # Real, current assets/ subdirs meant to ship inside the target OS.
  # Deliberately excludes: assets/rootfs (base-tarball build cache),
  # assets/squashfs (this script's own output dir), assets/models (not
  # consumed by anything in this pipeline yet -- verify before adding),
  # and mesa/cix-py/vivaldi/nvidia/wallpaper-debs/cix-debs's *.deb payload
  # which the desktop-role branch stages separately below. Found stale
  # 2026-09-24 (real 7.34GB reference ISO vs a 3.56GB new build) --
  # agent-images/agent-stack/audio/cix-c-shims/cix-mm/dev/diag/docs/
  # dracut/embedkit/keys/npu/regreet/singularity were silently dropped by
  # this allowlist, breaking the NCZ agent stack, EmbedKit LLM stack, the
  # regreet login theme, NPU assets, and Singularity Desktop's own asset
  # tree on every amd64 build since this loop was last updated.
  for a in cix-debs kernel mesa gpu sky1-firmware firmware refind grub rescue branding wallpaper wallpaper-debs sinty-nm agent-images agent-stack audio display cix-c-shims cix-mm dev diag docs dracut embedkit amd intel keys npu regreet singularity; do
    # assets/dracut is Sky1-only (docs/platform-inventory.tsv): 10-ncz-sky1.conf
    # is the linlon-dp/trilin-dpsub Sky1 display + USB-ethernet module set.
    # 94-dracut-config refuses to apply it on amd64, but staging the file still
    # leaves an arm64-only dracut config in the amd64 payload (and any future
    # consumer would feed it to dracut, which logs "linlon_dp: module not
    # found"). Never stage it into an amd64 base.
    case "$a" in
      dracut) [ "$NCZ_TARGET_ARCH" = amd64 ] && continue ;;
    esac
    [ -d "$ROOT/assets/$a" ] && sudo cp -a "$ROOT/assets/$a" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true
  done
  # Only the pinned kernel's accelerator overlays belong in the image. The copy
  # above takes whatever the build tree holds, and a long-lived build tree holds
  # every overlay ever staged: the d395bb2d images shipped ~40 retired
  # <drv>/<kver>/ directories (7.0.12 .. 7.3.0-rc6) and the retired
  # modules-overlay/<kver> and r<NNN>-*/test-* kernel snapshots, whose modules carry the
  # build paths of the machines that compiled them. Keep the pinned KVER only.
  _pin_kver="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["variants"]["mainline"]["kver"])' "$ROOT/assets/kernel-manifest.json" 2>/dev/null || true)"
  _ka="$WORK/base/usr/local/lib/cix-installer/assets/kernel"
  if [ -n "$_pin_kver" ] && [ -d "$_ka" ]; then
    for _drv in mali npu vpu panthor modules-overlay; do
      for _kd in "$_ka/$_drv"/[0-9]*.*-*; do
        [ -d "$_kd" ] || continue
        [ "$(basename "$_kd")" = "$_pin_kver" ] || sudo rm -rf "$_kd"
      done
    done
    sudo rm -rf "$_ka"/r[0-9]*-* "$_ka"/test-*
    # assets/kernel/mainline is the build tree's link into this host's
    # kernel-staging pool (build/link-kernel-mainline.sh); on an installed
    # system it dangles. The installer takes the Sky1 kernel from the medium
    # (ncz-payload/assets/kernel/mainline, a real directory).
    if [ -L "$_ka/mainline" ]; then sudo rm -f "$_ka/mainline"; fi
    log "  kernel assets: accelerator overlays pruned to the pinned $_pin_kver; build-local mainline link left out"
  else
    log "ERROR: no pinned kernel version in assets/kernel-manifest.json; cannot prune staged overlays"
    exit 1
  fi
  # Standalone files at assets/ root -- same silent-drop bug, same fix.
  for f in install_ncz_agents.sh kernel-manifest.json README.md cix-deb-repo.gpg; do [ -f "$ROOT/assets/$f" ] && sudo cp -a "$ROOT/assets/$f" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true; done
  if [ -f "$ROOT/assets/sinty-nm/sinty-nmd" ]; then
    log "  staged sinty-nm daemon into BASE ($(du -h "$ROOT/assets/sinty-nm/sinty-nmd" | cut -f1))"
  else
    log "  WARN: assets/sinty-nm/sinty-nmd ABSENT — base falls back to NetworkManager (build singularityos-lab/sinty-nm)"
  fi
  [ -f "$ROOT/assets/ncz-cli.sh" ] && sudo cp -a "$ROOT/assets/ncz-cli.sh" "$WORK/base/usr/local/lib/cix-installer/assets/" 2>/dev/null || true
  base_assets_stamp | sudo tee "$WORK/base/$BASE_STAMP_REL" >/dev/null   # see base_assets_stamp
  # prune dev-only junk from the staged asset tree (backup kernels, retired
  # channels) -- it otherwise ships inside base.squashfs as dead weight
  sudo rm -rf "$WORK/base/usr/local/lib/cix-installer/assets/kernel/"retired-* 2>/dev/null || true
  sudo find "$WORK/base/usr/local/lib/cix-installer/assets" \( -name "*.pre-*" -o -name "*.bak" -o -name "*.r57-bak" \) -delete 2>/dev/null || true
  # test/validation debs are SKIPPED by 25-cix-proprietary at install time
  # (see its DEBS filter) and consumed by nothing else -- do not bake ~2.2G
  # of dead weight into base.squashfs
  # BEGIN prune-singularity-from-base
  # The base layer NEVER carries an ncz-singularity-desktop deb. The payload
  # reaches the target from the desktop layer (build_layer stages the arch's
  # deb from assets/cix-debs into its own assets/cix-debs, same path), from
  # /cdrom/pool/main and from /cdrom/ncz-payload; 25-cix-proprietary.sh skips it
  # by name and 20-desktop.sh falls back to apt. The copy of assets/cix-debs
  # just made into the base is therefore dead weight (~46 MB) and, when it is an
  # OLDER build than the one the payload stage produces, a stale second deb
  # shipped in the image (found on the r201 amd64 image).
  # This must NOT depend on build/sinty-out: in STAGE=all build_base runs BEFORE
  # build_singularity_payload, so on a clean tree sinty-out is still empty here.
  sudo rm -f "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"ncz-singularity-desktop_*.deb
  # END prune-singularity-from-base
  sudo rm -f "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-unit-test_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-ltp_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-gpu-test_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-vpu-test_*.deb \
             "$WORK/base/usr/local/lib/cix-installer/assets/cix-debs/"cix-npu-onnxruntime_*.deb 2>/dev/null || true
  # KVER sidecar that 10-our-kernel.sh + 70-bootloader.sh need to discover
  # the shipped (mainline) kernel's KVER at install time. The sidecar keeps
  # its historical KVER_NEXT name because installed systems already carry it.
  [ -f "$ROOT/assets/kernel/mainline/KVER" ] && sudo cp "$ROOT/assets/kernel/mainline/KVER" "$WORK/base/usr/local/lib/cix-installer/KVER_NEXT"
  # Unified 7.3 policy (2026-10-05): the arm64 base bakes the SAME
  # one 7.3 kernel as the default/installer kernel (KVER_NEXT above). The
  # retired second experimental "edge" line (assets/kernel/edge, KVER_EDGE)
  # is gone -- remove any stale edge asset/KVER_EDGE the cp -a above may have
  # carried, so base.squashfs cannot ship a second kernel line.
  sudo rm -rf "$WORK/base/usr/local/lib/cix-installer/assets/kernel/edge"
  sudo rm -f "$WORK/base/usr/local/lib/cix-installer/KVER_EDGE"
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
  # Cygnus 26.10 rEFInd theme (tracked under assets/refind/cygnus); the refresh
  # scripts stage it to the ESP when present.
  if [ -d "$ROOT/assets/refind/cygnus" ]; then
    sudo cp -a "$ROOT/assets/refind/cygnus" "$WORK/base/usr/local/lib/cix-installer/assets/refind/"
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
    if ! sudo chroot "$WORK/base" dpkg-query -W -f='${Status}' network-manager 2>/dev/null | grep >/dev/null "^install ok installed"; then
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
      sudo chroot "$WORK/base" dpkg-query -W -f='${Status}' "$_p" 2>/dev/null | grep >/dev/null "^install ok installed" \
          && _purge="$_purge $_p"
  done
  if [ -n "$_purge" ]; then
      sudo chroot "$WORK/base" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $_purge 2>&1 | tail -6 \
          || log "  WARN gnome purge rc=$?"
  else
      log "  BASE: no GNOME/Ubuntu desktop packages installed — nothing to purge"
  fi
  sudo chroot "$WORK/base" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge 2>&1 | tail -4 || true
  # r160: DE-CLOUD the base rootfs (written for the old Ubuntu cloud base, kept
  # as a belt; the r160 install-time STUB fixups are the braces — both are
  # idempotent):
  #  - systemd-networkd (+ wait-online + dispatcher) is enabled alongside NM
  #    but has no .network config on NCZ → every boot stalls ~120s in
  #    systemd-networkd-wait-online. NM is the NCZ network manager.
  #  - 60-cloudimg-settings.conf forces PasswordAuthentication no; the project
  #    is LAN-only and requires the password fallback (doctrine: lockout
  #    recovery beats plaintext-on-LAN concerns). First-value-wins → 10-.
  sudo chroot "$WORK/base" systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service networkd-dispatcher.service 2>/dev/null || true
  # r164: make NetworkManager manage ETHERNET too. The old Ubuntu desktop base shipped
  # /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf =
  #   unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma
  # i.e. NM handles ONLY wifi and leaves ethernet to systemd-networkd — which we
  # just disabled (de-cloud, above). Net result on real hardware: the wired NIC
  # is 'unmanaged' and never gets DHCP (wifi works, ethernet dead — observed on a Sky1 test board).
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
  # sshd-keygen.service ConditionFirstBoot=yes is fragile on a pre-built image
  # (measured 2026-09-15: ssh.service FAILED 4x on a real qemu boot test of
  # ncz-amd64-desktop.img despite an empty machine-id) -- force key generation
  # unconditionally as a drop-in, ssh-keygen -A is idempotent and skips keys
  # that already exist so this is safe even when the first-boot path DOES fire.
  #
  # r2 (2026-09-15, same night): the first version of this drop-in did NOT
  # work -- confirmed via a real interactive serial-console login on a
  # rebuilt+re-tested image. `systemctl cat ssh.service` showed the merged
  # unit runs the BASE fragment's `ExecStartPre=/usr/sbin/sshd -t` FIRST,
  # then appends this drop-in's `ExecStartPre=/usr/bin/ssh-keygen -A` AFTER
  # it -- a systemd drop-in's ExecStartPre= lines are APPENDED to the list,
  # never reordered ahead of the base unit's own. So `sshd -t` ran first,
  # failed immediately with "sshd: no hostkeys available -- exiting." (no
  # keys exist yet), and the unit hit start-limit-hit before ssh-keygen ever
  # got a chance to run. The empty `ExecStartPre=` line below clears the
  # inherited list (including the base fragment's `sshd -t`) so this drop-in
  # can redeclare both steps in the correct order.
  sudo mkdir -p "$WORK/base/etc/systemd/system/ssh.service.d"
  printf '[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
' | sudo tee "$WORK/base/etc/systemd/system/ssh.service.d/10-ensure-hostkeys.conf" >/dev/null
  # cleanup
  sudo rm -f "$WORK/base/usr/sbin/policy-rc.d" "$WORK/base/usr/bin/$QEMU_BIN"
  sudo chroot "$WORK/base" apt-get clean 2>/dev/null || true
  sudo rm -rf "$WORK/base/var/lib/apt/lists/"* "$WORK/base/tmp/"* 2>/dev/null || true
  apt_unmount "$WORK/base"; umount_chroot "$WORK/base"
  strip_build_host_state "$WORK/base" base || exit 1
  # 2026-08-26: defensive chmod 0755 on the base root before mksquashfs.
  # Why: O6N install shipped with / mode 0700 (observed). mksquashfs
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
  # 2026-09-13: this call was missing `sudo`, unlike the equivalent hotfix
  # gate below (line ~914 at the time of this fix). $WORK/base is owned
  # root:root (it's a chroot rootfs), so a bare `chmod` run as the
  # unprivileged build user ALWAYS failed with "Operation not permitted" --
  # meaning this guardrail (added 2026-08-26 specifically to catch a
  # shipped 0700 root) could never once succeed, and every `base` stage
  # rebuild since has hard-failed here. Confirmed: base.squashfs / dpkg
  # dates were stuck at 2026-08-25, predating the gate's introduction --
  # nobody had rebuilt the base layer since, because this always failed.
  sudo chmod 0755 "$WORK/base" || {
    log "ERROR: failed to chmod 0755 $WORK/base before mksquashfs — refusing to publish a possibly-unbootable layer"
    exit 1
  }
  # Drop the BUILD HOST's SELinux labels from the published archive. NCZ-OS is
  # a Debian image; SELinux labels (e.g. system_u:object_r:container_file_t:s0
  # :c1022,c1023 = podman per-container MCS categories from a Fedora Asahi
  # build host) belong to THIS machine's policy and are wrong inside a rootfs
  # that will never be evaluated by it. Shipping them also broke
  # verify_squashfs(): when the verifier's extraction target cannot hold
  # xattrs (e.g. an overlayfs upperdir without user_xattr), unsquashfs fails
  # with "write_xattr: failed to write xattr security.selinux ... extended
  # attributes are not supported by the destination filesystem" and exits 2,
  # and the gate condemns a perfectly good archive ("refusing to publish").
  # security.capability (file caps, e.g. on /bin/ping) is legitimate Debian
  # content and is preserved -- this is NOT a blanket -no-xattrs.
  log "BASE: mksquashfs -> $OUT/base.squashfs"
  # env -u SOURCE_DATE_EPOCH: see the desktop-layer call above (mksquashfs>=4.7).
  sudo env -u SOURCE_DATE_EPOCH mksquashfs "$WORK/base" "$OUT/base.squashfs" -comp zstd -Xcompression-level 15 -all-time 0 -fstime 0 -processors 1 -xattrs-exclude '^security\.selinux' -noappend -no-progress 2>&1 | tail -3
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
# silent archive corruption before publish. (ISO build guardrails:
# "desktop-hotfix.squashfs has no committed builder" was the original
# audit finding.)
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

# ----------------------------------------------------------------------------
# build_singularity_payload() — rebuild ncz-singularity-desktop from CURRENT
# upstream head, unconditionally, before anything downstream consumes it.
#
# Real gap this closes (2026-09-16, after a shipped arm64 ISO
# turned out to carry a singularity-desktop build 158 commits behind
# upstream and missing a full set of already-merged/queued fixes): this
# pipeline had a fully-working, reproducible build script for the payload
# (build-singularity.sh, already defaulting SRC_REF=master i.e. current
# head) and a working packager (build-singularity-deb.sh) -- but NOTHING
# ever called them. build_hotfix()'s own error message, right below,
# literally told a human to run both by hand and copy the .deb into
# assets/cix-debs/ "then retry" -- a manual step nobody was reliably
# doing every pipeline run, so whatever .deb happened to be sitting there
# from a past session just kept getting reused, silently, forever.
#
# Fix: build fresh, every single pipeline invocation that touches the
# desktop/hotfix layers -- no "if missing" check, no staleness heuristic.
# This is the same doctrine the rest of this pipeline already applies to
# the base rootfs and mkosi role deltas (rebuild from source every run,
# trust no cache) -- singularity-desktop was the one artifact still
# exempted from it, and that exemption is exactly what went stale.
#
# NOT arch-gated beyond what build-singularity.sh/build-singularity-deb.sh
# already handle themselves (native container platform + dpkg
# --print-architecture-derived ARCH) -- this runs identically on the
# arm64 and amd64 build hosts.
# PINNED SINCE 2026-10-06: "from source every run" still holds, but the
# source is the exact upstream commits in assets/singularity/upstream-pins.tsv
# (build-singularity.sh reads them through build/singularity-pins.sh), not the
# branch heads of the hour. Rebuilding from heads let an upstream push at
# 15:01Z on 2026-10-06 (libsingularity f3d0f49) break the r199 respin's stage
# 1 the same afternoon. Moving forward is a deliberate pin bump.
build_singularity_payload(){
  # Operator-tested payload: stage EXACTLY this deb instead of recompiling.
  # Both variables are required and the sha256 is verified, so a wrong or
  # swapped file cannot slip in. Without them the behaviour is unchanged
  # (rebuild from the pinned sources; the version string and tarball hash then
  # differ on every run even though the sources are identical).
  if [ -z "${NCZ_SINGULARITY_PREBUILT_DEB:-}" ] && [ -n "${NCZ_SINGULARITY_PREBUILT_SHA256:-}" ]; then
    # A sha256 alone used to be ignored and the payload silently recompiled,
    # i.e. an operator who pinned a hash got an unpinned build. Refuse instead.
    log "ERROR: NCZ_SINGULARITY_PREBUILT_SHA256 is set but NCZ_SINGULARITY_PREBUILT_DEB is not -- refusing to recompile an unpinned payload"
    exit 1
  fi
  if [ -n "${NCZ_SINGULARITY_PREBUILT_DEB:-}" ]; then
    local _pre="$NCZ_SINGULARITY_PREBUILT_DEB" _want="${NCZ_SINGULARITY_PREBUILT_SHA256:-}" _got
    [ -s "$_pre" ] || { log "ERROR: NCZ_SINGULARITY_PREBUILT_DEB=$_pre is missing/empty"; exit 1; }
    [ -n "$_want" ] || { log "ERROR: NCZ_SINGULARITY_PREBUILT_DEB needs NCZ_SINGULARITY_PREBUILT_SHA256"; exit 1; }
    _got="$(sha256sum "$_pre" | cut -d' ' -f1)"
    [ "$_got" = "$_want" ] || { log "ERROR: $_pre sha256 $_got != expected $_want"; exit 1; }
    case "$(basename "$_pre")" in
      ncz-singularity-desktop_*_"$NCZ_TARGET_ARCH".deb) ;;
      *) log "ERROR: $_pre is not an ncz-singularity-desktop deb for $NCZ_TARGET_ARCH"; exit 1 ;;
    esac
    mkdir -p "$ROOT/build/sinty-out"
    # build/sinty-out/singularity-opt.tgz is read by build-wallpaper-contrib-deb.sh
    # (Singularity wallpaper pack) and secret-scan-gate.sh. Leaving the one from an
    # EARLIER run would cut the pack from, and scan, a different payload than the
    # staged deb. The deb keeps opt/singularity byte-for-byte, so regenerate the
    # tarball from it; the .depends/.sources sidecars describe a build we did not
    # run here and cannot be regenerated, so drop them.
    local _x _tgz_tmp="$ROOT/build/sinty-out/.singularity-opt.tgz.prebuilt.$$"
    _x="$(mktemp -d "$ROOT/build/.sinty-prebuilt.XXXXXX")" || { log "ERROR: cannot create a scratch dir under $ROOT/build"; exit 1; }
    if ! dpkg-deb -x "$_pre" "$_x" || [ ! -d "$_x/opt/singularity" ] \
       || ! tar -czf "$_tgz_tmp" --sort=name --owner=0 --group=0 --numeric-owner -C "$_x" opt/singularity; then
      rm -rf "$_x"; rm -f "$_tgz_tmp"
      log "ERROR: $_pre has no usable opt/singularity tree (cannot regenerate singularity-opt.tgz)"; exit 1
    fi
    rm -rf "$_x"
    # Do NOT `rm -f "$ROOT/assets/cix-debs/"ncz-singularity-desktop_*.deb` and
    # then `install "$_pre"` from it: with --sources pinned, $_pre IS that
    # path, so the rm deleted the source-of-truth and the install failed,
    # leaving the hotfix layer (and the medium) with no payload. Prune only
    # SUPERSEDED versions; copy in only when the chosen deb lives elsewhere.
    local _keep; _keep="$(basename "$_pre")"
    find "$ROOT/assets/cix-debs" -maxdepth 1 \
        -name 'ncz-singularity-desktop_*.deb' ! -name "$_keep" -delete 2>/dev/null || true
    rm -f "$ROOT/build/sinty-out/"ncz-singularity-desktop_*.deb \
          "$ROOT/build/sinty-out/singularity-opt.tgz.depends" "$ROOT/build/sinty-out/singularity-opt.tgz.sources"
    mv -f "$_tgz_tmp" "$ROOT/build/sinty-out/singularity-opt.tgz"
    install -m 0644 "$_pre" "$ROOT/build/sinty-out/"
    [ -f "$ROOT/assets/cix-debs/$_keep" ] || install -m 0644 "$_pre" "$ROOT/assets/cix-debs/"
    log "SINGULARITY: staged the prebuilt $(basename "$_pre") (sha256 $_got) + regenerated singularity-opt.tgz from it; NOT rebuilding"
    return 0
  fi
  log "SINGULARITY: rebuilding ncz-singularity-desktop from the pinned upstream sources (assets/singularity/upstream-pins.tsv)"
  local _sinty_out="$ROOT/build/sinty-out"
  local _tgz="$_sinty_out/singularity-opt.tgz"
  rm -f "$_tgz"
  OUT="$_sinty_out" SINGULARITY_IMAGE="debian:${NCZ_BASE_CODENAME}" \
    bash "$ROOT/build/build-singularity.sh" || {
      log "ERROR: build-singularity.sh failed -- refusing to fall back to a stale .deb"
      exit 1
    }
  [ -s "$_tgz" ] || {
    log "ERROR: build-singularity.sh reported success but $_tgz is missing/empty"
    exit 1
  }
  local _deb
  _deb="$(NCZ_SINGULARITY_ARCH="$NCZ_TARGET_ARCH" OUT="$_sinty_out" \
    bash "$ROOT/build/build-singularity-deb.sh" "$_tgz" | tee /dev/stderr | \
    sed -n 's/^Final \.deb: //p')"
  [ -n "$_deb" ] && [ -s "$_deb" ] || {
    log "ERROR: build-singularity-deb.sh did not produce a usable .deb"
    exit 1
  }
  # Remove EVERY existing ncz-singularity-desktop .deb in assets/cix-debs/
  # first -- not just the one build_hotfix()'s -V sort would have picked.
  # A stale SECOND .deb left behind (a different version string, an older
  # arch build) is exactly the kind of thing that silently wins a future
  # sort-by-version comparison if this fresh one is ever missing for any
  # reason; the directory should hold exactly one, always the one just
  # built.
  rm -f "$ROOT/assets/cix-debs/"ncz-singularity-desktop_*.deb
  install -m 0644 "$_deb" "$ROOT/assets/cix-debs/"
  log "SINGULARITY: staged $(basename "$_deb") -> assets/cix-debs/ (fresh, from the pinned sources)"
}

# strip_build_host_state <root> <label> -- a layer must not describe the machine
# that built it. Package scripts run inside the build chroot record the BUILD
# HOST: mmdebstrap copies its /etc/hostname, lvm2's vgcfgbackup writes its volume
# groups to /etc/lvm/backup, nvme-cli generates one NVMe host NQN/ID that every
# install would share, and dpkg/apt/openssh logs carry its paths and host name
# (ssh-keygen prints root@<host>). Measured in the d395bb2d images: the amd64 base
# layer shipped /etc/hostname = the build host and term.log fingerprints naming
# it. The target writes its own hostname, logs and ids at install/first boot.
#
# Full list (each item is removed or reset here and verified below):
#   etc/hostname          base: localhost; any other layer: localhost if present
#   etc/hosts             reset to the Debian default if it names another host
#   etc/resolv.conf       mount_chroot copies the builder's resolver config into
#                         the chroot for apt; a regular file is truncated (the
#                         installer writes the target's own: preseed/extract-
#                         rootfs.sh, preseed/late.sh). A symlink is left as is.
#   etc/machine-id        truncated (empty = first boot generates it)
#   var/lib/dbus/machine-id   removed when it is a regular file
#   etc/mtab              a regular file becomes the ../proc/self/mounts link
#   var/lib/systemd/random-seed, var/lib/systemd/credential.secret   removed
#   etc/ssh/ssh_host_*    removed (generated per device at first boot)
#   var/lib/dhcp, var/lib/dhclient, NetworkManager *.lease   leases removed
#   var/cache/apt/*.bin, var/cache/apt/archives/*.deb, var/lib/apt/lists/*   removed
#   var/log/*.log*, var/log/journal/*   removed
#   root/                 only Debian's .bashrc, .profile and an empty .ssh stay;
#                         .config, .local, .cache ... written by programs the
#                         build ran as root are removed
#   home/*                removed (no account exists in a layer)
#   var/opt/vivaldi/media-codecs-*   removed (fetched by Vivaldi's update-ffmpeg,
#                         part of no package; 52-vivaldi.sh blocks the fetch)
#   tmp/*, var/tmp/*      removed
#   etc/lvm/backup, etc/lvm/archive, etc/nvme/hostnqn|hostid   removed
#   file owners           the build tree is copied with cp -a, so files carry
#                         the build user's uid/gid (1000): every owner or group
#                         outside the system range (>= 1000, except nobody/
#                         nogroup 65534) becomes root, and the project tree
#                         loses the group/other write bits of the build umask.
# etc/ld.so.cache is kept: ldconfig derives it from the layer's own libraries.
NCZ_HOSTS_DEFAULT='127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
'
# names a layer's etc/hosts may carry (anything else names a host)
NCZ_HOSTS_NAMES_RE='^(localhost|localhost\.localdomain|ip6-localhost|ip6-loopback|ip6-allnodes|ip6-allrouters|ip6-localnet|ip6-mcastprefix)$'
ncz_hosts_foreign_names(){  # file -> prints names that are not local ones
  [ -f "$1" ] || return 0
  sudo awk '!/^[[:space:]]*#/ && NF>1 { for (i=2; i<=NF; i++) { if ($i ~ /^#/) break; print $i } }' "$1" 2>/dev/null \
    | grep -v -E "$NCZ_HOSTS_NAMES_RE" || true
}
strip_build_host_state(){
  local r="$1" label="$2" left
  [ -d "$r" ] || return 0
  sudo find "$r/var/log" -type f \( -name '*.log' -o -name '*.log.xz' -o -name '*.log.[0-9]*' \) -delete 2>/dev/null || true
  sudo find "$r/var/log/journal" -mindepth 1 -delete 2>/dev/null || true
  sudo rm -f "$r/tmp/ncz-apt-update.log" "$r/etc/nvme/hostnqn" "$r/etc/nvme/hostid" 2>/dev/null || true
  sudo find "$r/etc/lvm/backup" "$r/etc/lvm/archive" -mindepth 1 -delete 2>/dev/null || true
  if [ "$label" = base ] || [ -f "$r/etc/hostname" ]; then
    printf 'localhost\n' | sudo tee "$r/etc/hostname" >/dev/null
  fi
  if [ -n "$(ncz_hosts_foreign_names "$r/etc/hosts")" ]; then
    printf '%s' "$NCZ_HOSTS_DEFAULT" | sudo tee "$r/etc/hosts" >/dev/null
  fi
  if [ -f "$r/etc/resolv.conf" ] && [ ! -L "$r/etc/resolv.conf" ]; then
    sudo truncate -s 0 "$r/etc/resolv.conf"
  fi
  if [ -f "$r/etc/machine-id" ] && [ ! -L "$r/etc/machine-id" ]; then
    sudo truncate -s 0 "$r/etc/machine-id"
  fi
  if [ -f "$r/var/lib/dbus/machine-id" ] && [ ! -L "$r/var/lib/dbus/machine-id" ]; then
    sudo rm -f "$r/var/lib/dbus/machine-id"
  fi
  if [ -f "$r/etc/mtab" ] && [ ! -L "$r/etc/mtab" ]; then
    sudo rm -f "$r/etc/mtab"; sudo ln -s ../proc/self/mounts "$r/etc/mtab"
  fi
  sudo rm -f "$r/var/lib/systemd/random-seed" "$r/var/lib/systemd/credential.secret" 2>/dev/null || true
  sudo find "$r/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -delete 2>/dev/null || true
  sudo find "$r/var/lib/dhcp" "$r/var/lib/dhclient" "$r/var/lib/NetworkManager" -maxdepth 1 -type f \
    \( -name '*.lease' -o -name '*.leases' \) -delete 2>/dev/null || true
  sudo find "$r/var/cache/apt" -maxdepth 1 -type f -name '*.bin' -delete 2>/dev/null || true
  sudo find "$r/var/cache/apt/archives" -type f -name '*.deb' -delete 2>/dev/null || true
  sudo find "$r/var/lib/apt/lists" -maxdepth 1 -type f ! -name lock ! -name '.*' -delete 2>/dev/null || true
  sudo find "$r/var/lib/apt/lists/partial" -mindepth 1 -delete 2>/dev/null || true
  if [ -d "$r/root" ]; then
    sudo find "$r/root" -mindepth 1 -maxdepth 1 ! -name .bashrc ! -name .profile ! -name .ssh -exec rm -rf {} + 2>/dev/null || true
    sudo find "$r/root/.ssh" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true
  fi
  sudo find "$r/home" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  sudo rm -rf "$r"/var/opt/vivaldi/media-codecs-* 2>/dev/null || true
  sudo find "$r/tmp" "$r/var/tmp" -mindepth 1 -maxdepth 1 \
    ! -name .X11-unix ! -name .ICE-unix ! -name .XIM-unix ! -name .font-unix -exec rm -rf {} + 2>/dev/null || true
  # owners: build uid/gid -> root; project tree: no group/other write
  sudo find "$r" -xdev \( \( -uid +999 ! -uid 65534 \) -o \( -gid +999 ! -gid 65534 \) \) -exec chown -h 0:0 {} + 2>/dev/null || true
  if [ -d "$r/usr/local/lib/cix-installer" ]; then
    sudo find "$r/usr/local/lib/cix-installer" ! -type l -perm /022 -exec chmod go-w {} + 2>/dev/null || true
  fi

  left="$(sudo find "$r/var/log" -type f \( -name '*.log' -o -name '*.log.xz' \) 2>/dev/null; \
          sudo find "$r/var/log/journal" -mindepth 1 -type f 2>/dev/null; \
          sudo find "$r/etc/lvm/backup" "$r/etc/lvm/archive" -mindepth 1 2>/dev/null; \
          sudo find "$r/etc/nvme" -maxdepth 1 \( -name hostnqn -o -name hostid \) 2>/dev/null; \
          sudo find "$r/etc/ssh" -maxdepth 1 -name 'ssh_host_*' 2>/dev/null; \
          sudo find "$r/var/lib/systemd" -maxdepth 1 \( -name random-seed -o -name credential.secret \) 2>/dev/null; \
          sudo find "$r/var/lib/dhcp" "$r/var/lib/dhclient" "$r/var/lib/NetworkManager" -maxdepth 1 -type f \( -name '*.lease' -o -name '*.leases' \) 2>/dev/null; \
          sudo find "$r/var/cache/apt/archives" -type f -name '*.deb' 2>/dev/null; \
          sudo find "$r/var/lib/apt/lists" -maxdepth 1 -type f ! -name lock ! -name '.*' 2>/dev/null; \
          sudo find "$r/root" -mindepth 1 -maxdepth 1 ! -name .bashrc ! -name .profile ! -name .ssh 2>/dev/null; \
          sudo find "$r/root/.ssh" "$r/home" -mindepth 1 2>/dev/null; \
          sudo find "$r/var/opt/vivaldi" -maxdepth 1 -name 'media-codecs-*' 2>/dev/null; \
          sudo find "$r" -xdev \( \( -uid +999 ! -uid 65534 \) -o \( -gid +999 ! -gid 65534 \) \) -print 2>/dev/null | head -5)"
  if [ "$label" = base ] && [ "$(sudo cat "$r/etc/hostname" 2>/dev/null)" != localhost ]; then
    left="$left /etc/hostname"
  fi
  [ -n "$(ncz_hosts_foreign_names "$r/etc/hosts")" ] && left="$left /etc/hosts"
  if [ ! -L "$r/etc/resolv.conf" ] && sudo grep >/dev/null -sE '^[[:space:]]*(nameserver|search|domain)[[:space:]]' "$r/etc/resolv.conf"; then
    left="$left /etc/resolv.conf"
  fi
  if [ ! -L "$r/etc/machine-id" ] && [ -s "$r/etc/machine-id" ]; then left="$left /etc/machine-id"; fi
  if [ -f "$r/etc/mtab" ] && [ ! -L "$r/etc/mtab" ]; then left="$left /etc/mtab"; fi
  if [ -n "$(printf '%s' "$left" | tr -d '[:space:]')" ]; then
    log "ERROR: $label layer would carry build-host state: $(printf '%s' "$left" | tr '\n' ' ')"
    return 1
  fi
  log "$label: no build-host state (hostname, hosts, resolv.conf, machine-id, mtab, random seed, ssh host keys, leases, apt caches, logs, journal, root and home contents, downloaded codecs, tmp, LVM backup, NVMe ids, build-user owners)"
}

ensure_wallpaper_packs(){
  local pack
  mkdir -p "$ROOT/assets/wallpaper-debs"
  for pack in ncz cygnus-2610 singularity brandon-perlow alex-jay-brady; do
    if ls "$ROOT/assets/wallpaper-debs/ncz-wallpapers-${pack}_"*.deb >/dev/null 2>&1; then
      continue
    fi
    log "wallpaper-debs: $pack not staged -- building"
    bash "$ROOT/build/build-wallpaper-contrib-deb.sh" "$pack" >/dev/null || {
      log "ERROR: required shipping wallpaper pack $pack failed to build"
      return 1
    }
    cp "$ROOT/build/wallpaper-debs/"*.deb "$ROOT/assets/wallpaper-debs/" 2>/dev/null || true
  done
  log "wallpaper-debs: staged $(ls "$ROOT/assets/wallpaper-debs/"*.deb | wc -l) pack(s)"
}

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
  # permissioned, and the gate in build/iso/stage-ncz-payload.py's
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
  # Drop the BUILD HOST's SELinux labels from the published archive. NCZ-OS is
  # a Debian image; SELinux labels (e.g. system_u:object_r:container_file_t:s0
  # :c1022,c1023 = podman per-container MCS categories from a Fedora Asahi
  # build host) belong to THIS machine's policy and are wrong inside a rootfs
  # that will never be evaluated by it. Shipping them also broke
  # verify_squashfs(): when the verifier's extraction target cannot hold
  # xattrs (e.g. an overlayfs upperdir without user_xattr), unsquashfs fails
  # with "write_xattr: failed to write xattr security.selinux ... extended
  # attributes are not supported by the destination filesystem" and exits 2,
  # and the gate condemns a perfectly good archive ("refusing to publish").
  # security.capability (file caps, e.g. on /bin/ping) is legitimate Debian
  # content and is preserved -- this is NOT a blanket -no-xattrs.
  log "HOTFIX: mksquashfs $WORK/hotfix -> $OUT/desktop-hotfix.squashfs"
  # env -u SOURCE_DATE_EPOCH: see the desktop-layer call above (mksquashfs>=4.7).
  sudo env -u SOURCE_DATE_EPOCH mksquashfs "$WORK/hotfix" "$OUT/desktop-hotfix.squashfs" -comp zstd -Xcompression-level 15 -all-time 0 -fstime 0 -processors 1 -xattrs-exclude '^security\.selinux' -noappend -no-progress 2>&1 | tail -2
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

# ---------------------------------------------------------------------------
# Plan-aware wrappers used by `all` (build-image.sh always drives `all`).
# Standalone `base`/`desktop`/`hotfix` keep their historical unconditional
# behaviour so existing callers and docs are unchanged.
# ---------------------------------------------------------------------------
rotate_stale_base() {
  local ts; ts="$(date -u +%Y%m%d-%H%M%S)"
  sudo mv -f "$OUT/base.squashfs" "$OUT/base.squashfs.stale-${ts}" 2>/dev/null \
    || mv -f "$OUT/base.squashfs" "$OUT/base.squashfs.stale-${ts}" 2>/dev/null \
    || { log "ERROR: could not rotate $OUT/base.squashfs aside -- refusing to clobber it" >&2; exit 1; }
  log "  kept for inspection: $OUT/base.squashfs.stale-${ts}"
}

# Per-layer post-check hook (DESIGN RULE 2026-10-10).  Called right after a
# layer squashfs is finalized, BEFORE the next layer is built on top of it, so a
# bad layer never gets consumed.  No-op unless the caller (build-image.sh)
# exports NCZ_LAYERS_CHECK=1; the authoritative run happens again at the stage
# level with the manifest + chain.  Never falls back silently.
ncz_layer_postcheck() {  # <layer>  (base|desktop|hotfix)
  local l="$1" sq; sq="$(ncz_layer_artifact "$l")"
  [ "${NCZ_LAYERS_CHECK:-0}" = 1 ] || return 0
  [ -s "$sq" ] || { log "POSTCHECK: $sq missing"; return 1; }
  local -a a=(--arch "$NCZ_TARGET_ARCH" --stage layers-postcheck --layer "$l" --append)
  [ -n "${NCZ_LAYERS_CHECK_RUN_DIR:-}" ] && a+=(--run-dir "$NCZ_LAYERS_CHECK_RUN_DIR")
  [ -n "${NCZ_LAYERS_CHECK_PAYLOAD:-}" ] && a+=(--payload-deb "$NCZ_LAYERS_CHECK_PAYLOAD")
  [ -n "${NCZ_LAYERS_CHECK_CHAIN:-}" ] && a+=(--chain "$NCZ_LAYERS_CHECK_CHAIN")
  # overlay deltas: the layers under them (nearest first)
  case "$l" in
    desktop) a+=(--lower "$(ncz_layer_artifact base)") ;;
    hotfix)  a+=(--lower "$(ncz_layer_artifact desktop)" --lower "$(ncz_layer_artifact base)") ;;
  esac
  log "POSTCHECK: build/check-layers.sh $l"
  if bash "$ROOT/build/check-layers.sh" "$sq" "${a[@]}"; then
    return 0
  fi
  log "POSTCHECK: FAILED for $l -- refusing to consume this layer"
  return 1
}

run_base_layer() {
  # `all` used to ask only "does base.squashfs exist", then "does it carry the
  # staged kernel".  It never noticed a change to assets/... or, before the
  # r202 fix, to wallpaper/post-install.  The stamp now fingerprints every base
  # input (build/lib/layerplan.py); NCZ_LAYER_PLAN=base=rebuild forces a fresh
  # build when the caller already knows the inputs changed.
  local d; d="$(ncz_layer_decision base)"
  if [ "$d" = rebuild ]; then
    [ -s "$OUT/base.squashfs" ] && { log "BASE: forced rebuild (plan)"; rotate_stale_base; }
    build_base || return 1
    ncz_layer_stamp_write base
    ncz_layer_postcheck base || return 1
    return 0
  fi
  if [ -s "$OUT/base.squashfs" ]; then
    local _want_stamp _have_stamp _kernel_ok=1
    _want_stamp="$(base_assets_stamp)"; _have_stamp="$(base_stamp_in_layer "$OUT/base.squashfs")"
    if [ "$_want_stamp" != "$_have_stamp" ]; then
      log "BASE: asset inputs changed since base.squashfs was built (layer stamp '${_have_stamp:-none}' vs current '$_want_stamp'); rebuilding"
      _kernel_ok=0
    elif NCZ_TARGET_ARCH="$NCZ_TARGET_ARCH" bash "$ROOT/build/verify-base-kernel-assets.sh" \
         --layer "$OUT/base.squashfs" --label base.squashfs; then
      _kernel_ok=1
    else
      _kernel_ok=0
    fi
    if [ "$_kernel_ok" = 1 ]; then
      log "BASE: reusing existing $OUT/base.squashfs ($(du -h "$OUT/base.squashfs" | cut -f1))"
      ncz_layer_stamp_write base
      ncz_layer_postcheck base || return 1
      return 0
    fi
    log "BASE: STALE (asset stamp or staged kernel assets); rotating aside and rebuilding"
    rotate_stale_base
  fi
  build_base || return 1
  ncz_layer_stamp_write base
  ncz_layer_postcheck base || return 1
}

run_desktop_layer() {
  local d; d="$(ncz_layer_decision desktop)"
  # No plan (standalone caller): historical behaviour is to rebuild.
  if [ -z "${NCZ_LAYER_PLAN:-}" ]; then
    build_singularity_payload; ensure_wallpaper_packs; build_layer desktop "$DESKTOP_MANIFEST"
    return $?
  fi
  if [ "$d" = reuse ] && ncz_layer_reuse_ok desktop; then
    log "DESKTOP: reusing existing $OUT/desktop.squashfs (fingerprint unchanged)"
    ncz_layer_postcheck desktop || return 1
    return 0
  fi
  if [ "$d" = auto ] && ncz_layer_reuse_ok desktop; then
    log "DESKTOP: reusing existing $OUT/desktop.squashfs (fingerprint unchanged)"
    ncz_layer_postcheck desktop || return 1
    return 0
  fi
  build_singularity_payload || return 1
  ensure_wallpaper_packs
  build_layer desktop "$DESKTOP_MANIFEST" || return 1
  ncz_layer_stamp_write desktop
  ncz_layer_postcheck desktop || return 1
}

run_hotfix_layer() {
  local d; d="$(ncz_layer_decision hotfix)"
  if [ -z "${NCZ_LAYER_PLAN:-}" ]; then
    build_singularity_payload; build_hotfix
    return $?
  fi
  if { [ "$d" = reuse ] || [ "$d" = auto ]; } && ncz_layer_reuse_ok hotfix; then
    log "HOTFIX: reusing existing $OUT/desktop-hotfix.squashfs (fingerprint unchanged)"
    ncz_layer_postcheck hotfix || return 1
    return 0
  fi
  build_hotfix || return 1
  ncz_layer_stamp_write hotfix
  ncz_layer_postcheck hotfix || return 1
}

case "$STAGE" in
  base)    build_base ;;
  desktop) build_singularity_payload; ensure_wallpaper_packs; build_layer desktop "$DESKTOP_MANIFEST" ;;
  hotfix)  build_singularity_payload; build_hotfix ;;
  server)  echo "ERROR: the server layer is gone; NCZ-OS ships ONE build." >&2
           echo "       Boot the console entry (multi-user.target) instead." >&2
           exit 1 ;;
  all)     run_base_layer || exit 1
           run_desktop_layer || exit 1
           run_hotfix_layer || exit 1 ;;
  *) echo "usage: $0 base|desktop|hotfix|server|all"; exit 2 ;;
esac
