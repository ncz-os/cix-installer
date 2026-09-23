#!/bin/bash
# 96-setuid-audit.sh - reassert setuid-root on binaries that need it.
#
# Real bug found 2026-09-18: /usr/bin/pkexec shipped mode 0755 instead of
# 4755 on a live O6N install, despite pkexec's own dpkg postinst correctly
# running `chmod 4755` at package-configure time. Every other package's
# setuid postinst (sudo/su/mount/passwd/chsh/chfn/gpasswd/fusermount3/
# ntfs-3g) was intact -- only pkexec's bit was lost. Exact mechanism not
# exhaustively traced; suspected the containerized mkosi role-delta build
# (build/build-role-delta-mkosi.sh runs under podman with only
# --cap-add=SYS_ADMIN, not --privileged) drops the bit somewhere between
# postinst and the final squashfs layer. Effect: pkexec refused to run at
# all ("pkexec must be setuid root"), which silently broke every
# polkit-gated action in the desktop -- including the Artist Pack Install
# button, whose own helper chain was otherwise completely correct.
#
# Fail-loud, idempotent re-assertion, same pattern as extract-rootfs.sh's
# root-mode 0755 gate -- a mechanical backstop, not a fix to the build tool
# itself.
set -euo pipefail

echo "[96] auditing setuid-root binaries"

declare -A EXPECTED=(
    [/usr/bin/pkexec]=4755
    [/usr/bin/sudo]=4755
    [/usr/bin/su]=4755
    [/usr/bin/mount]=4755
    [/usr/bin/umount]=4755
    [/usr/bin/passwd]=4755
    [/usr/bin/chsh]=4755
    [/usr/bin/chfn]=4755
    [/usr/bin/gpasswd]=4755
    [/usr/bin/fusermount3]=4755
    [/usr/bin/ntfs-3g]=4755
)

FIXED=0
for bin in "${!EXPECTED[@]}"; do
    [ -f "$bin" ] || continue
    want="${EXPECTED[$bin]}"
    have=$(stat -c '%a' "$bin")
    if [ "$have" != "$want" ]; then
        echo "[96]   WRONG: $bin is $have, expected $want -- correcting" >&2
        chmod "$want" "$bin"
        FIXED=$((FIXED + 1))
    fi
done

if [ "$FIXED" -gt 0 ]; then
    echo "[96] corrected $FIXED setuid binary/binaries"
else
    echo "[96] all setuid binaries already correct"
fi
