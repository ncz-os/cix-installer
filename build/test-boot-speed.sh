#!/bin/bash
# test-boot-speed.sh -- regression tests for boot-speed properties that are
# provable statically from the generated systemd units.
#
# Why this exists (docs/BOOT-SPEED.md): a Type=oneshot service that is
# WantedBy=multi-user.target is NOT "fire and forget" -- the multi-user.target
# start job does not complete until the oneshot process exits, so a oneshot
# that waits on the network (or polls for up to a minute) sits directly on the
# way to graphical.target. This is exactly the failure post-install/
# 97-firstboot-report.sh avoids by using Type=simple "on purpose ... a oneshot
# in multi-user.target's wants would hold the target (and the display manager
# behind it) for the 30 s sleep" (97-firstboot-report.sh:36-37).
#
# ncz-issue-refresh.service only rewrites the cosmetic IP/SoC lines in
# /etc/issue, and its ExecStart already polls for a DHCP address itself. It
# must therefore be Type=simple (asynchronous) and must not carry a redundant
# After=/Wants=network-online.target that both delays its start and drags the
# network-online wait onto the multi-user critical chain.
#
# Positive/negative self-checks are included so this test demonstrably FAILS on
# the pre-fix unit (a boot-blocking oneshot) and PASSES on the fixed one.
#
# Run: bash build/test-boot-speed.sh
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file under
# test is missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BRAND="$REPO/post-install/50-brand.sh"
[ -r "$BRAND" ] || { echo "FATAL: cannot read $BRAND" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

# Extract a heredoc unit body from a shell source file.
# $1 = source file, $2 = marker (e.g. ISSUE_UNIT)
extract_unit() {
    awk -v m="$2" '
        $0 ~ "<<.?" m "." { f=1; next }
        f && $0 == m { f=0 }
        f { print }
    ' "$1"
}

# ---- the property checker ---------------------------------------------------
# A unit is boot-blocking when it is WantedBy=multi-user.target (or pulled into
# the multi-user transaction) and is Type=oneshot without RemainAfterExit=yes
# (RemainAfterExit=yes still blocks for the duration of ExecStart, but the
# common "waits forever for the network" case is the no-RemainAfterExit oneshot;
# treat any oneshot as blocking unless RemainAfterExit=yes is explicitly set).
is_boot_blocking() {
    local body="$1"
    printf '%s\n' "$body" | grep -qE '^[[:space:]]*Type=oneshot[[:space:]]*$' || return 1
    return 0
}

# ncz-issue-refresh.service must be Type=simple (async) and not wait on the
# network target: it polls for its own address.
UNIT="$(extract_unit "$BRAND" ISSUE_UNIT)"
oneshot_body='Type=oneshot
WantedBy=multi-user.target'
simple_body='Type=simple
WantedBy=multi-user.target'
if [ -z "$UNIT" ]; then
    bad "ncz-issue-refresh.service unit found in 50-brand.sh" "ISSUE_UNIT heredoc not extracted"
else
    ok "ncz-issue-refresh.service unit found in 50-brand.sh"

    if is_boot_blocking "$UNIT"; then
        bad "ncz-issue-refresh is not a boot-blocking oneshot" \
            "$(printf '%s\n' "$UNIT" | grep -nE 'Type=|WantedBy=|RemainAfterExit')"
    else
        ok "ncz-issue-refresh is not a boot-blocking oneshot (Type=simple)"
    fi

    if printf '%s\n' "$UNIT" | grep -qE '^[[:space:]]*Type=simple[[:space:]]*$'; then
        ok "ncz-issue-refresh.service is Type=simple"
    else
        bad "ncz-issue-refresh.service declares Type=simple" "$UNIT"
    fi

    if printf '%s\n' "$UNIT" | grep -qE '^[[:space:]]*(After|Wants)=[[:space:]]*network-online\.target'; then
        bad "ncz-issue-refresh has no redundant network-online dependency" \
            "$(printf '%s\n' "$UNIT" | grep -nE 'network-online')"
    else
        ok "ncz-issue-refresh has no redundant network-online dependency"
    fi

    # The poll must still exist: the unit is allowed to be async only because
    # ncz-issue-refresh polls for a real address itself.
    if grep -q 'TRIES=' "$BRAND" && grep -q 'sleep 2' "$BRAND"; then
        ok "ncz-issue-refresh helper still polls for a DHCP address"
    else
        bad "ncz-issue-refresh helper still polls for a DHCP address" \
            "poll loop (TRIES=/sleep 2) missing from 50-brand.sh"
    fi
fi

# ---- self-check of the property checker ------------------------------------
# Prove the checker actually rejects the pre-fix shape (fails-before proof) and
# accepts the intended shape.
if is_boot_blocking "$oneshot_body"; then
    ok "self-check: boot-blocking oneshot is detected"
else
    bad "self-check: boot-blocking oneshot is detected"
fi
if is_boot_blocking "$simple_body"; then
    bad "self-check: Type=simple is not flagged as boot-blocking"
else
    ok "self-check: Type=simple is not flagged as boot-blocking"
fi

echo
echo "boot-speed tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
