# shellcheck shell=bash
# ncz-work-dir-guard.sh -- reject in-memory / copy-on-write scratch mounts
# before any apt fetch or container launch. Sourced by build-singularity.sh
# (and any other builder that owns a /work-style workspace) and exercised
# by apt-sim-tests.sh so the test does not duplicate the policy.
#
# Contract:
#   ncz_work_dir_guard <workspace-path>
#     1. mkdir -p the path (idempotent; never deletes anything).
#     2. findmnt -T <path> -o FSTYPE -n; a non-zero exit is fatal.
#     3. A successful findmnt that prints an EMPTY fstype is a probe failure
#        and is fatal -- never silently treated as "unknown == disk".
#     4. The fstype is then classified:
#          REJECTED: empty, ramfs, tmpfs, overlay, aufs, fuse-overlayfs.
#          ACCEPTED: every other fstype (btrfs, ext4, xfs, zfs, f2fs, jfs,
#                    ntfs, vfat, and any other real backing store the test
#                    or operator wants to allow).
#     5. On rejection, prints a single-line "ERROR:" message to stderr
#        naming the offending fstype and returns 1.
#
# Optional override: NCZ_WORK_DIR_GUARD_FINDMNT=<path> lets the test inject
# a stub findmnt that returns a canned fstype without touching the real
# /proc/self/mountinfo. Documented here so the name never appears in a
# public script body.

ncz_work_dir_guard() {
    local work_dir="${1:?ncz_work_dir_guard: missing WORK_DIR argument}"
    mkdir -p "$work_dir"
    local findmnt_bin="${NCZ_WORK_DIR_GUARD_FINDMNT:-$(command -v findmnt || true)}"
    if [ -z "$findmnt_bin" ]; then
        echo "ERROR: WORK_DIR=$work_dir: findmnt not available on PATH" >&2
        return 1
    fi
    local fstype
    if ! fstype="$("$findmnt_bin" -T "$work_dir" -o FSTYPE -n 2>/dev/null)"; then
        echo "ERROR: WORK_DIR=$work_dir: findmnt -T failed (not on any mounted filesystem)" >&2
        return 1
    fi
    if [ -z "$fstype" ]; then
        # A successful findmnt that prints an empty fstype is a probe failure:
        # the kernel could not classify the backing store. Reject explicitly --
        # never silently fall through to "unknown == disk".
        echo "ERROR: WORK_DIR=$work_dir: findmnt returned an empty fstype (probe failed); refusing to build" >&2
        return 1
    fi
    case "$fstype" in
        ""|ramfs|tmpfs|overlay|aufs|fuse-overlayfs)
            echo "ERROR: WORK_DIR=$work_dir is on $fstype; refusing to build on in-memory / copy-on-write scratch" >&2
            return 1
            ;;
        *)
            # Any non-rejected fstype (btrfs, ext4, xfs, zfs, f2fs, jfs, ntfs,
            # vfat, ...) is accepted. A new disk filesystem only needs to
            # land on the rejection list when it is actually in-memory or
            # copy-on-write, not when it is a new disk filesystem.
            return 0
            ;;
    esac
}
