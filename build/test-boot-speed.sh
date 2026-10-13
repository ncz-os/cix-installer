#!/bin/bash
# test-boot-speed.sh -- regression tests for boot-speed properties that are
# provable statically from the generated systemd units.
#
# Why this exists: a Type=oneshot service that is
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

# ---- ncz-rtc-sync.service must not hold the boot transaction (item F) -------
# post-install/44-rtc-sync.sh emitted a Type=oneshot, WantedBy=multi-user.target
# unit with After=/Wants= systemd-time-wait-sync.service time-sync.target.
# systemd-time-wait-sync BLOCKS until NTP actually synchronises, and a targets'
# start job waits for the oneshot it Wants, so multi-user -- and therefore
# graphical -- waited for the first NTP sync. MEASURED on O6N 2026-10-04 14:38Z:
# `Startup finished ... 32.7s (userspace)` and `graphical.target @32.644s` while
# the unit chain otherwise finished at 3.6s. The ExecStart
# loop already polls NTPSynchronized itself, so Type=simple with no time-sync
# ordering lets the target complete while the loop still writes the RTC after
# the first sync. This checks the fix and that the RTC write-back survived.
RTC="$REPO/post-install/44-rtc-sync.sh"
[ -r "$RTC" ] || { echo "FATAL: cannot read $RTC" >&2; exit 2; }
RTC_UNIT="$(extract_unit "$RTC" UNIT)"
if [ -z "$RTC_UNIT" ]; then
    bad "ncz-rtc-sync.service unit found in 44-rtc-sync.sh" "UNIT heredoc not extracted"
else
    ok "ncz-rtc-sync.service unit found in 44-rtc-sync.sh"

    if is_boot_blocking "$RTC_UNIT"; then
        bad "ncz-rtc-sync is not a boot-blocking oneshot" \
            "$(printf '%s\n' "$RTC_UNIT" | grep -nE 'Type=|WantedBy=|RemainAfterExit')"
    else
        ok "ncz-rtc-sync is not a boot-blocking oneshot (Type=simple)"
    fi

    if printf '%s\n' "$RTC_UNIT" | grep -qE '^[[:space:]]*Type=simple[[:space:]]*$'; then
        ok "ncz-rtc-sync.service is Type=simple"
    else
        bad "ncz-rtc-sync.service declares Type=simple" "$RTC_UNIT"
    fi

    if printf '%s\n' "$RTC_UNIT" \
        | grep -qE '^[[:space:]]*(After|Wants)=.*(systemd-time-wait-sync|time-sync\.target)'; then
        bad "ncz-rtc-sync does not order against time sync" \
            "$(printf '%s\n' "$RTC_UNIT" | grep -nE 'time-wait-sync|time-sync')"
    else
        ok "ncz-rtc-sync has no systemd-time-wait-sync/time-sync ordering"
    fi

    # RTC write-back must survive: same synchronised-clock gate, same write,
    # same "never synchronised" log line.
    if printf '%s\n' "$RTC_UNIT" | grep -q 'timedatectl show -p NTPSynchronized'; then
        ok "ncz-rtc-sync still gates on NTPSynchronized=yes"
    else
        bad "ncz-rtc-sync still gates on NTPSynchronized=yes"
    fi
    if printf '%s\n' "$RTC_UNIT" | grep -q 'hwclock --systohc --utc'; then
        ok "ncz-rtc-sync still writes the RTC after the first sync"
    else
        bad "ncz-rtc-sync still writes the RTC after the first sync"
    fi
    if printf '%s\n' "$RTC_UNIT" | grep -q 'NTP never synchronised within 120s'; then
        ok "ncz-rtc-sync keeps the 'never synchronised' log line"
    else
        bad "ncz-rtc-sync keeps the 'never synchronised' log line"
    fi

    # Parse the generated unit with systemd itself, in a throwaway fixture
    # (never the live system): catches a dependency cycle or a malformed
    # ExecStart that grep cannot see.
    if command -v systemd-analyze >/dev/null 2>&1; then
        vdir="$(mktemp -d)"
        mkdir -p "$vdir/etc/systemd/system"
        printf '%s\n' "$RTC_UNIT" > "$vdir/etc/systemd/system/ncz-rtc-sync.service"
        if SYSTEMD_LOG_LEVEL=warning systemd-analyze verify \
            "$vdir/etc/systemd/system/ncz-rtc-sync.service" >"$vdir/out" 2>&1; then
            ok "systemd-analyze verify accepts the generated ncz-rtc-sync.service"
        else
            bad "systemd-analyze verify accepts the generated ncz-rtc-sync.service" \
                "$(cat "$vdir/out")"
        fi
        rm -rf "$vdir"
    else
        echo "SKIP: systemd-analyze not installed; generated unit not parser-verified"
    fi
fi

# ---- ncz-noe-venv-sync.service must not hold the boot transaction (item F) --
# Same class as ncz-rtc-sync: post-install/88-noe-umd-venv.sh emitted a
# Type=oneshot in multi-user.target's wants whose ExecStart can run a `uv pip
# install` for minutes on the first boot after a cix-noe-umd upgrade. The script
# exits on every path, so Type=simple lets multi-user complete while it syncs;
# ncz-npu-embed.service already retries (Restart=on-failure) if it races.
VENV="$REPO/post-install/88-noe-umd-venv.sh"
[ -r "$VENV" ] || { echo "FATAL: cannot read $VENV" >&2; exit 2; }
VENV_UNIT="$(extract_unit "$VENV" UNIT)"
if [ -z "$VENV_UNIT" ]; then
    bad "ncz-noe-venv-sync.service unit found in 88-noe-umd-venv.sh" \
        "UNIT heredoc not extracted"
else
    ok "ncz-noe-venv-sync.service unit found in 88-noe-umd-venv.sh"
    if is_boot_blocking "$VENV_UNIT"; then
        bad "ncz-noe-venv-sync is not a boot-blocking oneshot" \
            "$(printf '%s\n' "$VENV_UNIT" | grep -nE 'Type=|WantedBy=|RemainAfterExit')"
    else
        ok "ncz-noe-venv-sync is not a boot-blocking oneshot (Type=simple)"
    fi
    if printf '%s\n' "$VENV_UNIT" | grep -q '/usr/local/lib/cix-installer/sync-noe-venv.sh'; then
        ok "ncz-noe-venv-sync still runs the venv re-sync script"
    else
        bad "ncz-noe-venv-sync still runs the venv re-sync script"
    fi
fi

# ---- repo-wide detector (item F, step 3) -----------------------------------
# build/boot-speed-scan.py walks every *.service and every service unit embedded
# in shell/python heredocs, and fails on a Type=oneshot in a boot target whose
# resolved script sleeps, polls timedatectl, or waits on network-online/
# systemd-time-wait-sync/time-sync, unless the unit is on its written,
# justified allowlist. Run against this repo it must be clean.
SCAN="$REPO/build/boot-speed-scan.py"
[ -r "$SCAN" ] || { echo "FATAL: cannot read $SCAN" >&2; exit 2; }
if ! command -v python3 >/dev/null 2>&1; then
    bad "repo-wide boot-blocking scan" "python3 not installed"
else
    scan_out="$(python3 "$SCAN" "$REPO" 2>&1)"; scan_rc=$?
    if [ "$scan_rc" = 0 ]; then
        ok "repo-wide scan finds no unallowlisted boot-blocking oneshot"
    else
        bad "repo-wide scan finds no unallowlisted boot-blocking oneshot" "$scan_out"
    fi

    # Fails-before self-check: the pre-fix ncz-rtc-sync unit (Type=oneshot,
    # After/Wants=systemd-time-wait-sync, sleep/timedatectl loop) must be
    # rejected by the same scanner on a throwaway fixture. Run against the real
    # `git show HEAD:post-install/44-rtc-sync.sh` before the fix, the scanner
    # exits 1 with "FAIL ncz-rtc-sync.service": this is its permanent guard.
    fdir="$(mktemp -d)"
    cat > "$fdir/ncz-rtc-sync.service" <<'OLD_RTC'
[Unit]
Description=Write the synchronised system clock back to the RTC
After=systemd-time-wait-sync.service time-sync.target systemd-timesyncd.service
Wants=systemd-time-wait-sync.service time-sync.target
ConditionPathExists=/dev/rtc0

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12; do if [ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ]; then hwclock --systohc --utc && exit 0; fi; sleep 10; done; exit 0'

[Install]
WantedBy=multi-user.target
OLD_RTC
    if python3 "$SCAN" "$fdir" >/dev/null 2>&1; then
        bad "self-check: scanner rejects the pre-fix ncz-rtc-sync unit"
    else
        ok "self-check: scanner rejects the pre-fix ncz-rtc-sync unit"
    fi
    rm -rf "$fdir"
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
