#!/bin/bash
# gen-singularity-deb-depends.sh — derive the runtime Depends: set of the
# NCZ-OS Singularity Desktop .deb from the real payload.
#
# The payload (singularity-opt.tgz, wrapped by build-singularity-deb.sh) is a
# /opt/singularity tree whose binaries link a large set of system libraries.
# Those libraries must be listed in the package's Depends: or a clean
# `apt-get install` leaves the binary unresolvable (Item G report 2026-10-05:
# libnm0, libinput10, libseat1, libxcb-*, libgoa-1.0-0b, ... were all missing).
#
# Method (must run as root on Debian, with `apt-file` available):
#   1. extract the payload (or accept an already-extracted tree)
#   2. enumerate every ELF, collect DT_NEEDED (needed) and DT_SONAME (provided)
#   3. external = needed - provided  (the payload's own .so are not deps)
#   4. map each external soname to the Debian package that ships it (apt-file)
#   5. emit build/singularity-runtime-deps.tsv (soname<TAB>package evidence)
#      and build/singularity-deb-depends.txt (sorted Depends entries)
#
# Run it in a container matching the shipping suite (the payload is built on
# debian:forky, which is what release.conf's NCZ_BASE_CODENAME selects):
#
#   docker run --rm --security-opt label=disable -v "$PWD:/w" -w /w debian:forky \
#     bash -c 'apt-get update -qq && apt-get install -y -qq apt-file binutils >/dev/null \
#       && apt-file update >/dev/null \
#       && bash build/gen-singularity-deb-depends.sh \
#            ncz-singularity-desktop_<ver>_<arch>.deb --write'
#
# The generated files are checked in; build-singularity-deb.sh consumes
# singularity-deb-depends.txt. Regenerate deliberately, never silently.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

INPUT=""
WRITE=0
for arg in "$@"; do
    case "$arg" in
        --write) WRITE=1 ;;
        -*) die "unknown option: $arg" ;;
        *) INPUT="$arg" ;;
    esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${OUTDIR:-$REPO/build}"

# Non-soname runtime requirements that are deliberately kept, each with the
# evidence that justifies it (see report.md). These are appended to the sorted
# package list and recorded in the evidence TSV with source=runtime:
#   upower             — the shell talks to org.freedesktop.UPower over D-Bus
#                        (strings: org.freedesktop.UPower.PowerProfiles).
#   libadwaita-1-0     — retained from the pre-existing list; no ELF links it
#                        today, but it is part of the desktop closure and
#                        removing it is out of scope for a Depends fix.
#   libglib2.0-bin     — provides glib-compile-schemas, which DEBIAN/postinst
#                        needs to compile the payload's GSettings schemas, and
#                        the `gsettings` CLI the session wrapper calls. Without
#                        it the desktop aborts on a missing-schema g_settings_*.
EXTRA_PACKAGES="upower libadwaita-1-0 libglib2.0-bin"

[ -n "$INPUT" ] || die "usage: $0 <payload.deb|payload.tgz|payload-dir> [--write]"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/gen-sing-deps.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

ROOT=""
if [ -d "$INPUT" ]; then
    # already-extracted tree: either .../opt/singularity or a parent of it
    if [ -d "$INPUT/opt/singularity" ]; then
        ROOT="$INPUT/opt/singularity"
    elif [ -d "$INPUT/bin" ] && [ -d "$INPUT/lib" ]; then
        ROOT="$INPUT"
    else
        die "$INPUT is not a /opt/singularity tree or deb/tgz"
    fi
elif [ -f "$INPUT" ]; then
    case "$INPUT" in
        *.deb) dpkg-deb -x "$INPUT" "$STAGE" 2>/dev/null || die "dpkg-deb -x failed on $INPUT" ;;
        *.tgz|*.tar.gz) tar -C "$STAGE" -xzf "$INPUT" ;;
        *) die "unrecognised payload type: $INPUT" ;;
    esac
    ROOT="$STAGE/opt/singularity"
else
    die "payload not found: $INPUT"
fi
[ -d "$ROOT" ] || die "payload root missing: $ROOT"

command -v readelf >/dev/null 2>&1 || die "readelf (binutils) not available"
command -v apt-file >/dev/null 2>&1 || die "apt-file not available (run inside a Debian container, see header)"

# --- 1/2. enumerate ELF files, DT_NEEDED and DT_SONAME ------------------------
: > "$STAGE/elfs"
while IFS= read -r -d '' f; do
    if [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]; then
        printf '%s\n' "$f"
    fi
done < <(find "$ROOT" -type f -print0) | sort > "$STAGE/elfs" || true

: > "$STAGE/provided"
: > "$STAGE/needed"
while IFS= read -r f; do
    readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(SONAME\)/{print $2}' >> "$STAGE/provided"
    readelf -d "$f" 2>/dev/null | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' >> "$STAGE/needed"
done < "$STAGE/elfs"
sort -u "$STAGE/provided" -o "$STAGE/provided"
sort -u "$STAGE/needed" -o "$STAGE/needed"

echo "[gen] payload: $INPUT" >&2
echo "[gen] ELF files: $(wc -l < "$STAGE/elfs")" >&2
echo "[gen] distinct DT_NEEDED: $(wc -l < "$STAGE/needed")" >&2
echo "[gen] payload-provided sonames: $(wc -l < "$STAGE/provided")" >&2

# external = needed - provided. Keep libc/libm/etc. mapped explicitly (they
# resolve to libc6); the point is no linked soname is silently missing.
comm -23 "$STAGE/needed" "$STAGE/provided" > "$STAGE/external"
echo "[gen] external sonames: $(wc -l < "$STAGE/external")" >&2

# --- 4. map soname -> package, one deterministic choice ----------------------
pick_package() {
    # $1 = space-separated candidate packages from apt-file
    # Deterministic: drop -dev/-dbgsym/-dbg/-doc/-cross, keep lib*, shortest
    # name wins, then alphabetical. Never let an empty match trip pipefail.
    local out
    out=$(printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' \
        | grep -vE '(-dev$|-dbgsym$|-dbg$|-doc$|-cross$)' \
        | grep -E '^lib' \
        | sort | awk '{ print length, $0 }' | sort -n -k1,1 -k2,2 | head -n1 | awk '{ $1=""; sub(/^ /,""); print }') || true
    printf '%s' "$out"
    return 0
}

: > "$STAGE/deps.tsv"
while IFS= read -r so; do
    esc=$(printf '%s' "$so" | sed 's/[.[\*^$()+?{}|]/\\&/g')
    cands=$(apt-file search -x "/${esc}\$" 2>/dev/null | sed 's/:.*$//' | sort -u | tr '\n' ' ')
    pkg=$(pick_package "$cands")
    [ -n "$pkg" ] || { echo "[gen] WARNING: no package found for $so" >&2; pkg="MISSING:$so"; }
    printf '%s\t%s\telf\n' "$so" "$pkg" >> "$STAGE/deps.tsv"
done < "$STAGE/external"

# --- 5. emit ----------------------------------------------------------------
# package list = everything the payload links + the explicit runtime extras.
# The list is exact for the payload this ran against; it carries no ' | '
# alternatives, because a payload built against another suite links different
# sonames and must be regenerated rather than papered over.
pkgs="$(
    {
        cut -f2 "$STAGE/deps.tsv"
        printf '%s\n' $EXTRA_PACKAGES
    } | grep -v '^MISSING:' | sort -u
)"
entries="$(printf '%s\n' "$pkgs" | sed '/^$/d' | sort -u)"

if [ "$WRITE" -eq 1 ]; then
    {
        echo "# singularity-runtime-deps.tsv — evidence for the ncz-singularity-desktop Depends: list."
        echo "# Generated by build/gen-singularity-deb-depends.sh from the real payload"
        echo "# inside debian:forky (the release.conf NCZ_BASE_CODENAME)."
        echo "# Columns: soname<TAB>package<TAB>source"
        echo "#   source=elf     soname discovered from the payload's DT_NEEDED"
        echo "#   source=runtime non-soname runtime requirement, soname recorded as '-'"
        echo "# Multiple sonames may map to the same package."
        cat "$STAGE/deps.tsv"
        for p in $EXTRA_PACKAGES; do printf -- '-\t%s\truntime\n' "$p"; done
    } > "$OUTDIR/singularity-runtime-deps.tsv"

    {
        echo "# singularity-deb-depends.txt — Depends: entries for ncz-singularity-desktop."
        echo "# One Debian Depends entry per line. Generated by"
        echo "# build/gen-singularity-deb-depends.sh from the real payload inside"
        echo "# debian:forky (release.conf NCZ_BASE_CODENAME). Exact for that payload:"
        echo "# no ' | ' alternatives. Do not hand-edit; regenerate and review the diff."
        echo "# Non-soname runtime entries are documented in singularity-runtime-deps.tsv."
        echo "# Consumed by build-singularity-deb.sh."
        printf '%s\n' "$entries"
    } > "$OUTDIR/singularity-deb-depends.txt"
    echo "[gen] wrote $OUTDIR/singularity-runtime-deps.tsv" >&2
    echo "[gen] wrote $OUTDIR/singularity-deb-depends.txt" >&2
else
    echo "== soname -> package =="
    cat "$STAGE/deps.tsv"
    echo
    echo "== Depends entries =="
    printf '%s\n' "$entries"
fi
