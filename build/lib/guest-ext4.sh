# shellcheck shell=bash
# guest-ext4.sh -- read files off a KVM guest's ext4 root that was not cleanly unmounted.
#
# The KVM gate stops the phase-2 guest by timeout (qemu rc=124), so the root
# filesystem it reads back is usually still marked needs_recovery: recent
# metadata (block/inode bitmaps, the files the first boot just wrote) can sit
# in the jbd2 journal only. debugfs does not replay the journal and refuses to
# open such a filesystem ("Inode bitmap checksum does not match bitmap while
# reading allocation bitmaps"), and the gate then reported "no first-boot
# report" for a guest that had written one (2026-10-26, Preview4 arm64).
#
# ncz_guest_ext4_recover IMG LOG
#   Replay the journal and repair IMG in place with e2fsck -fy. IMG must be a
#   scratch copy (the gate's .fb-root.raw), never the guest disk itself.
#   Returns 0 when e2fsck left the filesystem consistent (exit 0, 1 or 2),
#   non-zero otherwise; e2fsck's output goes to LOG.
ncz_guest_ext4_recover() {
    local img="$1" log="$2" e2fsck rc
    e2fsck="$(command -v e2fsck || echo /sbin/e2fsck)"
    [ -x "$e2fsck" ] || { echo "e2fsck not installed" > "$log"; return 127; }
    "$e2fsck" -fy "$img" > "$log" 2>&1
    rc=$?
    echo "e2fsck rc=$rc" >> "$log"
    [ "$rc" -lt 4 ]
}
