#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jason Perlow
#
# build-deb.sh - generate and build the data-only apple-t2-audio-config package.
#
#   build-deb.sh --out-dir DIR --scratch-parent DIR [--source-date-epoch N]
#                [--layout all|2|4|6] [--stage-only] [--keep-staging]
#
# Directories:
#   --out-dir          where the .deb is written. Absolute, must be empty or
#                      absent, and must live outside this package's source tree.
#   --scratch-parent   the parent under which this run allocates its own
#                      private scratch directory. It must be absolute, must be
#                      inside the caller's ~/Projects tree, must contain no
#                      symbolic-link component, and must not be within --out-dir
#                      or the source tree. Defaults to ~/Projects.
#
# Scratch ownership: this script never deletes a caller-supplied directory.
# After every argument, the layout, the facts and the output path have been
# validated without touching the filesystem, the run allocates one exclusive
# child directory with mktemp -d inside the validated parent and removes
# exactly that child on exit - never the parent, never anything that was
# already there.
#
# Deterministic: SOURCE_DATE_EPOCH (default 2026-10-15T00:00:00Z, overridable)
# is applied to every payload file, to the changelog date inside the package
# and to the .deb itself, and the payload is compressed with a fixed gzip level
# and mtime 0. Identical inputs produce an identical .deb.
#
# Side effects on the target system: none. The package ships no maintainer
# scripts, so installing or upgrading it restarts nothing and changes no mixer
# state; the existing PipeWire headroom configuration is not touched.
#
# Needs python3 (standard library only) and, unless --stage-only, dpkg-deb.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACKAGE_NAME="apple-t2-audio-config"
SCRATCH_PREFIX="apple-t2-audio-config.stage."
DEFAULT_EPOCH=1792022400 # 2026-10-15T00:00:00Z

OUT_DIR=""
SCRATCH_PARENT=""
LAYOUT="all"
EPOCH="${SOURCE_DATE_EPOCH:-$DEFAULT_EPOCH}"
STAGE_ONLY=0
KEEP_STAGING=0
SCRATCH_CHILD=""
SCRATCH_PARENT_CANON=""

die() { printf '%s: error: %s\n' "$PACKAGE_NAME" "$*" >&2; exit 2; }
log() { printf '%s: %s\n' "$PACKAGE_NAME" "$*"; }

usage() {
    sed -n '5,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# path helpers. Nothing here writes; every check runs before the first mkdir.
# --------------------------------------------------------------------------

# Strip trailing slashes and reject the ambiguous spellings. With '.' and
# '..' excluded, the lexical path is what the kernel will resolve, so a later
# physical-path comparison detects any symbolic link in the path.
normalise_syntax() {
    local path="$1"
    while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
        path="${path%/}"
    done
    case "$path" in
        *//*) die "path has an empty segment: $path" ;;
        */./*|*/.) die "path must not contain '.' segments: $path" ;;
    esac
    printf '%s\n' "$path"
}

# The physical path of an existing directory, or failure.
physical_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    ( cd -- "$dir" && pwd -P )
}

require_absolute() {
    case "$1" in
        /*) return 0 ;;
        *) die "$2 must be an absolute path: $1" ;;
    esac
}

require_under() {
    # $1 candidate, $2 allowed parent, $3 label
    case "$1" in
        "$2") return 0 ;;
        "$2"/*) return 0 ;;
    esac
    die "$3 must be $2 or below it: $1"
}

reject_overlap() {
    # $1 first path, $2 second path, $3 label
    case "$1" in
        "$2"|"$2"/*) die "$3 overlaps $2" ;;
    esac
    case "$2" in
        "$1"/*) die "$3 is inside $1" ;;
    esac
    return 0
}

# --------------------------------------------------------------------------
# arguments
# --------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out-dir)          [ "$#" -ge 2 ] || die "--out-dir needs a value"; OUT_DIR="$2"; shift 2 ;;
        --scratch-parent)   [ "$#" -ge 2 ] || die "--scratch-parent needs a value"; SCRATCH_PARENT="$2"; shift 2 ;;
        --layout)           [ "$#" -ge 2 ] || die "--layout needs a value"; LAYOUT="$2"; shift 2 ;;
        --source-date-epoch)[ "$#" -ge 2 ] || die "--source-date-epoch needs a value"; EPOCH="$2"; shift 2 ;;
        --stage-only)       STAGE_ONLY=1; shift ;;
        --keep-staging)     KEEP_STAGING=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "$OUT_DIR" ] || die "--out-dir is required"
[ -n "$SCRATCH_PARENT" ] || SCRATCH_PARENT="${HOME:-}/Projects"

require_absolute "$OUT_DIR" "--out-dir"
require_absolute "$SCRATCH_PARENT" "--scratch-parent"
OUT_DIR="$(normalise_syntax "$OUT_DIR")"
SCRATCH_PARENT="$(normalise_syntax "$SCRATCH_PARENT")"

case "$EPOCH" in
    ''|*[!0-9]*) die "--source-date-epoch must be a non-negative integer: $EPOCH" ;;
esac

[ -n "${HOME:-}" ] || die "HOME is not set; pass --scratch-parent explicitly"
HOME_CANON="$(physical_dir "$HOME")" || die "HOME is not a readable directory: $HOME"
PROJECTS_CANON="$(physical_dir "$HOME/Projects")" \
    || die "--scratch-parent default needs $HOME/Projects to exist; pass --scratch-parent explicitly"

command -v python3 >/dev/null 2>&1 || die "python3 is required (standard library only)"
if [ "$STAGE_ONLY" -eq 0 ]; then
    command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required to build the package"
fi

# Scratch parent: real directory, no symbolic link anywhere in the path, inside
# ~/Projects, and outside the output directory and the source tree.
[ -d "$SCRATCH_PARENT" ] || die "--scratch-parent does not exist: $SCRATCH_PARENT"
SCRATCH_PARENT_CANON="$(physical_dir "$SCRATCH_PARENT")" \
    || die "--scratch-parent is not a readable directory: $SCRATCH_PARENT"
[ "$SCRATCH_PARENT_CANON" = "$SCRATCH_PARENT" ] \
    || die "--scratch-parent traverses a symbolic link: $SCRATCH_PARENT"
require_under "$SCRATCH_PARENT_CANON" "$PROJECTS_CANON" "--scratch-parent"
[ "$SCRATCH_PARENT_CANON" != "$HOME_CANON" ] \
    || die "refusing to use $SCRATCH_PARENT_CANON as the scratch parent"

# Output directory: outside the source tree, not a system directory, empty.
[ "$OUT_DIR" != "/" ] || die "refusing to use / as an output directory"
reject_overlap "$OUT_DIR" "$SOURCE_DIR" "--out-dir"
case "$SCRATCH_PARENT_CANON" in
    "$OUT_DIR"|"$OUT_DIR"/*) die "--scratch-parent overlaps --out-dir" ;;
    "$SOURCE_DIR"|"$SOURCE_DIR"/*) die "--scratch-parent overlaps source" ;;
esac
case "$OUT_DIR" in
    /usr|/usr/share|/usr/share/alsa|/usr/share/alsa/ucm2|/etc|/var|/home|/root|/boot|/opt)
        die "refusing to use $OUT_DIR as an output directory" ;;
esac
OUT_PARENT="$(physical_dir "$(dirname -- "$OUT_DIR")")" \
    || die "the parent of --out-dir must already exist: $(dirname -- "$OUT_DIR")"
[ "$OUT_PARENT" = "$(dirname -- "$OUT_DIR")" ] \
    || die "--out-dir traverses a symbolic link: $(dirname -- "$OUT_DIR")"
[ ! -L "$OUT_DIR" ] || die "--out-dir must not be a symlink: $OUT_DIR"
if [ -e "$OUT_DIR" ]; then
    [ -d "$OUT_DIR" ] || die "--out-dir exists and is not a directory: $OUT_DIR"
    [ -z "$(ls -A -- "$OUT_DIR" 2>/dev/null)" ] \
        || die "--out-dir is not empty, leaving it untouched: $OUT_DIR"
fi

# Layout, facts and the output path are validated by the generator with
# --validate-only, which creates nothing. Only if that passes does this run
# allocate a directory.
SOURCE_DATE_EPOCH="$EPOCH" TZ=UTC LC_ALL=C \
    python3 "$SOURCE_DIR/src/applet2_ucm.py" \
        --facts "$SOURCE_DIR/src/facts.json" \
        --source-dir "$SOURCE_DIR" \
        --out-dir "$OUT_DIR" \
        --layout "$LAYOUT" \
        --source-date-epoch "$EPOCH" \
        --validate-only >/dev/null \
    || die "the layout, the facts or the output path are not acceptable; nothing was created"

# --------------------------------------------------------------------------
# scratch: one exclusive child, allocated here, removed here and nowhere else
# --------------------------------------------------------------------------

cleanup() {
    [ -n "$SCRATCH_CHILD" ] || return 0
    if [ "$KEEP_STAGING" -eq 1 ]; then
        log "scratch kept at $SCRATCH_CHILD"
        return 0
    fi
    case "$SCRATCH_CHILD" in
        "$SCRATCH_PARENT_CANON"/"$SCRATCH_PREFIX"??????????) ;;
        *) printf '%s: refusing to remove unexpected scratch path %s\n' \
               "$PACKAGE_NAME" "$SCRATCH_CHILD" >&2; return 0 ;;
    esac
    [ -d "$SCRATCH_CHILD" ] && [ ! -L "$SCRATCH_CHILD" ] && rm -rf -- "$SCRATCH_CHILD"
    return 0
}
trap cleanup EXIT

SCRATCH_CHILD="$(mktemp -d -- "$SCRATCH_PARENT_CANON/${SCRATCH_PREFIX}XXXXXXXXXX")" \
    || die "cannot allocate a scratch directory under $SCRATCH_PARENT_CANON"
[ -d "$SCRATCH_CHILD" ] || die "mktemp did not create $SCRATCH_CHILD"
CHILD_REAL="$(physical_dir "$SCRATCH_CHILD")" \
    || die "the allocated scratch directory vanished: $SCRATCH_CHILD"
[ "$(physical_dir "$(dirname -- "$CHILD_REAL")")" = "$SCRATCH_PARENT_CANON" ] \
    || die "the allocated scratch directory is not inside $SCRATCH_PARENT_CANON"
SCRATCH_CHILD="$CHILD_REAL"
STAGING="$SCRATCH_CHILD/staging"

# Generator: writes the staging tree, validated above.
SOURCE_DATE_EPOCH="$EPOCH" TZ=UTC LC_ALL=C \
    python3 "$SOURCE_DIR/src/applet2_ucm.py" \
        --facts "$SOURCE_DIR/src/facts.json" \
        --source-dir "$SOURCE_DIR" \
        --out-dir "$STAGING" \
        --layout "$LAYOUT" \
        --source-date-epoch "$EPOCH" \
        --json > "$SCRATCH_CHILD/manifest.json"

log "staged $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["files"]))' "$SCRATCH_CHILD/manifest.json") files in $STAGING (epoch $EPOCH)"

if [ "$STAGE_ONLY" -eq 1 ]; then
    log "stage-only: no .deb build; --keep-staging controls retention of $STAGING"
    exit 0
fi

# Re-check the output directory: nothing is created until the payload exists.
[ ! -e "$OUT_DIR" ] || [ -d "$OUT_DIR" ] || die "--out-dir exists and is not a directory: $OUT_DIR"
if [ -d "$OUT_DIR" ]; then
    [ -z "$(ls -A -- "$OUT_DIR" 2>/dev/null)" ] \
        || die "--out-dir is not empty, leaving it untouched: $OUT_DIR"
fi
mkdir -p -- "$OUT_DIR" || die "cannot create output directory: $OUT_DIR"

# Normalise modes and timestamps so the archive does not depend on the build
# host's umask, clock or filesystem ordering.
find "$STAGING" -type d -exec chmod 0755 {} +
find "$STAGING" -type f -exec chmod 0644 {} +
find "$STAGING" -depth -exec touch --no-dereference --date="@$EPOCH" {} +

# Version and architecture come straight from the generated control file so the
# file name and the metadata can never drift apart.
PKG_VERSION="$(awk '$1 == "Version:" { print $2; exit }' "$STAGING/DEBIAN/control")"
PKG_ARCH="$(awk '$1 == "Architecture:" { print $2; exit }' "$STAGING/DEBIAN/control")"
[ -n "$PKG_VERSION" ] || die "could not read Version from the generated control file"
[ -n "$PKG_ARCH" ] || die "could not read Architecture from the generated control file"

DEB_PATH="$OUT_DIR/${PACKAGE_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"
[ ! -e "$DEB_PATH" ] || die "refusing to overwrite an existing file: $DEB_PATH"

SOURCE_DATE_EPOCH="$EPOCH" TZ=UTC LC_ALL=C \
    dpkg-deb --root-owner-group -Zgzip -z9 --uniform-compression \
             --build "$STAGING" "$DEB_PATH" >/dev/null \
    || die "dpkg-deb --build failed"

log "built $DEB_PATH"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$DEB_PATH"
fi

exit 0