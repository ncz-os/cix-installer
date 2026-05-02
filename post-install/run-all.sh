#!/bin/bash
# run-all.sh — orchestrate the numbered post-install hooks.
#
# Invoked from preseed late_command via in-target. Runs in chroot
# context against the freshly-installed Debian Bookworm rootfs.
#
# Hooks are numbered 00-..-90 and run in lexical order. A failure in
# any hook aborts the install (set -e). Hook output is logged to
# /var/log/cix-install/<hook>.log on the target so a successful boot
# can show "what was done" — useful for demo + debugging.
set -euo pipefail

LOGDIR=/var/log/cix-install
mkdir -p "$LOGDIR"

cd /usr/local/lib/cix-installer/post-install
for hook in $(ls [0-9][0-9]-*.sh | sort); do
    LOG="$LOGDIR/${hook%.sh}.log"
    echo ""
    echo "============================================================"
    echo "[cix-installer] running $hook → $LOG"
    echo "============================================================"
    if ! bash ./"$hook" 2>&1 | tee "$LOG"; then
        echo "[cix-installer] FAIL on $hook — aborting"
        exit 1
    fi
done

echo ""
echo "============================================================"
echo "[cix-installer] all hooks completed cleanly"
echo "  → reboot to boot nclawzero"
echo "============================================================"
