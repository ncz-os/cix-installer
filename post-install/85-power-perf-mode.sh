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

install -Dm755 /dev/stdin /usr/local/bin/ncz-performance-mode <<'SCRIPT'
#!/bin/bash
# ncz-performance-mode {on|off} — forces CPU out of deep idle states + performance
# governor, and pins the GPU power domain always-on, while the Singularity
# desktop session is active. Reversible.
ACTION="$1"
if [ "$ACTION" = "on" ]; then
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state2/disable; do
    echo 1 > "$c" 2>/dev/null || true
  done
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do
    echo 1 > "$c" 2>/dev/null || true
  done
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$g" 2>/dev/null || true
  done
  echo on > /sys/devices/genpd:0:CIXH5000:00/power/control 2>/dev/null || true
  echo on > /sys/devices/platform/CIXH5000:00/power/control 2>/dev/null || true
  echo performance > /sys/class/devfreq/CIXH5000:00/governor 2>/dev/null || true
  logger -t ncz-performance-mode "enabled: LPI-1/LPI-2 disabled, governor=performance, GPU power domain pinned on, GPU devfreq pinned to performance"
elif [ "$ACTION" = "off" ]; then
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state2/disable; do
    echo 0 > "$c" 2>/dev/null || true
  done
  for c in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do
    echo 0 > "$c" 2>/dev/null || true
  done
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo schedutil > "$g" 2>/dev/null || true
  done
  echo auto > /sys/devices/genpd:0:CIXH5000:00/power/control 2>/dev/null || true
  echo auto > /sys/devices/platform/CIXH5000:00/power/control 2>/dev/null || true
  echo simple_ondemand > /sys/class/devfreq/CIXH5000:00/governor 2>/dev/null || true
  logger -t ncz-performance-mode "disabled: idle states + schedutil + GPU auto power-gating + GPU auto devfreq restored"
else
  echo "usage: ncz-performance-mode {on|off}" >&2
  exit 1
fi
SCRIPT

# Wire into greetd's PAM session stack (fires on real login/logout, independent
# of systemd graphical-session.target wiring). Idempotent — skip if already present.
PAM_GREETD=/etc/pam.d/greetd
if [ -f "$PAM_GREETD" ] && ! grep -q ncz-performance-mode "$PAM_GREETD"; then
  cat >> "$PAM_GREETD" <<'PAM'
session      optional        pam_exec.so type=open_session  /usr/local/bin/ncz-performance-mode on
session      optional        pam_exec.so type=close_session /usr/local/bin/ncz-performance-mode off
PAM
fi

# ALSO wire into greetd.service directly (systemd drop-in), not just PAM.
# Real gap found 2026-07-27, confirmed live on O6N via sysfs (cpuidle
# disable=0, genpd=auto) + user report: the PAM hook above only fires for
# the REAL user's login session — it does NOT cover greetd's own greeter
# session (the pre-authentication password-entry screen), which runs under
# a separate system account (_greetd) and apparently doesn't traverse this
# PAM stack the same way. Result: the lag this whole fix targets was still
# reproducing at the greeter/password-entry screen specifically, gone once
# the real desktop session (and the PAM hook) kicked in. The systemd
# ExecStartPre/ExecStopPost pair below covers greetd's entire runtime —
# greeter included — regardless of PAM session semantics. Idempotent
# (ncz-performance-mode on/off is safe to call repeatedly); harmless
# overlap with the PAM hook once a real session also opens.
install -d -m0755 /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/ncz-performance-mode.conf <<'DROPIN'
[Service]
ExecStartPre=/usr/local/bin/ncz-performance-mode on
ExecStopPost=/usr/local/bin/ncz-performance-mode off
DROPIN
