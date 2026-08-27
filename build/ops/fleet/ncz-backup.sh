#!/bin/bash
# ncz-backup.sh — per-host fleet backup to argonas2 (192.168.207.41).
#
# WHY THIS EXISTS (2026-08-10): the fleet had NO working backup at all, while
# looking like it did. Three independent silent failures were found the same
# day the ARGOS build tree was deleted and proved unrecoverable:
#   * argonas2's per-host backup dirs were created 2026-07-03 and were still
#     EMPTY five weeks later,
#   * ARGONAS's argos tarballs stopped at 2026-07-05 because the "ARGONAS pulls
#     now" job quietly died,
#   * datapool/tydeus-backup snapshotted DAILY while holding 256K and one
#     `config` file, so the snapshot list looked perfectly healthy.
#
# So this script's contract is not "run rsync" — it is "prove data landed".
# It writes a heartbeat with the measured size and FAILS LOUDLY when a backup
# is empty, because an empty backup that exits 0 is what caused the loss.
set -uo pipefail

NAS_HOST="${NAS_HOST:-192.168.207.41}"
NAS_EXPORT="${NAS_EXPORT:-/mnt/datapool/backups}"
MNT="${MNT:-/mnt/argonas2_backups}"
HOSTN="$(hostname -s)"
DEST="$MNT/$HOSTN"
LOG="/var/log/ncz-backup.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }

# What to protect. Home is where every host's real work lives; /etc carries the
# machine-specific config that is painful to reconstruct.
SOURCES=("/home" "/etc")

# Excludes: only genuinely regenerable churn. Deliberately NOT excluding build
# outputs, ISOs or mirrors -- "it can be rebuilt" is exactly the assumption that
# cost us the chromium .deb, which then had to be dpkg-repack'd off a live box.
# --timeout=1800: a stalled NFS transfer must FAIL, not hang forever.
# MEASURED 2026-08-11: cixmini and TYDEUS each sat 16+ hours with the rsync
# receiver in state D on argonas2, no log output, no completion -- and because
# the run never exits, the daily timer never produces a clean backup either.
# The mount is `hard`, so rsync blocks indefinitely by design; an explicit I/O
# timeout is what converts that into a reportable failure. Silent forever is
# worse than a loud failure, which is the whole premise of this script.
EXCLUDES=(
    --exclude='*/.cache/**'
    --exclude='*/.ccache/**'
    --exclude='*/__pycache__/**'
    --exclude='*/node_modules/**'
    --exclude='*/.npm/_cacache/**'
    --exclude='/home/*/.local/share/Trash/**'
    --exclude='*.sock'
    --exclude='*/proc/**'
    --exclude='*/sys/**'
    # Container/image stores. podman+docker overlay layers are owned by mapped
    # subordinate UIDs with restrictive modes, and the NFS target squashes to a
    # single uid, so rsync cannot recreate those dirs and returns rc=23 -- which
    # failed the WHOLE backup even though every byte of real user data landed
    # (ACHILLES 2026-08-11: 113 errors, all under containers/storage/overlay).
    # This content is reconstructible (podman/docker pull), so it is EXCLUDED
    # rather than the exit code being suppressed. Masking rc=23 would hide a
    # genuine failure of something that actually matters -- and silent backup
    # failure is the exact bug this whole arrangement exists to prevent.
    --exclude='*/.local/share/containers/storage/**'
    --exclude='/var/lib/containers/storage/**'
    --exclude='/var/lib/docker/**'
)

command -v rsync >/dev/null || die "rsync not installed"

# Mount the NAS export on demand; leave it mounted if it already was.
WAS_MOUNTED=1
if ! mountpoint -q "$MNT" 2>/dev/null; then
    WAS_MOUNTED=0
    mkdir -p "$MNT"
    mount -t nfs4 "$NAS_HOST:$NAS_EXPORT" "$MNT" 2>>"$LOG" \
        || die "cannot mount $NAS_HOST:$NAS_EXPORT at $MNT"
fi
mountpoint -q "$MNT" || die "$MNT is not a mountpoint after mount"

mkdir -p "$DEST" || die "cannot create $DEST"

log "backup start: $HOSTN -> $NAS_HOST:$NAS_EXPORT/$HOSTN"
rc=0
for src in "${SOURCES[@]}"; do
    [ -d "$src" ] || { log "skip $src (absent)"; continue; }
    log "  rsync $src"
    # NOT -aHAX --numeric-ids: the NAS export squashes ownership
    # (all_squash/anonuid, the documented ARGONAS convention), so every single
    # file failed `chown` with "Operation not permitted" -- thousands of errors
    # and a non-zero exit on an otherwise fine transfer. Preserve times, perms,
    # symlinks and hardlinks; let the server own the files, which is what a
    # squashing export is going to do regardless.
    rsync --timeout=1800 -rlptDH --delete --no-o --no-g --stats \
        "${EXCLUDES[@]}" "$src" "$DEST/" >>"$LOG" 2>&1
    r=$?
    # 24 = "source vanished during transfer", normal on a live system.
    if [ $r -ne 0 ] && [ $r -ne 24 ]; then rc=1; log "  rsync $src FAILED (rc=$r)"; fi
done

# PROVE IT LANDED. A backup that exits 0 having written nothing is the failure
# mode this whole script exists to prevent, so measure and refuse to call it a
# success.
sz_bytes=$(du -sb "$DEST" 2>/dev/null | cut -f1)
sz_human=$(du -sh "$DEST" 2>/dev/null | cut -f1)
files=$(find "$DEST" -type f 2>/dev/null | head -100000 | wc -l)
log "backup size: ${sz_human:-0} (${sz_bytes:-0} bytes, ${files} files sampled)"

if [ "${sz_bytes:-0}" -lt 10485760 ]; then      # < 10 MiB is not a real backup
    log "FATAL: backup for $HOSTN is only ${sz_bytes:-0} bytes — refusing to report success"
    rc=1
fi

# Heartbeat: lets anyone audit freshness across the fleet with a single ls.
printf '%s\thost=%s\tbytes=%s\tsize=%s\trc=%s\n' \
    "$(date -u +%FT%TZ)" "$HOSTN" "${sz_bytes:-0}" "${sz_human:-0}" "$rc" \
    > "$DEST/.ncz-backup-heartbeat"

[ "$WAS_MOUNTED" = 0 ] && umount "$MNT" 2>/dev/null

if [ "$rc" = 0 ]; then log "backup OK: $HOSTN ($sz_human)"; else log "backup FAILED: $HOSTN"; fi
exit "$rc"
