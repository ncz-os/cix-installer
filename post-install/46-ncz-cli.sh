#!/bin/bash
# 46-ncz-cli.sh — install the ncz CLI under /usr/local/bin/ncz.
#
# r75 P5: foundational `ncz` command with `desktop {on,off,status}` as the
# first subcommand. Sets up the dispatch frame for future subcommands
# (`ncz install mnemos`, `ncz models pull`, `ncz agent install ...`)
# without locking us into a specific UX yet.
#
# Why bash not Rust: ncz at this stage is fleet-system glue — it's
# wrapping systemctl + apt + filesystem ops. A Rust port comes when the
# CLI surface stabilizes (likely r80+). Bash keeps the cixmini ISO size
# down and means the operator can read+edit the script in place.
#
# `ncz desktop` semantics:
#   on     -> set-default graphical.target + start the active display manager
#   off    -> set-default multi-user.target + stop display manager
#   status -> print current default target + DM state
# Persists across reboots (set-default writes to /etc/systemd/system).
#
# RUNS INSIDE CHROOT (via run-all.sh). All paths are relative to the
# installed system root (no /target/ prefix).
set -euo pipefail

echo "[46] installing ncz CLI"

install -D -m 0755 /dev/stdin /usr/local/bin/ncz <<'NCZ'
#!/bin/bash
# ncz — nclawzero operator CLI.
# Subcommands: desktop {on|off|status}, version, help
# Future: install <component>, models pull, agent {install|list|enable|disable}
set -euo pipefail

readonly NCZ_VERSION="0.1.0"

ncz_help() {
    cat <<HELP
ncz — nclawzero operator CLI ($NCZ_VERSION)

Usage: ncz <subcommand> [args]

Subcommands:
  desktop on        Enable graphical login (set-default graphical.target,
                    start the configured display manager).
  desktop off       Drop to multi-user (headless) mode. Set-default
                    multi-user.target, stop display manager. Reversible
                    with 'ncz desktop on'. SSH/network stays up.
  desktop status    Show current default target + display-manager state.
  version           Print version.
  help              Show this help.

For server-class deploys (Magnetar SKU), 'ncz desktop off' is the
canonical post-install step. Reinhardt SKU ships graphical-by-default.
HELP
}

# --- desktop subcommand --------------------------------------------------

# Detect the active display-manager unit. Returns empty if none.
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

# --- main dispatch -------------------------------------------------------

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        desktop)        ncz_desktop "$@" ;;
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
