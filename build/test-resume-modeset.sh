#!/bin/bash
# test-resume-modeset.sh -- regression test for post-install/67-ncz-resume-modeset.sh,
# the ncz-resume-modeset helper and the system-sleep hook it installs.
#
# The bug it guards: after ANY S3 resume the internal panel flickers (desktop and
# lock-screen saver) although the kernel log is clean; a full output off/on cycle
# through the compositor cures it. The hook re-modesets the INTERNAL panel on every
# amd64 machine (not only T2 Macs) and never on arm64/Sky1 (an output off/on cycle
# wedges the Sky1 DP AUX engine).
#
# Everything runs against stubs (wlr-randr, runuser, logger, systemd-run) and fake
# /run trees with real unix sockets; nothing touches the real compositor, /etc or
# systemd.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/post-install/67-ncz-resume-modeset.sh"
LIB="$ROOT/post-install/lib/ncz-resume-modeset"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
chk() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

ME="$(id -un)"
STUB="$T/stub"; mkdir -p "$STUB"
CALLS="$T/calls"; LOG="$T/log"

# --- stubs ------------------------------------------------------------------
# wlr-randr: no args => print $T/outputs.<WAYLAND_DISPLAY dir>; --output => record.
cat > "$STUB/wlr-randr" <<'STUBEOF'
#!/bin/bash
key="$(basename "$XDG_RUNTIME_DIR")"
if [ "$#" = 0 ]; then cat "$NCZ_T/outputs.$key" 2>/dev/null; exit 0; fi
echo "owner=${STUB_OWNER:-?} xdg=$key disp=$WAYLAND_DISPLAY $*" >> "$NCZ_T/calls"
[ -e "$NCZ_T/fail-off.$key" ] && [ "${3:-}" = "--off" ] && exit 1
exit 0
STUBEOF
# runuser -u <owner> -- cmd...
cat > "$STUB/runuser" <<'STUBEOF'
#!/bin/bash
[ -e "$NCZ_T/runuser-fails" ] && exit 1
[ "$1" = -u ] || exit 2
export STUB_OWNER="$2"; shift 3
exec "$@"
STUBEOF
cat > "$STUB/logger" <<'STUBEOF'
#!/bin/bash
shift 2; echo "$*" >> "$NCZ_T/log"
STUBEOF
chmod +x "$STUB"/*
export NCZ_T="$T"

mksock() { python3 - "$1" <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()
PYEOF
}
OUT_MIXED='eDP-1 "Apple Computer Inc Color LCD (eDP-1)"
  Make: Apple Computer Inc
  Enabled: yes
  Modes:
    3072x1920 px, 60.000000 Hz (preferred, current)
HDMI-A-1 "Dock monitor"
  Enabled: yes
DP-2 "Other monitor"
  Enabled: yes
eDP-2 "Second internal, disabled by the user"
  Enabled: no
LVDS-1 "Old laptop panel"
  Enabled: yes
Virtual-1 "virtual"
  Enabled: yes'

RUNTIME="$T/run"
reset_run() {
    rm -rf "$RUNTIME" "$CALLS" "$LOG" "$T"/outputs.* "$T"/fail-off.* "$T/runuser-fails"
    mkdir -p "$RUNTIME/user/1000" "$RUNTIME/user/1001"
    mksock "$RUNTIME/user/1000/wayland-0"     # the logged-in session
    mksock "$RUNTIME/user/1001/wayland-0"     # the greeter compositor
    printf '%s\n' "$OUT_MIXED" > "$T/outputs.1000"
    printf '%s\n' "$OUT_MIXED" > "$T/outputs.1001"
}
HELPER() { # run the helper against the stubs
    env NCZ_RMS_RUNTIME_ROOT="$RUNTIME" NCZ_RMS_WLR_RANDR="$STUB/wlr-randr" \
        NCZ_RMS_RUNUSER="$STUB/runuser" NCZ_RMS_LOGGER="$STUB/logger" \
        NCZ_RMS_STAT="${NCZ_RMS_STAT_OVERRIDE:-stat}" NCZ_RMS_OFF_DELAY=0.1 NCZ_RMS_TRIES=3 NCZ_RMS_TRY_DELAY=0.1 NCZ_RMS_TIMEOUT=5 "$@" bash "$LIB" >"$T/helper.out" 2>&1
}

# === installer ===============================================================
TROOT="$T/root"
env NCZ_TARGET_ARCH=amd64 NCZ_RESUME_MODESET_ROOT="$TROOT" bash "$INSTALLER" >"$T/inst.out" 2>&1; rc=$?
H="$TROOT/usr/local/sbin/ncz-resume-modeset"
K="$TROOT/usr/lib/systemd/system-sleep/ncz-resume-modeset"
[ "$rc" = 0 ] && [ -x "$H" ] && [ -x "$K" ]; chk $? "installer (amd64) installs the helper and the system-sleep hook"
cmp -s "$H" "$LIB"; chk $? "installed helper is byte-identical to post-install/lib/ncz-resume-modeset"
[ "$(stat -c %a "$H")" = 755 ] && [ "$(stat -c %a "$K")" = 755 ]; chk $? "helper and hook are mode 0755"
env NCZ_TARGET_ARCH=amd64 NCZ_RESUME_MODESET_ROOT="$TROOT" bash "$INSTALLER" >/dev/null 2>&1; chk $? "installer is idempotent (second run exits 0)"
rm -rf "$T/root-arm"
env NCZ_TARGET_ARCH=arm64 NCZ_RESUME_MODESET_ROOT="$T/root-arm" bash "$INSTALLER" >"$T/inst-arm.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/root-arm/usr/local/sbin/ncz-resume-modeset" ] && [ ! -e "$T/root-arm/usr/lib/systemd/system-sleep/ncz-resume-modeset" ]
chk $? "installer on arm64 installs nothing and exits 0 (Sky1 DP AUX wedge)"
grep -q "Sky1" "$T/inst-arm.out"; chk $? "arm64 refusal says why"
# the hook is NOT DMI/T2 gated: a generic PC (no DMI at all) still installs it
rm -rf "$T/root-pc"; env NCZ_TARGET_ARCH=amd64 NCZ_DMI_ROOT="$T/nodmi" NCZ_RESUME_MODESET_ROOT="$T/root-pc" bash "$INSTALLER" >/dev/null 2>&1
[ -x "$T/root-pc/usr/lib/systemd/system-sleep/ncz-resume-modeset" ]; chk $? "installs on a generic PC too (no T2/DMI gate)"
! grep -q -E "ncz_is_t2_hardware|product_name|sys_vendor" "$INSTALLER" "$LIB"; chk $? "no T2/DMI gating anywhere in the installer or helper"

# === system-sleep hook =======================================================
cat > "$STUB/systemd-run" <<'STUBEOF'
#!/bin/bash
echo "$*" >> "$NCZ_T/sdrun"
STUBEOF
cat > "$STUB/fake-helper" <<'STUBEOF'
#!/bin/bash
echo "helper-ran" >> "$NCZ_T/helper-ran"
STUBEOF
chmod +x "$STUB/systemd-run" "$STUB/fake-helper"
HOOK() { env PATH="$STUB:$PATH" NCZ_RMS_HELPER="$STUB/fake-helper" bash "$K" "$@"; }
rm -f "$T/sdrun" "$T/helper-ran"
t0=$(date +%s.%N); HOOK post suspend; rc=$?; t1=$(date +%s.%N)
[ "$rc" = 0 ] && grep -q -- "--no-block" "$T/sdrun" && grep -q -- "--on-active=500ms" "$T/sdrun" && grep -q "fake-helper" "$T/sdrun"
chk $? "hook 'post suspend' schedules the helper with systemd-run --no-block --on-active=500ms"
awk -v a="$t0" -v b="$t1" 'BEGIN{exit !((b-a) < 1.0)}'; chk $? "hook returns immediately (never delays the resume)"
for a in "post hibernate" "post hybrid-sleep" "post suspend-then-hibernate"; do
    rm -f "$T/sdrun"; HOOK $a; [ -s "$T/sdrun" ]; chk $? "hook '$a' schedules the helper"
done
for a in "pre suspend" "pre hibernate" "post poweroff" "post"; do
    rm -f "$T/sdrun"; HOOK $a; rc=$?; [ ! -e "$T/sdrun" ] && [ "$rc" = 0 ]; chk $? "hook '$a' does nothing and exits 0"
done
rm -f "$T/sdrun"; env PATH="$STUB:$PATH" NCZ_RMS_HELPER="$T/missing" bash "$K" post suspend; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/sdrun" ]; chk $? "hook with the helper missing does nothing and exits 0"
# systemd-run failing => detached fallback still runs the helper, still without blocking
printf '#!/bin/bash\nexit 1\n' > "$STUB/systemd-run"
rm -f "$T/helper-ran"; t0=$(date +%s.%N); HOOK post suspend; rc=$?; t1=$(date +%s.%N)
awk -v a="$t0" -v b="$t1" 'BEGIN{exit !((b-a) < 1.0)}'; chk $? "hook fallback (systemd-run failing) returns immediately"
n=0; while [ $n -lt 40 ] && [ ! -e "$T/helper-ran" ]; do sleep 0.2; n=$((n + 1)); done
[ -e "$T/helper-ran" ] && [ "$rc" = 0 ]; chk $? "hook fallback still runs the helper, detached"

# === helper ==================================================================
reset_run; HELPER; rc=$?
[ "$rc" = 0 ]; chk $? "helper exits 0"
for u in 1000 1001; do
    grep -q "xdg=$u disp=wayland-0 --output eDP-1 --off" "$CALLS" && grep -q "xdg=$u disp=wayland-0 --output eDP-1 --on" "$CALLS"
    chk $? "socket of uid $u (session / greeter): eDP-1 off then on"
    a=$(grep -n "xdg=$u .*--output eDP-1 --off" "$CALLS" | head -1 | cut -d: -f1)
    b=$(grep -n "xdg=$u .*--output eDP-1 --on" "$CALLS" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; chk $? "uid $u: --off comes before --on"
done
grep -q "owner=$ME " "$CALLS"; chk $? "wlr-randr runs as the socket's owner (runuser -u <owner>)"
grep -q "LVDS-1 --off" "$CALLS"; chk $? "LVDS internal panels are re-modeset too"
! grep -q -E "HDMI-A-1|DP-2|Virtual-1" "$CALLS"; chk $? "external and virtual outputs are never touched"
! grep -q "eDP-2" "$CALLS"; chk $? "an internal panel that is not enabled is never switched on"
! grep -q -- "--mode" "$CALLS"; chk $? "no --mode is passed (the previous mode is kept)"
grep -c "re-modeset" "$LOG" | grep -q '^4$'; chk $? "one journal line per re-modeset (4: two sockets x eDP-1, LVDS-1)"
# failure isolation
reset_run; : > "$T/fail-off.1000"; HELPER; rc=$?
grep -q "xdg=1000 .*eDP-1 --on" "$CALLS" && grep -q "xdg=1001 .*eDP-1 --on" "$CALLS" && [ "$rc" = 0 ]
chk $? "a failing --off on one socket still attempts --on there, still serves the other socket, exits 0"
reset_run; : > "$T/runuser-fails"; HELPER; rc=$?
[ "$rc" = 0 ] && [ ! -e "$CALLS" ]; chk $? "runuser failing => nothing happens and the helper still exits 0"
# compositor not answering yet right after resume: the helper retries, then acts
reset_run; rm -f "$T/outputs.1000" "$T/outputs.1001"
( sleep 0.15; printf '%s\n' "$OUT_MIXED" > "$T/outputs.1000"; printf '%s\n' "$OUT_MIXED" > "$T/outputs.1001" ) &
rdy=$!; HELPER; rc=$?; wait "$rdy" 2>/dev/null
[ "$rc" = 0 ] && grep -q "xdg=1000 .*eDP-1 --off" "$CALLS" && grep -q "xdg=1001 .*eDP-1 --on" "$CALLS"
chk $? "a compositor that is not ready yet is retried and then re-modeset"
reset_run; rm -f "$T/outputs.1000" "$T/outputs.1001"; HELPER; rc=$?
[ "$rc" = 0 ] && [ ! -e "$CALLS" ] && grep -q "after 3 tries" "$LOG"; chk $? "a compositor that never answers: gives up after the retries, quietly, exit 0"
# no-op paths
reset_run; env NCZ_RMS_RUNTIME_ROOT="$RUNTIME" NCZ_RMS_WLR_RANDR="$T/no-such-wlr-randr" NCZ_RMS_RUNUSER="$STUB/runuser" NCZ_RMS_LOGGER="$STUB/logger" bash "$LIB" >"$T/helper.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/helper.out" ] && [ ! -e "$CALLS" ]; chk $? "no wlr-randr => silent exit 0, no calls"
reset_run; rm -rf "$RUNTIME/user"/*; HELPER; rc=$?
[ "$rc" = 0 ] && [ ! -e "$CALLS" ]; chk $? "no compositor socket => exit 0, no calls"
reset_run; mv "$RUNTIME/user/1000/wayland-0" "$RUNTIME/user/1000/wayland-0.lock"; rm -rf "$RUNTIME/user/1001"; HELPER
[ ! -e "$CALLS" ]; chk $? "a *.lock socket is ignored"
reset_run; rm -f "$T/outputs.1000" "$T/outputs.1001"; HELPER; rc=$?
[ "$rc" = 0 ] && [ ! -e "$CALLS" ]; chk $? "a compositor that lists no outputs => nothing happens, exit 0"
# overlapping resumes: the lock makes the second run skip
reset_run
( exec 9>"$RUNTIME/ncz-resume-modeset.lock"; flock -n 9 && sleep 3 ) &
holder=$!; sleep 0.3
HELPER; rc=$?
[ "$rc" = 0 ] && [ ! -e "$CALLS" ] && grep -q "skipped" "$LOG"; chk $? "an overlapping run is skipped (flock) and says so"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
reset_run; HELPER; [ -s "$CALLS" ]; chk $? "once the lock is free the helper runs normally again"

# === socket trust (the helper runs as root and drops to the socket owner) =====
# stat stub: a path listed in $T/stat-uid ("<path> <uid>") reports that uid, anything else is real stat
cat > "$STUB/stat" <<'STUBEOF'
#!/bin/bash
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%u" ] && [ -r "$NCZ_T/stat-uid" ]; then
    while read -r p u; do [ "$p" = "${3:-}" ] && { echo "$u"; exit 0; }; done < "$NCZ_T/stat-uid"
fi
exec stat "$@"
STUBEOF
chmod +x "$STUB/stat"
STATRUN() { NCZ_RMS_STAT_OVERRIDE="$STUB/stat" HELPER; }
reset_run; rm -rf "$RUNTIME/user/1001"; mkdir -p "$RUNTIME/user/1001"
ln -s "$RUNTIME/user/1000/wayland-0" "$RUNTIME/user/1001/wayland-0"
HELPER
! grep -q "xdg=1001" "$CALLS" && grep -q "xdg=1000 .*eDP-1 --off" "$CALLS"
chk $? "a symlink in a runtime dir (even to a real socket) is skipped; the real session socket still works"
reset_run; rm -f "$T/stat-uid"; printf '%s 4242\n' "$RUNTIME/user/1001/wayland-0" > "$T/stat-uid"; STATRUN
! grep -q "xdg=1001" "$CALLS" && grep -q "xdg=1000 .*eDP-1 --on" "$CALLS" && grep -q "owner differs" "$LOG"
chk $? "a socket whose owner differs from its runtime dir owner is skipped (and logged); the other socket still works"
reset_run; printf '%s 0\n%s 0\n' "$RUNTIME/user/1001/wayland-0" "$RUNTIME/user/1001" > "$T/stat-uid"; STATRUN
! grep -q "xdg=1001" "$CALLS" && grep -q "xdg=1000 .*eDP-1 --off" "$CALLS"
chk $? "uid 0 (socket and dir both root) is never used"
rm -f "$T/stat-uid"
reset_run; HELPER
grep -q "xdg=1000 " "$CALLS" && grep -q "xdg=1001 " "$CALLS"
chk $? "normal session and greeter sockets are still handled after the hardening"
grep -q "owner=$ME " "$CALLS"; chk $? "the account name is derived from the checked uid (id -nu)"

# === registration ============================================================
grep -q "^67-ncz-resume-modeset.sh$" "$ROOT/post-install/hooks.list.amd64"; chk $? "listed in hooks.list.amd64"
! grep -q "67-ncz-resume-modeset" "$ROOT/post-install/hooks.list.sky1-arm64"; chk $? "NOT listed in hooks.list.sky1-arm64"
for p in post-install/67-ncz-resume-modeset.sh post-install/lib/ncz-resume-modeset build/test-resume-modeset.sh; do
    grep -q "^$p	" "$ROOT/docs/platform-inventory.tsv"; chk $? "platform-inventory has a row for $p"
done
grep -q "test-resume-modeset.sh" "$ROOT/Makefile"; chk $? "test is wired into the Makefile"
# The installer only runs hooks named in run-all.sh (MACHINE_HOOKS_RE / REQUIRED_HOOKS); an unlisted hook is
# reported ORPHAN and silently never runs. r2g shipped the hook on disk but never ran it for that reason.
bash "$ROOT/build/check-hook-registration.sh" >/dev/null 2>&1; chk $? "67-ncz-resume-modeset is registered in an execution list (check-hook-registration)"
grep -q "check-hook-registration.sh" "$ROOT/Makefile"; chk $? "the hook registration check is wired into the Makefile"
bash -n "$LIB" && bash -n "$INSTALLER"; chk $? "bash -n on the helper and the installer"

echo "resume modeset tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
