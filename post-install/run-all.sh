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
cd /usr/local/lib/cix-installer/post-install

# Track failures across phases for end-of-run summary.
FAILED_HOOKS=""

# EXIT trap: always run 70-bootloader.sh (via direct invocation, NOT
# through the failure-tracking machinery, since this trap fires after
# any earlier `exit` or `set -e` propagation).
finalize_bootloader() {
    BOOTLOADER_RC=0
    if [ -f /usr/local/lib/cix-installer/post-install/70-bootloader.sh ]; then
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
            2>&1 | tee "$LOGDIR/99-diagnostics.log" || \
            echo "[cix-installer] WARN: 99-diagnostics.sh hit errors"
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
}
trap finalize_bootloader EXIT

# Phase 1: required hooks (set -e)
set -euo pipefail
for hook in $(ls [0-9][0-9]-*.sh | sort); do
    case "$hook" in
        10-our-kernel.sh|12-sky1-firmware.sh)
            LOG="$LOGDIR/${hook%.sh}.log"
            echo ""
            echo "============================================================"
            echo "[cix-installer] [REQUIRED] running $hook → $LOG"
            echo "============================================================"
            if ! bash ./"$hook" 2>&1 | tee "$LOG"; then
                echo "[cix-installer] FATAL on $hook — install cannot continue"
                # Bootloader trap will still fire, but with no kernel images
                # nothing useful can be written. Exit anyway.
                exit 1
            fi
            ;;
    esac
done

# Phase 2: optional hooks. Failures logged but don't abort.
set +e
for hook in $(ls [0-9][0-9]-*.sh | sort); do
    case "$hook" in
        10-our-kernel.sh|12-sky1-firmware.sh|70-bootloader.sh|99-diagnostics.sh)
            continue ;;  # required ones already ran; bootloader+diagnostics are in trap
    esac
    LOG="$LOGDIR/${hook%.sh}.log"
    echo ""
    echo "============================================================"
    echo "[cix-installer] [OPTIONAL] running $hook → $LOG"
    echo "============================================================"
    bash ./"$hook" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo "[cix-installer] $hook FAILED rc=$rc — continuing (bootloader still writes)"
        FAILED_HOOKS="$FAILED_HOOKS $hook"
    fi
done

echo ""
echo "============================================================"
if [ -z "$FAILED_HOOKS" ]; then
    echo "[cix-installer] all optional hooks completed cleanly"
else
    echo "[cix-installer] some optional hooks failed: $FAILED_HOOKS"
fi
echo "  → bootloader runs via EXIT trap next, then reboot"
echo "============================================================"
# EXIT trap fires after this — bootloader runs there
