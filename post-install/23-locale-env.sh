#!/bin/bash
# 23-locale-env.sh — fix "'C' is not a UTF-8 locale, falling back to 'C.UTF-8'"
# warnings from foot (and any other app) launched via systemd --user scopes.
#
# Root cause (found + live-verified on O6N 2026-07-27): /etc/locale.conf sets
# LANG=en_US.UTF-8, and PAM applies that to interactive LOGIN sessions, but
# systemd --user SCOPES (the standard mechanism app launchers use to spawn
# GUI apps under their own cgroup, e.g. via `systemd-run --user --scope`)
# do NOT inherit it — confirmed with `systemd-run --user --scope -- env`
# showing no LANG/LC_* at all, even though `systemctl --user show-environment`
# reports LANG is set (that RPC-settable overlay doesn't propagate to scopes
# either). systemd's environment.d IS read by the user manager at its own
# startup and applied as the default spawn environment for everything it
# creates thereafter, including scopes — the only mechanism confirmed to
# actually reach them.
#
# Ships as our own file, not an edit to /etc/environment.d/cix_env.conf
# (that file is owned by the vendor `cix-env` package; an apt upgrade would
# clobber a local edit).
set -euo pipefail

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[23] BUILD_VARIANT=server - Server headless SKU; no GUI app-launch scopes, skipping locale-env fix"
        exit 0
        ;;
esac

install -d /etc/environment.d
cat > /etc/environment.d/50-locale.conf <<'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF
chmod 0644 /etc/environment.d/50-locale.conf

echo "[23] /etc/environment.d/50-locale.conf installed (fixes UTF-8 locale warning in systemd --user scope-launched apps, e.g. foot)"
