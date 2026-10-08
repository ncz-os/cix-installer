# mirror-apt-opts.sh — shared helpers for consumers of a pinned snapshot mirror.
# shellcheck shell=bash
#
# release.conf sets NCZ_BASE_MIRROR_APT_OPTS=check-valid-until=no only while
# NCZ_BASE_MIRROR_SNAPSHOT is set. A snapshot Release carries a short
# Valid-Until; apt refuses it once that date passes unless every deb line
# that points at the pin carries the option. An unpinned build leaves the
# variable empty and these helpers emit a plain "deb URI suite components"
# line, so live-mirror expiry checks stay on.
#
# Sourced, never executed. No set -e here: the caller owns the shell options.

# ncz_mirror_deb_line URI SUITE COMPONENTS
# Print one sources.list deb line. Appends [NCZ_BASE_MIRROR_APT_OPTS] only
# when that variable is non-empty, the same way build-forky-mirror.sh and
# build-desktop-mirror.sh do.
ncz_mirror_deb_line() {
    local uri="$1" suite="$2" components="$3"
    if [ -n "${NCZ_BASE_MIRROR_APT_OPTS:-}" ]; then
        printf "deb [%s] %s %s %s\n" "$NCZ_BASE_MIRROR_APT_OPTS" "$uri" "$suite" "$components"
    else
        printf "deb %s %s %s\n" "$uri" "$suite" "$components"
    fi
}

# ncz_mirror_sources_list
# Print the chroot sources.list for the active profile.
#   $1 URI of the base mirror (NCZ_BASE_MIRROR / the caller's MIRROR)
#   $2 suite (NCZ_BASE_CODENAME)
#   $3 components
#   $4 "updates" to also emit $suite-updates on the same URI, or "" to skip
#   $5 security URI, or "" to skip the security line
#   $6 security suite name (typically $suite-security)
#
# A pinned snapshot.debian.org timestamp serves the base suite and
# $suite-updates. It does not serve $suite-security: that pocket lives on
# snapshot.debian.org/archive/debian-security under its own timestamp, and
# its Packages files are empty for forky. Passing a security URI here still
# emits the line (with the same options) so the caller's historical
# sources.list shape is preserved; the caller decides whether that URI is
# one the pin can actually fetch.
ncz_mirror_sources_list() {
    local uri="$1" suite="$2" components="$3" updates="$4" sec_uri="$5" sec_suite="$6"
    ncz_mirror_deb_line "$uri" "$suite" "$components"
    if [ "$updates" = "updates" ]; then
        ncz_mirror_deb_line "$uri" "${suite}-updates" "$components"
    fi
    if [ -n "$sec_uri" ]; then
        ncz_mirror_deb_line "$sec_uri" "$sec_suite" "$components"
    fi
}

# ncz_apt_update_or_die LOG LABEL -- apt-get-args...
# Run apt-get update, keep the log, and on failure print its E:/W: lines
# (the whole log if apt printed neither) then exit 1. Same contract as
# build-desktop-mirror.sh: a swallowed apt-get update is how the expired
# snapshot pin failed as a bare "Error 100".
ncz_apt_update_or_die() {
    local log="$1" label="$2"
    shift 2
    if ! "$@" >"$log" 2>&1; then
        echo "ERROR: apt-get update failed (${label}):" >&2
        grep -E "^(E|W):" "$log" >&2 || cat "$log" >&2
        exit 1
    fi
}

# ncz_pkgs_from_manifest MANIFEST
# Package names from a .pkgs manifest: drop comments and blanks, keep the
# first field, dedupe. Prints the names space-separated with a trailing
# space when non-empty, or nothing when the manifest has no packages.
#
# The previous form ended the pipeline with `grep .` under `set -o pipefail`.
# grep exits 1 on no match, which kills the script before the assignment and
# prints nothing. An empty manifest is a bug and must say so; a manifest
# that only contains comments is the same bug.
ncz_pkgs_from_manifest() {
    local manifest="$1" names
    names="$(grep -vE "^[[:space:]]*(#|$)" "$manifest" | sed "s/#.*//" | awk "NF {print \$1}" | sort -u | tr "\n" " " || true)"
    if [ -z "${names%"${names##*[![:space:]]}"}" ]; then
        echo "ERROR: package manifest has no packages: $manifest" >&2
        return 1
    fi
    printf "%s" "$names"
}

# ncz_package_record_count PACKAGES_FILE
# Count "^Package: " records. `grep -c` exits 1 when the count is 0 and, under
# pipefail, that kills the script with no message. An empty index is a bug.
ncz_package_record_count() {
    local packages="$1" count
    count="$(grep -c "^Package: " "$packages" || true)"
    if [ "${count:-0}" -eq 0 ]; then
        echo "ERROR: package index has no Package records: $packages" >&2
        return 1
    fi
    printf "%s\n" "$count"
}

# ncz_require_debian_forky SUITE MIRROR [BASE_NAME]
# Operator rule 2026-10-08: "We shouldn't be using Ubuntu debs ever" and "we
# should only use Debian versions from forky". Every rootfs/mirror builder calls
# this before it touches a network or a chroot. Returns 1 (with a message) for
# any non-forky suite or any non-Debian mirror; callers `|| exit 1`.
ncz_require_debian_forky() {
    local suite="$1" mirror="$2" base="${3:-Debian}"
    if [ "$suite" != "forky" ]; then
        echo "ERROR: suite '$suite' refused: only Debian forky is allowed (no Ubuntu, trixie, stable, sid, backports)" >&2
        return 1
    fi
    case "$mirror" in
        *ubuntu*|*launchpad*|*canonical*)
            echo "ERROR: mirror '$mirror' refused: Ubuntu archives are never allowed" >&2
            return 1 ;;
    esac
    case "$mirror" in
        https://snapshot.debian.org/*|http://snapshot.debian.org/*|https://deb.debian.org/debian*|http://deb.debian.org/debian*|file:*|/*) ;;
        *)
            echo "ERROR: mirror '$mirror' refused: not a Debian archive or snapshot.debian.org" >&2
            return 1 ;;
    esac
    if [ "$base" != "Debian" ]; then
        echo "ERROR: NCZ_BASE_NAME='$base' refused: only Debian" >&2
        return 1
    fi
    return 0
}
