#!/bin/bash
# 46-ncz-cli.sh — install /usr/local/bin/ncz + /opt/cix/npu_embed_v2.py.
#
# r75 P5/P7 (#115/#99): foundational `ncz` command with subcommands:
#   * desktop {on,off,status}      — graphical/multi-user toggle (P5)
#   * models pull                  — fetch cixtech/ai_model_hub_25_Q3 LFS
#   * install mnemos               — pull + start MNEMOS memory server (:5002)
#   * install nemoclaw             — pull + start NVIDIA NemoClaw runtime
#   * version, help
#
# `models pull` remains a STUB (see task #99). `install mnemos` is now
# implemented: it pulls ghcr.io/ncz-os/mnemos (overridable via MNEMOS_IMAGE)
# and starts it as a quadlet service with a persistent sqlite volume. Like
# NemoClaw, the image is pulled on demand (not bundled in the ISO).
#
# Also stages the canonical npu_embed_v2.py wrapper (Python ctypes around
# libnoe.so) to /opt/cix/npu_embed_v2.py so users can invoke it directly
# once they fetch the .cix model. Wrapper is small (~8KB) and lives
# alongside the FyrbyAdditive aipu kernel module.
#
# Why bash not Rust: see prior comment block. Rust port comes when the
# CLI surface stabilizes.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

echo "[46] installing ncz CLI + /opt/cix/npu_embed_v2.py"

# Stage the canonical Python NPU wrapper from cix-installer/assets/npu/
NPU_WRAPPER_SRC=/cdrom/cixmini/assets/cix-py/npu_embed_v2.py
if [ -f "$NPU_WRAPPER_SRC" ]; then
    install -D -m 0644 "$NPU_WRAPPER_SRC" /opt/cix/npu_embed_v2.py
    echo "    /opt/cix/npu_embed_v2.py staged ($(wc -l < /opt/cix/npu_embed_v2.py) lines)"
else
    echo "    WARN: $NPU_WRAPPER_SRC not in cdrom payload — /opt/cix/npu_embed_v2.py NOT staged" >&2
fi

install -D -m 0755 /dev/stdin /usr/local/bin/ncz <<'NCZ'
#!/bin/bash
# ncz — nclawzero operator CLI.
# Subcommands:
#   desktop {on|off|status}  — graphical/multi-user toggle
#   models pull              — fetch cixtech/ai_model_hub_25_Q3 LFS to /opt/ncz/models
#   install mnemos           — pull + start MNEMOS memory server (:5002, sqlite)
#   install nemoclaw         — pull + start NVIDIA NemoClaw runtime
#   version, help
set -euo pipefail

readonly NCZ_VERSION="0.2.0"
readonly NCZ_MODELS_DIR="/opt/ncz/models"
readonly NCZ_CIX_LIB_DIR="/opt/cix"
readonly NCZ_AGENT_HELPER="/usr/local/lib/ncz-agent-cli"
readonly NCZ_QUADLET_TEMPLATES="/usr/share/ncz/quadlets"
readonly NCZ_QUADLET_ACTIVE="/etc/containers/systemd"
readonly NEMOCLAW_IMAGE="ghcr.io/nvidia/nemoclaw/sandbox-base:latest"
# MNEMOS server image. Overridable (e.g. pin a tag) via the MNEMOS_IMAGE env.
# Multi-arch (linux/arm64 present) — runs on Cix Sky1.
readonly MNEMOS_IMAGE="${MNEMOS_IMAGE:-ghcr.io/ncz-os/mnemos:latest}"

ncz_help() {
    cat <<HELP
ncz — nclawzero operator CLI ($NCZ_VERSION)

Usage: ncz <subcommand> [args]

Subcommands:
  desktop on            Enable graphical login (set-default graphical.target,
                        start the configured display manager).
  desktop off           Drop to multi-user (headless) mode. SSH/network stays up.
                        Reversible with 'ncz desktop on'.
  desktop status        Show current default target + display-manager state.
  models pull           Fetch cixtech/ai_model_hub_25_Q3 LFS to $NCZ_MODELS_DIR
                        (STUB in r75 — see task #99).
  install mnemos        Pull + start the MNEMOS memory server (REST + MCP +
                        OpenAI-compatible gateway on :5002, sqlite-backed).
  install nemoclaw      Pull + start NVIDIA NemoClaw OpenShell sandbox runtime.
  agent ...             Manage zeroclaw/openclaw/hermes/portainer agents.
  status                Print system summary: ncz version, BUILD_VARIANT,
                        kernel, default-target, NPU + GPU presence.
  version               Print version.
  help                  Show this help.

For server-class deploys (Magnetar SKU), 'ncz desktop off' is the
canonical post-install step. Reinhardt SKU ships graphical-by-default.
HELP
}

# --- agent subcommand ----------------------------------------------------

ncz_agent() {
    if [ -x "$NCZ_AGENT_HELPER" ]; then
        exec "$NCZ_AGENT_HELPER" agent "$@"
    fi
    echo "ncz agent: helper missing: $NCZ_AGENT_HELPER" >&2
    echo "This system did not preserve the agent installer from 30-agents.sh." >&2
    exit 1
}

# --- desktop subcommand --------------------------------------------------

ncz_dm_unit() {
    for u in lightdm.service gdm3.service gdm.service sddm.service; do
        if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
            echo "$u"
            return 0
        fi
    done
    return 1
}

ncz_desktop_status() {
    local target dm
    target=$(systemctl get-default 2>/dev/null || echo unknown)
    echo "default-target: $target"
    if dm=$(ncz_dm_unit); then
        echo "display-manager: $dm ($(systemctl is-active "$dm" 2>/dev/null || echo unknown))"
    else
        echo "display-manager: (none installed)"
    fi
}

ncz_desktop_on() {
    if ! [ "$(id -u)" = "0" ]; then echo "ncz desktop on: requires root (use sudo)" >&2; exit 1; fi
    echo "[ncz] desktop ON"
    systemctl set-default graphical.target
    if dm=$(ncz_dm_unit); then
        # r75 Codex MED fix: 48-magnetar-variant.sh masks DM units in the
        # server variant. systemctl enable fails under set -e on a masked
        # unit, so always unmask first. Unmask is a no-op on unmasked
        # units, so this is safe in the desktop-already-active case too.
        systemctl unmask "$dm" 2>&1 | sed 's/^/  /' || true
        systemctl enable "$dm"
        systemctl start "$dm"
        echo "[ncz] $dm unmasked + enabled + started"
    else
        echo "[ncz] no display-manager unit installed; graphical.target set anyway."
        echo "      install one (lightdm/gdm3/sddm) and re-run 'ncz desktop on'."
    fi
}

ncz_desktop_off() {
    if ! [ "$(id -u)" = "0" ]; then echo "ncz desktop off: requires root (use sudo)" >&2; exit 1; fi
    echo "[ncz] desktop OFF (headless mode — SSH stays up)"
    systemctl set-default multi-user.target
    if dm=$(ncz_dm_unit); then
        systemctl disable "$dm" 2>&1 | sed 's/^/  /' || true
        systemctl stop "$dm" 2>&1 | sed 's/^/  /' || true
        echo "[ncz] $dm disabled+stopped"
    fi
    echo "[ncz] system will boot to text-mode tty1 next time."
}

ncz_desktop() {
    local action="${1:-status}"
    case "$action" in
        on)     ncz_desktop_on ;;
        off)    ncz_desktop_off ;;
        status) ncz_desktop_status ;;
        *)
            echo "ncz desktop: unknown action '$action' (expected on|off|status)" >&2
            exit 1
            ;;
    esac
}

# --- models subcommand ---------------------------------------------------

ncz_models() {
    local action="${1:-help}"
    case "$action" in
        pull)
            cat >&2 <<MSG
ncz models pull — STUB (r75)

Will fetch the Cix .cix model bundle to:
    $NCZ_MODELS_DIR/  (incl. bge-small-zh_256.cix and tokenizer)

Source: cixtech/ai_model_hub on GitHub (Q3 2025 LFS bundle).
Body deferred to r76. See task #99.

For now, bootstrap manually:
    sudo mkdir -p $NCZ_MODELS_DIR
    cd $NCZ_MODELS_DIR
    sudo git clone https://github.com/cixtech/ai_model_hub.git
    cd ai_model_hub && sudo git lfs pull
MSG
            exit 2
            ;;
        list)
            if [ -d "$NCZ_MODELS_DIR" ]; then
                find "$NCZ_MODELS_DIR" -maxdepth 3 -name '*.cix' 2>/dev/null
            else
                echo "(no models — $NCZ_MODELS_DIR does not exist)"
            fi
            ;;
        *)
            echo "ncz models: unknown action '$action' (expected pull|list)" >&2
            exit 1
            ;;
    esac
}

# --- install subcommand --------------------------------------------------

ncz_install_nemoclaw() {
    if ! [ "$(id -u)" = "0" ]; then
        echo "ncz install nemoclaw: requires root (use sudo)" >&2
        exit 1
    fi
    if ! command -v podman >/dev/null 2>&1; then
        echo "ncz install nemoclaw: podman is not installed" >&2
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "ncz install nemoclaw: systemctl is not available" >&2
        exit 1
    fi

    local template="$NCZ_QUADLET_TEMPLATES/nemoclaw.container"
    local active="$NCZ_QUADLET_ACTIVE/nemoclaw.container"
    if [ ! -f "$template" ]; then
        echo "ncz install nemoclaw: missing quadlet template: $template" >&2
        exit 1
    fi

    echo "[ncz] installing NemoClaw"
    echo "[ncz] pulling $NEMOCLAW_IMAGE (about 2.4 GB compressed; network required)"
    if ! podman pull "$NEMOCLAW_IMAGE"; then
        echo "ncz install nemoclaw: podman pull failed" >&2
        exit 1
    fi

    mkdir -p "$NCZ_QUADLET_ACTIVE"
    podman volume exists nemoclaw-data 2>/dev/null || podman volume create nemoclaw-data >/dev/null

    if [ -f "$active" ]; then
        echo "[ncz] active quadlet already exists; preserving $active"
    else
        install -m 0644 "$template" "$active"
        echo "[ncz] staged $active"
    fi

    systemctl daemon-reload
    systemctl start nemoclaw.service

    echo "[ncz] NemoClaw started."
    echo "[ncz] OpenShell-gated inference endpoint: https://inference.local/v1"
    echo "[ncz] Service: systemctl status nemoclaw.service"
}

ncz_install_mnemos() {
    if ! [ "$(id -u)" = "0" ]; then
        echo "ncz install mnemos: requires root (use sudo)" >&2
        exit 1
    fi
    if ! command -v podman >/dev/null 2>&1; then
        echo "ncz install mnemos: podman is not installed" >&2
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "ncz install mnemos: systemctl is not available" >&2
        exit 1
    fi

    local template="$NCZ_QUADLET_TEMPLATES/mnemos.container"
    local active="$NCZ_QUADLET_ACTIVE/mnemos.container"
    if [ ! -f "$template" ]; then
        echo "ncz install mnemos: missing quadlet template: $template" >&2
        exit 1
    fi

    echo "[ncz] installing MNEMOS"
    echo "[ncz] pulling $MNEMOS_IMAGE (multi-arch; arm64; network required)"
    if ! podman pull "$MNEMOS_IMAGE"; then
        echo "ncz install mnemos: podman pull failed" >&2
        exit 1
    fi

    mkdir -p "$NCZ_QUADLET_ACTIVE"
    podman volume exists mnemos-data 2>/dev/null || podman volume create mnemos-data >/dev/null

    if [ -f "$active" ]; then
        echo "[ncz] active quadlet already exists; preserving $active"
    else
        install -m 0644 "$template" "$active"
        # Keep the running image in sync with what we just pulled (honours a
        # MNEMOS_IMAGE override so the quadlet never points at a stale tag).
        sed -i "s|^Image=.*|Image=$MNEMOS_IMAGE|" "$active"
        echo "[ncz] staged $active (Image=$MNEMOS_IMAGE)"
    fi

    systemctl daemon-reload
    systemctl start mnemos.service

    echo "[ncz] MNEMOS started."
    echo "[ncz]   endpoint: http://<host>:5002  (REST /v1/*, MCP, OpenAI-compatible gateway)"
    echo "[ncz]   health:   curl -fsS http://127.0.0.1:5002/health"
    echo "[ncz]   data:     volume mnemos-data (sqlite at /data/mnemos.db, persistent)"
    echo "[ncz]   embedder: in-process CPU (nomic-embed-text-v1.5, 768-dim)"
    echo "[ncz]   service:  systemctl status mnemos.service"
    echo "[ncz] NOTE: Cix NPU embedding offload is not enabled by this command —"
    echo "[ncz]       the stock image has no libnoe/transformers/.cix. It needs a"
    echo "[ncz]       purpose-built image (those baked in) + /dev/aipu passthrough."
}

ncz_install() {
    local component="${1:-help}"
    case "$component" in
        help|--help|-h)
            cat <<MSG
Usage: ncz install <component>

Components:
  mnemos     Pull + start the MNEMOS memory server (REST + MCP + OpenAI-compatible
             gateway on :5002, sqlite-backed, in-process CPU embedder)
  nemoclaw   Pull + start NVIDIA NemoClaw OpenShell sandbox runtime
MSG
            ;;
        mnemos)
            ncz_install_mnemos
            ;;
        nemoclaw)
            ncz_install_nemoclaw
            ;;
        *)
            echo "ncz install: unknown component '$component' (expected: mnemos | nemoclaw)" >&2
            exit 1
            ;;
    esac
}

# --- status subcommand ---------------------------------------------------

ncz_status() {
    local sidecar=/usr/local/lib/cix-installer/BUILD_VARIANT
    local variant=desktop
    [ -f "$sidecar" ] && variant="$(tr -d ' \t\r\n' < "$sidecar")"
    local target
    target="$(systemctl get-default 2>/dev/null || echo unknown)"
    local kver
    kver="$(uname -r 2>/dev/null || echo unknown)"
    local hostname
    hostname="$(hostname 2>/dev/null || echo unknown)"

    printf '%-26s %s\n' 'ncz:' "$NCZ_VERSION"
    printf '%-26s %s\n' 'hostname:' "$hostname"
    printf '%-26s %s\n' 'kernel:' "$kver"
    printf '%-26s %s\n' 'BUILD_VARIANT:' "$variant"
    printf '%-26s %s\n' 'default-target:' "$target"
    # NPU device node. The armchina/Zhouyi driver exposes /dev/aipu (no
    # numeric suffix) on the cix-sky1 kernels; older names are checked too.
    local npu_node=""
    for n in /dev/aipu /dev/aipu0 /dev/cix-noe0; do
        [ -e "$n" ] && { npu_node="$n"; break; }
    done
    if [ -n "$npu_node" ]; then
        local npu_drv="absent"
        [ -e /sys/bus/platform/drivers/armchina ] && npu_drv="armchina bound"
        printf '%-26s %s\n' 'NPU:' "present ($npu_node, $npu_drv)"
    else
        printf '%-26s %s\n' 'NPU:' "absent"
    fi
    if [ -e /dev/dri/renderD128 ]; then
        printf '%-26s %s\n' 'GPU /dev/dri/renderD128:' "present"
        if command -v vulkaninfo >/dev/null 2>&1; then
            local devs
            devs="$(vulkaninfo --summary 2>/dev/null | awk -F: '/deviceName/ {gsub(/^ +/, "", $2); print $2}' | head -3 | paste -sd, -)"
            [ -n "$devs" ] && printf '%-26s %s\n' 'Vulkan devices:' "$devs"
        fi
    else
        printf '%-26s %s\n' 'GPU /dev/dri/renderD128:' "absent"
    fi
    if [ -d /opt/ncz/models ]; then
        local nmodels
        nmodels="$(find /opt/ncz/models -name '*.cix' 2>/dev/null | wc -l | tr -d ' ')"
        printf '%-26s %s .cix files in /opt/ncz/models\n' 'models:' "$nmodels"
    fi
}

# --- main dispatch -------------------------------------------------------

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        agent)          ncz_agent "$@" ;;
        desktop)        ncz_desktop "$@" ;;
        models)         ncz_models  "$@" ;;
        install)        ncz_install "$@" ;;
        status)         ncz_status ;;
        version|--version|-V) echo "ncz $NCZ_VERSION" ;;
        help|--help|-h) ncz_help ;;
        '')             ncz_help ;;
        *)
            echo "ncz: unknown subcommand '$cmd'" >&2
            echo "Run 'ncz help' for usage." >&2
            exit 1
            ;;
    esac
}

main "$@"
NCZ

# Verify the installed CLI parses + responds to help.
if ! /usr/local/bin/ncz help >/dev/null 2>&1; then
    echo "[46] ERROR: ncz CLI failed self-check (ncz help)"
    /usr/local/bin/ncz help 2>&1 || true
    exit 1
fi

echo "[46] ncz CLI installed at /usr/local/bin/ncz"
/usr/local/bin/ncz version
