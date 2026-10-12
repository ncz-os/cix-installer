#!/bin/bash
# test-ncz-first-login-tour.sh -- prove the first-login tour guard behaves.
#
# The guard (assets/branding/first-login-tour/ncz-first-login-tour) decides
# whether the Singularity tour may auto-open at login. Every decision branch is
# exercised here with a stubbed environment (no Wayland, no DRM, no gsettings,
# no root), so the test runs anywhere and never touches the real session.
#
# The marker path must resolve under XDG_STATE_HOME (a user-writable state dir),
# and "show" must write it BEFORE launching so a crash cannot loop the tour.
#
# Usage: bash build/test-ncz-first-login-tour.sh
set -uo pipefail

# SC2086 is intentional below: CASE_EXTRA is a whitespace-separated list of
# VAR=VAL tokens that must word-split into separate arguments for env(1); it is
# only ever set to plain assignments like "NCZ_TOUR_DRYRUN=1".
# shellcheck disable=SC2086

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${NCZ_FIRSTLOGIN_TOUR:-$ROOT/assets/branding/first-login-tour/ncz-first-login-tour}"
DESKTOP="$ROOT/assets/branding/first-login-tour/ncz-first-login-tour.desktop"
HOOK="$ROOT/post-install/51-ncz-tour-slides.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

[ -f "$SCRIPT" ] || { bad "guard script missing: $SCRIPT"; echo "1..0"; exit 1; }
[ -f "$DESKTOP" ] || { bad "autostart entry missing: $DESKTOP"; exit 1; }
[ -x "$SCRIPT" ] || bad "guard script is not executable (mode 0755)"
sh -n "$SCRIPT" 2>/dev/null && ok "guard script parses (sh -n)" || bad "guard script does not parse"

W="$(mktemp -d "${TMPDIR:-/tmp}/ncz-tour-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# --- desktop entry must be a SINGULARITY system autostart entry --------------------------------
# The shipped shell's AutostartManager launches a SYSTEM /etc/xdg/autostart entry
# only when OnlyShowIn names Singularity; without it the entry is silently dead
# (which is exactly the bug the existing ncz-qotd/ncz-firewall-notice entries have).
if grep -q '^OnlyShowIn=Singularity;$' "$DESKTOP"; then ok "autostart entry sets OnlyShowIn=Singularity"; else bad "autostart entry lacks OnlyShowIn=Singularity (never launched by the shell)"; fi
if grep -q '^Exec=/usr/local/bin/ncz-first-login-tour show$' "$DESKTOP"; then ok "autostart entry Exec runs the guard 'show'"; else bad "autostart entry Exec is wrong"; fi
if grep -q '^Type=Application' "$DESKTOP"; then ok "autostart entry Type=Application"; else bad "autostart entry Type wrong"; fi

# --- hook installs both the guard and the entry ------------------------------------------------
if [ -f "$HOOK" ]; then
    grep -q 'usr/local/bin/ncz-first-login-tour' "$HOOK" && ok "hook installs the guard to /usr/local/bin" || bad "hook does not install the guard"
    grep -q '/etc/xdg/autostart/ncz-first-login-tour.desktop' "$HOOK" && ok "hook installs the autostart entry" || bad "hook does not install the autostart entry"
else
    bad "hook missing: $HOOK"
fi

# --- environment stubs -------------------------------------------------------------------------
mk_sandbox() {   # fresh state/home each case
    S="$W/s-$RANDOM"; mkdir -p "$S/home" "$S/state" "$S/config"
}
# base "everything fine" knobs; individual cases flip one.
pretend() {
    env -i PATH="$PATH" \
        HOME="$S/home" \
        NCZ_TOUR_STATE_HOME="$S/state" \
        NCZ_TOUR_CONFIG_HOME="$S/config" \
        NCZ_TOUR_OPT_OUT="$S/no-such-optout" \
        NCZ_TOUR_UID="${CASE_UID:-1000}" \
        NCZ_TOUR_WAYLAND="${CASE_WAYLAND:-1}" \
        NCZ_TOUR_DRM_STATUS="${CASE_DRM:-connected}" \
        NCZ_TOUR_LIVE="${CASE_LIVE:-0}" \
        NCZ_TOUR_FIRST_RUN="${CASE_FIRSTRUN:-0}" \
        NCZ_TOUR_LOCKED="${CASE_LOCKED:-0}" \
        NCZ_TOUR_SETTLE=0 NCZ_TOUR_SHELL_WAIT=0 \
        ${CASE_EXTRA:-} \
        sh "$SCRIPT" "${1:-guard}"
}

# guard_expect <name> <want_rc> <want_substr>
guard_expect() {
    local name="$1" want_rc="$2" want="$3" out rc
    out="$(pretend guard 2>&1)"; rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "$name: rc=$rc want $want_rc ($out)"; return
    fi
    case "$out" in
        *"$want"*) ok "$name" ;;
        *) bad "$name: output '$out' lacks '$want'" ;;
    esac
}

mk_sandbox; guard_expect "allow when everything is fine" 0 "allow"

mk_sandbox; mkdir -p "$S/state/ncz"; : >"$S/state/ncz/tour-seen"
guard_expect "marker present -> already shown" 1 "already shown"

mk_sandbox; : >"$S/optout"; CASE_EXTRA="NCZ_TOUR_OPT_OUT=$S/optout"
guard_expect "admin opt-out file -> skip" 1 "opt-out"; unset CASE_EXTRA

mk_sandbox; mkdir -p "$S/config/ncz"; : >"$S/config/ncz/no-first-login-tour"
guard_expect "user opt-out file -> skip" 1 "opt-out"

mk_sandbox; CASE_UID=0 guard_expect "root -> skip" 1 "root"; CASE_UID=

mk_sandbox; CASE_LIVE=1 guard_expect "live/installer session -> skip" 1 "live"; CASE_LIVE=

mk_sandbox; CASE_FIRSTRUN=1 guard_expect "another first-run flow -> skip" 1 "first-run"; CASE_FIRSTRUN=

mk_sandbox; CASE_WAYLAND=0 guard_expect "no graphical session -> skip" 1 "no graphical"; CASE_WAYLAND=

mk_sandbox; CASE_DRM=disconnected guard_expect "no connected DRM output -> skip" 1 "no connected DRM"; CASE_DRM=

# The guard parses NCZ_TOUR_DRM_STATUS as a comma-separated connector list and
# allows when ANY entry is "connected" (has_connected_output's case match on
# ",${...},*,"), so a mix of disconnected + connected outputs must allow.
mk_sandbox; CASE_DRM=disconnected,connected guard_expect "comma-list with one connected output -> allow" 0 "allow"; CASE_DRM=

# --- "show" side effects -----------------------------------------------------------------------
# allowed: marker written BEFORE launch (DRYRUN keeps it offline and inert)
mk_sandbox; out="$(CASE_EXTRA="NCZ_TOUR_DRYRUN=1" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$S/state/ncz/tour-seen" ]; then ok "show (allowed) writes the marker before launching"; else bad "show (allowed) did not write marker (rc=$rc, $out)"; fi
unset CASE_EXTRA

# locked: must NOT consume the marker (defer to a later unlocked login)
mk_sandbox; CASE_LOCKED=1 out="$(CASE_EXTRA="NCZ_TOUR_DRYRUN=1" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$S/state/ncz/tour-seen" ]; then ok "show (locked) defers and leaves the marker unwritten"; else bad "show (locked) wrote the marker or failed (rc=$rc, $out)"; fi

# opt-out: show is a no-op and does not write the marker
mk_sandbox; : >"$S/optout"
out="$(CASE_EXTRA="NCZ_TOUR_OPT_OUT=$S/optout NCZ_TOUR_DRYRUN=1" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$S/state/ncz/tour-seen" ]; then ok "show (opt-out) does not write the marker"; else bad "show (opt-out) misbehaved (rc=$rc, $out)"; fi
unset CASE_EXTRA

# marker path is user-writable state, resolved under XDG_STATE_HOME
if grep -q 'XDG_STATE_HOME' "$SCRIPT" && grep -q '\.local/state' "$SCRIPT"; then
    ok "marker resolves under a user-writable XDG state dir"
else
    bad "marker path does not use XDG_STATE_HOME/.local/state"
fi

echo "$((PASS + FAIL)) checks, $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
