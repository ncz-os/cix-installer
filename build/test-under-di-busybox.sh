#!/bin/bash
# test-under-di-busybox.sh — run a shell snippet under the REAL d-i BusyBox,
# not a generic system busybox.
#
# Why this exists: the 2026-08-26 0700-root incident's rounds 4-5 (see
# docs/ISO-BUILD-GUARDRAILS.md) both shipped gate-code bugs that only
# manifested in the actual debian-installer runtime -- a missing `stat`
# applet, then a corrupted `awk` invocation -- because every fix was
# verified against a normal bash/GNU-coreutils shell instead of the
# constrained BusyBox ash environment the code actually runs in at install
# time. Confirmed live 2026-08-26: this ISO's own d-i BusyBox
# (v1.38.0 Debian 1:1.38.0-3+b1) has NO `stat` applet at all -- a DIFFERENT
# applet set from other busybox builds on this host (e.g. the diag module's
# own static busybox-arm64, v1.37.0 Ubuntu, DOES have stat -- testing
# against the wrong busybox gives a false pass on exactly this class of bug).
#
# This script extracts the REAL substrate initrd (the one actually shipped
# on install.a64/initrd.gz) and chroots into it to run BusyBox natively,
# using the initrd's own bundled libc (the extracted busybox is dynamically
# linked against a substrate-specific glibc that will NOT run against this
# host's own libc outside a chroot).
#
# Usage:
#   build/test-under-di-busybox.sh 'ls -ld /tmp | awk '"'"'{print $1}'"'"''
#   build/test-under-di-busybox.sh -f path/to/script.sh
#   build/test-under-di-busybox.sh --applet-list
#
# Requires: an already-built build/iso-staging-di/install.a64/initrd.gz
# (i.e. run this after `make iso` has staged the installer at least once).
# Requires root (chroot).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INITRD="$ROOT/build/iso-staging-di/install.a64/initrd.gz"
WORK="${NCZ_BUSYBOX_TEST_WORK:-/tmp/ncz-di-busybox-test}"

[ -f "$INITRD" ] || {
    echo "FATAL: $INITRD not found -- run 'make iso' (or at least the [1]/[2]/[3]" >&2
    echo "  staging steps of build/build-iso-di.sh) at least once first." >&2
    exit 1
}
[ "$(id -u)" = "0" ] || {
    echo "FATAL: this must run as root (chroot). Try: sudo $0 ..." >&2
    exit 1
}

if [ ! -x "$WORK/bin/busybox" ] || [ "$INITRD" -nt "$WORK/.extracted-from" ] 2>/dev/null; then
    echo "[test-under-di-busybox] extracting $INITRD -> $WORK (cached after this)" >&2
    rm -rf "$WORK"
    mkdir -p "$WORK"
    # cpio warns (nonzero exit) on device nodes it can't mknod outside a real
    # root context (dev/console, dev/null) -- harmless for our purposes, we
    # only need the busybox binary and its libs, which extract fine. Do not
    # let that trip `set -e`/pipefail and abort before the cache marker below
    # is written (that bug made every invocation silently re-extract).
    ( cd "$WORK" && zcat "$INITRD" | cpio -idm 2>/dev/null ) || true
    [ -x "$WORK/bin/busybox" ] || {
        echo "FATAL: extraction ran but $WORK/bin/busybox is still missing -- something beyond the expected device-node warnings failed" >&2
        exit 1
    }
    cp "$INITRD" "$WORK/.extracted-from"
fi

if [ "${1:-}" = "--applet-list" ]; then
    chroot "$WORK" /bin/busybox --list
    exit 0
fi

if [ "${1:-}" = "-f" ]; then
    [ -n "${2:-}" ] || { echo "usage: $0 -f <script-file>" >&2; exit 2; }
    SNIPPET="$(cat "$2")"
else
    SNIPPET="${1:?usage: $0 '<shell snippet>'  |  $0 -f <script-file>  |  $0 --applet-list}"
fi

echo "[test-under-di-busybox] running under the REAL d-i BusyBox ($(chroot "$WORK" /bin/busybox 2>&1 | head -1)):" >&2
echo "---" >&2
printf '%s\n' "$SNIPPET" >&2
echo "---" >&2
chroot "$WORK" /bin/ash -c "$SNIPPET"
RC=$?
echo "[test-under-di-busybox] exit code: $RC" >&2
exit "$RC"
