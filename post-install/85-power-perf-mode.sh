#!/bin/bash
# 85-power-perf-mode.sh — install ncz-performance-mode: forces the CPU out of
# deep idle states (LPI-1/LPI-2) and pins the GPU power domain always-on while
# a Singularity desktop session is active, then reverts on logout.
#
# Root cause: real, measured firmware/SCMI power-management round-trip latency
# on CIX Sky1 — 500-1200ms input-event delivery stalls tied to the CPU's deep
# ClusterPD idle state (LPI-2) and the GPU's genpd power-domain gating. Keeping
# both pinned "on" during interactive use eliminates the stalls. Confirmed live
# on O6N. Not a kludge: this trades idle power draw for correctness during
# active use, reverting to normal power management on logout.
#
# EXTENDED 2026-07-27: also pins GPU devfreq to the "performance" governor
# (max clock). Real, separate bug found running a real Vulkan compute
# workload (llama.cpp/Gemma-4 on the Mali stack): the GPU's `simple_ondemand`
# devfreq governor never ramped clock up under sustained load, staying
# pinned at its lowest OPP (72MHz of 1000MHz max — a 13.9x gap) even
# mid-inference. Same family of SCMI/power-management bug as the CPU/genpd
# issue above, different subsystem (clock scaling, not idle-state/power-
# domain gating). GPU-only pin hardware-validated stable on O6N (stayed up
# through repeated checks after the write).
#
# NPU (CIXH4000) MUST NEVER be touched here — this script does not read,
# write, or restore its governor/frequency at all, in either direction.
# Live-isolated on O6N 2026-07-27: writing governor=performance to
# CIXH4000:00 makes the armchina_npu driver's sky1_npu_devfreq_target() call
# dev_pm_opp_set_rate() -> clk_round_rate() on a clock handle that's
# NULL/not-ready in this platform config -> "Kernel panic - not syncing:
# Oops: Fatal exception" -> panic=6 reboots the whole board 6s later
# (confirmed via serial trace on MEDUSA, /var/log/o6n-serial.log). WORSE: this
# is not just a bad value to avoid — simple_ondemand (the "restore to
# default" governor tried for the off action) is ALSO fatal, and not even at
# write time: simple_ondemand is a *polling* governor, so once set it keeps
# hitting the same crash on every periodic devfreq_monitor workqueue cycle
# (confirmed via a second, separate crash whose trace shows
# "Workqueue: devfreq_wq devfreq_monitor" as the caller, not a direct sysfs
# write). NPU's actual factory-safe state is "userspace" (static, no
# periodic polling) — that's what it boots with and what it must be left at.
# Net effect: there is no known-safe non-default governor for CIXH4000 on
# this platform/kernel combo at all; do not add ANY write to it here, on OR
# off, until the armchina_npu driver's clk wiring is fixed upstream/DT-side.
# Same clk_round_rate NULL-deref bug class already tracked (unresolved) as
# "Crash #2" in assets/kernel/mali-70012/README.md on 7.0.12+mali_kbase's OWN
# devfreq path — different driver, same call site, same platform-level
# clk-wiring gap, present across kernel versions.
#
# This also means: never wire ncz-performance-mode into anything that runs
# unconditionally on every boot without being able to detect and break a
# resulting panic-reboot loop — the greetd ExecStartPre below does exactly
# that (fires "on" before the greeter can render), so a bad edit here is a
# live boot-loop risk for the whole box, not just a failed feature. Confirmed
# this the hard way 2026-07-27: an earlier version of this fix that still
# touched CIXH4000 was live-installed, and every subsequent greetd start
# panic-rebooted the board before the greeter could come up.
#
# CIXH3010 = VPU (drivers/media/.../mvx_dev.c ACPI id "CIXH3010", confirmed
# via ncz-os/linux-cix + cixtech/edk2-platforms Dsdt-Vpu.asl) — intentionally
# left unpinned here too: it's bursty (only active during video decode, not
# sustained compute), so an always-on max-clock pin during a desktop session
# would just burn power for no benefit. Cross-vendor evidence
# (ThomasKaiser/sbc-bench results on a different Sky1 board, Minisforum
# MS-R1) shows the identical simple_ondemand-stuck-at-lowest-OPP pattern on
# CIXH3010 too, confirming the underlying governor behavior is a
# platform-wide CIX Sky1 quirk, not build-specific — worth revisiting (GPU
# path only, same clk_round_rate risk applies) if VPU-under-load is ever
# observed stuck slow.
#
# Activated TWO ways (both needed, see the systemd drop-in below for why):
# the greetd PAM session hook (real user login/logout) and a greetd.service
# systemd drop-in (covers the greeter's own pre-auth session too — the PAM
# hook alone left the greeter/password-entry screen unprotected, confirmed
# via live sysfs + a real user report 2026-07-27).
set -euo pipefail

# ----------------------------------------------------------------------
# ncz-perf-activity — make the performance policy ACTIVITY-DRIVEN.
#
# ncz-performance-mode (below) pins every core at max with deep idle disabled
# and leaves it there from greeter start onward. Measured on O6N with the box
# doing nothing: all 12 cores at ceiling (2600/2500/2300/2200/1800 MHz),
# governor=performance, LPI-1 and LPI-2 both disabled, 44-50 C. Correct while
# somebody is using the machine; pure waste while nobody is, and a login screen
# sits unused most of its life.
#
# This daemon watches /dev/input and flips the CPU policy on activity. INPUT,
# not session state, because the greeter runs as _greetd and a session-scoped
# idle tool would not cover the logged-out case at all.
#
# METAL-VERIFIED on O6N 2026-08-10:
#   active           all policies at ceiling, LPI-1+LPI-2 disabled
#   after idle       ALL five policies drop to 800 MHz, governor schedutil,
#                    LPI-2 released, LPI-1 still disabled
#   thermals         TZB0 47->46, TZB1 46->44, TZM0 47/50->45, TZM1 46->44,
#                    TZGT 44->43 C
#   restore          back to performance @ 2600 MHz, both states disabled
# There is NO power sensor on this board (no power_supply, no hwmon power*_input,
# no energy*_uj), so temperature and clocks are the only available evidence --
# do not claim a wattage figure.
#
# THE LATENCY FLOOR IS DELIBERATE. This board had a notorious USB-keyboard lag
# at the greeter, fixed by disabling deep idle. Exit latencies measured here:
# LPI-1 = 360 us, LPI-2 = 500 us. Idle releases only LPI-2; LPI-1 stays
# disabled so the first keystroke after idle never pays the larger wake.
# NCZ_PERF_ALLOW_STATE1=1 releases it too, once that is metal-tested.
#
# DEVFREQ IS NEVER TOUCHED by this daemon -- see the panic notes above.
# Absolute staged-asset path, matching 12-sky1-firmware.sh and the other hooks.
# A $(dirname $0)-relative path resolves differently depending on where the hook
# is invoked from, and build-iso-di.sh stages this tree to a FIXED location:
# assets/perf -> /cixmini/assets/perf -> /usr/local/lib/cix-installer/assets/perf
# on the target (the generic `*) cp -aL` branch of its asset loop).
PERF_SRC=/usr/local/lib/cix-installer/assets/perf/ncz-perf-activity
if [ -s "$PERF_SRC" ]; then
    install -Dm755 "$PERF_SRC" /usr/local/bin/ncz-perf-activity
else
    echo "[85] WARN: $PERF_SRC not staged; activity-driven scaling DISABLED (cores stay pinned at max)"
fi

if [ -x /usr/local/bin/ncz-perf-activity ]; then
    install -Dm644 /dev/stdin /etc/systemd/system/ncz-perf-activity.service <<'UNIT'
[Unit]
Description=NCZ activity-driven CPU performance policy
After=multi-user.target

[Service]
Type=simple
# Idle threshold: long enough that a pause in typing does not throttle mid-use,
# short enough that an unattended login screen stops burning power.
Environment=NCZ_PERF_IDLE_SEC=120
ExecStart=/usr/local/bin/ncz-perf-activity
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable ncz-perf-activity.service 2>/dev/null || true
    echo "[85] ncz-perf-activity enabled (idle 120s -> schedutil + LPI-2; input -> performance)"
fi

install -Dm755 /dev/stdin /usr/local/bin/ncz-performance-mode <<'SCRIPT'
#!/bin/bash
# ncz-performance-mode {on|off} — forces CPU out of deep idle states + performance
# governor, and pins the GPU power domain always-on, while the Singularity
# desktop session is active. Reversible.
ACTION="$1"
write_if_writable() {
  [ -w "$1" ] || return 0
  printf '%s\n' "$2" > "$1"
}
if [ "$ACTION" = "on" ]; then
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state2/disable; do
    write_if_writable "$c" 1
  done
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do
    write_if_writable "$c" 1
  done
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    write_if_writable "$g" performance
  done
  write_if_writable /sys/devices/genpd:0:CIXH5000:00/power/control on
  write_if_writable /sys/devices/platform/CIXH5000:00/power/control on
  write_if_writable /sys/class/devfreq/CIXH5000:00/governor performance
  logger -t ncz-performance-mode "enabled: LPI-1/LPI-2 disabled, governor=performance, GPU power domain pinned on, GPU devfreq pinned to performance"
elif [ "$ACTION" = "off" ]; then
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state2/disable; do
    write_if_writable "$c" 0
  done
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do
    write_if_writable "$c" 0
  done
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    write_if_writable "$g" schedutil
  done
  # THE GPU IS DELIBERATELY NOT RESTORED HERE (2026-08-11). This block used to
  # write `simple_ondemand` to CIXH5000's devfreq and set both genpd
  # power/control back to `auto`. All three are hazards:
  #
  #   1. devfreq governor write -- the same clk_round_rate NULL-deref class
  #      documented above for CIXH4000 is also tracked in mali_kbase's OWN
  #      devfreq path (assets/kernel/mali-70012/README.md, "Crash #2"). This
  #      ran on every logout, so a latent panic path shipped in the `off`
  #      action of the very script written to avoid that panic elsewhere.
  #   2. even when it does not crash, simple_ondemand is measurably broken on
  #      this GPU: it stays pinned at 72 MHz of 1000 MHz (13.9x) even under a
  #      sustained Vulkan workload. That is a severe performance regression
  #      sold as a power saving.
  #   3. re-enabling genpd gating re-arms part of the ORIGINAL input-stall root
  #      cause -- see the 500-1200ms note at the top of this file. The pin is a
  #      latency fix, not merely an idle-power choice.
  #
  # CPU policy is dynamic now (ncz-perf-activity); the GPU stays pinned.
  logger -t ncz-performance-mode "disabled: CPU idle states + schedutil restored; GPU left pinned on purpose (devfreq/genpd hazards)"
else
  echo "usage: ncz-performance-mode {on|off}" >&2
  exit 1
fi
SCRIPT

# PAM session hook REMOVED 2026-07-27 (was added, then found actively
# harmful). Original idea: wire into greetd's PAM session stack so real
# login/logout toggles performance mode independent of systemd. Problem
# found live on O6N: greetd.service's OWN systemd ExecStartPre/ExecStopPost
# pair (below) is meant to hold performance mode "on" for the whole
# greetd runtime — greeter screen included, from service start to service
# stop. But PAM's close_session fires "off" on every user LOGOUT, even
# though greetd itself keeps running (same instance, back at the greeter)
# — so logging out silently undid the systemd-level pin and left the
# greeter laggy again on every return to it, which is the exact bug this
# whole script exists to fix. Confirmed via live sysfs read right after a
# real logout: cpuidle disable=0, governor=schedutil, genpd=auto — all
# back to "off" while greetd was still up. The two hooks have different
# lifecycles (per-user-session vs whole-service) and can't safely coexist
# with a shared on/off toggle. The systemd drop-in alone is correct and
# sufficient — it already covers the greeter (this was the reason it was
# added in the first place, see git history) and the real session for
# greetd's entire runtime, with no premature "off". Also clean up the PAM
# lines from any prior install (self-healing, idempotent).
PAM_GREETD=/etc/pam.d/greetd
if [ -f "$PAM_GREETD" ] && grep -q ncz-performance-mode "$PAM_GREETD"; then
  sed -i '/ncz-performance-mode/d' "$PAM_GREETD"
fi

# Keep the mode enabled for the entire graphical boot, not only while greetd
# happens to be running.  The previous greetd-only lifetime left a short race
# during greeter/session transitions where Sky1 could re-enter deep idle and
# USB keyboard input would stall again.
install -Dm644 /dev/stdin /etc/systemd/system/ncz-performance-mode.service <<'UNIT'
[Unit]
Description=NCZ: hold Sky1 interactive performance mode
After=systemd-udev-settle.service
Before=greetd.service
Wants=greetd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-performance-mode on
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
UNIT
systemctl enable ncz-performance-mode.service >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true

# Wire into greetd.service directly via a systemd drop-in. Real gap found
# 2026-07-27, confirmed live on O6N via sysfs (cpuidle disable=0,
# genpd=auto) + user report: the pre-authentication greeter/password-entry
# screen runs under a separate system account (_greetd) that a PAM session
# hook on the REAL user's login doesn't cover — the lag this whole fix
# targets was still reproducing at the greeter specifically, gone only
# once a real desktop session started. ExecStartPre/ExecStopPost below
# covers greetd's entire runtime — greeter included — for as long as the
# service itself is up, regardless of how many users log in/out of it.
install -d -m0755 /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/ncz-performance-mode.conf <<'DROPIN'
[Service]
ExecStartPre=/usr/local/bin/ncz-performance-mode on
DROPIN
