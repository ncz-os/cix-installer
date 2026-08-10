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
# Current contract: only zeroclaw is active as a rootful Quadlet on first boot.
# OpenClaw, Hermes, Portainer, and NemoClaw are operator opt-in after install.
# The image ships:
#   - podman + crun + conmon + netavark + aardvark-dns
#   - quadlet templates at /usr/share/ncz/quadlets/
#   - zeroclaw active quadlet staged at /etc/containers/systemd/
#   - nclawzero-load-agent-images.service to load/pull zeroclaw
#   - /etc/nclawzero/agent-env.sample + agent-env (operator API keys)
#   - /usr/local/bin/ncz CLI with agent management helpers
#
# Re-runnable, idempotent.
# Same upstream image digests as the Pi fleet (bigpi/clawpi).

set +e
RELEASE_FILE=/usr/local/lib/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE=/etc/cix-installer/RELEASE
if [ -s "$RELEASE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$RELEASE_FILE"
else
    NCZ_PRODUCT_NAME="NCZ-OS"
    NCZ_RELEASE_VERSION="unknown"
    NCZ_RELEASE_CODENAME=""
fi
NCZ_RELEASE_DISPLAY="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"
[ -n "$NCZ_RELEASE_CODENAME" ] && \
    NCZ_RELEASE_DISPLAY="$NCZ_RELEASE_DISPLAY \"$NCZ_RELEASE_CODENAME\""
echo '[30] agent stack (podman + zeroclaw default quadlet + ncz CLI)'

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    podman crun conmon netavark aardvark-dns catatonit librsvg2-bin whiptail \
    2>&1 | tail -3

# r187.2: pin the storage driver explicitly. Without this, podman's own
# postinst/first-probe during squashfs baking creates a stale
# /var/lib/containers/storage/overlay (leftover build-time state that ships
# baked into desktop.squashfs), and on real Sky1 hardware the FIRST live
# podman invocation (nclawzero-load-agent-images.service / any `ncz agent
# install`) auto-detects a different driver (vfs), landing both overlay/ and
# vfs/ in the same storage root -> "contains several valid graphdrivers"
# hard error, blocking every agent/mnemos install (observed on .66 r187: ncz
# install mnemos failed until `podman system reset --force`). Pin overlay
# explicitly so real hardware always agrees with whatever the bake left
# behind instead of auto-detecting a second, conflicting driver. No
# /etc/containers/storage.conf ships by default (containers-storage has no
# default file, only compiled-in defaults), so writing this is additive, not
# an override of existing operator config.
if [ ! -f /etc/containers/storage.conf ]; then
    mkdir -p /etc/containers
    cat > /etc/containers/storage.conf << 'STORAGECONF'
[storage]
driver = "overlay"
STORAGECONF
    echo "[30] pinned podman storage driver=overlay (/etc/containers/storage.conf)"
fi

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

# Remove only stale Portainer bootstrap units from older revs.
rm -f /etc/systemd/system/portainer-bootstrap.service \
      /etc/systemd/system/{default,multi-user}.target.wants/portainer-bootstrap.service

# r186: hermes networking is now baked into assets/agent-stack/hermes.container
# (Network=host + Exec `dashboard --host 127.0.0.1 ... --insecure`). The Cix
# Sky1 kernel has no veth/bridge (CONFIG_VETH off), so the old isolated-bridge +
# PublishPort model — and the r61/r74 seds that rewrote it — could not start on
# metal ("create veth pair: Operation not supported", status=126). --insecure +
# the loopback bind now ship in the template itself, so no in-place sed rewrite
# is needed. Assert the template carries the loopback + insecure model instead.
HERMES_TPL="$QUADLET_TEMPLATES/hermes.container"
if [ -f "$HERMES_TPL" ]; then
    grep -q -- "--host 127.0.0.1" "$HERMES_TPL" || echo "[30] WARN: hermes template not loopback-bound (--host 127.0.0.1 missing)"
    grep -q -- "--insecure"       "$HERMES_TPL" || echo "[30] WARN: hermes template missing --insecure"
    grep -q "^Network=host$"       "$HERMES_TPL" || echo "[30] WARN: hermes template not Network=host (will fail on Sky1 veth)"
    grep -q "^PublishPort="         "$HERMES_TPL" && echo "[30] WARN: hermes template still has PublishPort (fails on Sky1 veth)"
fi

# /etc/nclawzero/agent-env — fleet API keys. Always write .sample;
# only create live file if absent. Operator-set keys must NOT be clobbered.
groupadd -r nclawzero 2>/dev/null
mkdir -p /etc/nclawzero
cat > /etc/nclawzero/agent-env.sample << 'ENV'
# /etc/nclawzero/agent-env — fleet API keys for zeroclaw/openclaw/hermes/nemoclaw
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

# Agent image manifest + offline-only first-boot loader. Full/offline images
# may stage OCI tarballs under assets/agent-images; the loader pre-loads those
# so `ncz agent install` is instant. Netinstall images leave the tarballs
# absent and the loader does nothing at boot — the operator pulls on demand via
# `ncz agent install` (r124: no agent auto-pulls or auto-starts at boot).
mkdir -p "$IMAGE_DIR" /usr/local/sbin /etc/systemd/system
if [ -d /usr/local/lib/cix-installer/assets/agent-images ]; then
    cp -an /usr/local/lib/cix-installer/assets/agent-images/. "$IMAGE_DIR"/ 2>/dev/null || true
elif [ -d /cdrom/cixmini/assets/agent-images ]; then
    cp -an /cdrom/cixmini/assets/agent-images/. "$IMAGE_DIR"/ 2>/dev/null || true
fi

cat > /usr/share/ncz/agent-images.manifest << 'MANIFEST'
# Offline-staging manifest. NO agent is auto-installed or auto-started; this
# only tells the OFFLINE-ONLY boot loader which locally staged OCI tarballs to
# pre-load (full/offline ISO variants) so a later `ncz agent install` is
# instant. Netinstall ISOs ship no tarballs -> the loader is a no-op and the
# operator pulls on demand. All agents (incl. zeroclaw) are opt-in via
# `ncz agent install <name>` or `ncz install nemoclaw`.
#
# r186 offline/network-pull split (all images have a verified arm64 manifest):
#   OFFLINE-BUNDLED (small/core, staged as assets/agent-images/<name>.oci.tar):
#     zeroclaw  ghcr.io/zeroclaw-labs/zeroclaw:latest   (~109 MB)
#     mnemos    ghcr.io/ncz-os/mnemos:latest            (~260 MB, via `ncz install mnemos`)
#   NETWORK-PULL-ON-DEMAND (too large to bundle on the ISO — `ncz agent install`
#   pulls the published image while the operator is online):
#     openclaw  ghcr.io/openclaw/openclaw@sha256:06b4f3df...  (~756 MB)
#     hermes    docker.io/nousresearch/hermes-agent@sha256:aa60e748...  (~2.55 GB)
#     nemoclaw  ghcr.io/nvidia/nemoclaw/sandbox-base:latest   (~2.4 GB)
#     portainer docker.io/portainer/portainer-ce:lts          (installed via
#               direct `podman run`, not this loader)
# agent|image-ref|oci-tarball-under-/var/lib/nclawzero/agent-images
zeroclaw|ghcr.io/zeroclaw-labs/zeroclaw:latest|zeroclaw.oci.tar
MANIFEST
chmod 0644 /usr/share/ncz/agent-images.manifest

cat > /usr/local/sbin/nclawzero-load-agent-images << 'LOADSCRIPT'
#!/bin/bash
set -uo pipefail

MANIFEST=/usr/share/ncz/agent-images.manifest
IMAGE_DIR=/var/lib/nclawzero/agent-images
PODMAN=/usr/bin/podman
rc=0          # hard errors (podman/manifest/tarball-load) -> fail the unit

if [ ! -x "$PODMAN" ]; then
    echo "[agent-images] ERROR: podman missing"
    exit 1
fi
if [ ! -f "$MANIFEST" ]; then
    echo "[agent-images] ERROR: manifest missing: $MANIFEST"
    exit 1
fi

# r124: the boot loader is OFFLINE-ONLY. It loads locally staged OCI tarballs
# (full/offline ISO variants) so an operator can `ncz agent install` instantly
# with no network. It NEVER pulls from a registry at boot — that removes the
# boot-time network dependency that crash-looped a default-active agent on a
# fresh box whose DHCP/DNS wasn't up yet. On-demand registry pulls happen only
# in `ncz agent install <agent>`, where the operator is present and online.
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
        # No locally staged tarball (e.g. netinstall ISO). Do NOT pull at boot;
        # the operator installs on demand. This never touches the network and
        # never red-flags boot.
        echo "[agent-images] $agent: no local OCI tarball — install on demand with 'ncz agent install $agent'"
        continue
    fi

    if "$PODMAN" image exists "$image" 2>/dev/null; then
        echo "[agent-images] ready: $agent"
    else
        echo "[agent-images] WARN: $agent loaded/pulled but exact ref not found by podman image exists"
    fi
done < "$MANIFEST"

[ "$rc" -ne 0 ] && exit "$rc"
exit 0
LOADSCRIPT
chmod 0755 /usr/local/sbin/nclawzero-load-agent-images

cat > /etc/systemd/system/nclawzero-load-agent-images.service << 'UNIT'
[Unit]
Description=Load or pull NCZ agent container images
Documentation=man:podman-load(1) man:podman-pull(1)
Wants=network-online.target
After=network-online.target
ConditionPathExists=/var/lib/nclawzero/agent-images

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=/usr/local/sbin/nclawzero-load-agent-images
UNIT
chmod 0644 /etc/systemd/system/nclawzero-load-agent-images.service

cat > /etc/systemd/system/nclawzero-load-agent-images.timer << UNIT
[Unit]
Description=Timer for loading NCZ agent container images

[Timer]
OnBootSec=10
Unit=nclawzero-load-agent-images.service

[Install]
WantedBy=timers.target
UNIT
chmod 0644 /etc/systemd/system/nclawzero-load-agent-images.timer


# Named volumes are also created lazily by podman run, but pre-creating them
# makes the target state explicit for operator inspection.
for v in zeroclaw-data; do
    podman volume exists "$v" 2>/dev/null || podman volume create "$v" 2>/dev/null || true
done

# r124: NO agent auto-activates on first boot. ALL agents — including
# zeroclaw — are opt-in via `ncz agent install` (or the Install-NCZ-Agents
# desktop launcher). Rationale: a default-active quadlet with Pull=never +
# Restart=always crash-loops on a fresh box whose DHCP/DNS isn't up when the
# boot-time image pull races it (observed on MS-R1 r123: network-online.target
# fires before the link settles -> image-not-known 125 loop). Making every
# agent opt-in removes the boot-time network dependency entirely and keeps
# unreviewed container code from running with the fleet API keys in
# /etc/nclawzero/agent-env until an operator explicitly installs it.
mkdir -p "$QUADLET_ACTIVE"
if [ ! -e /var/lib/nclawzero/.agents-installed ]; then
    # Fresh install (or upgrade from an r<=123 default-active image): strip any
    # pre-placed active quadlet so nothing auto-starts. `ncz agent install`
    # re-places + starts them on demand.
    rm -f "$QUADLET_ACTIVE/zeroclaw.container" \
          "$QUADLET_ACTIVE/openclaw.container" \
          "$QUADLET_ACTIVE/hermes.container" \
          "$QUADLET_ACTIVE/hermes-isolated.network"
fi
systemctl daemon-reload 2>/dev/null || true

# r74: full ncz CLI with `agent install` subcommand (whiptail UI).
mkdir -p /usr/local/bin
cat > /usr/local/bin/ncz << 'NCZSCRIPT'
#!/bin/bash
# ncz — release-aware NCZ agent CLI
# Manages the optional agent stack (zeroclaw, openclaw, hermes, portainer).
# Quadlet templates live at /usr/share/ncz/quadlets/.
# Active quadlets get copied to /etc/containers/systemd/ on install.

set +e
NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="unknown"
NCZ_RELEASE_CODENAME=""
[ -s /etc/cix-installer/RELEASE ] && . /etc/cix-installer/RELEASE
NCZ_RELEASE_DISPLAY="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"
[ -n "$NCZ_RELEASE_CODENAME" ] && \
    NCZ_RELEASE_DISPLAY="$NCZ_RELEASE_DISPLAY \"$NCZ_RELEASE_CODENAME\""

QUADLET_TEMPLATES=/usr/share/ncz/quadlets
QUADLET_ACTIVE=/etc/containers/systemd
SENTINEL_DIR=/var/lib/nclawzero
AGENTS=(zeroclaw openclaw hermes)

# Image digests (pinned, fleet-canonical — must match Pi fleet quadlets)
declare -A AGENT_IMAGE
AGENT_IMAGE[zeroclaw]='ghcr.io/zeroclaw-labs/zeroclaw:latest'
AGENT_IMAGE[openclaw]='ghcr.io/openclaw/openclaw@sha256:06b4f3dfa3c88d49c92e99d635dc62053d4afd045d6220e811dff6190040f3de'
AGENT_IMAGE[hermes]='docker.io/nousresearch/hermes-agent@sha256:aa60e7483a6fad26eee233d2498d4f2b4223bf9d8990e3b07017f19b6ba7b6fe'
AGENT_IMAGE[portainer]='docker.io/portainer/portainer-ce:lts'

declare -A AGENT_DESC
AGENT_DESC[zeroclaw]='ZeroClaw daemon — gateway + agents (~109 MB)'
AGENT_DESC[openclaw]='OpenClaw upstream OSS (~756 MB)'
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

# r186: ensure_network() removed. hermes no longer uses a custom Podman bridge
# (hermes-isolated-v2) — the Cix Sky1 kernel has no veth/bridge (CONFIG_VETH
# off) so bridge creation fails on metal. hermes now runs Network=host with a
# 127.0.0.1 dashboard bind (see assets/agent-stack/hermes.container).

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
Exec=/usr/bin/chromium-ncz-sky1 http://127.0.0.1:$port/
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
            "zeroclaw"  "${AGENT_DESC[zeroclaw]}"  OFF \
            "openclaw"  "${AGENT_DESC[openclaw]}"  OFF \
            "hermes"    "${AGENT_DESC[hermes]}"    OFF \
            "portainer" "${AGENT_DESC[portainer]}" OFF \
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
        echo "no TTY and no agents specified — try: ncz agent install openclaw hermes"
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

    # r186: hermes needs NO custom network. It runs Network=host with a
    # 127.0.0.1 dashboard bind (Sky1 kernel has no veth/bridge — the old
    # hermes-isolated bridge could not be created on metal). Nothing to stage.

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
ncz — $NCZ_RELEASE_DISPLAY CLI

Agent management:
  ncz agent install [name...]      install agents (interactive if no args)
  ncz agent install --all          install zeroclaw/openclaw/hermes/portainer
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
    "version "*|"--version "*) echo "$NCZ_RELEASE_DISPLAY" ;;
    "help "*|"--help "*|"-h "*|" "|"") cmd_help ;;
    *) cmd_help; exit 2 ;;
esac
NCZSCRIPT
chmod 0755 /usr/local/bin/ncz
# 46-ncz-cli.sh installs the final unified `ncz` binary later in hook order.
# Preserve this richer agent-management implementation for that CLI to exec.
install -D -m 0755 /usr/local/bin/ncz /usr/local/lib/ncz-agent-cli

# r74: desktop launchers — ONLY install once-and-done items pre-staged.
# Agent launchers (ZeroClaw/OpenClaw/Hermes/Portainer) get written by
# `ncz agent install` AFTER the user opts in.
mkdir -p /etc/skel/Desktop
rm -rf /etc/skel/Desktop/Agents 2>/dev/null
# Defensive: remove any stale auto-placed agent launchers from r73 images
rm -f /etc/skel/Desktop/{ZeroClaw,OpenClaw,Hermes,Portainer}.desktop
rm -f /usr/share/applications/{ZeroClaw,OpenClaw,Hermes,Portainer}.desktop

# r181: combined agents + MNEMOS installer. The whiptail agent menu
# (`ncz agent install`) covers zeroclaw/openclaw/hermes/portainer; MNEMOS is a
# separate `ncz install mnemos`. The operator expects ONE headline "Install
# agents and mnemos" action, so this wrapper runs the agent picker then offers
# MNEMOS.
cat > /usr/local/bin/ncz-install-stack <<'STACK'
#!/bin/bash
# ncz-install-stack — headline first-run installer: AI agents + MNEMOS memory server.
echo "=============================================="
echo "  NCZ — install AI agents + MNEMOS"
echo "=============================================="
echo
echo "Step 1/2: AI agents (zeroclaw / openclaw / hermes / portainer)"
sudo ncz agent install
echo
echo "Step 2/2: MNEMOS memory server (:5002)"
if command -v whiptail >/dev/null 2>&1 && [ -t 0 ] \
   && whiptail --title "MNEMOS" --yesno \
        "Also install the MNEMOS memory server?\n\nInstalls OFFLINE from the image bundled on the ISO and starts it on :5002 (no network needed; falls back to a ghcr pull if the bundled image is absent)." 12 70; then
    sudo ncz install mnemos
else
    echo "Skipped MNEMOS. Install later with:  sudo ncz install mnemos"
fi
echo
echo "Done. You can re-run this any time from the desktop icon."
read -r -p "Press Enter to close this window..." _ || true
STACK
chmod 0755 /usr/local/bin/ncz-install-stack

# Headline first-run launcher — the most-prominent icon on a fresh desktop.
cat > /etc/skel/Desktop/Install-NCZ-Agents.desktop <<'IA'
[Desktop Entry]
Version=1.0
Type=Application
Name=⭐ Install AI Agents & MNEMOS
GenericName=AI agent + MNEMOS installer (zeroclaw / openclaw / hermes / portainer / mnemos)
Comment=Start here — pull + launch your AI agents and the MNEMOS memory server
Exec=foot -T "Install AI Agents and MNEMOS" /usr/local/bin/ncz-install-stack
Icon=ncz-rocket
Terminal=false
StartupNotify=true
Categories=System;Settings;Network;
IA
chmod 0755 /etc/skel/Desktop/Install-NCZ-Agents.desktop
cp /etc/skel/Desktop/Install-NCZ-Agents.desktop /usr/share/applications/

# r124: one-time first-login notice that points the user at the installer icon.
# Since no agent auto-starts anymore, a fresh desktop needs a nudge toward
# "Install AI Agents". Runs once per user (guarded by a marker), prefers a
# zenity dialog, falls back to a desktop notification, and self-disables.
cat > /usr/local/bin/ncz-first-login-notice << 'NOTICE'
#!/bin/bash
# Shown once on first XFCE login. Non-fatal; never blocks the session.
set -u
MARK="${HOME}/.config/ncz/.first-login-done"
[ -e "$MARK" ] && exit 0
mkdir -p "${HOME}/.config/ncz" 2>/dev/null

NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="unknown"
NCZ_RELEASE_CODENAME=""
[ -s /etc/cix-installer/RELEASE ] && . /etc/cix-installer/RELEASE
TITLE="Welcome to $NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION"
[ -n "$NCZ_RELEASE_CODENAME" ] && TITLE="$TITLE \"$NCZ_RELEASE_CODENAME\""
BODY="AI agents are opt-in on this system — nothing runs until you install it.

To get started, open the \"⭐ Install AI Agents\" icon on your Desktop (or run: sudo ncz agent install). It installs the ZeroClaw gateway and any optional agents (OpenClaw, Hermes, Portainer)."

# Give the desktop a moment to settle before popping UI.
sleep 8

if command -v zenity >/dev/null 2>&1; then
    zenity --info --no-wrap --title="$TITLE" \
           --ok-label="Got it" --text="$BODY" >/dev/null 2>&1
elif command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal -t 0 -i ncz-rocket "$TITLE" \
        "AI agents are opt-in. Open the \"⭐ Install AI Agents\" desktop icon (or run: sudo ncz agent install)."
elif command -v xmessage >/dev/null 2>&1; then
    xmessage -center "$TITLE

$BODY"
fi

# Mark done regardless of which path ran, so it never repeats.
touch "$MARK" 2>/dev/null
exit 0
NOTICE
chmod 0755 /usr/local/bin/ncz-first-login-notice

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/ncz-first-login.desktop << 'FLAUTOSTART'
[Desktop Entry]
Type=Application
Name=NCZ First-Login Notice
Comment=One-time welcome pointing to the AI agent installer
Exec=/usr/local/bin/ncz-first-login-notice
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=true
OnlyShowIn=Singularity;
FLAUTOSTART
chmod 0644 /etc/skel/.config/autostart/ncz-first-login.desktop

# NCZ-Help.md — quick reference doc (updated for r74 ncz CLI)
cat > /etc/skel/Desktop/NCZ-Help.md << 'HELP'
# @NCZ_RELEASE_DISPLAY@ — Quick Reference

## First-time setup (5 minutes)

The base image ships with **Claude Code**. Every agent — including
**zeroclaw** — is **opt-in**: nothing auto-starts on first boot, so a fresh
box has no boot-time network dependency. A one-time welcome notice on first
login points you to the installer. Install agents from the **⭐ Install AI
Agents** desktop icon, or the `ncz` CLI.

### 1. Install agents (interactive)

Double-click **⭐ Install AI Agents** on the Desktop, or run:

```
sudo ncz agent install
```

A checkbox menu appears. Pick the agents you want, hit Enter:

```
  [ ] zeroclaw    ZeroClaw daemon — gateway + agents (~109 MB)
  [ ] openclaw    OpenClaw upstream OSS (~756 MB)
  [ ] hermes      Hermes Agent — NousResearch (~2.55 GB, slowest)
  [ ] portainer   Container management web UI (~50 MB)
```

The image pulls (you're online and present), the quadlet activates, and the
service starts. A desktop launcher for each agent appears — click to open its
dashboard. Re-run **Install NCZ Agents** later to add more.

Install NVIDIA NemoClaw separately:

```
sudo ncz install nemoclaw
```

NemoClaw pulls about 2.4 GB from
`ghcr.io/nvidia/nemoclaw/sandbox-base:latest`, needs network, and runs
the sandbox-base + OpenShell runtime. Its OpenShell-gated inference
endpoint is `https://inference.local/v1`.

### Install MNEMOS (memory server)

MNEMOS is the memory operating system for agentic AI — a REST + MCP +
OpenAI-compatible memory server on port **5002**, sqlite-backed so your
memories survive reboots. Double-click **Install MNEMOS** on the Desktop,
or run:

```
sudo ncz install mnemos
```

This installs **OFFLINE** from the MNEMOS container image bundled on the
ISO — `ncz install mnemos` runs `podman load` on the local image at
`/var/lib/nclawzero/agent-images/mnemos.oci.tar` (or the staged
`/usr/local/lib/cix-installer/assets/agent-images/mnemos.oci.tar`), so
**no network is needed**. If no bundled image is found it falls back to
pulling `ghcr.io/ncz-os/mnemos:latest` (network required). It then stages
the `mnemos.container` quadlet, creates the persistent `mnemos-data`
volume, and starts `mnemos.service`.

Verify it's up:

```
systemctl status mnemos.service
curl -fsS http://127.0.0.1:5002/health
```

Endpoint: `http://<host>:5002` — REST `/v1/*`, MCP, and an
OpenAI-compatible gateway. Memories persist in the `mnemos-data` podman
volume (sqlite at `/data/mnemos.db`). The stock image embeds in-process
on CPU (nomic-embed-text-v1.5, 768-dim). On boards with a Zhouyi NPU,
`ncz install mnemos` offloads embedding to the on-device NPU embedder —
the same model at the same 768 dimensions, so it is a drop-in and needs
no re-embedding. Never repoint MNEMOS at an embedder of a different
width: nothing fails loudly, retrieval just stops returning the memories
already written.

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
NVIDIA_API_KEY=...
MISTRAL_API_KEY=...
```

Restart affected agents:

```
sudo ncz agent restart zeroclaw
```

## Non-interactive install (scripting)

```
sudo ncz agent install openclaw              # one optional agent
sudo ncz agent install openclaw portainer    # multiple optional agents
sudo ncz agent install --all                 # zeroclaw/openclaw/hermes/portainer
sudo ncz install nemoclaw                    # NVIDIA NemoClaw (~2.4 GB pull)
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
systemctl status nemoclaw.service
ncz version
ncz help
```

Opt-in via `ncz agent install`: **zeroclaw**, **openclaw**, **hermes**, **portainer**

Opt-in via `ncz install`: **mnemos** (memory server, :5002), **nemoclaw**

(No agent auto-starts on first boot — all are opt-in.)

## Web dashboards and endpoints

| Agent     | URL / endpoint                 | What                              |
|-----------|--------------------------------|-----------------------------------|
| zeroclaw  | http://127.0.0.1:42617/        | NCZ gateway daemon + web UI       |
| openclaw  | http://127.0.0.1:18789/        | OpenClaw                          |
| hermes    | http://127.0.0.1:8642/         | Hermes Agent (NousResearch)       |
| Portainer | http://127.0.0.1:9000/         | Container management              |
| mnemos    | http://127.0.0.1:5002/         | MNEMOS memory server (REST + MCP) |
| nemoclaw  | https://inference.local/v1     | OpenShell-gated inference API     |

## Uninstall

```
sudo ncz agent uninstall hermes      # one agent
sudo ncz agent uninstall --all       # everything
```

Stops + removes the container, deletes the quadlet, removes the desktop
launcher. Re-runnable.

## Image sources (pinned)

```
zeroclaw   ghcr.io/zeroclaw-labs/zeroclaw:latest      (official zeroclaw-labs gateway)
openclaw   ghcr.io/openclaw/openclaw@sha256:06b4f3df...
hermes     docker.io/nousresearch/hermes-agent@sha256:aa60e748...
portainer  docker.io/portainer/portainer-ce:lts
nemoclaw   ghcr.io/nvidia/nemoclaw/sandbox-base:latest
```

Quadlet templates: `/usr/share/ncz/quadlets/`
Active quadlets (after `ncz agent install`): `/etc/containers/systemd/`

## Model library

Embedding models ship in `/opt/ncz/models/` (no download needed):

```
ncz models              # list installed models (.cix NPU + .gguf CPU/GPU)
ncz models list         # same
ncz models pull         # fetch more from the Cix ai_model_hub (network)
```

| File                          | Format               | Adapter                          |
|-------------------------------|----------------------|----------------------------------|
| `bge-small-zh-v1.5_256.cix`   | Cix Compass NN INT8  | `npu-cix` (Zhouyi NPU, /dev/aipu)|
| `bge-small-zh-v1.5-q8_0.gguf` | llama.cpp Q8 GGUF    | `cpu-llamacpp` / `gpu-vulkan`    |

Model-library docs on this system:

```
/opt/ncz/models/MODELS-README.md          # what ships + how Engine.auto() picks
/usr/share/doc/ncz/MODELSCOPE-MODELS.md    # adding ModelScope / HuggingFace models
```

MNEMOS uses these automatically via `embedkit.Engine.auto()`, which
detects libnoe + /dev/aipu and selects the NPU `.cix` model.

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
sudo ncz install nemoclaw
```

By second login the system clock has resynced via NTP and the registry
TLS handshake succeeds.

## Brand

@NCZ_RELEASE_DISPLAY@  ·  Cix Sky1 / CP8180  ·  *Workloads. Not wallpapers.*

The configured NCZ release codename is the release name. Variants are Desktop and Server —
no per-revision codenames.
HELP
sed -i "s|@NCZ_RELEASE_DISPLAY@|$NCZ_RELEASE_DISPLAY|g" /etc/skel/Desktop/NCZ-Help.md
chmod 0644 /etc/skel/Desktop/NCZ-Help.md

# NCZ CLI desktop launcher
cat > /etc/skel/Desktop/NCZ-CLI.desktop << 'NCZCLI'
[Desktop Entry]
Version=1.0
Type=Application
Name=NCZ CLI
Comment=NCZ command-line — agents, NPU status (ncz help)
Exec=foot --hold -T NCZ /usr/local/bin/ncz help
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
Exec=foot -T ClaudeCode claude
Icon=utilities-terminal
Terminal=false
Categories=Development;
CC
chmod 0755 /etc/skel/Desktop/ClaudeCode.desktop

# r187.3: Zoder (Rust coding CLI). Always install from current master via
# the official installer (operator directive 2026-07-05) — never a prebuilt
# binary asset staged at build/bake time, which goes stale the moment
# upstream moves. The launcher still runs through a guarded wrapper so it
# degrades gracefully if the install is ever unavailable (no network during
# chroot install, upstream down, etc). zoder needs the operator's own
# config/API keys to run — that's their setup; we only wire the binary +
# launcher.
#
# GitLab, not the GitHub mirror: zoder ships rolling nightlies off master
# with no git tags/releases ever (confirmed 2026-07-05), so install.sh
# resolves the build from a fixed GitLab generic-package location
# (zoder-nightly/$CHANNEL), not the GitHub Releases API. GitHub's own repo
# is now explicitly a frozen mirror for zoder, and its raw.githubusercontent
# CDN also lagged behind a same-day install.sh fix by several minutes
# (edge-cache purge delay) -- fetch straight from GitLab to avoid both
# problems at once.
# zoder-review (2026-07-05): without pipefail, if curl fails silently
# (network hiccup, upstream unreachable) the piped `sh` gets empty stdin,
# runs nothing, and exits 0 -- the bare pipe exit code alone would report
# false success. Belt-and-suspenders: pipefail so a curl failure is visible
# in the pipeline's own exit status, PLUS verify the binary actually landed
# rather than trusting either command's exit status alone (this whole
# script runs under `set +e`, so pipefail changes failure visibility, not
# whether the script continues -- restore the prior setting after).
ZODER_INSTALL_URL=https://gitlab.com/ncz-os/zoder/-/raw/master/install.sh
set -o pipefail
curl -fsSL --max-time 60 "$ZODER_INSTALL_URL" | ZODER_BIN_DIR=/usr/local/bin sh
ZODER_PIPE_RC=$?
set +o pipefail
[ "$ZODER_PIPE_RC" -eq 0 ] || echo "[30] zoder install pipeline exited $ZODER_PIPE_RC (curl or install.sh failed)"
if [ -x /usr/local/bin/zoder ]; then
    echo "[30] zoder installed: $(/usr/local/bin/zoder --version 2>&1)"
else
    echo "[30] zoder install deferred (no network during chroot install, or upstream unreachable) — launcher will show a friendly notice"
fi
cat > /usr/local/bin/zoder-launch <<'ZL'
#!/bin/bash
# zoder-launch — run zoder TUI if installed, else a friendly notice.
if command -v zoder >/dev/null 2>&1; then
    exec zoder "$@"
fi
echo "Zoder is not installed yet."
echo
echo "The arm64-linux 'zoder' binary is pending. Once it is placed at"
echo "  /usr/local/bin/zoder   (chmod +x)"
echo "this launcher will start it. Zoder also needs your own config / API keys."
echo
read -r -p "Press Enter to close..." _ || true
ZL
chmod 0755 /usr/local/bin/zoder-launch

# r190.4: operator feedback (2026-07-05, .66 fresh-install validation) -- the
# icon launched zoder bare (no args), which just drops into an interactive
# TUI with no project/config context and looks like it "does nothing"; the
# desktop icon should point at the project's GitLab page instead, matching
# how a user actually gets started with zoder (install docs, config, keys).
cat > /etc/skel/Desktop/Zoder.desktop <<'ZD'
[Desktop Entry]
Version=1.0
Type=Link
Name=Zoder
GenericName=Zoder coding CLI
Comment=Zoder — Rust coding assistant CLI (project page)
URL=https://gitlab.com/ncz-os/zoder
Icon=web-browser
Categories=Development;
ZD
chmod 0755 /etc/skel/Desktop/Zoder.desktop

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

# ncz-rocket icon — MAGENTA NCZ rocket. r181: this icon is referenced by the
# "⭐ Install AI Agents & MNEMOS" and "NCZ CLI" launchers but was NEVER generated
# by any hook, so those launchers rendered with a BLANK icon on .66 (operator
# report). Generate it here (brand = magenta) so the launchers resolve a real
# icon.
cat > /tmp/ncz-agent-icons/ncz-rocket.svg << 'RSVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <linearGradient id="rbody" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ffd1ec"/><stop offset="45%" stop-color="#e0218a"/>
      <stop offset="100%" stop-color="#8a0f54"/>
    </linearGradient>
    <linearGradient id="rflame" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ff9ad6"/><stop offset="100%" stop-color="#ff2d95"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="#0a0a0a" rx="20"/>
  <path d="M 128 34 C 168 74 176 128 168 172 L 88 172 C 80 128 88 74 128 34 Z" fill="url(#rbody)"/>
  <circle cx="128" cy="98" r="20" fill="#12000a"/>
  <circle cx="128" cy="98" r="20" fill="none" stroke="#ff9ad6" stroke-width="2"/>
  <path d="M 88 150 L 60 188 L 88 172 Z" fill="#b3126b"/>
  <path d="M 168 150 L 196 188 L 168 172 Z" fill="#b3126b"/>
  <path d="M 112 172 L 128 226 L 144 172 Z" fill="url(#rflame)"/>
</svg>
RSVG

if command -v rsvg-convert >/dev/null 2>&1; then
    for icon in ncz-zeroclaw ncz-openclaw ncz-hermes ncz-rocket; do
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

# r181: the MNEMOS icon INSTALLS MNEMOS (was: opened the github page in a
# browser). `ncz install mnemos` pulls ghcr.io/ncz-os/mnemos + starts it as a
# podman quadlet (REST+MCP+OpenAI gateway on :5002). Needs podman (baked via
# manifests/desktop.pkgs + 30-agents apt-install) + network for the image pull.
cat > /etc/skel/Desktop/MNEMOS.desktop << 'MN'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install MNEMOS
GenericName=MNEMOS memory server installer
Comment=Pull + start the MNEMOS memory server (REST + MCP + OpenAI gateway on :5002)
Exec=foot --hold -T "Install MNEMOS" bash -c "sudo ncz install mnemos"
Icon=applications-science
Terminal=false
StartupNotify=true
Categories=System;Development;Network;
MN
chmod 0755 /etc/skel/Desktop/MNEMOS.desktop

# Separate docs link (github) — kept as a secondary, clearly-labelled icon.
cat > /etc/skel/Desktop/MNEMOS-Docs.desktop << 'MND'
[Desktop Entry]
Version=1.0
Type=Application
Name=MNEMOS Docs
Comment=MNEMOS — hybrid memory stack for AI agents (github)
Exec=/usr/bin/chromium-ncz-sky1 https://github.com/mnemos-os/mnemos
Icon=applications-science
Terminal=false
Categories=Development;Network;
MND
chmod 0755 /etc/skel/Desktop/MNEMOS-Docs.desktop

# Mirror to /usr/share/applications so they show in Whisker / app menu
cp /etc/skel/Desktop/*.desktop /usr/share/applications/ 2>/dev/null
chmod 0644 /usr/share/applications/*.desktop 2>/dev/null
update-desktop-database 2>&1 | tail -1

# r188: xfdesktop 4.20 refuses to launch a ~/Desktop .desktop file unless gvfs
# metadata::xfce-exe-checksum equals the file's own sha256 -- otherwise every
# icon prompts "Untrusted application launcher" on first click. gio launch
# (used to smoke-test these icons) bypasses this gate entirely, which is why
# the prompt wasn't caught earlier -- confirmed via a real xdotool double-click
# reproducing the operator's exact error (2026-07-05). Pre-seed trust at every
# XFCE session start so a fresh user never sees the prompt; also covers
# per-agent dashboard launchers create_launcher() adds later, and re-seeds
# after any .desktop is rewritten in place (e.g. this hook's own re-runs).
cat > /usr/local/bin/ncz-trust-desktop-icons <<'TRUSTSH'
#!/bin/bash
# Mark every ~/Desktop/*.desktop file as trusted for xfdesktop 4.20+, which
# gates launch on gvfs metadata::xfce-exe-checksum == sha256(file).
for f in "$HOME/Desktop"/*.desktop; do
    [ -f "$f" ] || continue
    sum=$(sha256sum "$f" | cut -d' ' -f1)
    gio set "$f" metadata::xfce-exe-checksum "$sum" 2>/dev/null
done
TRUSTSH
chmod 0755 /usr/local/bin/ncz-trust-desktop-icons

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ncz-trust-desktop-icons.desktop <<'AUTO'
[Desktop Entry]
Type=Application
Name=NCZ Desktop Icon Trust Seeder
Exec=/usr/local/bin/ncz-trust-desktop-icons
NoDisplay=true
X-XFCE-Autostart-enabled=true
OnlyShowIn=Singularity;
StartupNotify=false
Terminal=false
AUTO

# r74: ensure podman.socket is enabled so portainer can talk to it
# AFTER the operator runs `ncz agent install portainer`.
systemctl enable podman.socket 2>/dev/null

# Offline-only image loader: pre-loads locally staged OCI tarballs at boot
# (full/offline ISOs) so `ncz agent install` is instant. No-op on netinstall.
systemctl enable nclawzero-load-agent-images.service 2>/dev/null || true

# disable cix-npu-driver-dkms — we ship FyrbyAdditive prebuilt .ko at
# /usr/lib/modules/<KVER>/extra/armchina_npu.ko (handled by 80-npu.sh).
systemctl mask dkms.service 2>&1 | tail -1
rm -rf /var/lib/dkms/aipu /var/lib/dkms/cix-vpu-driver 2>/dev/null
echo '[30] dkms.service masked (FyrbyAdditive prebuilt .ko ships at /usr/lib/modules/<KVER>/extra/)'

echo '[30] agent stack: ALL agents opt-in (no auto-start on first boot)'
echo '     templates at /usr/share/ncz/quadlets/; install via `ncz agent install` or the Install-NCZ-Agents desktop icon'
echo '     active units land in /etc/containers/systemd/ after install'
