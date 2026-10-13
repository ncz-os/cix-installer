#!/bin/bash
# 64-t2-power-cap.sh — Apple T2 Intel Macs: cap the CPU package power so a heavy
# all-core load cannot trip the SMC/BMS hard power cut that powers the whole
# machine off with no journal entry.
#
# THE BUG. On the MacBookPro16,1 (unit A = i9-9980HK, unit B = i7-9750H) the
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
# (project T2 7.3 power-cut handoff notes, 2026-10-04;
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
#             read live on both MacBookPro16,1 test units 2026-10-11), so it is a value the
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

# --- lock-screen saver thermal cap ---------------------------------------
# The lock-hosted saver renderer (ncz-screensavers src/ncz_feed_render.c)
# pauses and holds the last frame when the hottest trusted hwmon sensor
# (coretemp/amdgpu/t2smc/k10temp/acpitz) reaches its hot threshold, compiled-in
# 85 C, and resumes 5 C below it. On MacBookPro16,1 the dGPU is always on and
# the CPU idles warm, so 85 C is reached in ordinary use and the saver stays
# still on the lock screen. Measured on both MacBookPro16,1 units (i9-9980HK,
# i7-9750H; 2026-10-13): coretemp temp*_max == temp*_crit == 100 C (Tjmax,
# TCC offset 0, so the CPU self-throttles at 100 C), amdgpu junction crit
# 105 C (emergency 110 C), edge crit 110 C (emergency 115 C), PCH thermal
# zone critical trip 120 C; the x86_pkg_temp zone has no enabled trip. Up to
# 100 C is normal operation on these Macs: the CPU throttles itself at Tjmax
# (package/core thermal_throttle counters advance in ordinary use). The cap is
# 100 C, or 2 C under the lowest critical trip of the governor's sensors when
# that trip is at or below 100 C. coretemp reports Tjmax itself as temp*_crit
# (100 C), so MacBookPro16,1 gets 98 C, resume at 93 C. The governor samples
# once a second and the package temperature moves 10-14 C in one second under
# turbo bursts, so the reading that trips the pause can reach Tjmax; the CPU's
# own throttling covers that.
# The warm band (75 C .. hot) renders at NCZ_FEED_FPS_WARM, compiled-in 10 fps,
# which is above the 8 fps lock policy; T2 Macs use 6 fps there so a warmer
# machine renders less, not more.
# Written into /etc/ncz/lock-renderer.env (sourced by the session launcher and
# inherited by the lock and the feed) only when that file already names a lock
# renderer (post-install/64-ncz-lock-saver-plan.sh); a value already present
# there is kept. Remove the lines to return to the compiled-in defaults.
# Test seams: NCZ_T2_SAVER_HWMON, NCZ_T2_SAVER_DMI.
SAVER_ENV="$ROOT/etc/ncz/lock-renderer.env"
SAVER_HWMON="${NCZ_T2_SAVER_HWMON:-/sys/class/hwmon}"
SAVER_DMI="${NCZ_T2_SAVER_DMI:-/sys/class/dmi/id}"
SAVER_HOT_MAX_MC=100000
SAVER_HOT_MARGIN_MC=2000
SAVER_HOT_DEFAULT_MC=85000
SAVER_WARM_FPS=6

# saver_min_crit_mc -> lowest tempN_crit (> 0) of the governor's sensors, or empty
saver_min_crit_mc() {
    local h n c best=""
    for h in "$SAVER_HWMON"/hwmon*; do
        [ -r "$h/name" ] || continue
        n=$(cat "$h/name" 2>/dev/null)
        case "$n" in *coretemp*|*amdgpu*|*t2smc*|*k10temp*|*acpitz*) ;; *) continue ;; esac
        for c in "$h"/temp*_crit; do
            [ -r "$c" ] || continue
            c=$(cat "$c" 2>/dev/null)
            case "$c" in ''|*[!0-9]*) continue ;; esac
            [ "$c" -gt 0 ] || continue
            if [ -z "$best" ] || [ "$c" -lt "$best" ]; then best=$c; fi
        done
    done
    printf '%s' "$best"
}

saver_hot_mc() {
    local crit cap product
    crit=$(saver_min_crit_mc)
    if [ -n "$crit" ]; then
        if [ "$crit" -le "$SAVER_HOT_MAX_MC" ]; then
            cap=$((crit - SAVER_HOT_MARGIN_MC))
        else
            cap=$SAVER_HOT_MAX_MC
        fi
        printf '%s' "$cap"
        return 0
    fi
    # Sensors not loaded (e.g. installer kernel): use the measured model value.
    product=$(cat "$SAVER_DMI/product_name" 2>/dev/null)
    case "$product" in MacBookPro16,*) printf '%s' $((100000 - SAVER_HOT_MARGIN_MC)) ;; esac
}

SAVER_HOT=$(saver_hot_mc)
if [ ! -f "$SAVER_ENV" ] || ! grep -qE '^[[:space:]]*SINGULARITY_LOCK_RENDERER[[:space:]]*=[[:space:]]*[^[:space:]]' "$SAVER_ENV"; then
    echo "[64] lock renderer not configured; saver thermal cap left at the compiled-in default"
elif [ -z "$SAVER_HOT" ] || [ "$SAVER_HOT" -le "$SAVER_HOT_DEFAULT_MC" ]; then
    echo "[64] saver thermal cap: no value above the compiled-in 85 C (critical trips or model unknown); default kept"
else
    if grep -qE '^[[:space:]]*NCZ_FEED_TEMP_HOT_MC=' "$SAVER_ENV"; then
        echo "[64] saver thermal cap: $SAVER_ENV already sets NCZ_FEED_TEMP_HOT_MC; kept"
    else
        if printf '# Apple T2: saver pauses at 100 C, or 2 C under a critical trip at or below 100 C; post-install/64-t2-power-cap.sh\nNCZ_FEED_TEMP_HOT_MC=%s\n' \
            "$SAVER_HOT" >> "$SAVER_ENV" 2>/dev/null; then
            echo "[64] saver thermal cap: NCZ_FEED_TEMP_HOT_MC=$SAVER_HOT in $SAVER_ENV"
        else
            echo "[64] WARN: could not write $SAVER_ENV; saver thermal cap not set" >&2
        fi
    fi
    if grep -qE '^[[:space:]]*NCZ_FEED_FPS_WARM=' "$SAVER_ENV"; then
        echo "[64] saver warm-band fps: $SAVER_ENV already sets NCZ_FEED_FPS_WARM; kept"
    else
        if printf 'NCZ_FEED_FPS_WARM=%s\n' "$SAVER_WARM_FPS" >> "$SAVER_ENV" 2>/dev/null; then
            echo "[64] saver warm-band fps: NCZ_FEED_FPS_WARM=$SAVER_WARM_FPS in $SAVER_ENV"
        else
            echo "[64] WARN: could not write $SAVER_ENV; saver warm-band fps not set" >&2
        fi
    fi
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
# The helper lives in post-install/lib/ (a standalone, reviewable script)
# and is copied into place; it is NOT regenerated here.
HELPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ncz-t2-power-cap"
if [ ! -r "$HELPER_SRC" ]; then
    echo "[64] WARN: $HELPER_SRC missing; cannot install ncz-t2-power-cap" >&2
    exit 0
fi
mkdir -p "$ROOT/usr/local/sbin"
cp -f "$HELPER_SRC" "$ROOT/usr/local/sbin/ncz-t2-power-cap"
chmod 0755 "$ROOT/usr/local/sbin/ncz-t2-power-cap"

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
