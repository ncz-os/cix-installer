#!/bin/bash
# test-t2-power-cap.sh -- regression test for post-install/64-t2-power-cap.sh
# and the ncz-t2-power-cap helper it installs.
#
# The bug it guards: on MacBookPro16,1 the firmware RAPL package limits are
# PL1=100 W / PL2=125 W; heavy CPU load trips the SMC/BMS hard power cut. The
# hook installs a cap (battery 25/35 W + no-turbo + max_perf 50; AC 45/60 W)
# applied at boot (intel-rapl:0 udev add), on plug/unplug (Mains change), on
# resume (systemd-sleep) and before thermald (drop-in ExecStartPre).
#
# Everything runs against a FAKE sysfs tree; nothing here touches the real
# /sys, /etc or systemd. See the hook header for the test seams.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/64-t2-power-cap.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

SYS="$T/sys"
TROOT="$T/root"

# --- fake sysfs -----------------------------------------------------------
mk_sysfs() {
    local product="$1" ac="$2"
    rm -rf "$SYS"
    mkdir -p "$SYS/cpu/intel_pstate" \
             "$SYS/powercap/intel-rapl:0" \
             "$SYS/powercap/intel-rapl:0:0" \
             "$SYS/psu/ADP1" "$SYS/psu/BAT0" \
             "$SYS/dmi"
    printf '0\n'        > "$SYS/cpu/intel_pstate/no_turbo"
    printf '100\n'      > "$SYS/cpu/intel_pstate/max_perf_pct"
    # writable limits
    printf '100000000\n' > "$SYS/powercap/intel-rapl:0/constraint_0_power_limit_uw"
    printf '125000000\n' > "$SYS/powercap/intel-rapl:0/constraint_1_power_limit_uw"
    # read-only ceilings (must never be written)
    printf '45000000\n'  > "$SYS/powercap/intel-rapl:0/constraint_0_max_power_uw"
    printf '0\n'         > "$SYS/powercap/intel-rapl:0/constraint_1_max_power_uw"
    printf 'Mains\n'    > "$SYS/psu/ADP1/type"
    printf '%s\n' "$ac" > "$SYS/psu/ADP1/online"
    printf 'Battery\n'  > "$SYS/psu/BAT0/type"
    printf 'Discharging\n' > "$SYS/psu/BAT0/status"
    printf '%s\n' "$product" > "$SYS/dmi/product_name"
    printf 'Apple Inc.\n' > "$SYS/dmi/sys_vendor"
}
ac_off() { printf '0\n' > "$SYS/psu/ADP1/online"; }
ac_on()  { printf '1\n' > "$SYS/psu/ADP1/online"; }

# --- install once ---------------------------------------------------------
# The hook's "is there an Intel RAPL/pstate platform" plausibility probe reads
# the real /sys or, under the test root, $ROOT/sys. Stage it so the hook runs.
mkdir -p "$TROOT/sys/devices/system/cpu/intel_pstate"
HOOKRUN() { # run the hook against the test root
    env NCZ_T2_POWER_CAP_ROOT="$TROOT" NCZ_T2_POWER_CAP_ASSUME_T2=1 \
        bash "$HOOK" >"$T/hook.out" 2>&1
}
HOOKRUN
rc=$?
HELPER="$TROOT/usr/local/sbin/ncz-t2-power-cap"
CONF="$TROOT/etc/ncz/power-cap.conf"
if [ "$rc" = 0 ] && [ -x "$HELPER" ]; then ok "hook installs the helper"; else bad "helper not installed (rc=$rc): $(tail -3 "$T/hook.out")"; fi
for f in "$CONF" \
         "$TROOT/etc/udev/rules.d/72-ncz-t2-power-cap.rules" \
         "$TROOT/usr/lib/systemd/system-sleep/ncz-t2-power-cap" \
         "$TROOT/etc/systemd/system/thermald.service.d/10-ncz-t2-power-cap.conf"; do
    if [ -s "$f" ]; then ok "installed $(basename "$f")"; else bad "missing $f"; fi
done
[ -x "$TROOT/usr/lib/systemd/system-sleep/ncz-t2-power-cap" ] && ok "sleep hook is executable" || bad "sleep hook not executable"

# udev rule covers the boot race (rapl add) and plug/unplug (Mains change)
if grep -q 'KERNEL=="intel-rapl:0"' "$TROOT/etc/udev/rules.d/72-ncz-t2-power-cap.rules" \
   && grep -q 'SUBSYSTEM=="powercap"' "$TROOT/etc/udev/rules.d/72-ncz-t2-power-cap.rules"; then
    ok "udev rule arms on the intel-rapl:0 powercap add event (boot race)"
else bad "udev rule does not cover the rapl add event"; fi
if grep -q 'SUBSYSTEM=="power_supply"' "$TROOT/etc/udev/rules.d/72-ncz-t2-power-cap.rules" \
   && grep -q 'ATTR{type}=="Mains"' "$TROOT/etc/udev/rules.d/72-ncz-t2-power-cap.rules"; then
    ok "udev rule re-applies on the Mains change event"
else bad "udev rule does not cover plug/unplug"; fi
grep -q 'ExecStartPre=.*ncz-t2-power-cap apply' "$TROOT/etc/systemd/system/thermald.service.d/10-ncz-t2-power-cap.conf" \
    && ok "thermald drop-in runs the cap before thermald starts" || bad "thermald drop-in missing ExecStartPre"

# --- helper against the fake tree ----------------------------------------
RH() { # run installed helper with fake paths
    env NCZ_POWERCAP_CONF="$CONF" \
        NCZ_POWERCAP_SYS_CPU="$SYS/cpu" \
        NCZ_POWERCAP_SYS_RAPL="$SYS/powercap" \
        NCZ_POWERCAP_SYS_PSU="$SYS/psu" \
        NCZ_POWERCAP_DMI="$SYS/dmi" \
        NCZ_POWERCAP_RUN="$T/run" \
        NCZ_POWERCAP_NO_JOURNAL=1 \
        bash "$HELPER" "$@" >"$T/helper.out" 2>&1
}
get() { cat "$SYS/powercap/intel-rapl:0/$1" 2>/dev/null; }

# AC default: 45/60 W, turbo/max_perf untouched
mk_sysfs MacBookPro16,1 1; mkdir -p "$T/run"
RH apply --wait 2; rc=$?
if [ "$rc" = 0 ] && [ "$(get constraint_0_power_limit_uw)" = 45000000 ] && [ "$(get constraint_1_power_limit_uw)" = 60000000 ]; then
    ok "AC applies PL1=45 W / PL2=60 W"
else bad "AC PL1/PL2 wrong (rc=$rc): $(get constraint_0_power_limit_uw)/$(get constraint_1_power_limit_uw)"; fi
if [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 0 ] && [ "$(cat "$SYS/cpu/intel_pstate/max_perf_pct")" = 100 ]; then
    ok "AC leaves turbo / max_perf at firmware values"
else bad "AC changed turbo/max_perf"; fi
# read-only ceilings untouched
if [ "$(get constraint_0_max_power_uw)" = 45000000 ] && [ "$(get constraint_1_max_power_uw)" = 0 ]; then
    ok "never writes constraint_N_max_power_uw (read-only ceiling)"
else bad "max_power_uw was modified"; fi

# battery: 25/35 W + no_turbo 1 + max_perf 50
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
RH apply --wait 2; rc=$?
if [ "$rc" = 0 ] && [ "$(get constraint_0_power_limit_uw)" = 25000000 ] && [ "$(get constraint_1_power_limit_uw)" = 35000000 ]; then
    ok "battery applies PL1=25 W / PL2=35 W"
else bad "battery PL1/PL2 wrong (rc=$rc): $(get constraint_0_power_limit_uw)/$(get constraint_1_power_limit_uw)"; fi
if [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 1 ] && [ "$(cat "$SYS/cpu/intel_pstate/max_perf_pct")" = 50 ]; then
    ok "battery disables turbo and caps max_perf_pct=50"
else bad "battery turbo/max_perf wrong"; fi

# restore returns the captured baseline (firmware 100/125, no_turbo 0, 100)
RH restore --wait 2; rc=$?
if [ "$rc" = 0 ] && [ "$(get constraint_0_power_limit_uw)" = 100000000 ] \
   && [ "$(get constraint_1_power_limit_uw)" = 125000000 ] \
   && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 0 ] \
   && [ "$(cat "$SYS/cpu/intel_pstate/max_perf_pct")" = 100 ]; then
    ok "restore writes the captured firmware baseline back"
else bad "restore wrong (rc=$rc): $(get constraint_0_power_limit_uw)/$(get constraint_1_power_limit_uw)/$(cat "$SYS/cpu/intel_pstate/no_turbo")"; fi
[ -s "$T/run/ncz-t2-power-cap.baseline" ] && ok "baseline file captured" || bad "no baseline captured"

# replay: apply is idempotent and keeps the same numbers
RH apply --wait 2; a1="$(get constraint_0_power_limit_uw)"
RH apply --wait 2; a2="$(get constraint_0_power_limit_uw)"
[ "$a1" = "$a2" ] && [ "$a1" = 25000000 ] && ok "apply is idempotent" || bad "apply not idempotent ($a1 vs $a2)"

# performance mode: AC uncapped (firmware), battery still capped
mk_sysfs MacBookPro16,1 1; rm -rf "$T/run"; mkdir -p "$T/run"
printf '\nNCZ_T2_POWER_MODE=performance\n' >> "$CONF"
RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 100000000 ] && [ "$(get constraint_1_power_limit_uw)" = 125000000 ]; then
    ok "performance mode leaves AC uncapped (firmware 100/125 W)"
else bad "performance AC wrong: $(get constraint_0_power_limit_uw)/$(get constraint_1_power_limit_uw)"; fi
ac_off; RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 25000000 ] && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 1 ]; then
    ok "performance mode keeps the battery cap (safety)"
else bad "performance battery not capped"; fi
# undo the mode line for later tests
grep -v '^NCZ_T2_POWER_MODE=performance$' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"

# NCZ_T2_POWER_CAP=0 -> no writes at all
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
printf '\nNCZ_T2_POWER_CAP=0\n' >> "$CONF"
RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 100000000 ] && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 0 ]; then
    ok "NCZ_T2_POWER_CAP=0 disables every write"
else bad "cap=0 still wrote"; fi
grep -v '^NCZ_T2_POWER_CAP=0$' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"

# product gate: a non-MacBookPro16 T2 Mac is untouched by default
mk_sysfs MacBookPro15,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
RH apply --wait 2; rc=$?
if [ "$rc" = 0 ] && [ "$(get constraint_0_power_limit_uw)" = 100000000 ] && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 0 ]; then
    ok "non-enforce product is left untouched (exit 0)"
else bad "product gate failed (rc=$rc)"; fi
# ... but FORCE=1 enables it
printf '\nNCZ_T2_POWER_FORCE=1\n' >> "$CONF"
RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 25000000 ]; then ok "NCZ_T2_POWER_FORCE=1 enforces on other T2 Macs"; else bad "FORCE did not enforce"; fi
grep -v '^NCZ_T2_POWER_FORCE=1$' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"

# late zone: helper waits (bounded) for intel-rapl:0 to appear
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
mv "$SYS/powercap/intel-rapl:0" "$SYS/powercap/intel-rapl:0.late"
( sleep 1; mv "$SYS/powercap/intel-rapl:0.late" "$SYS/powercap/intel-rapl:0" ) &
RH apply --wait 5; rc=$?; wait
if [ "$rc" = 0 ] && [ "$(get constraint_0_power_limit_uw)" = 25000000 ]; then
    ok "waits (bounded) for a late intel-rapl:0 and then caps"
else bad "late-zone wait failed (rc=$rc)"; fi

# missing zone + no wait -> clean no-op, exit 0 (never fails boot)
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
mv "$SYS/powercap/intel-rapl:0" "$SYS/powercap/absent"
RH apply --wait 0; rc=$?
if [ "$rc" = 0 ]; then ok "missing RAPL zone is a clean no-op (exit 0)"; else bad "missing zone returned rc=$rc"; fi
mv "$SYS/powercap/absent" "$SYS/powercap/intel-rapl:0"

# --strict surfaces a real failure (read-only limit file)
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
chmod 0444 "$SYS/powercap/intel-rapl:0/constraint_0_power_limit_uw"
RH apply --wait 0 --strict; rc=$?
if [ "$rc" != 0 ]; then ok "--strict returns nonzero when a limit cannot be written"; else bad "--strict hid a write failure"; fi
chmod 0644 "$SYS/powercap/intel-rapl:0/constraint_0_power_limit_uw"

# status is available and reports the state
mk_sysfs MacBookPro16,1 1; rm -rf "$T/run"; mkdir -p "$T/run"
RH status; rc=$?
if [ "$rc" = 0 ] && grep -q 'state=ac' "$T/helper.out" && grep -q 'PL1_uw=100000000' "$T/helper.out"; then
    ok "status reports state and current limits"
else bad "status output unexpected (rc=$rc)"; fi

# --- hook idempotency + config preservation ------------------------------
mkdir -p "$TROOT/sys/devices/system/cpu/intel_pstate"   # hook's RAPL plausibility probe
printf 'keep me\n' >> "$CONF"
HOOKRUN; rc=$?
if grep -q 'keep me' "$CONF"; then ok "second hook run preserves the operator config"; else bad "hook overwrote the config"; fi
[ "$rc" = 0 ] && ok "hook is idempotent (exit 0)" || bad "second hook run failed"

# --- registration ---------------------------------------------------------
grep -qx '64-t2-power-cap.sh' "$ROOT/post-install/hooks.list.amd64" \
    && ok "hook listed in hooks.list.amd64" || bad "hook not in hooks.list.amd64"
! grep -qx '64-t2-power-cap.sh' "$ROOT/post-install/hooks.list.sky1-arm64" \
    && ok "hook not on the arm64 list (T2 is amd64-only)" || bad "hook wrongly on the arm64 list"
grep -q '64-t2-power-cap' "$ROOT/post-install/run-all.sh" \
    && ok "hook is on run-all.sh MACHINE_HOOKS_RE (baked allowlist)" || bad "hook not on MACHINE_HOOKS_RE"

echo "t2-power-cap tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
