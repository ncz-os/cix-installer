#!/bin/bash
# 65-ncz-titlebar-buttons.sh -- NCZ image ships classic titlebar with min/max
# buttons on every window (operator 2026-10-13: "can our next image include
# minimize and maximize buttons on windows? I'm not sure why Mirko has them
# turned off.").
#
# THE BUG (per the brief's pre-verified finding). Upstream Singularity
# (singularityos-lab) renders window controls as floating "hover bubble"
# controls over the window content for libsingularity CSD apps. The
# `dev.sinty.desktop.legacy-titlebar` boolean (default false; schema text
# "Show a classic static titlebar with inline buttons instead of the
# floating hover window controls. Ignored when force-ssd is enabled.")
# exposes a classic titlebar path for those CSD apps. The labwc SSD layout
# written into ~/.config/labwc/rc.xml -- used by Chromium, foot, and any
# GTK app with force-ssd=true (CSD off) -- is sourced from
# `org.gnome.desktop.wm.preferences.button-layout`, whose shipped default
# is `appmenu:close`, which translates to `menu:close` (close-only).
# Setting legacy-titlebar=true did not change the SSD layout: the legacy
# key is NOT wired to write_labwc_rc_xml or apply_gtk_decoration_layout.
# So: libsingularity CSD apps can get classic; everything else (Chromium,
# foot, GTK SSD) stays close-only, by upstream design.
#
# THE FIX (NCZ image only; upstream default unchanged). Two pieces.
#
#   (a) Default override: write 99-ncz-titlebar.gschema.override into the
#       Singularity schema dir so legacy-titlebar=true is the EFFECTIVE
#       default for a fresh user. A user who later disables the toggle
#       still gets what they picked (only DEFAULTS change; no dconf key
#       is written, so an explicit user choice wins).
#
#   (b) Downstream patch (assets/singularity/patches/singularity-shell/
#       0020-titlebar-buttons-when-legacy.patch, applied by
#       build/singularity-pins.sh check-patches against the pinned commit):
#       when legacy-titlebar is on, translate_button_layout() returns
#       `menu:iconify,max,close` (the GNOME `appmenu:minimize,maximize,close`
#       round-tripped through translate_buttons()) and apply_gtk_decoration_layout()
#       uses the same layout for GTK4 CSD windows and the xsettingsd
#       daemon. The settings.changed["legacy-titlebar"] listener re-renders
#       rc.xml and the GTK layout, mirroring the existing button-layout
#       listener. Upstream default (legacy-titlebar=false) is unchanged:
#       SSD layout still follows GNOME's button-layout. The patch is a
#       generic helper, no NCZ paths or naming, and is the only candidate
#       Mirko-respecting change.
#
# Stage 2 (the payload deb rebuild) carries the patch; this hook only
# needs to land the gschema default. The hook validates the override
# against glib-compile-schemas (--strict --dry-run) before installing it,
# so a stale schema or a typo aborts the install cleanly (override is
# simply not written). Idempotent. Never fails the install (exit 0).
#
# Test seam (build/test-titlebar-buttons.sh):
#   NCZ_TITLEBAR_SCHEMA_DIR  override the Singularity schema dir
set -u

SCHEMADIR="${NCZ_TITLEBAR_SCHEMA_DIR:-/opt/singularity/share/glib-2.0/schemas}"
DESKTOP_SCHEMA="$SCHEMADIR/dev.sinty.desktop.gschema.xml"
OVERRIDE="$SCHEMADIR/99-ncz-titlebar.gschema.override"

echo "[65] NCZ titlebar: classic titlebar + minimize/maximize on every window"

if [ ! -f "$DESKTOP_SCHEMA" ]; then
    echo "[65]   dev.sinty.desktop schema not installed; skipping"
    exit 0
fi

if ! grep -qE '<key name="legacy-titlebar" type="b"' "$DESKTOP_SCHEMA"; then
    echo "[65]   legacy-titlebar key absent in the schema; skipping (unpatched payload)"
    exit 0
fi

BODY="[dev.sinty.desktop]
legacy-titlebar=true"

if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    echo "[65]   WARN: glib-compile-schemas missing; cannot validate the override, not installing it" >&2
    exit 0
fi

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCHEMADIR"/*.gschema.xml "$SCRATCH"/ 2>/dev/null
cp "$SCHEMADIR"/*.enums.xml "$SCRATCH"/ 2>/dev/null
cp "$SCHEMADIR"/*.gschema.override "$SCRATCH"/ 2>/dev/null
printf '%s\n' "$BODY" > "$SCRATCH/99-ncz-titlebar.gschema.override"
if ! glib-compile-schemas --strict --dry-run "$SCRATCH" >"$SCRATCH/compile.log" 2>&1; then
    echo "[65]   WARN: override does not compile against the installed schema; not installing it:" >&2
    sed 's/^/[65]     /' "$SCRATCH/compile.log" >&2
    exit 0
fi

printf '%s\n' "$BODY" > "$OVERRIDE"
chmod 0644 "$OVERRIDE"
if [ -z "${NCZ_TITLEBAR_SCHEMA_DIR:-}" ]; then
    glib-compile-schemas "$SCHEMADIR" 2>&1 | sed 's/^/[65]   /' || true
fi
echo "[65]   legacy-titlebar default = true (effective on first login; user toggle still wins) via $OVERRIDE"
exit 0