#!/bin/bash
# 46-ncz-cli.sh — install /usr/local/bin/ncz + /opt/cix/npu_embed_v2.py.
#
# r75 P5/P7 (#115/#99): foundational `ncz` command with subcommands:
#   * desktop {on,off,status}      — graphical/multi-user toggle (P5)
#   * models pull                  — fetch cixtech/ai_model_hub_25_Q3 LFS
#   * install mnemos               — wire MNEMOS server with NPU embedder
#   * version, help
#
# `models pull` and `install mnemos` are STUBS in r75 — they print clear
# "not yet implemented; see task #99/#98" messages and exit 2. This locks
# the CLI surface so users + scripts can rely on the command names; the
# actual fetch/wire logic lands in r76+ once the LFS pull strategy is
# settled (cixtech raw .git LFS over HTTPS vs ARGONAS-mirror local pull).
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
#   install mnemos           — wire MNEMOS + NPU embedder backend (stub r75)
#   version, help
set -euo pipefail

readonly NCZ_VERSION="0.2.0"
readonly NCZ_MODELS_DIR="/opt/ncz/models"
readonly NCZ_CIX_LIB_DIR="/opt/cix"

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
  install mnemos        Wire MNEMOS server + Cix NPU embedder backend
                        (STUB in r75 — see task #98).
  status                Print system summary: ncz version, BUILD_VARIANT,
                        kernel, default-target, NPU + GPU presence.
  version               Print version.
  help                  Show this help.

For server-class deploys (Magnetar SKU), 'ncz desktop off' is the
canonical post-install step. Reinhardt SKU ships graphical-by-default.
HELP
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
        systemctl enable "$dm"
        systemctl start "$dm"
        echo "[ncz] $dm started"
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

ncz_install() {
    local component="${1:-help}"
    case "$component" in
        mnemos)
            cat >&2 <<MSG
ncz install mnemos — STUB (r75)

Will:
  1. Pull bge-small-zh_256.cix via 'ncz models pull' if not present
  2. Verify libnoe.so + cix-noe-umd userspace
  3. Start the NPU embedder server (FastAPI) on :5040 with content-hash cache
  4. Pull MNEMOS server container (mnemos-os/mnemos image)
  5. Configure MNEMOS to use the local NPU embedder (INFERENCE_EMBED_HOST)

Body deferred to r76 (depends on 'models pull' body). See task #98.

For now, on a system with libnoe.so + .cix model in place, the wrapper
at /opt/cix/npu_embed_v2.py can be imported directly:

    python3 -c "
    import sys; sys.path.insert(0, '/opt/cix')
    from npu_embed_v2 import NPUEmbedder
    e = NPUEmbedder('/opt/ncz/models/.../bge-small-zh_256.cix',
                    '/usr/share/cix/lib/libnoe.so')
    v = e.embed('hello cix')
    print(v.shape, v[:5])
    "
MSG
            exit 2
            ;;
        *)
            echo "ncz install: unknown component '$component' (expected mnemos)" >&2
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
    printf '%-26s %s\n' 'NPU /dev/aipu0:' "$([ -e /dev/aipu0 ] && echo present || echo absent)"
    printf '%-26s %s\n' 'NPU /dev/cix-noe0:' "$([ -e /dev/cix-noe0 ] && echo present || echo absent)"
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
