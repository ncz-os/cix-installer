#!/bin/bash
# 64-t2-power-cap.sh — Apple T2 Intel Macs: cap the CPU package power so a heavy
# all-core load cannot trip the SMC/BMS hard power cut that powers the whole
# machine off with no journal entry.
#
# THE BUG. On the MacBookPro16,1 (CHIMERA = i9-9980HK, MEDUSA = i7-9750H) the
# firmware ships Intel RAPL package limits of PL1 = 100 W / PL2 = 125 W with
# turbo enabled and intel_pstate max_perf_pct = 100. Under a sustained all-core
# load the package alone spikes past what the battery (or, on AC, the 96 W
# charger plus the always-on Navi dGPU) can deliver, and the machine cuts
# instantly: all power off, nothing in the journal, prior boot ends mid-line.
# Measured and field-confirmed upstream on an i9-9980HK MacBookPro16,1
# (omacom/omarchy issue #13295, PR #14987): the cut happens on BATTERY and also
# on AC at the firmware 100/125 W limits; capping the package to a value the
# delivery path can sustain stops it. 12 days / ~200 boots with no cut after
# the cap was actually applied.
#
# WHY A CAP, NOT A DRIVER FIX. Our own T2 7.3 power-cut investigation
# (MNEMOS project_t2_73_powercut_handoff_2026_10_04, mem_1791153431205_d3fa8b;
# amd64-kernel-t2 docs/) ran an extensive boot-time experiment matrix
# (userspace off, DKMS blocked, BCE blocked, amdgpu blocked, C-states<=C1,
# ASPM off, TB blocked, nosmp) and did NOT reproduce the boot cut with any of
# them — that work is about a DIFFERENT, ~16-27 s post-boot cut on 7.3 and is
# not this. The load-triggered cut addressed here is a power-delivery/BMS
# protection trip, not a kernel regression: the package is simply allowed to
# draw more than the board can feed. Capping it is a mitigation that keeps the
# machine up (same conclusion the upstream reporter reached: "a band-aid, but
# it works"). The iGPU-primary/gmux hang (issue #9609) and the AER revert
# decision remain separate hypotheses and are unaffected by this hook.
#
# THE POLICY (battery PL1<=25 W / PL2<=35 W + no-turbo + capped max_perf; AC a
# conservative cap). Numbers and why:
#   BATTERY   PL1=25 W, PL2=35 W, no_turbo=1, max_perf_pct=50. This is exactly
#             the field-proven upstream battery policy (12 days, no cuts). On
#             battery the whole machine runs off the pack; the trip point is
#             the pack's internal-resistance/current limit, so the cap must be
#             well below the idle drain of the rest of the system (~15-18 W
#             dGPU + platform). 25/35 W leaves real headroom.
#   AC        PL1=45 W, PL2=60 W, turbo and max_perf untouched. A cut was
#             observed ON AC at the firmware 100/125 W limits (96 W charger),
#             so AC is capped too - but conservatively, so a build host keeps
#             usable throughput. 45 W is the firmware's own read-only PL1
#             ceiling on these machines (constraint_0_max_power_uw = 45 W,
#             read live on CHIMERA and MEDUSA 2026-10-11), so it is a value the
#             firmware itself considers valid.
#   The AC numbers, the battery numbers and the exact behaviour are all
#   overridable in /etc/ncz/power-cap.conf (see below), including a clean
#   "performance" opt-out.
#
# DBUG PITFALLS THIS HOOK AVOIDS (all measured upstream on real T2 metal):
#   * intel_rapl_common registers intel-rapl:0 LATE (~21.8 s) while udev
#     coldplug fires the Mains event EARLIER (~19.7 s): a helper that just runs
#     at the Mains event finds no RAPL zone and silently does nothing, so the
#     machine boots uncapped. Fixed by a udev rule on the powercap
#     intel-rapl:0 "add" event itself, plus a bounded wait in the helper.
#   * thermald --adaptive remembers the PL1 it read at startup and rewrites it
#     after every 95 C excursion and on stop. A drop-in ExecStartPre applies
#     the cap BEFORE thermald starts, so thermald's "remembered" value is
#     already the cap.
#   * the writable limit is constraint_N_power_limit_uw; constraint_N_max_power_uw
#     is the READ-ONLY ceiling. Writing the wrong one silently no-ops (it is
#     the -r--r--r-- file). The helper only ever writes power_limit_uw.
#   * resume does not emit a Mains change event: a systemd-sleep hook re-applies
#     the cap on resume.
#
# SCOPE. The bug is documented on MacBookPro16,x (i9-9980HK / i7-9750H, Coffee
# Lake-H 45 W parts with an always-on dGPU). The hook is installed on any Apple
# T2 machine that has a RAPL package zone, but the helper ENFORCES by default
# only when product_name is MacBookPro16*; other T2 Macs are left untouched
# unless the operator sets NCZ_T2_POWER_FORCE=1 in /etc/ncz/power-cap.conf
# (their lower-TDP CPUs have not been shown to trip the same protection). A
# non-T2 machine, or a T2 machine without RAPL, is a no-op.
#
# REVERSIBILITY. The helper supports `restore` (writes back the values it
# captured before its first write this boot, kept in
# /run/ncz-t2-power-cap.baseline) and the whole feature is disabled with
# NCZ_T2_POWER_CAP=0 in the config file. The hook itself removes nothing and is
# idempotent.
#
# TEST SEAM (build/test-t2-power-cap.sh): NCZ_T2_POWER_CAP_ROOT prefixes every
# install path; NCZ_T2_POWER_CAP_ASSUME_T2=1 bypasses the T2 probe so the hook
# can be exercised on a non-T2 test box; the installed helper honours
# NCZ_POWERCAP_{CONF,SYS_CPU,SYS_RAPL,SYS_PSU,DMI,RUN,NO_JOURNAL} against a
# fake sysfs tree.
#
# # NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order
# matches run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then
# dpkg. An undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not amd64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set -u

ROOT="${NCZ_T2_POWER_CAP_ROOT:-}"
echo "[64] Apple T2 CPU package power cap"

# --- T2 gate (DMI/bridge) ------------------------------------------------
if [ "${NCZ_T2_POWER_CAP_ASSUME_T2:-0}" != 1 ]; then
    HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
    if [ -r "$HOOK_LIB_DIR/hw-detect.sh" ]; then
        # shellcheck source=post-install/lib/hw-detect.sh
        . "$HOOK_LIB_DIR/hw-detect.sh"
    fi
    if ! command -v is_t2_hardware >/dev/null 2>&1 || ! is_t2_hardware; then
        echo "[64] not Apple T2 hardware — skipping (cap is a T2 Mac mitigation)"
        exit 0
    fi
    echo "[64] T2 hardware: detected ($(t2_hardware_detail 2>/dev/null || echo unknown))"
fi

# T2 Macs are Intel (bridgeOS); require a RAPL package zone to be plausible.
# Absent at install time is NOT fatal (the zone can register late); the helper
# waits for it at runtime. We only refuse when there is a CPU cpufreq tree but
# no intel_pstate at all, which means a non-Intel or non-RAPL machine.
if [ -e /sys/devices/system/cpu/intel_pstate ] || [ -e "$ROOT/sys/devices/system/cpu/intel_pstate" ]; then
    :
else
    echo "[64] no intel_pstate — no Intel RAPL package cap to apply; skipping"
    exit 0
fi

install -d -m0755 "$ROOT/usr/local/sbin" "$ROOT/etc/ncz" \
                   "$ROOT/etc/udev/rules.d" \
                   "$ROOT/usr/lib/systemd/system-sleep" \
                   "$ROOT/etc/systemd/system/thermald.service.d"

# _wr MODE DEST — write stdin to DEST with MODE (portable: `install /dev/stdin`
# is a GNU-coreutils behaviour and is awkward under a test prefix on a host
# whose /dev/stdin is not a regular file).
_wr() {
    local mode="$1" dest="$2"
    mkdir -p "$(dirname "$dest")" || return 1
    cat > "$dest" || return 1
    chmod "$mode" "$dest"
}

# --- the helper ----------------------------------------------------------
_wr 0755 "$ROOT/usr/local/sbin/ncz-t2-power-cap" <<'HELPER'
#!/bin/bash
# ncz-t2-power-cap — apply/restore the NCZ-OS CPU package power cap on Apple T2
# Intel Macs. See post-install/64-t2-power-cap.sh for the full rationale.
#
#   ncz-t2-power-cap apply   [--wait N] [--strict] [--quiet]
#   ncz-t2-power-cap restore [--wait N] [--strict] [--quiet]
#   ncz-t2-power-cap status
#
# Safe to call from udev (Mains change, intel-rapl:0 add), a systemd-sleep
# hook and thermald's ExecStartPre: bounded wait only, exit 0 unless --strict,
# logs to the journal.
set -u

CONF="${NCZ_POWERCAP_CONF:-/etc/ncz/power-cap.conf}"
SYS_CPU="${NCZ_POWERCAP_SYS_CPU:-/sys/devices/system/cpu}"
SYS_RAPL="${NCZ_POWERCAP_SYS_RAPL:-/sys/class/powercap}"
SYS_PSU="${NCZ_POWERCAP_SYS_PSU:-/sys/class/power_supply}"
SYS_DMI="${NCZ_POWERCAP_DMI:-/sys/class/dmi/id}"
RUN="${NCZ_POWERCAP_RUN:-/run}"
BASELINE="$RUN/ncz-t2-power-cap.baseline"

# ---- defaults (any of these may be overridden by $CONF) ----
NCZ_T2_POWER_CAP=1
NCZ_T2_POWER_MODE=default             # default | performance | disabled
NCZ_T2_POWER_ENFORCE_PRODUCT=MacBookPro16
NCZ_T2_POWER_FORCE=0
NCZ_T2_POWER_BATTERY_PL1_W=25
NCZ_T2_POWER_BATTERY_PL2_W=35
NCZ_T2_POWER_BATTERY_NOTURBO=1
NCZ_T2_POWER_BATTERY_MAXPERF=50
NCZ_T2_POWER_AC_PL1_W=45
NCZ_T2_POWER_AC_PL2_W=60
NCZ_T2_POWER_AC_NOTURBO=0
NCZ_T2_POWER_AC_MAXPERF=100
NCZ_T2_POWER_FW_PL1_W=100
NCZ_T2_POWER_FW_PL2_W=125
NCZ_T2_POWER_FW_NOTURBO=0
NCZ_T2_POWER_FW_MAXPERF=100
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

log() { [ "${NCZ_POWERCAP_NO_JOURNAL:-0}" = 1 ] || logger -t ncz-t2-power-cap "$*" 2>/dev/null || true; }
say() { [ "${QUIET:-0}" = 1 ] || echo "ncz-t2-power-cap: $*"; }
FAIL=0
fail() { FAIL=$((FAIL + 1)); log "ERROR: $*"; echo "ncz-t2-power-cap: ERROR: $*" >&2; }

RAIL0_DIR="$SYS_RAPL/intel-rapl:0"
F_PL1="$RAIL0_DIR/constraint_0_power_limit_uw"
F_PL2="$RAIL0_DIR/constraint_1_power_limit_uw"
F_NOTURBO="$SYS_CPU/intel_pstate/no_turbo"
F_MAXPERF="$SYS_CPU/intel_pstate/max_perf_pct"

is_uint() { case "${1:-}" in (''|*[!0-9]*) return 1 ;; (*) return 0 ;; esac; }

wait_zone() {   # bounded wait for the package RAPL zone (seconds)
    local n="${1:-0}" i=0
    [ -e "$F_PL1" ] && return 0
    while [ "$i" -lt "$n" ]; do
        sleep 1
        i=$((i + 1))
        [ -e "$F_PL1" ] && return 0
    done
    return 1
}

product_ok() {
    [ "$NCZ_T2_POWER_FORCE" = 1 ] && return 0
    local p
    p="$(cat "$SYS_DMI/product_name" 2>/dev/null || true)"
    case "$p" in
        ${NCZ_T2_POWER_ENFORCE_PRODUCT}*) return 0 ;;
    esac
    return 1
}

on_ac() {   # 0 = Mains online; 1 = on battery (or unknown -> conservative)
    local s t o
    for s in "$SYS_PSU"/*; do
        [ -r "$s/type" ] || continue
        t="$(cat "$s/type" 2>/dev/null)"
        [ "$t" = "Mains" ] || continue
        o="$(cat "$s/online" 2>/dev/null || true)"
        [ "$o" = 1 ] && return 0
    done
    return 1
}

write_val() {   # file value
    local f="$1" v="$2" got
    if [ ! -e "$f" ]; then fail "missing $f"; return 1; fi
    if [ ! -w "$f" ]; then fail "not writable: $f"; return 1; fi
    if ! printf '%s\n' "$v" > "$f" 2>/dev/null; then fail "write failed: $f=$v"; return 1; fi
    got="$(cat "$f" 2>/dev/null || true)"
    if [ "$got" != "$v" ]; then fail "read-back mismatch on $f: wrote '$v' got '$got'"; return 1; fi
    return 0
}

capture_baseline() {
    [ -e "$BASELINE" ] && return 0
    {
        printf '# ncz-t2-power-cap baseline, captured %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
        printf 'B_PL1=%s\n'     "$(cat "$F_PL1" 2>/dev/null || true)"
        printf 'B_PL2=%s\n'     "$(cat "$F_PL2" 2>/dev/null || true)"
        printf 'B_NOTURBO=%s\n' "$(cat "$F_NOTURBO" 2>/dev/null || true)"
        printf 'B_MAXPERF=%s\n' "$(cat "$F_MAXPERF" 2>/dev/null || true)"
    } > "$BASELINE" 2>/dev/null || true
}

# select_policy -> "PL1_uw PL2_uw no_turbo max_perf_pct" or "none"
select_policy() {
    if [ "$NCZ_T2_POWER_CAP" != 1 ] || [ "$NCZ_T2_POWER_MODE" = disabled ]; then
        echo "none"; return 0
    fi
    if on_ac; then
        if [ "$NCZ_T2_POWER_MODE" = performance ]; then
            echo "$((NCZ_T2_POWER_FW_PL1_W * 1000000)) $((NCZ_T2_POWER_FW_PL2_W * 1000000)) $NCZ_T2_POWER_FW_NOTURBO $NCZ_T2_POWER_FW_MAXPERF"
        else
            echo "$((NCZ_T2_POWER_AC_PL1_W * 1000000)) $((NCZ_T2_POWER_AC_PL2_W * 1000000)) $NCZ_T2_POWER_AC_NOTURBO $NCZ_T2_POWER_AC_MAXPERF"
        fi
    else
        echo "$((NCZ_T2_POWER_BATTERY_PL1_W * 1000000)) $((NCZ_T2_POWER_BATTERY_PL2_W * 1000000)) $NCZ_T2_POWER_BATTERY_NOTURBO $NCZ_T2_POWER_BATTERY_MAXPERF"
    fi
}

cmd_apply() {
    local prod
    prod="$(cat "$SYS_DMI/product_name" 2>/dev/null || true)"
    if ! product_ok; then
        say "product '${prod:-unknown}' is not in the enforce set (${NCZ_T2_POWER_ENFORCE_PRODUCT}*); cap not applied (set NCZ_T2_POWER_FORCE=1 to enable)"
        log "skipped: product '${prod:-unknown}' outside enforce set"
        return 0
    fi
    if ! wait_zone "$WAIT"; then
        say "intel-rapl:0 did not appear within ${WAIT}s; nothing to cap yet"
        log "skipped: intel-rapl:0 absent after ${WAIT}s"
        return 0
    fi
    local pol
    pol="$(select_policy)"
    if [ "$pol" = "none" ]; then
        say "cap disabled by config (NCZ_T2_POWER_CAP or mode)"
        return 0
    fi
    # shellcheck disable=SC2086
    set -- $pol
    local pl1="$1" pl2="$2" nt="$3" mp="$4" state
    if on_ac; then state=ac; else state=battery; fi
    capture_baseline
    write_val "$F_PL1" "$pl1"
    write_val "$F_PL2" "$pl2"
    [ -e "$F_NOTURBO" ] && write_val "$F_NOTURBO" "$nt"
    [ -e "$F_MAXPERF" ] && write_val "$F_MAXPERF" "$mp"
    if [ "$FAIL" -eq 0 ]; then
        say "applied ($state): PL1=$((pl1 / 1000000))W PL2=$((pl2 / 1000000))W no_turbo=$nt max_perf_pct=$mp"
        log "applied ($state): PL1=${pl1}uW PL2=${pl2}uW no_turbo=$nt max_perf_pct=$mp"
    fi
    return 0
}

cmd_restore() {
    local pl1 pl2 nt mp
    if [ -r "$BASELINE" ]; then
        # shellcheck disable=SC1090
        . "$BASELINE"
        pl1="${B_PL1:-}"; pl2="${B_PL2:-}"; nt="${B_NOTURBO:-}"; mp="${B_MAXPERF:-}"
    fi
    [ -n "${pl1:-}" ] && is_uint "$pl1" || pl1=$((NCZ_T2_POWER_FW_PL1_W * 1000000))
    [ -n "${pl2:-}" ] && is_uint "$pl2" || pl2=$((NCZ_T2_POWER_FW_PL2_W * 1000000))
    [ -n "${nt:-}" ] || nt=$NCZ_T2_POWER_FW_NOTURBO
    [ -n "${mp:-}" ] || mp=$NCZ_T2_POWER_FW_MAXPERF
    if ! wait_zone "$WAIT"; then
        say "intel-rapl:0 absent; cannot restore"
        return 0
    fi
    write_val "$F_PL1" "$pl1"
    write_val "$F_PL2" "$pl2"
    [ -e "$F_NOTURBO" ] && write_val "$F_NOTURBO" "$nt"
    [ -e "$F_MAXPERF" ] && write_val "$F_MAXPERF" "$mp"
    [ "$FAIL" -eq 0 ] && say "restored: PL1=$((pl1 / 1000000))W PL2=$((pl2 / 1000000))W no_turbo=$nt max_perf_pct=$mp" \
                       && log "restored: PL1=${pl1}uW PL2=${pl2}uW no_turbo=$nt max_perf_pct=$mp"
    return 0
}

cmd_status() {
    local state prod
    if on_ac; then state=ac; else state=battery; fi
    prod="$(cat "$SYS_DMI/product_name" 2>/dev/null || true)"
    echo "product=${prod:-unknown}"
    echo "state=$state"
    echo "enforce_set=${NCZ_T2_POWER_ENFORCE_PRODUCT}*"
    product_ok && echo "product_match=yes" || echo "product_match=no"
    echo "mode=$NCZ_T2_POWER_MODE cap=${NCZ_T2_POWER_CAP}"
    echo "PL1_uw=$(cat "$F_PL1" 2>/dev/null || echo -)"
    echo "PL2_uw=$(cat "$F_PL2" 2>/dev/null || echo -)"
    echo "no_turbo=$(cat "$F_NOTURBO" 2>/dev/null || echo -)"
    echo "max_perf_pct=$(cat "$F_MAXPERF" 2>/dev/null || echo -)"
    echo "policy=$(select_policy)"
    [ -r "$BASELINE" ] && { echo "baseline=$BASELINE"; cat "$BASELINE"; } || echo "baseline=absent"
}

WAIT=0
STRICT=0
QUIET=0
cmd="${1:-status}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --wait)   WAIT="${2:-0}"; shift 2 ;;
        --strict) STRICT=1; shift ;;
        --quiet)  QUIET=1; shift ;;
        *) echo "ncz-t2-power-cap: unknown option '$1'" >&2; shift ;;
    esac
done
is_uint "$WAIT" || WAIT=0

case "$cmd" in
    apply)   cmd_apply ;;
    restore) cmd_restore ;;
    status)  cmd_status; exit 0 ;;
    *) echo "usage: ncz-t2-power-cap {apply|restore|status} [--wait N] [--strict] [--quiet]" >&2; exit 2 ;;
esac

if [ "$FAIL" -gt 0 ]; then
    [ "$STRICT" = 1 ] && exit 1
fi
exit 0
HELPER

# --- default policy file (never overwrite an operator's edits) -----------
CONF="$ROOT/etc/ncz/power-cap.conf"
if [ ! -f "$CONF" ]; then
    _wr 0644 "$CONF" <<'CONFEOF'
# /etc/ncz/power-cap.conf — NCZ-OS Apple T2 CPU package power cap policy.
#
# Why this exists (omacom/omarchy issue #13295): on MacBookPro16,1 the firmware
# RAPL package limits are PL1=100 W / PL2=125 W. Under heavy all-core load that
# trips the battery/charger protection and the machine cuts power instantly
# (battery AND, at those limits, AC). The cap below keeps the package within
# what the board can actually deliver.
#
# Applied by /usr/local/sbin/ncz-t2-power-cap (hooks: the intel-rapl:0 udev add
# event at boot, the Mains change event on plug/unplug, a systemd-sleep hook on
# resume, and thermald's ExecStartPre). Edit this file and re-run
# `sudo ncz-t2-power-cap apply` to change it live; no reboot needed.
#
#   NCZ_T2_POWER_CAP=0           disable the cap entirely (no writes anywhere)
#   NCZ_T2_POWER_MODE=default    battery AND AC capped (recommended)
#   NCZ_T2_POWER_MODE=performance  AC left UNCAPPED (firmware 100/125 W); the
#                                battery cap is still kept for safety. Choose
#                                this only on a machine you are willing to
#                                risk a hard power cut on under sustained load
#                                (e.g. a sit-on-AC build host).
#   NCZ_T2_POWER_MODE=disabled   same as NCZ_T2_POWER_CAP=0
#
# The cap is enforced only when product_name starts with NCZ_T2_POWER_ENFORCE_PRODUCT
# (default MacBookPro16, the documented-affected machine). Set
# NCZ_T2_POWER_FORCE=1 to also enforce on other Apple T2 Macs.

NCZ_T2_POWER_CAP=1
NCZ_T2_POWER_MODE=default
NCZ_T2_POWER_ENFORCE_PRODUCT=MacBookPro16
NCZ_T2_POWER_FORCE=0

# Battery: field-proven conservative cap (PL1=25 W / PL2=35 W, no turbo, half
# the turbo range). Values in W / integer percent.
NCZ_T2_POWER_BATTERY_PL1_W=25
NCZ_T2_POWER_BATTERY_PL2_W=35
NCZ_T2_POWER_BATTERY_NOTURBO=1
NCZ_T2_POWER_BATTERY_MAXPERF=50

# AC: conservative cap; 45 W is the firmware's own read-only PL1 ceiling on
# MacBookPro16,x. Turbo / max_perf are left at the firmware values so a build
# host keeps throughput.
NCZ_T2_POWER_AC_PL1_W=45
NCZ_T2_POWER_AC_PL2_W=60
NCZ_T2_POWER_AC_NOTURBO=0
NCZ_T2_POWER_AC_MAXPERF=100

# Firmware (uncapped) values — used by `restore` when no per-boot baseline was
# captured, and by the `performance` mode's AC branch.
NCZ_T2_POWER_FW_PL1_W=100
NCZ_T2_POWER_FW_PL2_W=125
NCZ_T2_POWER_FW_NOTURBO=0
NCZ_T2_POWER_FW_MAXPERF=100
CONFEOF
    echo "[64] wrote default policy $CONF"
else
    echo "[64] $CONF exists; left untouched"
fi

# --- udev: boot (rapl zone registers) + plug/unplug ---------------------
_wr 0644 "$ROOT/etc/udev/rules.d/72-ncz-t2-power-cap.rules" <<'UDEVEOF'
# Apple T2 CPU package power cap (post-install/64-t2-power-cap.sh).
#
# intel_rapl_common registers intel-rapl:0 LATE (~21.8 s), AFTER udev coldplug
# fires the Mains "change" event (~19.7 s). A helper that only runs at the
# Mains event finds no zone and silently does nothing, so the machine boots
# uncapped. This rule fires when the package zone itself appears.
ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:0", RUN+="/usr/local/sbin/ncz-t2-power-cap apply --wait 5"

# Re-apply on AC plug/unplug (battery <-> AC policy switch).
ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/local/sbin/ncz-t2-power-cap apply --wait 2"
UDEVEOF

# --- resume: systemd-sleep hook -----------------------------------------
_wr 0755 "$ROOT/usr/lib/systemd/system-sleep/ncz-t2-power-cap" <<'SLEEPEOF'
#!/bin/bash
# Apple T2 CPU package power cap: re-apply after resume. A resume does not
# emit a Mains change event, so the udev rule alone does not cover it.
# ($1 = pre|post, $2 = suspend|hibernate|...)
case "${1:-}" in
    post) /usr/local/sbin/ncz-t2-power-cap apply --wait 5 >/dev/null 2>&1 || true ;;
esac
exit 0
SLEEPEOF

# --- thermald: apply BEFORE thermald reads its baseline -----------------
# thermald --adaptive reads PL1 at startup and rewrites it after every 95 C
# excursion and when it stops. Starting thermald on top of the cap makes the
# value it remembers the cap, not the firmware 100 W.
_wr 0644 "$ROOT/etc/systemd/system/thermald.service.d/10-ncz-t2-power-cap.conf" <<'THERMALDEOF'
[Service]
# Apply the package power cap before thermald reads its startup PL1.
ExecStartPre=/usr/local/sbin/ncz-t2-power-cap apply --wait 5
THERMALDEOF

# --- apply now (real installs only) -------------------------------------
if [ -z "$ROOT" ]; then
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules >/dev/null 2>&1 || true
        udevadm trigger --subsystem-match=powercap >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    /usr/local/sbin/ncz-t2-power-cap apply --wait 5 >/dev/null 2>&1 || true
    echo "[64] installed ncz-t2-power-cap (udev boot/plug, sleep-resume, thermald drop-in)"
else
    echo "[64] staged into $ROOT (test mode)"
fi
echo "[64] done"
exit 0
