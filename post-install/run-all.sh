#!/bin/bash
# run-all.sh — orchestrate the numbered post-install hooks.
#
# Invoked from preseed late_command via in-target. Runs in chroot
# context against the freshly-installed Debian Bookworm rootfs.
#
# 2026-05-03 — TWO-PHASE FAIL-TOLERANT PATTERN:
#
# Phase 1: required hooks (kernel install). MUST succeed or the
#          system is unbootable. set -e applies here.
# Phase 2: optional hooks (desktop, boot-splash, branding,
#          ssh, claude-code, cix proprietary, quadlet shim). Each
#          hook runs in isolation; failures get logged + recorded
#          but DON'T abort.
# Phase 3: bootloader hook (70-bootloader.sh). Runs ALWAYS via the
#          EXIT trap, even if Phase 2 had failures. Without this,
#          earlier r6/r7 installs left systems with stale loader
#          entries from prior installs because run-all.sh aborted
#          before 70-bootloader could clean+rewrite.
#
# Hook output is logged to /var/log/cix-install/<hook>.log on the
# target so a successful boot can show "what was done" — useful
# for demo + debugging.

LOGDIR=${NCZ_LOGDIR:-/var/log/cix-install}
HOOK_DIR=${NCZ_HOOK_DIR:-/usr/local/lib/cix-installer/post-install}
mkdir -p "$LOGDIR"
cd "$HOOK_DIR" || exit 1

# Every hook that shells out to apt inherits this. Without it debconf tries
# Dialog, then Readline, then Teletype, fails all three inside the d-i chroot,
# and emits three "debconf: unable to initialize frontend" lines per package —
# hundreds of lines of noise across the desktop layer that bury the warnings
# that actually matter (this is how the missing-curl and missing-timesyncd
# failures went unnoticed until the 2026-08-02 log audit). Individual hooks
# that already set it explicitly are unaffected.
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
# Track failures across phases for end-of-run summary.
FAILED_HOOKS=""
CRITICAL_HOOK_FAILURES=""
# These hooks own the minimum release contract: boot-to-login, native
# networking, and a populated rescue partition. They still run in the
# fail-tolerant phase so the bootloader/diagnostics always execute, but a
# failure is propagated to d-i after those recovery affordances are written.
CRITICAL_OPTIONAL_HOOKS_RE='^(20-desktop|19-sinty-nm|55-greeter|60-boot-splash|72-rescue-partition)\.sh$'
# Phase 1 must complete before the EXIT trap is allowed to touch the ESP.
REQUIRED_PHASE_OK=0
# r156: baked-image mode — generic hooks already ran at build time; run
# ONLY machine-specific hooks at install (fstab/rescue/bootloader/diag).
NCZ_BAKED=0
[ -f /usr/local/lib/cix-installer/BAKED ] && NCZ_BAKED=1
[ -f /etc/ncz-baked ] && NCZ_BAKED=1   # survives late.sh rm -rf of cix-installer
# r184: the CIX proprietary userland + NPU-userspace hooks were NEVER running on
# a fresh baked install — they're not in build-squashfs-layers.sh BASE_HOOKS (so
# not baked into base.squashfs) and the baked-mode filter below only whitelisted
# fstab/rescue. Result: no cix SDK, no /opt/python3.11, no /opt/ncz/embed-venv,
# no libnoe → NPU dark from Python (confirmed absent on .66 r180). These hooks
# are machine-AGNOSTIC userspace that only need the staged ISO assets (not the
# hardware), and running them at install-time (rather than baking) avoids the
# base.squashfs rebuild + the LAYER-COHERENCE delta-rebuild trap (25 changes the
# dpkg package set; baking it would force rebuilding every role delta). The
# assets they read are on the ISO and union-synced into /target by late.sh:
#   25-cix-proprietary → cix userland + stages libnoe.so + libnoe/NOE_Engine
#                        cp311/cp312 wheels to /usr/share/cix/{lib,pypi}
#                        (assets/cix-debs/cix-noe-umd_2.0.2, on the ISO)
#   46-python311       → relocatable CPython 3.11 at /opt/python3.11 + uv
#                        (assets/python311, on the ISO) — the libnoe wheel only
#                        ships cp311/cp312 .so, so a 3.11 venv is REQUIRED (the
#                        resolute system python is 3.14 and cannot import libnoe)
#   47-embedkit        → /opt/ncz/embed-venv (py3.11) + installs the libnoe wheel;
#                        ship-critical libnoe import smoke. Ordered AFTER 25+46.
#   80-npu             → validated armchina_npu.ko (ARCH_V3 fix) → updates/ for
#                        the 7.0.x-next kernel (assets/kernel/modules-overlay, on
#                        ISO) + the MS-R1 ACPI SSDT (idempotent, see below).
#   81-vpu             → validated amvx.ko (vb2 q->lock fix) → updates/ for the
#                        7.0.x-next kernel (assets/kernel/modules-overlay, on ISO)
# Hooks run in sorted order → 25, 34-fstab, 46, 47, 72-rescue, 80, 81 (deps
# satisfied: 25+46 both precede 47).
#
# r187.1: 80-npu WAS deliberately excluded here (comment used to say adding it
# would double-run the SSDT/KMD install already done by preseed/late.sh's
# ncz_npu_install_time) — but that pre-chroot install-time path turned out to
# be unreliable: on .66 r187, late.sh's FIX B silently failed to write
# armchina_npu.ko to /target/usr/lib/modules/$KVER/updates/ for the NEXT kernel
# (no error, no log line — likely an environment quirk of running against
# /target from OUTSIDE chroot during d-i, before the target filesystem is
# fully assembled), while the near-identical 81-vpu.sh call for amvx.ko — same
# overlay mechanism, same install -D pattern, but running INSIDE chroot via
# run-all.sh — succeeded every time. Root cause of the "unidentified hardware
# version number: 5" / no /dev/aipu failure on a fresh install, even with the
# ARCH_V3 kernel-config fix (053b5ce) and the overlay file itself both correct
# and present. Fix: run 80-npu here too, in the same reliable chroot context
# that already works for VPU. Its SSDT step is idempotent (checks the initrd's
# leading CPIO magic bytes and skips if late.sh already prepended it), so
# running both is safe — it will not double-inject.
#   26-gpu-default-open → REQUIRED after 25: 25 installs the CIX proprietary
#                        GPU userland (cix-gpu-umd libmali/libgbm/libEGL under
#                        /opt/cixgpu-*), whose ld.so.conf.d entries SHADOW Mesa.
#                        libmali is built for the mali_kbase KMD, but this image
#                        runs in-tree panthor -> "No mali devices found" and the
#                        broken CIX libgbm makes native Panfrost GL fail, so Mesa
#                        falls back to zink-over-panvk reporting only GL 2.1.
#                        26 demotes the CIX ld paths + dead Vulkan ICD/WSI layer,
#                        restoring native Panfrost OpenGL 3.1 (verified .66 metal
#                        2026-07-04). WITHOUT this, baked installs shipped zink-2.1
#                        and GL screensavers/apps mis-rendered. Runs right after 25.
# r204: the DESKTOP + branding + session hooks below were MISSING from this
# list, so on a --mode full d-i install (which writes /etc/ncz-baked ->
# NCZ_BAKED=1, build-iso-di.sh) the Phase-2 baked filter dropped them and
# 20-desktop.sh never ran -> ncz-singularity-desktop never apt-installed from
# the offline pool -> a booted system with NO Singularity, no greeter, no
# branding. --mode full ships a BASE rootfs (desktop is NOT baked in; comment
# build-iso-di.sh:527), so these are genuinely per-install machine hooks and
# MUST run even under the baked flag. All are variant-aware (self-skip on the
# server SKU), so adding them is a no-op for server installs.
# r262 (2026-08-18): NINE MORE HOOKS WERE MISSING FROM THIS LIST, and the
# consequences were shipping. Same failure as the r204 note above, which is the
# point: this is an ALLOWLIST, so every hook added to post-install/ is silently
# dropped from baked installs until somebody remembers to edit this regex.
# Nobody remembers.
#
# Measured on O6N running a v8 baked install (/etc/ncz-baked present, so
# NCZ_BAKED=1), by diffing the hooks on disk against the two lists:
#
#   12-sky1-firmware   dropped from REQUIRED by the baked filter below
#   15-mesa-sky1-pin   16-mesa-gpu-2613    23-base-apt-sources
#   27-net-caps        32-quadlet-shim     33-network
#   39-usb-gpt-autofix 44-rtc-sync
#
# Two were confirmed broken ON THE BOARD, not merely absent from a list:
#   - 12-sky1-firmware never ran, so /lib/firmware held ZERO *.fwb while the
#     16 blobs sat staged and unused in the installer asset tree. The VPU
#     could not decode or encode anything. Copying the firmware by hand and
#     reloading amvx made H.264 decode, H.264 encode and HEVC encode all work
#     immediately -- the hardware and driver were always fine.
#   - 44-rtc-sync never ran, so hwclock was absent and the RTC stayed at the
#     2024 firmware default. Every fresh flash booted ~2 years in the past.
#
# Neither produced a single line in /var/log/cix-install/ -- there is no log
# for a hook that was never invoked, which is exactly why this went unnoticed
# across multiple ISO revisions.
MACHINE_HOOKS_RE="^(12-sky1-firmware|15-mesa-sky1-pin|16-mesa-gpu-2613|20-desktop|21-flatpak-arch-filter|22-display-fix|22-locale-gen|23-base-apt-sources|23-locale-env|24-apt-sources|25-cix-proprietary|26-gpu-default-mali|27-net-caps|31-remote-access|32-quadlet-shim|19-sinty-nm|33-network|34-fstab|35-fstrim-fix|35-ssh|36-telemetry|37-failsafe-access|37-ntp-hostname|38-recovery-container|39-usb-gpt-autofix|40-claude-code|41-usb2-rescan|43-hw-quirks|44-rtc-sync|45-wallpaper-rotator|46-ncz-cli|46-python311|47-embedkit|47-llm-stack|48-server-variant|50-brand|52-vivaldi|53-chrome|55-greeter|56-icon-theme|57-qotd|58-boot-hygiene|59-desktop-curate|60-boot-splash|72-rescue-partition|79-dkms-prep|80-npu|81-vpu|82-mali-gpu|83-panthor-gpu|83-vpu-ffmpeg|84-vpu-mpv|84-vpu-vaapi|85-power-perf-mode|86-cix-dkms-register|87-mpam-cache-partition|88-noe-umd-venv|89-npu-embed-server|91-dbus-broker|92-apparmor-enable|93-zram-swap|94-dracut-config|95-console-font-autosize)\.sh$"


# r55+: surface progress on /dev/tty3 (the d-i log VT — Alt+F3 during install)
# so users can watch hooks tick by instead of staring at d-i's stuck dialog.
# Best-effort: if tty3 isn't writable (post-reboot, or unusual context),
# falls back silently.
TTY=${NCZ_TTY:-/dev/tty3}
tty_msg() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >"$TTY" 2>/dev/null || true
}
# r141: install the per-package apt-get progress shim ahead of PATH.
NCZ_SHIM=/tmp/ncz-apt-shim; mkdir -p "$NCZ_SHIM" "$LOGDIR" 2>/dev/null || true
SHIMSRC="$(dirname "$0")/apt-progress-shim"
if [ "${NCZ_DISABLE_APT_SHIM:-0}" != 1 ] && [ -f "$SHIMSRC" ]; then
    cp "$SHIMSRC" "$NCZ_SHIM/apt-get"
    chmod 0755 "$NCZ_SHIM/apt-get"
    export PATH="$NCZ_SHIM:$PATH"
    tty_msg "per-package apt progress shim active (Alt+F3)"
fi

# Build the execution plan once. This is the authoritative list used both for
# execution and progress reporting; late.sh must not try to reconstruct it from
# every numbered script in the directory.
PHASE0_HOOKS=$(ls 0[0-9]-*.sh 2>/dev/null | sort || true)
REQUIRED_HOOKS=$(ls [0-9][0-9]-*.sh 2>/dev/null | sort | \
    grep -E '^(10-our-kernel|11-fix-cixmini-boot|12-sky1-firmware|33-network)\.sh$' || true)
if [ "$NCZ_BAKED" = 1 ]; then
    # 12-sky1-firmware and 33-network MUST SURVIVE THE BAKED FILTER.
    #
    # They are excluded from OPT_HOOKS by the grep -vE below (they are REQUIRED,
    # not optional), so if the baked filter also drops them from REQUIRED they
    # land in NO list at all and never run. Adding them to MACHINE_HOOKS_RE
    # does nothing, because that regex only filters OPT_HOOKS -- which already
    # excluded them. That is exactly what happened: measured on O6N running
    # v10, the orphan audit reported
    #
    #     ORPHAN: 12-sky1-firmware.sh
    #     ORPHAN: 33-network.sh
    #
    # and /lib/firmware held zero *.fwb, so the VPU could not decode or encode.
    #
    # Neither is baked into the rootfs: 12 copies Sky1 firmware out of the
    # installer asset tree into /lib/firmware, and 33 writes per-machine
    # network config. Both are genuinely per-install work and must run under
    # --mode full like any other machine hook.
    REQUIRED_HOOKS=$(printf '%s\n' $REQUIRED_HOOKS | \
        grep -E '^(10-our-kernel|11-fix-cixmini-boot)\.sh$' || true)
fi
# 12-sky1-firmware and 33-network are NOT excluded here any more.
#
# They used to be excluded because they were REQUIRED. Under NCZ_BAKED the
# required list is trimmed to the kernel hooks, so excluding them here left
# them in NO list at all and they never ran -- /lib/firmware held zero *.fwb
# and the VPU could not decode.
#
# The obvious repair, promoting them back into the baked REQUIRED list, was
# WORSE and shipped in v11: the required phase is fatal, and 33-network exits 1
# by design on this SKU (see its own header -- it requires NetworkManager,
# which 19-sinty-nm.sh PURGES in favour of sinty-nmd). Every v11 install died
# with "33-network.sh FAILED rc=1 -- install aborts" at the finish-install
# step. Measured on O6N 2026-08-18.
#
# Correct placement is the FAIL-TOLERANT phase: they are per-machine work that
# must run, but neither should be able to abort an otherwise good install.
# MACHINE_HOOKS_RE already lists both.
OPT_HOOKS=$(ls [0-9][0-9]-*.sh 2>/dev/null | sort | \
    grep -vE '^(0[0-9]|10-our-kernel|11-fix-cixmini-boot|70-bootloader|99-diagnostics)\.sh$' || true)
if [ "$NCZ_BAKED" = 1 ]; then
    OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -E "$MACHINE_HOOKS_RE" || true)
fi
# r303: install-time component toggle (see preseed/component-selector.sh). The
# chooser writes one-bit-per-toggle files at /usr/local/lib/cix-installer/
# COMPONENTS_<name> (0 or 1) AND a single comma-separated COMPONENTS file. This
# block skips hooks whose component was toggled OFF. The mapping is explicit
# (not regex-derived) so the relationship between a toggle and its hooks is
# readable in one place. Lines that map a hook to a toggle that no chooser
# currently writes are inert (no skipping).
COMP_FILE=/usr/local/lib/cix-installer/COMPONENTS
[ -r "$COMP_FILE" ] || COMP_FILE=/etc/cix-installer/COMPONENTS
[ -r "$COMP_FILE" ] || COMP_FILE=/var/lib/cix-components/COMPONENTS
_CDESKTO=1; _CBRW=1; _CMGMT=1; _CRESC=1; _CWP=1
if [ -r "$COMP_FILE" ]; then
    _ck=$(tr -d ' \t\r\n' < "$COMP_FILE" 2>/dev/null || true)
    case ",$_ck," in *",desktop,"*)            :;; *) _CDESKTO=0;; esac
    case ",$_ck," in *",browsers,"*)           :;; *) _CBRW=0;; esac
    case ",$_ck," in *",mgmt-container,"*)     :;; *) _CMGMT=0;; esac
    case ",$_ck," in *",rescue-partition,"*)   :;; *) _CRESC=0;; esac
    case ",$_ck," in *",wallpaper-rotator,"*)  :;; *) _CWP=0;; esac
else
    # NOT a benign default. Until r309 the component-selector wrote its record
    # to /target during preseed/early_command, before partman had mounted the
    # real root there, so the record was destroyed and this branch ran on every
    # install -- silently re-enabling every component the operator had just
    # deselected (measured on .66, 2026-08-22: full desktop installed after
    # desktop+browsers were explicitly unticked). Be loud: a missing record is
    # a defect in the install pipeline, not an operator choice.
    echo "  WARNING: no COMPONENTS record found (checked /usr/local/lib/cix-installer," >&2
    echo "           /etc/cix-installer, /var/lib/cix-components) -- assuming ALL" >&2
    echo "           components enabled. If the operator deselected anything at" >&2
    echo "           install time, that selection has been LOST." >&2
fi
# When desktop is OFF, skip the desktop-only hooks (anything that touches
# /opt/singularity, greetd, labwc, or the wallpaper stack). The browsers
# toggle only does anything when desktop is ON; OFF+desktop is the only
# browser-skip path the user explicitly asked for.
# DESKTOP_FILTER: drop desktop-only hooks when desktop is OFF.
# NOTE: 95-console-font-autosize.sh is deliberately NOT in this list. It sizes
# the TEXT CONSOLE font to the panel (ter-132n on 2160p), which matters MOST on
# a console-only install -- skipping it there left 8x16 text on a 4K display.
# It was in the skip list until 2026-08-22, harmless only because the component
# selection was being lost and desktop was therefore never actually OFF.
_SKIP_DESKTOP_RE='^(20-desktop|22-display-fix|45-wallpaper-rotator|50-brand|52-vivaldi|53-chrome|55-greeter|56-icon-theme|57-qotd|59-desktop-curate|60-boot-splash|84-vpu-mpv|84-vpu-vaapi|85-power-perf-mode|89-npu-embed-server)\.sh$'
# Per-toggle skips (work whether desktop is ON or OFF).
_SKIP_BROWSERS_RE='^(52-vivaldi|53-chrome)\.sh$'
_SKIP_MGMT_RE='^(38-recovery-container)\.sh$'
_SKIP_RESCUE_RE='^(72-rescue-partition)\.sh$'
_SKIP_WALLPAPER_RE='^(45-wallpaper-rotator)\.sh$'
# Audit every per-component skip so the install log records what was dropped
# (and a board-week-later audit can find it). MAX_RETENTION=mirror.
_tty_skip() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >"$TTY" 2>/dev/null || true; }
if [ "$_CDESKTO" = 0 ] && [ -n "$OPT_HOOKS" ]; then
    _drop=$(printf '%s\n' $OPT_HOOKS | grep -E "$_SKIP_DESKTOP_RE" || true)
    if [ -n "$_drop" ]; then
        _tty_skip "component-selector: desktop OFF — skipping:$_drop"
        OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -vE "$_SKIP_DESKTOP_RE" || true)
    fi
fi
if [ "$_CBRW" = 0 ] && [ -n "$OPT_HOOKS" ]; then
    _drop=$(printf '%s\n' $OPT_HOOKS | grep -E "$_SKIP_BROWSERS_RE" || true)
    if [ -n "$_drop" ]; then
        _tty_skip "component-selector: browsers OFF — skipping:$_drop"
        OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -vE "$_SKIP_BROWSERS_RE" || true)
    fi
fi
if [ "$_CMGMT" = 0 ] && [ -n "$OPT_HOOKS" ]; then
    _drop=$(printf '%s\n' $OPT_HOOKS | grep -E "$_SKIP_MGMT_RE" || true)
    if [ -n "$_drop" ]; then
        _tty_skip "component-selector: mgmt-container OFF — skipping:$_drop"
        OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -vE "$_SKIP_MGMT_RE" || true)
    fi
fi
if [ "$_CRESC" = 0 ] && [ -n "$OPT_HOOKS" ]; then
    _drop=$(printf '%s\n' $OPT_HOOKS | grep -E "$_SKIP_RESCUE_RE" || true)
    if [ -n "$_drop" ]; then
        _tty_skip "component-selector: rescue-partition OFF — skipping:$_drop"
        OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -vE "$_SKIP_RESCUE_RE" || true)
    fi
fi
if [ "$_CWP" = 0 ] && [ -n "$OPT_HOOKS" ]; then
    _drop=$(printf '%s\n' $OPT_HOOKS | grep -E "$_SKIP_WALLPAPER_RE" || true)
    if [ -n "$_drop" ]; then
        _tty_skip "component-selector: wallpaper-rotator OFF — skipping:$_drop"
        OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -vE "$_SKIP_WALLPAPER_RE" || true)
    fi
fi
# AUDIT: name every hook that exists on disk but is in NO list.
#
# The lists above are allowlists, so a dropped hook is invisible: it produces
# no log, no warning and no progress tick, and the install reports success.
# That is how 12-sky1-firmware and 44-rtc-sync shipped dead through several
# ISO revisions. Enumerate the gap explicitly at plan time so the next one is
# caught by reading the install log rather than by auditing a board weeks
# later.
_planned=$(printf '%s\n%s\n%s\n' "$PHASE0_HOOKS" "$REQUIRED_HOOKS" "$OPT_HOOKS" | sort -u)
_ondisk=$(ls [0-9][0-9]-*.sh 2>/dev/null | sort -u)
# Component-selector skips (r303) are NOT orphans — they're the operator
# explicitly opting OUT of a toggle. The five skip regexes must be remembered
# here exactly as written in the toggle block above.
_SKIP_ALL_RE="${_SKIP_DESKTOP_RE}|${_SKIP_BROWSERS_RE}|${_SKIP_MGMT_RE}|${_SKIP_RESCUE_RE}|${_SKIP_WALLPAPER_RE}"
_orphans=$(comm -13 <(printf '%s\n' $_planned | sort -u) \
                    <(printf '%s\n' $_ondisk | sort -u) \
           | grep -vE '^(70-bootloader|99-diagnostics)\.sh$' \
           | grep -vE "$_SKIP_ALL_RE" || true)
if [ -n "$_orphans" ]; then
    echo "[cix-installer] WARNING: hooks present on disk but in NO execution list (NCZ_BAKED=${NCZ_BAKED:-0}):"
    printf '%s\n' $_orphans | sed 's/^/[cix-installer]   ORPHAN: /'
    echo "[cix-installer]   These will NOT run. Add them to MACHINE_HOOKS_RE or the REQUIRED list."
fi

PHASE0_TOTAL=$(printf '%s\n' $PHASE0_HOOKS | awk 'NF { n++ } END { print n+0 }')
REQUIRED_TOTAL=$(printf '%s\n' $REQUIRED_HOOKS | awk 'NF { n++ } END { print n+0 }')
TOTAL_OPT=$(printf '%s\n' $OPT_HOOKS | awk 'NF { n++ } END { print n+0 }')
TOTAL_HOOKS=$((PHASE0_TOTAL + REQUIRED_TOTAL + TOTAL_OPT))
[ -f 70-bootloader.sh ] && TOTAL_HOOKS=$((TOTAL_HOOKS + 1))
[ -f 99-diagnostics.sh ] && TOTAL_HOOKS=$((TOTAL_HOOKS + 1))

# Structured progress protocol consumed by preseed/late.sh and also retained as
# a post-boot audit trail. The state file is replaced atomically so the renderer
# never observes a partially-written record.
#
# started|updated|event|phase|index|total|hook|percent|rc|detail
PROGRESS_STATE="$LOGDIR/progress.state"
PROGRESS_LOG="$LOGDIR/progress.tsv"
PROGRESS_INDEX=0
PROGRESS_PHASE=plan
PROGRESS_HOOK=run-all
PROGRESS_STARTED=$(date +%s)
: > "$PROGRESS_LOG"
progress_clean() {
    printf '%s' "$*" | tr '|\t\r\n' '     ' | cut -c1-180
}
progress_emit() {
    local event="${1:-INFO}" detail="${2:-}" percent="${3:-}" rc="${4:-}"
    local now tmp record
    now=$(date +%s)
    detail=$(progress_clean "$detail")
    record="${PROGRESS_STARTED}|${now}|${event}|${PROGRESS_PHASE}|${PROGRESS_INDEX}|${TOTAL_HOOKS}|${PROGRESS_HOOK}|${percent}|${rc}|${detail}"
    tmp="${PROGRESS_STATE}.tmp.$$"
    if printf '%s\n' "$record" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$PROGRESS_STATE" 2>/dev/null || true
    fi
    printf '%s\n' "$record" >> "$PROGRESS_LOG" 2>/dev/null || true
}
progress_start() {
    local phase="$1" hook="$2" detail="${3:-Running $2}"
    PROGRESS_INDEX=$((PROGRESS_INDEX + 1))
    PROGRESS_PHASE="$phase"
    PROGRESS_HOOK="$hook"
    PROGRESS_STARTED=$(date +%s)
    export NCZ_PROGRESS_FILE="$PROGRESS_STATE"
    export NCZ_PROGRESS_LOG="$PROGRESS_LOG"
    export NCZ_PROGRESS_PHASE="$PROGRESS_PHASE"
    export NCZ_PROGRESS_INDEX="$PROGRESS_INDEX"
    export NCZ_PROGRESS_TOTAL="$TOTAL_HOOKS"
    export NCZ_PROGRESS_HOOK="$PROGRESS_HOOK"
    export NCZ_PROGRESS_STARTED="$PROGRESS_STARTED"
    progress_emit START "$detail"
}
progress_finish() {
    progress_emit "${1:-DONE}" "${2:-}" "" "${3:-0}"
}
progress_emit PLAN "Post-install plan: $TOTAL_HOOKS scheduled steps"

tty_msg "==== run-all.sh: post-install hooks starting ===="

# EXIT trap: run 70-bootloader.sh only after Phase 1 required hooks have
# completed. It is invoked directly, not through the failure-tracking
# machinery, since this trap fires after any earlier `exit` or `set -e`
# propagation.
finalize_bootloader() {
    ORIGINAL_RC=$?
    # The trap may run while Phase 1's `set -euo pipefail` is active.
    # Keep finalization best-effort so bootloader failure cannot skip
    # the diagnostics hook.
    set +e
    BOOTLOADER_RC=0
    if [ -w /boot/efi ]; then
        { echo "TRAP ORIGINAL_RC=$ORIGINAL_RC REQUIRED_PHASE_OK=${REQUIRED_PHASE_OK:-unset}"; echo "TRAP 70bl=$([ -f "$HOOK_DIR/70-bootloader.sh" ] && echo YES || echo NO)"; } \
            >> /boot/efi/ncz-debug.txt 2>/dev/null || true
    fi
    if [ "$ORIGINAL_RC" -ne 0 ] && [ "${REQUIRED_PHASE_OK:-0}" != "1" ]; then
        if [ -f "$HOOK_DIR/70-bootloader.sh" ]; then
            progress_start bootloader 70-bootloader.sh "Skipping bootloader after required-step failure"
            progress_finish SKIP "Required install step failed; bootloader was not modified" "$ORIGINAL_RC"
        fi
        echo ""
        echo "============================================================"
        echo "[cix-installer] EXIT trap -> required phase failed; skipping bootloader"
        echo "============================================================"
        echo "[cix-installer] 70-bootloader.sh skipped so a failed required hook cannot wipe the ESP"
    elif [ -f "$HOOK_DIR/70-bootloader.sh" ]; then
        progress_start bootloader 70-bootloader.sh "Installing the bootloader"
        echo ""
        echo "============================================================"
        echo "[cix-installer] EXIT trap → finalizing bootloader"
        echo "============================================================"
        bash "$HOOK_DIR/70-bootloader.sh" \
            2>&1 | tee "$LOGDIR/70-bootloader.log"
        BOOTLOADER_RC=${PIPESTATUS[0]}
        if [ "$BOOTLOADER_RC" -ne 0 ]; then
            progress_finish FAIL "Bootloader installation failed" "$BOOTLOADER_RC"
            echo "[cix-installer] CRITICAL: 70-bootloader.sh failed rc=$BOOTLOADER_RC"
            echo "[cix-installer] System will likely fail to boot — see $LOGDIR/70-bootloader.log"
        else
            progress_finish DONE "Bootloader installed" 0
        fi
    fi
    # Run 99-diagnostics AFTER bootloader, so it captures the final
    # /boot/efi/loader/ state (loader.conf, entries, vmlinuz-* layout).
    if [ -f "$HOOK_DIR/99-diagnostics.sh" ]; then
        progress_start diagnostics 99-diagnostics.sh "Collecting final diagnostics"
        echo ""
        echo "============================================================"
        echo "[cix-installer] EXIT trap → final diagnostics dump"
        echo "============================================================"
        bash "$HOOK_DIR/99-diagnostics.sh" \
            2>&1 | tee "$LOGDIR/99-diagnostics.log"
        DIAGNOSTICS_RC=${PIPESTATUS[0]}
        if [ "$DIAGNOSTICS_RC" -ne 0 ]; then
            progress_finish WARN "Final diagnostics reported errors" "$DIAGNOSTICS_RC"
            echo "[cix-installer] WARN: 99-diagnostics.sh hit errors rc=$DIAGNOSTICS_RC"
        else
            progress_finish DONE "Final diagnostics collected" 0
        fi
    fi
    if [ -n "$FAILED_HOOKS" ]; then
        echo ""
        echo "[cix-installer] hooks that failed: $FAILED_HOOKS"
        echo "  bootloader + diagnostics still ran — system should boot"
        echo "  to default kernel; logs available at /var/log/cix-install/"
    fi
    # Codex A2 CRITICAL #1 fix: propagate bootloader failure to late_command
    # so d-i marks install as failed if bootloader didn't install. Without
    # this, late_command "succeeds" with no working bootloader and user
    # boots to nothing.
    if [ "$BOOTLOADER_RC" -ne 0 ]; then
        progress_emit FAIL "Post-install failed: bootloader rc=$BOOTLOADER_RC" "" "$BOOTLOADER_RC"
        exit "$BOOTLOADER_RC"
    fi
    if [ -n "$CRITICAL_HOOK_FAILURES" ]; then
        progress_emit FAIL "Ship-critical post-install hooks failed:$CRITICAL_HOOK_FAILURES" "" 1
        echo "[cix-installer] FATAL: ship-critical hooks failed:$CRITICAL_HOOK_FAILURES"
        exit 1
    fi
    # r149: optional (Phase 2) hook failures must NOT abort the install — the
    # system is fully installed + bootable; only a failed REQUIRED phase or a
    # bootloader failure is fatal. (Was: bare `exit $ORIGINAL_RC` propagated a
    # leftover non-zero from a network-dependent optional hook -> d-i
    # preseed/command_failed.)
    if [ "$ORIGINAL_RC" -ne 0 ] && [ "${REQUIRED_PHASE_OK:-0}" != "1" ]; then
        progress_emit FAIL "Post-install failed in a required step" "" "$ORIGINAL_RC"
        exit "$ORIGINAL_RC"
    fi
    if [ -n "$FAILED_HOOKS" ]; then
        progress_emit COMPLETE "Completed with optional-step warnings:$FAILED_HOOKS" "" 0
    else
        progress_emit COMPLETE "Post-install completed successfully" "" 0
    fi
    exit 0
}
trap finalize_bootloader EXIT

# Phase 0: diagnostic affordance hooks (set +e) — run BEFORE Phase 1.
# These create the magnetar diag account + any other "must exist before
# the install can fail" affordances. Failures logged but never block the
# install. Specifically: 09-diag-account.sh creates magnetar/diags
# so a remote operator has a working SSH login the moment this chroot
# touches /etc/passwd, regardless of whether 10-our-kernel.sh or any
# subsequent hook crashes.
#
# Codex-found bug 2026-05-07: on r78-take2, magnetar was missing from
# installed system because 09-diag-account.sh was in Phase 2 alphabetic
# sort and the install never reached Phase 2 — 10-our-kernel.sh had
# already aborted run-all.sh. Phase 0 fixes that.
set +e
tty_msg "Phase 0: diag affordance hooks (run BEFORE required kernel install)"
for hook in $PHASE0_HOOKS; do
    LOG="$LOGDIR/${hook%.sh}.log"
    HOOK_START=$(date +%s)
    progress_start diagnostic "$hook" "Preparing diagnostic access: ${hook%.sh}"
    tty_msg "  → $hook (diag, non-blocking)"
    echo ""
    echo "============================================================"
    echo "[cix-installer] [PHASE0] running $hook → $LOG"
    echo "============================================================"
    # Codex r78 audit MEDIUM (2026-05-07): pipefail is not enabled
    # until Phase 1, so `if bash | tee ...` checks tee's exit code, not
    # the hook's — hook syntax errors get reported as ✓ success on
    # tty3. Mirror Phase 2's PIPESTATUS pattern instead.
    bash ./"$hook" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    HOOK_DUR=$(( $(date +%s) - HOOK_START ))
    if [ "$rc" -eq 0 ]; then
        progress_finish DONE "Diagnostic preparation complete (${HOOK_DUR}s)" 0
        tty_msg "  ✓ $hook done (${HOOK_DUR}s)"
    else
        progress_finish WARN "Diagnostic preparation warning (${HOOK_DUR}s)" "$rc"
        tty_msg "  ⚠ $hook rc=$rc (${HOOK_DUR}s, continuing — Phase 0 is non-blocking)"
        echo "[cix-installer] [PHASE0] WARN: $hook exited rc=$rc — install continues"
    fi
done

# Phase 1: required hooks (set -e)
set -euo pipefail
# r193.1 (found on .66, 2026-07-06): a baked image used to skip Phase 1
# ENTIRELY, on the assumption the kernel/firmware/network are all already
# present from the bake. True for firmware/network, but the kernel-apt fix
# (10-our-kernel.sh) needs to run even on a baked image -- otherwise dpkg
# never learns the kernel is installed (baked images pre-date that fix, or
# even ones built after it still need the *install* to register the
# package, since the bake only wrote files to the squashfs, not a dpkg
# database entry) and `apt upgrade` has nothing it thinks needs upgrading,
# exactly the bug this whole fix exists to close. 12-sky1-firmware.sh and
# 33-network.sh remain genuinely bake-safe to skip.
if [ "$NCZ_BAKED" = 1 ]; then
    tty_msg "Phase 1: baked image — firmware/network skipped, kernel dpkg-tracking still required"
else
    tty_msg "Phase 1: required hooks (kernel + sky1-firmware + network)"
fi
for hook in $REQUIRED_HOOKS; do
    LOG="$LOGDIR/${hook%.sh}.log"
    HOOK_START=$(date +%s)
    progress_start required "$hook" "Installing required component: ${hook%.sh}"
    tty_msg "  → $hook (required)"
    echo ""
    echo "============================================================"
    echo "[cix-installer] [REQUIRED] running $hook → $LOG"
    echo "============================================================"
    set +e
    bash ./"$hook" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        HOOK_DUR=$(( $(date +%s) - HOOK_START ))
        progress_finish FAIL "Required component failed (${HOOK_DUR}s)" "$rc"
        tty_msg "  ✗ $hook FAILED rc=$rc — install aborts"
        echo "[cix-installer] FATAL on $hook rc=$rc — install cannot continue"
        # The EXIT trap will skip the bootloader because Phase 1 did
        # not complete. Preserve the required hook rc.
        exit "$rc"
    fi
    HOOK_DUR=$(( $(date +%s) - HOOK_START ))
    progress_finish DONE "Required component complete (${HOOK_DUR}s)" 0
    tty_msg "  ✓ $hook done (${HOOK_DUR}s)"
done
REQUIRED_PHASE_OK=1

# Phase 2: optional hooks. Failures logged but don't abort.
set +e
tty_msg "Phase 2: optional hooks (desktop + brand + ssh + ...)"
if [ "$NCZ_BAKED" = 1 ]; then
    tty_msg "Phase 2: baked image — running only machine-specific hooks: $OPT_HOOKS"
fi
IDX=0
for hook in $OPT_HOOKS; do
    IDX=$((IDX + 1))
    LOG="$LOGDIR/${hook%.sh}.log"
    HOOK_START=$(date +%s)
    progress_start optional "$hook" "Installing optional component: ${hook%.sh}"
    tty_msg "  → [$IDX/$TOTAL_OPT] $hook"
    echo ""
    echo "============================================================"
    echo "[cix-installer] [OPTIONAL $IDX/$TOTAL_OPT] running $hook → $LOG"
    echo "============================================================"
    bash ./"$hook" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    HOOK_DUR=$(( $(date +%s) - HOOK_START ))
    if [ "$rc" -ne 0 ]; then
        progress_finish WARN "Optional component warning (${HOOK_DUR}s)" "$rc"
        tty_msg "  ✗ [$IDX/$TOTAL_OPT] $hook FAILED rc=$rc (${HOOK_DUR}s) — continuing"
        echo "[cix-installer] $hook FAILED rc=$rc — continuing (bootloader still writes)"
        FAILED_HOOKS="$FAILED_HOOKS $hook"
        if printf '%s\n' "$hook" | grep -Eq "$CRITICAL_OPTIONAL_HOOKS_RE"; then
            CRITICAL_HOOK_FAILURES="$CRITICAL_HOOK_FAILURES $hook"
            echo "[cix-installer] $hook is ship-critical; d-i will fail after bootloader + diagnostics"
        fi
    else
        progress_finish DONE "Optional component complete (${HOOK_DUR}s)" 0
        tty_msg "  ✓ [$IDX/$TOTAL_OPT] $hook done (${HOOK_DUR}s)"
    fi
done

echo ""
echo "============================================================"
if [ -z "$FAILED_HOOKS" ]; then
    echo "[cix-installer] all optional hooks completed cleanly"
    tty_msg "Phase 2 complete: all optional hooks OK"
else
    echo "[cix-installer] some optional hooks failed: $FAILED_HOOKS"
    tty_msg "Phase 2 done with failures:$FAILED_HOOKS"
fi
echo "  → bootloader runs via EXIT trap next, then reboot"
echo "============================================================"
tty_msg "Phase 3: bootloader (EXIT trap)"
# EXIT trap fires after this — bootloader runs there
