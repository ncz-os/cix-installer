#!/bin/bash
# 63-ncz-idle-lock-order.sh -- order the desktop's automatic screen-lock AFTER
# the ncz screensaver instead of at the same instant (2026-10-11).
#
# THE BUG. Two independent idle consumers read the same idle clock and act:
#   * the Singularity shell's IdleManager locks the session at
#     dev.sinty.lockscreen:idle-delay (schema default 300s), through
#     ext-session-lock-v1;
#   * ncz-screensaver-idled starts the animated saver at
#     dev.ncz.screensaver:hack-idle-delay (schema default 300s), on a
#     wlr-layer-shell surface.
# ext-session-lock-v1 is EXCLUSIVE: while the session is locked the compositor
# presents the lock surface and nothing else (architecture
# decision 2026-08-17: the lockscreen IS the screensaver). A layer-shell
# screensaver therefore cannot be seen behind the lock, and ncz-screensaver
# refuses to start one at all while a locker is alive ("session is locked; not
# starting", ncz-screensavers launcher/ncz-screensaver). With both defaults at
# 300s the two fire in the same instant and whichever wins the race decides
# whether the screensaver ever appears. Measured on the OmniDesk test desktop 2026-10-11: the
# shell lock won, the saver never ran, and the session stayed locked.
#
# THE FIX. Install a GSettings DEFAULT override for the shell lock so it fires
# strictly after the saver, using the same ordering ncz-screensaver-idled
# already models for its OWN optional lock (`lock = hack-idle-delay +
# lock-delay`, launcher/ncz-screensaver-idled.c plan_compute()):
#
#     dev.sinty.lockscreen:idle-delay = hack-idle-delay + lock-delay
#                                     = 300 + 60 = 360
#
# The value is read from the INSTALLED dev.ncz.screensaver schema at install
# time (not hard-coded) so it tracks the package, with 300 + 60 as the fallback.
# 360 > 300 gives the saver a full lock-delay of visible run time first.
#
# The override lives in the Singularity schema dir -- where dev.sinty.lockscreen
# is defined and where the session's GSETTINGS_SCHEMA_DIR points -- so it is
# compiled together with that schema. A schema-directory override only affects
# schemas in the SAME directory, so dev.ncz.screensaver (in the system schema
# dir, owned by the ncz-screensavers package) is deliberately untouched.
#
# Only DEFAULTS change: a user or an earlier hook that already chose a lock
# time keeps it (no dconf key is written). On a fresh install, and on any
# install where the user never changed the lock time, this becomes the
# effective value.
#
# SAFETY: an override that names an unknown key makes glib-compile-schemas fail
# for EVERY schema in the directory, so the combination is validated with
# `glib-compile-schemas --strict --dry-run` on a scratch copy first and is only
# installed when it compiles; otherwise the hook warns and leaves the system
# untouched. Idempotent. Never fails the install (exit 0 on every path).
#
# Test seam (build/test-idle-lock-order.sh): NCZ_IDLELOCK_SCHEMA_DIR overrides
# the Singularity schema dir, NCZ_IDLELOCK_SAVER_SCHEMA overrides the
# dev.ncz.screensaver schema path.
set -u

SCHEMADIR="${NCZ_IDLELOCK_SCHEMA_DIR:-/opt/singularity/share/glib-2.0/schemas}"
SAVER_SCHEMA="${NCZ_IDLELOCK_SAVER_SCHEMA:-/usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml}"
LOCK_SCHEMA="$SCHEMADIR/dev.sinty.lockscreen.gschema.xml"
OVERRIDE="$SCHEMADIR/99-ncz-idle-lock-order.gschema.override"

echo "[63] desktop idle-lock ordering (lock after the screensaver)"

if [ ! -f "$LOCK_SCHEMA" ]; then
    echo "[63]   dev.sinty.lockscreen schema not installed; skipping"
    exit 0
fi

# schema_int_default FILE KEY -> the integer <default> of a top-level int key.
# The key header, optional <range/> and the <default> are separate lines in the
# schema, so match the key block and print the digits of its <default>.
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
LOCK_DELAY=60
if [ -f "$SAVER_SCHEMA" ]; then
    _v="$(schema_int_default "$SAVER_SCHEMA" hack-idle-delay)"
    [ -n "$_v" ] && SAVER_DELAY="$_v"
    _v="$(schema_int_default "$SAVER_SCHEMA" lock-delay)"
    [ -n "$_v" ] && LOCK_DELAY="$_v"
else
    echo "[63]   WARN: $SAVER_SCHEMA absent; using defaults ${SAVER_DELAY}s + ${LOCK_DELAY}s" >&2
fi

# The lock must fire strictly after the saver. If a future schema ships
# lock-delay 0 (lock with the saver), keep a 60s guard so the saver still wins.
case "$LOCK_DELAY" in ''|*[!0-9]*) LOCK_DELAY=60 ;; esac
[ "$LOCK_DELAY" -gt 0 ] || LOCK_DELAY=60
LOCK_AT=$((SAVER_DELAY + LOCK_DELAY))

BODY="[dev.sinty.lockscreen]
idle-delay=$LOCK_AT"

if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    echo "[63]   WARN: glib-compile-schemas missing; cannot validate the override, not installing it" >&2
    exit 0
fi

# Validate on a scratch copy before touching the real directory.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp "$SCHEMADIR"/*.gschema.xml "$SCRATCH"/ 2>/dev/null
cp "$SCHEMADIR"/*.enums.xml "$SCRATCH"/ 2>/dev/null
cp "$SCHEMADIR"/*.gschema.override "$SCRATCH"/ 2>/dev/null
printf '%s\n' "$BODY" > "$SCRATCH/99-ncz-idle-lock-order.gschema.override"
if ! glib-compile-schemas --strict --dry-run "$SCRATCH" >"$SCRATCH/compile.log" 2>&1; then
    echo "[63]   WARN: override does not compile against the installed schema; not installing it:" >&2
    sed 's/^/[63]     /' "$SCRATCH/compile.log" >&2
    exit 0
fi

printf '%s\n' "$BODY" > "$OVERRIDE"
chmod 0644 "$OVERRIDE"
if [ -z "${NCZ_IDLELOCK_SCHEMA_DIR:-}" ]; then
    glib-compile-schemas "$SCHEMADIR" 2>&1 | sed 's/^/[63]   /' || true
fi
echo "[63]   idle screen-lock default: ${LOCK_AT}s (screensaver ${SAVER_DELAY}s + lock-delay ${LOCK_DELAY}s) via $OVERRIDE"
exit 0
