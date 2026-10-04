#!/bin/bash
# verify-gsettings-effective-defaults.sh -- the stale-gschemas.compiled gate.
#
# WHY THIS EXISTS (O6N, 2026-10-04)
# ---------------------------------
# /opt/singularity/share/glib-2.0/schemas/gschemas.compiled had an mtime (16:06)
# OLDER than the two overrides that configure it,
# 99-ncz-defaults.gschema.override and
# 99-zz-ncz-screensaver-plugin.gschema.override (mtime Sep 30). GLib only ever
# reads the compiled database, never the raw XML/override files, so the
# overrides never took effect:
#
#   GSETTINGS_BACKEND=memory gsettings get dev.sinty.desktop pinned-apps
#
# returned the stock first-party list (no browser, no terminal on the dock)
# from the installed compiled file, while compiling the SAME directory fresh
# returned the correct Cygnus list. The shell's session wrapper points
# GSETTINGS_SCHEMA_DIR at /opt/singularity/share/glib-2.0/schemas, so that
# stale file is exactly what the running shell reads.
#
# This gate cannot look at timestamps (mtime is not a reliable ordering across
# a payload swap that preserves mtimes). It asks GLib for the EFFECTIVE default
# of the configured keys twice -- once from the installed compiled database,
# once from a fresh compile of the same directory -- and fails if they differ.
# A stale compiled file is therefore caught no matter how it got that way.
#
# USAGE
#   verify-gsettings-effective-defaults.sh \
#       [--schema-dir DIR] [--id SCHEMA] [--key KEY]... \
#       [--expect-contains KEY SUBSTRING]... [--require]
#
#   default DIR  = /opt/singularity/share/glib-2.0/schemas (what the shell reads)
#   default id   = dev.sinty.desktop
#   default keys = pinned-apps enabled-plugins
#   --require    fail if the schema/gsettings tooling is absent (build gate);
#                without it, an absent schema dir is a clean SKIP (parity test)
#
# Exit 0 = installed compiled defaults equal a fresh compile (and any
#          --expect-contains matched); 1 = stale/drift; 2 = usage error.
#
# SELF-TEST: build/test-gsettings-effective-defaults.sh proves both directions.
set -uo pipefail

SCHEMA_DIR="/opt/singularity/share/glib-2.0/schemas"
SCHEMA_ID="dev.sinty.desktop"
KEYS=()
EXPECT=()   # "key<TAB>substring"
REQUIRE=0
TAB=$'\t'

while [ $# -gt 0 ]; do
    case "$1" in
        --schema-dir) SCHEMA_DIR="${2:?--schema-dir needs a directory}"; shift 2 ;;
        --schema-dir=*) SCHEMA_DIR="${1#*=}"; shift ;;
        --id) SCHEMA_ID="${2:?--id needs a schema id}"; shift 2 ;;
        --id=*) SCHEMA_ID="${1#*=}"; shift ;;
        --key) KEYS+=("${2:?--key needs a key}"); shift 2 ;;
        --key=*) KEYS+=("${1#*=}"); shift ;;
        --expect-contains)
            EXPECT+=("${2:?--expect-contains needs KEY}$TAB${3:?--expect-contains needs SUBSTRING}"); shift 3 ;;
        --require) REQUIRE=1; shift ;;
        -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
        *) echo "verify-gsettings-effective-defaults: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [ "${#KEYS[@]}" -eq 0 ]; then
    KEYS=(pinned-apps enabled-plugins)
fi

if [ "$REQUIRE" = 1 ]; then
    command -v glib-compile-schemas >/dev/null 2>&1 || { echo "gsettings-gate: glib-compile-schemas not found" >&2; exit 2; }
    command -v gsettings >/dev/null 2>&1 || { echo "gsettings-gate: gsettings not found" >&2; exit 2; }
    [ -d "$SCHEMA_DIR" ] || { echo "gsettings-gate: schema dir missing: $SCHEMA_DIR" >&2; exit 1; }
else
    command -v glib-compile-schemas >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1 || {
        echo "gsettings-gate: SKIP (glib tooling absent)"; exit 0; }
    [ -d "$SCHEMA_DIR" ] || { echo "gsettings-gate: SKIP (no schema dir $SCHEMA_DIR)"; exit 0; }
fi

if ! ls "$SCHEMA_DIR"/*.gschema.xml >/dev/null 2>&1; then
    if [ "$REQUIRE" = 1 ]; then echo "gsettings-gate: FAIL no *.gschema.xml in $SCHEMA_DIR" >&2; exit 1; fi
    echo "gsettings-gate: SKIP (no schema XML in $SCHEMA_DIR)"; exit 0
fi

INSTALLED="$SCHEMA_DIR/gschemas.compiled"
if [ ! -s "$INSTALLED" ]; then
    echo "gsettings-gate: FAIL $INSTALLED is missing/empty -- GLib reads only the compiled database, so no override can take effect" >&2
    exit 1
fi

get() { # $1=dir $2=key
    GSETTINGS_SCHEMA_DIR="$1" GSETTINGS_BACKEND=memory gsettings get "$SCHEMA_ID" "$2" 2>/dev/null
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gsettings-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Fresh compile of EXACTLY the same inputs the installed dir holds.
cp "$SCHEMA_DIR"/*.gschema.xml "$TMP"/ 2>/dev/null || true
cp "$SCHEMA_DIR"/*.gschema.override "$TMP"/ 2>/dev/null || true
if ! glib-compile-schemas --strict "$TMP" >"$TMP/compile.log" 2>&1; then
    echo "gsettings-gate: FAIL fresh compile of $SCHEMA_DIR does not pass --strict:" >&2
    sed 's/^/    /' "$TMP/compile.log" >&2
    exit 1
fi

FAIL=0
for k in "${KEYS[@]}"; do
    inst="$(get "$SCHEMA_DIR" "$k")"
    fresh="$(get "$TMP" "$k")"
    if [ -z "$inst" ] && [ -z "$fresh" ]; then
        echo "gsettings-gate: WARN schema $SCHEMA_ID has no key '$k' (both reads empty)" >&2
        continue
    fi
    if [ "$inst" = "$fresh" ]; then
        echo "gsettings-gate: ok   $SCHEMA_ID $k = $inst"
    else
        FAIL=1
        echo "gsettings-gate: FAIL $SCHEMA_ID $k differs between the installed compiled file and a fresh compile:" >&2
        echo "    installed: $inst" >&2
        echo "    fresh    : $fresh" >&2
    fi
done

# --expect-contains checks the EFFECTIVE installed value, not the fresh one, so
# a specific regression (the Cygnus dock/plugin defaults) is named directly.
for e in "${EXPECT[@]:-}"; do
    [ -n "$e" ] || continue
    key="${e%%$TAB*}"; want="${e#*$TAB}"
    got="$(get "$SCHEMA_DIR" "$key")"
    if printf '%s' "$got" | grep -qF -- "$want"; then
        echo "gsettings-gate: ok   $SCHEMA_ID $key contains '$want'"
    else
        FAIL=1
        echo "gsettings-gate: FAIL $SCHEMA_ID $key does not contain '$want' (installed: $got)" >&2
    fi
done

if [ "$FAIL" != 0 ]; then
    echo "gsettings-gate: FAILED -- recompile with: glib-compile-schemas $SCHEMA_DIR" >&2
    exit 1
fi
echo "gsettings-gate: OK -- installed compiled defaults match a fresh compile"
exit 0
