#!/bin/sh
# See docs/ISO-BUILD-GUARDRAILS.md before changing this file —
# these are ISO build MECHANICS, stable across builds by design.
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
#      in a debconf-disconnected target chroot
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
# while this script runs silently into its log. The main screen now shows the
# authoritative run-all state as changing status text without modifying
# finish-install's parent progress accounting; this tty3 mirror remains the detail view
# (Alt+F3) and as the fallback if the debconf channel is unavailable. Best-
# effort; never fatal.
TTY=/dev/tty3
LATE_T0=$(date +%s 2>/dev/null || echo 0)
ttymsg() {
    _el=$(( $(date +%s 2>/dev/null || echo 0) - LATE_T0 ))
    printf '[ncz %s +%ss] %s\n' "$(date -u +%H:%M:%S)" "$_el" "$*" >"$TTY" 2>/dev/null || true
}
ttymsg "NCZ-OS installer: applying base OS + desktop + drivers (offline)."
ttymsg "This phase takes several minutes. The main screen shows a 'please be"
ttymsg "patient' status that updates per step; watch THIS console (Alt+F3) for detail."

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

# Release identity is independent from BUILD_VERSION (the per-ISO build serial).
# build-iso-di.sh stages release.conf as /cixmini/RELEASE; source it before any
# installer-visible text and copy it into the installed system below.
NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="unknown"
NCZ_RELEASE_CODENAME=""
for _release in /cdrom/cixmini/RELEASE /hd-media/cixmini/RELEASE \
                /media/cdrom/cixmini/RELEASE /run/live/medium/cixmini/RELEASE; do
    if [ -s "$_release" ]; then
        . "$_release"
        NCZ_RELEASE_SOURCE="$_release"
        break
    fi
done
NCZ_RELEASE_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"
[ -n "$NCZ_RELEASE_CODENAME" ] && \
    NCZ_RELEASE_LABEL="$NCZ_RELEASE_LABEL $NCZ_RELEASE_CODENAME"
export NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME NCZ_RELEASE_LABEL

# Initialize debconf before source discovery and asset staging so even the
# pre-hook portion of late_command has visible main-screen status. We inherit
# finish-install's frontend fds, but it owns the progress bar: use INFO only,
# never START/STOP/SET/STEP.
DEBCONF_OK=0
db_try() { [ "$DEBCONF_OK" = 1 ] || return 0; "$@" 2>/dev/null || true; }
# Report EACH precondition separately. This gate has four independent
# requirements and the old diagnostics only printed the DEBCONF_OK result, so a
# frozen progress bar told you the gate failed but never which half of it. Every
# investigation then needed a fresh install run to get back to this point.
# Printing all four costs nothing and makes the next install conclusive.
ncz_dbg_gate() {
    echo "[late/progress] gate: DEBIAN_HAS_FRONTEND=${DEBIAN_HAS_FRONTEND:-<unset>}"
    echo "[late/progress] gate: DEBCONF_REDIR=${DEBCONF_REDIR:-<unset>}"
    echo "[late/progress] gate: confmodule=$([ -f /usr/share/debconf/confmodule ] && echo present || echo MISSING)"
    echo "[late/progress] gate: debconf-loadtemplate=$([ -x /usr/bin/debconf-loadtemplate ] && echo present || echo MISSING)"
    # d-i is cdebconf, not Perl debconf: the loader may live elsewhere or under
    # another name. Show what IS available so a MISSING above is actionable.
    echo "[late/progress] gate: which debconf-loadtemplate=$(command -v debconf-loadtemplate 2>/dev/null || echo none)"
    echo "[late/progress] gate: cdebconf tools=$(ls /usr/bin/debconf-* 2>/dev/null | tr '\n' ' ')"
}
ncz_dbg_gate

if [ -n "$DEBIAN_HAS_FRONTEND" ] && [ -n "$DEBCONF_REDIR" ] \
   && [ -f /usr/share/debconf/confmodule ] && [ -x /usr/bin/debconf-loadtemplate ]; then
    cat > /tmp/ncz-progress.templates <<NCZTPL
Template: nclawzero/install-progress
Type: text
Description: Installing ${NCZ_RELEASE_LABEL} — please be patient (several minutes)
 The full desktop, GPU/NPU drivers, kernels and agents are being installed.
 The parent bar may remain in one position while the status below it changes.
 Press Alt+F3 at any time for live, per-step detail.

Template: nclawzero/install-step
Type: text
Description: \${STEP}

Template: nclawzero/remove-media
Type: note
Description: ${NCZ_RELEASE_LABEL} install complete - REMOVE THE USB STICK NOW
 The installation finished successfully.
 .
 IMPORTANT: physically remove the USB installation stick NOW, before you
 continue.
 .
 When you select Continue the system reboots into your new ${NCZ_RELEASE_LABEL}
 desktop. If the USB stick is left inserted, the machine may boot back
 into the installer instead of your new system.
NCZTPL
    if . /usr/share/debconf/confmodule 2>/dev/null; then
        if debconf-loadtemplate nclawzero /tmp/ncz-progress.templates 2>/dev/null; then
            DEBCONF_OK=1
        else
            echo "[late/progress] gate: confmodule sourced OK but debconf-loadtemplate FAILED"
        fi
    else
        echo "[late/progress] gate: sourcing /usr/share/debconf/confmodule FAILED"
    fi
else
    echo "[late/progress] gate: preconditions not met — progress bar will not update (see gate: lines above)"
fi
db_try db_subst nclawzero/install-step STEP "Preparing ${NCZ_RELEASE_LABEL} install media and target filesystem..."
db_try db_progress INFO nclawzero/install-step

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
# r157: a BAKED rootfs already ships /usr/local/lib/cix-installer with the
# generic-hook results + baked assets (refind_aa64.efi, rescue, kernel) +
# the BAKED marker. The old unconditional `rm -rf` wiped ALL of that (marker
# -> run-all fell back to NON-baked mode + kernel hooks; refind -> gone ->
# 70-bootloader could not install a bootloader). In baked mode, PRESERVE the
# baked tree and only refresh the post-install scripts from the ISO.
if [ -f /target/usr/local/lib/cix-installer/BAKED ] || [ -f /target/etc/ncz-baked ]; then
    echo "[late r157] baked rootfs detected — preserving baked assets + marker, refreshing post-install scripts only"
    rm -rf /target/usr/local/lib/cix-installer/post-install
    cp -a "$SRC/post-install" /target/usr/local/lib/cix-installer/
    # r160: union-sync assets from the ISO. The layered-squashfs base stages
    # only a SUBSET of assets (e.g. assets/refind/ holds just refind_aa64.efi
    # — no ncz.png / ncz-banner.png / icons/), so preserving the baked tree
    # alone left 70-bootloader without its banner + icons → rEFInd rendered
    # TEXT-ONLY (r128 regression, again). Copy any asset dir/file the baked
    # tree lacks; never overwrite what the image already ships (baked wins).
    if [ -d "$SRC/assets" ]; then
        # NOTE: this runs under d-i's BUSYBOX sh/cp — no `cp -n` (no-clobber);
        # the r160 first cut used `cp -an` and busybox cp rejected it silently
        # (stderr was discarded), leaving the icons gap in place. Do the union
        # file-by-file: mkdir every dir, copy only files the target lacks.
        DSTA=/target/usr/local/lib/cix-installer/assets
        mkdir -p "$DSTA"
        ( cd "$SRC/assets" || exit 0
          find . -type d | while read -r d; do
              mkdir -p "$DSTA/$d"
          done
          find . ! -type d | while read -r f; do
              # `-e` is FALSE for a dangling symlink while the link itself is
              # very much there, so the plain `[ -e ] || cp` here reported
              # every one of them as a failure:
              #   cp: can not create ".../0001-mali-...patch": File exists
              #   [late r160] WARN union-sync failed on ...
              # MEASURED on the r243 KVM install: 24 such warnings per install.
              # The baked layer shipped absolute symlinks into the Yocto build
              # container (/workdir/meta-cix/...), a path that exists on no
              # installed system, so those 24 kernel patches were absent from
              # every machine ever shipped. The source tree now carries the
              # real files; this replaces a broken link left by an older baked
              # layer rather than warning about it. A present REAL file is
              # still left alone -- baked still wins where baked has something.
              if [ -e "$DSTA/$f" ]; then
                  continue
              fi
              [ -L "$DSTA/$f" ] && rm -f "$DSTA/$f"
              cp -a "$f" "$DSTA/$f" || \
                  echo "[late r160] WARN union-sync failed on $f"
          done )
        echo "[late r160] asset union-sync done (refind: $(ls "$DSTA/refind/" 2>/dev/null | tr '\n' ' '))"

        # The union above deliberately preserves large baked payloads, but
        # boot-control code must never be "baked wins": fixes to the rEFInd
        # generator otherwise remain stale across every ISO that reuses the
        # base squashfs. Refresh this small executable from the current media
        # unconditionally and verify the copy before 70-bootloader runs it.
        REFIND_REFRESH=refind/ncz-refind-refresh.sh
        if [ -s "$SRC/assets/$REFIND_REFRESH" ]; then
            cp -a "$SRC/assets/$REFIND_REFRESH" "$DSTA/$REFIND_REFRESH" || {
                echo "[late] FATAL: could not refresh $REFIND_REFRESH from install media" >&2
                exit 1
            }
            chmod 0755 "$DSTA/$REFIND_REFRESH"
            cmp -s "$SRC/assets/$REFIND_REFRESH" "$DSTA/$REFIND_REFRESH" || {
                echo "[late] FATAL: refreshed $REFIND_REFRESH does not match install media" >&2
                exit 1
            }
            echo "[late] refreshed boot-control asset: $REFIND_REFRESH"
        else
            echo "[late] FATAL: install media lacks $REFIND_REFRESH" >&2
            exit 1
        fi
    fi
else
    rm -rf /target/usr/local/lib/cix-installer
    cp -a "$SRC" /target/usr/local/lib/cix-installer
fi
chmod 755 /target/usr/local/lib/cix-installer/post-install/*.sh
echo "    copy ok"
echo

# Stamp the install with the build serial + dual-kernel KVERs so
# 10-our-kernel.sh + 70-bootloader.sh can read them. Files land at
# both /etc/cix-installer/ (easy `cat` from running system) and
# /usr/local/lib/cix-installer/ (where post-install scripts read).
mkdir -p /target/etc/cix-installer
for f in BUILD_VERSION BUILD_DATE BUILD_HOST BUILD_ARCH KVER_LEGACY KVER_NEXT RELEASE; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" /target/etc/cix-installer/"$f"
        cp "$SRC/$f" /target/usr/local/lib/cix-installer/"$f"
    fi
done

ncz_recover_components() {
    _ncz_comp=""
    if [ -r /tmp/ncz-components ]; then
        _ncz_comp=$(tr -d ' \t\r\n' < /tmp/ncz-components 2>/dev/null || true)
    fi
    if [ -z "$_ncz_comp" ] && [ -r /var/lib/ncz-components/COMPONENTS ]; then
        _ncz_comp=$(tr -d ' \t\r\n' < /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)
    fi
    if [ -z "$_ncz_comp" ] && command -v debconf-get >/dev/null 2>&1; then
        _ncz_comp=$(debconf-get ncz/components 2>/dev/null | tr -d ' \t\r\n' || true)
    fi
    if [ -z "$_ncz_comp" ] && [ -r /var/lib/cdebconf/questions.dat ]; then
        _ncz_comp=$(awk '
            $0 == "Name: ncz/components" { inq=1; next }
            inq && /^Value: / { sub(/^Value: /, ""); print; exit }
            inq && /^Name: / { exit }
        ' /var/lib/cdebconf/questions.dat 2>/dev/null | tr -d ' \t\r\n' || true)
    fi
    if [ -z "$_ncz_comp" ]; then
        for _ncz_log in /var/log/syslog /var/log/installer/syslog /target/var/log/installer/syslog; do
            [ -r "$_ncz_log" ] || continue
            _ncz_comp=$(awk '
                /debconf: --> GET ncz\/components/ { want=1; next }
                want && /debconf: <-- 0 / {
                    sub(/^.*debconf: <-- 0 /, "")
                    val=$0
                    want=0
                }
                END { if (val != "") print val }
            ' "$_ncz_log" 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && break
        done
    fi
    [ -n "$_ncz_comp" ] || return 1

    printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
    mkdir -p /var/lib/ncz-components 2>/dev/null || true
    printf '%s\n' "$_ncz_comp" > /var/lib/ncz-components/COMPONENTS 2>/dev/null || true
    for _d in /target/usr/local/lib/cix-installer /target/etc/cix-installer \
              /target/var/lib/cix-components; do
        mkdir -p "$_d" 2>/dev/null || continue
        printf '%s\n' "$_ncz_comp" > "$_d/COMPONENTS" 2>/dev/null || true
    done
    for _bit in desktop browsers mgmt-container rescue-partition wallpaper-rotator; do
        _v=0
        case ",$_ncz_comp," in *,"$_bit",*) _v=1 ;; esac
        printf '%s\n' "$_v" > "/target/etc/cix-installer/COMPONENTS_$_bit" 2>/dev/null || true
    done
    printf '%s\n' "$_ncz_comp"
    return 0
}

echo "[late] component-selector state before BUILD_VARIANT decision: /tmp=[$(ls -l /tmp/ncz-components 2>&1)] value=[$(cat /tmp/ncz-components 2>/dev/null || true)] durable=[$(ls -l /var/lib/ncz-components/COMPONENTS 2>&1)] durable_value=[$(cat /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)]"
_ncz_comp=$(ncz_recover_components 2>/dev/null || true)
[ -n "$_ncz_comp" ] && echo "[late] recovered component selection before BUILD_VARIANT: $_ncz_comp"

# The ISO has one unified installation target.  Keep the desktop layer marker
# for compatibility with its existing hooks; console, recovery, Mali, and
# experimental Panthor are installed-system rEFInd choices, not install-time
# variants.
ncz_variant=$(sed -n 's/.*\(^\| \)ncz_variant=\([a-z]*\).*/\2/p' /proc/cmdline 2>/dev/null || echo "")
_want_desktop=1
if [ -n "$_ncz_comp" ]; then
    case ",$_ncz_comp," in
        *",desktop,"*) _want_desktop=1 ;;
        *)             _want_desktop=0 ;;
    esac
fi
if [ "$_want_desktop" = 0 ]; then
    echo "server" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
    echo "    desktop component disabled; console/base target selected"
else
    case "$ncz_variant" in
        desktop|""|server)
            echo "desktop" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
            [ "$ncz_variant" = server ] && echo "    ignoring obsolete ncz_variant=server; unified target selected"
            [ "$ncz_variant" != server ] && echo "    unified desktop layer selected"
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
fi
if [ -f /target/etc/cix-installer/BUILD_VERSION ]; then
    echo "    build stamp: $(cat /target/etc/cix-installer/BUILD_VERSION) ($(cat /target/etc/cix-installer/BUILD_DATE 2>/dev/null))"
fi
if [ -f /target/etc/cix-installer/KVER_LEGACY ]; then
    echo "    KVER_LEGACY:  $(cat /target/etc/cix-installer/KVER_LEGACY)"
fi
if [ -f /target/etc/cix-installer/KVER_NEXT ] && [ -s /target/etc/cix-installer/KVER_NEXT ]; then
    echo "    KVER_NEXT: $(cat /target/etc/cix-installer/KVER_NEXT) [BETA]"
fi
echo

echo "--- post-copy md5 of /target/.../10-our-kernel.sh ---"
md5sum /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || echo "md5sum unavailable"
wc -c /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || true
echo

# r196 CRITICAL: generate /etc/machine-id NOW, at install time, in the target.
# The baked Ubuntu-cloud rootfs ships an EMPTY /etc/machine-id (regenerated
# per-instance by cloud-init/systemd first boot). We de-cloud, and dbus.service
# starts EARLY at boot (sysinit/basic target) — well before ncz-firstboot's
# multi-user machine-id fixup runs. With an empty machine-id, dbus.service
# FAILS on the very first boot, and EVERYTHING that needs the system bus
# cascades: NetworkManager (=> no network), polkit, systemd-logind (=> greetd
# never starts => no GUI/Singularity), upower, bluetooth, wpa_supplicant. This
# was the "total regression since r194 — no network, no GUI" the operator hit
# on O6N metal (mali+dbus failures visible on the console). Writing a real,
# per-install-unique machine-id here (each d-i run generates its own) makes the
# system bus come up cleanly on boot #1. Also point /var/lib/dbus/machine-id at
# it (dbus reads that path on some layouts). Deterministic; runs every install.
echo "--- r196: seeding /etc/machine-id in target (dbus/NetworkManager/greetd depend on it) ---"
if [ ! -s /target/etc/machine-id ]; then
    if chroot /target systemd-machine-id-setup 2>/dev/null && [ -s /target/etc/machine-id ]; then
        echo "    machine-id generated via systemd-machine-id-setup: $(cat /target/etc/machine-id)"
    elif chroot /target dbus-uuidgen > /target/etc/machine-id 2>/dev/null && [ -s /target/etc/machine-id ]; then
        echo "    machine-id generated via dbus-uuidgen: $(cat /target/etc/machine-id)"
    else
        # last resort: 32 hex chars from the kernel RNG
        tr -cd '0-9a-f' < /dev/urandom 2>/dev/null | head -c 32 > /target/etc/machine-id
        echo "    machine-id generated via urandom fallback: $(cat /target/etc/machine-id)"
    fi
else
    echo "    /etc/machine-id already populated: $(cat /target/etc/machine-id)"
fi
# dbus system bus reads /var/lib/dbus/machine-id; keep it in sync with /etc/machine-id
mkdir -p /target/var/lib/dbus
ln -sf /etc/machine-id /target/var/lib/dbus/machine-id 2>/dev/null || \
    cp -f /target/etc/machine-id /target/var/lib/dbus/machine-id 2>/dev/null || true

# Do not add an ExecStartPre to dbus.service.  It runs with the unit's
# unprivileged service credentials on this image, so attempts to repair /run
# fail and take down D-Bus, logind, networking, and greetd together.  The
# target machine-id is generated and linked above before the first boot.
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
CDROM_REGULAR_INDEX=/cdrom/dists/${NCZ_BASE_CODENAME:-resolute}/main/binary-arm64/Packages
if [ -e /cdrom/.disk/base_installable ] || [ -s "$CDROM_REGULAR_INDEX" ]; then
    echo "--- mounting cdrom into /target for offline apt-get during post-install ---"
    mkdir -p /target/cdrom
    if grep -qs ' /target/cdrom ' /proc/mounts; then
        echo "    /target/cdrom already mounted"
    else
        mount --bind /cdrom /target/cdrom 2>&1 || \
            { echo "WARN: bind-mount /cdrom into /target failed; post-install apt-get may fail"; }
    fi

    # The NCZ flat repository is optional at build time. Do not register a
    # nonexistent source: v14 did so unconditionally, making every apt update
    # probe a series of missing Packages files before falling through to the
    # network repositories.
    if [ -s /cdrom/cixmini/apt-repo/Packages ] || \
       [ -s /cdrom/cixmini/apt-repo/Packages.gz ] || \
       [ -s /cdrom/cixmini/apt-repo/Packages.xz ] || \
       [ -s /cdrom/cixmini/apt-repo/Packages.zst ]; then
        echo "deb [trusted=yes] file:///cdrom/cixmini/apt-repo /" \
            > /target/etc/apt/sources.list.d/cixmini-offline.list
        echo "    NCZ flat offline repository enabled"
    else
        rm -f /target/etc/apt/sources.list.d/cixmini-offline.list
        echo "WARN: /cdrom/cixmini/apt-repo has no Packages index; NCZ packages require configured network repositories"
    fi

    # Add file:///cdrom apt source to /target's sources.list so apt-get
    # install in chroot can find packages locally. [trusted=yes] bypasses
    # GPG (we don't sign our offline mirror Release file yet).
    cat > /target/etc/apt/sources.list.d/cixmini-cdrom.list <<CDROM_LIST
deb [trusted=yes] file:///cdrom ${NCZ_BASE_CODENAME:-resolute} main
CDROM_LIST
    # During d-i the target clock can still be at the firmware default. APT
    # rejects the freshly generated ISO Release file as "not valid yet" in
    # that state, which leaves the local pool invisible to post-install hooks.
    # Keep this scoped to the install window and remove it before first boot.
    cat > /target/etc/apt/apt.conf.d/00ncz-install-time-clock <<'APT_CLOCK'
Acquire::Check-Date "false";
APT_CLOCK
    # d-i may leave a `deb cdrom:` entry that apt-get update cannot use without
    # apt-cdrom registration. The equivalent file:///cdrom source above is the
    # usable install-time source, so remove only the broken cdrom transport line.
    if [ -f /target/etc/apt/sources.list ]; then
        sed -i '/^[[:space:]]*deb[[:space:]].*cdrom:/d' /target/etc/apt/sources.list
    fi
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
        # "linux-firmware" is the Ubuntu name and does not exist in Debian, where
        # the same content is split across firmware-linux-free (main) and the
        # non-free-firmware bundles. Asking for the wrong one aborted with
        # "E: Unable to locate package linux-firmware" and left the system with
        # NO generic firmware -- e.g. rtl_nic/rtl8125k-1.fw for the r8169 NIC.
        if [ "${NCZ_BASE_NAME:-Ubuntu}" = "Debian" ]; then
            FW_PKGS="firmware-linux-free firmware-realtek firmware-misc-nonfree"
        else
            FW_PKGS="linux-firmware"
        fi
        chroot /target /usr/bin/apt-get install -y --allow-unauthenticated $FW_PKGS || { echo "WARN: firmware install failed ($FW_PKGS)"; true; }
        # r178: telnetd (doctrine #9 fleet lockout-prevention) from the OFFLINE
        # /cdrom pool. pkgsel/include is now EMPTY (the baked squashfs is the
        # complete system), but inetutils-telnetd + openbsd-inetd are the only
        # formerly-included packages not yet baked into base/desktop.squashfs.
        # They ARE in the embedded /cdrom pool (server-mirror), so install them
        # here fully offline — NOT from a network mirror. Non-fatal (|| true):
        # a bootable install must never red-error over telnet. Once
        # manifests/desktop.pkgs bakes them into the squashfs this is redundant.
        chroot /target /usr/bin/apt-get install -y --allow-unauthenticated inetutils-telnetd openbsd-inetd || { echo "WARN: offline telnetd apt-get returned non-zero (finishing configure below)"; true; }
        # r253.1: python3-dbus for bluetooth-autoconnect.service. It belongs in
        # the desktop layer via manifests/desktop.pkgs, but stale prebuilt
        # layers can reach this late-install path. Install it from the offline
        # pool here as a no-op once the layer is fresh, and as a targeted fix
        # for the live .66 ModuleNotFoundError: No module named 'dbus'.
        if ! chroot /target /usr/bin/apt-get install -y --allow-unauthenticated python3-dbus; then
            _pydbus_deb=$(find /cdrom/pool/main -maxdepth 1 -type f -name 'python3-dbus_*.deb' 2>/dev/null | sort -V | tail -1)
            if [ -n "$_pydbus_deb" ]; then
                cp "$_pydbus_deb" /target/tmp/python3-dbus.deb
                chroot /target /usr/bin/dpkg -i --force-depends /tmp/python3-dbus.deb || true
                rm -f /target/tmp/python3-dbus.deb
            else
                echo "WARN: offline python3-dbus apt-get returned non-zero and no embedded python3-dbus deb was found"
            fi
        fi
        # r178: finish configure in DEPENDENCY ORDER. inetutils-telnetd depends on
        # inet-superserver (provided by openbsd-inetd); apt unpacks both but may
        # try to configure telnetd before inetd -> configure error leaving them
        # 'unpacked'. dpkg --configure -a reconfigures ALL pending packages in the
        # correct order so telnet lands fully 'ii' at install time (doctrine #9).
        chroot /target /usr/bin/dpkg --configure -a 2>&1 | tail -3 || true
        # r178: ENABLE telnet on :23 (doctrine #9). openbsd-inetd's default telnet
        # entry ships DISABLED (#<off>#) and, in baked mode, run-all skips the
        # 36-telemetry hook that normally enables it. Activate it here: uncomment
        # the package entry (tcpd + telnetd are both installed), and belt-and-
        # suspenders add a direct line if none is active, then enable inetd. This
        # mirrors post-install/36-telemetry.sh. Non-fatal.
        if chroot /target dpkg -s inetutils-telnetd >/dev/null 2>&1; then
            chroot /target update-inetd --enable telnet 2>/dev/null || true
            chroot /target sh -c "grep -qE '^[[:space:]]*telnet[[:space:]]' /etc/inetd.conf 2>/dev/null || printf 'telnet\tstream\ttcp\tnowait\troot\t/usr/sbin/telnetd\ttelnetd\n' >> /etc/inetd.conf"
            chroot /target systemctl enable inetd 2>/dev/null || true
            chroot /target systemctl enable openbsd-inetd 2>/dev/null || true
            echo "[late r178] telnet enabled on :23 (doctrine #9): inetd.conf active + inetd service enabled"
        fi
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
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
options timeout:2 attempts:3
RESOLVCONF
echo "    /target/etc/resolv.conf:"
cat /target/etc/resolv.conf | sed 's/^/      /'

echo "--- running post-install in chroot ---"
ttymsg "running post-install hooks (kernel, desktop, GPU/NPU, bootloader, rescue)…"
db_try db_capb
db_try db_subst nclawzero/install-step STEP "Starting NCZ-OS post-install plan..."
db_try db_progress INFO nclawzero/install-step

_ncz_comp=""
for _ncz_log in /var/log/syslog /var/log/installer/syslog /target/var/log/installer/syslog; do
    [ -r "$_ncz_log" ] || continue
    _ncz_comp=$(awk '
        /debconf: --> GET ncz\/components/ { want=1; next }
        want && /debconf: <-- 0 / {
            sub(/^.*debconf: <-- 0 /, "")
            val=$0
            want=0
        }
        END { if (val != "") print val }
    ' "$_ncz_log" 2>/dev/null | tr -d ' \t\r\n' || true)
    [ -n "$_ncz_comp" ] && break
done
if [ -n "$_ncz_comp" ]; then
    for _d in /target/usr/local/lib/cix-installer /target/etc/cix-installer \
              /target/var/lib/cix-components; do
        mkdir -p "$_d" 2>/dev/null || continue
        printf '%s\n' "$_ncz_comp" > "$_d/COMPONENTS" 2>/dev/null || true
    done
    for _bit in desktop browsers mgmt-container rescue-partition wallpaper-rotator; do
        _v=0
        case ",$_ncz_comp," in *,"$_bit",*) _v=1 ;; esac
        printf '%s\n' "$_v" > "/target/etc/cix-installer/COMPONENTS_$_bit" 2>/dev/null || true
    done
    echo "[late] recovered component selection for post-install: $_ncz_comp"
fi

# Render the authoritative state written atomically by run-all.sh and the apt
# shim. This intentionally uses db_progress INFO only: finish-install owns the
# parent bar and will advance it after 07preseed/late_command returns.
PROGRESS_STATE=/target/var/log/cix-install/progress.state
case "${NCZ_PROGRESS_UNITS:-0}" in
    ''|*[!0-9]*) NCZ_PROGRESS_UNITS=0 ;;
esac

# --- NCZ PROGRESS DIAGNOSTICS -------------------------------------------
# The parent bar advances only when ALL THREE of these hold:
#   DEBCONF_OK = 1, NCZ_PROGRESS_UNITS > 0, hb_total > 0
# When the bar sat frozen through an entire install (reported 2026-08-14),
# none of the three could be recovered afterwards, because nothing logged
# them -- progress.state proved hb_total was 53, and that was the only one of
# the three that left any trace. The finish-install patch that exports
# NCZ_PROGRESS_UNITS was verified present in the shipped pool udeb (3 hits)
# and absent from the initrd (which carries no finish-install at all), so the
# patched copy is the one that runs and the variable SHOULD arrive here.
# Log all of it, once, so the next frozen bar names its own cause.
#
# NO PIPE, and specifically NOT `tee`. MEASURED on the r243 KVM install: this
# block was piped through `tee -a "$LOG" >&2`, and d-i busybox has no tee
# applet --
#     /cdrom/cixmini/late.sh: line 550: tee: not found
# -- so the ONE diagnostic written to answer "why is the bar frozen" silently
# produced nothing, and the trailing `|| true` hid the failure. The bar stayed
# frozen and the log still could not say why.
#
# It also did not need a pipe in the first place. Line 25 already does
# `exec >"$LOG" 2>&1`, so this block writing to plain stdout lands in exactly
# the same file; `tee -a "$LOG" >&2` would have written every line TWICE, once
# through the append and once through a stderr that is the same file.
{
    echo "[late/progress] DEBCONF_OK=${DEBCONF_OK:-unset}"
    echo "[late/progress] NCZ_PROGRESS_UNITS=${NCZ_PROGRESS_UNITS:-unset}"
    echo "[late/progress] NCZ_PROGRESS_CONSUMED_FILE=${NCZ_PROGRESS_CONSUMED_FILE:-unset}"
    echo "[late/progress] partsdir 07preseed: $(ls -l /usr/lib/finish-install.d/07preseed 2>&1 | head -1)"
    if [ "${NCZ_PROGRESS_UNITS:-0}" -gt 0 ] 2>/dev/null && [ "${DEBCONF_OK:-0}" = 1 ]; then
        echo "[late/progress] bar WILL advance"
    else
        echo "[late/progress] bar will NOT advance -- text-only degraded mode"
    fi
} 2>&1                               # $LOG is /target/var/log/... (line 23);
                                     # the bare /var/log path is the d-i ramdisk
                                     # and is DISCARDED at reboot -- that is why the
                                     # first KVM run produced no diagnostics at all.
late_progress_state() {
    _event="$1"; _phase="$2"; _hook="$3"; _detail="$4"
    _now=$(date +%s 2>/dev/null || echo 0)
    _idx=0; _total=0
    if [ -r "$PROGRESS_STATE" ]; then
        IFS='|' read -r _old_started _old_updated _old_event _old_phase _idx _total \
            _old_hook _old_pct _old_rc _old_detail < "$PROGRESS_STATE" || true
    fi
    _detail=$(printf '%s' "$_detail" | tr '|\t\r\n' '     ' | cut -c1-180)
    _tmp="${PROGRESS_STATE}.late.$$"
    printf '%s|%s|%s|%s|%s|%s|%s|||%s\n' \
        "$_now" "$_now" "$_event" "$_phase" "$_idx" "$_total" "$_hook" "$_detail" \
        > "$_tmp" && mv -f "$_tmp" "$PROGRESS_STATE"
}
set +e
# Do not background `in-target` here. in-target intentionally configures the
# target command to use d-i debconf passthrough on fd 0/fd 3; if it runs while
# this parent heartbeat also calls db_*, both process trees share one
# synchronous cdebconf protocol stream and the first heartbeat db_subst can
# block forever. Use chroot-setup's mount/policy setup, but run the target
# command with debconf fds/env disconnected so this foreground parent is the
# only debconf client.
RUNALL_RC_FILE=/tmp/ncz-runall.rc
rm -f "$RUNALL_RC_FILE"
(
    _runall_rc=1
    unset DEBIAN_HAS_FRONTEND DEBCONF_REDIR DEBCONF_FRONTEND
    unset DEBCONF_READFD DEBCONF_WRITEFD DEBCONF_PIPE
    DEBIAN_FRONTEND=noninteractive
    DEBIAN_PRIORITY=${DEBIAN_PRIORITY:-critical}
    IT_LANG_OVERRIDE=${IT_LANG_OVERRIDE:-C.UTF-8}
    export DEBIAN_FRONTEND DEBIAN_PRIORITY IT_LANG_OVERRIDE
    exec </dev/null
    exec 3>&-

    if [ -r /lib/chroot-setup.sh ]; then
        . /lib/chroot-setup.sh
        # chroot_setup normally calls debconf-get for locale/priority/proxy.
        # In this background process, any debconf access is forbidden because
        # the parent owns the cdebconf protocol channel for progress updates.
        _ncz_path=/tmp/ncz-runall-path.$$
        mkdir -p "$_ncz_path"
        cat > "$_ncz_path/debconf-get" <<'NCZ_DEBCONF_GET'
#!/bin/sh
case "$1" in
    debconf/priority) printf '%s\n' "${DEBIAN_PRIORITY:-critical}" ;;
    debian-installer/locale) printf '%s\n' "${IT_LANG_OVERRIDE:-C.UTF-8}" ;;
    *) exit 1 ;;
esac
NCZ_DEBCONF_GET
        chmod +x "$_ncz_path/debconf-get"
        PATH="$_ncz_path:$PATH"
        export PATH
        if chroot_setup; then
            chroot /target /usr/local/lib/cix-installer/post-install/run-all.sh
            _runall_rc=$?
            chroot_cleanup || true
            rm -rf "$_ncz_path"
        else
            echo "[late/progress] ERROR: chroot_setup failed; run-all.sh not executed"
            _runall_rc=1
            rm -rf "$_ncz_path"
        fi
    else
        echo "[late/progress] WARN: /lib/chroot-setup.sh missing; using plain chroot"
        chroot /target /usr/local/lib/cix-installer/post-install/run-all.sh
        _runall_rc=$?
    fi

    _tmp="${RUNALL_RC_FILE}.tmp.$$"
    printf '%s\n' "$_runall_rc" > "$_tmp" && mv -f "$_tmp" "$RUNALL_RC_FILE"
    exit "$_runall_rc"
) &
RUNALL_PID=$!
# r252: the heartbeat runs in the FOREGROUND, and the background chroot is
# disconnected from debconf. debconf confmodule is a synchronous
# request/response protocol over shared fds; no child may share those fds while
# this loop calls db_subst/db_progress.
hb_last_key=""
  hb_last_units=0
  hb_iter=0
  # r250 measured the writer and the reader separately and they disagree: the
  # writer emitted 573 progress records with valid hooks and totals (1/57 ..
  # 57/57 over 332s, see /var/log/cix-install/progress.tsv on the target),
  # while this loop logged NOTHING -- not one iteration reached the body. So
  # the bar does not stall because of the debconf gate (DEBCONF_OK=1,
  # NCZ_PROGRESS_UNITS=100, "bar WILL advance" are all present); it stalls
  # because this consumer never runs.
  #
  # Report, once, what the loop actually sees BEFORE any guard can skip it:
  # the path, whether it is readable, and whether the hook field parses. One of
  # those three is the answer, and without this every attempt costs a full
  # ISO + KVM cycle to get back to this point.
  echo "[late/progress] hb loop start: PROGRESS_STATE=${PROGRESS_STATE:-<unset>}"
  while [ ! -s "$RUNALL_RC_FILE" ] && kill -0 "$RUNALL_PID" 2>/dev/null; do
      sleep 4
      hb_iter=$((hb_iter + 1))
      if [ "$hb_iter" -le 3 ] || [ "$hb_iter" = 10 ] || [ "$hb_iter" = 30 ]; then
          echo "[late/progress] hb iter=$hb_iter readable=$([ -r "$PROGRESS_STATE" ] && echo yes || echo no) exists=$([ -e "$PROGRESS_STATE" ] && echo yes || echo no)"
      fi
      [ -r "$PROGRESS_STATE" ] || continue
      IFS='|' read -r hb_started hb_updated hb_event hb_phase hb_idx hb_total \
          hb_hook hb_pct hb_rc hb_detail < "$PROGRESS_STATE" || continue
      [ -n "$hb_hook" ] || continue
      case "$hb_idx" in ''|*[!0-9]*) hb_idx=0 ;; esac
      case "$hb_total" in ''|*[!0-9]*) hb_total=0 ;; esac
      hb_now=$(date +%s 2>/dev/null || echo "$hb_updated")
      hb_elapsed=$((hb_now - hb_started))
      [ "$hb_elapsed" -ge 0 ] 2>/dev/null || hb_elapsed=0
      hb_label=${hb_hook%.sh}
      hb_label=$(printf '%s' "$hb_label" | sed 's/^[0-9][0-9]-//; s/-/ /g')
      case "$hb_event" in
          APT)
              hb_status="Installing NCZ-OS: $hb_label ($hb_idx/$hb_total, ${hb_elapsed}s) - packages ${hb_pct:-0}%: $hb_detail"
              ;;
          WARN)
              hb_status="Installing NCZ-OS: $hb_label ($hb_idx/$hb_total) - warning: $hb_detail"
              ;;
          FAIL)
              hb_status="Installing NCZ-OS: $hb_label ($hb_idx/$hb_total) - FAILED: $hb_detail"
              ;;
          COMPLETE)
              hb_status="$hb_detail"
              ;;
          FINALIZE)
              hb_status="Finalizing NCZ-OS: $hb_label (${hb_elapsed}s) - $hb_detail"
              ;;
          *)
              hb_status="Installing NCZ-OS: $hb_label ($hb_idx/$hb_total, ${hb_elapsed}s) - $hb_detail"
              ;;
      esac
      hb_status=$(printf '%s' "$hb_status" | cut -c1-150)
      hb_key="$hb_event|$hb_phase|$hb_idx|$hb_hook|$hb_pct|$hb_detail"
      if [ "$hb_key" != "$hb_last_key" ]; then
          ttymsg "  → $hb_status"
          hb_last_key="$hb_key"
      fi
      # db_try swallows every error (`"$@" 2>/dev/null || true`), which is what
      # makes a dead heartbeat invisible. Measured on the r249 install: the two
      # FOREGROUND messages ("Preparing NCZ-OS ...", "Starting NCZ-OS
      # post-install plan...") both reached the console exactly once, while the
      # heartbeat produced ZERO updates -- even though progress.state was being
      # written correctly and reached 57/57. So the state feed works and the
      # display path needs direct return-code diagnostics.
      #
      # Log the actual return codes for the first few iterations. Bounded, so a
      # long install cannot spam the log, and enough to distinguish "debconf
      # rejects writes from a background subshell" from "the calls succeed but
      # nothing renders" -- which need completely different fixes.
      hb_subst_rc=0; hb_info_rc=0
      db_subst nclawzero/install-step STEP "$hb_status" 2>/dev/null || hb_subst_rc=$?
      db_progress INFO nclawzero/install-step 2>/dev/null || hb_info_rc=$?
      if [ "${hb_diag_n:-0}" -lt 3 ]; then
          hb_diag_n=$(( ${hb_diag_n:-0} + 1 ))
          echo "[late/progress] hb#$hb_diag_n subst_rc=$hb_subst_rc info_rc=$hb_info_rc event=$hb_event idx=$hb_idx/$hb_total hook=$hb_hook"
      fi

      # New ISOs patch finish-install itself to allocate exactly
      # NCZ_PROGRESS_UNITS units to 07preseed. Advance only inside that owned
      # range. On older/unpatched installers the variable is absent and this
      # safely degrades to changing INFO text without touching the parent bar.
      if [ "$DEBCONF_OK" = 1 ] && [ "$NCZ_PROGRESS_UNITS" -gt 0 ] \
         && [ "${hb_total:-0}" -gt 0 ] 2>/dev/null; then
          case "$hb_pct" in ''|*[!0-9]*) hb_pkg_pct=0 ;; *) hb_pkg_pct="$hb_pct" ;; esac
          [ "$hb_pkg_pct" -gt 100 ] 2>/dev/null && hb_pkg_pct=100
          case "$hb_event" in
              DONE|WARN|FAIL|SKIP|COMPLETE|FINALIZE)
                  hb_work=$((hb_idx * 100))
                  ;;
              APT)
                  hb_work=$(((hb_idx - 1) * 100 + hb_pkg_pct))
                  ;;
              *)
                  hb_work=$(((hb_idx - 1) * 100))
                  ;;
          esac
          hb_target_units=$((hb_work * NCZ_PROGRESS_UNITS / (hb_total * 100)))
          [ "$hb_target_units" -gt "$NCZ_PROGRESS_UNITS" ] && \
              hb_target_units="$NCZ_PROGRESS_UNITS"
          if [ "$hb_target_units" -gt "$hb_last_units" ]; then
              hb_delta=$((hb_target_units - hb_last_units))
              hb_step_rc=0
              db_progress STEP "$hb_delta" 2>/dev/null || hb_step_rc=$?
              if [ "${hb_step_diag_n:-0}" -lt 3 ]; then
                  hb_step_diag_n=$(( ${hb_step_diag_n:-0} + 1 ))
                  echo "[late/progress] hb STEP#$hb_step_diag_n delta=$hb_delta rc=$hb_step_rc units=$hb_target_units/$NCZ_PROGRESS_UNITS"
              fi
              hb_last_units="$hb_target_units"
              if [ -n "${NCZ_PROGRESS_CONSUMED_FILE:-}" ]; then
                  printf '%s\n' "$hb_last_units" > "$NCZ_PROGRESS_CONSUMED_FILE" 2>/dev/null || true
              fi
          fi
      fi
  done
  # r252 final drain: run-all has exited; push the bar to 100% of its owned
  # range before the finalize text replaces it, then reap run-all's real rc.
  if [ "$DEBCONF_OK" = 1 ] && [ "${NCZ_PROGRESS_UNITS:-0}" -gt "$hb_last_units" ]; then
      db_progress STEP "$((NCZ_PROGRESS_UNITS - hb_last_units))" 2>/dev/null || true
      hb_last_units="$NCZ_PROGRESS_UNITS"
  fi
wait "$RUNALL_PID"
WAIT_RET=$?
if [ -r "$RUNALL_RC_FILE" ]; then
    read -r RET < "$RUNALL_RC_FILE" || RET="$WAIT_RET"
else
    RET="$WAIT_RET"
fi

# 2026-08-26 round-2 defensive chmod (follow-up to 7de5ce6). The round-1
# extract-rootfs.sh gate verified live on O6N at the gate-pass window, but
# the fully-installed system still booted with / at 0700 — confirmed via
# rescue-partition stat:
#
#     Birth: 2026-08-26 14:22:13   (matches the extraction / gate-pass window)
#     Modify: 2026-08-26 14:27:39  (5 minutes LATER, mode is 0700 again)
#
# So something running BETWEEN the round-1 gate (~14:22:38, per syslog
# "squashfs rootfs ready") and 14:27:39 re-applies 0700 to / (== /target
# during install). That window covers: base-installer/pkgsel package
# installs, AND run-all.sh's chroot into /target where ~50 post-install
# hooks run live. A thorough search for the cd-then-relative-chmod /
# find ... -exec chmod-with-empty-var pattern across post-install/*.sh +
# late.sh did not pin the exact culprit; the defensive belt-and-suspenders
# below ships regardless. This is the CORRECTIVE half: chmod 0755 /target
# right after run-all.sh returns, log a clear warning if the mode had to
# be corrected. Non-hard-fail: too much install work has happened by now
# and a simple chmod is the right fix. The HARD-FAIL half is below,
# immediately before the final reboot-decision block.
# BusyBox in the d-i environment has no `stat` applet (confirmed live on
# O6N: "stat: not found") -- use `ls -ld` and compare the permission-string
# field instead of an octal mode.
_ncz_root_mode_post_runall=$(ls -ld /target 2>/dev/null | awk '{print $1}')
[ -n "$_ncz_root_mode_post_runall" ] || _ncz_root_mode_post_runall="???"
if [ "$_ncz_root_mode_post_runall" != "drwxr-xr-x" ]; then
    echo "[late round2/7de5ce6] WARNING: /target root mode was $_ncz_root_mode_post_runall after run-all.sh; correcting to 755"
    ttymsg "WARNING: /target root mode was $_ncz_root_mode_post_runall (expected drwxr-xr-x/0755); correcting (hard gate below will verify)"
    chmod 0755 /target 2>/dev/null || \
        echo "[late round2/7de5ce6] WARN: corrective chmod 0755 /target failed — relying on hard gate below"
fi

late_progress_state FINALIZE hardware npu-install-time "Applying install-time NPU and firmware finalization"

# ----------------------------------------------------------------------
# NPU (Cix Sky1 / Zhouyi v3) — INSTALL-TIME fixes on the REAL MS-R1.
#
# The BAKE runs the post-install hooks in an x86/qemu build chroot that CANNOT
# see the MS-R1's ACPI (/sys/bus/acpi/CIXH4000) or its DMI, so 80-npu.sh's
# board gate (should_apply_npu_ssdt) SKIPs the SSDT at build time, and in baked
# mode run-all.sh does not re-run 80-npu at install. This d-i runtime, by
# contrast, runs ON the MS-R1 — /sys/bus/acpi here reflects the real board — so
# it is the correct place to apply the two hardware-visible NPU fixes. Both are
# proven live on cixmini/.66 (persist across cold boot; /dev/aipu + 3 cores):
#
#   FIX A — prepend the NPU-core SSDT (adds the CIXH4010:0[012] core _HIDs the
#           MS-R1 BIOS omits; without it: probe -22, "failed to find NPU core
#           device CRE0/1/2") to the initrd rEFInd actually boots. rEFInd loads
#           the ESP copy (/boot/efi/initrd.img-$KVER), NOT btrfs /boot, and
#           70-bootloader has already staged the ESP copies by here (EXIT trap
#           inside run-all.sh above), so we prepend to the ESP copy directly.
#   FIX B — install the zhouyi_v3 armchina_npu.ko into updates/ so it wins over
#           the zhouyi-v2-only in-tree KMD ("unidentified hardware version
#           number: 5" -> probe -22). Machine-agnostic; belt-and-suspenders to
#           the base.squashfs bake (build-squashfs-layers.sh BASE_HOOKS 80-npu),
#           so a fresh install works even against the CURRENT (un-rebuilt) base.
#
# 100% best-effort: a bootable install must NEVER red-error over the NPU.
# ----------------------------------------------------------------------
ncz_npu_install_time() {
    NPU_KVERS=""
    for _kf in KVER_NEXT KVER_LEGACY; do
        _v=$(cat /target/etc/cix-installer/"$_kf" 2>/dev/null | tr -d ' \t\r\n')
        [ -n "$_v" ] && NPU_KVERS="$NPU_KVERS $_v"
    done
    if [ -z "$NPU_KVERS" ]; then
        echo "[npu] no KVER_NEXT/KVER_LEGACY sidecar — skipping NPU install-time fixes"
        return 0
    fi
    echo "[npu] install-time NPU fixes for KVERs:$NPU_KVERS (SRC=$SRC)"

    # --- FIX B: zhouyi_v3 armchina_npu.ko -> updates/ (machine-agnostic) ---
    # Only lands what the baked base did not already ship; safe to re-run.
    #
    # r186.1: $SRC (the live ISO /cixmini mount) can be missing this file
    # even when the repo + the baked rootfs both have it — observed on .66
    # r186 (cix-installer-late.log: FIX A ran, FIX B silently never fired,
    # "no CIXH4010 cores" -> unidentified hardware version 5 at boot,
    # /dev/aipu absent). Root cause is upstream in the squashfs/ISO staging of
    # assets/kernel/modules-overlay into /cixmini; this fallback makes FIX B
    # resilient to that regardless: /target/usr/local/lib/cix-installer/assets
    # is populated from the BAKED image (confirmed present even when $SRC
    # lacked it) and is unioned from $SRC earlier in this script, so it is at
    # least as complete as $SRC. Mirrors the existing dual-candidate pattern
    # in post-install/80-npu.sh and 81-vpu.sh (ISO path + already-staged path).
    for _kv in $NPU_KVERS; do
        _ov=""
        for _cand in             "$SRC/assets/kernel/modules-overlay/$_kv/armchina_npu.ko"             "/target/usr/local/lib/cix-installer/assets/kernel/modules-overlay/$_kv/armchina_npu.ko"; do
            [ -f "$_cand" ] && { _ov="$_cand"; break; }
        done
        [ -n "$_ov" ] || { echo "[npu]   FIX B: no armchina_npu.ko overlay found for $_kv (checked SRC + baked /target)"; continue; }
        [ -d "/target/usr/lib/modules/$_kv" ] || { echo "[npu]   no /target modules dir for $_kv"; continue; }
        if install -D -m 0644 "$_ov" "/target/usr/lib/modules/$_kv/updates/armchina_npu.ko" 2>/dev/null; then
            in-target depmod -a "$_kv" 2>/dev/null || true
            echo "[npu]   FIX B: zhouyi_v3 armchina_npu.ko ($_ov) -> /usr/lib/modules/$_kv/updates/ (+ depmod)"
        fi
    done
    # ensure the module auto-loads on boot (baked 80-npu also writes this)
    mkdir -p /target/etc/modules-load.d
    if ! grep -qs '^armchina_npu' /target/etc/modules-load.d/ncz-npu.conf 2>/dev/null; then
        printf '# NCZ: Cix Sky1 / Zhouyi v3 NPU driver\narmchina_npu\n' \
            > /target/etc/modules-load.d/ncz-npu.conf
    fi

    # --- FIX A: SSDT prepend to the ESP initrd (REAL-hardware gated) ---
    NPU_CPIO="$SRC/assets/npu/npu-acpi-override.cpio"
    if [ ! -f "$NPU_CPIO" ]; then
        echo "[npu] FIX A: SSDT cpio missing at $NPU_CPIO — cores may not enumerate on MS-R1"
        return 0
    fi
    # Board gate — mirror 80-npu.sh should_apply_npu_ssdt(), but on the LIVE
    # installer /sys (this IS the MS-R1). Apply iff the NPU device is present
    # but its cores are incomplete (<3) — the MS-R1 BIOS _HID gap. Skip when the
    # cores already enumerate natively (>=3; O6/O6N firmware is correct).
    _apply=0
    _ovr=/target/usr/local/lib/cix-installer/NPU_SSDT
    if [ -f "$_ovr" ]; then
        case "$(tr -d ' \t\r\n' < "$_ovr" 2>/dev/null)" in
            force|apply|on|1) _apply=1 ;;
            skip|off|0)       _apply=2 ;;   # 2 = forced-skip
        esac
    fi
    if [ "$_apply" = 0 ] && [ -d /sys/bus/acpi/devices ]; then
        _nc=$(ls -d /sys/bus/acpi/devices/CIXH4010:* 2>/dev/null | wc -l)
        if [ "$_nc" -ge 3 ]; then
            echo "[npu] FIX A: $_nc CIXH4010 cores enumerate natively (>=3) — SKIP (firmware OK)"
            _apply=2
        elif [ -e /sys/bus/acpi/devices/CIXH4000:00 ]; then
            echo "[npu] FIX A: CIXH4000 present, cores $_nc/3 — APPLY (MS-R1 BIOS _HID gap)"
            _apply=1
        fi
    fi
    if [ "$_apply" = 0 ]; then
        # No ACPI signal — DMI fallback (MS-R1 / Minisforum only).
        _pn=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        _sv=$(cat /sys/class/dmi/id/sys_vendor   2>/dev/null)
        case "$_pn $_sv" in
            *MS-R1*|*MINISFORUM*|*[Mm]inisforum*)
                echo "[npu] FIX A: DMI='$_pn'/'$_sv' (Minisforum MS-R1) — APPLY"; _apply=1 ;;
            *)
                echo "[npu] FIX A: no CIX NPU ACPI signal + DMI='$_pn'/'$_sv' unknown — SKIP" ;;
        esac
    fi
    if [ "$_apply" != 1 ]; then
        echo "[npu] FIX A: SSDT not applied for this board"
        return 0
    fi
    for _kv in $NPU_KVERS; do
        _esp="/target/boot/efi/initrd.img-$_kv"
        [ -f "$_esp" ] || { echo "[npu]   FIX A: no ESP initrd for $_kv (skip)"; continue; }
        # Idempotent: a non-prepended NCZ initrd is compressed (gzip/zstd magic);
        # a newc-cpio magic (070701) at the head means the SSDT is already there.
        if head -c 6 "$_esp" 2>/dev/null | grep -q '070701'; then
            echo "[npu]   FIX A: $_esp already SSDT-prepended"
            continue
        fi
        if cat "$NPU_CPIO" "$_esp" > "$_esp.npu" 2>/dev/null && mv "$_esp.npu" "$_esp"; then
            echo "[npu]   FIX A: SSDT prepended to $_esp"
        else
            rm -f "$_esp.npu" 2>/dev/null
            echo "[npu]   FIX A: WARN prepend failed for $_esp"
        fi
    done
    return 0
}
ncz_npu_install_time || echo "[npu] install-time NPU fixes returned nonzero (non-fatal)"

# r130.8 (defect B): stay under `set +e` through finalization so a non-fatal
# cleanup step (eject/strip/rsync/banner) can NEVER turn a SUCCESSFUL install
# (RET=0) into a non-zero late_command that bounces d-i back to the menu. The
# real run-all.sh rc stays in RET and is still propagated by `exit $RET` below
# (preserves the intended bootloader-failure -> install-failed behavior).
# r252: heartbeat is foreground now and run-all was already waited on above --
# no background PID to kill/reap here.
:
# r163: finalization (eject / skel / remove-media dialog / reboot stop) must
# gate on BOOTABILITY, not RET=0. On Sky1 METAL, efivars is unavailable so
# 70-bootloader's efibootmgr NVRAM write returns non-zero → RET!=0 even though
# rEFInd is on the ESP and the system boots. The old `if [ "$RET" = "0" ]`
# gates then SKIPPED the remove-media banner + blocking dialog entirely, so
# d-i had nothing to consume the finish flow and dropped to the raw MAIN MENU
# instead of rebooting (observed .66, 2026-07-03). By the time we get here
# run-all.sh's EXIT trap has already installed the bootloader, so this ESP
# check is authoritative. FINALIZE_OK = "install succeeded OR is bootable".
# ncz_bootable: TRUE iff rEFInd is on the ESP — INDEPENDENT of efibootmgr /
# efivars. 70-bootloader writes BOTH /EFI/BOOT/BOOTAA64.EFI and
# /EFI/BOOT/refind.conf to the removable-media fallback path BEFORE its
# best-effort efibootmgr NVRAM write, and hard-exits if BOOTAA64.EFI is empty.
# On Sky1 METAL there is NO efivars, so efibootmgr fails and RET!=0 — but the
# box still boots via the fallback binary. Key the finish/reboot decision on
# rEFInd-present, never on efibootmgr success. (refind.conf OR'd in as belt-and-
# suspenders in case a future ESP layout renames the fallback binary.)
ncz_bootable() {
    [ -f /target/boot/efi/EFI/BOOT/BOOTAA64.EFI ] || \
    [ -f /target/boot/efi/EFI/BOOT/refind.conf ]
}
# ncz_force_reboot: drive the reboot OURSELVES rather than trusting
# finish-install's menu loop. On Sky1 METAL the priority=critical finish-install
# did NOT auto-reboot after our late_command returned 0 — it dropped to the d-i
# MAIN MENU (operator report .66, 2026-07-03/04). r180 proved a direct reboot
# here is clean + deterministic on the unattended path; r181 uses the SAME path
# for the interactive install (after the operator dismisses the remove-media
# dialog). rEFInd is already synced to the FAT ESP and the root fs is journaled.
# Preserve the installer's OWN logs before we reboot.
#
# d-i normally copies /var/log/syslog into /target/var/log/installer/ during
# finish-install's own tail end. We deliberately reboot ourselves instead of
# returning to that menu (see ncz_force_reboot below), so that copy never
# happens and every install throws away the only timestamped record of the d-i
# session. That cost a diagnosis on 2026-08-14: an operator reported ~15s of
# black screen during d-i startup and there was nothing on the installed
# system to measure it with -- /var/log/installer did not exist.
#
# The installer console is tty0 + ttyAMA2 while the serial capture rig watches
# ttyAMA0, so serial is not a substitute here.
ncz_preserve_di_logs() {
    _dst=/target/var/log/installer
    mkdir -p "$_dst" 2>/dev/null || return 0
    for _f in /var/log/syslog /var/log/partman /var/log/hardware-summary; do
        [ -r "$_f" ] && cp -a "$_f" "$_dst/" 2>/dev/null || true
    done
    # dmesg gives the kernel-side timeline of the INSTALLER boot, which is a
    # different boot from the installed system's and is otherwise unrecoverable.
    dmesg > "$_dst/dmesg-installer.log" 2>/dev/null || true
    # NOT /var/log/cix-installer-late.log: that is the d-i ramdisk copy which may
    # not exist. The real log is $LOG, already on the target, so nothing to copy.
    sync 2>/dev/null || true
    echo "[late] preserved d-i logs to /var/log/installer on the target"
}

ncz_force_reboot() {
    ncz_preserve_di_logs
    echo "[late r181] forcing clean reboot ($1) — rEFInd on ESP; not relying on finish-install menu"
    ttymsg "install complete — rebooting into ${NCZ_RELEASE_LABEL}" 2>/dev/null || true
    db_try db_set  debian-installer/exit/reboot true
    db_try db_fset debian-installer/exit/reboot seen true
    db_try db_set  debian-installer/exit/poweroff false
    sync
    # best-effort unmount of the target so the reboot is clean; ignore fails
    for _m in /target/cdrom /target/dev/pts /target/dev /target/proc /target/sys; do
        umount "$_m" 2>/dev/null || true
    done
    reboot 2>/dev/null || reboot -f 2>/dev/null || true
}
FINALIZE_OK=0
{ [ "$RET" = "0" ] || ncz_bootable; } && FINALIZE_OK=1

# 2026-08-26 round-2 HARD-FAIL MECHANICAL VERIFICATION GATE.
#
# Why here (and not anywhere later): every reboot path from this script
# originates BELOW this point — the unattended branch's ncz_force_reboot
# (~line ~1361), the interactive branch's ncz_force_reboot (~line ~1383),
# and the final r155 fallback `if ncz_bootable; then ... exit 0; fi` near
# the bottom of the file (~line ~1406). By placing the gate here, before
# anything that can call reboot(8) or exit 0, every reboot path MUST pass
# this check first.
#
# What it checks: stat -c '%a' /target must read 755. The corrective
# chmod earlier in this script (right after run-all.sh returned) makes a
# best-effort fix; this gate is the operator-required safety net that
# refuses to ship a broken install even if a later step we haven't yet
# identified re-broke the root mode. Same fail-loud pattern as the round-1
# extract-rootfs.sh gate (FATAL message, set RET, force the existing
# exit-code mapping at the very end of this file to do the non-zero exit).
#
# Why we also force FINALIZE_OK=0 and a separate _ncz_root_mode_ok flag on
# failure: the existing r155 logic (`if ncz_bootable; then ... exit 0; fi`)
# intentionally swallows non-zero RETs from optional hook failures when
# rEFInd is present on the ESP, to avoid finish-install's red error on
# boards where efibootmgr/efivars are unavailable (Sky1 METAL). That logic
# assumes rEFInd-present == system boots. A root at 0700 VIOLATES that
# assumption: rEFInd loads, but the kernel cannot traverse / for any
# non-root UID, so greetd/NIC/RTC all fail and the system never reaches a
# login. We must NOT honour the r155 exit-0 heuristic for this failure
# class, so we route around it via _ncz_root_mode_ok.
_ncz_root_mode_final=$(ls -ld /target 2>/dev/null | awk '{print $1}')
[ -n "$_ncz_root_mode_final" ] || _ncz_root_mode_final="???"
_ncz_root_mode_ok=1
if [ "$_ncz_root_mode_final" != "drwxr-xr-x" ]; then
    echo "[late round2/7de5ce6] FATAL: /target root mode is $_ncz_root_mode_final, expected drwxr-xr-x/0755 — refusing to ship a broken install"
    ttymsg "FATAL: /target root mode $_ncz_root_mode_final (expected drwxr-xr-x/0755) — install refused"
    # Final corrective attempt + verify. Idempotent and cheap even if the
    # earlier corrective gate already fixed it.
    chmod 0755 /target 2>/dev/null || \
        echo "[late round2/7de5ce6] FATAL: chmod 0755 /target failed — bailing"
    _ncz_root_mode_recheck=$(ls -ld /target 2>/dev/null | awk '{print $1}')
    [ -n "$_ncz_root_mode_recheck" ] || _ncz_root_mode_recheck="???"
    if [ "$_ncz_root_mode_recheck" != "drwxr-xr-x" ]; then
        # Same fail-loud pattern as the round-1 extract-rootfs.sh gate:
        # mark failure on the existing RET axis and force the r155
        # bootability heuristic off so finish-install surfaces the failure.
        # Preserve an existing non-zero RET (a run-all failure we shouldn't
        # overwrite); only stamp RET=1 if run-all had succeeded.
        if [ "${RET:-0}" = "0" ]; then
            RET=1
        fi
        FINALIZE_OK=0
        _ncz_root_mode_ok=0
        echo "[late round2/7de5ce6] FATAL: /target root mode still $_ncz_root_mode_recheck after corrective chmod — refusing to boot"
    fi
fi

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
echo "target run-all.sh exited: $RET"

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
    rm -f /target/etc/apt/apt.conf.d/00ncz-install-time-clock
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
# Profile-aware: the suite above is Ubuntu-only. On a Debian base the
# profile-correct base repo is already written as a signed deb822 file
# (/etc/apt/sources.list.d/ncz-base.sources) by post-install/24-apt-sources.sh,
# so writing an Ubuntu sources.list here would leave a Debian system pointing
# at ports.ubuntu.com and break apt-get update outright. Only write the ports
# list for an actual Ubuntu base, and take the codename from release.conf
# rather than hard-coding it.
if [ "${NCZ_BASE_NAME:-}" = "Ubuntu" ]; then
    _ubu_suite="${NCZ_BASE_CODENAME:-resolute}"
    echo "--- writing canonical ports.ubuntu.com network sources ($_ubu_suite) ---"
    cat > /target/etc/apt/sources.list <<PORTS
deb http://ports.ubuntu.com/ubuntu-ports $_ubu_suite main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports $_ubu_suite-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports $_ubu_suite-security main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports $_ubu_suite-backports main universe restricted multiverse
PORTS
else
    echo "--- ${NCZ_BASE_NAME:-non-Ubuntu} base: leaving sources.list to the profile deb822 source ---"
    : > /target/etc/apt/sources.list
    if [ -s /target/etc/apt/sources.list.d/ncz-base.sources ]; then
        echo "    base repo carried by /etc/apt/sources.list.d/ncz-base.sources:"
        sed 's/^/      /' /target/etc/apt/sources.list.d/ncz-base.sources
    else
        echo "    WARN: no ncz-base.sources — the installed system has NO base apt repo" >&2
    fi
fi
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
if [ "$FINALIZE_OK" = "1" ]; then
    echo "--- ejecting install media ---"
    eject /cdrom 2>&1 || echo "eject /cdrom failed (non-fatal)"
fi


# r56: hydrate /etc/skel content into existing user homes that d-i created before late_command fired.
# Without this, post-install hooks that populate /etc/skel/Desktop and /etc/skel/.config don't
# reach the user (because d-i's user-creation step copies /etc/skel BEFORE late_command runs).
if [ "$FINALIZE_OK" = "1" ]; then
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
if [ "$FINALIZE_OK" = "1" ]; then
    BANNER="\n\n  ============================================================\n  \n    ${NCZ_RELEASE_LABEL} INSTALL COMPLETE\n    \n    >>> REMOVE THE USB STICK NOW <<<\n    \n    Then press Enter on the next dialog to reboot.\n    \n    If you forget, the system will boot back into the\n    installer (USB has higher boot priority than NVMe).\n  \n  ============================================================\n"
    for tty in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/console; do
        if [ -w "$tty" ]; then
            printf '%b' "$BANNER" >> "$tty" 2>/dev/null || true
        fi
    done
    # r135: BLOCKING graphical dialog so the user removes the USB before the
    # reboot. priority=critical (r134) means d-i may reboot without its own
    # final prompt, and the TTY banner above is only visible on Alt+F3. This
    # pops a note on the same frontend d-i uses and waits for Continue.
    # r162 (codex review): skip the blocking remove-media dialog on unattended
    # installs (qemu harness / automated runs pass ncz_unattended=1). Metal
    # USB installs keep the full stop — that dialog is the whole point there.
    #
    # r180/r181 (.66 metal fix): d-i's priority=critical finish-install did NOT
    # auto-reboot after our late_command (finish-install.d/07preseed) returned —
    # it dropped to the d-i MAIN MENU on Sky1 metal, on BOTH the unattended and
    # the interactive path. The skipped/dismissed remove-media db_input used to be
    # what drove finish->reboot. So we drive the reboot OURSELVES on BOTH paths
    # (ncz_force_reboot), gated on rEFInd-present bootability (ncz_bootable) which
    # is efibootmgr/efivars-INDEPENDENT — the metal Sky1 box has no efivars so
    # efibootmgr fails, but the ESP fallback binary still boots it.
    #
    # UNATTENDED (qemu harness / automated): no dialog — reboot immediately.
    # INTERACTIVE (metal USB install): show the blocking remove-media dialog,
    # WAIT for the operator to remove the stick + press Continue, THEN reboot.
    if grep -qw ncz_unattended=1 /proc/cmdline 2>/dev/null; then
        if ncz_bootable; then
            ncz_force_reboot "unattended"
        else
            echo "[late r181] unattended but NOT bootable — leaving to d-i (no forced reboot)"
        fi
    else
        # r135: BLOCKING graphical dialog so the operator removes the USB before
        # the reboot. priority=critical means d-i may not show its own final
        # prompt, and the TTY banner above is only visible on Alt+F3. This pops a
        # note on the same frontend d-i uses and WAITS for Continue.
        if [ "$DEBCONF_OK" = 1 ]; then
            db_try db_fset nclawzero/remove-media seen false
            db_try db_input critical nclawzero/remove-media
            db_try db_go
        else
            # no debconf channel — the TTY banner above is the only notice; give
            # the operator a moment to read it before we reboot.
            sleep 5
        fi
        # r181: after the operator dismisses the dialog, DRIVE the reboot too.
        # Relying on finish-install's menu loop here is exactly what left the box
        # at the d-i MAIN MENU on Sky1 metal — force it, gated on bootability.
        if ncz_bootable; then
            ncz_force_reboot "interactive"
        else
            echo "[late r181] interactive but NOT bootable — leaving to d-i (will surface the failure, not reboot into an unbootable system)"
        fi
    fi
fi
# r155/r174/r181: a bootable install (rEFInd on the ESP) must NEVER throw d-i's
# critical preseed/command_failed red error. Optional apt/network hook failures
# and the Sky1 efivars-unavailable bootloader path leave RET!=0 but the system
# still boots via the /EFI/BOOT fallback. This block is a FALLBACK: on the normal
# path ncz_force_reboot above already rebooted the box; we only reach here if that
# reboot(8) has not yet taken effect. Reassert reboot + exit 0 so finish-install
# does NOT red-error a bootable install. ncz_bootable is efibootmgr/efivars-
# independent (keys on rEFInd-present, not NVRAM), so metal succeeds here too.
#
# 2026-08-26 round-2 (follow-up to 7de5ce6): also require _ncz_root_mode_ok=1.
# rEFInd-present is NOT sufficient evidence of a bootable system when / is
# 0700 — the kernel loads but cannot traverse / for non-root UIDs (greetd /
# NIC / RTC all fail). When the hard-fail gate above fires, it sets
# _ncz_root_mode_ok=0 AND RET=1; we drop through this r155 block and let the
# existing case statement at the end of this file translate RET=1 into a
# non-zero exit (NOT honouring the r155 exit-0 heuristic for this failure
# class — it's a different failure than efivars-unavailable).
if ncz_bootable && [ "${_ncz_root_mode_ok:-1}" = "1" ]; then
    # r174 (#1 finish): reassert the reboot intent ONLY on the bootable path, so
    # the clean finish does not hinge on the priority=critical boot arg AND we
    # never tell finish-install to reboot a NON-bootable install. rEFInd is
    # installed DURING finish-install (this late_command runs as
    # finish-install.d/07preseed), so by here the bootloader phase is complete.
    # Best-effort; guarded so it can never fail the finish.
    if [ -n "$DEBIAN_HAS_FRONTEND" ] && [ -f /usr/share/debconf/confmodule ]; then
        ( . /usr/share/debconf/confmodule 2>/dev/null || exit 0
          db_set debian-installer/exit/reboot true 2>/dev/null || true
          db_fset debian-installer/exit/reboot seen true 2>/dev/null || true
          db_set debian-installer/exit/poweroff false 2>/dev/null || true
          db_fset finish-install/reboot_in_progress seen true 2>/dev/null || true
        ) 2>/dev/null || true
    fi
    if [ "$RET" != "0" ]; then
        echo "[late r155] post-install rc=$RET but rEFInd present at /EFI/BOOT/BOOTAA64.EFI -> system is bootable; exiting 0 (no red error)"
        ttymsg "install complete (some optional hooks failed, system is bootable)" 2>/dev/null || true
    fi
    exit 0
fi
# r174 (#6 review): NOT bootable — do NOT reassert reboot; force a NONZERO exit
# even when run-all.sh returned 0, so finish-install surfaces the failure and
# does NOT reboot into an unbootable install.
echo "[late r174] no rEFInd at /target/boot/efi/EFI/BOOT/BOOTAA64.EFI -> install is NOT bootable; refusing clean reboot"
# r203: exit non-zero robustly. This must surface a failure to finish-install,
# but `exit $RET` assumed RET is numeric — if RET is non-numeric (observed once
# as the string "OK") the sh builtin dies with "exit: Illegal number: OK",
# which STILL exits non-zero but spams a confusing error over the real cause.
# Force a clean numeric exit: any non-"0"/non-numeric RET (including empty)
# reports as 1; a genuine numeric non-zero RET is passed through unchanged.
case "$RET" in
    0)          exit 1 ;;                       # bootloader missing despite rc=0
    ''|*[!0-9]*) exit 1 ;;                      # non-numeric/empty RET
    *)          exit "$RET" ;;                  # genuine numeric failure code
esac
