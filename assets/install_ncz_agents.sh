#!/bin/bash
# NCZ agents — install / manage launcher (Reinhardt desktop)
#
# This is the "Install AI Agents" desktop icon. The NCZ distro ships
# AGENT-ENABLED but with the agents OPT-IN: nothing AI is turned on until
# the user runs this launcher (or the `ncz` CLI). It offers three optional
# components, each installed on demand:
#
#   1. ZeroClaw   — autonomous coding agent gateway (official upstream
#                   quadlet ghcr.io/zeroclaw-labs/zeroclaw). Ships active by
#                   default on Reinhardt; this tool toggles install<->remove.
#   2. MNEMOS     — persistent memory substrate (REST + MCP + OpenAI-compatible
#                   gateway on :5002, sqlite-backed). Pulled on demand via
#                   `ncz install mnemos`.
#   3. NemoClaw   — NVIDIA NemoClaw OpenShell sandbox runtime, via
#                   `ncz install nemoclaw`.
#
# MNEMOS + NemoClaw are thin wrappers over the `ncz` CLI so there is ONE
# canonical install path; this GUI just makes them discoverable from the
# desktop. None of this is installed automatically — the distro is "enabled",
# not "turned on".
set -uo pipefail

# ---- ZeroClaw (official upstream quadlet) -------------------------------
ZC_IMAGE="ghcr.io/zeroclaw-labs/zeroclaw:latest"
ZC_SERVICE="zeroclaw.service"
ZC_TEMPLATE="/usr/share/ncz/quadlets/zeroclaw.container"
ZC_ACTIVE="/etc/containers/systemd/zeroclaw.container"
ZC_PORT=42617

if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi

say(){ printf '%s\n' "$*"; }
hr(){ printf '==========================================================\n'; }
pause(){ say; read -r -p "Press Enter to return to the menu... " _; }
host_ip(){ hostname -I 2>/dev/null | awk '{print ($1==""?"localhost":$1)}'; }

have_ncz(){ command -v ncz >/dev/null 2>&1; }

# ---- ZeroClaw helpers ---------------------------------------------------
zc_is_active(){ systemctl is-active --quiet "$ZC_SERVICE"; }
zc_is_installed(){ [ -f "$ZC_ACTIVE" ]; }
zc_img_present(){ $SUDO podman image exists "$ZC_IMAGE" 2>/dev/null; }
zc_running(){ $SUDO podman ps --filter 'name=^zeroclaw$' --format '{{.Status}}' 2>/dev/null; }

zc_status(){
  hr; say "  ZeroClaw agent status"; hr
  zc_is_installed && say "  quadlet  : installed  ($ZC_ACTIVE)" || say "  quadlet  : not installed"
  zc_is_active    && say "  service  : $ZC_SERVICE  ACTIVE"      || say "  service  : $ZC_SERVICE  inactive"
  local rc; rc="$(zc_running)"
  [ -n "$rc" ] && say "  container: zeroclaw — $rc" || say "  container: not running"
  zc_img_present  && say "  image    : present  ($ZC_IMAGE)"     || say "  image    : absent"
  say "  gateway  : http://$(host_ip):$ZC_PORT   (when active)"
  hr
}

zc_pull(){ say "[*] Pulling official image from ghcr.io ..."; $SUDO podman pull "$ZC_IMAGE"; }

zc_activate(){
  if [ ! -f "$ZC_ACTIVE" ]; then
    [ -f "$ZC_TEMPLATE" ] || { say "ERROR: quadlet template missing: $ZC_TEMPLATE"; return 1; }
    say "[*] Activating quadlet ($ZC_TEMPLATE -> $ZC_ACTIVE) ..."
    $SUDO cp -a "$ZC_TEMPLATE" "$ZC_ACTIVE"
  fi
}

zc_install(){
  zc_pull || { say "ERROR: pull failed (check network / ghcr.io reachability)."; return 1; }
  zc_activate || return 1
  $SUDO systemctl daemon-reload
  say "[*] Starting $ZC_SERVICE ..."
  $SUDO systemctl start "$ZC_SERVICE" || true
  sleep 2; zc_status
  say "ZeroClaw gateway should now answer on port $ZC_PORT."
}

zc_repull(){
  zc_pull || { say "ERROR: pull failed."; return 1; }
  zc_activate || return 1
  $SUDO systemctl daemon-reload
  say "[*] Restarting $ZC_SERVICE with the freshly pulled image ..."
  $SUDO systemctl restart "$ZC_SERVICE" || $SUDO systemctl start "$ZC_SERVICE" || true
  sleep 2; zc_status
}

zc_remove(){
  say "[*] Stopping $ZC_SERVICE ..."
  $SUDO systemctl stop "$ZC_SERVICE" 2>/dev/null || true
  [ -f "$ZC_ACTIVE" ] && { say "[*] Removing active quadlet ..."; $SUDO rm -f "$ZC_ACTIVE"; }
  $SUDO systemctl daemon-reload
  say "[*] ZeroClaw removed. Image cache + 'zeroclaw-data' volume retained for"
  say "    a fast re-install; run this tool again to reinstall."
  zc_status
}

zc_menu(){
  zc_status
  if zc_is_installed || zc_is_active; then
    say
    say "ZeroClaw is already present (it ships active by default on Reinhardt)."
    read -r -p "Action — [r]emove, [u]pdate (re-pull+restart), [b]ack: " a
    case "${a:-b}" in
      r|R) zc_remove ;;
      u|U) zc_repull ;;
      *)   say "No changes made." ;;
    esac
  else
    say
    read -r -p "ZeroClaw is not installed. [i]nstall now, [b]ack: " a
    case "${a:-b}" in
      i|I) zc_install ;;
      *)   say "No changes made." ;;
    esac
  fi
}

# ---- MNEMOS (memory substrate, via ncz) ---------------------------------
mnemos_active(){ systemctl is-active --quiet mnemos.service 2>/dev/null; }

mnemos_menu(){
  hr; say "  MNEMOS — persistent memory substrate"; hr
  say "  REST + MCP + OpenAI-compatible gateway on :5002 (sqlite-backed)."
  say "  Pulled on demand from ghcr.io/ncz-os/mnemos (network required)."
  if mnemos_active; then
    say "  service  : mnemos.service  ACTIVE"
    say "  endpoint : http://$(host_ip):5002   (health: curl -fsS http://127.0.0.1:5002/health)"
  else
    say "  service  : not running"
  fi
  hr
  if ! have_ncz; then
    say "ERROR: the 'ncz' CLI is not installed; cannot manage MNEMOS from here."
    return 1
  fi
  say
  if mnemos_active; then
    say "MNEMOS is already running. Use 'systemctl status mnemos.service' to inspect."
    read -r -p "Action — [u]pdate (re-pull+restart), [b]ack: " a
    case "${a:-b}" in
      u|U) $SUDO ncz install mnemos ;;
      *)   say "No changes made." ;;
    esac
  else
    read -r -p "Install MNEMOS now? [i]nstall, [b]ack: " a
    case "${a:-b}" in
      i|I) $SUDO ncz install mnemos ;;
      *)   say "No changes made." ;;
    esac
  fi
}

# ---- NemoClaw (NVIDIA OpenShell runtime, via ncz) -----------------------
nemoclaw_active(){ systemctl is-active --quiet nemoclaw.service 2>/dev/null; }

nemoclaw_menu(){
  hr; say "  NemoClaw — NVIDIA NemoClaw OpenShell sandbox runtime"; hr
  say "  Pulled on demand (about 2.4 GB compressed; network required)."
  nemoclaw_active && say "  service  : nemoclaw.service  ACTIVE" || say "  service  : not running"
  hr
  if ! have_ncz; then
    say "ERROR: the 'ncz' CLI is not installed; cannot manage NemoClaw from here."
    return 1
  fi
  say
  read -r -p "Install NemoClaw now? [i]nstall, [b]ack: " a
  case "${a:-b}" in
    i|I) $SUDO ncz install nemoclaw ;;
    *)   say "No changes made." ;;
  esac
}

# ---- main menu ----------------------------------------------------------
main_menu(){
  while true; do
    clear 2>/dev/null || true
    hr
    say "  NCZ — Install AI Agents"
    say "  The distro is agent-ENABLED; agents are OPT-IN (nothing AI runs"
    say "  until you install it here or via the 'ncz' CLI)."
    hr
    say "  1) ZeroClaw   — autonomous coding agent gateway (:$ZC_PORT)"
    say "  2) MNEMOS     — persistent memory substrate (:5002)"
    say "  3) NemoClaw   — NVIDIA OpenShell sandbox runtime"
    say "  4) Show status of all"
    say "  q) Quit"
    hr
    read -r -p "Select [1-4, q]: " choice
    case "${choice:-q}" in
      1) zc_menu; pause ;;
      2) mnemos_menu; pause ;;
      3) nemoclaw_menu; pause ;;
      4) zc_status; say; { mnemos_active && say "MNEMOS  : ACTIVE (:5002)" || say "MNEMOS  : not running"; }
         { nemoclaw_active && say "NemoClaw: ACTIVE" || say "NemoClaw: not running"; }; pause ;;
      q|Q) say "Bye."; exit 0 ;;
      *)   say "Unknown selection."; sleep 1 ;;
    esac
  done
}

main_menu
