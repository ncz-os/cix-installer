#!/bin/bash
# NCZ-MIXED-HOOK: ncz CLI is generic; also stages /opt/cix/npu_embed_v2.py and NPU status (Sky1); TODO split NPU parts (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
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
# bundled image is present does it fall back to pulling ghcr.io/ncz-os/mnemos-enterprise
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
[ -f "$NPU_WRAPPER_SRC" ] || NPU_WRAPPER_SRC=/cdrom/ncz-payload/assets/cix-py/npu_embed_v2.py
if [ -f "$NPU_WRAPPER_SRC" ]; then
    install -D -m 0644 "$NPU_WRAPPER_SRC" /opt/cix/npu_embed_v2.py
    echo "    /opt/cix/npu_embed_v2.py staged ($(wc -l < /opt/cix/npu_embed_v2.py) lines)"
else
    echo "    WARN: $NPU_WRAPPER_SRC not in cdrom payload — /opt/cix/npu_embed_v2.py NOT staged" >&2
fi

# Install the agent helper that backs `ncz agent ...`. The helper is inert until
# an operator explicitly runs `sudo ncz agent install`; all Podman/quadlet/env
# setup happens there, not in the OS installer.
AGENT_HELPER_SRC=/usr/local/lib/cix-installer/assets/ncz-cli.sh
[ -f "$AGENT_HELPER_SRC" ] || AGENT_HELPER_SRC=/cdrom/ncz-payload/assets/ncz-cli.sh
if [ -f "$AGENT_HELPER_SRC" ]; then
    install -D -m 0755 "$AGENT_HELPER_SRC" /usr/local/lib/ncz-agent-cli
    echo "    /usr/local/lib/ncz-agent-cli staged (agent install remains on-demand)"
else
    echo "    WARN: $AGENT_HELPER_SRC not in payload — ncz agent helper NOT staged" >&2
fi

# Stage the on-disk quadlet templates so `ncz install mnemos` and
# `ncz install nemoclaw` find them BEFORE the operator runs
# `ncz agent install <x>` (which is the only path that otherwise copies them
# into place via agent_bootstrap() in /usr/local/lib/ncz-agent-cli).
# Without this pre-staging, `ncz install mnemos` on a freshly-installed box
# errors out with "missing quadlet template" (verified on the amd64 test host / the Sky1 test board
# / the Sky1 test board by the orchestrator on 2026-10-13). The agent-install path
# uses `cp -n` (non-destructive) and is therefore safe to redrive, so a
# duplicate install of the same template is a no-op.
AGENT_STACK_SRC=/usr/local/lib/cix-installer/assets/agent-stack
[ -d "$AGENT_STACK_SRC" ] || AGENT_STACK_SRC=/cdrom/ncz-payload/assets/agent-stack
if [ -d "$AGENT_STACK_SRC" ]; then
    install -d -m 0755 /usr/share/ncz/quadlets
    # -D creates the parent dir + copies the file. -m 0644 makes them writable
    # by root only; quadlets in /etc/containers/systemd override these.
    # Stamping the agent-stack as "stage once" rather than "every run" is safe:
    # the templates are intentionally versioned with the install media and are
    # NOT modified by ncz install (ncz writes to /etc/containers/systemd).
    for f in "$AGENT_STACK_SRC"/*.container "$AGENT_STACK_SRC"/*.network \
             "$AGENT_STACK_SRC"/agent-env.sample; do
        [ -e "$f" ] || continue
        install -D -m 0644 "$f" /usr/share/ncz/quadlets/$(basename "$f")
    done
    echo "    /usr/share/ncz/quadlets staged ($(ls /usr/share/ncz/quadlets/*.container 2>/dev/null | wc -l | tr -d ' ') container + $(ls /usr/share/ncz/quadlets/*.network 2>/dev/null | wc -l | tr -d ' ') network templates)"
else
    echo "    WARN: $AGENT_STACK_SRC not in payload — /usr/share/ncz/quadlets NOT staged" >&2
fi

# The default Debian `secure_path` is /usr/sbin:/usr/bin:/sbin:/bin. Operators
# install `ncz` to /usr/local/bin (the FHS-correct location for add-on
# binaries), but `sudo ncz ...` then fails with "sudo: ncz: command not
# found" because sudo's PATH does NOT include /usr/local/bin. Drop a tiny
# sudoers.d fragment that adds /usr/local/bin to the secure_path for this
# image. ONLY the secure_path is touched — no NOPASSWD, no scope expansion —
# so it is the minimum-impact way to keep `sudo ncz install mnemos` working.
SUDOERS_D=/etc/sudoers.d
if [ -d "$SUDOERS_D" ]; then
    cat > "$SUDOERS_D/ncz-cli-secure-path" <<'SUDOERS'
# NCZ-OS: add /usr/local/bin to sudo's secure_path so `sudo ncz ...` finds
# the CLI staged at /usr/local/bin/ncz. Without this, the very first thing
# an operator types after `apt install ncz-cli` fails with "sudo: ncz:
# command not found" (verified on the amd64 test host / the Sky1 test board / the Sky1 test board on
# 2026-10-13). Intentionally minimal: just the PATH, no NOPASSWD, no scope
# expansion. visudo-equivalent: this file is parsed by sudo only if owned by
# root:root and mode 0440.
Defaults secure_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SUDOERS
    chown root:root "$SUDOERS_D/ncz-cli-secure-path"
    chmod 0440 "$SUDOERS_D/ncz-cli-secure-path"
    echo "    /etc/sudoers.d/ncz-cli-secure-path installed (adds /usr/local/bin to sudo secure_path)"
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
readonly MNEMOS_IMAGE="${MNEMOS_IMAGE:-ghcr.io/ncz-os/mnemos-enterprise:latest}"

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
  models pull           Download nomic-embed-text-v1.5.Q8_0.gguf
                        (HuggingFace, pinned sha256) to $NCZ_MODELS_DIR.
                        Idempotent + offline-safe.
  install mnemos        Install + start the MNEMOS memory server (REST + MCP +
                        OpenAI-compatible gateway on :5002, sqlite-backed).
                        Auto-pulls the embedder model + backfills
                        memory_embeddings on first install. Loads the
                        bundled image OFFLINE; falls back to a ghcr pull
                        only if no bundled image is found.
  install zeroclaw      Alias for 'ncz agent install zeroclaw' (gateway +
                        agents container, ~109 MB).
  install zoder         Download zoder (ZeroClaw CLI for MNEMOS work
                        history) from ncz-os/zoder nightly release. Pinned
                        version + sha256. Config template at
                        /etc/nclawzero/zoder.conf (no secrets).
  install nemoclaw      Pull + start NVIDIA NemoClaw OpenShell sandbox runtime.
  agent install [name]  On-demand setup/install for optional agents.
  agent ...             Manage zeroclaw/openclaw/hermes/portainer agents.
  status                Print system summary: ncz version, BUILD_VARIANT,
                        kernel, default-target, NPU + GPU presence, MNEMOS
                        embedder backend + model.
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
    echo "This system did not preserve assets/ncz-cli.sh during CLI installation." >&2
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
        # No lightdm/gdm3/sddm unit installed — typical for the singularity-
        # labwc desktop SKU which launches the session directly from the
        # user's login shell. Surface that fact rather than leaving the
        # operator to wonder whether something is broken.
        local session_info=""
        # A running labwc compositor on :99 (or Xwayland) is the actual
        # "is the desktop up" signal in this SKU.
        if pgrep -x labwc >/dev/null 2>&1; then
            session_info=" (labwc session active)"
        elif pgrep -x Xwayland >/dev/null 2>&1; then
            session_info=" (Xwayland active)"
        elif pgrep -x sway >/dev/null 2>&1; then
            session_info=" (sway active)"
        fi
        echo "display-manager: (none installed${session_info})"
        # The DM-less layout does NOT support `ncz desktop on` because there
        # is nothing to enable. Make this visible so the operator does not
        # believe the command did something.
        echo "desktop-on: no DM to enable; singularity-labwc session starts from user login"
    fi
}

ncz_desktop_on() {
    if ! [ "$(id -u)" = "0" ]; then echo "ncz desktop on: requires root (use sudo)" >&2; exit 1; fi
    echo "[ncz] desktop ON"
    systemctl set-default graphical.target
    if dm=$(ncz_dm_unit); then
        # r75 review MED fix: 48-server-variant.sh masks DM units in the
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
Usage: ncz models [list|pull|path]

  list   (default) Show embedding models installed in $NCZ_MODELS_DIR:
         .cix (NPU / Zhouyi) + .gguf (CPU/GPU llama.cpp) + tokenizers.
  pull   Download the embedder bundle that MNEMOS expects at runtime
         (nomic-embed-text-v1.5.Q8_0.gguf from HuggingFace, pinned sha256).
         Idempotent: skips when the file is already present and its
         sha256 matches. Public source only; clear offline message when
         the network is down.
  path   Print the on-disk path that 'ncz install mnemos' will use
         (or 'unset' if no host-side model is installed).

Docs: $NCZ_MODELS_DIR/MODELS-README.md,
      /usr/share/doc/ncz/MODELSCOPE-MODELS.md
MSG
            ;;
        pull)
            ncz_models_pull
            ;;
        path)
            # Surface the path 'ncz install mnemos' will hand to the MNEMOS
            # container via the bind mount (/opt/ncz/models -> /opt/ncz/models:ro).
            # The MNEMOS embedder runs INSIDE the container at
            # /opt/mnemos/models/<file>.gguf (its own copy), but the host-side
            # file is the audit-able, sha256-pinned artifact.
            local p
            p="$(find "$NCZ_MODELS_DIR" -maxdepth 2 -name 'nomic-embed-text-v1.5.Q8_0.gguf' 2>/dev/null | head -1)"
            if [ -n "$p" ]; then
                echo "$p"
                return 0
            fi
            echo "(unset — run 'ncz models pull' to fetch)" >&2
            return 1
            ;;
        *)
            echo "ncz models: unknown action '$action' (expected list|pull|path)" >&2
            exit 1
            ;;
    esac
}

# ncz_models_pull -- download nomic-embed-text-v1.5.Q8_0.gguf to $NCZ_MODELS_DIR
# with a pinned hash + 3 retries + clear offline message. Idempotent: skips
# when the file is already present with the correct hash. The same GGUF is
# baked into the MNEMOS-enterprise image at /opt/mnemos/models/<file>, so
# pulling it to the host is optional (only needed for host-side embedders
# such as the zoder work-history path that doesn't run inside MNEMOS).
ncz_models_pull() {
    # Public source: HuggingFace nomic-ai/nomic-embed-text-v1.5-GGUF.
    # The Q8_0 quantization is ~146 MB. Hash pinned below matches the file
    # baked into ghcr.io/ncz-os/mnemos-enterprise:latest as of 2026-10-13.
    local url='https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf'
    local sha256='3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7'
    local dest_dir="$NCZ_MODELS_DIR"
    local dest="$dest_dir/nomic-embed-text-v1.5.Q8_0.gguf"
    install -d -m 0755 "$dest_dir" 2>/dev/null || {
        echo "ncz models pull: cannot create $dest_dir (mkdir failed)" >&2
        return 1
    }
    # Idempotency: if the file is already present with the correct hash,
    # skip the download. The META-INF/ directory is host-side metadata that
    # we write after a successful download so the next 'ncz models list'
    # surfaces provenance.
    if [ -f "$dest" ]; then
        local actual
        actual="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
        if [ "$actual" = "$sha256" ]; then
            echo "[ncz] models pull: $dest already present, sha256 matches"
            return 0
        fi
        echo "[ncz] models pull: $dest sha256 mismatch (have=$actual want=$sha256) — re-downloading"
        rm -f "$dest"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "ncz models pull: curl is not installed" >&2
        return 1
    fi
    # 3 attempts spaced 2s apart. Typical offline diagnostic = no message
    # printed by curl other than 'Could not resolve host' or 'Connection
    # timed out', so we also probe with -fsghw' ' before the download.
    #
    # IMPORTANT: use -fsSL (follow redirects). HuggingFace serves the
    # gguf via an xet-bridge CDN that 302s to a signed URL — without -L
    # curl returns the 1108-byte redirector JSON, not the 146 MB file
    # (verified on the amd64 test host 2026-10-13; a sha256 mismatch was actually
    # curl downloaded a wrong-but-valid HTML body).
    echo "[ncz] models pull: fetching $url"
    echo "[ncz] models pull: target sha256 = $sha256"
    local tmp; tmp="$(mktemp -t ncz-models.XXXXXX)"
    local attempt got=0
    for attempt in 1 2 3; do
        if curl -fsSL --connect-timeout 8 --max-time 600 -o "$tmp" "$url"; then
            got=1
            break
        fi
        echo "[ncz] models pull: attempt $attempt/3 failed, sleeping 2s"
        sleep 2
    done
    if [ "$got" != "1" ]; then
        rm -f "$tmp"
        cat >&2 <<EOF
ncz models pull: failed to fetch $url after 3 attempts.

  This system is offline, or huggingface.co is unreachable from this network.
  MNEMOS does not need this file to embed — the gguf is shipped inside the
  mnemos-enterprise image at /opt/mnemos/models/<file>. This host-side copy
  is only used by tools that embed outside the container (e.g. zoder's
  work-history path). To come back online and retry:

    sudo ncz models pull
EOF
        return 1
    fi
    # Verify the downloaded file's hash matches the pinned value.
    local actual
    actual="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ "$actual" != "$sha256" ]; then
        rm -f "$tmp"
        echo "ncz models pull: sha256 mismatch after download" >&2
        echo "  expected: $sha256" >&2
        echo "  got:      $actual" >&2
        echo "  refusing to install — the source may have been tampered with or" >&2
        echo "  the pinned version in this script is stale (re-roll ncz and bump" >&2
        echo "  the sha256 in ncz_models_pull if HuggingFace rotated the artifact)." >&2
        return 1
    fi
    install -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
    echo "[ncz] models pull: installed $dest (sha256 verified)"
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
        echo "  expected at: $template" >&2
        echo "  the post-install/46-ncz-cli.sh hook should have staged it from assets/agent-stack/." >&2
        echo "  re-install the ncz-cli deb (or run 'sudo ncz agent install --all' once to populate /usr/share/ncz/quadlets/)." >&2
        exit 1
    fi

    echo "[ncz] installing MNEMOS"
    # OFFLINE-FIRST image acquisition. The ISO bundles the MNEMOS image as
    # an OCI archive (assets/agent-images/mnemos.oci.tar); load it locally so
    # `ncz install mnemos` works with NO network. Only if no bundled image
    # is present (e.g. a netinstall ISO, or an image built without the
    # 30-agents.sh staging step) do we fall back to a registry pull with
    # explicit retries. The quadlet uses Pull=never, so the image MUST
    # exist locally before the service starts.
    #
    # Image-pinning policy: zeroclaw + openclaw + hermes + portainer all pin
    # or float on registry tags. MNEMOS is special because it is BOTH the
    # on-system service host (an authenticated REST API at :5002) AND the
    # data plane the in-product MCP-AUDIT log calls out. We default to :*
    # (the value of MNEMOS_IMAGE, which ghcr.io/ncz-os/mnemos-enterprise:*
    # re-tags to the latest stable). Operators who want strict reproducibility
    # should override MNEMOS_IMAGE to a digest before invoking `ncz install
    # mnemos`; the CLI just passes MNEMOS_IMAGE straight to the quadlet.
    if podman image exists "$MNEMOS_IMAGE" 2>/dev/null; then
        echo "[ncz] image already present: $MNEMOS_IMAGE"
    else
        local mnemos_loaded=0 mnemos_tar
        for mnemos_tar in \
            /var/lib/nclawzero/agent-images/mnemos.oci.tar \
            /usr/local/lib/cix-installer/assets/agent-images/mnemos.oci.tar \
            /cdrom/ncz-payload/assets/agent-images/mnemos.oci.tar; do
            [ -f "$mnemos_tar" ] || continue
            echo "[ncz] loading bundled MNEMOS image OFFLINE from $mnemos_tar"
            if podman load -i "$mnemos_tar"; then mnemos_loaded=1; break; fi
            echo "[ncz] WARN: podman load failed for $mnemos_tar — trying next source"
        done
        if [ "$mnemos_loaded" != 1 ]; then
            echo "[ncz] no bundled image found — falling back to network pull of $MNEMOS_IMAGE"
            # Retry on transient network errors. podman pull exits non-zero on
            # a flaky link or a registry 5xx; 3 attempts spaced 2s apart is
            # enough for the typical "registry just 503'd me" case without
            # making a real offline operator wait minutes before the
            # diagnostic message.
            local mnemos_pulled=0 attempt
            for attempt in 1 2 3; do
                if podman pull "$MNEMOS_IMAGE"; then mnemos_pulled=1; break; fi
                echo "[ncz] WARN: podman pull attempt $attempt/3 failed, sleeping 2s"
                sleep 2
            done
            if [ "$mnemos_pulled" != 1 ]; then
                echo "ncz install mnemos: failed to acquire $MNEMOS_IMAGE" >&2
                echo "  no bundled image at:" >&2
                echo "    /var/lib/nclawzero/agent-images/mnemos.oci.tar" >&2
                echo "    /usr/local/lib/cix-installer/assets/agent-images/mnemos.oci.tar" >&2
                echo "    /cdrom/ncz-payload/assets/agent-images/mnemos.oci.tar" >&2
                echo "  AND a 3-attempt pull of $MNEMOS_IMAGE failed." >&2
                echo "  → this system is offline, OR ghcr.io is unreachable from this network." >&2
                echo "  → for offline bundles, see assets/agent-images/README.md (this image was built without a bundle)." >&2
                echo "  → for connectivity, check:    curl -fsSI https://ghcr.io/" >&2
                exit 1
            fi
        fi
        # The bundled archive is tagged ghcr.io/ncz-os/mnemos-enterprise:latest. If the
        # operator overrode MNEMOS_IMAGE to a different tag, retag the loaded
        # image so the Pull=never quadlet (Image=$MNEMOS_IMAGE) can resolve it.
        if ! podman image exists "$MNEMOS_IMAGE" 2>/dev/null \
           && podman image exists ghcr.io/ncz-os/mnemos-enterprise:latest 2>/dev/null; then
            podman tag ghcr.io/ncz-os/mnemos-enterprise:latest "$MNEMOS_IMAGE" 2>/dev/null || true
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

    systemctl daemon-reload
    systemctl start mnemos.service

    # Generate (or load) a host-unique MNEMOS internal-audit token and write
    # it into the quadlet so the `/v1/internal/mcp_audit` route is locked down.
    # The token is persisted on the host at /etc/nclawzero/mnemos-audit-token
    # so the bootstrap below can present it via X-Mnemos-Audit-Token when
    # creating the default admin user + API key.
    #
    # Why here and not at MNEMOS image-build time: the quadlet Env= line is
    # owned by /etc/containers/systemd/mnemos.container (root-editable on
    # every install), so generating on the host keeps tokens per-machine and
    # survives image rebuilds without invalidating every deployed MNEMOS.
    local token_file=/etc/nclawzero/mnemos-audit-token
    install -d -m 0750 -g nclawzero /etc/nclawzero 2>/dev/null || true
    if [ ! -s "$token_file" ]; then
        # 32 bytes hex = 64 chars. Same shape MNEMOS's installer uses for
        # `internal_audit_token` (256-bit).
        head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' > "$token_file"
        chmod 0640 "$token_file"
        chgrp nclawzero "$token_file" 2>/dev/null || true
    fi
    local audit_token mcp_token mcp_token_file=/etc/nclawzero/mnemos-mcp-token
    audit_token="$(cat "$token_file" 2>/dev/null)"
    if [ -n "$audit_token" ]; then
        # Replace or insert MNEMOS_INTERNAL_AUDIT_TOKEN=... in the active
        # quadlet. If we generated it on this run, daemon-reload+restart so
        # MNEMOS picks it up; on subsequent runs the value is unchanged so
        # the restart is a no-op for env (MNEMOS still restarts cleanly).
        #
        # Insertion is robust against quadlet-template drift: first try to
        # anchor after MNEMOS_PERSISTENCE_BACKEND=sqlite (the documented
        # hook), then fall back to MNEMOS_SQLITE_PATH=, then fall back to
        # appending to any Environment= block, then append after [Container].
        # We NEVER silently lose the token; if none of those hooks exist we
        # fail-loud with a clear message rather than restarting MNEMOS
        # without the env var the bootstrap expects to see.
        if grep -q '^Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=' "$active"; then
            sed -i "s|^Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=.*|Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=$audit_token|" "$active"
        else
            if grep -q '^Environment=MNEMOS_PERSISTENCE_BACKEND=sqlite' "$active"; then
                sed -i "/^Environment=MNEMOS_PERSISTENCE_BACKEND=sqlite/a\\Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=$audit_token" "$active"
            elif grep -q '^Environment=MNEMOS_SQLITE_PATH=' "$active"; then
                sed -i "/^Environment=MNEMOS_SQLITE_PATH=/a\\Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=$audit_token" "$active"
            elif grep -q '^\[Container\]' "$active"; then
                sed -i "/^\[Container\]/a\\Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=$audit_token" "$active"
            else
                echo "[ncz] FATAL: cannot find a stable insertion point for MNEMOS_INTERNAL_AUDIT_TOKEN in $active" >&2
                echo "[ncz]   quadlet does not match any of:" >&2
                echo "[ncz]     - Environment=MNEMOS_PERSISTENCE_BACKEND=sqlite" >&2
                echo "[ncz]     - Environment=MNEMOS_SQLITE_PATH=" >&2
                echo "[ncz]     - [Container]" >&2
                echo "[ncz]   refusing to restart MNEMOS without the audit token — fix the quadlet template." >&2
                exit 1
            fi
        fi
        if ! grep -q '^Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=' "$active"; then
            echo "[ncz] FATAL: MNEMOS_INTERNAL_AUDIT_TOKEN line did not land in $active after sed." >&2
            exit 1
        fi
        # MCP HTTP/SSE auth token. The Exec=mnemos-serve-api-and-mcp supervisor
        # will not start the MCP child without MNEMOS_MCP_TOKEN, so generate a
        # per-host token and inject it the same way as the audit token.
        if [ ! -s "$mcp_token_file" ]; then
            head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' > "$mcp_token_file"
            chmod 0640 "$mcp_token_file"
            chgrp nclawzero "$mcp_token_file" 2>/dev/null || true
        fi
        mcp_token="$(cat "$mcp_token_file" 2>/dev/null)"
        if [ -n "$mcp_token" ]; then
            if grep -q '^Environment=MNEMOS_MCP_TOKEN=' "$active"; then
                sed -i "s|^Environment=MNEMOS_MCP_TOKEN=.*|Environment=MNEMOS_MCP_TOKEN=$mcp_token|" "$active"
            elif grep -q '^Environment=MNEMOS_MCP_PORT=' "$active"; then
                sed -i "/^Environment=MNEMOS_MCP_PORT=/a\\Environment=MNEMOS_MCP_TOKEN=$mcp_token" "$active"
            elif grep -q '^Environment=MNEMOS_PERSISTENCE_BACKEND=sqlite' "$active"; then
                sed -i "/^Environment=MNEMOS_PERSISTENCE_BACKEND=sqlite/a\\Environment=MNEMOS_MCP_TOKEN=$mcp_token" "$active"
            elif grep -q '^\[Container\]' "$active"; then
                sed -i "/^\[Container\]/a\\Environment=MNEMOS_MCP_TOKEN=$mcp_token" "$active"
            fi
            if ! grep -q '^Environment=MNEMOS_MCP_TOKEN=' "$active"; then
                echo "[ncz] FATAL: MNEMOS_MCP_TOKEN line did not land in $active after sed." >&2
                exit 1
            fi
        fi
        systemctl daemon-reload
        systemctl restart mnemos.service
    fi

    # Wait for MNEMOS to bind :5002 (sqlite cold-start + uvicorn ready can take
    # 5-15 s on arm64). Bounded wait: 60 attempts × 1 s = 60 s, then give up.
    local ready=0 i
    for i in $(seq 1 60); do
        if curl -fsS --max-time 2 http://127.0.0.1:5002/health >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 1
    done
    if [ "$ready" != 1 ]; then
        echo "[ncz] WARN: MNEMOS did not answer /health within 60 s — bootstrap skipped." >&2
        echo "[ncz]   check 'systemctl status mnemos.service' and 'journalctl -u mnemos -n 50'." >&2
    fi

    echo "[ncz] MNEMOS started."
    echo "[ncz]   REST/OpenAI endpoint: http://<host>:5002  (/v1/*, OpenAI-compatible gateway)"
    echo "[ncz]   MCP endpoint:         http://<host>:5004/mcp  (HTTP/SSE, bearer token)"
    echo "[ncz]   health:   curl -fsS http://127.0.0.1:5002/health"
    echo "[ncz]   data:     volume mnemos-data (sqlite at /data/mnemos.db, persistent)"
    echo "[ncz]   embedder: in-process CPU (nomic-embed-text-v1.5, 768-dim)"
    echo "[ncz]   service:  systemctl status mnemos.service"

    # HOST-SIDE MODEL PULL. The MNEMOS image already ships the GGUF inside the
    # container at /opt/mnemos/models/<file>.gguf so the embedder works on
    # first install with no host-side artifact. But host-side tools (zoder's
    # work-history path, future CLI embedders) want a host-side copy under
    # /opt/ncz/models. We pull it here so `ncz install mnemos` is the canonical
    # one-shot setup for the embedder stack. Best-effort: if the network is
    # down the container still serves — we just don't have the host-side copy
    # yet. The operator can `ncz models pull` later.
    if ! ncz_models_pull 2>&1 | sed 's/^/[ncz]   /'; then
        echo "[ncz] WARN: host-side embedder model pull failed; MNEMOS keeps its in-image copy." >&2
        echo "[ncz]   retry later: sudo ncz models pull" >&2
    fi

    # SQLITE EMBEDDING BACKFILL. MNEMOS's SQLite persistence has two places
    # where an embedding lives: the inline `memories.embedding` TEXT column
    # (written by create_memory at write time) and the separate
    # `memory_embeddings` table (read by semantic_search). On PG/MariaDB these
    # collapse to one; on SQLite they are intentionally separate (a PG-style
    # backfill worker keeps them in sync). For a small fresh install the
    # backfill is a single INSERT OR IGNORE — copying every row that has an
    # inline embedding into memory_embeddings so semantic_search returns it
    # on the very next request. Idempotent: ON CONFLICT DO NOTHING means
    # re-running this is safe. Best-effort: if podman exec fails (container
    # not up yet, etc.) we don't fail the install — the embedder still
    # produces vectors; the operator can re-run via a follow-up hook.
    local backfill_out backfill_rc=0
    backfill_out="$(podman exec mnemos python3 -c '
import sqlite3, sys
try:
    c = sqlite3.connect("/data/mnemos.db")
    c.execute("""
        INSERT OR IGNORE INTO memory_embeddings(memory_id, embedding, updated_at)
        SELECT m.id, m.embedding, strftime(\"%s\", \"now\")
        FROM memories m
        WHERE m.embedding IS NOT NULL AND m.embedding != \"\"
    """)
    c.commit()
    n = c.execute("SELECT count(*) FROM memory_embeddings").fetchone()[0]
    print(f"OK memory_embeddings={n}")
except Exception as e:
    print(f"FAIL {e}", file=sys.stderr)
    sys.exit(1)
' 2>&1)" || backfill_rc=$?
    if [ "$backfill_rc" = "0" ] && echo "$backfill_out" | grep -q '^OK '; then
        echo "[ncz]   backfill: $(echo "$backfill_out" | grep '^OK ' | head -1)"
    else
        echo "[ncz] WARN: SQLite memory_embeddings backfill failed (rc=$backfill_rc)" >&2
        echo "[ncz]   semantic_search on new memories will fall back to FTS until the next backfill" >&2
        echo "[ncz]   output: $backfill_out" >&2
    fi

# FIRST-RUN BOOTSTRAP. After install, ensure a default admin user + API
    # key exist for this host and persist them at /etc/nclawzero/mnemos.env,
    # so the operator (and `ncz status` later) can authenticate without
    # first passing an existing bearer token. This is the "personal
    # profile" path: one user, one key, no OAuth, no MFA — exactly what a
    # single-user desktop install wants.
    #
    # Why sqlite instead of POST /admin/users? /admin/users requires bearer
    # auth, and we don't have one yet on a fresh install. The audit-token
    # endpoint (/v1/internal/mcp_audit) ALSO requires bearer auth (see
    # mnemos/api/routes/mcp_audit.py:_require_internal_audit_token, which
    # only checks the audit-token header, but the route ALSO depends on
    # get_current_user). MNEMOS's only chicken-and-egg escape is the sqlite
    # backend itself — insert a row directly. We do that via podman exec
    # the MNEMOS container (it already has python + sqlite3, no need for the
    # host to ship sqlite3-cli).
    #
    # Skipped silently on a re-install: if /etc/nclawzero/mnemos.env already
    # has a token, the install is idempotent.
    if [ "$ready" = 1 ]; then
        local mnemos_env=/etc/nclawzero/mnemos.env
        if [ -s "$mnemos_env" ] && grep -q '^MNEMOS_API_TOKEN=' "$mnemos_env"; then
            echo "[ncz] MNEMOS API token already provisioned at $mnemos_env"
        else
            local bootstrap_user="ncz-$(hostname -s 2>/dev/null | tr -cd 'a-z0-9-' | cut -c1-20)"
            [ -n "$bootstrap_user" ] || bootstrap_user="ncz-admin"
            # Generate raw_key + key_hash INSIDE the MNEMOS container so we
            # never expose mnemos.db to the host (the volume is owned by
            # root inside the container; the bind-mount on the host is
            # rootless vlog-style and we do NOT want to depend on that).
            # The bootstrap script: insert the 'ncz-*' user as root if
            # missing, then mint an api_key whose key_hash is sha256(raw_key).
            local raw_key key_hash
            raw_key="$(head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n')"
            key_hash="$(printf '%s' "$raw_key" | sha256sum | awk '{print $1}')"
            local bootstrap_out
            # SECURITY: pass bootstrap_user, key_hash, and raw_key_prefix
            # via environment variables (NOT shell-string interpolation),
            # and validate bootstrap_user on the Python side so a hostile
            # hostname (single quote, backslash, control char) cannot break
            # out of the SQLite parameter binding. The raw_key itself is
            # only ever read on the host — it goes to /etc/nclawzero/mnemos.env
            # via the shell, never into the Python heredoc.
            bootstrap_out="$(NCZ_BOOTSTRAP_USER="$bootstrap_user" \
                                  NCZ_BOOTSTRAP_KEY_HASH="$key_hash" \
                                  NCZ_BOOTSTRAP_KEY_PREFIX="${raw_key:0:8}" \
                             podman exec -e NCZ_BOOTSTRAP_USER \
                                        -e NCZ_BOOTSTRAP_KEY_HASH \
                                        -e NCZ_BOOTSTRAP_KEY_PREFIX \
                                        mnemos python3 -c '
import os, sqlite3, sys
# Parameter binding — never string-format a value into SQL.
user_id    = os.environ["NCZ_BOOTSTRAP_USER"]
key_hash   = os.environ["NCZ_BOOTSTRAP_KEY_HASH"]
key_prefix = os.environ["NCZ_BOOTSTRAP_KEY_PREFIX"]
# Defensive validation. user_id is generated on the host as
# "ncz-$(hostname -s | tr -cd a-z0-9- | cut -c1-20)", so under
# normal conditions it is already a safe identifier. This check
# is a second line of defense in case the host filter is bypassed
# or the username is supplied through a future code path.
#
# Forbidden-char set is built with chr() so this Python source does not
# carry a literal backtick on a line bash will later re-parse during the
# `ncz-cli-basics` shell test (an unpaired backtick inside the
# single-quoted heredoc is literal here, but the test extracts the body
# and re-runs it as a stand-alone script where the backtick inside a
# double-quoted Python string is interpreted as command substitution and
# the script dies with `unexpected EOF while looking for matching`).
if not (1 <= len(user_id) <= 64) or any(c in user_id for c in (chr(34), chr(39), chr(92), chr(96))):
    print("FAIL user_id contains a forbidden character", file=sys.stderr)
    sys.exit(2)
if len(key_hash) != 64 or any(c not in "0123456789abcdef" for c in key_hash):
    print("FAIL key_hash must be 64 lowercase hex chars", file=sys.stderr)
    sys.exit(2)
if len(key_prefix) != 8 or any(c not in "0123456789abcdef" for c in key_prefix):
    print("FAIL key_prefix must be 8 lowercase hex chars", file=sys.stderr)
    sys.exit(2)
c = sqlite3.connect("/data/mnemos.db")
c.row_factory = sqlite3.Row
existing = c.execute("SELECT id FROM users WHERE id = ?", (user_id,)).fetchone()
if not existing:
    c.execute("INSERT INTO users (id, username, role, namespace) VALUES (?, ?, ?, ?)",
              (user_id, user_id, "root", "default"))
# Mint a fresh api_key for this user. Revoke any pre-existing active keys
# for this user so we never accumulate more than one. (MNEMOS caps at 10
# per user; this is the same cap the /admin/users/{user_id}/apikeys route
# enforces.)
c.execute("UPDATE api_keys SET revoked = 1, revoked_at = CURRENT_TIMESTAMP "
          "WHERE user_id = ? AND revoked = 0", (user_id,))
c.execute("INSERT INTO api_keys (id, user_id, key_hash, label, key_prefix, revoked) "
          "VALUES (lower(hex(randomblob(16))), ?, ?, ?, ?, 0)",
          (user_id, key_hash, "ncz-install-bootstrap", key_prefix))
c.commit()
# Verify
rows = c.execute("SELECT id, key_prefix, label, revoked FROM api_keys "
                 "WHERE user_id = ? ORDER BY created_at DESC LIMIT 1", (user_id,)).fetchall()
print("OK " + str(len(rows)) + " key(s) for " + user_id)
for r in rows:
    print("KEY " + r["key_prefix"] + " " + r["label"])
' 2>&1)"
            local bootstrap_rc=$?
            if [ "$bootstrap_rc" = "0" ] && echo "$bootstrap_out" | grep -q "^OK "; then
                {
                    echo "# MNEMOS API credential for this host."
                    echo "# Issued by 'ncz install mnemos' on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
                    echo "# Source the file (or read MNEMOS_API_TOKEN) before calling MNEMOS."
                    echo "MNEMOS_USER=$bootstrap_user"
                    echo "MNEMOS_API_TOKEN=$raw_key"
                    echo "MNEMOS_BASE_URL=http://127.0.0.1:5002"
                    [ -n "$mcp_token" ] && echo "MNEMOS_MCP_TOKEN=$mcp_token"
                    echo "MNEMOS_MCP_URL=http://127.0.0.1:5004"
                } > "$mnemos_env"
                chmod 0640 "$mnemos_env"
                chgrp nclawzero "$mnemos_env" 2>/dev/null || true
                echo "[ncz] MNEMOS bootstrap: user=$bootstrap_user token written to $mnemos_env"
                echo "[ncz]   test:    curl -H \"Authorization: Bearer \$(grep MNEMOS_API_TOKEN= $mnemos_env | cut -d= -f2)\" http://127.0.0.1:5002/stats"
            else
                echo "[ncz] WARN: MNEMOS API key bootstrap did not succeed." >&2
                echo "[ncz]   raw output: $bootstrap_out" >&2
                echo "[ncz]   manual bootstrap:" >&2
                echo "[ncz]     podman exec mnemos python3 -c 'import sqlite3; c=sqlite3.connect(\"/data/mnemos.db\"); ...'" >&2
            fi
        fi
        # Backfill MCP creds into an already-provisioned mnemos.env so existing
        # installs pick up the MCP endpoint without re-bootstrapping.
        if [ -s "$mnemos_env" ] && [ -n "$mcp_token" ] && ! grep -q '^MNEMOS_MCP_TOKEN=' "$mnemos_env"; then
            { echo "MNEMOS_MCP_TOKEN=$mcp_token"; echo "MNEMOS_MCP_URL=http://127.0.0.1:5004"; } >> "$mnemos_env"
            chmod 0640 "$mnemos_env"
            chgrp nclawzero "$mnemos_env" 2>/dev/null || true
        fi
    fi

    # NPU EMBEDDING OFFLOAD — installed HERE and only here.
    #
    # Operator direction 2026-08-17: the embedding model is an
    # application-layer artifact that ships from the NCZ apt repo and is
    # deployed ONLY with MNEMOS, its sole consumer. It is deliberately no
    # longer baked into the ISO (see the models) exclusion in
    # build/build-iso-di.sh), which keeps ~100-600MB off every desktop
    # install that will never run MNEMOS and lets the model version roll
    # forward on apt's cadence rather than the ISO's.
    #
    # DIMENSION IS THE WHOLE POINT. MNEMOS's in-process embedder is
    # nomic-embed-text-v1.5 at 768 dimensions, so the NPU graph must be the
    # 768-dim build of the SAME model or the vectors are not comparable and
    # the store is silently poisoned. ncz-model-nomic-embed exists for
    # exactly this ("768 dimensions to match MNEMOS's in-process embedder
    # exactly", per its own package description).
    #
    # The previous text here told the operator to
    # `apt install mnemos-cix-integration` for a MiniLM-L6-v2 384-dim
    # embedder. That package does not exist in the repo at all (verified
    # 2026-08-17 against both the buildkite and R2 indices), and 384 != 768
    # would have been a dimension mismatch even if it had.
    if [ -e /dev/aipu ]; then
        echo "[ncz] NPU detected (/dev/aipu)."
        if [ "${NCZ_MNEMOS_NPU:-0}" = "1" ]; then
            echo "[ncz]   NCZ_MNEMOS_NPU=1 — installing the 768-dim NPU embedder"
            _npu_remv=$(apt-get install -y -s ncz-npu-embed ncz-model-nomic-embed 2>/dev/null | grep -c '^Remv' || true)
            if [ "${_npu_remv:-1}" = "0" ]; then
                if apt-get install -y ncz-npu-embed ncz-model-nomic-embed; then
                    echo "[ncz]   installed ncz-npu-embed + ncz-model-nomic-embed (768-dim)"
                else
                    echo "[ncz]   WARN: NPU embedder install failed — MNEMOS keeps its in-process CPU embedder"
                fi
            else
                echo "[ncz]   WARN: skipping NPU embedder — apt wanted to REMOVE $_npu_remv package(s)"
            fi
        else
            # Default path. The shipped MNEMOS quadlet keeps the cix-npu block
            # commented out because the NOE userspace engine fails every
            # inference on the current kernel (noe_get_tensor), so passing
            # /dev/aipu + a .cix model in would make MNEMOS select a backend
            # that cannot embed. Report the device and stay on the embedder
            # that actually works; keep the NPU stack opt-in.
            echo "[ncz]   MNEMOS uses the in-process CPU embedder (nomic-embed-text-v1.5, 768-dim)."
            echo "[ncz]   The cix-npu embedder is disabled in this release (NOE userspace"
            echo "[ncz]   engine ABI gap: every cix-npu inference fails). The 768-dim NPU"
            echo "[ncz]   model (ncz-model-nomic-embed) and runtime (ncz-npu-embed) are"
            echo "[ncz]   available; opt in once the gap is fixed with:"
            echo "[ncz]     sudo NCZ_MNEMOS_NPU=1 ncz install mnemos"
        fi
    else
        echo "[ncz] no /dev/aipu — using the in-process CPU embedder (nomic-embed-text-v1.5, 768-dim)."
    fi
}

# --- android (waydroid) --------------------------------------------------
#
# Waydroid runs Android in an LXC container against the host GPU and
# compositor: Mali through the vendor driver, and labwc. Both are already here.
#
# Installed through Waydroid's OWN repository rather than Debian's package, as
# the project documents at https://docs.waydro.id/usage/install-on-desktops.
# Their repo tracks the images on the official OTA server, so the tooling and
# the system image stay in step; the Debian package lags and can end up asking
# an older waydroid to run a newer image.
#
# THE ONE HARD REQUIREMENT IS BINDER. Waydroid cannot start without
# /dev/binderfs or /dev/binder, and a kernel without CONFIG_ANDROID_BINDER_IPC
# has neither. This is checked FIRST, before anything is downloaded, because
# otherwise the failure surfaces as an opaque LXC error several minutes into a
# ~1 GB download.
# Sky1 has NO render-capable DRM node, and Waydroid picks one anyway.
#
# ROOT CAUSE (measured on the Sky1 test board 2026-08-18). /dev/dri/renderD128 belongs to
# linlondp -- the Arm Mali-DP DISPLAY CONTROLLER on CIXH5010. It exposes a
# renderD* node but has no render engine: its only children are card0-DP-1..3
# and card0-Writeback-1..6. The actual GPU is Mali-G720-Immortalis behind the
# vendor blob at /dev/mali0, which is not a DRM device at all.
#
# Waydroid's tools/helpers/gpu.py:getDriNode() accepts any renderD* whose kernel
# driver is not in a denylist that contains exactly one entry, "nvidia". So it
# selects linlondp, sets ro.hardware.gralloc=gbm and
# gralloc.gbm.device=/dev/dri/renderD128, and every allocation then fails:
#
#     E GBM-MESA-WRAPPER: Unable to create BO, size=128x128, fmt=875708993
#     E android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa: Failed to create bo.
#
# hwcomposer.waydroid.so dereferences the null buffer in get_buffer_metadata_cros(),
# android.hardware.graphics.composer@2.1-service dies, and system_server restarts
# forever. Android never reaches sys.boot_completed.
#
# Two edits, both idempotent, both re-applied on every run because they patch
# files owned by the waydroid package and an apt upgrade will revert them:
#
#   1. Add linlondp to the denylist, so getDriNode() returns nothing and Waydroid
#      falls back to gralloc=default (ashmem/CPU buffers, no render node needed).
#   2. Waydroid pairs that fallback with egl=swiftshader, but this image ships NO
#      swiftshader -- /system/lib64/egl is empty and only libEGL_mesa.so and
#      libEGL_angle.so exist under /vendor/lib64/egl. Naming a driver that is not
#      there yields no EGL at all. libgallium_dri.so IS present, so use mesa,
#      which lands on llvmpipe.
#
# Then regenerate waydroid_base.prop. It is written ONCE at init and never
# refreshed, so without this the stale gbm values survive every restart and the
# patch looks like it did nothing. `waydroid upgrade -o` is the supported
# config-only regeneration and does not re-download the images.
#
# This is SOFTWARE rendering. It is the only thing that works on this board
# today; hardware rendering needs either panthor (blocked on ACPI-vs-DT
# enumeration) or the Android Mali userspace blob injected into the Waydroid
# vendor image, with /dev/mali0 -- already passed into the container -- as the
# kernel path.
ncz_android_gpu_quirk() {
    local gpu_py=/usr/lib/waydroid/tools/helpers/gpu.py
    local lxc_py=/usr/lib/waydroid/tools/helpers/lxc.py
    local changed=0

    if [ -f "$gpu_py" ] && ! grep -q 'linlondp' "$gpu_py"; then
        sed -i 's/^unsupported = \["nvidia"\]$/unsupported = ["nvidia", "linlondp"]  # linlondp is display-only: no render engine/' "$gpu_py"
        grep -q 'linlondp' "$gpu_py" && { changed=1; echo "[ncz] waydroid: denylisted linlondp (display-only DRM node)"; }
    fi

    if [ -f "$lxc_py" ] && grep -q 'egl = "swiftshader"' "$lxc_py"; then
        # This image has no swiftshader; mesa (libgallium_dri.so -> llvmpipe) is
        # the software renderer that actually loads.
        sed -i 's/            egl = "swiftshader"/            egl = "mesa"  # no swiftshader in this image; mesa gives llvmpipe/' "$lxc_py"
        changed=1
        echo "[ncz] waydroid: software EGL set to mesa (image ships no swiftshader)"
    fi

    if [ "$changed" = 1 ] && [ -f /var/lib/waydroid/waydroid_base.prop ]; then
        # waydroid_base.prop is generated once at init and never refreshed.
        waydroid session stop >/dev/null 2>&1 || true
        if waydroid upgrade -o >/dev/null 2>&1; then
            echo "[ncz] waydroid: regenerated waydroid_base.prop"
        else
            echo "[ncz] WARN: 'waydroid upgrade -o' failed; base props may still name the unusable gbm device" >&2
        fi
    fi

    if [ -f /var/lib/waydroid/waydroid_base.prop ]; then
        echo "[ncz] waydroid graphics: $(grep -E '^ro.hardware.(gralloc|egl)=' /var/lib/waydroid/waydroid_base.prop | tr '\n' ' ')"
    fi
}

# The launcher the Waydroid package ships is NOT usable. Its Waydroid.desktop
# carries `Exec=waydroid`, and bare `waydroid` takes no action: measured on the Sky1 test board
# it printed nothing and had not exited after two minutes. Clicking the shipped
# icon therefore hangs silently, which reads as "Android is broken".
#
# So ship our own entry that runs the command that actually starts Android, and
# hide theirs rather than editing it -- the package owns that file and would
# overwrite an edit on its next upgrade, whereas a NoDisplay flag on a file we
# do not own is the same mechanism 59-desktop-curate.sh already uses for base
# system cruft.
ncz_android_launcher() {
    local appdir=/usr/share/applications
    local ours="$appdir/ncz-waydroid.desktop"
    local theirs="$appdir/Waydroid.desktop"

    install -d "$appdir"
    cat > "$ours" <<'LAUNCH'
[Desktop Entry]
Version=1.0
Type=Application
Name=Android
GenericName=Android apps (Waydroid)
Comment=Run Android apps in a container, on the host GPU
Exec=waydroid show-full-ui
Icon=waydroid
Terminal=false
StartupNotify=true
Categories=Utility;
Keywords=android;waydroid;apps;play;
Actions=stop;

[Desktop Action stop]
Name=Stop Android
Exec=waydroid session stop
Icon=waydroid
LAUNCH
    chmod 0644 "$ours"
    echo "[ncz] launcher -> $ours (Exec=waydroid show-full-ui)"

    # Hide the package's own entry, whose Exec hangs.
    if [ -f "$theirs" ]; then
        if grep -q '^NoDisplay=' "$theirs"; then
            sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$theirs"
        else
            sed -i '0,/^\[Desktop Entry\]/s//[Desktop Entry]\nNoDisplay=true/' "$theirs"
        fi
        echo "[ncz] hid $theirs (its Exec=waydroid does nothing and hangs)"
    fi

    # Desktop shortcut: /etc/skel for users created later, plus every existing
    # human home, because this subcommand runs on a LIVE system where /etc/skel
    # has already been copied and would otherwise reach nobody.
    local d
    for d in /etc/skel/Desktop /home/*/Desktop; do
        [ -d "$d" ] || continue
        cp "$ours" "$d/Android.desktop" 2>/dev/null || continue
        chmod 0755 "$d/Android.desktop" 2>/dev/null || true
        case "$d" in
            /home/*) chown "$(stat -c %u:%g "${d%/Desktop}")" "$d/Android.desktop" 2>/dev/null || true ;;
        esac
        echo "[ncz] launcher -> $d/Android.desktop"
    done

    update-desktop-database "$appdir" 2>/dev/null || true
    gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
}

# NOT EXPOSED YET -- deliberately unreachable from `ncz install`.
#
# Waydroid installs and Android 13 does boot on Sky1, but only on llvmpipe:
# /dev/dri/renderD128 belongs to linlondp, a DISPLAY controller with no render
# engine, so every gbm-family gralloc fails to allocate and the hardware path is
# unavailable. The result is a software-rendered Android that is slow and, until
# the gralloc fallback was forced, crash-looped outright.
#
# Offering `ncz install android` in that state would hand a user a ~1 GB
# download, a Google account registration dance, and a poor experience -- and
# they would reasonably read it as a shipped feature rather than an experiment.
# The implementation is kept, verified as far as it goes, and stays here ready
# to be re-wired the moment hardware rendering works: the blocker is an arm64
# Android >= 14 base image for the CIX Mali blob, not this code.
#
# Re-enable by restoring the `android|waydroid)` case in ncz_install() and its
# line in the help text.

# ncz_install_zoder -- install zoder (ZeroClaw CLI for MNEMOS work history)
# from the public ncz-os/zoder GitHub release. The nightly tarball ships
# `zoder`, `zerocode`, `zeroclaw` binaries; we only stage `zoder` to
# /usr/local/bin/zoder (the others are agent runtimes that operators may
# install separately via `ncz agent install`). Both arches have a
# native build (x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu).
# The pinned nightly also publishes a per-binary sha256 in manifest.json;
# we re-verify the zoder binary after extraction and fail-loud on any
# mismatch (defence against a tampered release artifact).
#
# Config: drop a sample at /etc/nclawzero/zoder.conf with documented
# MNEMOS_URL/MNEMOS_TOKEN placeholders, NOT a populated value. Operators
# fill in MNEMOS_TOKEN with `source /etc/nclawzero/mnemos.env`. No fleet
# model routes, no internal endpoints, no secrets in the template.
ncz_install_zoder() {
    if ! [ "$(id -u)" = "0" ]; then
        echo "ncz install zoder: requires root (use sudo)" >&2
        exit 1
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        echo "ncz install zoder: curl, tar, and sha256sum are required" >&2
        exit 1
    fi
    # Architecture dispatch. The nightly tarballs are named by the rustc
    # target triple. Match the host arch against the known set. Anything
    # else (musl, darwin, etc.) is unsupported on NCZ-OS today and we fail
    # loud with the URL so the operator can roll their own.
    local arch arch_url arch_sha256
    case "$(uname -m)" in
        x86_64)
            arch='x86_64-unknown-linux-gnu'
            arch_url='https://github.com/ncz-os/zoder/releases/download/nightly/zoder-x86_64-unknown-linux-gnu.tar.gz'
            arch_sha256='b2ce794b0ee2dbd163672a4dfafc63582df48f41a288f1189ac26ccd6971e577'
            ;;
        aarch64)
            arch='aarch64-unknown-linux-gnu'
            arch_url='https://github.com/ncz-os/zoder/releases/download/nightly/zoder-aarch64-unknown-linux-gnu.tar.gz'
            arch_sha256='bcec547fe1f29447fd71284cae4b14ae8b92459b5a5988692f38a53277decfd0'
            ;;
        *)
            echo "ncz install zoder: unsupported arch '$(uname -m)' (NCZ-OS supports x86_64 / aarch64 linux-gnu)" >&2
            exit 1
            ;;
    esac
    local install_path=/usr/local/bin/zoder
    local tmp_dir; tmp_dir="$(mktemp -d -t ncz-zoder.XXXXXX)"
    local tarball="$tmp_dir/zoder.tar.gz"
    # 3 attempts, 2s apart. Releases are anonymous on GitHub.
    local got=0 attempt
    for attempt in 1 2 3; do
        if curl -fsSL --connect-timeout 8 --max-time 600 -o "$tarball" "$arch_url"; then
            got=1
            break
        fi
        echo "[ncz] zoder: download attempt $attempt/3 failed, sleeping 2s"
        sleep 2
    done
    if [ "$got" != "1" ]; then
        rm -rf "$tmp_dir"
        cat >&2 <<EOF
ncz install zoder: failed to fetch $arch_url after 3 attempts.

  This system is offline, or github.com is unreachable. zoder has no apt
  package — it ships only as a GitHub release asset. To come back online:

    sudo ncz install zoder
EOF
        exit 1
    fi
    local actual_tarball_sha
    actual_tarball_sha="$(sha256sum "$tarball" | awk '{print $1}')"
    if [ "$actual_tarball_sha" != "$arch_sha256" ]; then
        rm -rf "$tmp_dir"
        cat >&2 <<EOF
ncz install zoder: tarball sha256 mismatch (refusing to install).

  expected: $arch_sha256
  got:      $actual_tarball_sha

  The upstream release has rotated; re-roll ncz (post-install/46-ncz-cli.sh,
  function ncz_install_zoder, the arch_sha256 in each case arm) and re-run.
EOF
        exit 1
    fi
    # Extract just the zoder binary; the tarball ships zoder/ + zerocode/ +
    # zeroclaw/ under a zoder-<target-triple>/ directory.
    local arch_dir="zoder-${arch}"
    local extract_dir="$tmp_dir/extract"
    mkdir -p "$extract_dir"
    if ! tar -xzf "$tarball" -C "$extract_dir" "$arch_dir/zoder" "$arch_dir/manifest.json" 2>/dev/null; then
        rm -rf "$tmp_dir"
        echo "ncz install zoder: tar extraction failed" >&2
        exit 1
    fi
    if [ ! -f "$extract_dir/$arch_dir/zoder" ] || [ ! -f "$extract_dir/$arch_dir/manifest.json" ]; then
        rm -rf "$tmp_dir"
        echo "ncz install zoder: tarball did not contain $arch_dir/zoder (layout drift)" >&2
        exit 1
    fi
    # Re-verify the inner binary against the per-binary sha256 in manifest.json
    # (defence against a corrupted tarball or a partial download that passed
    # the outer hash because curl also verified TLS).
    local expected_zoder_sha
    expected_zoder_sha="$(python3 -c "import json; print(json.load(open('$extract_dir/$arch_dir/manifest.json'))['binaries']['zoder'])" 2>/dev/null || true)"
    if [ -n "$expected_zoder_sha" ]; then
        local actual_zoder_sha
        actual_zoder_sha="$(sha256sum "$extract_dir/$arch_dir/zoder" | awk '{print $1}')"
        if [ "$actual_zoder_sha" != "$expected_zoder_sha" ]; then
            rm -rf "$tmp_dir"
            cat >&2 <<EOF
ncz install zoder: inner zoder binary sha256 mismatch (refusing to install).

  expected: $expected_zoder_sha
  got:      $actual_zoder_sha

  The tarball hash matches but the inner zoder binary does not — possible
  tarball corruption, partial download, or upstream release re-tar.
EOF
            exit 1
        fi
    fi
    install -D -m 0755 "$extract_dir/$arch_dir/zoder" "$install_path"
    # Stage the manifest alongside, NOT under /usr/local. Operators can
    # inspect it for the engine SHA + upstream SHA + run link.
    install -d -m 0755 /etc/zoder
    install -m 0644 "$extract_dir/$arch_dir/manifest.json" /etc/zoder/manifest.json
    rm -rf "$tmp_dir"
    # Drop a sample at /etc/nclawzero/zoder.conf. PUBLIC-SAFE wording:
    # documented placeholders, no fleet model routes, no internal endpoints.
    local zoder_conf=/etc/nclawzero/zoder.conf
    install -d -m 0750 -g nclawzero /etc/nclawzero 2>/dev/null || true
    if [ ! -f "$zoder_conf" ]; then
        cat > "$zoder_conf" <<'ZODER_CONF'
# /etc/nclawzero/zoder.conf — environment overrides for `ncz install zoder`.
#
# zoder reads MNEMOS_URL + MNEMOS_TOKEN from the environment (it is a CLI, not
# a daemon — no config file is parsed by zoder itself). Operators populate
# this file via `set -a; source /etc/nclawzero/zoder.conf; set +a; zoder ...`
# or by exporting the values inline. The host-installed MNEMOS token lives
# at /etc/nclawzero/mnemos.env — the canonical way to wire zoder is:
#
#   set -a; source /etc/nclawzero/mnemos.env; set +a
#   export MNEMOS_URL="$MNEMOS_BASE_URL"
#   unset MNEMOS_USER  # zoder reads only MNEMOS_TOKEN + MNEMOS_URL
#   zoder -h
#
# NO fleet model routes, NO internal endpoints, NO Anthropic (project ban).
# To add provider credentials see /etc/nclawzero/agent-env.sample.
ZODER_CONF
        chmod 0640 "$zoder_conf" 2>/dev/null || true
        chgrp nclawzero "$zoder_conf" 2>/dev/null || true
    fi
    # Smoke test: zoder must print its version.
    local out
    if ! out="$("$install_path" --version 2>&1)"; then
        echo "[ncz] zoder: installed at $install_path but '--version' failed" >&2
        echo "  output: $out" >&2
        exit 1
    fi
    echo "[ncz] zoder installed: $install_path"
    echo "  release:   nightly ($arch)"
    echo "  tarball:   $arch_url"
    echo "  sha256:    $arch_sha256 (verified)"
    [ -f /etc/zoder/manifest.json ] && \
        echo "  manifest:  /etc/zoder/manifest.json (engine + upstream SHAs)"
    echo "  config:    $zoder_conf (MNEMOS_URL + MNEMOS_TOKEN placeholders)"
    echo "  smoke:     zoder --version -> $(echo "$out" | head -1)"
    echo
    echo "Next: source the MNEMOS credentials and try a search:"
    echo "  set -a; source /etc/nclawzero/mnemos.env; set +a"
    echo "  export MNEMOS_URL=\"\$MNEMOS_BASE_URL\""
    echo "  zoder search 'test query'"
}

# ncz_install_zeroclaw -- convenience alias for `ncz agent install zeroclaw`.
# Keeps `ncz install <thing>` ergonomic for the three primary agents the
# orchestrator uses (zeroclaw + mnemos + zoder). Everything else stays under
# `ncz agent ...`.
ncz_install_zeroclaw() {
    if ! [ "$(id -u)" = "0" ]; then
        echo "ncz install zeroclaw: requires root (use sudo)" >&2
        exit 1
    fi
    echo "[ncz] install zeroclaw -> delegating to ncz agent install zeroclaw"
    ncz_agent install zeroclaw
}
ncz_install_android() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ncz install android: run as root (sudo ncz install android)" >&2
        exit 1
    fi

    if [ ! -e /dev/binderfs ] && [ ! -e /dev/binder ] && \
       ! grep -qw binder /proc/filesystems 2>/dev/null; then
        echo "ncz install android: this kernel has no binder support." >&2
        echo >&2
        echo "  Waydroid needs CONFIG_ANDROID_BINDER_IPC and" >&2
        echo "  CONFIG_ANDROID_BINDERFS. Checked and not found:" >&2
        echo "    /dev/binderfs, /dev/binder, and 'binder' in /proc/filesystems" >&2
        echo >&2
        echo "  Running kernel: $(uname -r)" >&2
        echo "  Binder is enabled from the 7.2 kernel built after 2026-08-18." >&2
        echo "  Update the kernel first:  sudo apt update && sudo apt install --only-upgrade linux-image-cixmini" >&2
        exit 1
    fi
    echo "[ncz] binder present"

    local remv

    # WHERE WAYDROID COMES FROM: the DISTRIBUTION first, their repo only as a
    # fallback.
    #
    # This used to go straight to repo.waydro.id. That broke outright on
    # NCZ-OS (measured on the Sky1 test board 2026-08-18):
    #
    #     [!] Distribution "forky" is not supported
    #
    # Their installer matches the codename against a fixed whitelist which ends
    # at trixie/sid; forky, which is what 26.7 is built on, is not in it, so the
    # script exits and takes `ncz install android` down with it. It will break
    # again on the next Debian codename, so codename-matching cannot be the
    # primary path.
    #
    # Debian forky already carries waydroid 1.6.3+ds-2 with lxc and
    # python3-gbinder, and that is what actually ran Android 13 here. Prefer it:
    # it needs no third-party key, no `curl | bash` as root, and it tracks the
    # release we are on. The original concern -- that a distro package can lag
    # the OTA images -- is real but is a version-skew risk, not the hard failure
    # that hardcoding their whitelist guarantees.
    local waydroid_candidate
    waydroid_candidate=$(apt-cache policy waydroid 2>/dev/null \
        | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -1)

    if [ -n "$waydroid_candidate" ] && [ "$waydroid_candidate" != "(none)" ]; then
        echo "[ncz] installing waydroid $waydroid_candidate from the distribution"
    else
        echo "[ncz] no distro waydroid package — falling back to the Waydroid repository"

        remv=$(apt-get install -y -s curl ca-certificates 2>/dev/null | grep -c '^Remv' || true)
        remv=$(printf '%s' "$remv" | head -1)
        if [ "${remv:-1}" != "0" ]; then
            echo "ncz install android: refusing — apt wants to REMOVE ${remv} package(s)" >&2
            exit 1
        fi
        apt-get install -y curl ca-certificates >/dev/null || {
            echo "ncz install android: could not install curl/ca-certificates" >&2; exit 1; }

        # Their official installer. This pipes a remote script into a root
        # shell, which is the mechanism the project publishes; it is called out
        # here rather than performed quietly, because a reader deserves to know
        # that is what "the official install" means.
        echo "[ncz] adding the Waydroid repository (runs https://repo.waydro.id as root)"
        if ! curl -s https://repo.waydro.id | bash; then
            echo "ncz install android: adding the Waydroid repository failed" >&2
            echo >&2
            echo "  Their installer only accepts a fixed list of codenames. If it said" >&2
            echo "  'Distribution \"...\" is not supported', this release is newer than" >&2
            echo "  that list and there is no distro package to fall back to." >&2
            exit 1
        fi
        apt-get update -qq || true
    fi

    remv=$(apt-get install -y -s waydroid 2>/dev/null | grep -c '^Remv' || true)
    remv=$(printf '%s' "$remv" | head -1)
    if [ "${remv:-1}" != "0" ]; then
        echo "ncz install android: refusing — apt wants to REMOVE ${remv} package(s)" >&2
        exit 1
    fi
    if ! apt-get install -y waydroid; then
        echo "ncz install android: installing waydroid failed" >&2
        exit 1
    fi

    # GAPPS rather than VANILLA, so the Play Store is present. The system_type
    # options are VANILLA, FOSS and GAPPS; VANILLA is the default and has no
    # Google apps at all.
    #
    # Downloads the LineageOS system and vendor images from the official OTA
    # server, roughly 1 GB. This is one of the few parts of NCZ-OS that
    # genuinely needs the network, and it is said plainly rather than
    # discovered halfway through.
    if [ -f /var/lib/waydroid/waydroid.cfg ]; then
        echo "[ncz] waydroid already initialised — leaving the existing images alone"
        echo "      (re-initialise with: sudo waydroid init -s GAPPS -f)"
    else
        echo "[ncz] downloading the Android images with Google Apps (~1 GB)"
        if ! waydroid init -s GAPPS; then
            echo "ncz install android: waydroid init failed" >&2
            echo "  Retry with: sudo waydroid init -s GAPPS -f" >&2
            exit 1
        fi
    fi

    ncz_android_gpu_quirk

    systemctl enable --now waydroid-container.service 2>/dev/null || \
        echo "[ncz] note: could not enable waydroid-container.service"

    ncz_android_launcher

    cat <<'DONE'

Waydroid installed, with Google Apps.

  waydroid show-full-ui     the full Android UI in a window
  waydroid app list         list installed Android apps
  waydroid session stop     stop the session

REGISTER THE DEVICE BEFORE THE PLAY STORE WILL WORK.

A GAPPS image is not a certified Google device, so Play Services refuses to
sign in until the device ID is registered against your Google account. This is
a manual step and there is no way around it:

  1. Start Android once so the ID exists:
         waydroid show-full-ui

  2. Read the device ID:
         sudo waydroid shell -- sh -c \
           "sqlite3 /data/data/*/*/gservices.db \
            'select value from main where name = \"android_id\";'"

  3. Register that number at:
         https://www.google.com/android/uncertified

  4. Give Google a few minutes to apply it, then restart the session:
         waydroid session stop

Until that is done the Play Store will report the device as uncertified.
DONE
}

ncz_install() {
    local component="${1:-help}"
    case "$component" in
        help|--help|-h)
            cat <<MSG
Usage: ncz install <component>

Components:
  mnemos     Install + start the MNEMOS memory server (REST on :5002, MCP
             HTTP/SSE on :5004, OpenAI-compatible gateway, sqlite-backed).
             Pulls the embedder model (nomic-embed-text-v1.5 Q8, 768-dim) to
             /opt/ncz/models if absent. Backfills memory_embeddings from
             memories.embedding so search works on first install.
  zeroclaw   Convenience alias for 'ncz agent install zeroclaw'.
  zoder      Download + install zoder (ZeroClaw work-history CLI) from
             the public ncz-os/zoder nightly release. Pinned version +
             sha256. Idempotent. Config template at
             /etc/nclawzero/zoder.conf (no secrets, no fleet routes).
  nemoclaw   Pull + start NVIDIA NemoClaw OpenShell sandbox runtime.

Every component is a systemd (quadlet) service and is safe to re-run. To stop
or remove one: 'systemctl disable --now <name>.service', drop the quadlet under
/etc/containers/systemd/ and (for MNEMOS) 'podman volume rm mnemos-data';
agents: 'ncz agent uninstall <name>'. See docs/NCZ-AGENT-STACK.md.
MSG
            ;;
        mnemos)
            ncz_install_mnemos
            ;;
        zeroclaw)
            ncz_install_zeroclaw
            ;;
        zoder)
            ncz_install_zoder
            ;;
        nemoclaw)
            ncz_install_nemoclaw
            ;;
        # android|waydroid) INTENTIONALLY NOT WIRED UP -- see ncz_install_android.
        *)
            echo "ncz install: unknown component '$component' (expected: mnemos | zeroclaw | zoder | nemoclaw)" >&2
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
            # vulkaninfo --summary emits "deviceName = <vendor>..." lines,
            # but the leading whitespace differs across versions: some
            # builds indent with a tab ("\tdeviceName  = ..."), some
            # don't (column 0). The earlier awk `/^deviceName.../` only
            # matched the un-indented flavour and silently produced an
            # empty device list on the indented flavour (verified on
            # the amd64 test host with Mesa 21.x: 0 rows matched, status row
            # then read "(no deviceName found in vulkaninfo --summary)"
            # which made `ncz status` look like the Vulkan driver was
            # missing even when `vulkaninfo --summary` clearly had rows
            # in it). Anchor on either flavour + the older `deviceName:`
            # form some pre-1.3 vulkaninfo shipped.
            local devs
            devs="$(vulkaninfo --summary 2>/dev/null | awk '
                /^[ \t]*deviceName[ \t]*=/ { sub(/^[ \t]*deviceName[ \t]*=[ \t]*/, ""); print; next }
                /^[ \t]*deviceName:/ { sub(/^[ \t]*deviceName:[ \t]*/, ""); print; next }
            ' | sed 's/[[:space:]]*$//' | awk 'NF' | head -3 | paste -sd, -)"
            if [ -n "$devs" ]; then
                printf '%-26s %s\n' 'Vulkan devices:' "$devs"
            else
                # vulkaninfo can produce no deviceName output for many
                # reasons: no Vulkan ICD installed, no permission to read
                # /dev/dri/renderD*, the loader returning zero devices, or
                # vulkaninfo itself being too old to know the summary format.
                # State what we observed, not a guessed root cause.
                printf '%-26s %s\n' 'Vulkan devices:' '(no deviceName found in vulkaninfo --summary)'
            fi
        fi
    else
        printf '%-26s %s\n' 'GPU /dev/dri/renderD128:' "absent"
    fi
    if [ -d /opt/ncz/models ]; then
        local ncix ngguf
        ncix="$(find /opt/ncz/models -name '*.cix' 2>/dev/null | wc -l | tr -d ' ')"
        ngguf="$(find /opt/ncz/models -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ')"
        printf '%-26s %s .cix / %s .gguf files in /opt/ncz/models\n' 'models:' "$ncix" "$ngguf"
    fi
    # MNEMOS embedder — same shape as the orchestrator expects on every host
    # (operator direction 2026-10-13, "embedder model + zoder + zeroclaw").
    # Read state from the active quadlet + MNEMOS /health so the operator can
    # tell at a glance which backend is active and whether the container is up.
    ncz_status_mnemos
    # zeroclaw + zoder — the other two components `ncz install` manages, so
    # `ncz status` reports all three managed components in one place.
    local zc='not-installed'
    if [ -f /etc/containers/systemd/zeroclaw.container ]; then
        zc="$(systemctl is-active zeroclaw.service 2>/dev/null || echo unknown)"
    fi
    printf '%-26s %s\n' 'zeroclaw:' "$zc"
    if command -v zoder >/dev/null 2>&1; then
        printf '%-26s %s\n' 'zoder:' "$(zoder --version 2>/dev/null | head -1)"
    else
        printf '%-26s %s\n' 'zoder:' 'not-installed'
    fi
}

# ncz_status_mnemos -- print MNEMOS embedder / service state. Reads the active
# quadlet for MNEMOS_EMBED_BACKEND + MNEMOS_EMBED_MODEL_PATH (the knobs we
# stage), and probes MNEMOS /health for the actual embedder the process picked.
# Best-effort: every individual probe is a separate sentence, so a missing
# container or no-auth path is reported, not fatal.
ncz_status_mnemos() {
    local active=/etc/containers/systemd/mnemos.container
    local embed_backend='' embed_model='' embed_dim=''
    # Important: each pipeline ends in `|| true` so a missing `Environment=`
    # line in the quadlet (which makes grep exit 1) does NOT take down
    # the whole status path under `set -euo pipefail`. grep -E alone is
    # also wrapped in `|| true` so the assignment is unconditionally
    # non-failing. Without this the function returns silently on every
    # host whose quadlet hasn't been staged yet.
    if [ -f "$active" ]; then
        embed_backend="$(grep -E '^Environment=MNEMOS_EMBED_BACKEND=' "$active" 2>/dev/null | head -1 | sed -E 's/^Environment=MNEMOS_EMBED_BACKEND=//' || true)"
        embed_model="$(grep -E '^Environment=MNEMOS_EMBED_MODEL_PATH=' "$active" 2>/dev/null | head -1 | sed -E 's/^Environment=MNEMOS_EMBED_MODEL_PATH=//' || true)"
        if [ -z "$embed_model" ]; then
            embed_model="$(grep -E '^Environment=MNEMOS_EMBED_CIX_MODEL_PATH=' "$active" 2>/dev/null | head -1 | sed -E 's/^Environment=MNEMOS_EMBED_CIX_MODEL_PATH=//' || true)"
        fi
        [ -z "$embed_backend" ] && embed_backend='llamacpp (default)'
    else
        embed_backend='(quadlet not staged — run ncz install mnemos)'
    fi
    # Service state — derive from systemctl without requiring root (systemctl
    # is-active is queryable for non-root as long as the service is reachable
    # via the user bus).
    local svc='(not installed)'
    if command -v systemctl >/dev/null 2>&1; then
        svc="$(systemctl is-active mnemos.service 2>/dev/null || echo unknown)"
    fi
    # If the quadlet doesn't set MNEMOS_EMBED_MODEL_PATH but the container is
    # running, probe the live process env via /proc/<pid>/environ. Rootful
    # `podman inspect` sees the system container when status runs as root; a
    # non-root shell uses the rootless store and cannot, so we fall back to the
    # image's canonical in-process model path below rather than leaving the
    # active backend anonymous.
    if [ -z "$embed_model" ] && [ "$svc" = "active" ] && command -v podman >/dev/null 2>&1; then
        local mnemos_pid
        mnemos_pid="$(podman inspect mnemos --format '{{.State.Pid}}' 2>/dev/null || true)"
        if [ -n "$mnemos_pid" ] && [ -r "/proc/$mnemos_pid/environ" ]; then
            embed_model="$(tr '\0' '\n' < "/proc/$mnemos_pid/environ" 2>/dev/null | grep -a '^MNEMOS_EMBED_MODEL_PATH=' | head -1 | sed 's/^MNEMOS_EMBED_MODEL_PATH=//' || true)"
        fi
        # mnemos-enterprise bakes the embedder model in-process at a fixed path;
        # report that canonical path when the live env is not readable.
        if [ -z "$embed_model" ]; then
            embed_model='(in-image) /opt/mnemos/models/nomic-embed-text-v1.5.Q8_0.gguf'
        fi
    fi
    # /health probes the live container. We do NOT need to authenticate to
    # /health (MNEMOS exposes it anonymously) so this works as user ncz too.
    local health='(service inactive)'
    if [ "$svc" = "active" ] && command -v curl >/dev/null 2>&1; then
        health="$(curl -fsS --max-time 2 http://127.0.0.1:5002/health 2>/dev/null | head -c 200 || echo '(unreachable)')"
    fi
    # Dimension comes from the MODEL identity, not the file suffix alone. The
    # GGUF is nomic-embed-text-v1.5 Q8 (768-dim). The .cix NPU graph is the
    # SAME model at 768 dimensions — its "256" is the fixed max_tokens
    # (sequence length), NOT the embedding width, so it must not be reported
    # as the dimension.
    if [ -n "$embed_model" ]; then
        case "$embed_model" in
            *.gguf) embed_dim=768 ;;
            *.cix)  embed_dim=768 ;;
            *nomic-embed-text*) embed_dim=768 ;;
            *)      embed_dim='?' ;;
        esac
    fi
    printf '%-26s %s\n' 'mnemos service:' "$svc"
    printf '%-26s %s\n' 'mnemos embedder:' "${embed_backend:-unknown}${embed_dim:+ (dim=$embed_dim)}"
    [ -n "$embed_model" ] && printf '%-26s %s\n' 'mnemos model:' "$embed_model"
    # MCP transport. Served by the api+mcp supervisor on :5004 once the install
    # has provisioned MNEMOS_MCP_TOKEN (written to the quadlet + mnemos.env).
    local mcp_state='disabled (no MNEMOS_MCP_TOKEN)'
    if [ -s /etc/nclawzero/mnemos-mcp-token ] || \
       { [ -f "$active" ] && grep -q '^Environment=MNEMOS_MCP_TOKEN=' "$active" 2>/dev/null; }; then
        mcp_state='enabled (:5004)'
    fi
    printf '%-26s %s\n' 'mnemos mcp:' "$mcp_state"
    printf '%-26s %s\n' 'mnemos health:' "$health"
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
