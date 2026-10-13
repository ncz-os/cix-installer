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
    # NCZ_TARGET_ARCH=amd64 pins the hook's platform guard so the amd64/T2 hook
    # actually runs on any host (same pattern as test-t2-dkms-hook.sh); the
    # guard otherwise self-skips on a non-amd64 build host (e.g. an arm64 CI box).
    env NCZ_TARGET_ARCH=amd64 NCZ_T2_POWER_CAP_ROOT="$TROOT" NCZ_T2_POWER_CAP_ASSUME_T2=1 \
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
RH() { # run installed helper with fake paths (RCONF overrides the config path)
    env NCZ_POWERCAP_CONF="${RCONF:-$CONF}" \
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
RCONF="$T/conf.performance"; cp "$CONF" "$RCONF"
printf '\nNCZ_T2_POWER_MODE=performance\n' >> "$RCONF"
RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 100000000 ] && [ "$(get constraint_1_power_limit_uw)" = 125000000 ]; then
    ok "performance mode leaves AC uncapped (firmware 100/125 W)"
else bad "performance AC wrong: $(get constraint_0_power_limit_uw)/$(get constraint_1_power_limit_uw)"; fi
ac_off; RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 25000000 ] && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 1 ]; then
    ok "performance mode keeps the battery cap (safety)"
else bad "performance battery not capped"; fi
unset RCONF

# NCZ_T2_POWER_CAP=0 -> no writes at all
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
RCONF="$T/conf.off"; cp "$CONF" "$RCONF"; printf '\nNCZ_T2_POWER_CAP=0\n' >> "$RCONF"
RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 100000000 ] && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 0 ]; then
    ok "NCZ_T2_POWER_CAP=0 disables every write"
else bad "cap=0 still wrote"; fi
unset RCONF

# product gate: a non-MacBookPro16 T2 Mac is untouched by default
mk_sysfs MacBookPro15,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
RH apply --wait 2; rc=$?
if [ "$rc" = 0 ] && [ "$(get constraint_0_power_limit_uw)" = 100000000 ] && [ "$(cat "$SYS/cpu/intel_pstate/no_turbo")" = 0 ]; then
    ok "non-enforce product is left untouched (exit 0)"
else bad "product gate failed (rc=$rc)"; fi
# ... but FORCE=1 enables it
RCONF="$T/conf.force"; cp "$CONF" "$RCONF"; printf '\nNCZ_T2_POWER_FORCE=1\n' >> "$RCONF"
RH apply --wait 2
if [ "$(get constraint_0_power_limit_uw)" = 25000000 ]; then ok "NCZ_T2_POWER_FORCE=1 enforces on other T2 Macs"; else bad "FORCE did not enforce"; fi
unset RCONF

# late zone: helper waits (bounded) for intel-rapl:0 to appear
mk_sysfs MacBookPro16,1 0; rm -rf "$T/run"; mkdir -p "$T/run"
mv "$SYS/powercap/intel-rapl:0" "$SYS/powercap/intel-rapl:0.late"
( sleep 1; mv "$SYS/powercap/intel-rapl:0.late" "$SYS/powercap/intel-rapl:0" ) &
lz_pid=$!
RH apply --wait 5; rc=$?
wait "$lz_pid"
[ -e "$SYS/powercap/intel-rapl:0.late" ] && mv "$SYS/powercap/intel-rapl:0.late" "$SYS/powercap/intel-rapl:0"
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

# --- lock-screen saver thermal cap ----------------------------------------
# The hook raises the saver feed's hot pause (compiled-in 85 C) on T2 Macs to
# 100 C, or 2 C under the lowest critical trip of the governor's sensors when
# that trip is at or below 100 C, and
# sets the warm-band fps to 6, in /etc/ncz/lock-renderer.env only.
HW="$T/hwmon"; DMIF="$T/dmi"
mk_hwmon() { # mk_hwmon "name:crit[,crit...]" ...   (crit "-" = no crit file)
    rm -rf "$HW"; mkdir -p "$HW"
    local i=0 spec n crits c j
    for spec in "$@"; do
        n=${spec%%:*}; crits=${spec#*:}
        mkdir -p "$HW/hwmon$i"; printf '%s\n' "$n" > "$HW/hwmon$i/name"
        j=1
        for c in $(printf '%s' "$crits" | tr ',' ' '); do
            printf '50000\n' > "$HW/hwmon$i/temp${j}_input"
            [ "$c" = - ] || printf '%s\n' "$c" > "$HW/hwmon$i/temp${j}_crit"
            j=$((j + 1))
        done
        i=$((i + 1))
    done
}
mk_dmi() { rm -rf "$DMIF"; mkdir -p "$DMIF"; printf '%s\n' "$1" > "$DMIF/product_name"; }
LENV="$TROOT/etc/ncz/lock-renderer.env"
renderer_env() { printf 'SINGULARITY_LOCK_RENDERER=/usr/libexec/ncz-screensaver-feed\n' > "$LENV"; }
SAVERRUN() {
    env NCZ_TARGET_ARCH=amd64 NCZ_T2_POWER_CAP_ROOT="$TROOT" NCZ_T2_POWER_CAP_ASSUME_T2=1 \
        NCZ_T2_SAVER_HWMON="$HW" NCZ_T2_SAVER_DMI="$DMIF" \
        bash "$HOOK" >"$T/saver.out" 2>&1
}
hot()  { sed -n 's/^NCZ_FEED_TEMP_HOT_MC=//p' "$LENV" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
warm() { sed -n 's/^NCZ_FEED_FPS_WARM=//p' "$LENV" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# MacBookPro16,1 as measured: coretemp crit 100 C, amdgpu edge/junction/mem
# 110/105/150 C, t2smc without crit files, nvme (not a governor sensor) lower.
mk_hwmon "coretemp:100000,100000,100000" "amdgpu:110000,105000,150000" "t2smc:-,-" "nvme:84850"
mk_dmi MacBookPro16,1
renderer_env
SAVERRUN; rc=$?
if [ "$rc" = 0 ] && [ "$(hot)" = 98000 ]; then ok "saver cap: MacBookPro16,1 sensors -> NCZ_FEED_TEMP_HOT_MC=98000 (coretemp crit = Tjmax 100 C, - 2 C)"
else bad "saver cap: expected 98000, got '$(hot)' (rc=$rc): $(tail -3 "$T/saver.out")"; fi
[ "$(warm)" = 6 ] && ok "saver cap: warm-band fps set to 6" || bad "saver cap: warm fps '$(warm)'"
grep -q '^SINGULARITY_LOCK_RENDERER=/usr/libexec/ncz-screensaver-feed$' "$LENV" \
    && ok "saver cap: renderer line preserved" || bad "saver cap: renderer line changed"
# shellcheck source=/dev/null
if (set -a; . "$LENV"; [ "$NCZ_FEED_TEMP_HOT_MC" = 98000 ] && [ "$NCZ_FEED_FPS_WARM" = 6 ]); then
    ok "saver cap: env file sources cleanly the way the session launcher reads it"
else bad "saver cap: env file does not source"; fi
SAVERRUN
if [ "$(hot)" = 98000 ] && [ "$(warm)" = 6 ]; then ok "saver cap: second run is idempotent (one line each)"
else bad "saver cap: duplicate lines after second run: hot='$(hot)' warm='$(warm)'"; fi

# an operator value is kept
renderer_env; printf 'NCZ_FEED_TEMP_HOT_MC=88000\n' >> "$LENV"
SAVERRUN
[ "$(hot)" = 88000 ] && ok "saver cap: existing NCZ_FEED_TEMP_HOT_MC kept" || bad "saver cap: operator value replaced: '$(hot)'"

# a lower critical trip lowers the cap (crit - 2 C)
renderer_env; mk_hwmon "coretemp:97000" "amdgpu:105000"
SAVERRUN
[ "$(hot)" = 95000 ] && ok "saver cap: crit 97 C -> 95 C" || bad "saver cap: crit 97 C gave '$(hot)'"

# 100 C when every critical trip is above 100 C
renderer_env; mk_hwmon "coretemp:105000" "amdgpu:110000"
SAVERRUN
[ "$(hot)" = 100000 ] && ok "saver cap: trips 105/110 C -> 100 C" || bad "saver cap: not clamped: '$(hot)'"

# a trip just above 100 C does not lower the cap
renderer_env; mk_hwmon "coretemp:101000" "amdgpu:105000"
SAVERRUN
[ "$(hot)" = 100000 ] && ok "saver cap: lowest trip 101 C -> 100 C" || bad "saver cap: trip 101 C gave '$(hot)'"

# a cap that would not raise the default is not written
renderer_env; mk_hwmon "coretemp:87000"
SAVERRUN
if [ -z "$(hot)" ] && [ -z "$(warm)" ]; then ok "saver cap: crit 87 C -> nothing written (crit - 2 C is not above 85 C)"
else bad "saver cap: wrote '$(hot)'/'$(warm)' for crit 87 C"; fi

# sensors absent (installer kernel): measured model value, other models untouched
renderer_env; mk_hwmon "nvme:84850"
SAVERRUN
[ "$(hot)" = 98000 ] && ok "saver cap: no sensors + MacBookPro16,1 -> 98 C" || bad "saver cap: no sensors MBP16,1 gave '$(hot)'"
renderer_env; mk_dmi MacBookAir9,1
SAVERRUN
[ -z "$(hot)" ] && ok "saver cap: no sensors + other T2 model -> default kept" || bad "saver cap: unmeasured model got '$(hot)'"

# no renderer configured: the env file is neither created nor changed
mk_dmi MacBookPro16,1; mk_hwmon "coretemp:100000"
rm -f "$LENV"
SAVERRUN
[ ! -e "$LENV" ] && ok "saver cap: no lock-renderer.env -> not created" || bad "saver cap: created $LENV"
printf '# no renderer\n' > "$LENV"
SAVERRUN
[ "$(cat "$LENV")" = "# no renderer" ] && ok "saver cap: env without a renderer -> unchanged" || bad "saver cap: changed an env without a renderer"
rm -f "$LENV"

# an unwritable env file is reported, not claimed as written
renderer_env; chmod 0444 "$LENV"
if [ "$(id -u)" != 0 ]; then
    SAVERRUN
    if grep -q 'WARN: could not write' "$T/saver.out" && ! grep -q 'NCZ_FEED_TEMP_HOT_MC=98000 in' "$T/saver.out"; then
        ok "saver cap: unwritable env file -> WARN, no success claim"
    else bad "saver cap: unwritable env file not reported: $(grep saver "$T/saver.out")"; fi
fi
chmod 0644 "$LENV"; rm -f "$LENV"

# the hook and the renderer agree on the variable names
grep -q 'NCZ_FEED_TEMP_HOT_MC' "$HOOK" && grep -q 'NCZ_FEED_FPS_WARM' "$HOOK" \
    && ok "saver cap: hook writes the feed's NCZ_FEED_TEMP_HOT_MC / NCZ_FEED_FPS_WARM" || bad "saver cap: variable names missing"

# --- registration ---------------------------------------------------------
grep -qx '64-t2-power-cap.sh' "$ROOT/post-install/hooks.list.amd64" \
    && ok "hook listed in hooks.list.amd64" || bad "hook not in hooks.list.amd64"
! grep -qx '64-t2-power-cap.sh' "$ROOT/post-install/hooks.list.sky1-arm64" \
    && ok "hook not on the arm64 list (T2 is amd64-only)" || bad "hook wrongly on the arm64 list"
grep -q '64-t2-power-cap' "$ROOT/post-install/run-all.sh" \
    && ok "hook is on run-all.sh MACHINE_HOOKS_RE (baked allowlist)" || bad "hook not on MACHINE_HOOKS_RE"

echo "t2-power-cap tests: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
