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
# Phase 2: optional hooks (desktop, agents, plymouth, branding,
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

LOGDIR=/var/log/cix-install
mkdir -p "$LOGDIR"
cd /usr/local/lib/cix-installer/post-install || exit 1
# Track failures across phases for end-of-run summary.
FAILED_HOOKS=""
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
MACHINE_HOOKS_RE="^(24-apt-sources|25-cix-proprietary|26-gpu-default-mali|30-agents|31-remote-access|34-fstab|35-fstrim-fix|35-ssh|36-telemetry|37-failsafe-access|37-ntp-hostname|38-recovery-container|40-claude-code|41-usb2-rescan|46-python311|47-embedkit|47-llm-stack|48-magnetar-variant|52-vivaldi|72-rescue-partition|80-npu|81-vpu|82-mali-gpu|83-panthor-gpu|83-vpu-ffmpeg|84-vpu-mpv)\.sh$"


# r55+: surface progress on /dev/tty3 (the d-i log VT — Alt+F3 during install)
# so users can watch hooks tick by instead of staring at d-i's stuck dialog.
# Best-effort: if tty3 isn't writable (post-reboot, or unusual context),
# falls back silently.
TTY=/dev/tty3
tty_msg() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >"$TTY" 2>/dev/null || true
}
# r141: install the per-package apt-get progress shim ahead of PATH.
NCZ_SHIM=/tmp/ncz-apt-shim; mkdir -p "$NCZ_SHIM" /var/log/cix-install 2>/dev/null || true
SHIMSRC="$(dirname "$0")/apt-progress-shim"; [ -f "$SHIMSRC" ] && { cp "$SHIMSRC" "$NCZ_SHIM/apt-get" && chmod 0755 "$NCZ_SHIM/apt-get" && export PATH="$NCZ_SHIM:$PATH" && tty_msg "per-package apt progress shim active (Alt+F3)"; }

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
    { echo "TRAP ORIGINAL_RC=$ORIGINAL_RC REQUIRED_PHASE_OK=${REQUIRED_PHASE_OK:-unset}"; echo "TRAP 70bl=$([ -f /usr/local/lib/cix-installer/post-install/70-bootloader.sh ] && echo YES || echo NO)"; } >> /boot/efi/ncz-debug.txt 2>/dev/null || true
    if [ "$ORIGINAL_RC" -ne 0 ] && [ "${REQUIRED_PHASE_OK:-0}" != "1" ]; then
        echo ""
        echo "============================================================"
        echo "[cix-installer] EXIT trap -> required phase failed; skipping bootloader"
        echo "============================================================"
        echo "[cix-installer] 70-bootloader.sh skipped so a failed required hook cannot wipe the ESP"
    elif [ -f /usr/local/lib/cix-installer/post-install/70-bootloader.sh ]; then
        echo ""
        echo "============================================================"
        echo "[cix-installer] EXIT trap → finalizing bootloader"
        echo "============================================================"
        bash /usr/local/lib/cix-installer/post-install/70-bootloader.sh \
            2>&1 | tee "$LOGDIR/70-bootloader.log"
        BOOTLOADER_RC=${PIPESTATUS[0]}
        if [ "$BOOTLOADER_RC" -ne 0 ]; then
            echo "[cix-installer] CRITICAL: 70-bootloader.sh failed rc=$BOOTLOADER_RC"
            echo "[cix-installer] System will likely fail to boot — see $LOGDIR/70-bootloader.log"
        fi
    fi
    # Run 99-diagnostics AFTER bootloader, so it captures the final
    # /boot/efi/loader/ state (loader.conf, entries, vmlinuz-* layout).
    if [ -f /usr/local/lib/cix-installer/post-install/99-diagnostics.sh ]; then
        echo ""
        echo "============================================================"
        echo "[cix-installer] EXIT trap → final diagnostics dump"
        echo "============================================================"
        bash /usr/local/lib/cix-installer/post-install/99-diagnostics.sh \
            2>&1 | tee "$LOGDIR/99-diagnostics.log"
        DIAGNOSTICS_RC=${PIPESTATUS[0]}
        if [ "$DIAGNOSTICS_RC" -ne 0 ]; then
            echo "[cix-installer] WARN: 99-diagnostics.sh hit errors rc=$DIAGNOSTICS_RC"
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
        exit "$BOOTLOADER_RC"
    fi
    # r149: optional (Phase 2) hook failures must NOT abort the install — the
    # system is fully installed + bootable; only a failed REQUIRED phase or a
    # bootloader failure is fatal. (Was: bare `exit $ORIGINAL_RC` propagated a
    # leftover non-zero from a network-dependent optional hook -> d-i
    # preseed/command_failed.)
    if [ "$ORIGINAL_RC" -ne 0 ] && [ "${REQUIRED_PHASE_OK:-0}" != "1" ]; then
        exit "$ORIGINAL_RC"
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
for hook in $(ls 0[0-9]-*.sh 2>/dev/null | sort); do
    LOG="$LOGDIR/${hook%.sh}.log"
    HOOK_START=$(date +%s)
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
        tty_msg "  ✓ $hook done (${HOOK_DUR}s)"
    else
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
for hook in $(ls [0-9][0-9]-*.sh | sort); do
    case "$hook" in
        12-sky1-firmware.sh|33-network.sh)
            if [ "$NCZ_BAKED" = 1 ]; then
                tty_msg "  → $hook SKIPPED (baked image)"
                continue
            fi
            ;;
        10-our-kernel.sh|11-fix-cixmini-boot.sh)
            ;;
        *)
            continue
            ;;
    esac
    LOG="$LOGDIR/${hook%.sh}.log"
    HOOK_START=$(date +%s)
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
        tty_msg "  ✗ $hook FAILED rc=$rc — install aborts"
        echo "[cix-installer] FATAL on $hook rc=$rc — install cannot continue"
        # The EXIT trap will skip the bootloader because Phase 1 did
        # not complete. Preserve the required hook rc.
        exit "$rc"
    fi
    HOOK_DUR=$(( $(date +%s) - HOOK_START ))
    tty_msg "  ✓ $hook done (${HOOK_DUR}s)"
done
REQUIRED_PHASE_OK=1

# Phase 2: optional hooks. Failures logged but don't abort.
set +e
tty_msg "Phase 2: optional hooks (desktop + agents + brand + ssh + ...)"
OPT_HOOKS=$(ls [0-9][0-9]-*.sh 2>/dev/null | sort | grep -vE '^(0[0-9]|10-our-kernel|11-fix-cixmini-boot|12-sky1-firmware|33-network|70-bootloader|99-diagnostics)\.sh$')
if [ "$NCZ_BAKED" = 1 ]; then
    OPT_HOOKS=$(printf '%s\n' $OPT_HOOKS | grep -E "$MACHINE_HOOKS_RE" || true)
    tty_msg "Phase 2: baked image — running only machine-specific hooks: $OPT_HOOKS"
fi
TOTAL_OPT=$(echo "$OPT_HOOKS" | wc -l)
IDX=0
for hook in $OPT_HOOKS; do
    IDX=$((IDX + 1))
    LOG="$LOGDIR/${hook%.sh}.log"
    HOOK_START=$(date +%s)
    tty_msg "  → [$IDX/$TOTAL_OPT] $hook"
    echo ""
    echo "============================================================"
    echo "[cix-installer] [OPTIONAL $IDX/$TOTAL_OPT] running $hook → $LOG"
    echo "============================================================"
    bash ./"$hook" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    HOOK_DUR=$(( $(date +%s) - HOOK_START ))
    if [ "$rc" -ne 0 ]; then
        tty_msg "  ✗ [$IDX/$TOTAL_OPT] $hook FAILED rc=$rc (${HOOK_DUR}s) — continuing"
        echo "[cix-installer] $hook FAILED rc=$rc — continuing (bootloader still writes)"
        FAILED_HOOKS="$FAILED_HOOKS $hook"
    else
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
