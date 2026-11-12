#!/bin/bash
# 61-ncz-console-saver.sh -- install and enable the Magnetar Server console
# screen saver (operator 2026-11-09 04:40Z): after idle_seconds of console
# idleness the Rust ASCII black-hole saver (ncz-bh-console) runs on a free
# VT and any key gives the console back. Server variant only -- the desktop
# image is untouched.
#
# WHAT THIS HOOK INSTALLS:
#   /usr/local/bin/ncz-console-saver              the idle-driven VT daemon
#   /usr/local/bin/ncz-bh-console                 the saver it spawns
#   /etc/systemd/system/ncz-console-saver.service enabled by default (server)
#   /etc/ncz/console-saver.conf                   config (only if absent)
#   /usr/share/doc/ncz-console-saver/README.md    what it is, how to disable
#
# Shipped through the existing payload path: assets/console-saver/ on the
# medium (ncz-payload/assets/console-saver/, union-synced into
# /usr/local/lib/cix-installer/assets/ by late.sh) -- NOT a deb (the stated
# B3 decision, ncz-screensavers 5ae8a71f). The unit's ExecStart matches the
# install path below (build/test-console-saver-wiring.sh pins the contract).
#
# Mandatory on a server MEDIUM (late.sh: MEDIUM_VARIANT=server): no staged
# assets = exit 1 (hook 59's silent-skip bug is not repeated). A desktop
# medium installed as a console/base target writes BUILD_VARIANT=server
# (late.sh, desktop component off) but stages no payload -- write-usb-image.py
# stage_console_saver is server-variant-guarded, "the desktop image is
# untouched" (04:40Z) -- so on a non-server medium a missing payload is
# expected and the hook skips cleanly (option-matrix minimal set, 2026-11-12).
# Idempotent: an existing /etc/ncz/console-saver.conf is never overwritten
# (operator config wins); binaries and the unit are re-copied. Desktop never
# installs anything.
#
# Enabling is server-only ("enabled by default on the server variant only",
# 04:40Z item 2); headless installs but leaves the unit disabled. The unit
# itself refuses serial-only boxes (ConditionPathExists=/dev/tty0) and the
# daemon refuses ttyS*/ttyAMA* consoles.
#
# Test seam (build/test-console-saver-wiring.sh): NCZ_CS_ROOT installs under
# a prefix; NCZ_CS_SKIP_ENABLE skips systemctl (as does a non-empty
# NCZ_CS_ROOT).
set -uo pipefail

echo "[61-ncz-console-saver] enforcing console-saver install on server variants"

ROOT="${NCZ_CS_ROOT:-}"
VARIANT=desktop
if [ -f "$ROOT/usr/local/lib/cix-installer/BUILD_VARIANT" ]; then
    VARIANT=$(tr -d ' \t\r\n' < "$ROOT/usr/local/lib/cix-installer/BUILD_VARIANT")
fi
case "$VARIANT" in
    desktop)
        echo "[61-ncz-console-saver] BUILD_VARIANT=desktop -- desktop SKU; skipping"
        exit 0
        ;;
    server|headless) ;;
    *)
        echo "[61-ncz-console-saver] unknown BUILD_VARIANT='$VARIANT'; skipping" >&2
        exit 0
        ;;
esac

# Mandatory-on-missing is a property of the MEDIUM, not of BUILD_VARIANT:
# only a Magnetar server medium (late.sh: MEDIUM_VARIANT=server) stages
# assets/console-saver (write-usb-image.py stage_console_saver is
# server-variant-guarded). A desktop medium installed as a console/base
# target writes BUILD_VARIANT=server (desktop component off) and stages no
# payload -- FATALing there aborted the whole required phase, skipped the
# bootloader and left the install unbootable (option-matrix minimal set,
# 2026-11-12).
MEDIUM=""
if [ -r "$ROOT/usr/local/lib/cix-installer/MEDIUM_VARIANT" ]; then
    MEDIUM=$(tr -d ' \t\r\n' < "$ROOT/usr/local/lib/cix-installer/MEDIUM_VARIANT")
fi

# Where the payload path put the assets (same convention as 66-lite/50-update):
# the medium first, then the installer's union-synced copy.
ASSETS=""
for _r in "$ROOT/cdrom/ncz-payload" "$ROOT/usr/local/lib/cix-installer"; do
    if [ -f "$_r/assets/console-saver/ncz-console-saver" ]; then
        ASSETS="$_r/assets/console-saver"
        break
    fi
done
if [ -z "$ASSETS" ]; then
    if [ "$MEDIUM" = server ]; then
        echo "[61-ncz-console-saver] FATAL: assets/console-saver/ncz-console-saver not found under" \
             "/cdrom/ncz-payload or /usr/local/lib/cix-installer -- the server console saver is" \
             "mandatory on a server medium (04:40Z order); refusing to continue" >&2
        exit 1
    fi
    echo "[61-ncz-console-saver] no console-saver payload staged on a non-server medium (BUILD_VARIANT=$VARIANT); skipping (desktop image untouched)"
    exit 0
fi

for f in ncz-console-saver ncz-bh-console ncz-console-saver.service console-saver.conf; do
    if [ ! -f "$ASSETS/$f" ]; then
        if [ "$MEDIUM" = server ]; then
            echo "[61-ncz-console-saver] FATAL: $ASSETS/$f missing from the staged payload" >&2
            exit 1
        fi
        echo "[61-ncz-console-saver] $ASSETS/$f missing on a non-server medium; skipping"
        exit 0
    fi
done

install -d "$ROOT/usr/local/bin" "$ROOT/etc/systemd/system" "$ROOT/etc/ncz" \
           "$ROOT/usr/share/doc/ncz-console-saver"
install -m 0755 "$ASSETS/ncz-console-saver"     "$ROOT/usr/local/bin/ncz-console-saver"
install -m 0755 "$ASSETS/ncz-bh-console"        "$ROOT/usr/local/bin/ncz-bh-console"
install -m 0644 "$ASSETS/ncz-console-saver.service" \
                "$ROOT/etc/systemd/system/ncz-console-saver.service"
if [ -f "$ROOT/etc/ncz/console-saver.conf" ]; then
    echo "[61-ncz-console-saver] keeping existing /etc/ncz/console-saver.conf (operator config)"
else
    install -m 0644 "$ASSETS/console-saver.conf" "$ROOT/etc/ncz/console-saver.conf"
fi
if [ -f "$ASSETS/README.md" ]; then
    install -m 0644 "$ASSETS/README.md" "$ROOT/usr/share/doc/ncz-console-saver/README.md"
fi

if [ "$VARIANT" = server ] && [ -z "$ROOT" ] && [ -z "${NCZ_CS_SKIP_ENABLE:-}" ]; then
    systemctl daemon-reload
    systemctl enable ncz-console-saver.service
    echo "[61-ncz-console-saver] ncz-console-saver.service enabled (server variant)"
else
    echo "[61-ncz-console-saver] installed without enabling (variant=$VARIANT)"
fi
exit 0
