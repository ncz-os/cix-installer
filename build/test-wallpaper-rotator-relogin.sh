#!/bin/bash
# test-wallpaper-rotator-relogin.sh -- regression test for the item RRH fix:
# ncz-wallpaper-rotator.service must be pulled in on EVERY login.
#
# Why this exists (live O6N evidence, 2026-10-04): the unit was
# WantedBy=default.target with PartOf=graphical-session.target. The systemd
# --user manager outlives a logout (lingering sessions keep it up), so
# default.target stays active and its Wants are never re-pulled; PartOf= only
# propagates a STOP. The unit was SIGTERMed at 16:08 when the first desktop
# session ended and was NEVER started again -- wallpaper rotation was dead for
# 7 h. The session launcher
# (/opt/singularity/bin/singularity-desktop-session; subprojects/
# singularity-session) starts singularity-session.target on EVERY login and
# stops it on logout, and 20-desktop.sh bridges that target in from the /opt
# payload, so the unit must be WantedBy=singularity-session.target (the
# per-login anchor) as well as WantedBy=graphical-session.target (the standard
# anchor so it still works under other compositors).
#
# Positive/negative self-checks prove this test FAILS on the pre-fix unit and
# PASSES on the fixed one.
#
# Run: bash build/test-wallpaper-rotator-relogin.sh
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file under
# test is missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO/post-install/45-wallpaper-rotator.sh"
DESKTOP="$REPO/post-install/20-desktop.sh"
for f in "$HOOK" "$DESKTOP"; do
    [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

# Extract a heredoc unit body from a shell source file.
# $1 = source file, $2 = marker (e.g. UNIT)
extract_unit() {
    awk -v m="$2" '
        $0 ~ "<<.?" m "." { f=1; next }
        f && $0 == m { f=0 }
        f { print }
    ' "$1"
}

# The per-login property checker. A unit satisfies it when:
#   - it is WantedBy= the target the session launcher starts on EVERY login
#     (singularity-session.target), and
#   - it does NOT still carry the buggy WantedBy=default.target anchor
#     (default.target stays active across a logout, so its Wants never re-fire).
has_relogin_anchor() {
    local body="$1"
    printf '%s\n' "$body" | grep >/dev/null -E '^[[:space:]]*WantedBy=.*singularity-session\.target' || return 1
    printf '%s\n' "$body" | grep >/dev/null -E '^[[:space:]]*WantedBy=[[:space:]]*default\.target[[:space:]]*$' && return 1
    return 0
}

# Stops-on-logout: PartOf= the per-login target so the logout stop propagates.
has_logout_stop() {
    printf '%s\n' "$1" | grep >/dev/null -E '^[[:space:]]*PartOf=.*singularity-session\.target'
}

# systemd-analyze verify, tolerating the one expected diagnostic for a unit
# whose ExecStart binary is not installed on the test host.
verify_unit() {
    local body="$1" name="$2" vdir out
    command -v systemd-analyze >/dev/null 2>&1 || { echo "SKIP"; return 0; }
    vdir="$(mktemp -d)"
    mkdir -p "$vdir/etc/systemd/system"
    printf '%s\n' "$body" > "$vdir/etc/systemd/system/$name"
    out="$(SYSTEMD_LOG_LEVEL=warning systemd-analyze verify \
        "$vdir/etc/systemd/system/$name" 2>&1 \
        | grep -E "$name|$vdir" \
        | grep -vE 'is not executable|No such file or directory' || true)"
    rm -rf "$vdir"
    [ -z "$out" ] && return 0
    printf '%s' "$out"
    return 1
}

UNIT="$(extract_unit "$HOOK" UNIT)"
if [ -z "$UNIT" ]; then
    bad "ncz-wallpaper-rotator.service unit found in 45-wallpaper-rotator.sh" \
        "UNIT heredoc not extracted"
else
    ok "ncz-wallpaper-rotator.service unit found in 45-wallpaper-rotator.sh"

    if has_relogin_anchor "$UNIT"; then
        ok "unit is WantedBy=singularity-session.target (fires at every login)"
    else
        bad "unit is WantedBy=singularity-session.target (fires at every login)" \
            "$(printf '%s\n' "$UNIT" | grep -nE 'WantedBy=|PartOf=')"
    fi

    if printf '%s\n' "$UNIT" | grep >/dev/null -E '^[[:space:]]*WantedBy=.*graphical-session\.target'; then
        ok "unit also WantedBy=graphical-session.target (other compositors)"
    else
        bad "unit also WantedBy=graphical-session.target (other compositors)"
    fi

    if has_logout_stop "$UNIT"; then
        ok "unit is PartOf=singularity-session.target (logout stops it)"
    else
        bad "unit is PartOf=singularity-session.target (logout stops it)" \
            "$(printf '%s\n' "$UNIT" | grep -nE 'PartOf=')"
    fi

    if printf '%s\n' "$UNIT" | grep >/dev/null -E '^[[:space:]]*WantedBy=[[:space:]]*default\.target[[:space:]]*$'; then
        bad "unit does not rely on WantedBy=default.target" \
            "$(printf '%s\n' "$UNIT" | grep -nE 'WantedBy=')"
    else
        ok "unit does not rely on WantedBy=default.target"
    fi

    if printf '%s\n' "$UNIT" | grep >/dev/null -E '^[[:space:]]*ExecStartPre[[:space:]]*='; then
        bad "unit has no ExecStartPre (no login-time polling)"
    else
        ok "unit has no ExecStartPre (no login-time polling)"
    fi

    verify_out="$(verify_unit "$UNIT" ncz-wallpaper-rotator.service || true)"
    if [ -z "$verify_out" ]; then
        ok "systemd-analyze verify accepts the generated unit"
    else
        bad "systemd-analyze verify accepts the generated unit" "$verify_out"
    fi
fi

# The anchor must really be started per login: 20-desktop.sh bridges
# singularity-session.target in from the /opt payload and starts it at the
# start of every session.
if grep -q 'systemctl --user start singularity-session.target' "$DESKTOP"; then
    ok "20-desktop.sh starts singularity-session.target each session"
else
    bad "20-desktop.sh starts singularity-session.target each session" \
        "$(grep -nE 'singularity-session\.target' "$DESKTOP")"
fi
if grep -qE 'ln -sfn .*singularity-session\.target' "$DESKTOP"; then
    ok "20-desktop.sh bridges singularity-session.target into systemd --user"
else
    bad "20-desktop.sh bridges singularity-session.target into systemd --user" \
        "$(grep -nE 'singularity-session\.target' "$DESKTOP")"
fi

# ---- fails-before self-check -----------------------------------------------
# The pre-fix unit shape must be rejected by the same checker, so this test
# would have caught the live regression.
OLD_UNIT='[Unit]
Description=NCZ wallpaper rotator
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ncz-wallpaper-daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target'
if has_relogin_anchor "$OLD_UNIT"; then
    bad "self-check: pre-fix WantedBy=default.target unit is rejected"
else
    ok "self-check: pre-fix WantedBy=default.target unit is rejected"
fi

echo
echo "wallpaper-rotator relogin tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
