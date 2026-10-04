#!/bin/bash
# apply-singularity-payload.sh -- sanctioned live-apply of a fresh
# singularity-opt.tgz over /opt/singularity, WITHOUT dropping files that other
# dpkg packages own.
#
# WHY THIS EXISTS (O6N, 2026-10-04)
# ---------------------------------
# The quick board recipe -- `mv /opt/singularity /opt/singularity.old && tar -C
# / -xzf singularity-opt.tgz` -- is correct for payload FILES but wrong for the
# tree: /opt/singularity is NOT owned solely by ncz-singularity-desktop.
# ncz-screensavers-plugin owns lib/singularity/plugins/screensaver/{libscreensaver.so,
# screensaver.plugin} and every ncz-wallpapers-* pack owns
# share/singularity/wallpaper-collections/<pack>.{artistpack,collection}. A raw
# swap deletes them (they are not in the tarball), so `dpkg -V` goes red, the
# Settings "screensaver plugin" looks disabled and no artist packs appear.
# Restoring them by hand from the backup worked, but a hand list is exactly the
# thing that rots. This helper derives the restore set from the dpkg database
# (`var/lib/dpkg/info/*.list`, the store `dpkg -S` reads) and then PROVES the
# result with `dpkg -V` through build/verify-singularity-opt-owners.sh.
#
# WHAT IT DOES
#   1. tar-validates the payload (must carry opt/singularity/bin/singularity-desktop).
#   2. records every file under /opt/singularity owned by a package OTHER than
#      the payload package (ncz-singularity-desktop) -- database-driven.
#   3. moves /opt/singularity aside to a timestamped backup (the revert target).
#   4. extracts the payload.
#   5. restores every recorded package-owned file from the backup.
#   6. recompiles the /opt/singularity GSettings schemas (stale gschemas.compiled
#      is the other half of the O6N regression).
#   7. runs the ownership gate; FAILS LOUDLY (exit 1) if anything is missing.
#   8. writes a revert note next to the backup.
#
# It NEVER restarts the user's session/compositor (the O6N operator ran this over
# a live session; the payload is read on next login). It also never touches
# /lib, /usr, or any schema tree other than /opt/singularity.
#
# USAGE
#   sudo tools/apply-singularity-payload.sh [PAYLOAD.tgz]
#   sudo tools/apply-singularity-payload.sh --payload build/sinty-out/singularity-opt.tgz
#
#   --root DIR             apply under DIR instead of / (for tests/chroots)
#   --payload FILE         payload tarball (default: build/sinty-out then assets/singularity)
#   --require-shipping     also require the screensaver plugin + the five wallpaper packs
#   --no-schema-compile    skip step 6 (tests only)
#   --dry-run              validate + report, change nothing
#   --yes                  do not prompt
#
# Exit 0 = payload applied and every package-owned file verifies clean.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ROOT="/"
PAYLOAD=""
REQUIRE_SHIPPING=0
DO_SCHEMA=1
DRY=0
ASSUME_YES=0
PAYLOAD_PKG="ncz-singularity-desktop"

while [ $# -gt 0 ]; do
    case "$1" in
        --root)            ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --root=*)          ROOT="${1#*=}"; shift ;;
        --payload)         PAYLOAD="${2:?--payload needs a file}"; shift 2 ;;
        --payload=*)       PAYLOAD="${1#*=}"; shift ;;
        --require-shipping) REQUIRE_SHIPPING=1; shift ;;
        --no-schema-compile) DO_SCHEMA=0; shift ;;
        --dry-run)         DRY=1; shift ;;
        --yes|-y)          ASSUME_YES=1; shift ;;
        -h|--help)         sed -n '2,60p' "$0"; exit 0 ;;
        -*)                echo "apply-singularity-payload: unknown option: $1" >&2; exit 2 ;;
        *)                 PAYLOAD="$1"; shift ;;
    esac
done

case "$ROOT" in /) : ;; *) ROOT="${ROOT%/}" ;; esac
[ -d "$ROOT" ] || { echo "apply-singularity-payload: root '$ROOT' does not exist" >&2; exit 2; }

if [ -z "$PAYLOAD" ]; then
    for c in "$REPO/build/sinty-out/singularity-opt.tgz" "$REPO/assets/singularity/singularity-opt.tgz"; do
        [ -s "$c" ] && { PAYLOAD="$c"; break; }
    done
fi
[ -n "$PAYLOAD" ] && [ -s "$PAYLOAD" ] || {
    echo "apply-singularity-payload: no payload tarball found (looked in build/sinty-out and assets/singularity; or pass one)" >&2
    exit 2
}

VERIFIER="$REPO/build/verify-singularity-opt-owners.sh"
[ -x "$VERIFIER" ] || { echo "apply-singularity-payload: ownership verifier missing: $VERIFIER" >&2; exit 2; }

if [ "$DRY" != 1 ] && [ "$ROOT" = "/" ] && [ "$(id -u)" != 0 ]; then
    echo "apply-singularity-payload: must run as root to apply over the live / (or use --dry-run)" >&2
    exit 2
fi
CPOPTS=(-a)
[ "$(id -u)" = 0 ] || CPOPTS=(-a --no-preserve=ownership)

TARGET="$ROOT/opt/singularity"
ADMINDIR="$ROOT/var/lib/dpkg"
INFO="$ADMINDIR/info"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

echo "[payload] payload = $PAYLOAD"
echo "[payload] target  = $TARGET"

# 1. payload sanity: it must actually be an opt/singularity payload.
if ! tar tzf "$PAYLOAD" 2>/dev/null | grep -qx 'opt/singularity/bin/singularity-desktop'; then
    echo "[payload] FATAL: $PAYLOAD does not contain opt/singularity/bin/singularity-desktop -- refusing to apply" >&2
    exit 2
fi
echo "[payload] payload contains opt/singularity/bin/singularity-desktop"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-payload-apply.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# 2. package-owned restore set, straight from the dpkg database.
#    Only files under /opt/singularity whose owning package is NOT the payload
#    package. Paths are stored root-relative (opt/singularity/...).
OWNED_LIST="$WORK/package-owned.list"
: > "$OWNED_LIST"
if [ -d "$INFO" ]; then
    for l in "$INFO"/*.list; do
        [ -e "$l" ] || continue
        pkg="$(basename "$l")"; pkg="${pkg%.list}"; pkg="${pkg%%:*}"
        [ "$pkg" = "$PAYLOAD_PKG" ] && continue
        grep -E '^/opt/singularity(/|$)' "$l" 2>/dev/null | sed -e "s#^$ROOT/##" -e 's#^/##' >> "$OWNED_LIST" || true
    done
fi
# normalise to root-relative paths (opt/singularity/...), de-dupe
sed -i -e 's#^/##' "$OWNED_LIST" 2>/dev/null || true
LC_ALL=C sort -u "$OWNED_LIST" -o "$OWNED_LIST"
OWNED_N="$(grep -c . "$OWNED_LIST" || true)"
echo "[payload] package-owned files under /opt/singularity (from dpkg): $OWNED_N"

if [ "$DRY" = 1 ]; then
    echo "[payload] DRY RUN: would back up $TARGET -> $TARGET.ncz-backup-$TS,"
    echo "[payload]          extract the payload, restore $OWNED_N package-owned file(s),"
    echo "[payload]          recompile schemas, and re-run $VERIFIER --root $ROOT"
    exit 0
fi

# 2b. interactive confirmation (skip with --yes). A live payload swap over a
#     running session is operator-visible, so prompt unless explicitly told not to.
if [ "$ASSUME_YES" != 1 ] && [ -t 0 ] && [ -t 1 ]; then
    printf '[payload] apply %s over %s? [y/N] ' "$PAYLOAD" "$TARGET"
    read -r _ans || _ans=""
    case "$_ans" in y|Y|yes|YES) ;; *) echo "[payload] aborted"; exit 1 ;; esac
fi

# 3. move the live tree aside (this backup IS the revert source).
BACKUP="$TARGET.ncz-backup-$TS"
mkdir -p "$ROOT/opt"
if [ -e "$TARGET" ]; then
    mv "$TARGET" "$BACKUP"
    echo "[payload] backed up $TARGET -> $BACKUP"
else
    echo "[payload] WARN: $TARGET did not exist; nothing to back up" >&2
    mkdir -p "$TARGET"
fi
cp "${CPOPTS[@]}" "$OWNED_LIST" "$BACKUP/NCZ-PACKAGE-OWNED-FILES.list" 2>/dev/null || true

# 4. extract the payload.
tar -C "$ROOT" -xzf "$PAYLOAD"
[ -x "$TARGET/bin/singularity-desktop" ] || {
    echo "[payload] FATAL: extraction produced no $TARGET/bin/singularity-desktop" >&2
    exit 1
}
echo "[payload] extracted payload into $TARGET"

# 5. restore every package-owned file from the backup.
RESTORED=0
MISSING_IN_BACKUP=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="$BACKUP/${rel#opt/singularity/}"
    dst="$ROOT/$rel"
    if [ -e "$src" ] || [ -L "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "${CPOPTS[@]}" "$src" "$dst"
        RESTORED=$((RESTORED + 1))
    else
        MISSING_IN_BACKUP=$((MISSING_IN_BACKUP + 1))
    fi
done < "$OWNED_LIST"
echo "[payload] restored $RESTORED package-owned file(s) from $BACKUP"
if [ "$MISSING_IN_BACKUP" -gt 0 ]; then
    echo "[payload] WARN: $MISSING_IN_BACKUP recorded package-owned file(s) were already absent from the backup" >&2
fi

# 6. recompile the /opt/singularity schemas (stale gschemas.compiled was the
#    second half of the O6N regression).
if [ "$DO_SCHEMA" = 1 ]; then
    SSD="$TARGET/share/glib-2.0/schemas"
    if [ -d "$SSD" ] && command -v glib-compile-schemas >/dev/null 2>&1; then
        glib-compile-schemas "$SSD" 2>&1 | sed 's/^/[payload]   /' || {
            echo "[payload] FATAL: glib-compile-schemas $SSD failed" >&2; exit 1; }
        echo "[payload] recompiled $SSD/gschemas.compiled"
    else
        echo "[payload] WARN: schema dir or glib-compile-schemas missing; not recompiling" >&2
    fi
fi

# 6b. prove the compiled defaults are not stale (O6N: gschemas.compiled predated
#     the overrides, so the shell read the stock dock/plugin list).
GATE="$REPO/build/verify-gsettings-effective-defaults.sh"
if [ "$DO_SCHEMA" = 1 ] && [ -x "$GATE" ]; then
    if ! "$GATE" --schema-dir "$TARGET/share/glib-2.0/schemas"; then
        echo "[payload] FATAL: effective GSettings defaults are stale after the payload swap" >&2
        exit 1
    fi
fi

# 7. prove it. The verifier is dpkg -V driven and fails on any missing/modified file.
VARG=(--root "$ROOT")
[ "$REQUIRE_SHIPPING" = 1 ] && VARG+=(--require-shipping)
if ! "$VERIFIER" "${VARG[@]}"; then
    echo "[payload] FATAL: package-owned files under /opt/singularity are NOT verify-clean after the swap." >&2
    echo "[payload]        Revert with: rm -rf '$TARGET' && mv '$BACKUP' '$TARGET'" >&2
    exit 1
fi

# 8. revert note.
RESTORE_NOTE="$BACKUP/REVERT.txt"
cat > "$RESTORE_NOTE" <<REVERT
apply-singularity-payload.sh -- revert note
applied : $TS
payload : $PAYLOAD
backup  : $BACKUP

To revert to the pre-apply /opt/singularity tree:
    rm -rf '$TARGET'
    mv '$BACKUP' '$TARGET'
    glib-compile-schemas '$TARGET/share/glib-2.0/schemas'

Package-owned files restored from the backup this run: $RESTORED
The list is recorded at $BACKUP/NCZ-PACKAGE-OWNED-FILES.list.
REVERT
echo "[payload] revert note: $RESTORE_NOTE"
echo "[payload] DONE: payload applied, ownership verified clean. The live session was NOT restarted -- log out/in to pick up the new shell."
exit 0
