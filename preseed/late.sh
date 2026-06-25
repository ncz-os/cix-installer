#!/bin/sh
# late.sh — run from preseed late_command in the d-i runtime context.
#
# d-i's late_command runs after base install + apt config + bootloader
# but before reboot. /target is mounted; /cdrom *should* be the install
# media, but eject behavior + multi-source detection (cdrom vs hd-media
# vs cd-from-iso) makes hard-coded paths fragile. This script:
#
#   1. logs everything to /target/var/log/cix-installer-late.log
#   2. probes ALL plausible locations for the bundled /cixmini dir
#   3. copies it into /target/usr/local/lib/cix-installer
#   4. invokes /usr/local/lib/cix-installer/post-install/run-all.sh
#      via in-target chroot
#   5. emits a clear, debuggable error if any step fails — including
#      mountpoint state, dir contents, and exit codes
#
# This script lives at /cdrom/cixmini/late.sh in the ISO; preseed's
# late_command invokes it via `sh /cdrom/cixmini/late.sh` (with
# multi-path fallback to find the script itself if /cdrom moved).

set -e

LOG=/target/var/log/cix-installer-late.log
mkdir -p /target/var/log
exec >"$LOG" 2>&1

# r130.3 progress UX: preseed/late_command is a single opaque step to d-i, so
# the main "Finishing the installation" bar parks (testers reported a "stuck at
# 14%" hang) for the entire multi-minute OFFLINE base + desktop + driver install
# while this script runs silently into its log. r130.7 (below, near run-all)
# drives the REAL main-screen bar with a "be patient / not frozen" title that
# advances per hook; this tty3 mirror remains as the live per-step detail view
# (Alt+F3) and as the fallback if the debconf channel is unavailable. Best-
# effort; never fatal.
TTY=/dev/tty3
LATE_T0=$(date +%s 2>/dev/null || echo 0)
ttymsg() {
    _el=$(( $(date +%s 2>/dev/null || echo 0) - LATE_T0 ))
    printf '[ncz %s +%ss] %s\n' "$(date -u +%H:%M:%S)" "$_el" "$*" >"$TTY" 2>/dev/null || true
}
ttymsg "nclawzero installer: applying base OS + desktop + drivers (offline)."
ttymsg "This phase takes several minutes. The main screen shows a 'please be"
ttymsg "patient' bar that advances per step; watch THIS console (Alt+F3) for detail."

echo "=== late.sh ($(date -u)) ==="
echo

# r116: serialize concurrent late_command invocations. When the operator
# retries a failed finish-install step, d-i re-runs late_command. A second
# late.sh that starts while the first is still inside `in-target
# run-all.sh` previously caused a FATAL race: the new pass's
# `rm -rf /target/usr/local/lib/cix-installer` (below) deleted the
# post-install directory out from under the first pass's still-running
# run-all.sh — which had cd'd into post-install/ — so the remaining hooks
# aborted with "getcwd: cannot access parent directories" /
# "./NN-hook.sh: No such file or directory" and never applied (this is how
# 22-display-fix.sh's cix-detect-display.service silently failed to install,
# leaving the installed system with no Xorg KMS pin → no GUI on first boot).
# A blocking flock makes a retry WAIT for the in-flight pass to finish, then
# run cleanly against a quiescent tree.
if command -v flock >/dev/null 2>&1; then
    { exec 9>/var/lock/cix-late.lock; } 2>/dev/null || exec 9>/tmp/cix-late.lock
    echo "--- acquiring late.sh lock (serialize concurrent late_command retries) ---"
    flock 9 || echo "WARN: flock failed; proceeding without serialization"
fi

echo "--- runtime context ---"
echo "PWD: $(pwd)"
echo "USER: $(id)"
echo "PATH: $PATH"
echo
echo "--- mounts ---"
mount | grep -E "cdrom|hd-media|media|target" || true
echo
echo "--- candidate source dirs ---"
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    if [ -d "$d" ]; then
        echo "FOUND: $d"
        ls -la "$d" | head -10
    else
        echo "MISSING: $d"
    fi
done
echo

# Pick the first source that exists
SRC=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    [ -d "$d" ] && SRC="$d" && break
done

if [ -z "$SRC" ]; then
    echo "FATAL: no /cixmini source found in any expected location."
    echo "Mounts:"
    mount
    echo
    echo "Failing late.sh — preseed late_command will report exit 1."
    exit 1
fi

echo "--- selected source: $SRC ---"
du -sh "$SRC" 2>/dev/null || true
echo
echo "--- pre-copy diagnostics: $SRC/post-install/ ---"
ls -la "$SRC/post-install/" 2>&1 | head -15
echo "--- pre-copy md5 of 10-our-kernel.sh on $SRC ---"
md5sum "$SRC/post-install/10-our-kernel.sh" 2>&1 || echo "md5sum unavailable"
wc -c "$SRC/post-install/10-our-kernel.sh" 2>&1 || true
echo

echo "--- copying $SRC → /target/usr/local/lib/cix-installer ---"
mkdir -p /target/usr/local/lib
# 2026-05-04 codex review: rm -rf + cp -a so reruns don't nest cixmini/
# inside existing /target/usr/local/lib/cix-installer/.
rm -rf /target/usr/local/lib/cix-installer
cp -a "$SRC" /target/usr/local/lib/cix-installer
chmod 755 /target/usr/local/lib/cix-installer/post-install/*.sh
echo "    copy ok"
echo

# Stamp the install with the build serial + dual-kernel KVERs so
# 10-our-kernel.sh + 70-bootloader.sh can read them. Files land at
# both /etc/cix-installer/ (easy `cat` from running system) and
# /usr/local/lib/cix-installer/ (where post-install scripts read).
mkdir -p /target/etc/cix-installer
for f in BUILD_VERSION BUILD_DATE BUILD_HOST KVER_LTS KVER_NEXT; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" /target/etc/cix-installer/"$f"
        cp "$SRC/$f" /target/usr/local/lib/cix-installer/"$f"
    fi
done

# r77: capture install-time variant choice from kernel cmdline.
# When the unified ISO offers a GRUB chooser between Desktop (Reinhardt)
# and Server (Magnetar), the operator's pick lands as ncz_variant=
# desktop|server on the kernel cmdline. 48-magnetar-variant.sh reads
# the BUILD_VARIANT sidecar at first boot and applies the headless
# toggle when value is "server".
#
# Default: if the cmdline didn't carry ncz_variant (because this isn't
# a unified-chooser ISO, or the operator boot directly to a non-chooser
# entry), fall back to the build's bake-time --variant. The
# BUILD_VARIANT sidecar may already be set on $SRC by build-iso-di.sh
# at bake time; only overwrite it when the kernel cmdline explicitly
# selected one.
ncz_variant=$(sed -n 's/.*\(^\| \)ncz_variant=\([a-z]*\).*/\2/p' /proc/cmdline 2>/dev/null || echo "")
case "$ncz_variant" in
    desktop|server)
        echo "$ncz_variant" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
        echo "    ncz_variant=$ncz_variant captured from kernel cmdline"
        ;;
    *)
        if [ -f "$SRC/BUILD_VARIANT" ]; then
            echo "    ncz_variant from bake-time BUILD_VARIANT: $(cat $SRC/BUILD_VARIANT)"
        else
            echo "desktop" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
            echo "    ncz_variant defaulted to 'desktop' (no cmdline, no bake stamp)"
        fi
        ;;
esac
if [ -f /target/etc/cix-installer/BUILD_VERSION ]; then
    echo "    build stamp: $(cat /target/etc/cix-installer/BUILD_VERSION) ($(cat /target/etc/cix-installer/BUILD_DATE 2>/dev/null))"
fi
if [ -f /target/etc/cix-installer/KVER_LTS ]; then
    echo "    KVER_LTS:  $(cat /target/etc/cix-installer/KVER_LTS)"
fi
if [ -f /target/etc/cix-installer/KVER_NEXT ] && [ -s /target/etc/cix-installer/KVER_NEXT ]; then
    echo "    KVER_NEXT: $(cat /target/etc/cix-installer/KVER_NEXT) [BETA]"
fi
echo

echo "--- post-copy md5 of /target/.../10-our-kernel.sh ---"
md5sum /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || echo "md5sum unavailable"
wc -c /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || true
echo

# Codex A2 CRITICAL #2 fix: Mount /cdrom inside /target so post-install
# hooks can `apt-get install` from our offline mirror via file:///cdrom.
# Without this, FULL/THIN mode 10-our-kernel.sh + 70-bootloader.sh +
# 20-desktop.sh fail because they need offline pkgs.
#
# 2026-05-07 take8 (per Codex R78-INVALID-RELEASE-AUDIT): minimal
# NETINSTALL ships an EMPTY main/binary-arm64/Packages and removes
# /cdrom/.disk/base_installable so base-installer uses the HTTP mirror.
# 2026-05-08 netinstall-bootstrap keeps base_installable absent but adds a
# small non-empty regular Packages index for pkgsel/include. In that mode,
# file:///cdrom is valid for pkgsel/post-install package fallback.
CDROM_REGULAR_INDEX=/cdrom/dists/resolute/main/binary-arm64/Packages
if [ -e /cdrom/.disk/base_installable ] || [ -s "$CDROM_REGULAR_INDEX" ]; then
    echo "--- mounting cdrom into /target for offline apt-get during post-install ---"
    mkdir -p /target/cdrom
    if grep -qs ' /target/cdrom ' /proc/mounts; then
        echo "    /target/cdrom already mounted"
    else
        mount --bind /cdrom /target/cdrom 2>&1 || \
            { echo "WARN: bind-mount /cdrom into /target failed; post-install apt-get may fail"; }
    fi

    echo "deb [trusted=yes] file:///cdrom/cixmini/apt-repo /" > /target/etc/apt/sources.list.d/cixmini-offline.list

    # Add file:///cdrom apt source to /target's sources.list so apt-get
    # install in chroot can find packages locally. [trusted=yes] bypasses
    # GPG (we don't sign our offline mirror Release file yet).
    cat > /target/etc/apt/sources.list.d/cixmini-cdrom.list <<'CDROM_LIST'
deb [trusted=yes] file:///cdrom resolute main
CDROM_LIST
    mkdir -p /target/etc/apt/preferences.d
    cat > /target/etc/apt/preferences.d/00cixmini-bootstrap-pool.pref <<'CDROM_PREF'
Package: *
Pin: release o=nclawzero
Pin-Priority: 1001
CDROM_PREF
    echo "    /target/etc/apt/sources.list.d/cixmini-cdrom.list installed"
    if [ ! -e /cdrom/.disk/base_installable ] && [ -s "$CDROM_REGULAR_INDEX" ]; then
        chroot /target /usr/bin/apt-get \
            -o Dir::Etc::sourcelist="sources.list.d/cixmini-cdrom.list" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" \
            update 2>&1 | tail -3 || \
            { echo "WARN: local apt-get update from bootstrap pool failed"; }
    else
        in-target apt-get update 2>&1 | tail -3 || { echo "WARN: in-target apt-get update from cdrom failed"; }
        # r116: install ONLY linux-firmware here. The NPU userspace packages
        # cix-noe-umd / cix-ai-engine MUST NOT be apt-installed in late.sh.
        # Their postinsts pip-install libnoe / noe-engine, which refuse to run
        # on resolute's Python 3.14 (they require <3.14,>=3.10) → postinst
        # exits 1 → dpkg leaves them HALF-CONFIGURED. That wedged dpkg state —
        # and, across red-dialog "Continue" retries, a still-running pip
        # postinst that keeps holding /var/lib/dpkg/lock-frontend — then makes
        # the REQUIRED 70-bootloader.sh `apt-get install systemd-boot` fail
        # with exit 100. run-all.sh propagates that, late_command returns
        # non-zero, and d-i shows the red "installation step failed" dialog
        # with NO bootloader installed. 25-cix-proprietary.sh already lands the
        # NPU userspace correctly (dpkg-deb -x files only, no postinst) and
        # purges any half-configured cix-* packages, so installing them here is
        # both redundant and actively harmful.
        chroot /target /usr/bin/apt-get install -y --allow-unauthenticated linux-firmware || { echo "WARN: linux-firmware install failed"; true; }
    fi
    CDROM_BIND_MOUNTED=1
else
    echo "--- netinstall mode: cdrom has no regular deb component, skipping cdrom apt source ---"
    echo "    (post-install hooks rely on ports.ubuntu.com via apt-setup)"
    CDROM_BIND_MOUNTED=0
fi

# 2026-05-07 take9 (per .66 take8 pkgsel cascade fail): pre-write apt
# retries config so post-install hooks 10-our-kernel.sh / 20-desktop.sh
# / etc retry transient DNS/network blips when fetching packages from
# ports.ubuntu.com. pkgsel itself runs BEFORE late.sh so this doesn't
# help that step — pkgsel/install-recommends=false in preseed handles
# pkgsel resilience by minimizing the dep cascade. This config covers
# everything our hooks do after.
mkdir -p /target/etc/apt/apt.conf.d/
cat > /target/etc/apt/apt.conf.d/99retries <<'APTRETRIES'
# nclawzero — apt resilience for transient DNS/network failures.
# Auto-injected by preseed/late.sh.
Acquire::Retries "5";
Acquire::http::Timeout "60";
Acquire::http::Pipeline-Depth "0";
APTRETRIES
echo "--- /target/etc/apt/apt.conf.d/99retries installed ---"

# 2026-05-07 take10: replace /target/etc/resolv.conf with a STATIC file
# containing multiple nameservers. d-i + Ubuntu chains symlink it to
# /run/systemd/resolve/stub-resolv.conf, but systemd-resolved isn't
# running inside the chroot — and the host stub points at only the
# DHCP-provided nameserver (one IP, often the LAN router). On flaky
# LAN DNS this single source dropped queries on .66 take8.
#
# A real file with public resolvers (Google + Cloudflare) survives any one
# being slow, and is network-neutral (no site-specific gateway baked in). Once
# the system boots and systemd-resolved starts, /etc/resolv.conf gets
# re-symlinked to the stub during normal boot, so this is install-time only.
echo "--- writing static /target/etc/resolv.conf with fallback nameservers ---"
rm -f /target/etc/resolv.conf
cat > /target/etc/resolv.conf <<'RESOLVCONF'
# nclawzero install-time DNS — replaced by systemd-resolved on boot.
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3
RESOLVCONF
echo "    /target/etc/resolv.conf:"
cat /target/etc/resolv.conf | sed 's/^/      /'

# ----------------------------------------------------------------------
# r130.7 (operator: "the 14% bar looks frozen — tell the user to be patient").
# Drive the REAL d-i main-screen progress bar during the long offline
# post-install. finish-install.d/07preseed runs our late_command via
# preseed_command's bare `eval` (NO log-output wrapper), so we inherit
# finish-install's live debconf protocol fds (fd3=command, fd0=reply) — the
# `exec >LOG` near the top only moved fd1/fd2, leaving the protocol intact.
# We therefore source confmodule and push a NESTED progress bar whose title is
# an explicit "be patient / not frozen" message, then advance it as each hook
# completes (reusing the tty3 heartbeat's current-hook detection below).
# 100% best-effort: any failure leaves DEBCONF_OK=0 and we fall back to the
# tty3-only heartbeat (prior behavior). Guarded so it can NEVER abort the
# install under `set -e`. We require DEBIAN_HAS_FRONTEND + DEBCONF_REDIR to be
# already set (true inside finish-install) so sourcing confmodule cannot
# re-exec late.sh from scratch.
# ----------------------------------------------------------------------
DEBCONF_OK=0
db_try() { [ "$DEBCONF_OK" = 1 ] || return 0; "$@" 2>/dev/null || true; }
if [ -n "$DEBIAN_HAS_FRONTEND" ] && [ -n "$DEBCONF_REDIR" ] \
   && [ -f /usr/share/debconf/confmodule ] && [ -x /usr/bin/debconf-loadtemplate ]; then
    cat > /tmp/ncz-progress.templates <<'NCZTPL'
Template: nclawzero/install-progress
Type: text
Description: Installing nclawzero — please be patient (several minutes)
 The full desktop, GPU/NPU drivers, kernels and agents are being installed from
 the local media. This bar may sit near 14% for a while — that is NORMAL and the
 system is NOT frozen. Press Alt+F3 at any time for live, per-step detail.

Template: nclawzero/install-step
Type: text
Description: ${STEP}
NCZTPL
    if . /usr/share/debconf/confmodule 2>/dev/null; then
        if debconf-loadtemplate nclawzero /tmp/ncz-progress.templates 2>/dev/null; then
            DEBCONF_OK=1
        fi
    fi
fi

# Ordered hook list (sorted ≈ run order) so the bar position maps to the hook
# currently executing. Names are basenames sans .sh (matches the per-hook log
# names run-all.sh writes as $LOGDIR/${hook%.sh}.log).
HOOK_DIR=/target/usr/local/lib/cix-installer/post-install
HOOK_NAMES=$(ls "$HOOK_DIR"/[0-9][0-9]*.sh 2>/dev/null | sed 's#.*/##; s#\.sh$##' | sort)
NH=$(printf '%s\n' $HOOK_NAMES | grep -c .)
[ "$NH" -gt 0 ] 2>/dev/null || NH=1

echo "--- running post-install in chroot ---"
ttymsg "running post-install hooks (kernel, desktop, GPU/NPU, bootloader, rescue)…"
db_try db_capb
# r130.8 (defect A): do NOT start a NESTED progress bar. finish-install owns the
# visible "Finishing the installation" bar and parks it at step ~1/N (~14%) for
# this whole late_command; a nested bar only crawls inside that one step's width
# and its title is not shown, so it still looks frozen. The d-i-correct primitive
# here is db_progress INFO, which updates the STATUS-TEXT line under
# finish-install's bar (visible, proves liveness, shows staged status).
db_try db_subst nclawzero/install-step STEP "Preparing nclawzero install - please wait (this is normal, not frozen)..."
db_try db_progress INFO nclawzero/install-step

# Heartbeat: name the hook currently running by watching which per-hook log in
# /target/var/log/cix-install/ was touched most recently. Purely observational —
# it never touches the install and is killed the moment run-all.sh returns. It
# ALSO advances the main-screen debconf bar (best-effort) to that hook's index.
HOOK_LOGDIR=/target/var/log/cix-install
( hb_last=""
  while :; do
      sleep 8
      hb_cur=$(ls -t "$HOOK_LOGDIR"/*.log 2>/dev/null | head -1)
      hb_cur=${hb_cur##*/}; hb_cur=${hb_cur%.log}
      [ -z "$hb_cur" ] && hb_cur="(starting)"
      if [ "$hb_cur" != "$hb_last" ]; then
          ttymsg "  → now running: $hb_cur"
          hb_last="$hb_cur"
          if [ "$DEBCONF_OK" = 1 ] && [ "$hb_cur" != "(starting)" ]; then
              idx=$(printf '%s\n' $HOOK_NAMES | grep -nxF "$hb_cur" | head -1 | cut -d: -f1)
              [ -n "$idx" ] || idx=0
              db_try db_subst nclawzero/install-step STEP "Installing nclawzero: $hb_cur  ($idx of $NH) - please wait (not frozen)"
              db_try db_progress INFO nclawzero/install-step
          fi
      else
          ttymsg "  … still working: $hb_cur"
      fi
  done
) &
LATE_HB_PID=$!
set +e
in-target /usr/local/lib/cix-installer/post-install/run-all.sh
RET=$?
# r130.8 (defect B): stay under `set +e` through finalization so a non-fatal
# cleanup step (eject/strip/rsync/banner) can NEVER turn a SUCCESSFUL install
# (RET=0) into a non-zero late_command that bounces d-i back to the menu. The
# real run-all.sh rc stays in RET and is still propagated by `exit $RET` below
# (preserves the intended bootloader-failure -> install-failed behavior).
kill "$LATE_HB_PID" 2>/dev/null || true
# r130.8 (defect B): do NOT call db_progress STOP/SET. We never START our own
# bar now, so STOP would pop finish-install's OWN progress bar - on the success
# path that corrupted finish-install's accounting and bounced d-i back to the
# preseed/menu instead of showing the "Installation complete" conclusion screen.
db_try db_subst nclawzero/install-step STEP "nclawzero post-install complete - finalizing..."
db_try db_progress INFO nclawzero/install-step
ttymsg "post-install hooks finished (rc=$RET); finalizing apt sources + bootloader."

# Codex A2 fix: don't leave bind-mount around after late_command finishes
if [ "${CDROM_BIND_MOUNTED:-0}" = "1" ]; then
    umount /target/cdrom 2>&1 || true
    rmdir /target/cdrom 2>&1 || true
fi
echo "in-target run-all.sh exited: $RET"

# r130 fix (MrSBC/COS feedback 2026-06-23): strip ALL CD-ROM apt sources from
# /target before reboot. The offline mirror sources are required DURING
# post-install (file:///cdrom for our pool; d-i apt-setup may also add a
# `deb cdrom:[...]` line), but once the install media is ejected they make the
# installed system's `apt-get update` fail. Remove them as the last apt action.
echo "--- stripping CD-ROM apt sources from /target before reboot ---"
# r130.2 fix (Codex analysis of .66 install red-error): this step runs in the
# d-i runtime under BUSYBOX sed, NOT GNU sed. busybox sed has no `I`
# case-insensitive address modifier (GNU-only); the old `/.../Id` aborted
# late.sh with "sed: unsupported command I" AFTER an otherwise-successful
# install (run-all.sh exited 0), throwing d-i's red error screen at the very
# end. apt writes the URI scheme lowercase (`deb cdrom:` / `file:///cdrom`),
# so case-insensitivity is unnecessary — drop the `I` flag and use POSIX BRE
# (busybox supports the `\|` alternation extension; the cmdline parse above
# already relies on it). Wrapped in a guarded function so this cosmetic
# cleanup can NEVER red-screen a good install under `set -e`.
strip_cdrom_sources() {
    rm -f /target/etc/apt/sources.list.d/cixmini-cdrom.list
    rm -f /target/etc/apt/preferences.d/00cixmini-bootstrap-pool.pref
    if [ -f /target/etc/apt/sources.list ]; then
        sed -i \
            -e '/^[[:space:]]*deb[[:space:]].*\(cdrom:\|file:\/\/\/cdrom\)/d' \
            -e '/^[[:space:]]*deb-src[[:space:]].*\(cdrom:\|file:\/\/\/cdrom\)/d' \
            /target/etc/apt/sources.list
    fi
    for f in /target/etc/apt/sources.list.d/*.list; do
        [ -e "$f" ] || continue
        sed -i '/\(cdrom:\|file:\/\/\/cdrom\)/d' "$f"
        # remove the file entirely if stripping left it empty (no active deb lines)
        grep -qE '^[[:space:]]*deb' "$f" 2>/dev/null || rm -f "$f"
    done
}
strip_cdrom_sources || echo "WARN: cdrom source strip failed (non-fatal)"
echo "    remaining apt sources after cdrom strip:"
grep -rhsE '^[[:space:]]*deb' \
    /target/etc/apt/sources.list /target/etc/apt/sources.list.d/ 2>/dev/null \
    | sed 's/^/      /' || echo "      (none)"

# r130 fix: write the canonical ports.ubuntu.com network sources for the
# INSTALLED system. Previously post-install/20-desktop.sh overwrote
# sources.list with ports, which (being a network line) survived the cdrom
# strip and gave the booted system working apt. r130 makes 20-desktop install
# OFFLINE from the bundled /cdrom pool and no longer writes sources.list, so
# without this the strip would leave an EMPTY sources.list and `apt-get update`
# would have nothing post-boot. Write ports here for ALL variants (server +
# desktop), as the final apt action, so updates work post-boot (MrSBC/COS
# requirement). arm64 => ports.ubuntu.com.
echo "--- writing canonical ports.ubuntu.com network sources for the installed system ---"
cat > /target/etc/apt/sources.list <<'PORTS'
deb http://ports.ubuntu.com/ubuntu-ports resolute main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-security main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-backports main universe restricted multiverse
PORTS
# Drop the transient ports fallback list 20-desktop may have added; the
# canonical sources.list above now carries ports, so it is redundant.
rm -f /target/etc/apt/sources.list.d/ncz-ports-fallback.list
echo "    final installed-system apt sources:"
grep -rhsE '^[[:space:]]*deb' \
    /target/etc/apt/sources.list /target/etc/apt/sources.list.d/ 2>/dev/null \
    | sed 's/^/      /' || echo "      (none)"

# Eject the install media on success. We turned cdrom-detect/eject off
# in preseed.cfg so /cdrom would survive into late.sh — now that we're
# done with it, eject it manually. Without this, a real hardware reboot
# would still boot from the USB stick (UEFI BootOrder put it first), and
# in QEMU the next pass of `-boot d` would re-enter d-i for a second
# install pass on top of the just-installed system.
if [ "$RET" = "0" ]; then
    echo "--- ejecting install media ---"
    eject /cdrom 2>&1 || echo "eject /cdrom failed (non-fatal)"
fi


# r56: hydrate /etc/skel content into existing user homes that d-i created before late_command fired.
# Without this, post-install hooks that populate /etc/skel/Desktop and /etc/skel/.config don't
# reach the user (because d-i's user-creation step copies /etc/skel BEFORE late_command runs).
if [ "$RET" = "0" ]; then
    for home in /target/home/*; do
        [ -d "$home" ] || continue
        user=$(basename "$home")
        in-target rsync -a --ignore-existing /etc/skel/ /home/"$user"/ 2>/dev/null || true
        in-target chown -R "$user":"$user" /home/"$user" 2>/dev/null || true
    done
fi

# r56: loud REMOVE-USB banner so user sees it on every TTY before d-i reboots.
# d-i preseed (reboot_in_progress no longer set to note) will then prompt the
# user to dismiss before the actual reboot fires.
if [ "$RET" = "0" ]; then
    BANNER='\n\n  ============================================================\n  \n    NCZ 26.6 INSTALL COMPLETE\n    \n    >>> REMOVE THE USB STICK NOW <<<\n    \n    Then press Enter on the next dialog to reboot.\n    \n    If you forget, the system will boot back into the\n    installer (USB has higher boot priority than NVMe).\n  \n  ============================================================\n'
    for tty in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/console; do
        if [ -w "$tty" ]; then
            printf '%b' "$BANNER" >> "$tty" 2>/dev/null || true
        fi
    done
    sleep 5
fi
exit $RET
