#!/bin/bash
# test-timesync-retry.sh -- regression tests for item G: the systemd-timesyncd
# fast-retry drop-in must ship on both architectures, must not disturb the NTP
# server lists, and time sync must never order the greeter/display-manager.
#
# Why this exists: systemd-timesyncd's default
# ConnectionRetrySec= is 30 s. On O6N (2026-10-04) timesyncd started at 5.58 s,
# the NIC link came up at 11.65 s, and the first "Contacted time server" landed
# at 36.92 s -- the attempt that raced link-up was retried only 30 s later.
# The repo installs /etc/systemd/timesyncd.conf.d/10-ncz-fast-retry.conf with
# ConnectionRetrySec=5 so the first sync lands in ~11-16 s instead, with no
# change to when the greeter appears.
#
# The drop-in is written by the NTP hook that already owns
# /etc/systemd/timesyncd.conf.d (post-install/37-ntp-hostname.sh), so it lands
# on BOTH arches (the hook is class=common and is in both hooks.list.*).
#
# Run: bash build/test-timesync-retry.sh
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file under
# test is missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

FAST_RETRY=/etc/systemd/timesyncd.conf.d/10-ncz-fast-retry.conf
SERVER_CONF=/etc/systemd/timesyncd.conf.d/10-nclawzero.conf
NTP_LIST='NTP=time.cloudflare.com time.google.com'
FALLBACK_LIST='FallbackNTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org'

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

# Print the body of every heredoc in a shell file, delimited by
# @@UNIT_START@@ <file>:<line> target=<redirect> ... @@UNIT_END@@ markers.
# (Handles `<<EOF`, `<<-EOF`, `<<'EOF'` and `<<\"EOF\"`; the redirect target on
# the same line, e.g. `cat > /path <<'EOF'`, is captured for filtering.)
emit_units() {
    awk -v sq="'" '
        function emit_start(path) {
            printf "@@UNIT_START@@ %s:%d target=%s\n", FILENAME, FNR, path
        }
        {
            if (inh) {
                chk = $0; sub(/^\t+/, "", chk)
                if (chk == term) { inh = 0; print "@@UNIT_END@@"; next }
                print
                next
            }
            if (match($0, /<<-?[[:space:]]*/)) {
                rest = substr($0, RSTART + RLENGTH)
                if (substr(rest, 1, 1) == sq) rest = substr(rest, 2)
                if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
                    term = substr(rest, RSTART, RLENGTH)
                    path = ""
                    if (match($0, /cat[[:space:]]*>[[:space:]]*[^[:space:]]+/)) {
                        path = substr($0, RSTART, RLENGTH)
                        sub(/^cat[[:space:]]*>[[:space:]]*/, "", path)
                    }
                    inh = 1
                    emit_start(path)
                }
            }
        }
    ' "$1"
}

# Extract just the heredoc whose redirect target is $2 from shell file $1.
extract_target_body() {
    local file="$1" target="$2"
    emit_units "$file" | awk -v t="target=$target" '
        /^@@UNIT_START@@/ { if (index($0, t) > 0) { f = 1; next } else { f = 0; next } }
        /^@@UNIT_END@@/ { f = 0; next }
        f { print }
    '
}

# Scan a stream of unit groups (see emit_units) and print the header of any
# group that both references greetd/display-manager and orders itself
# After=/Wants= a time-sync wait. Synthetic input is used to self-check this.
scan_greeter_after_timesync() {
    awk '
        function flush(   n, i, arr, greeter, ts) {
            if (body != "") {
                n = split(body, arr, "\n")
                greeter = 0; ts = 0
                for (i = 1; i <= n; i++) {
                    if (arr[i] ~ /greetd|display-manager/) greeter = 1
                    if (arr[i] ~ /^[[:space:]]*(After|Wants|Requires|BindsTo|PartOf)[[:space:]]*=/ \
                        && arr[i] ~ /time-sync\.target|systemd-time-wait-sync|time-wait-sync|ntp-wait/) ts = 1
                }
                if (greeter && ts) print hdr
            }
            body = ""; hdr = ""
        }
        /^@@UNIT_START@@/ { flush(); hdr = $0; next }
        /^@@UNIT_END@@/ { flush(); next }
        { body = body $0 "\n" }
        END { flush() }
    '
}

# Every unit group this repo could ship: heredocs in shell sources plus plain
# unit files. Comments/strings that merely mention both words are harmless as
# long as they are not on an ordering directive in the same unit group.
scan_all_groups() {
    local f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        case "$f" in
            *.sh) emit_units "$f" ;;
            *)
                printf '@@UNIT_START@@ %s target=\n' "$f"
                cat "$f"
                printf '@@UNIT_END@@\n'
                ;;
        esac
    done < <(find "$REPO/post-install" "$REPO/assets" "$REPO/build" -type f \
                 \( -name '*.sh' -o -name '*.service' -o -name '*.socket' \
                    -o -name '*.target' -o -name '*.timer' \) 2>/dev/null | LC_ALL=C sort)
}

# --------------------------------------------------------------------------
# Locate the hook that installs the drop-in: must be exactly one.
# --------------------------------------------------------------------------
HOOK=""
HOOK_COUNT=0
for f in "$REPO"/post-install/*.sh; do
    if grep -q '10-ncz-fast-retry\.conf' "$f"; then
        HOOK="$f"; HOOK_COUNT=$((HOOK_COUNT + 1))
    fi
done

if [ "$HOOK_COUNT" -eq 1 ]; then
    ok "exactly one post-install hook installs $FAST_RETRY"
else
    bad "exactly one post-install hook installs $FAST_RETRY" "found $HOOK_COUNT"
fi

if [ -n "$HOOK" ]; then
    HOOK_REL="${HOOK##*/}"

    # ---- 1. the drop-in contents ----------------------------------------
    body="$(extract_target_body "$HOOK" "$FAST_RETRY")"
    if [ -z "$body" ]; then
        bad "drop-in written to $FAST_RETRY" "no heredoc with that redirect in $HOOK_REL"
    else
        ok "drop-in written to $FAST_RETRY"

        if printf '%s\n' "$body" | grep >/dev/null -x '\[Time\]'; then
            ok "drop-in has the [Time] section"
        else
            bad "drop-in has the [Time] section" "$body"
        fi

        if printf '%s\n' "$body" | grep >/dev/null -E '^[[:space:]]*#'; then
            ok "drop-in has a short explanatory comment"
        else
            bad "drop-in has a short explanatory comment" "$body"
        fi

        retry="$(printf '%s\n' "$body" \
            | sed -nE 's/^[[:space:]]*ConnectionRetrySec[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' \
            | head -1)"
        if [ -n "$retry" ] && [ "$retry" -ge 1 ] 2>/dev/null && [ "$retry" -le 10 ] 2>/dev/null; then
            ok "ConnectionRetrySec=$retry (<= 10)"
        else
            bad "ConnectionRetrySec is present and <= 10" "got '${retry:-<none>}'"
        fi

        if printf '%s\n' "$body" | grep >/dev/null -E '^[[:space:]]*(NTP|FallbackNTP)[[:space:]]*='; then
            bad "fast-retry drop-in does not redefine NTP/FallbackNTP" "$body"
        else
            ok "fast-retry drop-in does not redefine NTP/FallbackNTP"
        fi
    fi

    # ---- 2. installed idempotently, mode 0644 ---------------------------
    if grep -E 'chmod[[:space:]]+0?644' "$HOOK" | grep >/dev/null -F '10-ncz-fast-retry.conf' \
       || grep -E 'install[[:space:]]+.*-m[[:space:]]*0?644' "$HOOK" | grep >/dev/null -F '10-ncz-fast-retry.conf'; then
        ok "drop-in is installed with mode 0644"
    else
        bad "drop-in is installed with mode 0644" \
            "$(grep -nE '10-ncz-fast-retry|chmod|install[[:space:]]' "$HOOK" | head -20)"
    fi

    if grep -qE 'install[[:space:]]+-d[[:space:]]+-m[[:space:]]*0?755[[:space:]]+/etc/systemd/timesyncd\.conf\.d' "$HOOK"; then
        ok "timesyncd.conf.d is created idempotently (install -d)"
    else
        bad "timesyncd.conf.d is created idempotently (install -d)" \
            "$(grep -nE 'timesyncd\.conf\.d' "$HOOK")"
    fi

    # ---- 3. the NTP/FallbackNTP server lists are untouched --------------
    sbody="$(extract_target_body "$HOOK" "$SERVER_CONF")"
    if printf '%s\n' "$sbody" | grep >/dev/null -xF "$NTP_LIST" \
       && printf '%s\n' "$sbody" | grep >/dev/null -xF "$FALLBACK_LIST"; then
        ok "NTP/FallbackNTP server lists are untouched"
    else
        bad "NTP/FallbackNTP server lists are untouched" "$sbody"
    fi

    # ---- 4. lands on BOTH arches ----------------------------------------
    if grep -qxF "$HOOK_REL" "$REPO/post-install/hooks.list.sky1-arm64"; then
        ok "$HOOK_REL is in hooks.list.sky1-arm64"
    else
        bad "$HOOK_REL is in hooks.list.sky1-arm64"
    fi
    if grep -qxF "$HOOK_REL" "$REPO/post-install/hooks.list.amd64"; then
        ok "$HOOK_REL is in hooks.list.amd64"
    else
        bad "$HOOK_REL is in hooks.list.amd64"
    fi
fi

# --------------------------------------------------------------------------
# 5. No unit orders greetd/display-manager after a time-sync wait.
# --------------------------------------------------------------------------
# Self-check the detector first so it demonstrably can fail.
pos="$(printf '%s\n' \
    '@@UNIT_START@@ synthetic:1 target=/etc/systemd/system/greetd.service.d/x.conf' \
    '[Unit]' 'After=time-sync.target' '[Service]' 'ExecStart=/usr/sbin/greetd' \
    '@@UNIT_END@@' | scan_greeter_after_timesync)"
if [ -n "$pos" ]; then
    ok "self-check: a greetd drop-in After=time-sync.target is detected"
else
    bad "self-check: a greetd drop-in After=time-sync.target is detected"
fi

neg="$(printf '%s\n' \
    '@@UNIT_START@@ synthetic:1 target=/etc/systemd/system/greetd.service.d/y.conf' \
    '[Unit]' 'After=systemd-udev-settle.service' '[Service]' 'ExecStart=/usr/sbin/greetd' \
    '@@UNIT_END@@' | scan_greeter_after_timesync)"
if [ -z "$neg" ]; then
    ok "self-check: a greetd unit with no time-sync ordering is accepted"
else
    bad "self-check: a greetd unit with no time-sync ordering is accepted" "$neg"
fi

real="$(scan_all_groups | scan_greeter_after_timesync)"
if [ -z "$real" ]; then
    ok "no unit orders greetd/display-manager after time-sync"
else
    bad "no unit orders greetd/display-manager after time-sync" "$real"
fi

echo
echo "timesync-retry tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
