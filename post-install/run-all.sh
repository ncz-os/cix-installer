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
    if [ "$ORIGINAL_RC" -ne 0 ]; then
        exit "$ORIGINAL_RC"
    fi
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
tty_msg "Phase 1: required hooks (kernel + sky1-firmware + network)"
for hook in $(ls [0-9][0-9]-*.sh | sort); do
    case "$hook" in
        10-our-kernel.sh|12-sky1-firmware.sh|33-network.sh)
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
            ;;
    esac
done
REQUIRED_PHASE_OK=1

# Phase 2: optional hooks. Failures logged but don't abort.
set +e
tty_msg "Phase 2: optional hooks (desktop + agents + brand + ssh + ...)"
OPT_HOOKS=$(ls [0-9][0-9]-*.sh 2>/dev/null | sort | grep -vE '^(0[0-9]|10-our-kernel|12-sky1-firmware|33-network|70-bootloader|99-diagnostics)\.sh$')
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
