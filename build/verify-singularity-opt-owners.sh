#!/bin/bash
# verify-singularity-opt-owners.sh -- the payload-swap ownership gate.
#
# WHY THIS EXISTS
# ---------------
# /opt/singularity is owned by MORE than the ncz-singularity-desktop payload
# package. Two other classes of package install files INTO that tree:
#
#   * ncz-screensavers-plugin  -> lib/singularity/plugins/screensaver/
#       libscreensaver.so, screensaver.plugin
#   * every ncz-wallpapers-* artist pack -> share/singularity/
#       wallpaper-collections/<pack>.artistpack and <pack>.collection
#
# Applying a payload by moving /opt/singularity aside and extracting a fresh
# tree (the board bring-up recipe, and what the desktop-hotfix layer did with
# an `opaque opt/singularity` overlay entry) DROPS those files: they are not in
# the payload, so nothing puts them back. On O6N 2026-10-04 `dpkg -V` showed
# them missing, the Settings plugin looked disabled and no artist packs
# appeared. Build the payload wrong once and the image ships that way.
#
# This verifier answers one question, from the dpkg database itself (never a
# hand list): after the payload step, is every package that owns files under
# /opt/singularity verify-clean? It runs `dpkg --root <root> -V <pkg>` for each
# owner discovered from var/lib/dpkg/info/*.list and fails on ANY output. Note
# that `dpkg -V` exits 0 even when it prints `missing ...`; the exit code is
# NOT a verdict, the output is.
#
# USAGE
#   verify-singularity-opt-owners.sh [--root DIR] [--require PKG]...
#                                    [--require-shipping] [--quiet]
#
#   --root DIR          target rootfs to inspect (default /)
#   --require PKG       additionally require PKG to be installed and clean
#                       (repeatable). Implies "must exist".
#   --require-shipping  shorthand for the NCZ desktop release contract:
#                       ncz-screensavers-plugin plus the five wallpaper packs
#                       (ncz, cygnus-2610, singularity, brandon-perlow,
#                       alex-jay-brady) must all be installed and verify clean.
#   --list-only         print the discovered owner packages and exit
#
# Exit 0 = every discovered owner (and every --require package) is clean;
# exit 1 = something is missing/modified or a required package is absent;
# exit 2 = usage / environment error.
#
# SELF-TEST: build/test-singularity-opt-owners.sh proves both directions.
set -uo pipefail
shopt -s nullglob

ROOT="/"
QUIET=0
LIST_ONLY=0
REQUIRE=()
REQUIRE_SHIPPING=0

while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --root=*)   ROOT="${1#*=}"; shift ;;
        --require)  REQUIRE+=("${2:?--require needs a package}"); shift 2 ;;
        --require=*) REQUIRE+=("${1#*=}"); shift ;;
        --require-shipping) REQUIRE_SHIPPING=1; shift ;;
        --quiet)    QUIET=1; shift ;;
        --list-only) LIST_ONLY=1; shift ;;
        -h|--help)  sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "verify-singularity-opt-owners: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$ROOT" in
    /) : ;;
    *) ROOT="${ROOT%/}" ;;
esac
[ -d "$ROOT" ] || { echo "verify-singularity-opt-owners: root '$ROOT' does not exist" >&2; exit 2; }

ADMINDIR="$ROOT/var/lib/dpkg"
INFO="$ADMINDIR/info"
[ -d "$INFO" ] || { echo "verify-singularity-opt-owners: no dpkg info dir at $INFO" >&2; exit 2; }
command -v dpkg    >/dev/null 2>&1 || { echo "verify-singularity-opt-owners: dpkg not found" >&2; exit 2; }
command -v dpkg-query >/dev/null 2>&1 || { echo "verify-singularity-opt-owners: dpkg-query not found" >&2; exit 2; }

if [ "$REQUIRE_SHIPPING" = 1 ]; then
    REQUIRE+=(ncz-screensavers-plugin \
              ncz-wallpapers-ncz \
              ncz-wallpapers-cygnus-2610 \
              ncz-wallpapers-singularity \
              ncz-wallpapers-brandon-perlow \
              ncz-wallpapers-alex-jay-brady)
fi

note() { [ "$QUIET" = 1 ] || echo "$@"; }
FAIL=0
fail() { FAIL=1; echo "OPT-OWNERS FAIL: $*" >&2; }

# ---- discover every package that owns a path under /opt/singularity ----------
# The dpkg info/*.list files are the authoritative ownership record on the
# target; no hand-maintained list to drift. Names may be arch-qualified
# (pkg:arch.list); keep the qualifier, dpkg accepts it.
declare -A OWNER_SEEN=()
OWNERS=()
for l in "$INFO"/*.list; do
    [ -e "$l" ] || continue
    if grep -qE '^/opt/singularity(/|$)' "$l" 2>/dev/null; then
        pkg="$(basename "$l")"; pkg="${pkg%.list}"
        [ -n "${OWNER_SEEN[$pkg]:-}" ] && continue
        OWNER_SEEN[$pkg]=1
        OWNERS+=("$pkg")
    fi
done

note "opt-owners: root=$ROOT owners=${#OWNERS[@]}"
for pkg in "${OWNERS[@]:-}"; do
    [ -n "$pkg" ] || continue
    note "opt-owners:   owner $pkg"
done

if [ "$LIST_ONLY" = 1 ]; then
    [ "$FAIL" = 0 ] || exit 1
    exit 0
fi

is_installed() {  # $1 = package (possibly arch-qualified)
    local st
    st="$(dpkg-query --admindir="$ADMINDIR" -W -f='${Status}' "$1" 2>/dev/null)"
    [ "$st" = "install ok installed" ]
}

verify_pkg() {  # $1 = package; verifies only if installed or required
    local pkg="$1" required="$2" out
    if ! is_installed "$pkg"; then
        if [ "$required" = 1 ]; then
            fail "$pkg is not installed (required package absent after the payload step)"
        else
            note "opt-owners:   (skip $pkg: not installed)"
        fi
        return 0
    fi
    # dpkg -V prints a line only for a problem; it exits 0 even for `missing`.
    out="$(dpkg --root="$ROOT" --admindir="$ADMINDIR" -V "$pkg" 2>/dev/null)"
    if [ -n "$out" ]; then
        fail "$pkg does not verify clean after the payload step:"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
    else
        note "opt-owners:   clean $pkg"
    fi
}

declare -A REQUIRED=()
for pkg in "${REQUIRE[@]:-}"; do
    [ -n "$pkg" ] && REQUIRED["$pkg"]=1
done

# Every discovered owner must be clean (if it is installed).
for pkg in "${OWNERS[@]:-}"; do
    [ -n "$pkg" ] || continue
    if [ -n "${REQUIRED[$pkg]:-}" ]; then
        verify_pkg "$pkg" 1
        unset 'REQUIRED[$pkg]'
    else
        verify_pkg "$pkg" 0
    fi
done
# Any explicitly required package that owns no /opt/singularity file (or was
# not discovered) is still required to be installed.
for pkg in "${!REQUIRED[@]}"; do
    verify_pkg "$pkg" 1
done

if [ "$FAIL" != 0 ]; then
    echo "opt-owners: FAILED -- a payload swap dropped or modified package-owned files under /opt/singularity" >&2
    exit 1
fi
note "opt-owners: OK -- all package-owned files under /opt/singularity verify clean"
exit 0
