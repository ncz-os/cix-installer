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
# `models pull` remains a STUB (see task #99). `install mnemos` is
# implemented + OFFLINE-CAPABLE: it `podman load`s the arm64 MNEMOS image
# bundled on the ISO (assets/agent-images/mnemos.oci.tar), then starts it as
# a quadlet service (Pull=never) with a persistent sqlite volume. Only if no
# bundled image is present does it fall back to pulling ghcr.io/ncz-os/mnemos
# (overridable via MNEMOS_IMAGE). `models` lists the installed model library.
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

# Stage the canonical Python NPU wrapper. Baked images stage it at
# assets/cix-py/ (build-squashfs-layers.sh); a plain install-media chroot
# still has /cdrom, so check both.
NPU_WRAPPER_SRC=/usr/local/lib/cix-installer/assets/cix-py/npu_embed_v2.py
[ -f "$NPU_WRAPPER_SRC" ] || NPU_WRAPPER_SRC=/cdrom/cixmini/assets/cix-py/npu_embed_v2.py
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
  models [list]         List the embedding models installed in $NCZ_MODELS_DIR
                        (.cix NPU + .gguf CPU/GPU). Docs:
                        $NCZ_MODELS_DIR/MODELS-README.md and
                        /usr/share/doc/ncz/MODELSCOPE-MODELS.md.
  models pull           Fetch cixtech/ai_model_hub_25_Q3 LFS to $NCZ_MODELS_DIR
                        (STUB in r75 — see task #99).
  install mnemos        Install + start the MNEMOS memory server (REST + MCP +
                        OpenAI-compatible gateway on :5002, sqlite-backed).
                        Loads the bundled image OFFLINE (no network); falls
                        back to a ghcr pull only if no bundled image is found.
  install nemoclaw      Pull + start NVIDIA NemoClaw OpenShell sandbox runtime.
  agent ...             Manage zeroclaw/openclaw/hermes/portainer agents.
  status                Print system summary: ncz version, BUILD_VARIANT,
                        kernel, default-target, NPU + GPU presence.
  version               Print version.
  help                  Show this help.

For server-class deploys (Server SKU), 'ncz desktop off' is the
canonical post-install step. Desktop SKU ships graphical-by-default.
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
        # r75 Codex MED fix: 48-server-variant.sh masks DM units in the
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
    # Bare `ncz models` lists the installed model library (most useful default).
    local action="${1:-list}"
    case "$action" in
        list|ls|"")
            if [ ! -d "$NCZ_MODELS_DIR" ]; then
                echo "(no models — $NCZ_MODELS_DIR does not exist; run 'ncz models pull' or install MNEMOS)"
                return 0
            fi
            echo "Model library: $NCZ_MODELS_DIR"
            local found=0
            # NPU (.cix) + CPU/GPU (.gguf) embedding models.
            while IFS= read -r m; do
                [ -n "$m" ] || continue
                found=1
                local sz; sz="$(du -h "$m" 2>/dev/null | cut -f1)"
                case "$m" in
                    *.cix)  printf '  %-34s %6s  NPU  (npu-cix / Zhouyi, /dev/aipu)\n' "$(basename "$m")" "$sz" ;;
                    *.gguf) printf '  %-34s %6s  CPU/GPU (llama.cpp / Vulkan)\n' "$(basename "$m")" "$sz" ;;
                esac
            done < <(find "$NCZ_MODELS_DIR" -maxdepth 3 -type f \( -name '*.cix' -o -name '*.gguf' \) 2>/dev/null | sort)
            # Tokenizer dirs (config.json alongside tokenizer.json/vocab).
            while IFS= read -r t; do
                [ -n "$t" ] || continue
                found=1
                printf '  %-34s %6s  tokenizer (offline BERT WordPiece)\n' "$(basename "$(dirname "$t")")/" "-"
            done < <(find "$NCZ_MODELS_DIR" -maxdepth 3 -name 'tokenizer_config.json' 2>/dev/null | sort)
            [ "$found" = 0 ] && echo "  (none installed yet — run 'ncz models pull')"
            echo
            echo "Docs: $NCZ_MODELS_DIR/MODELS-README.md"
            [ -f /usr/share/doc/ncz/MODELSCOPE-MODELS.md ] && \
                echo "      /usr/share/doc/ncz/MODELSCOPE-MODELS.md  (adding ModelScope/HuggingFace models)"
            return 0
            ;;
        help|--help|-h)
            cat <<MSG
Usage: ncz models [list|pull]

  list   (default) Show embedding models installed in $NCZ_MODELS_DIR:
         .cix (NPU / Zhouyi) + .gguf (CPU/GPU llama.cpp) + tokenizers.
  pull   Fetch the Cix ai_model_hub_25_Q3 LFS bundle (network; STUB, task #99).

Docs: $NCZ_MODELS_DIR/MODELS-README.md,
      /usr/share/doc/ncz/MODELSCOPE-MODELS.md
MSG
            ;;
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
        *)
            echo "ncz models: unknown action '$action' (expected list|pull)" >&2
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

# Bring up the on-device NPU embedder and PROVE it is interchangeable with the
# embedder MNEMOS would otherwise use in-process.
#
# The whole point is that this is a drop-in: the server runs
# nomic-embed-text-v1.5 at 768 dimensions, which is exactly MNEMOS's default
# (MNEMOS_EMBEDDING_DIM defaults to 768 and the stock image embeds with the same
# model). So switching to it does not restate the vector space and needs no
# migration -- measured cosine 0.9953 against the onnxruntime CPU reference.
#
# That property is also the thing that must never be assumed. An embedder of a
# different width silently strands every memory already written -- nothing
# fails loudly, retrieval just stops returning anything -- so this function
# REFUSES to wire anything up unless the running service actually returns a
# 768-wide vector. Returns 0 only when the embedder is up and verified.
ncz_npu_embedder_ready() {
    local url="http://127.0.0.1:8081/v1"
    [ -e /dev/aipu ] || { echo "[ncz] no /dev/aipu — NPU embedder not applicable"; return 1; }
    [ -x /opt/ncz/noe-venv/bin/python ] || { echo "[ncz] NPU embedder venv missing (/opt/ncz/noe-venv)"; return 1; }
    [ -f /opt/ncz/models/nomic-embed-text-v1.5_256.cix ] || {
        echo "[ncz] NPU graph missing: /opt/ncz/models/nomic-embed-text-v1.5_256.cix"; return 1; }
    [ -f /etc/systemd/system/ncz-npu-embed.service ] || {
        echo "[ncz] ncz-npu-embed.service not installed"; return 1; }

    systemctl enable --now ncz-npu-embed.service >/dev/null 2>&1 || true
    # Graph load is ~15s; the unit allows 120s, so poll rather than guess.
    local i
    for i in $(seq 1 40); do
        curl -fsS -m 3 "$url/models" >/dev/null 2>&1 && break
        sleep 3
    done
    if ! curl -fsS -m 3 "$url/models" >/dev/null 2>&1; then
        echo "[ncz] NPU embedder did not come up on :8081 — leaving MNEMOS on its CPU embedder"
        return 1
    fi

    # HARD GATE: a live request must return exactly 768 floats. Anything else
    # means a different model is loaded and wiring MNEMOS to it would corrupt
    # retrieval rather than fail loudly.
    local dim
    dim=$(curl -fsS -m 20 "$url/embeddings" -H 'Content-Type: application/json' \
            -d '{"model":"nomic-embed-text","input":"dimension probe"}' 2>/dev/null \
          | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null)
    if [ "$dim" != "768" ]; then
        echo "[ncz] NPU embedder returned dim='${dim:-none}', expected 768 — NOT wiring MNEMOS to it"
        return 1
    fi
    echo "[ncz] NPU embedder verified on :8081 (nomic-embed-text, 768-dim)"
    return 0
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
    # OFFLINE-FIRST image acquisition. The ISO bundles the arm64 MNEMOS image as
    # an OCI archive (assets/agent-images/mnemos.oci.tar, ~260 MB); load it
    # locally so `ncz install mnemos` works with NO network. Only if no bundled
    # image is present (e.g. a netinstall ISO) do we fall back to a registry
    # pull. The quadlet uses Pull=never, so the image MUST exist locally before
    # the service starts.
    if podman image exists "$MNEMOS_IMAGE" 2>/dev/null; then
        echo "[ncz] image already present: $MNEMOS_IMAGE"
    else
        local mnemos_loaded=0 mnemos_tar
        for mnemos_tar in \
            /var/lib/nclawzero/agent-images/mnemos.oci.tar \
            /usr/local/lib/cix-installer/assets/agent-images/mnemos.oci.tar \
            /cdrom/cixmini/assets/agent-images/mnemos.oci.tar; do
            [ -f "$mnemos_tar" ] || continue
            echo "[ncz] loading bundled MNEMOS image OFFLINE from $mnemos_tar"
            if podman load -i "$mnemos_tar"; then mnemos_loaded=1; break; fi
            echo "[ncz] WARN: podman load failed for $mnemos_tar — trying next source"
        done
        if [ "$mnemos_loaded" != 1 ]; then
            echo "[ncz] no bundled image found — falling back to network pull of $MNEMOS_IMAGE"
            if ! podman pull "$MNEMOS_IMAGE"; then
                echo "ncz install mnemos: no bundled image AND podman pull failed (offline?)" >&2
                echo "  expected bundled image at /var/lib/nclawzero/agent-images/mnemos.oci.tar" >&2
                exit 1
            fi
        fi
        # The bundled archive is tagged ghcr.io/ncz-os/mnemos:latest. If the
        # operator overrode MNEMOS_IMAGE to a different tag, retag the loaded
        # image so the Pull=never quadlet (Image=$MNEMOS_IMAGE) can resolve it.
        if ! podman image exists "$MNEMOS_IMAGE" 2>/dev/null \
           && podman image exists ghcr.io/ncz-os/mnemos:latest 2>/dev/null; then
            podman tag ghcr.io/ncz-os/mnemos:latest "$MNEMOS_IMAGE" 2>/dev/null || true
        fi
    fi
    if ! podman image exists "$MNEMOS_IMAGE" 2>/dev/null; then
        echo "ncz install mnemos: image $MNEMOS_IMAGE unavailable after load/pull" >&2
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

    # Offload embeddings to the NPU when this board can actually do it. The env
    # contract is MNEMOS's own (mnemos/core/config.py): MNEMOS_EMBED_BACKEND=http
    # selects the HTTP embedder, MNEMOS_EMBED_HTTP_URL is the full
    # /v1/embeddings path (not a base URL), and MNEMOS_EMBEDDING_DIM MUST equal
    # the embedder's width -- note it is NOT MNEMOS_DATABASE_EMBEDDING_DIM,
    # which MNEMOS does not read and which fails later as a vector cast error.
    # The quadlet is Network=host, so 127.0.0.1 reaches the host service.
    # Written before first start so MNEMOS never embeds a single memory on CPU
    # and then switches.
    local npu_embed=0
    if ncz_npu_embedder_ready; then
        npu_embed=1
        if ! grep -q "MNEMOS_EMBED_BACKEND=http" "$active"; then
            sed -i "/^Environment=MNEMOS_SQLITE_PATH=/a\\
Environment=MNEMOS_EMBED_BACKEND=http\\
Environment=MNEMOS_EMBED_HTTP_URL=http://127.0.0.1:8081/v1/embeddings\\
Environment=MNEMOS_EMBED_HTTP_MODEL=nomic-embed-text\\
Environment=MNEMOS_EMBEDDING_DIM=768" "$active"
            echo "[ncz] wired MNEMOS to the NPU embedder (nomic-embed-text, 768-dim)"
        else
            echo "[ncz] MNEMOS already wired to the NPU embedder"
        fi
    fi

    systemctl daemon-reload
    systemctl start mnemos.service

    echo "[ncz] MNEMOS started."
    echo "[ncz]   endpoint: http://<host>:5002  (REST /v1/*, MCP, OpenAI-compatible gateway)"
    echo "[ncz]   health:   curl -fsS http://127.0.0.1:5002/health"
    echo "[ncz]   data:     volume mnemos-data (sqlite at /data/mnemos.db, persistent)"
    if [ "$npu_embed" = 1 ]; then
        echo "[ncz]   embedder: Zhouyi NPU via :8081 (nomic-embed-text-v1.5, 768-dim)"
    else
        echo "[ncz]   embedder: in-process CPU (nomic-embed-text-v1.5, 768-dim)"
    fi
    echo "[ncz]   service:  systemctl status mnemos.service"
    echo "[ncz] NOTE: the NPU embedder is the SAME model and width as the CPU one"
    echo "[ncz]       (nomic-embed-text-v1.5, 768-dim), so it is a drop-in and needs"
    echo "[ncz]       no re-embedding. Never repoint MNEMOS at an embedder of a"
    echo "[ncz]       different width: nothing fails loudly, retrieval simply stops"
    echo "[ncz]       returning the memories already written."
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
