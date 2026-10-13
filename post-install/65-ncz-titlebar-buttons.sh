#!/bin/bash
# 65-ncz-titlebar-buttons.sh -- every window has minimize, maximize and close
# buttons by default, for every user, on both architectures.
#
# WHERE THE BUTTONS COME FROM. Every window-button path in the Singularity
# desktop reads the same key, org.gnome.desktop.wm.preferences button-layout:
#   * libsingularity CSD apps: the static titlebar (Toolbar.resolve_button_layout)
#     and the floating hover controls (HoverControls) both read it;
#   * labwc server-side decorations (Chromium, foot, GTK apps with CSD off):
#     the shell's ShortcutManager translates it into rc.xml <titlebar><layout>;
#   * GTK3/GTK4 client-side decorations: the shell propagates it as
#     gtk-decoration-layout (xsettingsd), and the settings portal exposes it.
# The upstream schema default is 'appmenu:close' (close only). Desktop
# Settings' minimize/maximize switches write the same key.
#
# WHAT THIS HOOK DOES. Two GSettings DEFAULT overrides (schema overrides, so
# they apply to every existing and future user and to the greeter/session
# alike; no dconf key is written, so a user's own choice in Settings wins):
#
#   (a) org.gnome.desktop.wm.preferences button-layout =
#       'appmenu:minimize,maximize,close', written next to every installed
#       copy of that schema (/usr/share/glib-2.0/schemas from
#       gsettings-desktop-schemas, and the Singularity schema dir if the
#       payload carries its own copy).
#   (b) dev.sinty.desktop legacy-titlebar = true: the classic static titlebar
#       with inline buttons instead of hover-only controls.
#
# WHY IT SURVIVES UPGRADES. The override files are not owned by any package,
# so dpkg never removes or replaces them. Schema directories are recompiled
# with the overrides included: /usr/share/glib-2.0/schemas by libglib2.0's
# dpkg trigger whenever a schema package changes, and the Singularity dir by
# the payload package's postinst on every install or upgrade.
#
# Each override is validated with glib-compile-schemas --strict --dry-run
# before it is installed; a stale schema or a missing key skips that override
# (logged) instead of breaking the schema directory. Idempotent. Never fails
# the install (exit 0). build/test-titlebar-buttons.sh is the regression test.
#
# Test seams (build/test-titlebar-buttons.sh):
#   NCZ_TITLEBAR_SCHEMA_DIR        Singularity schema dir
#   NCZ_TITLEBAR_GNOME_SCHEMA_DIRS space-separated dirs searched for the
#                                  org.gnome.desktop.wm.preferences schema
#                                  (default in a test: the Singularity dir only)
#   (when either is set the hook does not run glib-compile-schemas for real)
set -u

SCHEMADIR="${NCZ_TITLEBAR_SCHEMA_DIR:-/opt/singularity/share/glib-2.0/schemas}"
TEST_MODE=0
if [ -n "${NCZ_TITLEBAR_SCHEMA_DIR:-}" ] || [ -n "${NCZ_TITLEBAR_GNOME_SCHEMA_DIRS:-}" ]; then
    TEST_MODE=1
    # A test never falls back to the host's real /usr/share schema dir.
    GNOME_DIRS="${NCZ_TITLEBAR_GNOME_SCHEMA_DIRS:-$SCHEMADIR}"
else
    GNOME_DIRS="/usr/share/glib-2.0/schemas $SCHEMADIR"
fi

BUTTON_LAYOUT="appmenu:minimize,maximize,close"
OVERRIDE_NAME="99-ncz-titlebar.gschema.override"

echo "[65] NCZ titlebar: minimize, maximize and close on every window"

if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    echo "[65]   WARN: glib-compile-schemas missing; cannot validate the overrides, not installing them" >&2
    exit 0
fi

# install_override DIR BODY -- validate BODY against DIR's schemas (merged with
# any override already in DIR, minus a previous copy of ours) and install it.
install_override() {
    local dir="$1" body="$2" scratch rc=0
    scratch=$(mktemp -d) || return 1
    cp "$dir"/*.gschema.xml "$scratch"/ 2>/dev/null
    cp "$dir"/*.enums.xml "$scratch"/ 2>/dev/null
    cp "$dir"/*.gschema.override "$scratch"/ 2>/dev/null
    rm -f "$scratch/$OVERRIDE_NAME"
    printf '%s\n' "$body" > "$scratch/$OVERRIDE_NAME"
    if glib-compile-schemas --strict --dry-run "$scratch" >"$scratch/compile.log" 2>&1; then
        printf '%s\n' "$body" > "$dir/$OVERRIDE_NAME"
        chmod 0644 "$dir/$OVERRIDE_NAME"
        if [ "$TEST_MODE" = 0 ]; then
            glib-compile-schemas "$dir" 2>&1 | sed 's/^/[65]   /'
        fi
    else
        echo "[65]   WARN: override does not compile against $dir; not installing it:" >&2
        sed 's/^/[65]     /' "$scratch/compile.log" >&2
        rc=1
    fi
    rm -rf "$scratch"
    return "$rc"
}

# has_key DIR SCHEMA_FILE KEY TYPE
has_key() {
    [ -f "$1/$2" ] && grep -qE "<key name=\"$3\" type=\"$4\"" "$1/$2"
}

# (a) button layout. The Singularity dir and /usr/share are distinct dirs;
# collect each dir that carries the wm.preferences schema once.
seen=" "
installed_layout=0
for dir in $GNOME_DIRS; do
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    has_key "$dir" org.gnome.desktop.wm.preferences.gschema.xml button-layout s || continue
    BODY="[org.gnome.desktop.wm.preferences]
button-layout='$BUTTON_LAYOUT'"
    # The Singularity dir may also get the desktop key below; build the full
    # body for that dir there instead.
    if [ "$dir" = "$SCHEMADIR" ] && has_key "$SCHEMADIR" dev.sinty.desktop.gschema.xml legacy-titlebar b; then
        continue
    fi
    if install_override "$dir" "$BODY"; then
        echo "[65]   button-layout default = '$BUTTON_LAYOUT' via $dir/$OVERRIDE_NAME"
        installed_layout=1
    fi
done

# (b) classic titlebar default in the Singularity schema dir (plus the button
# layout when that dir carries its own wm.preferences schema).
if has_key "$SCHEMADIR" dev.sinty.desktop.gschema.xml legacy-titlebar b; then
    BODY="[dev.sinty.desktop]
legacy-titlebar=true"
    if has_key "$SCHEMADIR" org.gnome.desktop.wm.preferences.gschema.xml button-layout s; then
        BODY="$BODY

[org.gnome.desktop.wm.preferences]
button-layout='$BUTTON_LAYOUT'"
    fi
    if install_override "$SCHEMADIR" "$BODY"; then
        echo "[65]   legacy-titlebar default = true via $SCHEMADIR/$OVERRIDE_NAME"
        case "$BODY" in *button-layout*) installed_layout=1 ;; esac
    fi
elif [ -f "$SCHEMADIR/dev.sinty.desktop.gschema.xml" ]; then
    echo "[65]   legacy-titlebar key absent in the desktop schema; classic titlebar default skipped"
else
    echo "[65]   dev.sinty.desktop schema not installed; classic titlebar default skipped"
fi

if [ "$installed_layout" = 0 ]; then
    echo "[65]   WARN: no org.gnome.desktop.wm.preferences schema found in: $GNOME_DIRS; button-layout default not set" >&2
fi
exit 0
