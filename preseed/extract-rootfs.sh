#!/bin/sh
# r40 partman/late_command — extract pre-built rootfs.tar.zst into /target
# right after partman finishes (so /target is mounted) and before
# bootstrap-base runs. The bookworm bootstrap-base.run-debootstrap will then
# call /usr/sbin/debootstrap (our stub), which detects /target/etc/os-release
# from this extraction and exits 0.
#
# r55+ adds live progress feedback to /dev/tty3 (the d-i log VT — Alt+F3 during
# install) so the long extract phase no longer sits silent at "1%".
set -e

LOG=/var/log/cix-rootfs-extract.log
TTY=/dev/tty3
exec > "$LOG" 2>&1

# msg <text> — log AND print to tty3 with timestamp.
# Avoid `local` (non-POSIX) so the script stays portable to busybox sh
# in the d-i partman late_command environment.
msg() {
    msg_s="[$(date -u +%H:%M:%S)] $*"
    echo "$msg_s"
    printf '%s\n' "$msg_s" >"$TTY" 2>/dev/null || true
}

msg "=== r40 rootfs extract starting ==="
echo "--- mounts ---"
mount | grep -E "cdrom|hd-media|media|target|run/live" || true

ROOTFS=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    if [ -f "$d/rootfs.tar.zst" ]; then
        ROOTFS="$d/rootfs.tar.zst"
        SIZE=$(stat -c%s "$ROOTFS" 2>/dev/null || echo 0)
        SIZE_MB=$((SIZE / 1024 / 1024))
        msg "FOUND rootfs: $ROOTFS (${SIZE_MB} MB compressed)"
        break
    fi
done

if [ -z "$ROOTFS" ]; then
    msg "FATAL: rootfs.tar.zst not found"
    exit 1
fi
if ! command -v zstd >/dev/null; then
    msg "FATAL: zstd not in PATH"
    exit 1
fi
if ! [ -d /target ]; then
    msg "FATAL: /target does not exist"
    exit 1
fi
if ! mountpoint -q /target; then
    msg "WARN: /target is not a mountpoint"
fi

# best-effort progress reporter via background loop
# writes /target size + % every 3s to tty3 — gives the user something to watch
# instead of d-i's stuck "1%" main bar
EXTRACTED_TOTAL_KB=3000000  # rootfs decompresses to ~3 GB; rough estimate for %
(
    while [ -d /target ]; do
        sleep 3
        # /target size in KB (du in d-i busybox supports -s -k)
        CUR_KB=$(du -sk /target 2>/dev/null | awk '{print $1}')
        [ -z "$CUR_KB" ] && CUR_KB=0
        PCT=$(( CUR_KB * 100 / EXTRACTED_TOTAL_KB ))
        [ "$PCT" -gt 100 ] && PCT=100
        FILES=$(find /target -xdev -type f 2>/dev/null | wc -l)
        printf '[%s] extracting rootfs: %d MB / ~3000 MB (%d%%) — %d files\n' \
            "$(date -u +%H:%M:%S)" "$((CUR_KB/1024))" "$PCT" "$FILES" >"$TTY" 2>/dev/null || true
    done
) &
PROG_PID=$!
# shellcheck disable=SC2064  # PROG_PID set at trap-arm time and never reassigned, intentional
trap "kill $PROG_PID 2>/dev/null || true" EXIT

# Try to advance d-i's main progress bar via debconf — best effort, OK if it
# isn't reachable in this context.
if [ -f /usr/share/debconf/confmodule ]; then
    (
        . /usr/share/debconf/confmodule 2>/dev/null && {
            db_progress INFO cdebconf/progress-fallback 2>/dev/null || true
        }
    ) 2>/dev/null || true
fi

msg "--- extracting (typically 30-60s on USB 3 SSD) ---"
START=$(date +%s)

# tar's --checkpoint emits a status line every N records (1 record = 512 bytes,
# so checkpoint=20000 ≈ every 10 MB). Output goes to stderr -> our log AND tty3.
# Busybox tar may not support --checkpoint; fall back to plain extraction
# in that case (still get the background loop progress).
if zstd -dc "$ROOTFS" | tar --checkpoint=20000 \
        --checkpoint-action=ttyout='[r40] %u files (%T{%c} elapsed)\n' \
        -xpf - -C /target 2>"$TTY"; then
    EXTRACT_RC=0
else
    EXTRACT_RC=$?
    msg "tar with --checkpoint failed rc=$EXTRACT_RC; retrying without checkpoint"
    if zstd -dc "$ROOTFS" | tar -xpf - -C /target; then
        EXTRACT_RC=0
    else
        EXTRACT_RC=$?
    fi
fi

END=$(date +%s)
ELAPSED=$((END - START))

kill $PROG_PID 2>/dev/null || true
trap - EXIT

if [ "$EXTRACT_RC" -ne 0 ]; then
    msg "FATAL: rootfs extract failed rc=$EXTRACT_RC after ${ELAPSED}s"
    exit "$EXTRACT_RC"
fi

FINAL_KB=$(du -sk /target 2>/dev/null | awk '{print $1}')
FINAL_MB=$((FINAL_KB / 1024))
FINAL_FILES=$(find /target -xdev -type f 2>/dev/null | wc -l)
msg "--- extract done: ${FINAL_MB} MB, ${FINAL_FILES} files in ${ELAPSED}s ---"

ls -la /target | head -15
df -h /target | head -3

touch /target/.cix-r40-rootfs-extracted
[ -f /target/etc/os-release ] && {
    echo "--- /target/etc/os-release ---"
    cat /target/etc/os-release
} || msg "WARN: /target/etc/os-release missing"

msg "[r40] rootfs extracted — bootstrap-base stub will skip-success"
exit 0
