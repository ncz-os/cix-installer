#!/bin/bash
# ncz-agent-cli - on-demand NCZ agent stack installer/manager.
#
# The OS installer must not stage or activate the agent stack. This helper is
# installed by 46-ncz-cli.sh and performs all Podman/quadlet/env setup only
# when an operator explicitly runs `ncz agent install`.
set +e

AGENTS="zeroclaw openclaw hermes portainer"
QUADLET_TEMPLATES=/usr/share/ncz/quadlets
QUADLET_ACTIVE=/etc/containers/systemd
SENTINEL_DIR=/var/lib/nclawzero
IMAGE_DIR=/var/lib/nclawzero/agent-images
MANIFEST=/usr/share/ncz/agent-images.manifest
NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="unknown"
NCZ_RELEASE_CODENAME=""
[ -s /etc/cix-installer/RELEASE ] && . /etc/cix-installer/RELEASE
NCZ_RELEASE_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"
[ -n "$NCZ_RELEASE_CODENAME" ] && \
    NCZ_RELEASE_LABEL="$NCZ_RELEASE_LABEL \"$NCZ_RELEASE_CODENAME\""

declare -A AGENT_IMAGE
AGENT_IMAGE[zeroclaw]='ghcr.io/zeroclaw-labs/zeroclaw:latest'
AGENT_IMAGE[openclaw]='ghcr.io/openclaw/openclaw@sha256:06b4f3dfa3c88d49c92e99d635dc62053d4afd045d6220e811dff6190040f3de'
AGENT_IMAGE[hermes]='docker.io/nousresearch/hermes-agent@sha256:aa60e7483a6fad26eee233d2498d4f2b4223bf9d8990e3b07017f19b6ba7b6fe'
AGENT_IMAGE[portainer]='docker.io/portainer/portainer-ce:lts'

declare -A AGENT_DESC
AGENT_DESC[zeroclaw]='ZeroClaw daemon - gateway + agents (~109 MB)'
AGENT_DESC[openclaw]='OpenClaw upstream OSS (~756 MB)'
AGENT_DESC[hermes]='Hermes Agent - NousResearch (~2.55 GB, slowest)'
AGENT_DESC[portainer]='Portainer CE - container management web UI (~50 MB)'

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

agent_valid() {
    case "$1" in zeroclaw|openclaw|hermes|portainer) return 0 ;; *) return 1 ;; esac
}

asset_dir() {
    for d in /usr/local/lib/cix-installer/assets/agent-stack /cdrom/cixmini/assets/agent-stack; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

agent_bootstrap() {
    require_root agent install "$@"

    if ! command -v podman >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            podman crun conmon netavark aardvark-dns catatonit librsvg2-bin whiptail
    fi

    if [ ! -f /etc/containers/storage.conf ]; then
        mkdir -p /etc/containers
        cat > /etc/containers/storage.conf <<'STORAGECONF'
[storage]
driver = "overlay"
STORAGECONF
    fi

    mkdir -p "$QUADLET_TEMPLATES" "$QUADLET_ACTIVE" "$IMAGE_DIR" "$SENTINEL_DIR" \
             /usr/local/sbin /etc/systemd/system /etc/nclawzero

    ASSETS=$(asset_dir)
    if [ -n "$ASSETS" ]; then
        cp -a "$ASSETS"/*.container "$QUADLET_TEMPLATES"/ 2>/dev/null || true
        cp -a "$ASSETS"/*.network "$QUADLET_TEMPLATES"/ 2>/dev/null || true
    else
        echo "WARN: agent-stack assets missing; quadlet templates will be absent" >&2
    fi

    rm -f /etc/systemd/system/portainer-bootstrap.service \
          /etc/systemd/system/{default,multi-user}.target.wants/portainer-bootstrap.service

    groupadd -r nclawzero 2>/dev/null || true
    cat > /etc/nclawzero/agent-env.sample <<'ENV'
# /etc/nclawzero/agent-env - fleet API keys for zeroclaw/openclaw/hermes/nemoclaw
# Edit, then: sudo ncz agent restart <name>
TOGETHER_API_KEY=
GROQ_API_KEY=
GOOGLE_API_KEY=
GEMINI_API_KEY=
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
PERPLEXITY_API_KEY=
NVIDIA_API_KEY=
MISTRAL_API_KEY=
ENV
    chmod 0644 /etc/nclawzero/agent-env.sample
    if [ ! -f /etc/nclawzero/agent-env ]; then
        cp /etc/nclawzero/agent-env.sample /etc/nclawzero/agent-env
    fi
    chmod 0640 /etc/nclawzero/agent-env 2>/dev/null || true
    chgrp nclawzero /etc/nclawzero/agent-env 2>/dev/null || true

    mkdir -p /var/lib/nclawzero/openclaw-home
    chown -R 1000:1000 /var/lib/nclawzero/openclaw-home 2>/dev/null || true
    if [ ! -f /var/lib/nclawzero/openclaw-home/openclaw.json ]; then
        cat > /var/lib/nclawzero/openclaw-home/openclaw.json <<'OPENCLAW'
{ "gateway": { "bind": "lan" } }
OPENCLAW
        chown 1000:1000 /var/lib/nclawzero/openclaw-home/openclaw.json 2>/dev/null || true
    fi

    for d in /usr/local/lib/cix-installer/assets/agent-images /cdrom/cixmini/assets/agent-images; do
        [ -d "$d" ] && cp -an "$d"/. "$IMAGE_DIR"/ 2>/dev/null || true
    done

    mkdir -p "$(dirname "$MANIFEST")"
    cat > "$MANIFEST" <<'MANIFEST_EOF'
# Offline-staging manifest. No agent is auto-installed or auto-started.
# `ncz agent install` loads a local OCI tarball first when present, then pulls
# from the registry only if the exact image ref is still absent.
# agent|image-ref|oci-tarball-under-/var/lib/nclawzero/agent-images
zeroclaw|ghcr.io/zeroclaw-labs/zeroclaw:latest|zeroclaw.oci.tar
MANIFEST_EOF
    chmod 0644 "$MANIFEST"

    cat > /usr/local/sbin/nclawzero-load-agent-images <<'LOADSCRIPT'
#!/bin/bash
set -uo pipefail
MANIFEST=/usr/share/ncz/agent-images.manifest
IMAGE_DIR=/var/lib/nclawzero/agent-images
PODMAN=/usr/bin/podman
rc=0
[ -x "$PODMAN" ] || { echo "[agent-images] ERROR: podman missing"; exit 1; }
[ -f "$MANIFEST" ] || { echo "[agent-images] ERROR: manifest missing: $MANIFEST"; exit 1; }
while IFS='|' read -r agent image tarball; do
    case "$agent" in ""|\#*) continue ;; esac
    "$PODMAN" image exists "$image" 2>/dev/null && { echo "[agent-images] $agent already present"; continue; }
    case "$tarball" in /*) path="$tarball" ;; *) path="$IMAGE_DIR/$tarball" ;; esac
    if [ -f "$path" ]; then
        "$PODMAN" load -i "$path" || rc=1
    else
        echo "[agent-images] $agent: no local OCI tarball"
    fi
done < "$MANIFEST"
exit "$rc"
LOADSCRIPT
    chmod 0755 /usr/local/sbin/nclawzero-load-agent-images

    cat > /etc/systemd/system/nclawzero-load-agent-images.service <<'UNIT'
[Unit]
Description=Load locally staged NCZ agent container images
Documentation=man:podman-load(1)
ConditionPathExists=/var/lib/nclawzero/agent-images

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=/usr/local/sbin/nclawzero-load-agent-images
UNIT
    chmod 0644 /etc/systemd/system/nclawzero-load-agent-images.service

    podman volume exists zeroclaw-data 2>/dev/null || podman volume create zeroclaw-data 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

load_local_image() {
    local agent="$1" image="${AGENT_IMAGE[$1]}" line tarball path
    [ -f "$MANIFEST" ] || return 1
    line=$(awk -F'|' -v a="$agent" '$1 == a { print $0; exit }' "$MANIFEST")
    [ -n "$line" ] || return 1
    tarball=${line##*|}
    case "$tarball" in /*) path="$tarball" ;; *) path="$IMAGE_DIR/$tarball" ;; esac
    [ -f "$path" ] || return 1
    podman image exists "$image" 2>/dev/null && return 0
    echo "  loading local OCI image: $path"
    podman load -i "$path"
}

ensure_image() {
    local agent="$1" image="${AGENT_IMAGE[$1]}"
    podman image exists "$image" 2>/dev/null && return 0
    load_local_image "$agent" || true
    podman image exists "$image" 2>/dev/null && return 0
    echo "  pulling $image"
    podman pull "$image"
}

is_installed() {
    case "$1" in
        portainer) podman container exists portainer 2>/dev/null ;;
        *) [ -f "$QUADLET_ACTIVE/$1.container" ] ;;
    esac
}

write_launcher() {
    local agent="$1" port="${AGENT_PORT[$1]}" icon name
    case "$agent" in
        zeroclaw) icon=ncz-zeroclaw ;;
        openclaw) icon=ncz-openclaw ;;
        hermes) icon=ncz-hermes ;;
        portainer) icon=portainer ;;
    esac
    name="${AGENT_DNAME[$agent]}"
    mkdir -p /etc/skel/Desktop /usr/share/applications
    cat > "/etc/skel/Desktop/$name.desktop" <<DESKLAUNCH
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=${AGENT_DESC[$agent]}
Exec=xdg-open http://127.0.0.1:$port/
Icon=$icon
Terminal=false
Categories=Network;
DESKLAUNCH
    chmod 0755 "/etc/skel/Desktop/$name.desktop"
    cp "/etc/skel/Desktop/$name.desktop" "/usr/share/applications/$name.desktop" 2>/dev/null || true
    chmod 0644 "/usr/share/applications/$name.desktop" 2>/dev/null || true
}

remove_launcher() {
    local name="${AGENT_DNAME[$1]}"
    rm -f "/etc/skel/Desktop/$name.desktop" "/usr/share/applications/$name.desktop"
    for d in /home/*; do rm -f "$d/Desktop/$name.desktop" 2>/dev/null; done
}

cmd_agent_install() {
    require_root agent install "$@"
    agent_bootstrap "$@"

    local selected=()
    if [ $# -gt 0 ]; then
        for a in "$@"; do
            case "$a" in
                --all) selected=(zeroclaw openclaw hermes portainer) ;;
                *) agent_valid "$a" && selected+=("$a") || { echo "unknown agent: $a"; exit 2; } ;;
            esac
        done
    elif command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
        local choices rc
        choices=$(whiptail --title "NCZ Agent Installer" \
            --checklist "Select agents to install (space toggles, enter confirms):" \
            16 78 5 \
            "zeroclaw" "${AGENT_DESC[zeroclaw]}" OFF \
            "openclaw" "${AGENT_DESC[openclaw]}" OFF \
            "hermes" "${AGENT_DESC[hermes]}" OFF \
            "portainer" "${AGENT_DESC[portainer]}" OFF \
            3>&1 1>&2 2>&3)
        rc=$?
        [ "$rc" -eq 0 ] || { echo "cancelled."; exit 0; }
        eval "selected=($choices)"
    else
        echo "no TTY and no agents specified - try: ncz agent install openclaw hermes"
        exit 2
    fi

    [ "${#selected[@]}" -gt 0 ] || { echo "nothing selected - exiting."; exit 0; }

    local failed=()
    for a in "${selected[@]}"; do
        echo "===== $a ====="
        case "$a" in
            portainer)
                podman volume exists portainer_data 2>/dev/null || podman volume create portainer_data 2>/dev/null
                if ensure_image portainer; then
                    podman rm -f portainer 2>/dev/null || true
                    podman run -d --name portainer --restart=always \
                        --label nclawzero=true \
                        -p 9000:9000 -p 9443:9443 \
                        -v /run/podman/podman.sock:/var/run/docker.sock:Z \
                        -v portainer_data:/data:Z \
                        "${AGENT_IMAGE[portainer]}" && write_launcher portainer || failed+=("$a")
                else
                    failed+=("$a")
                fi
                ;;
            *)
                if ensure_image "$a" && [ -f "$QUADLET_TEMPLATES/$a.container" ]; then
                    cp "$QUADLET_TEMPLATES/$a.container" "$QUADLET_ACTIVE/$a.container"
                    systemctl daemon-reload
                    systemctl start "$a.service" 2>/dev/null
                    write_launcher "$a"
                else
                    echo "  FAILED - missing image or template for $a"
                    failed+=("$a")
                fi
                ;;
        esac
    done

    [ "${#failed[@]}" -eq 0 ] && touch "$SENTINEL_DIR/.agents-installed"
    update-desktop-database 2>/dev/null || true
    if [ "${#failed[@]}" -gt 0 ]; then
        echo "FAILED: ${failed[*]}"
        exit 1
    fi
    echo "All selected agents installed."
    echo "Edit API keys: sudo nano /etc/nclawzero/agent-env"
}

cmd_agent_uninstall() {
    require_root agent uninstall "$@"
    [ $# -lt 1 ] && { echo "usage: ncz agent uninstall <name|--all>"; exit 2; }
    local targets=()
    if [ "$1" = "--all" ]; then targets=(zeroclaw openclaw hermes portainer); else targets=("$@"); fi
    for a in "${targets[@]}"; do
        case "$a" in
            portainer) podman rm -f portainer 2>/dev/null || true ;;
            zeroclaw|openclaw|hermes)
                systemctl stop "$a.service" 2>/dev/null || true
                rm -f "$QUADLET_ACTIVE/$a.container"
                podman rm -f "$a" 2>/dev/null || true
                ;;
            *) echo "unknown agent: $a"; continue ;;
        esac
        remove_launcher "$a"
        echo "  $a uninstalled"
    done
    systemctl daemon-reload 2>/dev/null || true
}

cmd_agent_list() {
    printf "%-12s %-15s %s\n" AGENT STATE URL
    for a in zeroclaw openclaw hermes; do
        state=not-installed
        is_installed "$a" && state=$(systemctl is-active "$a.service" 2>/dev/null)
        printf "%-12s %-15s http://127.0.0.1:%s/\n" "$a" "$state" "${AGENT_PORT[$a]}"
    done
    state=not-installed
    podman container exists portainer 2>/dev/null && state=$(podman ps --filter name=portainer --format '{{.Status}}' 2>/dev/null | head -1)
    [ -n "$state" ] || state=stopped
    printf "%-12s %-15s http://127.0.0.1:%s/\n" portainer "$state" "${AGENT_PORT[portainer]}"
}

agent_token() {
    local name="$1"
    case "$name" in
        zeroclaw)
            grep -E '^(ZEROCLAW_GATEWAY_TOKEN|ZEROCLAW_API_KEY)' /etc/nclawzero/agent-env 2>/dev/null | head -1
            journalctl -u zeroclaw --no-pager 2>/dev/null | grep -oE 'X-Pairing-Code: [0-9]+' | tail -1
            ;;
        openclaw)
            python3 -c "import json; print('OpenClaw token:', json.load(open('/var/lib/nclawzero/openclaw-home/openclaw.json')).get('gateway',{}).get('auth',{}).get('token','(not set)'))" 2>/dev/null
            ;;
        hermes) journalctl -u hermes --no-pager 2>/dev/null | grep -oE '(token|api[_-]key)[^[:space:]]*' | tail -3 ;;
    esac
}

agent_show() {
    local name="$1"
    case "$name" in
        zeroclaw) echo "ZeroClaw"; echo "  URL: http://127.0.0.1:42617/" ;;
        openclaw) echo "OpenClaw"; echo "  URL: http://127.0.0.1:18789/" ;;
        hermes) echo "Hermes"; echo "  URL: http://127.0.0.1:8642/ (loopback only)" ;;
        portainer) echo "Portainer"; echo "  URL: http://127.0.0.1:9000/" ;;
        *) echo "Unknown agent: $name"; return 1 ;;
    esac
}

cmd_help() {
    cat <<USAGE
ncz - $NCZ_RELEASE_LABEL agent CLI
  ncz agent install [name...]      install agents; interactive if no args
  ncz agent install --all          install zeroclaw/openclaw/hermes/portainer
  ncz agent uninstall <name|--all> remove installed agents
  ncz agent list                   show all agents + status
  ncz agent status <name>          detailed status
  ncz agent start|stop|restart <name>
  ncz agent logs <name>            follow journal
  ncz agent enable|disable <name>
  ncz agent web                    list dashboard URLs
  ncz agent shell <name>           shell into the container
  ncz agent token <name>           print the auth token
  ncz agent show <name>            full info: URL, token, instructions
  ncz version                      ncz version + build info
Available agents: zeroclaw, openclaw, hermes, portainer
USAGE
}

case "$1" in
    agent)
        case "$2" in
            install) shift 2; cmd_agent_install "$@" ;;
            uninstall) shift 2; cmd_agent_uninstall "$@" ;;
            list|"") cmd_agent_list ;;
            status) systemctl status "$3.service" --no-pager ;;
            start|stop|restart|enable|disable) require_root agent "$2" "$3"; systemctl "$2" "$3.service" ;;
            logs) journalctl -u "$3.service" -f --no-pager ;;
            web) cmd_agent_list ;;
            shell) podman exec -it "$3" /bin/bash 2>/dev/null || podman exec -it "$3" /bin/sh ;;
            token) agent_token "$3" ;;
            show) agent_show "$3" ;;
            *) echo "Try: ncz agent {install|uninstall|list|status|start|stop|restart|logs|enable|disable|web|shell|token|show}"; exit 1 ;;
        esac ;;
    version|"--version"|"-V") echo "$NCZ_RELEASE_LABEL" ;;
    ""|help|--help|-h) cmd_help ;;
    *) echo "Unknown command: $1"; exit 1 ;;
esac
