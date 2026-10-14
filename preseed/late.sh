#!/bin/sh
# Read build/check-extract-rootfs-consistency.sh before changing this file —
# these are image build MECHANICS, stable across builds by design.
# late.sh — run from preseed late_command in the d-i runtime context.
#
# d-i's late_command runs after base install + apt config + bootloader
# but before reboot. /target is mounted; /cdrom *should* be the install
# media, but eject behavior + multi-source detection (cdrom vs hd-media
# vs cd-from-iso) makes hard-coded paths fragile. This script:
#
#   1. logs everything to /target/var/log/cix-installer-late.log
#   2. probes ALL plausible locations for the bundled /ncz-payload dir
#   3. copies it into /target/usr/local/lib/cix-installer
#   4. invokes /usr/local/lib/cix-installer/post-install/run-all.sh
#      in a debconf-disconnected target chroot
#   5. emits a clear, debuggable error if any step fails — including
#      mountpoint state, dir contents, and exit codes
#
# This script lives at /cdrom/ncz-payload/late.sh on the install medium; preseed's
# late_command invokes it via `sh /cdrom/ncz-payload/late.sh` (with
# multi-path fallback to find the script itself if /cdrom moved).

set -e

LOG=/target/var/log/cix-installer-late.log
mkdir -p /target/var/log
exec >"$LOG" 2>&1

# r130.3 progress UX: preseed/late_command is a single opaque step to d-i, so
# the main "Finishing the installation" bar parks (testers reported a "stuck at
# 14%" hang) for the entire multi-minute OFFLINE base + desktop + driver install
# while this script runs silently into its log. The main screen now shows the
# authoritative run-all state as changing status text and moves finish-install's
# own bar through post-install (NCZ-BAR block below; finish-install's accounting
# still ends at exactly 100%); this tty3 mirror remains the detail view
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

# Release identity is independent from BUILD_VERSION (the per-image build serial).
# build/iso/write-usb-image.py stages release.conf as /ncz-payload/RELEASE; source it before any
# installer-visible text and copy it into the installed system below.
NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="unknown"
NCZ_RELEASE_CODENAME=""
for _release in /cdrom/ncz-payload/RELEASE /hd-media/ncz-payload/RELEASE \
                /media/cdrom/ncz-payload/RELEASE /run/live/medium/ncz-payload/RELEASE; do
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
# finish-install's frontend fds and its progress bar: INFO here; the bar is
# only moved by the NCZ-BAR block (START/SET/STEP, never STOP).
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
    # The installer diagnostics login (root / rescue, docs/RECOVERY-LOGINS.md) stays on the
    # progress screen for the whole post-install phase (preseed/ncz-ui.sh).
    NCZ_DIAG_LOGIN_LINE=$( . /ncz/ncz-ui.sh 2>/dev/null && ncz_ui_diag_login 2>/dev/null )
    cat > /tmp/ncz-progress.templates <<NCZTPL
Template: nclawzero/install-progress
Type: text
Description: Installing ${NCZ_RELEASE_LABEL} - please be patient (several minutes)
 The full desktop, GPU/NPU drivers, kernels and agents are being installed.
 The status line below the bar names the step running now.
 Press Alt+F3 at any time for live, per-step detail.${NCZ_DIAG_LOGIN_LINE:+ Remote $NCZ_DIAG_LOGIN_LINE.}

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

Template: nclawzero/remove-media-gpu
Type: note
Description: ${NCZ_RELEASE_LABEL} install complete - REMOVE THE USB STICK NOW
 The installation finished successfully.
 .
 IMPORTANT: physically remove the USB installation stick NOW, before you
 continue.
 .
 \${GPUNOTE}
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
for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
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
for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
    [ -d "$d" ] && SRC="$d" && break
done

if [ -z "$SRC" ]; then
    echo "FATAL: no /ncz-payload source found in any expected location."
    ttymsg "FATAL: no NCZ payload found; installation refused (see late.log)."
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
# 2026-05-04 review: rm -rf + cp -a so reruns don't nest ncz-payload/
# inside existing /target/usr/local/lib/cix-installer/.
# r157: a BAKED rootfs already ships /usr/local/lib/cix-installer with the
# generic-hook results + baked assets (refind_aa64.efi, rescue, kernel) +
# the BAKED marker. The old unconditional `rm -rf` wiped ALL of that (marker
# -> run-all fell back to NON-baked mode + kernel hooks; refind -> gone ->
# 70-bootloader could not install a bootloader). In baked mode, PRESERVE the
# baked tree and only refresh the post-install scripts from the medium.
if [ -f /target/usr/local/lib/cix-installer/BAKED ] || [ -f /target/etc/ncz-baked ]; then
    echo "[late r157] baked rootfs detected — preserving baked assets + marker, refreshing post-install scripts only"
    # 2026-09-24: this used to `rm -rf` the baked post-install/ tree and THEN
    # copy from $SRC unconditionally. When the raw-GPT writer stopped staging
    # post-install/ onto the medium (build-iso-di.sh:3124 did; the new
    # write-usb-image.py did not), that copy failed under `set -e` -- AFTER
    # the delete -- so the target was left with no post-install scripts at
    # all and late.sh died on the spot. The refresh itself is deliberate
    # (post-install fixes must be able to land without a squashfs rebuild,
    # same reasoning as the ncz-refind-refresh.sh block below), so keep it --
    # but only when the medium really has a tree to refresh FROM, and never
    # destroy a working one to find that out.
    if [ -d "$SRC/post-install" ] && [ -f "$SRC/post-install/run-all.sh" ]; then
        rm -rf /target/usr/local/lib/cix-installer/post-install
        cp -a "$SRC/post-install" /target/usr/local/lib/cix-installer/
        mkdir -p /target/usr/local/lib/cix-installer/manifests
        cp -a "$SRC/manifests/." /target/usr/local/lib/cix-installer/manifests/ 2>/dev/null || true
        echo "[late] refreshed post-install scripts from $SRC/post-install"
    elif [ -f /target/usr/local/lib/cix-installer/post-install/run-all.sh ]; then
        echo "[late] WARN: install media carries no post-install/ — keeping the scripts baked into the image"
    else
        echo "[late] FATAL: no post-install/ on the install media AND none baked into the image — nothing would configure this system" >&2
        exit 1
    fi
    # r160: union-sync assets from the medium. The layered-squashfs base stages
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
              # A baked layer can carry an absolute symlink where the media
              # has a real directory: base.squashfs ships
              # assets/kernel/mainline -> <shared kernel-staging>/...,
              # which dangles on every installed system. mkdir -p cannot walk
              # through it ("can't create directory ...: No such file or
              # directory"), and because `find | while` reports the status of
              # its LAST iteration, whether that killed late.sh (set -e) came
              # down to which directory find happened to list last. The 2026-09-29
              # arm64 install died here once the media carried a populated
              # assets/kernel/mainline/headers-dir tree. Replace the dangling link
              # with a real directory, like the file loop below does for files.
              if [ -L "$DSTA/$d" ] && [ ! -e "$DSTA/$d" ]; then
                  rm -f "$DSTA/$d"
              fi
              mkdir -p "$DSTA/$d" || \
                  echo "[late r160] WARN union-sync could not create directory $d"
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
          done
          true )
        echo "[late r160] asset union-sync done (refind: $(ls "$DSTA/refind/" 2>/dev/null | tr '\n' ' '))"

        # The union above deliberately preserves large baked payloads, but
        # boot-control code must never be "baked wins": fixes to the rEFInd
        # generator otherwise remain stale across every image that reuses the
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
# Same class of trap as the refresh above: a bare glob under `set -e` turns
# a missing directory into an unexplained late.sh death. Say what is wrong.
if [ ! -f /target/usr/local/lib/cix-installer/post-install/run-all.sh ]; then
    echo "[late] FATAL: /target/usr/local/lib/cix-installer/post-install/run-all.sh is missing after the copy step" >&2
    exit 1
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

# NCZ-REGION-PERSIST-BEGIN
# r201: carry the installer's region choice (preseed/region-chooser.sh writes
# /tmp/ncz-region: locale, country, timezone, keymap -- one per line, also for
# the ncz_region= cmdline override) onto the target. Nothing used to, so
# 37-ntp-hostname.sh never saw the timezone and MS-R1 installed on UTC after
# the operator picked America/New_York.
_ncz_region_src="${NCZ_REGION_FILE:-/tmp/ncz-region}"
if [ -s "$_ncz_region_src" ]; then
    if cp "$_ncz_region_src" /target/etc/cix-installer/ncz-region 2>/dev/null; then
        chmod 0644 /target/etc/cix-installer/ncz-region 2>/dev/null || true
        echo "[late] region choice persisted: $(tr '\n' ' ' < /target/etc/cix-installer/ncz-region)"
    else
        echo "[late] WARN: could not copy $_ncz_region_src to /target/etc/cix-installer/ncz-region"
    fi
else
    echo "[late] no $_ncz_region_src (region chooser did not run); timezone policy falls back to hook defaults"
fi
unset _ncz_region_src
# NCZ-REGION-PERSIST-END

# NCZ-NOUVEAU-RUNPM-BEGIN
# amd64 only: keep nouveau's runtime PM off on the installed system, written
# BEFORE run-all.sh so the first hook that touches the GPU, the initramfs that
# 10-amd64-kernel.sh builds and the first boot all see it.
#
# Why (the GU502LV laptop, ASUS GU502LV, RTX 2060 Mobile TU106 10de:1f15, 2026-10-06):
# on 7.3-rc5+ nouveau_pmops_runtime_suspend() asks GSP-RM whether the GPU may
# enter GCOFF (nvif_device_gcx_ready -> nvkm_udevice_gcx_ready ->
# nvkm_gsp_gcx_ready). Without GSP-RM firmware the GSP subdev exists but
# gsp->rm is NULL, so the runtime-PM worker oopses (NULL deref at 0x18), the
# device stays in runtime_status "suspending" and every later PCI config read
# (lspci, udev, power tools) blocks forever. Upstream fix: 4d0e27041185
# "nouveau: check gsp->rm as well as gsp pointer before gcx ready"
# (drm-misc-fixes; carried by amd64-kernel-t2 as 9012). runpm=0 keeps the
# suspend path from running at all, whatever kernel is booted.
#
# Kept when the proprietary NVIDIA driver is installed (54-gpu-accel.sh /
# ncz-cuda-setup): that driver blacklists nouveau, so the option is inert, and
# if the NVIDIA DKMS build ever fails nouveau loads again and must not oops.
# The cost is that an Optimus dGPU driven by nouveau stays powered.
# 70-bootloader.sh adds nouveau.runpm=0 to the amd64 kernel command line too
# (assets/refind/ncz-refind-refresh-amd64.sh), for an initramfs without this
# file.
_ncz_late_arch=""
[ -r "$SRC/BUILD_ARCH" ] && _ncz_late_arch=$(tr -d '[:space:]' < "$SRC/BUILD_ARCH")
[ -n "$_ncz_late_arch" ] || _ncz_late_arch=$(uname -m 2>/dev/null)
case "$_ncz_late_arch" in
    amd64|x86_64)
        mkdir -p /target/etc/modprobe.d 2>/dev/null || true
        if cat > /target/etc/modprobe.d/ncz-nouveau-runpm.conf <<'NCZ_NOUVEAU_RUNPM'
# Written by the NCZ-OS installer (preseed/late.sh), amd64 only.
# nouveau runtime suspend oopses in nvkm_gsp_gcx_ready() on Turing/Ampere
# GPUs without GSP-RM firmware (7.3-rc5+, fixed upstream by 4d0e27041185);
# the GPU then never leaves "suspending" and PCI config reads hang.
# Inert when the proprietary NVIDIA driver is installed (nouveau is
# blacklisted). Remove only on a kernel that carries the upstream fix.
options nouveau runpm=0
NCZ_NOUVEAU_RUNPM
        then
            echo "[late] wrote /etc/modprobe.d/ncz-nouveau-runpm.conf (options nouveau runpm=0)"
        else
            echo "[late] WARN: could not write /etc/modprobe.d/ncz-nouveau-runpm.conf; the kernel command line still carries nouveau.runpm=0"
        fi
        ;;
    *)
        echo "[late] arch=$_ncz_late_arch: no nouveau runpm override (amd64 only)"
        ;;
esac
unset _ncz_late_arch
# NCZ-NOUVEAU-RUNPM-END

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
    for _bit in desktop browsers mgmt-container rescue-partition wallpaper-rotator cuda; do
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

# The medium has one unified installation target.  Keep the desktop layer marker
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
# The baked rootfs ships an EMPTY /etc/machine-id (regenerated per-instance
# by systemd on first boot), and dbus.service
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

# review A2 CRITICAL #2 fix: Mount /cdrom inside /target so post-install
# hooks can `apt-get install` from our offline mirror via file:///cdrom.
# Without this, FULL/THIN mode 10-our-kernel.sh + 70-bootloader.sh +
# 20-desktop.sh fail because they need offline pkgs.
#
# 2026-05-07 take8 (per review R78-INVALID-RELEASE-AUDIT): minimal
# NETINSTALL ships an EMPTY main/binary-arm64/Packages and removes
# /cdrom/.disk/base_installable so base-installer uses the HTTP mirror.
# 2026-05-08 netinstall-bootstrap keeps base_installable absent but adds a
# small non-empty regular Packages index for pkgsel/include. In that mode,
# file:///cdrom is valid for pkgsel/post-install package fallback.
# 2026-09-24: this had TWO amd64-migration leftovers in one line. The suite
# fallback was "resolute" -- an Ubuntu codename this project stopped targeting
# and which exists nowhere in the archive any more, so an unset
# NCZ_BASE_CODENAME silently produced a path that can never match. And
# binary-arm64 was hardcoded, so on amd64 the index was looked for under the
# wrong architecture and never found. Both now follow the real target.
NCZ_DEB_ARCH=$(uname -m 2>/dev/null)
case "$NCZ_DEB_ARCH" in
    aarch64) NCZ_DEB_ARCH=arm64 ;;
    x86_64)  NCZ_DEB_ARCH=amd64 ;;
esac
CDROM_REGULAR_INDEX=/cdrom/dists/${NCZ_BASE_CODENAME:-forky}/main/binary-${NCZ_DEB_ARCH}/Packages
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
    if [ -s /cdrom/ncz-payload/apt-repo/Packages ] || \
       [ -s /cdrom/ncz-payload/apt-repo/Packages.gz ] || \
       [ -s /cdrom/ncz-payload/apt-repo/Packages.xz ] || \
       [ -s /cdrom/ncz-payload/apt-repo/Packages.zst ]; then
        echo "deb [trusted=yes] file:///cdrom/ncz-payload/apt-repo /" \
            > /target/etc/apt/sources.list.d/cixmini-offline.list
        echo "    NCZ flat offline repository enabled"
    else
        rm -f /target/etc/apt/sources.list.d/cixmini-offline.list
        echo "WARN: /cdrom/ncz-payload/apt-repo has no Packages index; NCZ packages require configured network repositories"
    fi

    # Add file:///cdrom apt source to /target's sources.list so apt-get
    # install in chroot can find packages locally. [trusted=yes] bypasses
    # GPG (we don't sign our offline mirror Release file yet).
    cat > /target/etc/apt/sources.list.d/cixmini-cdrom.list <<CDROM_LIST
deb [trusted=yes] file:///cdrom ${NCZ_BASE_CODENAME:-forky} main
CDROM_LIST
    # During d-i the target clock can still be at the firmware default. APT
    # rejects the freshly generated medium Release file as "not valid yet" in
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
        # on the system Python 3.14 (they require <3.14,>=3.10) → postinst
        # exits 1 → dpkg leaves them HALF-CONFIGURED. That wedged dpkg state —
        # and, across red-dialog "Continue" retries, a still-running pip
        # postinst that keeps holding /var/lib/dpkg/lock-frontend — then makes
        # the REQUIRED 70-bootloader.sh bootloader install fail
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
        if [ "${NCZ_BASE_NAME:-}" != "Debian" ]; then
            echo "FATAL: NCZ_BASE_NAME='${NCZ_BASE_NAME:-unset}' -- only a Debian forky base is supported (no Ubuntu)" >&2
            ttymsg "FATAL: base is not Debian forky; installation refused (see late.log)."
            exit 1
        fi
        FW_PKGS="firmware-linux-free firmware-realtek firmware-misc-nonfree"
        chroot /target /usr/bin/apt-get install -y --allow-unauthenticated $FW_PKGS || { echo "WARN: firmware install failed ($FW_PKGS)"; true; }
        # r178: telnetd (doctrine #9 project lockout-prevention) from the OFFLINE
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
        # for the live MS-R1 test-board ModuleNotFoundError: No module named 'dbus'.
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
            # r201: one direct line to the telnetd that EXISTS (forky ships
            # /usr/sbin/telnetd, not in.telnetd); stale or tcpd-wrapped lines
            # that would exec a missing path are disabled by the shared helper.
            if [ -r /target/usr/local/lib/cix-installer/post-install/lib/telnet-inetd.sh ]; then
                chroot /target sh -c '. /usr/local/lib/cix-installer/post-install/lib/telnet-inetd.sh && ncz_telnet_inetd_fix ""' || echo "WARN: telnet inetd line repair failed"
            else
                chroot /target sh -c "grep -qE '^[[:space:]]*telnet[[:space:]]' /etc/inetd.conf 2>/dev/null || printf 'telnet\tstream\ttcp\tnowait\troot\t/usr/sbin/telnetd\ttelnetd\n' >> /etc/inetd.conf"
            fi
            chroot /target systemctl enable inetd 2>/dev/null || true
            chroot /target systemctl enable openbsd-inetd 2>/dev/null || true
            echo "[late r178] telnet enabled on :23 (doctrine #9): inetd.conf active + inetd service enabled"
        fi
    fi
    CDROM_BIND_MOUNTED=1
else
    echo "--- netinstall mode: cdrom has no regular deb component, skipping cdrom apt source ---"
    echo "    (post-install hooks rely on the Debian forky base source written by 23-base-apt-sources.sh)"
    CDROM_BIND_MOUNTED=0
fi

# 2026-05-07 take9 (per MS-R1 test-board take8 pkgsel cascade fail): pre-write apt
# retries config so post-install hooks 10-our-kernel.sh / 20-desktop.sh
# / etc retry transient DNS/network blips when fetching packages from
# the Debian archive. pkgsel itself runs BEFORE late.sh so this doesn't
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
# containing multiple nameservers. d-i + systemd chains symlink it to
# /run/systemd/resolve/stub-resolv.conf, but systemd-resolved isn't
# running inside the chroot — and the host stub points at only the
# DHCP-provided nameserver (one IP, often the LAN router). On flaky
# LAN DNS this single source dropped queries on the MS-R1 test board take8.
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
    for _bit in desktop browsers mgmt-container rescue-partition wallpaper-rotator cuda; do
        _v=0
        case ",$_ncz_comp," in *,"$_bit",*) _v=1 ;; esac
        printf '%s\n' "$_v" > "/target/etc/cix-installer/COMPONENTS_$_bit" 2>/dev/null || true
    done
    echo "[late] recovered component selection for post-install: $_ncz_comp"
fi

# Render the authoritative state written atomically by run-all.sh and the apt
# shim on finish-install's progress screen: the status line (db_progress INFO)
# on every heartbeat and, when a debconf channel exists, the bar itself
# (NCZ-BAR block below, docs/GPU-INSTALL-PROGRESS.md "Progress bar").
PROGRESS_STATE=/target/var/log/cix-install/progress.state
# NCZ_PROGRESS_UNITS: bar units late.sh owns. Only a patched finish-install
# (the legacy ISO builder) exports it; on the raw-image path ncz_bar_begin
# computes it at runtime. Normalise it HERE so every later test sees a number:
# the old `case "${NCZ_PROGRESS_UNITS:-0}"` guard left an UNSET variable unset
# (the default made it match nothing), and `[ "$NCZ_PROGRESS_UNITS" -gt 0 ]`
# then printed `sh: bad number` on every heartbeat of the r199 install.
case "${NCZ_PROGRESS_UNITS:-}" in
    ''|*[!0-9]*) NCZ_PROGRESS_UNITS=0 ;;
esac
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
# --- NCZ-HB-UNITS-BEGIN (extracted by build/test-gpu-install-progress.sh) --
# hb_units_for <event> <idx> <total> <pct> <plan-file> <units>
# Bar units owned by 07preseed that the current record has earned. run-all.sh
# writes progress.plan (index|hook|weight, one row per scheduled step); when
# it is present and matches <total>, each step gets bar room in proportion to
# its weight, so a long GPU/DKMS step (weight 12) ticks through its own share
# instead of parking at one slot. Without a usable plan: one equal slot per
# step, exactly as before. APT and GPU records carry a real in-step percent.
hb_units_for() {
    _u_ev="$1"; _u_idx="$2"; _u_tot="$3"; _u_pct="$4"; _u_plan="$5"; _u_units="$6"
    case "$_u_idx" in ''|*[!0-9]*) _u_idx=0 ;; esac
    case "$_u_tot" in ''|*[!0-9]*) _u_tot=0 ;; esac
    case "$_u_units" in ''|*[!0-9]*) _u_units=0 ;; esac
    case "$_u_pct" in ''|*[!0-9]*) _u_pct=0 ;; esac
    [ "$_u_pct" -gt 100 ] && _u_pct=100
    if [ "$_u_tot" -le 0 ] || [ "$_u_idx" -le 0 ] || [ "$_u_units" -le 0 ]; then
        echo 0; return 0
    fi
    case "$_u_ev" in
        DONE|WARN|FAIL|SKIP|COMPLETE|FINALIZE) _u_frac=100 ;;
        APT|GPU) _u_frac="$_u_pct" ;;
        *) _u_frac=0 ;;
    esac
    _u_out=""
    if [ -n "$_u_plan" ] && [ -r "$_u_plan" ]; then
        _u_out=$(awk -F'|' -v idx="$_u_idx" -v tot="$_u_tot" -v frac="$_u_frac" -v units="$_u_units" '
            $1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 { w[$1] = $3; tw += $3; n++ }
            END {
                if (n != tot || tw <= 0) exit 1
                b = 0; for (i = 1; i < idx; i++) b += w[i]
                v = int((b * 100 + w[idx] * frac) * units / (tw * 100))
                if (v > units) v = units
                print v
            }' "$_u_plan" 2>/dev/null) || _u_out=""
    fi
    if [ -z "$_u_out" ]; then
        _u_out=$(( ((_u_idx - 1) * 100 + _u_frac) * _u_units / (_u_tot * 100) ))
        [ "$_u_out" -gt "$_u_units" ] && _u_out="$_u_units"
    fi
    echo "$_u_out"
}

# hb_gpu_status <detail> <elapsed-seconds> <tick>
# The on-screen line for a GPU record. The elapsed clock and the moving marker
# go FIRST so the 150-column cut can never remove them, and they change on
# every heartbeat even while one large file compiles, so the line never looks
# frozen. ASCII only (newt draws anything else as <ERR>).
hb_gpu_status() {
    _g_el="$2"
    case "$_g_el" in ''|*[!0-9]*) _g_el=0 ;; esac
    case $(( ${3:-0} % 4 )) in
        0) _g_spin='*...' ;; 1) _g_spin='.*..' ;; 2) _g_spin='..*.' ;; *) _g_spin='...*' ;;
    esac
    printf '[%d:%02d %s] %s\n' $((_g_el / 60)) $((_g_el % 60)) "$_g_spin" "$1"
}
# --- NCZ-HB-UNITS-END ------------------------------------------------------
PROGRESS_PLAN=/target/var/log/cix-install/progress.plan

# --- NCZ-BAR-BEGIN (extracted by build/test-progress-bar-drive.sh) --------
# Drive finish-install's OWN progress bar through the debconf channel late.sh
# already holds (DEBCONF_OK=1: late_command runs as finish-install.d/07preseed,
# a child of finish-install.postinst, and inherits its confmodule fds).
#
# finish-install.postinst does `db_progress START 0 <N>` (N = entries in
# finish-install.d), runs each script, and does `db_progress STEP 1` after it.
# 07preseed is one of those N slots, so without help the bar parks at k/N for
# the whole post-install (k = scripts before 07preseed; 4/27 = 14% on the r199
# image). The legacy ISO builder patched the postinst to hand late.sh 100
# units (NCZ_PROGRESS_UNITS); the raw-image d-i loads the stock finish-install
# udeb, so nothing exports it any more.
#
# Runtime replacement, no installer patch: re-scale the same bar.
#   S = 40 * R (at least 800), R = N - k = STEP 1 calls finish-install still
#       makes (07preseed's own and every later script's); the later scripts
#       (initramfs refresh, log save, unmount) keep 1/40 of the bar
#   START 0 S with finish-install's own title, then SET B = ceil(k*S/N), the
#       point finish-install had reached (ceil: never lower)
#   late.sh owns B .. E = S - R (NCZ_PROGRESS_UNITS = E - B) and ends at E
#   finish-install's R remaining STEP 1 calls then land exactly on S (100%)
# cdebconf does not range-check SET/STEP and START only resets min/max/cur
# (cdebconf src/frontend.c, newt.c), so finish-install's accounting stays
# whole. Never STOP: that pops finish-install's bar (r130.8 defect B).
# The START redraw shows an empty bar for one frame before the SET that
# follows it at once; every value the bar settles on only moves forward.
#
# No channel (the KVM gate's unattended run, a manual late_command, a
# finish-install without 07preseed) leaves BAR_MODE=text: INFO text only.
NCZ_FINISH_PARTSDIR="${NCZ_FINISH_PARTSDIR:-/usr/lib/finish-install.d}"
NCZ_PROC_ROOT="${NCZ_PROC_ROOT:-/proc}"
BAR_MODE=text; BAR_SCALE=0; BAR_BASE=0; BAR_END=0
hb_last_units=0

# ncz_bar_in_finish_install [pid]
# 0 when <pid> (default: this shell) or an ancestor is finish-install's
# 07preseed, i.e. finish-install's bar is the one on screen.
ncz_bar_in_finish_install() {
    _f_pid="${1:-$$}"; _f_n=0
    while [ "$_f_n" -lt 16 ]; do
        case "$_f_pid" in ''|0|*[!0-9]*) return 1 ;; esac
        if [ -r "$NCZ_PROC_ROOT/$_f_pid/cmdline" ]; then
            _f_cmd=$(tr '\000' ' ' < "$NCZ_PROC_ROOT/$_f_pid/cmdline" 2>/dev/null)
            case "$_f_cmd" in *finish-install.d/07preseed*) return 0 ;; esac
        fi
        _f_pid=$(sed -n 's/^PPid:[[:space:]]*//p' "$NCZ_PROC_ROOT/$_f_pid/status" 2>/dev/null)
        _f_n=$((_f_n + 1))
    done
    return 1
}

# ncz_bar_geometry <finish-install.d> -> "S B E" (see above); 1 = unusable.
# Counts and orders entries exactly as finish-install.postinst does (its
# `ls | wc -l` count, its "$partsdir"/* loop order).
ncz_bar_geometry() {
    _g_dir="$1"; _g_n=0; _g_k=-1
    for _g_s in "$_g_dir"/*; do
        [ -e "$_g_s" ] || continue
        [ "$_g_s" = "$_g_dir/07preseed" ] && _g_k=$_g_n
        _g_n=$((_g_n + 1))
    done
    [ "$_g_n" -gt 0 ] || return 1          # divisor below
    [ "$_g_k" -ge 0 ] || return 1          # no 07preseed slot
    _g_r=$((_g_n - _g_k))
    _g_s=$((_g_r * 40)); [ "$_g_s" -lt 800 ] && _g_s=800
    _g_b=$(( (_g_k * _g_s + _g_n - 1) / _g_n ))
    _g_e=$((_g_s - _g_r))
    [ "$_g_e" -gt "$_g_b" ] || return 1
    echo "$_g_s $_g_b $_g_e"
}

# ncz_bar_begin: choose the bar mode once, before the heartbeat starts.
#   owned   a patched finish-install exported NCZ_PROGRESS_UNITS (STEP deltas)
#   rescale the runtime re-scale above (absolute SET)
#   text    no channel: INFO text only, the bar is not touched
ncz_bar_begin() {
    BAR_MODE=text
    case "${NCZ_PROGRESS_UNITS:-}" in ''|*[!0-9]*) NCZ_PROGRESS_UNITS=0 ;; esac
    if [ "${DEBCONF_OK:-0}" != 1 ]; then
        echo "[late/progress] bar: no debconf channel -- text-only"
        return 0
    fi
    if [ "${NCZ_PROGRESS_UNITS:-0}" -gt 0 ]; then
        BAR_MODE=owned
        echo "[late/progress] bar: finish-install allocated $NCZ_PROGRESS_UNITS units (owned)"
        return 0
    fi
    if ! ncz_bar_in_finish_install; then
        echo "[late/progress] bar: not running under finish-install.d/07preseed -- text-only"
        return 0
    fi
    if ! _b_geo=$(ncz_bar_geometry "$NCZ_FINISH_PARTSDIR"); then
        echo "[late/progress] bar: no 07preseed slot in $NCZ_FINISH_PARTSDIR -- text-only"
        return 0
    fi
    set -- $_b_geo
    _b_rc=0
    db_progress START 0 "$1" finish-install/progress/title 2>/dev/null \
        || db_progress START 0 "$1" nclawzero/install-progress 2>/dev/null \
        || _b_rc=$?
    if [ "$_b_rc" != 0 ]; then
        echo "[late/progress] bar: START rejected (rc=$_b_rc) -- text-only"
        return 0
    fi
    BAR_SCALE=$1; BAR_BASE=$2; BAR_END=$3
    db_progress SET "$BAR_BASE" 2>/dev/null || true
    db_progress INFO nclawzero/install-step 2>/dev/null || true
    NCZ_PROGRESS_UNITS=$((BAR_END - BAR_BASE))
    BAR_MODE=rescale
    echo "[late/progress] bar: rescaled finish-install bar to 0..$BAR_SCALE, late.sh owns $BAR_BASE..$BAR_END ($NCZ_PROGRESS_UNITS units)"
}

# ncz_bar_to <units>: move the bar to <units> of the owned range. Forward
# only; clamps to the range; a no-op in text mode.
ncz_bar_to() {
    _t="$1"
    case "$_t" in ''|*[!0-9]*) return 0 ;; esac
    [ "$BAR_MODE" = text ] && return 0
    hb_last_units=${hb_last_units:-0}
    [ "$_t" -gt "${NCZ_PROGRESS_UNITS:-0}" ] && _t=${NCZ_PROGRESS_UNITS:-0}
    [ "$_t" -gt "$hb_last_units" ] || return 0
    _t_rc=0
    if [ "$BAR_MODE" = rescale ]; then
        db_progress SET "$((BAR_BASE + _t))" 2>/dev/null || _t_rc=$?
    else
        db_progress STEP "$((_t - hb_last_units))" 2>/dev/null || _t_rc=$?
    fi
    if [ "${hb_step_diag_n:-0}" -lt 3 ]; then
        hb_step_diag_n=$(( ${hb_step_diag_n:-0} + 1 ))
        echo "[late/progress] bar#$hb_step_diag_n mode=$BAR_MODE units=$_t/$NCZ_PROGRESS_UNITS rc=$_t_rc"
    fi
    hb_last_units=$_t
    if [ "$BAR_MODE" = owned ] && [ -n "${NCZ_PROGRESS_CONSUMED_FILE:-}" ]; then
        printf '%s\n' "$hb_last_units" > "$NCZ_PROGRESS_CONSUMED_FILE" 2>/dev/null || true
    fi
    return 0
}

# hb_creep <last> <real> <step-end> -> next bar position while a step's own
# signal is not moving (one large file compiling, modpost, an initramfs
# rebuild, a slow download). Moves 1/24 of the way (at least one unit) toward
# a cap two thirds of the way from the real position to the end of the
# CURRENT step, so it never reaches the next step's share and real progress
# always has room left to show.
hb_creep() {
    _c_last="$1"; _c_real="$2"; _c_end="$3"
    case "$_c_last" in ''|*[!0-9]*) _c_last=0 ;; esac
    case "$_c_real" in ''|*[!0-9]*) _c_real=0 ;; esac
    case "$_c_end" in ''|*[!0-9]*) _c_end=0 ;; esac
    _c_cap=$(( _c_real + (_c_end - _c_real) * 2 / 3 ))
    if [ "$_c_end" -le "$_c_real" ] || [ "$_c_last" -ge "$_c_cap" ]; then
        echo "$_c_last"; return 0
    fi
    echo $(( _c_last + (_c_cap - _c_last + 23) / 24 ))
}

# hb_tick <heartbeat-number>: one heartbeat. Reads progress.state, refreshes
# the status line and moves the bar. The number drives the moving marker on
# the GPU line. Returns 0 always (no record yet is not an error).
hb_tick() {
    hb_tick_n="${1:-0}"
    [ -r "$PROGRESS_STATE" ] || return 0
    IFS='|' read -r hb_started hb_updated hb_event hb_phase hb_idx hb_total \
        hb_hook hb_pct hb_rc hb_detail < "$PROGRESS_STATE" || return 0
    [ -n "$hb_hook" ] || return 0
    case "$hb_idx" in ''|*[!0-9]*) hb_idx=0 ;; esac
    case "$hb_total" in ''|*[!0-9]*) hb_total=0 ;; esac
    case "$hb_started" in ''|*[!0-9]*) hb_started=0 ;; esac
    hb_now=$(date +%s 2>/dev/null || echo "$hb_updated")
    case "$hb_now" in ''|*[!0-9]*) hb_now=$hb_started ;; esac
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
        GPU)
            hb_status=$(hb_gpu_status "$hb_detail" "$hb_elapsed" "$hb_tick_n")
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
    # GPU records name a new build/stage every few seconds; the tty3 mirror
    # follows the record (not the per-tick clock) so it stays readable.
    if [ "$hb_key" != "${hb_last_key:-}" ]; then
        ttymsg "  → $hb_status"
        hb_last_key="$hb_key"
    fi
    # Return codes of the first few updates go to the log: db_try would hide
    # a dead channel (r249 showed ZERO heartbeat updates while progress.state
    # was correct), and "rejected" vs "accepted but not drawn" need different
    # fixes.
    hb_subst_rc=0; hb_info_rc=0
    if [ "${DEBCONF_OK:-0}" = 1 ]; then
        db_subst nclawzero/install-step STEP "$hb_status" 2>/dev/null || hb_subst_rc=$?
        db_progress INFO nclawzero/install-step 2>/dev/null || hb_info_rc=$?
    fi
    if [ "${hb_diag_n:-0}" -lt 3 ]; then
        hb_diag_n=$(( ${hb_diag_n:-0} + 1 ))
        echo "[late/progress] hb#$hb_diag_n subst_rc=$hb_subst_rc info_rc=$hb_info_rc event=$hb_event idx=$hb_idx/$hb_total hook=$hb_hook"
    fi
    [ "$BAR_MODE" != text ] && [ "${NCZ_PROGRESS_UNITS:-0}" -gt 0 ] \
        && [ "$hb_total" -gt 0 ] || return 0
    hb_last_units=${hb_last_units:-0}
    hb_target_units=$(hb_units_for "$hb_event" "$hb_idx" "$hb_total" "$hb_pct" \
        "$PROGRESS_PLAN" "$NCZ_PROGRESS_UNITS")
    case "$hb_target_units" in ''|*[!0-9]*) hb_target_units=0 ;; esac
    if [ "$hb_target_units" -gt "$hb_last_units" ]; then
        ncz_bar_to "$hb_target_units"
    else
        # Real signal flat (or behind a creep): creep inside this step only.
        # A later record with a lower in-step percent (a new apt transaction)
        # holds the bar; nothing here ever moves it back.
        hb_step_end=$(hb_units_for DONE "$hb_idx" "$hb_total" 100 \
            "$PROGRESS_PLAN" "$NCZ_PROGRESS_UNITS")
        ncz_bar_to "$(hb_creep "$hb_last_units" "$hb_target_units" "$hb_step_end")"
    fi
    return 0
}

# ncz_bar_finish: run-all has exited; fill the owned range so
# finish-install's remaining STEP 1 calls finish the bar at 100%.
ncz_bar_finish() {
    ncz_bar_to "${NCZ_PROGRESS_UNITS:-0}"
}
# --- NCZ-BAR-END -----------------------------------------------------------

set +e
ncz_bar_begin
# --- NCZ PROGRESS DIAGNOSTICS -------------------------------------------
# The bar advances only when ALL of these hold: DEBCONF_OK = 1, a bar mode
# other than text (NCZ-BAR block: a patched finish-install exported
# NCZ_PROGRESS_UNITS, or ncz_bar_begin re-scaled finish-install's bar), and
# hb_total > 0. A frozen bar on 2026-08-14 left only hb_total behind, and the
# r199 raw-image install logged NCZ_PROGRESS_UNITS=unset (the finish-install
# patch went away with the ISO builder in f40a8061).
# Log all of it, once, so the next frozen bar names its own cause.
#
# NO PIPE, and specifically NOT `tee`. MEASURED on the r243 KVM install: this
# block was piped through `tee -a "$LOG" >&2`, and d-i busybox has no tee
# applet --
#     /cdrom/ncz-payload/late.sh: line 550: tee: not found
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
    echo "[late/progress] BAR_MODE=$BAR_MODE scale=$BAR_SCALE base=$BAR_BASE end=$BAR_END"
    if [ "$BAR_MODE" != text ] && [ "${NCZ_PROGRESS_UNITS:-0}" -gt 0 ]; then
        echo "[late/progress] bar WILL advance"
    else
        echo "[late/progress] bar will NOT advance -- text-only degraded mode"
    fi
} 2>&1                               # $LOG is /target/var/log/... (line 23);
                                     # the bare /var/log path is the d-i ramdisk
                                     # and is DISCARDED at reboot -- that is why the
                                     # first KVM run produced no diagnostics at all.
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
hb_iter=0
# r250: the writer emitted 573 valid records while this loop logged nothing,
# so report, once, what the loop sees before any guard can skip it.
echo "[late/progress] hb loop start: PROGRESS_STATE=${PROGRESS_STATE:-<unset>} bar=$BAR_MODE"
while [ ! -s "$RUNALL_RC_FILE" ] && kill -0 "$RUNALL_PID" 2>/dev/null; do
    sleep 4
    hb_iter=$((hb_iter + 1))
    if [ "$hb_iter" -le 3 ] || [ "$hb_iter" = 10 ] || [ "$hb_iter" = 30 ]; then
        echo "[late/progress] hb iter=$hb_iter readable=$([ -r "$PROGRESS_STATE" ] && echo yes || echo no) exists=$([ -e "$PROGRESS_STATE" ] && echo yes || echo no) bar=$hb_last_units/$NCZ_PROGRESS_UNITS"
    fi
    hb_tick "$hb_iter"
done
# r252 final drain: run-all has exited; fill the owned bar range before the
# finalize text replaces it, then reap run-all's real rc.
ncz_bar_finish
wait "$RUNALL_PID"
WAIT_RET=$?
if [ -r "$RUNALL_RC_FILE" ]; then
    read -r RET < "$RUNALL_RC_FILE" || RET="$WAIT_RET"
else
    RET="$WAIT_RET"
fi
# cdebconf's confmodule uses RET as its own global response payload.  Keep the
# authoritative run-all result under a name that later db_* calls cannot
# overwrite (observed on amd64 as RET="OK", followed by BusyBox "bad number"
# and a false finish-install failure after an otherwise bootable install).
RUNALL_RET="$RET"

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
# proven live on the MS-R1 test board (persist across cold boot; /dev/aipu + 3 cores):
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
    # r186.1: $SRC (the install medium /ncz-payload mount) can be missing this file
    # even when the repo + the baked rootfs both have it — observed on the MS-R1 test board
    # r186 (cix-installer-late.log: FIX A ran, FIX B silently never fired,
    # "no CIXH4010 cores" -> unidentified hardware version 5 at boot,
    # /dev/aipu absent). Root cause is upstream in the squashfs/medium staging of
    # assets/kernel/modules-overlay into /ncz-payload; this fallback makes FIX B
    # resilient to that regardless: /target/usr/local/lib/cix-installer/assets
    # is populated from the BAKED image (confirmed present even when $SRC
    # lacked it) and is unioned from $SRC earlier in this script, so it is at
    # least as complete as $SRC. Mirrors the existing dual-candidate pattern
    # in post-install/80-npu.sh and 81-vpu.sh (medium path + already-staged path).
    # 2026-10-06: the Sky1 NPU driver is the vendor aipu.ko (cix-npu-driver-dkms,
    # built by 80-npu.sh into updates/dkms/; prebuilt r284 overlay at
    # assets/kernel/npu/<KVER>/aipu.ko). armchina_npu is the in-tree name, which
    # the Sky1 kernels leave unset, so the old armchina_npu-only lookup never
    # found anything on r282+ ("FIX B: no armchina_npu.ko overlay found").
    for _kv in $NPU_KVERS; do
        [ -d "/target/usr/lib/modules/$_kv" ] || { echo "[npu]   no /target modules dir for $_kv"; continue; }
        if find "/target/usr/lib/modules/$_kv" -name 'aipu.ko*' 2>/dev/null | grep -q .; then
            echo "[npu]   FIX B: aipu.ko already installed for $_kv"
            continue
        fi
        _ov=""
        for _cand in \
            "$SRC/assets/kernel/npu/$_kv/aipu.ko" \
            "/target/usr/local/lib/cix-installer/assets/kernel/npu/$_kv/aipu.ko" \
            "$SRC/assets/kernel/modules-overlay/$_kv/armchina_npu.ko" \
            "/target/usr/local/lib/cix-installer/assets/kernel/modules-overlay/$_kv/armchina_npu.ko"; do
            [ -f "$_cand" ] && { _ov="$_cand"; break; }
        done
        [ -n "$_ov" ] || { echo "[npu]   FIX B: no aipu.ko or armchina_npu.ko overlay found for $_kv (checked SRC + baked /target)"; continue; }
        _ovn=$(basename "$_ov")
        if install -D -m 0644 "$_ov" "/target/usr/lib/modules/$_kv/updates/$_ovn" 2>/dev/null; then
            in-target depmod -a "$_kv" 2>/dev/null || true
            echo "[npu]   FIX B: $_ovn ($_ov) -> /usr/lib/modules/$_kv/updates/ (+ depmod)"
        fi
    done
    # Auto-load on boot. 80-npu.sh owns /etc/modules-load.d/ncz-npu.conf and
    # lists aipu; this used to overwrite it with armchina_npu whenever that line
    # was missing, i.e. on every install, so the NPU never loaded and
    # systemd-modules-load failed on every boot. Only fill in a missing file.
    mkdir -p /target/etc/modules-load.d
    if [ ! -s /target/etc/modules-load.d/ncz-npu.conf ]; then
        printf '# NCZ: Cix Sky1 / Zhouyi v3 NPU driver (vendor aipu.ko)\naipu\n' \
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
# instead of rebooting (observed on the MS-R1 test board, 2026-07-03). By the time we get here
# run-all.sh's EXIT trap has already installed the bootloader, so this ESP
# check is authoritative. FINALIZE_OK = "install succeeded OR is bootable".
# ncz_bootable: TRUE iff rEFInd is on the ESP — INDEPENDENT of efibootmgr /
# efivars. 70-bootloader writes BOTH the arch's fallback binary
# (/EFI/BOOT/BOOTX64.EFI on amd64, /EFI/BOOT/BOOTAA64.EFI on arm64) and
# /EFI/BOOT/refind.conf BEFORE its best-effort efibootmgr NVRAM write, and
# hard-exits if the binary is empty. On Sky1 METAL there is NO efivars, so
# efibootmgr fails and RET!=0 — but the box still boots via the fallback
# binary. Key the finish/reboot decision on rEFInd-present, never on
# efibootmgr success.
# NCZ-BOOTABLE-BEGIN
# ncz_boot_binary: the firmware fallback path rEFInd is installed to on this
# target architecture (amd64: BOOTX64.EFI, arm64: BOOTAA64.EFI).
ncz_boot_binary() {
    case "${NCZ_DEB_ARCH:-}" in
        amd64) echo /target/boot/efi/EFI/BOOT/BOOTX64.EFI ;;
        arm64) echo /target/boot/efi/EFI/BOOT/BOOTAA64.EFI ;;
        *)     echo "/target/boot/efi/EFI/BOOT/BOOTX64.EFI or BOOTAA64.EFI" ;;
    esac
}
ncz_bootable() {
    # Both refresh scripts write the arch's fallback binary and then
    # refind.conf before any efibootmgr call, so the pair is the bootability
    # evidence. 2026-09-15: was arm64-only, which failed every amd64 finish.
    # 2026-10-14: the arch decides which binary counts (a refind.conf alone,
    # or the other arch's binary, is not a bootable install) and both must be
    # non-empty.
    [ -s /target/boot/efi/EFI/BOOT/refind.conf ] || return 1
    # An entry with an empty root= boots into an initramfs that waits forever.
    if grep -E 'root=(PARTUUID=|UUID=)?([" ]|$)' /target/boot/efi/EFI/BOOT/refind.conf >/dev/null 2>&1; then
        echo "[late] refind.conf has a boot entry with an empty root= -> not bootable" >&2
        return 1
    fi
    case "${NCZ_DEB_ARCH:-}" in
        amd64) [ -s /target/boot/efi/EFI/BOOT/BOOTX64.EFI ] ;;
        arm64) [ -s /target/boot/efi/EFI/BOOT/BOOTAA64.EFI ] ;;
        *)     [ -s /target/boot/efi/EFI/BOOT/BOOTX64.EFI ] || [ -s /target/boot/efi/EFI/BOOT/BOOTAA64.EFI ] ;;
    esac
}
# NCZ-BOOTABLE-END
# ncz_force_reboot: drive the reboot OURSELVES rather than trusting
# finish-install's menu loop. On Sky1 METAL the priority=critical finish-install
# did NOT auto-reboot after our late_command returned 0 — it dropped to the d-i
# MAIN MENU (operator report, MS-R1 test board, 2026-07-03/04). r180 proved a direct reboot
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
    for _f in /var/log/syslog /var/log/partman /var/log/hardware-summary \
              /var/log/diag-console.log /var/log/diag-sshd.log; do
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
{ [ "$RUNALL_RET" = "0" ] || ncz_bootable; } && FINALIZE_OK=1

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
        if [ "${RUNALL_RET:-0}" = "0" ]; then
            RUNALL_RET=1
        fi
        FINALIZE_OK=0
        _ncz_root_mode_ok=0
        echo "[late round2/7de5ce6] FATAL: /target root mode still $_ncz_root_mode_recheck after corrective chmod — refusing to boot"
    fi
fi

# r130.8 (defect B): do NOT call db_progress STOP. The bar on screen is
# finish-install's own (ncz_bar_begin only re-scaled it), so STOP would pop it -
# on the success path that corrupted finish-install's accounting and bounced
# d-i back to the preseed/menu instead of the "Installation complete" screen.
# ncz_bar_finish already left the bar at the end of late.sh's range.
db_try db_subst nclawzero/install-step STEP "nclawzero post-install complete - finalizing..."
db_try db_progress INFO nclawzero/install-step
ttymsg "post-install hooks finished (rc=$RUNALL_RET); finalizing apt sources + bootloader."

# review A2 fix: don't leave bind-mount around after late_command finishes
if [ "${CDROM_BIND_MOUNTED:-0}" = "1" ]; then
    umount /target/cdrom 2>&1 || true
    rmdir /target/cdrom 2>&1 || true
fi
echo "target run-all.sh exited: $RUNALL_RET"

# r130 fix (MrSBC/COS feedback 2026-06-23): strip ALL CD-ROM apt sources from
# /target before reboot. The offline mirror sources are required DURING
# post-install (file:///cdrom for our pool; d-i apt-setup may also add a
# `deb cdrom:[...]` line), but once the install media is ejected they make the
# installed system's `apt-get update` fail. Remove them as the last apt action.
echo "--- stripping CD-ROM apt sources from /target before reboot ---"
# r130.2 fix (review of an MS-R1 test-board install red-error): this step runs in the
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

# r130 fix: the INSTALLED system's apt sources. Previously 20-desktop overwrote
# sources.list with a network line that survived the cdrom strip; r130 made
# 20-desktop install OFFLINE from the bundled pool, so without this the strip
# would leave an EMPTY sources.list. The profile-correct base repo (Debian
# forky, the only allowed base) is the signed deb822 file
# /etc/apt/sources.list.d/ncz-base.sources written by
# post-install/23-base-apt-sources.sh, so sources.list itself stays empty.
# Rule since 2026-10-08: no Ubuntu archive is ever written here.
if [ "${NCZ_BASE_NAME:-}" != "Debian" ]; then
    echo "FATAL: NCZ_BASE_NAME='${NCZ_BASE_NAME:-unset}' -- only a Debian forky base is supported (no Ubuntu)" >&2
    ttymsg "FATAL: base is not Debian forky; installation refused (see late.log)."
    exit 1
else
    echo "--- ${NCZ_BASE_NAME} base: leaving sources.list to the profile deb822 source ---"
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

# Final ldconfig, once, after every package/dkms/post-install step has finished. On the first
# boot of 18e8a14 ldconfig.service failed ("Renaming of /etc/ld.so.cache~ to /etc/ld.so.cache
# failed: No such file or directory"): the boot clock still read the image build date, systemd
# judged /etc older than /usr and ran ldconfig.service while something else was also rebuilding
# the cache. Build the cache here and stamp /etc and /var as up to date (mtime in the future is
# harmless) so ConditionNeedsUpdate= skips it, and let the unit tolerate exit status 1 if it
# ever does run.
if [ "$FINALIZE_OK" = "1" ]; then
    in-target ldconfig 2>/dev/null || true
    in-target sh -c 'touch -d "+2 days" /etc/.updated /var/.updated' 2>/dev/null || true
    mkdir -p /target/etc/systemd/system/ldconfig.service.d
    printf '[Service]\nSuccessExitStatus=1\n' > /target/etc/systemd/system/ldconfig.service.d/10-ncz-tolerate-race.conf
fi

# r56: loud REMOVE-USB banner so user sees it on every TTY before d-i reboots.
# d-i preseed (reboot_in_progress no longer set to note) will then prompt the
# user to dismiss before the actual reboot fires.
# First-boot GPU notice (docs/GPU-INSTALL-PROGRESS.md, "First boot"): when a
# DKMS kernel-module build is still outstanding (dpkg left a *-dkms package
# unconfigured), say on the last screen what first boot will do with it: run
# it before the login screen (a build that may succeed), or skip it because
# it already failed here with a compiler error (the reason line from
# make.log, and what retries it). Empty for every
# machine with nothing to build, which then sees the unchanged dialog.
NCZ_GPU_NOTE=""
_ncz_dp=/target/usr/local/lib/cix-installer/post-install/lib/dkms-pending.sh
if [ -r "$_ncz_dp" ]; then
    NCZ_GPU_NOTE=$( . "$_ncz_dp" 2>/dev/null && ncz_firstboot_gpu_notice /target 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/ *$//' )
fi
if [ -n "$NCZ_GPU_NOTE" ]; then
    echo "[late] first-boot GPU notice: $NCZ_GPU_NOTE"
    ttymsg "GPU: $NCZ_GPU_NOTE" 2>/dev/null || true
else
    echo "[late] first-boot GPU notice: none (no DKMS build outstanding)"
fi
if [ "$FINALIZE_OK" = "1" ]; then
    BANNER="\n\n  ============================================================\n  \n    ${NCZ_RELEASE_LABEL} INSTALL COMPLETE\n    \n    >>> REMOVE THE USB STICK NOW <<<\n    \n    Then press Enter on the next dialog to reboot.\n    \n    If you forget, the system will boot back into the\n    installer (USB has higher boot priority than NVMe).\n  \n  ============================================================\n"
    for tty in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/console; do
        if [ -w "$tty" ]; then
            printf '%b' "$BANNER" >> "$tty" 2>/dev/null || true
            [ -n "$NCZ_GPU_NOTE" ] && printf '  %s\n\n' "$NCZ_GPU_NOTE" >> "$tty" 2>/dev/null
        fi
    done
    # r135: BLOCKING graphical dialog so the user removes the USB before the
    # reboot. priority=critical (r134) means d-i may reboot without its own
    # final prompt, and the TTY banner above is only visible on Alt+F3. This
    # pops a note on the same frontend d-i uses and waits for Continue.
    # r162 (review): skip the blocking remove-media dialog on unattended
    # installs (qemu harness / automated runs pass ncz_unattended=1). Metal
    # USB installs keep the full stop — that dialog is the whole point there.
    #
    # r180/r181 (MS-R1 test-board metal fix): d-i's priority=critical finish-install did NOT
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
            _ncz_rm_tpl=nclawzero/remove-media
            if [ -n "$NCZ_GPU_NOTE" ]; then
                _ncz_rm_tpl=nclawzero/remove-media-gpu
                db_try db_subst "$_ncz_rm_tpl" GPUNOTE "$NCZ_GPU_NOTE"
            fi
            db_try db_fset "$_ncz_rm_tpl" seen false
            db_try db_input critical "$_ncz_rm_tpl"
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
    if [ "$RUNALL_RET" != "0" ]; then
        echo "[late r155] post-install rc=$RUNALL_RET but rEFInd present on the ESP -> system is bootable; exiting 0 (no red error)"
        ttymsg "install complete (some optional hooks failed, system is bootable)" 2>/dev/null || true
    fi
    exit 0
fi
# r174 (#6 review): NOT bootable — do NOT reassert reboot; force a NONZERO exit
# even when run-all.sh returned 0, so finish-install surfaces the failure and
# does NOT reboot into an unbootable install.
echo "[late r174] no rEFInd at $(ncz_boot_binary) (with EFI/BOOT/refind.conf) -> install is NOT bootable; refusing clean reboot"
# r203: exit non-zero robustly. This must surface a failure to finish-install,
# but `exit $RET` assumed RET is numeric — if RET is non-numeric (observed once
# as the string "OK") the sh builtin dies with "exit: Illegal number: OK",
# which STILL exits non-zero but spams a confusing error over the real cause.
# Force a clean numeric exit: any non-"0"/non-numeric RET (including empty)
# reports as 1; a genuine numeric non-zero RET is passed through unchanged.
case "$RUNALL_RET" in
    0)          exit 1 ;;                       # bootloader missing despite rc=0
    ''|*[!0-9]*) exit 1 ;;                      # non-numeric/empty RET
    *)          exit "$RUNALL_RET" ;;           # genuine numeric failure code
esac
