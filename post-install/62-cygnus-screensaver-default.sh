#!/bin/bash
# 62-cygnus-screensaver-default.sh -- make the black hole saver in the Cygnus palette the
# default screensaver (operator decision 2026-10-04).
#
# The dev.ncz.screensaver schema is owned by the ncz-screensavers package. Its defaults are
# mode='random' with the stylized palette; the `cygnus` palette exists from ncz-screensavers
# 0.7.11 (blackhole-color-mode enum + `blackhole_gles3 --palette=cygnus`). This hook adds a
# GSettings override (mode='one', hack-id='blackhole_gles3', blackhole-color-mode='cygnus').
#
# SAFETY: an override that names an enum value the installed schema does not have makes
# glib-compile-schemas fail for EVERY schema on the system. So the override is validated
# first (`glib-compile-schemas --strict --dry-run` on a scratch copy of the schema dir) and is
# only installed when it compiles; otherwise the hook warns and leaves the system untouched.
#
# Idempotent. Never fails the install (exit 0 on every path).
# Test seam (build/test-screensaver-default.sh): NCZ_SS_SCHEMA_DIR.
set -u

DIR="${NCZ_SS_SCHEMA_DIR:-/usr/share/glib-2.0/schemas}"
SCHEMA_XML="$DIR/dev.ncz.screensaver.gschema.xml"
OVERRIDE="$DIR/99-ncz-cygnus-screensaver.gschema.override"

echo "[62] Cygnus black hole screensaver default"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in server|headless) echo "[62]   $VARIANT variant: no screensaver"; exit 0 ;; esac

if [ ! -f "$SCHEMA_XML" ]; then
    echo "[62]   dev.ncz.screensaver schema not installed (ncz-screensavers absent); skipping"
    exit 0
fi
if ! grep -q "nick=.cygnus." "$SCHEMA_XML"; then
    echo "[62]   WARN: installed schema has no 'cygnus' blackhole-color-mode (ncz-screensavers < 0.7.11); not setting the default" >&2
    rm -f "$OVERRIDE"
    exit 0
fi

BODY="[dev.ncz.screensaver]
mode='one'
hack-id='blackhole_gles3'
blackhole-color-mode='cygnus'"

# validate on a scratch copy before touching the real directory
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp "$DIR"/*.gschema.xml "$SCRATCH"/ 2>/dev/null
cp "$DIR"/*.gschema.override "$SCRATCH"/ 2>/dev/null
printf '%s\n' "$BODY" > "$SCRATCH/99-ncz-cygnus-screensaver.gschema.override"
if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    echo "[62]   WARN: glib-compile-schemas missing; cannot validate the override, not installing it" >&2
    exit 0
fi
if ! glib-compile-schemas --strict --dry-run "$SCRATCH" >"$SCRATCH/compile.log" 2>&1; then
    echo "[62]   WARN: override does not compile against the installed schema; not installing it:" >&2
    sed 's/^/[62]     /' "$SCRATCH/compile.log" >&2
    exit 0
fi

printf '%s\n' "$BODY" > "$OVERRIDE"
chmod 0644 "$OVERRIDE"
if [ -z "${NCZ_SS_SCHEMA_DIR:-}" ]; then
    glib-compile-schemas "$DIR" 2>&1 | sed 's/^/[62]   /' || true
fi
echo "[62]   default screensaver: blackhole_gles3, palette cygnus, mode one ($OVERRIDE)"
exit 0
