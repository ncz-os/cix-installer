#!/bin/sh
# test-greeter-scanout-gate.sh -- post-install/55-greeter.sh: the post-greetd
# scanout assertion (ncz-greeter-scanout). A greeter that is up with a dead
# pipeline (DELL .70, 2026-10-27: seatd lost the drmSetMaster race, every
# plane crtc=(null) fb=0, panel black for 16 h; a manual restart lit the
# pipeline instantly) must not stay black:
#   (a) greetd active + an active CRTC appears within the wait -> gate passes
#   (b) greetd active + no active CRTC -> restart greetd once, pass if the
#       pipeline comes up afterwards
#   (c) still no active CRTC after the restart -> fall back to the existing
#       text console path (ncz-greeter-fallback)
#   (d) greetd not active (headless / skipped / still starting) -> do nothing
# The gate is a oneshot: nothing re-triggers it, so it cannot loop.
#
# The real script runs in a hermetic sandbox: the gate is invoked through
# PATH="$SB:/bin:/usr/bin" so its interpreter (sh) and unstubbed tools resolve
# from /bin, while every external command it can reach (systemctl, logger,
# chvt, grep, cat, sleep) is a stub in $SB that reads its state from a state
# dir; fake /sys carries the debugfs drm state files and the connector sysfs
# attrs; the 0.25 s poll is shorted out so each ~10 s wait loop finishes
# instantly. A stub that forgets a case fails loudly.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-install/55-greeter.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-greeter-scanout.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
block() {  # block <heredoc tag> -> body of `cat > ... <<'TAG'` in the hook
    awk -v t="$1" '$0 ~ "<<\x27" t "\x27$" {f=1; next} $0 == t {f=0} f' "$HOOK"
}
block SCANOUT > "$T/scanout"; block SCANUNIT > "$T/unit"
[ -s "$T/scanout" ] && ok "55-greeter.sh writes the scanout script" || no "55-greeter.sh has no SCANOUT block"
[ -s "$T/unit" ] && ok "55-greeter.sh writes the scanout unit" || no "55-greeter.sh has no SCANUNIT block"

# --- the unit: a oneshot after greetd, enabled for the graphical boot ---------
grep -qx 'After=greetd.service' "$T/unit" && ok "unit: After=greetd.service" || no "unit does not order after greetd"
grep -qx 'Type=oneshot' "$T/unit" && ok "unit: Type=oneshot (judges once, cannot loop)" || no "unit is not a oneshot"
grep -qx 'WantedBy=graphical.target' "$T/unit" && ok "unit: WantedBy=graphical.target" || no "unit not wanted by graphical.target"
grep -qx 'ExecStart=/usr/local/sbin/ncz-greeter-scanout' "$T/unit" && ok "unit runs the gate script" || no "unit does not run the script"
sed -n '/^\[Unit\]/,/^\[Service\]/p' "$T/unit" | grep -qE '^(Requires|Requisite|BindsTo|PartOf)=' \
    && no "unit has a hard requirement that could cycle back to greetd" \
    || ok "unit has no hard requirement back to greetd (no cycle: the gate may restart it)"

# --- hermetic sandbox ---------------------------------------------------------
SYS="$T/sys"; SB="$T/bin"; ST="$T/state"
mkdir -p "$SYS/kernel/debug/dri" "$SYS/class/drm" "$SYS/class/dmi/id" \
         "$SYS/devices/virtual/dmi/id" "$SB" "$ST"
# debugfs state files: the crtc[N] header line followed by the enable/active
# line -- the exact shape the DELL .70 diagnosis read ("crtc[54] pipe A
# enable=1 active=1, primary fb=115" after the restart; crtc=(null), fb=0
# while the pipeline was dead).
ACTIVE_STATE='crtc[54] [4098]  eDP-1
    enable=1 active=1
    primary fb=115
'
DEAD_STATE='crtc[0] [899]  eDP-1
    enable=1 active=0
    primary fb=0
'
# crtc_active() must satisfy on either source: the debugfs state pair above,
# or the connector sysfs fallback (enabled + connected) when state is absent.
# card9 is unambiguous for the gate's card[0-9]*.state glob.
cat > "$SB/mkstate" <<MKS
#!/bin/sh
# mkstate <active|dead|none>
case "\$1" in
    active) printf '%s\n' "$ACTIVE_STATE" > "$SYS/kernel/debug/dri/card9.state" ;;
    dead)   printf '%s\n' "$DEAD_STATE"   > "$SYS/kernel/debug/dri/card9.state" ;;
    none)   rm -f "$SYS/kernel/debug/dri/card9.state" ;;
esac
MKS
# connector sysfs: present + connected + enabled (the fallback source)
mkdir -p "$SYS/class/drm/eDP-1"
echo connected > "$SYS/class/drm/eDP-1/status"
echo enabled   > "$SYS/class/drm/eDP-1/enabled"

# Stubs are written with an UNQUOTED heredoc so the test shell expands
# $SYS/$ST/$SB/$ACTIVE_STATE/$DEAD_STATE into the stub bodies at write time
# (a quoted heredoc would leave them literal and the stubs would target empty
# paths). $1/$* are escaped so they survive to the stub's own shell.
cat > "$SB/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$ST/actions.log"
case "\$1" in
    is-active)
        if [ -f "$ST/greetd-active" ]; then exit 0; else exit 3; fi ;;
    restart)
        [ -f "$ST/restart-heals" ] && exec "$SB/mkstate" active ;;
esac
exit 0
STUB
cat > "$SB/logger" <<'LOGGERSTUB'
#!/bin/sh
[ -n "${FLOG:-}" ] && echo "$*" >> "${FLOG}"
exit 0
LOGGERSTUB
printf '#!/bin/sh\nexit 0\n' > "$SB/chvt"
# The gate's 0.25 s poll: instant, so the ~10 s loops finish in milliseconds.
printf '#!/bin/sh\nexit 0\n' > "$SB/sleep"
# Host-tool shims: the gate's grep/cat run the real binaries against the
# sandbox /sys paths.
# Host-tool shims: the gate's grep/cat run the real binaries against the
# sandbox /sys paths. Written with a quoted heredoc (no test-shell expansion
# needed) and $@ unquoted so each argument is passed separately -- quoting $@
# would collapse all args into one string and grep would see one bogus arg.
cat > "$SB/grep" <<'GREPSTUB'
#!/bin/sh
exec /usr/bin/grep $@
GREPSTUB
cat > "$SB/cat" <<'CATSTUB'
#!/bin/sh
exec /usr/bin/cat $@
CATSTUB
chmod +x "$SB/"*

reset_state() {  # reset_state <active|dead|none>
    rm -f "$ST/actions.log" "$ST/restart-heals" "$T/journal"
    "$SB/mkstate" "$1"
}
reset_greetd() {  # reset_greetd <active|inactive>
    rm -f "$ST/greetd-active"
    [ "$1" = active ] && touch "$ST/greetd-active"
}
run_gate() {  # run_gate -> exit code; journal in $T/journal, actions in $ST/actions.log
    PATH="$SB:/bin:/usr/bin" \
    FLOG="$T/journal" \
    /bin/sh <(sed -e "s#/sys/kernel/debug/dri#$SYS/kernel/debug/dri#g" \
             -e "s#/sys/class/drm#$SYS/class/drm#g" \
             -e "s#/sys/class/dmi#$SYS/class/dmi#g" \
             -e "s#/sys/devices/virtual/dmi#$SYS/devices/virtual/dmi#g" \
             "$T/scanout")
}
acts() { [ -f "$ST/actions.log" ] && cat "$ST/actions.log"; }
# Real actions = restart/start (the is-active query is a read, not an action)
real_acts() { acts 2>/dev/null | grep -vE '^is-active '; }

# (a) greetd active + active CRTC -> passes, no restart, no fallback
reset_state active; reset_greetd active
run_gate; rc=$?
[ "$rc" = 0 ] && ok "(a) active CRTC: gate exits 0" || no "(a) active CRTC: gate rc=$rc: $(cat "$T/journal" 2>/dev/null)"
[ -z "$(real_acts)" ] && ok "(a) active CRTC: no systemctl action taken (restart/start)" || no "(a) active CRTC: unexpected action: $(real_acts)"
grep -q 'scanout gate passed' "$T/journal" && ok "(a) active CRTC: diagnostic says passed" || no "(a) no pass diagnostic: $(cat "$T/journal")"

# (b) greetd active + dead pipeline, the restart heals it -> restart once, pass
reset_state dead; reset_greetd active; touch "$ST/restart-heals"
run_gate; rc=$?
[ "$rc" = 0 ] && ok "(b) dead pipeline healed by restart: gate exits 0" || no "(b) rc=$rc"
[ "$(grep -c 'restart greetd.service' "$ST/actions.log" 2>/dev/null)" = 1 ] \
    && ok "(b) dead pipeline: greetd restarted exactly once" || no "(b) restart count wrong: $(acts)"
! grep -q 'ncz-greeter-fallback' "$ST/actions.log" 2>/dev/null \
    && ok "(b) dead pipeline healed: no fallback after the recovering restart" || no "(b) fallback fired: $(acts)"
grep -q 'restarting greetd once' "$T/journal" && ok "(b) dead pipeline: diagnostic names the restart" || no "(b) no restart diagnostic: $(cat "$T/journal")"

# (c) greetd active + pipeline dead AND the restart does NOT heal it ->
# fall back to the existing text console path.
reset_state dead; reset_greetd active
run_gate; rc=$?
[ "$rc" = 0 ] && ok "(c) restart did not help: gate exits 0 (fallback path is non-fatal)" || no "(c) rc=$rc"
grep -q 'start ncz-greeter-fallback.service' "$ST/actions.log" 2>/dev/null \
    && ok "(c) restart did not help: ncz-greeter-fallback started" \
    || no "(c) no fallback: $(acts)"
[ "$(grep -c 'restart greetd.service' "$ST/actions.log" 2>/dev/null)" = 1 ] \
    && ok "(c) restart happened exactly once before the fallback (no loop)" \
    || no "(c) restart count wrong: $(acts)"
grep -q 'falling back' "$T/journal" && ok "(c) diagnostic names the fallback" || no "(c) no fallback diagnostic"

# (d) greetd not active -> nothing happens (headless KVM / skipped / starting)
reset_state dead; reset_greetd inactive
run_gate; rc=$?
[ "$rc" = 0 ] && ok "(d) greetd inactive: gate exits 0" || no "(d) rc=$rc"
[ -z "$(real_acts)" ] && ok "(d) greetd inactive: no restart, no fallback" || no "(d) unexpected action: $(real_acts)"
grep -q 'not active' "$T/journal" && ok "(d) greetd inactive: diagnostic says gate not applicable" || no "(d) no inactive diagnostic: $(cat "$T/journal")"

# (d2) greetd not active + active CRTC (console already scanning) is also a no-op
reset_state active; reset_greetd inactive
run_gate; rc=$?
[ "$rc" = 0 ] && [ -z "$(real_acts)" ] && ok "(d2) inactive greetd + lit console: no-op" || no "(d2) wrong: $(real_acts)"

# --- the predicate must be the debugfs drm state with a sysfs fallback ------
# The gate enumerates /sys with POSIX globs (a bare shell for-list glob does
# not work in dash: it is not word-split), so the source carries literal glob
# patterns -- check them as fixed strings, and the CRTC-header + enable/active
# regexes as EREs.
grep -qF '/sys/kernel/debug/dri/' "$T/scanout" && grep -qF 'card[0-9]*.state' "$T/scanout" \
    && ok "predicate reads the drm debugfs state (glob card[0-9]*.state)" \
    || no "predicate does not read the drm debugfs state"
# The gate source carries the raw ERE patterns; check them as fixed strings
# (grep -F) since they contain backslashes that an ERE check would re-escape.
grep -qF 'crtc\[[0-9]+\]' "$T/scanout" && grep -qF 'enable=1[[:space:]]+active=1' "$T/scanout" \
    && ok "predicate matches a crtc[N] header with an enable=1 active=1 line" \
    || no "predicate regex wrong"
grep -qF '/sys/class/drm/' "$T/scanout" && grep -qF 'card[0-9]*-[0-9]/enabled' "$T/scanout" \
    && ok "predicate has the /sys/class/drm connector fallback (glob card[0-9]*-[0-9]/enabled)" \
    || no "no sysfs fallback in the predicate"

# --- idempotence: the unit has no Restart= and nothing re-triggers it -------
grep -q '^Restart=' "$T/unit" && no "unit has Restart= (could loop)" || ok "unit has no Restart= (the oneshot runs once per boot)"

echo "test-greeter-scanout-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
