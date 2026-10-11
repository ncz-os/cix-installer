#!/bin/bash
# 64-ncz-lock-saver-plan.sh -- single idle/lock/blank owner for the NCZ lock
# renderer (operator 2026-10-11; REQUIREMENT 3, "the lock screen should only come
# up if the screensaver is interrupted").
#
# THE MOTION. While the NCZ session-lock client is present, it is the sole
# ext-session-lock-v1 owner AND it hosts the screensaver: the screensaver
# renders in a separate process and hands the lock client a buffer fd
# (patch singularity-shell/0014). So the sequence is
#
#     idle -> [lock acquired, saver frames shown, NO prompt] -> input -> prompt
#
# and there is never a window in which the first keystroke reaches an unlocked
# session. This hook makes that the ONLY plan when the lock renderer is
# configured:
#
#   * the session lock fires AT the saver time (dev.sinty.lockscreen:idle-delay
#     = dev.ncz.screensaver:hack-idle-delay), not later -- because the lock IS
#     the saver now;
#   * ncz-screensaver-idled must NOT start its own wlr-layer-shell saver at the
#     same instant (it would race the lock and is invisible behind it anyway);
#     the lock hosts the saver. This hook does not start the daemon; it records
#     the plan for the daemon and removes the interim ordering override so
#     exactly one idle/lock owner remains;
#   * DPMS (blank) stays the last action, owned by the shell.
#
# THE FALLBACK. When the lock renderer is NOT configured, this hook does
# nothing and the shipped interim ordering stands unchanged: hook
# 63-ncz-idle-lock-order.sh sets idle-delay = hack-idle-delay + lock-delay
# (300 + 60 = 360 > 300), so the screensaver runs first and the lock follows.
#
# "CONFIGURED" = the lock renderer env file exists and names a command:
#   $NCZ_LOCKSAVER_CONF  (default /etc/ncz/lock-renderer.env)
# containing e.g. SINGULARITY_LOCK_RENDERER=/usr/libexec/ncz-screensaver-feed.
# A packaging-time override ($NCZ_LOCKSAVER_ENABLE=1) forces the plan on, for
# the image gate and the tests; there is no persisted state.
#
# SAFETY. A gschema override that names an unknown key breaks glib-compile-schemas
# for EVERY schema in the directory, so the override is validated with
# `glib-compile-schemas --strict --dry-run` on a scratch copy first and installed
# only when it compiles. Idempotent. Never fails the install (exit 0 everywhere).
#
# Test seam (build/test-lock-saver-plan.sh): NCZ_LOCKSAVER_SCHEMA_DIR,
# NCZ_LOCKSAVER_SAVER_SCHEMA, NCZ_LOCKSAVER_CONF, NCZ_LOCKSAVER_ENABLE.
set -u

SCHEMADIR="${NCZ_LOCKSAVER_SCHEMA_DIR:-/opt/singularity/share/glib-2.0/schemas}"
SAVER_SCHEMA="${NCZ_LOCKSAVER_SAVER_SCHEMA:-/usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml}"
CONF="${NCZ_LOCKSAVER_CONF:-/etc/ncz/lock-renderer.env}"
LOCK_SCHEMA="$SCHEMADIR/dev.sinty.lockscreen.gschema.xml"
OVERRIDE="$SCHEMADIR/99-ncz-lock-saver-plan.gschema.override"
FALLBACK_OVERRIDE="$SCHEMADIR/99-ncz-idle-lock-order.gschema.override"

echo "[64] NCZ lock/saver idle plan (one owner: lock held from saver start)"

# Renderer configured?  A conf file naming a command, or an explicit force.
renderer_configured() {
    [ "${NCZ_LOCKSAVER_ENABLE:-0}" = "1" ] && return 0
    [ -f "$CONF" ] || return 1
    grep -qE '^[[:space:]]*SINGULARITY_LOCK_RENDERER[[:space:]]*=[[:space:]]*[^[:space:]]' "$CONF"
}

if ! renderer_configured; then
    echo "[64]   NCZ lock renderer not configured (no command in $CONF);"
    echo "[64]   leaving the saver-before-lock fallback (hook 63) in place"
    exit 0
fi

if [ ! -f "$LOCK_SCHEMA" ]; then
    echo "[64]   dev.sinty.lockscreen schema not installed; skipping"
    exit 0
fi

# schema_int_default FILE KEY -> the integer <default> of a top-level int key.
schema_int_default() {
    [ -f "$1" ] || return 0
    awk -v key="$2" '
        index($0, "<key name=\"" key "\"") { found = 1 }
        found && /<default>/ {
            v = $0
            sub(/^.*<default>/, "", v)
            sub(/<\/default>.*$/, "", v)
            gsub(/[^0-9]/, "", v)
            if (v != "") print v
            exit
        }
        found && /<\/key>/ { found = 0 }
    ' "$1"
}

SAVER_DELAY=300
if [ -f "$SAVER_SCHEMA" ]; then
    _v="$(schema_int_default "$SAVER_SCHEMA" hack-idle-delay)"
    [ -n "$_v" ] && SAVER_DELAY="$_v"
else
    echo "[64]   WARN: $SAVER_SCHEMA absent; assuming hack-idle-delay ${SAVER_DELAY}s" >&2
fi
case "$SAVER_DELAY" in ''|*[!0-9]*) SAVER_DELAY=300 ;; esac
[ "$SAVER_DELAY" -gt 0 ] || SAVER_DELAY=300

BODY="[dev.sinty.lockscreen]
idle-delay=$SAVER_DELAY"

if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    echo "[64]   WARN: glib-compile-schemas missing; cannot validate the override, not installing it" >&2
    exit 0
fi

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCHEMADIR"/*.gschema.xml "$SCRATCH"/ 2>/dev/null
cp "$SCHEMADIR"/*.enums.xml "$SCRATCH"/ 2>/dev/null
cp "$SCHEMADIR"/*.gschema.override "$SCRATCH"/ 2>/dev/null
# The fallback override would set a second idle-delay; drop it from the scratch
# set so the compile reflects the single-owner plan this hook installs.
rm -f "$SCRATCH/99-ncz-idle-lock-order.gschema.override"
printf '%s\n' "$BODY" > "$SCRATCH/99-ncz-lock-saver-plan.gschema.override"
if ! glib-compile-schemas --strict --dry-run "$SCRATCH" >"$SCRATCH/compile.log" 2>&1; then
    echo "[64]   WARN: override does not compile against the installed schema; not installing it:" >&2
    sed 's/^/[64]     /' "$SCRATCH/compile.log" >&2
    exit 0
fi

printf '%s\n' "$BODY" > "$OVERRIDE"
chmod 0644 "$OVERRIDE"
# Superseded: the interim ordering override would give a second, different
# idle-delay in the same directory. Remove it so exactly one plan is in force.
if [ -f "$FALLBACK_OVERRIDE" ]; then
    rm -f "$FALLBACK_OVERRIDE"
    echo "[64]   removed the superseded interim override $(basename "$FALLBACK_OVERRIDE")"
fi
if [ -z "${NCZ_LOCKSAVER_SCHEMA_DIR:-}" ]; then
    glib-compile-schemas "$SCHEMADIR" 2>&1 | sed 's/^/[64]   /' || true
fi
echo "[64]   idle plan: lock held from saver start (idle-delay=${SAVER_DELAY}s = hack-idle-delay) via $OVERRIDE"
exit 0
