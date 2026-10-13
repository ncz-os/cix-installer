#!/bin/bash
# build/assert-mirror-has-screensavers.sh -- shared pre-flight for both
# build-squashfs-layers.sh and build-role-delta-mkosi.sh (and any future
# ISO-layer builder that consumes the offline mirror). Fails the build with
# a precise "missing package" message when the desktop-mirror (or any
# caller-specified mirror) does not carry ncz-screensavers at the required
# version floor.
#
# Reads the version floor from build/screensavers-version.env (single source
# of truth, shared with post-install/59-ncz-screensavers-pkg.sh and the
# post-install verifier). If the floor file is missing this script refuses
# to run -- without a floor a build cannot prove the package is new enough.
#
# Usage:
#   build/assert-mirror-has-screensavers.sh --mirror PATH [--mirror PATH2 ...] \
#                                            [--label NAME] [--arch ARCH]
# Exit codes:
#   0  every named mirror carries ncz-screensavers at >= NCZ_SCREENSAVERS_MIN_VERSION
#   1  at least one mirror is missing it OR has a too-old candidate
#   2  bad invocation
#
# IMPORTANT: this script is shared with build-desktop-mirror.sh's own
# version-floor check (which guards the pool population). Keep the floor and
# error messages sourced from the same file so an operator log line is
# immediately recognisable across every script that fires it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCREENSAVERS_VERSION_ENV="$HERE/screensavers-version.env"
if [ ! -r "$SCREENSAVERS_VERSION_ENV" ]; then
    echo "assert-mirror-has-screensavers: FATAL: $SCREENSAVERS_VERSION_ENV not readable -- refusing to assert without a version floor" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$SCREENSAVERS_VERSION_ENV"
# set -u only catches unset names; dpkg --compare-versions X ge "" returns 0,
# so an empty floor would accept any version. Require non-empty values.
for _ssv in NCZ_SCREENSAVERS_MIN_VERSION NCZ_SCREENSAVERS_MISSING_MSG NCZ_SCREENSAVERS_TOO_OLD_MSG; do
    if [ -z "${!_ssv:-}" ]; then
        echo "assert-mirror-has-screensavers: FATAL: $_ssv is empty or missing in $SCREENSAVERS_VERSION_ENV -- refusing to run without a version floor" >&2
        exit 1
    fi
done

# Version comparison: prefer dpkg --compare-versions; fall back to a shell-
# side compare if dpkg is missing. The fallback handles the dotted-numeric
# versions this package actually uses (0.7.x, 0.8.x, 0.9.x, 0.10+). It is
# NOT a full dpkg replacement -- it does NOT debias -- but it is good enough
# for the actual version set we expect. The test suite uses this fallback to
# run on macOS hosts without dpkg; production callers on the Linux build hosts always
# have it.
if command -v dpkg >/dev/null 2>&1; then
    _ss_ge() { dpkg --compare-versions "$1" ge "$2"; }
    _ss_gt() { dpkg --compare-versions "$1" gt "$2"; }
else
    # shell-side version compare: split on '.', compare numerically, then
    # lexicographically on any remaining suffix. Exact dpkg behaviour for
    # debian-style versions is more nuanced (epochs, ~, etc.) but for the
    # 0.7 / 0.8 / 0.9 / 0.10 dotted-numeric set we ship, this is enough.
    _ss_ge() {
        # $1=ver $2=floor: print 0 if $1 >= $2, 1 otherwise.
        if [ "$1" = "$2" ]; then return 0; fi
        case "$1" in "$2".*|"$2"-*) return 0 ;; esac
        awk -v a="$1" -v b="$2" 'BEGIN {
            n = split(a, A, "."); m = split(b, B, ".");
            for (i = 1; i <= (n < m ? n : m); i++) {
                ai = A[i] + 0; bi = B[i] + 0;
                if (ai < bi) exit 1;
                if (ai > bi) exit 0;
            }
            # common prefix identical: longer is "newer" only if its trailing
            # segment is non-empty; an exact equal is handled above
            if (n < m) exit 1;
            exit 0;
        }'; return $?
    }
    _ss_gt() {
        if [ "$1" = "$2" ]; then return 1; fi
        awk -v a="$1" -v b="$2" 'BEGIN {
            n = split(a, A, "."); m = split(b, B, ".");
            for (i = 1; i <= (n < m ? n : m); i++) {
                ai = A[i] + 0; bi = B[i] + 0;
                if (ai < bi) exit 1;
                if (ai > bi) exit 0;
            }
            if (n <= m) exit 1;
            exit 0;
        }'; return $?
    }
fi

usage() { echo "usage: $0 --mirror DIR [--mirror DIR2 ...] [--label NAME] [--arch ARCH]" >&2; }

MIRRORS=()
LABEL=""
ARCH=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror) MIRRORS+=("${2:-}"); shift 2 ;;
        --label)  LABEL="${2:-}"; shift 2 ;;
        --arch)   ARCH="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ "${#MIRRORS[@]}" -gt 0 ] || { echo "ERROR: --mirror required (one or more)" >&2; usage; exit 2; }

ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"

FAIL=0
for MIRROR in "${MIRRORS[@]}"; do
    [ -n "$MIRROR" ] || continue
    [ -d "$MIRROR" ] || { echo "ERROR: --mirror $MIRROR not a directory" >&2; FAIL=1; continue; }

    SUITE=""
    PKG_INDEX=""

    # Pick the best dists/<suite> path. desktop-mirror uses $NCZ_BASE_CODENAME,
    # others use the codename in their filename.
    for cand in "$MIRROR/dists"/*/main/binary-"$ARCH"/Packages; do
        if [ -f "$cand" ]; then
            SUITE="$(basename "$(dirname "$(dirname "$(dirname "$cand")")")")"
            PKG_INDEX="$cand"
            break
        fi
    done

    if [ -z "$PKG_INDEX" ] || [ ! -f "$PKG_INDEX" ]; then
        echo "assert-mirror-has-screensavers: ERROR: $LABEL mirror $MIRROR has no Packages index (suite=$SUITE, arch=$ARCH)" >&2
        FAIL=1
        continue
    fi

    # Find every ncz-screensavers row in the index; expect at least one with
    # Version >= floor. awk parses stanza records separated by blank lines and
    # emits "name version" pairs, one per line, so shell-side version comparison
    # can pick the newest that meets it.
    found_ok=""
    newest=""
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        v="${pair#* }"
        if [ -z "$newest" ] || _ss_gt "$v" "$newest" 2>/dev/null; then
            newest="$v"
        fi
        if _ss_ge "$v" "$NCZ_SCREENSAVERS_MIN_VERSION" 2>/dev/null; then
            found_ok="$v"
        fi
    done < <(awk '
        /^Package: ncz-screensavers$/ { in_pkg = 1; next }
        in_pkg && /^Version: / {
            v = substr($0, 10); sub(/^[[:space:]]*/, "", v)
            print "ncz-screensavers " v
            in_pkg = 0
        }
        /^$/ { in_pkg = 0 }
    ' "$PKG_INDEX")

    if [ -n "$found_ok" ]; then
        echo "assert-mirror-has-screensavers: OK  $LABEL mirror $MIRROR carries ncz-screensavers $found_ok (>= $NCZ_SCREENSAVERS_MIN_VERSION; newest available: ${newest:-none})"
    else
        echo "assert-mirror-has-screensavers: ERROR: $LABEL mirror $MIRROR does NOT carry ncz-screensavers >= $NCZ_SCREENSAVERS_MIN_VERSION" >&2
        echo "assert-mirror-has-screensavers:        newest available in index: ${newest:-NONE}" >&2
        echo "assert-mirror-has-screensavers:        ($NCZ_SCREENSAVERS_MISSING_MSG)" >&2
        echo "assert-mirror-has-screensavers:        packages index used: $PKG_INDEX" >&2
        FAIL=1
    fi
done

exit "$FAIL"
