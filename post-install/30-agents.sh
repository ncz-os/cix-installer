#!/bin/bash
# 30-agents.sh - agent stack via Podman Quadlet.
#
# r73 and earlier auto-pulled all 3 agent containers + portainer at
# first boot. That hit two failure modes:
#   1. Hermes 2.55 GB pull blocked first-boot UX for 5-10 min, often
#      looking like the system was hung.
#   2. Cold-RTC clock skew on first boot caused TLS cert validation
#      to fail on portainer-bootstrap (cert validity window vs. RTC).
#
# Current contract: the three core agents are active Quadlets on first boot.
# The image ships:
#   - podman + crun + conmon + netavark + aardvark-dns
#   - quadlet templates at /usr/share/ncz/quadlets/
#   - active quadlets staged at /etc/containers/systemd/
#   - nclawzero-load-agent-images.service to load OCI tarballs or pull refs
#   - /etc/nclawzero/agent-env.sample + agent-env (operator API keys)
#   - /usr/local/bin/ncz CLI with agent management helpers
#
# Re-runnable, idempotent.
# Same upstream image digests as the Pi fleet (bigpi/clawpi).

set +e
echo '[30] agent stack (podman + active quadlets + ncz CLI)'

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    podman crun conmon netavark aardvark-dns catatonit librsvg2-bin whiptail \
    2>&1 | tail -3

# Stage quadlet templates from the copied installer payload. /cdrom is not
# bind-mounted in netinstall mode, so prefer the late.sh copy and only fall
# back to /cdrom for older/manual recovery runs.
ASSETS=/usr/local/lib/cix-installer/assets/agent-stack
if [ ! -d "$ASSETS" ] && [ -d /cdrom/cixmini/assets/agent-stack ]; then
    ASSETS=/cdrom/cixmini/assets/agent-stack
fi
QUADLET_TEMPLATES=/usr/share/ncz/quadlets
QUADLET_ACTIVE=/etc/containers/systemd
IMAGE_DIR=/var/lib/nclawzero/agent-images
mkdir -p "$QUADLET_TEMPLATES"
if [ -d "$ASSETS" ]; then
    cp -a "$ASSETS"/*.container "$QUADLET_TEMPLATES"/ 2>/dev/null
    cp -a "$ASSETS"/*.network "$QUADLET_TEMPLATES"/ 2>/dev/null
else
    echo "[30] WARN: agent-stack assets missing; quadlet templates will be absent"
fi

# Remove only stale Portainer bootstrap units from older revs. The three
# agent quadlets are intentionally active on first boot.
rm -f /etc/systemd/system/portainer-bootstrap.service \
      /etc/systemd/system/{default,multi-user}.target.wants/portainer-bootstrap.service

# r61: --insecure for non-TLS dashboard
grep -q -- '--insecure' "$QUADLET_TEMPLATES"/hermes.container 2>/dev/null || \
    sed -i 's|^Exec=dashboard --host 0.0.0.0 --port 8642 --no-open$|Exec=dashboard --host 0.0.0.0 --port 8642 --no-open --insecure|' \
        "$QUADLET_TEMPLATES"/hermes.container 2>/dev/null
# r74: relax PublishPort to LAN — bigpi reference parity. Operator can
# tighten via per-host override under /etc/containers/systemd/
sed -i 's|^PublishPort=127.0.0.1:8642:8642$|PublishPort=8642:8642|' \
    "$QUADLET_TEMPLATES"/hermes.container 2>/dev/null

# r74 (codex): assert sed patches landed (template drift would silently no-op above)
HERMES_TPL="$QUADLET_TEMPLATES/hermes.container"
if [ -f "$HERMES_TPL" ]; then
    grep -q -- "--insecure" "$HERMES_TPL" ||         echo "[30] WARN: hermes --insecure injection did not match"
    grep -q "^PublishPort=8642:8642$" "$HERMES_TPL" ||         echo "[30] WARN: hermes PublishPort relax did not match"
fi

# /etc/nclawzero/agent-env — fleet API keys. Always write .sample;
# only create live file if absent. Operator-set keys must NOT be clobbered.
groupadd -r nclawzero 2>/dev/null
mkdir -p /etc/nclawzero
cat > /etc/nclawzero/agent-env.sample << 'ENV'
# /etc/nclawzero/agent-env — fleet API keys for zeroclaw + openclaw + hermes
# Edit, then: sudo ncz agent restart <name>
TOGETHER_API_KEY=
GROQ_API_KEY=
GOOGLE_API_KEY=
GEMINI_API_KEY=
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
PERPLEXITY_API_KEY=
MISTRAL_API_KEY=
ENV
chmod 0644 /etc/nclawzero/agent-env.sample

if [ ! -f /etc/nclawzero/agent-env ]; then
    cp /etc/nclawzero/agent-env.sample /etc/nclawzero/agent-env
    chmod 0640 /etc/nclawzero/agent-env
    chgrp nclawzero /etc/nclawzero/agent-env
    echo "  /etc/nclawzero/agent-env created from .sample"
else
    echo "  /etc/nclawzero/agent-env exists — preserving operator keys"
    chmod 0640 /etc/nclawzero/agent-env 2>/dev/null
    chgrp nclawzero /etc/nclawzero/agent-env 2>/dev/null
fi

# openclaw home dir owned 1000:1000 (container's 'node' UID writes config there)
mkdir -p /var/lib/nclawzero/openclaw-home
chown -R 1000:1000 /var/lib/nclawzero/openclaw-home
cat > /var/lib/nclawzero/openclaw-home/openclaw.json << 'OPENCLAW'
{ "gateway": { "bind": "lan" } }
OPENCLAW
chown 1000:1000 /var/lib/nclawzero/openclaw-home/openclaw.json

# Agent image manifest + first-boot loader. Full/offline images may stage OCI
# tarballs under assets/agent-images; netinstall images leave the tarballs
# absent and the loader pulls the pinned refs from registries instead.
mkdir -p "$IMAGE_DIR" /usr/local/sbin /etc/systemd/system
if [ -d /usr/local/lib/cix-installer/assets/agent-images ]; then
    cp -an /usr/local/lib/cix-installer/assets/agent-images/. "$IMAGE_DIR"/ 2>/dev/null || true
elif [ -d /cdrom/cixmini/assets/agent-images ]; then
    cp -an /cdrom/cixmini/assets/agent-images/. "$IMAGE_DIR"/ 2>/dev/null || true
fi

cat > /usr/share/ncz/agent-images.manifest << 'MANIFEST'
# agent|image-ref|oci-tarball-under-/var/lib/nclawzero/agent-images
zeroclaw|ghcr.io/perlowja/nclawzero-demo:latest|zeroclaw.oci.tar
openclaw|ghcr.io/openclaw/openclaw@sha256:06b4f3dfa3c88d49c92e99d635dc62053d4afd045d6220e811dff6190040f3de|openclaw.oci.tar
hermes|docker.io/nousresearch/hermes-agent@sha256:aa60e7483a6fad26eee233d2498d4f2b4223bf9d8990e3b07017f19b6ba7b6fe|hermes.oci.tar
MANIFEST
chmod 0644 /usr/share/ncz/agent-images.manifest

cat > /usr/local/sbin/nclawzero-load-agent-images << 'LOADSCRIPT'
#!/bin/bash
set -uo pipefail

MANIFEST=/usr/share/ncz/agent-images.manifest
IMAGE_DIR=/var/lib/nclawzero/agent-images
PODMAN=/usr/bin/podman
rc=0

if [ ! -x "$PODMAN" ]; then
    echo "[agent-images] ERROR: podman missing"
    exit 1
fi
if [ ! -f "$MANIFEST" ]; then
    echo "[agent-images] ERROR: manifest missing: $MANIFEST"
    exit 1
fi

while IFS='|' read -r agent image tarball; do
    case "$agent" in
        ""|\#*) continue ;;
    esac

    if "$PODMAN" image exists "$image" 2>/dev/null; then
        echo "[agent-images] $agent already present: $image"
        continue
    fi

    path="$tarball"
    case "$path" in
        /*) ;;
        *) path="$IMAGE_DIR/$path" ;;
    esac

    if [ -f "$path" ]; then
        echo "[agent-images] loading $agent from $path"
        if ! "$PODMAN" load -i "$path"; then
            echo "[agent-images] ERROR: podman load failed for $agent"
            rc=1
            continue
        fi
    else
        echo "[agent-images] no OCI tarball for $agent; pulling $image"
        if ! "$PODMAN" pull "$image"; then
            echo "[agent-images] ERROR: podman pull failed for $agent"
            rc=1
            continue
        fi
    fi

    if "$PODMAN" image exists "$image" 2>/dev/null; then
        echo "[agent-images] ready: $agent"
    else
        echo "[agent-images] WARN: $agent loaded/pulled but exact ref not found by podman image exists"
    fi
done < "$MANIFEST"

exit "$rc"
LOADSCRIPT
chmod 0755 /usr/local/sbin/nclawzero-load-agent-images

cat > /etc/systemd/system/nclawzero-load-agent-images.service << 'UNIT'
[Unit]
Description=Load or pull NCZ agent container images
Documentation=man:podman-load(1) man:podman-pull(1)
Wants=network-online.target
After=network-online.target
Before=zeroclaw.service openclaw.service hermes.service
ConditionPathExists=/var/lib/nclawzero/agent-images

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=3600
ExecStart=/usr/local/sbin/nclawzero-load-agent-images

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/nclawzero-load-agent-images.service

# Named volumes are also created lazily by podman run, but pre-creating them
# makes the target state explicit for operator inspection.
for v in zeroclaw-data openclaw-data hermes-data; do
    podman volume exists "$v" 2>/dev/null || podman volume create "$v" 2>/dev/null || true
done

# Activate the three first-boot agent quadlets. The [Install] sections are
# consumed by the Podman systemd generator at boot.
mkdir -p "$QUADLET_ACTIVE"
cp -a "$QUADLET_TEMPLATES"/*.container "$QUADLET_ACTIVE"/ 2>/dev/null || true
cp -a "$QUADLET_TEMPLATES"/*.network "$QUADLET_ACTIVE"/ 2>/dev/null || true
systemctl enable nclawzero-load-agent-images.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# r74: full ncz CLI with `agent install` subcommand (whiptail UI).
mkdir -p /usr/local/bin
cat > /usr/local/bin/ncz << 'NCZSCRIPT'
#!/bin/bash
# ncz — NCZ 26.5 "Reinhardt" CLI
# Manages the optional agent stack (zeroclaw, openclaw, hermes, portainer).
# Quadlet templates live at /usr/share/ncz/quadlets/.
# Active quadlets get copied to /etc/containers/systemd/ on install.

set +e

QUADLET_TEMPLATES=/usr/share/ncz/quadlets
QUADLET_ACTIVE=/etc/containers/systemd
SENTINEL_DIR=/var/lib/nclawzero
AGENTS=(zeroclaw openclaw hermes)

# Image digests (pinned, fleet-canonical — must match Pi fleet quadlets)
declare -A AGENT_IMAGE
AGENT_IMAGE[zeroclaw]='ghcr.io/perlowja/nclawzero-demo:latest'
AGENT_IMAGE[openclaw]='ghcr.io/openclaw/openclaw@sha256:06b4f3dfa3c88d49c92e99d635dc62053d4afd045d6220e811dff6190040f3de'
AGENT_IMAGE[hermes]='docker.io/nousresearch/hermes-agent@sha256:aa60e7483a6fad26eee233d2498d4f2b4223bf9d8990e3b07017f19b6ba7b6fe'
AGENT_IMAGE[portainer]='docker.io/portainer/portainer-ce:lts'

declare -A AGENT_DESC
AGENT_DESC[zeroclaw]='ZeroClaw daemon — gateway + agents (~109 MB)'
AGENT_DESC[openclaw]='OpenClaw — NemoClaw upstream OSS (~756 MB)'
AGENT_DESC[hermes]='Hermes Agent — NousResearch (~2.55 GB, slowest)'
AGENT_DESC[portainer]='Portainer CE — container management web UI (~50 MB)'

declare -A AGENT_PORT
AGENT_PORT[zeroclaw]=42617
AGENT_PORT[openclaw]=18789
AGENT_PORT[hermes]=8642
AGENT_PORT[portainer]=9000

declare -A AGENT_DNAME
AGENT_DNAME[zeroclaw]=ZeroClaw
AGENT_DNAME[openclaw]=OpenClaw
AGENT_DNAME[hermes]=Hermes
AGENT_DNAME[portainer]=Portainer

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This action needs root. Re-run with sudo:"
        echo "  sudo ncz $*"
        exit 1
    fi
}

is_installed() {
    case "$1" in
        portainer)
            podman container exists portainer 2>/dev/null
            ;;
        *)
            [ -f "$QUADLET_ACTIVE/$1.container" ]
            ;;
    esac
}

ensure_network() {
    podman network exists hermes-isolated-v2 2>/dev/null && return 0
    podman network create --driver bridge hermes-isolated-v2 2>/dev/null
}

ensure_volume() {
    podman volume exists "$1" 2>/dev/null || \
        podman volume create "$1" 2>/dev/null
}

write_launcher() {
    local agent="$1"
    local port="${AGENT_PORT[$agent]}"
    case "$agent" in
        zeroclaw) icon=ncz-zeroclaw ;;
        openclaw) icon=ncz-openclaw ;;
        hermes)   icon=ncz-hermes ;;
        portainer) icon=portainer ;;
    esac
    # Capitalize for desktop name
    name="${AGENT_DNAME[$agent]}"
    cat > /etc/skel/Desktop/$name.desktop <<DESKLAUNCH
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=${AGENT_DESC[$agent]}
Exec=/usr/bin/vivaldi-stable http://127.0.0.1:$port/
Icon=$icon
Terminal=false
Categories=Network;
DESKLAUNCH
    chmod 0755 /etc/skel/Desktop/$name.desktop
    cp /etc/skel/Desktop/$name.desktop /usr/share/applications/$name.desktop 2>/dev/null
    chmod 0644 /usr/share/applications/$name.desktop 2>/dev/null
    # Mirror to current users' Desktops so launchers appear without re-login
    for d in /home/*; do
        [ -d "$d/Desktop" ] || continue
        u=$(stat -c %U "$d")
        cp /etc/skel/Desktop/$name.desktop "$d/Desktop/$name.desktop"
        chown "$u:$u" "$d/Desktop/$name.desktop"
        chmod 0755 "$d/Desktop/$name.desktop"
    done
}

remove_launcher() {
    local agent="$1"
    name="${AGENT_DNAME[$agent]}"
    rm -f /etc/skel/Desktop/$name.desktop /usr/share/applications/$name.desktop
    for d in /home/*; do
        rm -f "$d/Desktop/$name.desktop" 2>/dev/null
    done
}

cmd_agent_install() {
    require_root agent install "$@"

    # If args provided: install those agents non-interactively.
    # Otherwise: whiptail checkbox menu.
    local selected=()
    if [ $# -gt 0 ]; then
        for a in "$@"; do
            case "$a" in
                --all) selected=(zeroclaw openclaw hermes portainer) ;;
                zeroclaw|openclaw|hermes|portainer) selected+=("$a") ;;
                *) echo "unknown agent: $a"; exit 2 ;;
            esac
        done
    elif command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        local choices
        choices=$(whiptail --title "NCZ Agent Installer" \
            --checklist "Select agents to install (space toggles, enter confirms):" \
            16 78 5 \
            "zeroclaw"  "${AGENT_DESC[zeroclaw]}"  ON \
            "openclaw"  "${AGENT_DESC[openclaw]}"  OFF \
            "hermes"    "${AGENT_DESC[hermes]}"    OFF \
            "portainer" "${AGENT_DESC[portainer]}" ON \
            3>&1 1>&2 2>&3)
        local rc=$?
        if [ $rc -ne 0 ]; then
            echo "cancelled."
            exit 0
        fi
        # whiptail returns "zeroclaw" "portainer" with quotes — eval is safe here
        # because the values come from our own hardcoded list above.
        eval "selected=($choices)"
    else
        echo "no TTY and no agents specified — try: ncz agent install zeroclaw openclaw"
        exit 2
    fi

    if [ ${#selected[@]} -eq 0 ]; then
        echo "nothing selected — exiting."
        exit 0
    fi

    echo
    echo "Installing: ${selected[*]}"
    echo "Pulling images (this may take several minutes for hermes)..."
    echo

    mkdir -p "$QUADLET_ACTIVE" "$SENTINEL_DIR"

    # Hermes needs the dedicated network ahead of the quadlet
    if [[ " ${selected[*]} " == *" hermes "* ]]; then
        ensure_network
        if [ -f "$QUADLET_TEMPLATES/hermes-isolated.network" ]; then
            cp "$QUADLET_TEMPLATES/hermes-isolated.network" "$QUADLET_ACTIVE/" 2>/dev/null
        fi
    fi

    local failed=()
    for a in "${selected[@]}"; do
        echo "===== $a ====="
        case "$a" in
            portainer)
                # Portainer runs directly via podman, not a quadlet.
                ensure_volume portainer_data
                if ! podman pull "${AGENT_IMAGE[portainer]}"; then
                    failed+=("$a")
                    echo "  FAILED to pull $a"
                    continue
                fi
                # Stop+remove existing if present (idempotent re-install)
                podman rm -f portainer 2>/dev/null
                if podman run -d --name portainer --restart=always \
                    --label nclawzero=true \
                    -p 9000:9000 -p 9443:9443 \
                    -v /run/podman/podman.sock:/var/run/docker.sock:Z \
                    -v portainer_data:/data:Z \
                    "${AGENT_IMAGE[portainer]}"; then
                    write_launcher portainer
                    echo "  $a started — http://127.0.0.1:9000/"
                else
                    failed+=("$a")
                fi
                ;;
            *)
                if ! podman pull "${AGENT_IMAGE[$a]}"; then
                    failed+=("$a")
                    echo "  FAILED to pull $a"
                    continue
                fi
                # Place the quadlet
                if [ -f "$QUADLET_TEMPLATES/$a.container" ]; then
                    cp "$QUADLET_TEMPLATES/$a.container" "$QUADLET_ACTIVE/$a.container"
                else
                    failed+=("$a")
                    echo "  FAILED — quadlet template missing: $QUADLET_TEMPLATES/$a.container"
                    continue
                fi
                systemctl daemon-reload
                if systemctl start "$a.service" 2>&1 | grep -v "^$"; then
                    : # daemon-reload happened, start may have async-launched
                fi
                # Allow up to 60s for the service to come up to active
                local i=0
                while [ $i -lt 30 ]; do
                    if systemctl is-active --quiet "$a.service"; then
                        break
                    fi
                    sleep 2
                    i=$((i+1))
                done
                if systemctl is-active --quiet "$a.service"; then
                    write_launcher "$a"
                    echo "  $a active — http://127.0.0.1:${AGENT_PORT[$a]}/"
                else
                    failed+=("$a")
                    echo "  $a not active — see: ncz agent logs $a"
                fi
                ;;
        esac
    done

    touch "$SENTINEL_DIR/.agents-installed"
    update-desktop-database 2>&1 | tail -1

    echo
    if [ ${#failed[@]} -gt 0 ]; then
        echo "FAILED: ${failed[*]}"
        echo "Inspect with: ncz agent logs <name>  (or:  journalctl -u <name>.service)"
        exit 1
    fi
    echo "All selected agents installed."
    echo "Edit API keys: sudo nano /etc/nclawzero/agent-env"
    echo "Then restart: sudo ncz agent restart <name>"
}

cmd_agent_uninstall() {
    require_root agent uninstall "$@"
    [ $# -lt 1 ] && { echo "usage: ncz agent uninstall <name|--all>"; exit 2; }
    local targets=()
    if [ "$1" = "--all" ]; then
        targets=(zeroclaw openclaw hermes portainer)
    else
        targets=("$@")
    fi
    for a in "${targets[@]}"; do
        case "$a" in
            portainer)
                podman rm -f portainer 2>/dev/null
                ;;
            zeroclaw|openclaw|hermes)
                systemctl stop "$a.service" 2>/dev/null
                rm -f "$QUADLET_ACTIVE/$a.container"
                podman rm -f "$a" 2>/dev/null
                ;;
            *) echo "unknown agent: $a"; continue ;;
        esac
        remove_launcher "$a"
        echo "  $a uninstalled"
    done
    systemctl daemon-reload
}

cmd_agent_list() {
    printf "%-12s %-15s %s\n" AGENT STATE URL
    for a in zeroclaw openclaw hermes; do
        if is_installed "$a"; then
            state=$(systemctl is-active "$a.service" 2>/dev/null)
        else
            state="not-installed"
        fi
        printf "%-12s %-15s http://127.0.0.1:%s/\n" "$a" "$state" "${AGENT_PORT[$a]}"
    done
    # Use sudo so non-root callers see rootful container state
    if [ "$EUID" -eq 0 ]; then
        PODMAN=podman
    else
        PODMAN="sudo -n podman"
    fi
    if $PODMAN container exists portainer 2>/dev/null; then
        state=$($PODMAN ps --filter name=portainer --format '{{.Status}}' 2>/dev/null | head -1)
        [ -z "$state" ] && state=stopped
    else
        state="not-installed"
    fi
    printf "%-12s %-15s http://127.0.0.1:%s/\n" "portainer" "$state" "${AGENT_PORT[portainer]}"
}

cmd_agent_web() {
    cmd_agent_list
}

cmd_help() {
    cat <<HELP
ncz — NCZ 26.5 "Reinhardt" CLI

Agent management:
  ncz agent install [name...]      install agents (interactive if no args)
  ncz agent install --all          install all 4 (~3.5 GB pull)
  ncz agent uninstall <name>       remove agent (stops + removes container)
  ncz agent list                   show install state + URLs
  ncz agent status <name>          systemctl status of agent service
  ncz agent start|stop|restart <name>
  ncz agent logs <name>            follow journal for agent
  ncz agent shell <name>           shell into agent container
  ncz agent web                    show dashboard URLs (alias for list)

Other:
  ncz version                      build version
  ncz help                         this message

Available agents: zeroclaw, openclaw, hermes, portainer
Quadlet templates: /usr/share/ncz/quadlets/
API keys: /etc/nclawzero/agent-env  (group: nclawzero)
HELP
}

case "$1 $2" in
    "agent install"*)   shift 2; cmd_agent_install "$@" ;;
    "agent uninstall"*) shift 2; cmd_agent_uninstall "$@" ;;
    "agent list"*|"agent ")     cmd_agent_list ;;
    "agent web "*|"agent web")  cmd_agent_web ;;
    "agent status")     systemctl status "$3.service" --no-pager ;;
    "agent start")      require_root agent start "$3"; systemctl start "$3.service" ;;
    "agent stop")       require_root agent stop  "$3"; systemctl stop  "$3.service" ;;
    "agent restart")    require_root agent restart "$3"; systemctl restart "$3.service" ;;
    "agent logs")       journalctl -u "$3.service" -f --no-pager ;;
    "agent enable")     require_root agent enable "$3"; systemctl enable --now "$3.service" ;;
    "agent disable")    require_root agent disable "$3"; systemctl disable --now "$3.service" ;;
    "agent shell")      podman exec -it "$3" sh ;;
    "version "*|"--version "*) echo 'ncz 26.5 r74 (Reinhardt)' ;;
    "help "*|"--help "*|"-h "*|" "|"") cmd_help ;;
    *) cmd_help; exit 2 ;;
esac
NCZSCRIPT
chmod 0755 /usr/local/bin/ncz

# r74: desktop launchers — ONLY install once-and-done items pre-staged.
# Agent launchers (ZeroClaw/OpenClaw/Hermes/Portainer) get written by
# `ncz agent install` AFTER the user opts in.
mkdir -p /etc/skel/Desktop
rm -rf /etc/skel/Desktop/Agents 2>/dev/null
# Defensive: remove any stale auto-placed agent launchers from r73 images
rm -f /etc/skel/Desktop/{ZeroClaw,OpenClaw,Hermes,Portainer}.desktop
rm -f /usr/share/applications/{ZeroClaw,OpenClaw,Hermes,Portainer}.desktop

# Install-NCZ-Agents launcher — prominent, runs the interactive installer
cat > /etc/skel/Desktop/Install-NCZ-Agents.desktop <<'IA'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install NCZ Agents
GenericName=Agent installer (zeroclaw / openclaw / hermes / portainer)
Comment=Pull + start optional agent containers (one-time per agent)
Exec=xfce4-terminal --title="Install NCZ Agents" --hold --command="sudo ncz agent install"
Icon=ncz-rocket
Terminal=false
Categories=System;Settings;Network;
IA
chmod 0755 /etc/skel/Desktop/Install-NCZ-Agents.desktop
cp /etc/skel/Desktop/Install-NCZ-Agents.desktop /usr/share/applications/

# Rheinhardt YouTube launcher with custom rocket icon (set in 50-brand.sh)
cat > /etc/skel/Desktop/Rheinhardt-Through-and-Beyond.desktop << 'RT'
[Desktop Entry]
Version=1.0
Type=Link
Name="Through and beyond!" — Dr. Hans Reinhardt
GenericName=The Black Hole (1979)
Comment=Required viewing for NCZ users.
URL=https://www.youtube.com/watch?v=HI5vaKdFnCA
Icon=ncz-rocket
RT
chmod 0755 /etc/skel/Desktop/Rheinhardt-Through-and-Beyond.desktop

# NCZ-Help.md — quick reference doc (updated for r74 ncz CLI)
cat > /etc/skel/Desktop/NCZ-Help.md << 'HELP'
# NCZ 26.5 "Reinhardt" — Quick Reference

> Dr. Reinhardt has gone into the Black Hole.

## First-time setup (5 minutes)

The base image ships with **only Claude Code** pre-installed. Everything
else is opt-in via the `ncz` CLI.

### 1. Install agents (interactive)

```
sudo ncz agent install
```

A checkbox menu appears. Pick the ones you want, hit Enter:

```
  [x] zeroclaw    NCZ daemon — gateway + agents (~109 MB)
  [ ] openclaw    OpenClaw — NemoClaw upstream OSS (~756 MB)
  [ ] hermes      Hermes Agent — NousResearch (~2.55 GB, slowest)
  [x] portainer   Container management web UI (~50 MB)
```

After install, a desktop launcher for each agent appears. Click to open
its dashboard. Re-run `sudo ncz agent install` later to add more.

### 2. Set API keys

Edit `/etc/nclawzero/agent-env` (group: `nclawzero`):

```
sudo nano /etc/nclawzero/agent-env
```

Fill in any providers you have keys for:

```
TOGETHER_API_KEY=...
GROQ_API_KEY=...
GOOGLE_API_KEY=...
GEMINI_API_KEY=...
ANTHROPIC_API_KEY=...
OPENAI_API_KEY=...
PERPLEXITY_API_KEY=...
MISTRAL_API_KEY=...
```

Restart affected agents:

```
sudo ncz agent restart zeroclaw
```

## Non-interactive install (scripting)

```
sudo ncz agent install zeroclaw              # one agent
sudo ncz agent install zeroclaw portainer    # multiple
sudo ncz agent install --all                 # all four (~3.5 GB pull)
```

## Daily operation

```
ncz agent list                  # show install state + URLs
ncz agent status <name>         # systemctl status
sudo ncz agent start   <name>
sudo ncz agent stop    <name>
sudo ncz agent restart <name>
sudo ncz agent logs    <name>   # follow journal (Ctrl-C to exit)
ncz agent shell <name>          # shell into container
ncz agent web                   # show dashboard URLs (alias for list)
ncz version
ncz help
```

Available agents: **zeroclaw**, **openclaw**, **hermes**, **portainer**

## Web dashboards

| Agent     | URL                      | What                            |
|-----------|--------------------------|---------------------------------|
| zeroclaw  | http://127.0.0.1:42617/  | NCZ gateway daemon + web UI     |
| openclaw  | http://127.0.0.1:18789/  | OpenClaw (NemoClaw upstream)    |
| hermes    | http://127.0.0.1:8642/   | Hermes Agent (NousResearch)     |
| Portainer | http://127.0.0.1:9000/   | Container management            |

## Uninstall

```
sudo ncz agent uninstall hermes      # one agent
sudo ncz agent uninstall --all       # everything
```

Stops + removes the container, deletes the quadlet, removes the desktop
launcher. Re-runnable.

## Image sources (pinned)

```
zeroclaw   ghcr.io/perlowja/nclawzero-demo:latest      (NCZ demo, web UI baked)
openclaw   ghcr.io/openclaw/openclaw@sha256:06b4f3df...
hermes     docker.io/nousresearch/hermes-agent@sha256:aa60e748...
portainer  docker.io/portainer/portainer-ce:lts
```

Quadlet templates: `/usr/share/ncz/quadlets/`

## NPU inference (Cix Zhouyi)

```
NPU device:    /dev/aipu
ACPI cores:    CIXH4000:00 + CIXH4010:00..02  (3 cores · 12 TECs)
Userspace:     cix-noe-umd  (mobilenet ≈ 640 inf/s on MS-R1)
```

See `/usr/share/doc/ncz/NPU-STATUS.md` for tooling and benchmarks.

## Troubleshooting

```
ncz agent logs <name>           # tail journal for an agent
journalctl -u <name>.service    # full journal (no follow)
podman ps -a                    # container state across all agents
sudo systemctl status <name>.service
```

If a pull fails on first try (clock skew on cold boot), retry:

```
sudo ncz agent install <name>
```

By second login the system clock has resynced via NTP and the registry
TLS handshake succeeds.

## Brand

NCZ 26.5 "Reinhardt"  ·  Cix Sky1 / CP8180  ·  *Workloads. Not wallpapers.*

Codenames track destructive cosmic phenomena: Reinhardt (black hole),
future revs Magnetar, Supernova, Vacuum-Decay.
HELP
chmod 0644 /etc/skel/Desktop/NCZ-Help.md

# NCZ CLI desktop launcher
cat > /etc/skel/Desktop/NCZ-CLI.desktop << 'NCZCLI'
[Desktop Entry]
Version=1.0
Type=Application
Name=NCZ CLI
Comment=NCZ command-line — agents, NPU status (ncz help)
Exec=xfce4-terminal --title=NCZ --hold --command="ncz help"
Icon=ncz-rocket
Terminal=false
Categories=System;Settings;
NCZCLI
chmod 0755 /etc/skel/Desktop/NCZ-CLI.desktop

# ClaudeCode terminal launcher (the ONLY agent pre-installed)
cat > /etc/skel/Desktop/ClaudeCode.desktop << 'CC'
[Desktop Entry]
Version=1.0
Type=Application
Name=Claude Code
Comment=Anthropic Claude Code CLI
Exec=xfce4-terminal --title=ClaudeCode --command=claude
Icon=utilities-terminal
Terminal=false
Categories=Development;
CC
chmod 0755 /etc/skel/Desktop/ClaudeCode.desktop

# r74: bake themed PNG icons for the agents at install time so when
# ncz agent install writes the launchers they have proper icons.
mkdir -p /tmp/ncz-agent-icons /usr/share/icons/hicolor

# zeroclaw icon — amber clamp on accretion disk
cat > /tmp/ncz-agent-icons/ncz-zeroclaw.svg << 'ZSVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <radialGradient id="zbg" cx="50%" cy="50%" r="60%">
      <stop offset="0%" stop-color="#1a1a1a"/><stop offset="100%" stop-color="#0a0a0a"/>
    </radialGradient>
    <linearGradient id="zclaw" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#fef3c7"/><stop offset="50%" stop-color="#fbbf24"/>
      <stop offset="100%" stop-color="#b45309"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="url(#zbg)" rx="20"/>
  <ellipse cx="128" cy="128" rx="78" ry="22" fill="#7c2d12" opacity="0.5"/>
  <ellipse cx="128" cy="128" rx="42" ry="42" fill="#000"/>
  <circle cx="128" cy="128" r="32" fill="none" stroke="#fbbf24" stroke-width="2" opacity="0.7"/>
  <path d="M 70 70 L 95 95 L 88 105 L 65 80 Z" fill="url(#zclaw)"/>
  <path d="M 186 70 L 161 95 L 168 105 L 191 80 Z" fill="url(#zclaw)"/>
  <path d="M 70 186 L 95 161 L 88 151 L 65 176 Z" fill="url(#zclaw)"/>
  <path d="M 186 186 L 161 161 L 168 151 L 191 176 Z" fill="url(#zclaw)"/>
  <text x="128" y="234" font-family="monospace" font-size="22" font-weight="bold" text-anchor="middle" fill="#fbbf24">Z</text>
</svg>
ZSVG

# openclaw icon — open hand with circuit
cat > /tmp/ncz-agent-icons/ncz-openclaw.svg << 'OSVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <linearGradient id="oclaw" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#fef3c7"/><stop offset="100%" stop-color="#92400e"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="#0a0a0a" rx="20"/>
  <circle cx="128" cy="100" r="48" fill="none" stroke="#fbbf24" stroke-width="3"/>
  <circle cx="128" cy="100" r="24" fill="url(#oclaw)"/>
  <path d="M 60 130 Q 128 200 196 130" fill="none" stroke="#fbbf24" stroke-width="4"/>
  <path d="M 70 145 L 70 180" stroke="#fbbf24" stroke-width="3"/>
  <path d="M 100 160 L 100 200" stroke="#fbbf24" stroke-width="3"/>
  <path d="M 128 165 L 128 210" stroke="#fbbf24" stroke-width="3"/>
  <path d="M 156 160 L 156 200" stroke="#fbbf24" stroke-width="3"/>
  <path d="M 186 145 L 186 180" stroke="#fbbf24" stroke-width="3"/>
  <text x="128" y="240" font-family="monospace" font-size="22" font-weight="bold" text-anchor="middle" fill="#fbbf24">O</text>
</svg>
OSVG

# hermes icon — winged caduceus / fast-message
cat > /tmp/ncz-agent-icons/ncz-hermes.svg << 'HSVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <linearGradient id="hwing" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#fef3c7"/><stop offset="100%" stop-color="#92400e"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="#0a0a0a" rx="20"/>
  <path d="M 128 60 L 128 200" stroke="#fbbf24" stroke-width="6"/>
  <circle cx="128" cy="60" r="12" fill="#fbbf24"/>
  <path d="M 80 80 Q 60 90 50 110 Q 70 100 95 110 Q 85 95 80 80 Z" fill="url(#hwing)"/>
  <path d="M 176 80 Q 196 90 206 110 Q 186 100 161 110 Q 171 95 176 80 Z" fill="url(#hwing)"/>
  <path d="M 100 130 Q 128 110 156 130 Q 128 150 100 130" fill="none" stroke="#fbbf24" stroke-width="3"/>
  <path d="M 100 160 Q 128 140 156 160 Q 128 180 100 160" fill="none" stroke="#fbbf24" stroke-width="3"/>
  <text x="128" y="234" font-family="monospace" font-size="22" font-weight="bold" text-anchor="middle" fill="#fbbf24">H</text>
</svg>
HSVG

if command -v rsvg-convert >/dev/null 2>&1; then
    for icon in ncz-zeroclaw ncz-openclaw ncz-hermes; do
        for sz in 32 48 64 128 256; do
            install -d /usr/share/icons/hicolor/${sz}x${sz}/apps
            rsvg-convert -w $sz -h $sz /tmp/ncz-agent-icons/$icon.svg \
                -o /usr/share/icons/hicolor/${sz}x${sz}/apps/$icon.png 2>/dev/null
        done
    done
    echo "[30] agent icons rendered (zeroclaw / openclaw / hermes — 5 sizes each)"
else
    echo "[30] WARN: rsvg-convert missing — agent icons will be generic"
fi

# Portainer icon — render from existing SVG asset
if command -v rsvg-convert >/dev/null 2>&1 && [ -f /usr/local/lib/cix-installer/assets/branding/portainer.svg ]; then
    for sz in 32 48 64 128 256; do
        install -d /usr/share/icons/hicolor/${sz}x${sz}/apps
        rsvg-convert -w $sz -h $sz \
            /usr/local/lib/cix-installer/assets/branding/portainer.svg \
            -o /usr/share/icons/hicolor/${sz}x${sz}/apps/portainer.png 2>/dev/null
    done
fi

gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>&1 | tail -1

# MNEMOS web launcher (kept — pure-link, no container)
cat > /etc/skel/Desktop/MNEMOS.desktop << 'MN'
[Desktop Entry]
Version=1.0
Type=Application
Name=MNEMOS
Comment=Hybrid memory stack for AI agents
Exec=/usr/bin/vivaldi-stable https://github.com/mnemos-os/mnemos
Icon=applications-science
Terminal=false
Categories=Development;Network;
MN
chmod 0755 /etc/skel/Desktop/MNEMOS.desktop

# Mirror to /usr/share/applications so they show in Whisker / app menu
cp /etc/skel/Desktop/*.desktop /usr/share/applications/ 2>/dev/null
chmod 0644 /usr/share/applications/*.desktop 2>/dev/null
update-desktop-database 2>&1 | tail -1

# r74: ensure podman.socket is enabled so portainer can talk to it
# AFTER the operator runs `ncz agent install portainer`.
systemctl enable podman.socket 2>/dev/null

# Agent image load/pull is ordered before the three active quadlets.
systemctl enable nclawzero-load-agent-images.service 2>/dev/null || true

# disable cix-npu-driver-dkms — we ship FyrbyAdditive prebuilt .ko at
# /usr/lib/modules/<KVER>/extra/armchina_npu.ko (handled by 80-npu.sh).
systemctl mask dkms.service 2>&1 | tail -1
rm -rf /var/lib/dkms/aipu /var/lib/dkms/cix-vpu-driver 2>/dev/null
echo '[30] dkms.service masked (FyrbyAdditive prebuilt .ko ships at /usr/lib/modules/<KVER>/extra/)'

echo '[30] agent stack active: zeroclaw/openclaw/hermes quadlets staged'
echo '     templates at /usr/share/ncz/quadlets/, active units at /etc/containers/systemd/'
