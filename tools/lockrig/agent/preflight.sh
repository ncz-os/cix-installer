#!/usr/bin/env bash
# tools/lockrig/agent/preflight.sh -- runs on the target host (as the login user,
# no root needed). Emits KEY=VALUE facts and a machine-readable verdict. Read by
# the lockrig driver. Deliberately read-only.
set -u
P() { printf '%s=%s\n' "$1" "$2"; }
sh_() { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }

P host "$(hostname -s)"
P arch "$(uname -m)"
P kernel "$(uname -r)"
P os "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
P desktop_ver "$(dpkg-query -W -f='${Version}' ncz-singularity-desktop 2>/dev/null || echo none)"
P saver_ver "$(dpkg-query -W -f='${Version}' ncz-screensavers 2>/dev/null || echo none)"

LB=/opt/singularity/bin/singularity-lockscreen
if [ -r "$LB" ]; then
  P lockbin_sha "$(sha256sum "$LB" | awk '{print $1}')"
  P lockbin_size "$(stat -c%s "$LB")"
  grep -aq 'SINGULARITY_LOCK_RENDERER' "$LB" && P lockbin_framesrc_hook yes || P lockbin_framesrc_hook no
else
  P lockbin_sha MISSING; P lockbin_size 0; P lockbin_framesrc_hook no
fi

if [ -r /etc/ncz/lock-renderer.env ]; then
  P renderer_env "$(tr '\n' ';' </etc/ncz/lock-renderer.env)"
else
  P renderer_env NONE
fi
if [ -r /usr/local/bin/ncz-singularity ]; then
  grep -q lock-renderer.env /usr/local/bin/ncz-singularity && P launcher_block present || P launcher_block MISSING
else
  P launcher_block absent
fi

FEED=/usr/libexec/ncz-screensaver-feed
if [ -x "$FEED" ]; then
  P feed present
  # policy marker (0.8.12+): --print-policy in a clean env
  POL="$(env -i "$FEED" --print-policy 2>/dev/null | head -1)"
  P feed_policy_marker "${POL:-none}"
else
  P feed absent; P feed_policy_marker none
fi

# schema keys (effective values; best-effort, user session may be absent)
GS="XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas"
if command -v runuser >/dev/null 2>&1 && id "$(logname 2>/dev/null || echo ncz)" >/dev/null 2>&1; then :; fi
P idle_delay "$(runuser -u "$(id -un)" -- env $GS gsettings get dev.sinty.lockscreen idle-delay 2>/dev/null | tr -dc '0-9' || echo '?')"
P hack_idle_delay "$(runuser -u "$(id -un)" -- env $GS gsettings get dev.ncz.screensaver hack-idle-delay 2>/dev/null | tr -dc '0-9' || echo '?')"
P lock_saver_override "$( [ -r /opt/singularity/share/glib-2.0/schemas/99-ncz-lock-saver-plan.gschema.override ] && echo present || echo absent )"

P drm_outputs "$( for s in /sys/class/drm/card*-*/status; do [ -f "$s" ] && echo "$(basename "$(dirname "$s")")=$(cat "$s")"; done | tr '\n' ' ' )"
P drm_connected "$( cat /sys/class/drm/card*-*/status 2>/dev/null | grep -c connected )"
P sessions "$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0"{print $1":"$3}' | tr '\n' ' ')"
P compositor "$(pgrep -a -f 'singularity-desktop$' 2>/dev/null | head -1 | awk '{print $1}')"
P wayland "$(ls /run/user/1000/wayland-* 2>/dev/null | head -1)"
P gpu "$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/.*: //' | tr '\n' ';')"
P disk_avail "$(df -Pk / | awk 'NR==2{print $4}')"
P disk_used_pct "$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
P tools_grim "$(sh_ grim)"
P tools_kbd "$(sh_ python3)"
P has_uinput "$( [ -w /dev/uinput ] && echo yes || echo no )"
P has_nvidia "$( [ -e /usr/bin/nvidia-smi ] && echo yes || echo no )"
P has_rapl "$( ls -d /sys/class/powercap/intel-rapl:* >/dev/null 2>&1 && echo yes || echo no )"
P has_podman "$(sh_ podman)"
P has_greetd_sock "$( ls /run/greetd*.sock >/dev/null 2>&1 && echo yes || echo no )"
