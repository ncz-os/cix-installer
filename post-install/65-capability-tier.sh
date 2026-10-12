#!/bin/bash
# 65-capability-tier.sh -- install the NCZ capability profiler and its units.
#
# Operator (2026-10-12): "hardware profile these machines and have an algorithm
# that ranks systems by capability and only enables what they can healthily do
# by default."
#
# This hook installs (data + tool only; it never measures anything at install
# time, because the install chroot has no real hardware):
#
#   /usr/bin/ncz-capability                       the profiler / ranker / applier
#   /usr/share/ncz/capability/capability-features.tsv   the tier -> defaults map
#   /usr/share/glib-2.0/schemas/dev.ncz.capability.gschema.xml  the user preference
#   /usr/share/doc/ncz-capability/CAPABILITY-TIERS.md    the design
#   ncz-capability.service            first boot: probe + apply the tier defaults
#   ncz-capability-recheck.{service,timer} + a udev rule  re-run on a hardware change
#
# The tier defaults are *defaults*: `ncz-capability apply` writes a GSettings
# override (a user `gsettings set` still wins), an /etc/environment.d file and a
# feature-flag file.  It never uninstalls anything, never touches a user's
# dconf, and only changes a service default at T0 (reversible).  See
# docs/CAPABILITY-TIERS.md.
#
# Idempotent. Never fails the install (exit 0 on every path).
# Test seams (build/test-capability-tier.sh): NCZ_CAP_ASSET_SRC, NCZ_CAP_ROOT,
# NCZ_CAP_SKIP_ENABLE, NCZ_CAP_SCHEMA_DIR.
set -uo pipefail

ROOT="${NCZ_CAP_ROOT:-}"
SCHEMADIR="${NCZ_CAP_SCHEMA_DIR:-$ROOT/usr/share/glib-2.0/schemas}"
echo "[65] NCZ capability profiler + tier defaults"

# locate the staged assets (build tree, installed tree, or install medium)
SRC="${NCZ_CAP_ASSET_SRC:-}"
if [ -z "$SRC" ]; then
    for c in "$ROOT/usr/local/lib/cix-installer/assets/capability" \
             /usr/local/lib/cix-installer/assets/capability \
             /cdrom/ncz-payload/assets/capability \
             /run/ncz-payload/assets/capability; do
        if [ -f "$c/ncz-capability" ]; then SRC="$c"; break; fi
    done
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/ncz-capability" ]; then
    echo "[65] WARN: assets/capability/ncz-capability not found; capability tiering disabled" >&2
    exit 0
fi

inst() { install "$@"; }
run_glib() { command -v glib-compile-schemas >/dev/null 2>&1; }

# --- 1. the tool + data ------------------------------------------------------
inst -d -m0755 "$ROOT/usr/bin" "$ROOT/usr/share/ncz/capability" "$ROOT/usr/share/doc/ncz-capability"
inst -m0755 "$SRC/ncz-capability" "$ROOT/usr/bin/ncz-capability"
[ -f "$SRC/capability-features.tsv" ] && \
    inst -m0644 "$SRC/capability-features.tsv" "$ROOT/usr/share/ncz/capability/capability-features.tsv"
for d in "$SRC/../.." "$ROOT/usr/local/lib/cix-installer"; do
    if [ -f "$d/docs/CAPABILITY-TIERS.md" ]; then
        inst -m0644 "$d/docs/CAPABILITY-TIERS.md" "$ROOT/usr/share/doc/ncz-capability/CAPABILITY-TIERS.md"
        break
    fi
done
echo "[65]   installed /usr/bin/ncz-capability"

# --- 2. the preference schema (validated before it is trusted) --------------
if [ -f "$SRC/dev.ncz.capability.gschema.xml" ] && [ -d "$SCHEMADIR" ]; then
    SCRATCH=$(mktemp -d)
    cp "$SCHEMADIR"/*.gschema.xml "$SCRATCH"/ 2>/dev/null
    cp "$SCHEMADIR"/*.enums.xml "$SCRATCH"/ 2>/dev/null
    cp "$SCHEMADIR"/*.gschema.override "$SCRATCH"/ 2>/dev/null
    cp "$SRC/dev.ncz.capability.gschema.xml" "$SCRATCH"/
    if run_glib; then
        if glib-compile-schemas --strict --dry-run "$SCRATCH" >"$SCRATCH/compile.log" 2>&1; then
            inst -m0644 "$SRC/dev.ncz.capability.gschema.xml" "$SCHEMADIR/dev.ncz.capability.gschema.xml"
            if [ -z "${NCZ_CAP_SCHEMA_DIR:-}" ]; then
                glib-compile-schemas "$SCHEMADIR" 2>&1 | sed 's/^/[65]   /' || true
            fi
            echo "[65]   installed dev.ncz.capability schema"
        else
            echo "[65]   WARN: dev.ncz.capability schema does not compile; not installing it:" >&2
            sed 's/^/[65]     /' "$SCRATCH/compile.log" >&2
        fi
    else
        inst -m0644 "$SRC/dev.ncz.capability.gschema.xml" "$SCHEMADIR/dev.ncz.capability.gschema.xml"
        echo "[65]   glib-compile-schemas missing; schema staged without compile"
    fi
    rm -rf "$SCRATCH"
else
    echo "[65]   schema dir or schema source absent; skipping the preference schema"
fi

# --- 3. the units + udev rule -----------------------------------------------
inst -d -m0755 "$ROOT/usr/lib/systemd/system" "$ROOT/etc/udev/rules.d" "$ROOT/etc/ncz"
for u in ncz-capability.service ncz-capability-recheck.service ncz-capability-recheck.timer; do
    [ -f "$SRC/$u" ] && inst -m0644 "$SRC/$u" "$ROOT/usr/lib/systemd/system/$u"
done
[ -f "$SRC/72-ncz-capability-recheck.rules" ] && \
    inst -m0644 "$SRC/72-ncz-capability-recheck.rules" "$ROOT/etc/udev/rules.d/72-ncz-capability-recheck.rules"

# --- 4. enable (by hand: the chroot has no running systemd) -----------------
if [ "${NCZ_CAP_SKIP_ENABLE:-0}" != "1" ]; then
    install -d -m0755 "$ROOT/usr/lib/systemd/system/multi-user.target.wants" \
                      "$ROOT/usr/lib/systemd/system/timers.target.wants"
    ln -sf ../ncz-capability.service "$ROOT/usr/lib/systemd/system/multi-user.target.wants/ncz-capability.service"
    ln -sf ../ncz-capability-recheck.timer "$ROOT/usr/lib/systemd/system/timers.target.wants/ncz-capability-recheck.timer"
    echo "[65]   enabled ncz-capability.service + ncz-capability-recheck.timer"
else
    echo "[65]   NCZ_CAP_SKIP_ENABLE=1: units installed but not enabled"
fi

echo "[65] capability tiering installed (measured at first boot; override: /etc/ncz/capability.override)"
exit 0
