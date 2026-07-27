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
  logger -t ncz-performance-mode "enabled: LPI-1/LPI-2 disabled, governor=performance, GPU power domain pinned on"
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
  logger -t ncz-performance-mode "disabled: idle states + schedutil + GPU auto power-gating restored"
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
