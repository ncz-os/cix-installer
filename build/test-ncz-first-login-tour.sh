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
# only when OnlyShowIn names Singularity; without it the entry is silently dead.
# build/test-xdg-autostart.sh applies the same rule to every system autostart entry.
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
SANDBOX_N=0
mk_sandbox() {   # fresh state/home each case
    SANDBOX_N=$((SANDBOX_N + 1)); S="$W/s-$SANDBOX_N"; mkdir -p "$S/home" "$S/state" "$S/config" "$S/run"
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
        NCZ_TOUR_RUNTIME_DIR="$S/run" \
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

# opt-out (admin file): show is a no-op and does not write the marker
mk_sandbox; : >"$S/optout"
out="$(CASE_EXTRA="NCZ_TOUR_OPT_OUT=$S/optout NCZ_TOUR_DRYRUN=1" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$S/state/ncz/tour-seen" ]; then ok "show (admin opt-out) does not write the marker"; else bad "show (admin opt-out) misbehaved (rc=$rc, $out)"; fi

# opt-out (user file under the config dir): same
mk_sandbox; mkdir -p "$S/config/ncz"; : >"$S/config/ncz/no-first-login-tour"
out="$(CASE_EXTRA="NCZ_TOUR_DRYRUN=1" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$S/state/ncz/tour-seen" ]; then ok "show (user opt-out) does not write the marker"; else bad "show (user opt-out) misbehaved (rc=$rc, $out)"; fi
unset CASE_EXTRA

# marker path is user-writable state, resolved under XDG_STATE_HOME
if grep -q 'XDG_STATE_HOME' "$SCRIPT" && grep -q '\.local/state' "$SCRIPT"; then
    ok "marker resolves under a user-writable XDG state dir"
else
    bad "marker path does not use XDG_STATE_HOME/.local/state"
fi

# --- first-login timing and thermal envelope ---------------------------------
# The tour opens once the desktop's login burst has passed: an adaptive settle
# (two quiet 0.5 s samples, at least NCZ_TOUR_SETTLE_MIN, at most
# NCZ_TOUR_SETTLE_MAX = 8 s) instead of the old fixed 30 s sleep that put the
# tour behind every login notice. NCZ_TOUR_SETTLE still forces a fixed delay.
if grep -q 'NCZ_TOUR_SETTLE:-30' "$SCRIPT"; then
    bad "fixed 30 s settle is still the default"
else
    ok "no fixed 30 s settle"
fi
if grep -qE 'NCZ_TOUR_SETTLE_MAX:-8' "$SCRIPT"; then ok "adaptive settle capped at 8 s"; else bad "adaptive settle cap is not 8 s"; fi
# settle_case <name> <samples> <min> <max> <want_half_seconds>
settle_case() {
    local name="$1" samples="$2" min="$3" max="$4" want="$5" got
    mk_sandbox; mkdir -p "$S/run"
    env -i PATH="$PATH" HOME="$S/home" NCZ_TOUR_STATE_HOME="$S/state" NCZ_TOUR_CONFIG_HOME="$S/config" \
        NCZ_TOUR_OPT_OUT="$S/no-such-optout" NCZ_TOUR_UID=1000 NCZ_TOUR_WAYLAND=1 NCZ_TOUR_DRM_STATUS=connected \
        NCZ_TOUR_LIVE=0 NCZ_TOUR_FIRST_RUN=0 NCZ_TOUR_LOCKED=0 NCZ_TOUR_SHELL_WAIT=0 NCZ_TOUR_DRYRUN=1 \
        NCZ_TOUR_RUNTIME_DIR="$S/run" NCZ_TOUR_LOAD_SAMPLES="$samples" \
        NCZ_TOUR_SETTLE_MIN="$min" NCZ_TOUR_SETTLE_MAX="$max" \
        sh "$SCRIPT" show >/dev/null 2>&1
    got="$(cat "$S/run/first-login-tour.settle" 2>/dev/null)"
    if [ "$got" = "$want" ]; then ok "$name"; else bad "$name: settled after '$got' half-seconds, want $want"; fi
}
settle_case "settle: quiet desktop -> opens at the minimum (1 s)" "5 5 5 5" 1 8 2
settle_case "settle: waits out the login burst, then two quiet samples" "300 250 180 90 20 10 5" 1 8 6
settle_case "settle: one quiet sample inside a burst does not end it" "300 10 300 10 10" 1 8 5
settle_case "settle: a desktop that never quiets is capped at 8 s" "$(printf '400 %.0s' $(seq 1 30))" 1 8 16
# Real sampling path (no test samples): bounded by the cap and parses /proc/stat.
if [ -r /proc/stat ]; then
    mk_sandbox; mkdir -p "$S/run"; t0=$(date +%s)
    env -i PATH="$PATH" HOME="$S/home" NCZ_TOUR_STATE_HOME="$S/state" NCZ_TOUR_CONFIG_HOME="$S/config" \
        NCZ_TOUR_OPT_OUT="$S/no-such-optout" NCZ_TOUR_UID=1000 NCZ_TOUR_WAYLAND=1 NCZ_TOUR_DRM_STATUS=connected \
        NCZ_TOUR_LIVE=0 NCZ_TOUR_FIRST_RUN=0 NCZ_TOUR_LOCKED=0 NCZ_TOUR_SHELL_WAIT=0 NCZ_TOUR_DRYRUN=1 \
        NCZ_TOUR_RUNTIME_DIR="$S/run" NCZ_TOUR_SETTLE_MIN=1 NCZ_TOUR_SETTLE_MAX=2 \
        sh "$SCRIPT" show >/dev/null 2>&1
    el=$(( $(date +%s) - t0 )); got="$(cat "$S/run/first-login-tour.settle" 2>/dev/null)"
    if [ "$el" -le 4 ] && [ -n "$got" ] && [ "$got" -ge 2 ] && [ "$got" -le 4 ]; then
        ok "settle: /proc/stat sampling is bounded (${el}s, ${got} half-seconds)"
    else
        bad "settle: /proc/stat sampling took ${el}s / '${got}' half-seconds (want 1-2 s)"
    fi
else
    ok "settle: /proc/stat case skipped (no /proc on this host)"
fi

# Wrapper must look up nice/cpu-quota. systemd-run --user --scope is the
# preferred path; plain `nice -n 19` is the fallback for non-IPC sessions.
if grep -q 'systemd-run --user --scope' "$SCRIPT" \
   && grep -q 'CPUQuota' "$SCRIPT" \
   && grep -q 'nice=19' "$SCRIPT"; then
    ok "launcher wraps the tour in a CPU-bounded scope (systemd-run --user --scope)"
else
    bad "launcher does not wrap the tour in a CPU-bounded scope"
fi
if grep -q 'NCZ_TOUR_NICE' "$SCRIPT" && grep -q 'NCZ_TOUR_CPUQUOTA' "$SCRIPT"; then
    ok "NCZ_TOUR_NICE / NCZ_TOUR_CPUQUOTA test seams present"
else
    bad "NCZ_TOUR_NICE / NCZ_TOUR_CPUQUOTA test seams missing"
fi
# The marker is written BEFORE the launch (fail-closed), whatever the settle.
mk_sandbox; out="$(CASE_LOCKED=0 CASE_EXTRA="NCZ_TOUR_DRYRUN=1 NCZ_TOUR_SETTLE=0 NCZ_TOUR_SHELL_WAIT=0" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$S/state/ncz/tour-seen" ]; then
    ok "marker is still fail-closed (written before launch, regardless of settle)"
else
    bad "marker not written under NCZ_TOUR_SETTLE=0 (rc=$rc, $out)"
fi
unset CASE_EXTRA
unset CASE_LOCKED

# When systemd-run is unavailable (KVM, recovery, no user bus), the launcher
# falls back to plain `nice -n 19`. The script must still launch the tour
# under that fallback; NCZ_TOUR_NICE=0 disables even the nice path (test seam).
if grep -q 'nice -n 19' "$SCRIPT" && grep -q 'NCZ_TOUR_NICE' "$SCRIPT"; then
    ok "launcher has a nice -n 19 fallback for sessions without systemd-run"
else
    bad "launcher missing nice -n 19 fallback"
fi

# The IFS word-splitting path is under 'set -f' (noglob; no filename expansion
# -- so a value of '*' becomes the literal token '*', not every file in cwd)
# and the launcher asserts \$# == 2 (mode + command line) so a caller that passes extra
# arguments fails loud instead of silently losing them.
# shellcheck disable=SC2016  # literal source text, not an expansion
if grep -B 2 -A 4 'set -- $2' "$SCRIPT" | grep >/dev/null 'set -f'; then
    ok "tokenisation under 'set -f' (noglob; audit-safe argv)"
else
    bad "tokenisation not under 'set -f'"
fi
if grep -qE 'expected 2 arguments \(wait\|bg CMDLINE\), got' "$SCRIPT"; then
    ok "launch_under_scope defensive assert (\$# == 2)"
else
    bad "launch_under_scope missing defensive assert"
fi
# systemd-run availability probe is cached one-shot, NOT re-run per launch
# (re-creating + destroying a scope on every tour launch would add load
# at the moment the scope exists to avoid).
if grep -q 'probe_systemd_run' "$SCRIPT" && grep -q 'NCZ_TOUR_SR_OK' "$SCRIPT"; then
    ok "systemd-run probe is cached (one-shot, not per-launch)"
else
    bad "systemd-run probe is not cached"
fi

# --- launch behaviour (functional, stubbed commands) -----------------------------------------
# The test hook runs in the foreground and its exit status is reported: a
# failing launcher must print "launch failed", a working one "opened the tour".
mkdir -p "$W/stub"
printf '#!/bin/sh\n: >"%s/hook-ran"\nexit 0\n' "$W" >"$W/stub/tour-ok"
printf '#!/bin/sh\nexit 3\n' >"$W/stub/tour-fail"
printf '#!/bin/sh\nnice >"%s/hook-nice"\n' "$W" >"$W/stub/tour-nice"
chmod +x "$W/stub/tour-ok" "$W/stub/tour-fail" "$W/stub/tour-nice"

mk_sandbox; rm -f "$W/hook-ran"
out="$(CASE_EXTRA="NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-ok" pretend show 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$W/hook-ran" ] && case "$out" in *"opened the tour"*) true;; *) false;; esac; then
    ok "launch: a working launcher runs (foreground) and is reported opened"
else
    bad "launch: working launcher not run/reported (rc=$rc, $out)"
fi
mk_sandbox
out="$(CASE_EXTRA="NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-fail" pretend show 2>&1)"; rc=$?
case "$out" in
    *"launch failed"*) ok "launch: a failing launcher is reported as failed (exit status kept)" ;;
    *) bad "launch: failing launcher reported as success (rc=$rc, $out)" ;;
esac
# Without systemd-run the fallback runs the launcher at nice 19.
mk_sandbox; rm -f "$W/hook-nice"
out="$(CASE_EXTRA="NCZ_TOUR_SR_OK=0 NCZ_TOUR_LAUNCH=$W/stub/tour-nice" pretend show 2>&1)"; rc=$?
if [ "$(cat "$W/hook-nice" 2>/dev/null)" = 19 ]; then
    ok "launch: fallback runs the launcher under nice 19"
else
    bad "launch: fallback niceness is '$(cat "$W/hook-nice" 2>/dev/null)', want 19 ($out)"
fi
# A failing gtk-launch falls through to the singularity-tour binary.
if [ ! -e /opt/singularity/bin/singularity-tour ]; then
    mkdir -p "$W/fall"
    printf '#!/bin/sh\nexit 1\n' >"$W/fall/gtk-launch"
    printf '#!/bin/sh\n: >"%s/fall-ran"\n' "$W" >"$W/fall/singularity-tour"
    chmod +x "$W/fall/gtk-launch" "$W/fall/singularity-tour"
    mk_sandbox; rm -f "$W/fall-ran"
    out="$(PATH="$W/fall:$PATH" CASE_EXTRA="NCZ_TOUR_NICE=0" pretend show 2>&1)"; rc=$?
    i=0; while [ ! -f "$W/fall-ran" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    if [ -f "$W/fall-ran" ]; then
        ok "launch: a failing gtk-launch falls through to singularity-tour"
    else
        bad "launch: failing gtk-launch did not fall through (rc=$rc, $out)"
    fi
else
    ok "launch: fall-through case skipped (real singularity-tour installed on this host)"
fi

# --- SCHED_IDLE, animations off, session state -------------------------------------------------
# The cgroup cpu controller is not delegated on NCZ-OS (43-hw-quirks.sh), so the
# scope's CPUQuota is not enforced there; SCHED_IDLE and animations off are the
# bounds that always hold. Measured: the tour's scene tick redraws every frame
# while the window is visible (50% of a core on HD4000, 55% Sky1, 88% on a
# MacBookPro16,1); with gtk-enable-animations=0 it idles at 0%.
_chrt="$(command -v chrt 2>/dev/null)"
if [ "$_chrt" = /usr/bin/chrt ] || [ "$_chrt" = /bin/chrt ]; then
    printf '#!/bin/sh\nchrt -p $$ >"%s/hook-sched"\nnice >>"%s/hook-sched"\n' "$W" "$W" >"$W/stub/tour-sched"
    chmod +x "$W/stub/tour-sched"
    mk_sandbox; rm -f "$W/hook-sched"
    out="$(CASE_EXTRA="NCZ_TOUR_SR_OK=0 NCZ_TOUR_LAUNCH=$W/stub/tour-sched" pretend show 2>&1)"
    if grep -q 'SCHED_IDLE' "$W/hook-sched" 2>/dev/null && grep -qx 19 "$W/hook-sched"; then
        ok "launch: the tour runs under SCHED_IDLE at nice 19"
    else
        bad "launch: tour not SCHED_IDLE + nice 19 ($(tr '\n' ' ' <"$W/hook-sched" 2>/dev/null) $out)"
    fi
    mk_sandbox; rm -f "$W/hook-sched"
    out="$(CASE_EXTRA="NCZ_TOUR_IDLE=0 NCZ_TOUR_SR_OK=0 NCZ_TOUR_LAUNCH=$W/stub/tour-sched" pretend show 2>&1)"
    if grep -q 'SCHED_OTHER' "$W/hook-sched" 2>/dev/null; then ok "launch: NCZ_TOUR_IDLE=0 keeps the normal policy"; else bad "launch: NCZ_TOUR_IDLE=0 ignored ($(tr '\n' ' ' <"$W/hook-sched" 2>/dev/null))"; fi
else
    ok "launch: SCHED_IDLE case skipped (no chrt at /usr/bin or /bin)"
fi

# Animations off: the launch sees GDK_DEBUG with no-portals and an
# XDG_CONFIG_DIRS led by the runtime dir, whose gtk-4.0/settings.ini turns
# animations off and carries the user's interface settings from GSettings.
mkdir -p "$W/gs"
cat >"$W/gs/gsettings" <<'GS'
#!/bin/sh
[ "$1" = get ] && [ "$2" = org.gnome.desktop.interface ] || exit 1
# GLib writes debug lines to stdout when G_MESSAGES_DEBUG is set (the image sets it).
[ -n "${G_MESSAGES_DEBUG:-}" ] && echo "(process:1): GLib-GIO-DEBUG: 00:00:00.000: noise"
case "$3" in
    font-name) echo "'Adwaita Sans 11'" ;;
    cursor-theme) echo "'Singularity'" ;;
    cursor-size) echo 48 ;;
    icon-theme) echo "'Singularity-pink'" ;;
    gtk-theme) echo "'Adwaita'" ;;
    color-scheme) echo "'prefer-dark'" ;;
    text-scaling-factor) echo 1.25 ;;
    *) exit 1 ;;
esac
GS
chmod +x "$W/gs/gsettings"
# shellcheck disable=SC2016  # the stub expands these when it runs
printf '#!/bin/sh\nprintf "%%s\\n%%s\\n" "$XDG_CONFIG_DIRS" "$GDK_DEBUG" >"%s/hook-env"\n' "$W" >"$W/stub/tour-env"
chmod +x "$W/stub/tour-env"
mk_sandbox; rm -f "$W/hook-env"
out="$(PATH="$W/gs:$PATH" CASE_EXTRA="G_MESSAGES_DEBUG=all NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-env" pretend show 2>&1)"
ini="$S/run/first-login-tour/gtk-4.0/settings.ini"
if [ "$(sed -n 1p "$W/hook-env" 2>/dev/null)" = "$S/run/first-login-tour:/etc/xdg" ] \
   && [ "$(sed -n 2p "$W/hook-env" 2>/dev/null)" = no-portals ]; then
    ok "quiesce: launch gets XDG_CONFIG_DIRS=<runtime>/first-login-tour:... and GDK_DEBUG=no-portals"
else
    bad "quiesce: launch env wrong ($(tr '\n' '|' <"$W/hook-env" 2>/dev/null) $out)"
fi
if grep -qx 'gtk-enable-animations=0' "$ini" 2>/dev/null; then ok "quiesce: settings.ini turns animations off"; else bad "quiesce: settings.ini lacks gtk-enable-animations=0"; fi
want_ini='gtk-font-name=Adwaita Sans 11
gtk-cursor-theme-name=Singularity
gtk-cursor-theme-size=48
gtk-icon-theme-name=Singularity-pink
gtk-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
gtk-xft-dpi=122880'
if [ "$(grep -v -e '^#' -e '^\[Settings\]' -e '^gtk-enable-animations' "$ini" 2>/dev/null)" = "$want_ini" ]; then
    ok "quiesce: settings.ini carries font, cursor, icons, theme, dark scheme and text scale (G_MESSAGES_DEBUG=all)"
else
    bad "quiesce: settings.ini content: $(tr '\n' '|' <"$ini" 2>/dev/null)"
fi
# A GSettings value that is not a plain one-line value is never written.
cat >"$W/gs/gsettings" <<'GS'
#!/bin/sh
case "$3" in font-name) echo "'x]
gtk-enable-animations=1'" ;; icon-theme) echo "'a=b'" ;; *) exit 1 ;; esac
GS
mk_sandbox
out="$(PATH="$W/gs:$PATH" CASE_EXTRA="NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-env" pretend show 2>&1)"
ini="$S/run/first-login-tour/gtk-4.0/settings.ini"
if [ "$(grep -c . "$ini" 2>/dev/null)" = 3 ] && ! grep -q 'gtk-enable-animations=1' "$ini"; then
    ok "quiesce: odd GSettings values are dropped, animations stay off"
else
    bad "quiesce: unexpected settings.ini: $(tr '\n' '|' <"$ini" 2>/dev/null)"
fi
mk_sandbox; rm -f "$W/hook-env"
out="$(CASE_EXTRA="NCZ_TOUR_ANIMATIONS=1 NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-env" pretend show 2>&1)"
if [ "$(sed -n 1p "$W/hook-env" 2>/dev/null)" = "" ] && [ ! -e "$S/run/first-login-tour/gtk-4.0/settings.ini" ]; then
    ok "quiesce: NCZ_TOUR_ANIMATIONS=1 leaves the environment alone"
else
    bad "quiesce: NCZ_TOUR_ANIMATIONS=1 still changed the launch ($(tr '\n' '|' <"$W/hook-env" 2>/dev/null))"
fi

# Session state for wait-done: open after a launch, closed on every other exit.
state_case() {
    local name="$1" want="$2" got
    got="$(cat "$S/run/first-login-tour.state" 2>/dev/null)"
    if [ "$got" = "$want" ]; then ok "$name"; else bad "$name: state '$got', want '$want'"; fi
}
mk_sandbox; CASE_EXTRA="NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-ok" pretend show >/dev/null 2>&1
state_case "state: open after the tour is launched" open
mk_sandbox; CASE_EXTRA="NCZ_TOUR_NICE=0 NCZ_TOUR_LAUNCH=$W/stub/tour-fail" pretend show >/dev/null 2>&1
state_case "state: closed after a failed launch" closed
mk_sandbox; CASE_EXTRA="NCZ_TOUR_DRYRUN=1" pretend show >/dev/null 2>&1
state_case "state: closed after a dry run" closed
mk_sandbox; CASE_LOCKED=1 CASE_EXTRA="NCZ_TOUR_DRYRUN=1" pretend show >/dev/null 2>&1
state_case "state: closed when the session is locked (deferred)" closed
mk_sandbox; mkdir -p "$S/state/ncz"; : >"$S/state/ncz/tour-seen"; pretend show >/dev/null 2>&1
state_case "state: closed on a later login (already shown)" closed

echo "$((PASS + FAIL)) checks, $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
