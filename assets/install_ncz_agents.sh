#!/bin/bash
# NCZ ZeroClaw agent — install / remove launcher (Reinhardt desktop)
#
# ZeroClaw ships ACTIVE BY DEFAULT as a rootful Podman Quadlet (see
# post-install/30-agents.sh). This launcher does NOT re-install it blindly:
# it shows current status and toggles install <-> remove.
#
# Design:
#   - Manages the OFFICIAL upstream quadlet (ghcr.io/zeroclaw-labs/zeroclaw),
#     NOT a custom apt package and NOT the perlowja/nclawzero-demo image.
#   - Image is fetched by an EXPLICIT `podman pull` from ghcr.io (no apt, no
#     AutoUpdate=registry — keeps unreviewed code away from fleet API keys).
#   - Quadlet template lives at /usr/share/ncz/quadlets/zeroclaw.container and
#     is activated by copying it to /etc/containers/systemd/.
set -uo pipefail

IMAGE="ghcr.io/zeroclaw-labs/zeroclaw:latest"
SERVICE="zeroclaw.service"
TEMPLATE="/usr/share/ncz/quadlets/zeroclaw.container"
ACTIVE="/etc/containers/systemd/zeroclaw.container"
PORT=42617

if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi

say(){ printf '%s\n' "$*"; }
hr(){ printf '==========================================================\n'; }

is_active(){ systemctl is-active --quiet "$SERVICE"; }
is_installed(){ [ -f "$ACTIVE" ]; }
img_present(){ $SUDO podman image exists "$IMAGE" 2>/dev/null; }
running_status(){ $SUDO podman ps --filter 'name=^zeroclaw$' --format '{{.Status}}' 2>/dev/null; }
host_ip(){ hostname -I 2>/dev/null | awk '{print ($1==""?"localhost":$1)}'; }

status(){
  hr; say "  ZeroClaw agent status"; hr
  is_installed && say "  quadlet  : installed  ($ACTIVE)" || say "  quadlet  : not installed"
  is_active    && say "  service  : $SERVICE  ACTIVE"      || say "  service  : $SERVICE  inactive"
  local rc; rc="$(running_status)"
  [ -n "$rc" ] && say "  container: zeroclaw — $rc" || say "  container: not running"
  img_present  && say "  image    : present  ($IMAGE)"     || say "  image    : absent"
  say "  gateway  : http://$(host_ip):$PORT   (when active)"
  hr
}

pull_image(){
  say "[*] Pulling official image from ghcr.io ..."
  $SUDO podman pull "$IMAGE"
}

activate_quadlet(){
  if [ ! -f "$ACTIVE" ]; then
    if [ ! -f "$TEMPLATE" ]; then say "ERROR: quadlet template missing: $TEMPLATE"; return 1; fi
    say "[*] Activating quadlet ($TEMPLATE -> $ACTIVE) ..."
    $SUDO cp -a "$TEMPLATE" "$ACTIVE"
  fi
}

do_install(){
  pull_image || { say "ERROR: pull failed (check network / ghcr.io reachability)."; return 1; }
  activate_quadlet || return 1
  $SUDO systemctl daemon-reload
  say "[*] Starting $SERVICE ..."
  $SUDO systemctl start "$SERVICE" || true
  sleep 2; status
  say "ZeroClaw gateway should now answer on port $PORT."
}

do_repull(){
  pull_image || { say "ERROR: pull failed."; return 1; }
  activate_quadlet || return 1
  $SUDO systemctl daemon-reload
  say "[*] Restarting $SERVICE with the freshly pulled image ..."
  $SUDO systemctl restart "$SERVICE" || $SUDO systemctl start "$SERVICE" || true
  sleep 2; status
}

do_remove(){
  say "[*] Stopping $SERVICE ..."
  $SUDO systemctl stop "$SERVICE" 2>/dev/null || true
  [ -f "$ACTIVE" ] && { say "[*] Removing active quadlet ..."; $SUDO rm -f "$ACTIVE"; }
  $SUDO systemctl daemon-reload
  say "[*] ZeroClaw removed. Image cache + 'zeroclaw-data' volume retained for"
  say "    a fast re-install; run this tool again to reinstall."
  status
}

hr
say "  NCZ ZeroClaw agent — install / remove"
say "  Official quadlet image: $IMAGE"
hr
status

if is_installed || is_active; then
  say
  say "ZeroClaw is already present (it ships active by default on Reinhardt)."
  read -r -p "Action — [r]emove, [u]pdate (re-pull+restart), [q]uit: " a
  case "${a:-q}" in
    r|R) do_remove ;;
    u|U) do_repull ;;
    *)   say "No changes made." ;;
  esac
else
  say
  read -r -p "ZeroClaw is not installed. [i]nstall now, [q]uit: " a
  case "${a:-q}" in
    i|I) do_install ;;
    *)   say "No changes made." ;;
  esac
fi
