#!/bin/bash
# release-identity.sh — shared, side-effect-free derivation of the NCZ release
# identity strings from release.conf, so no build or gate hardcodes a codename
# that release.conf has since changed.
#
# release.conf is the single source of truth for the product name, version and
# codename (docs/releases/26.10-cygnus.md §2.1). The retired ISO builder derived
# its volume label from it, and anything that labels a medium must derive the
# SAME label, or the medium carries a stale codename (the `NCZ_MAXIMILIAN` label
# left over from 26.7 was exactly that bug).
#
# Source it from a bash script (all callers are bash):
#   # shellcheck source=lib/release-identity.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/release-identity.sh"
#
# Sets:
#   NCZ_RELEASE_LABEL   "NCZ-OS 26.10 Cygnus"  (product version codename)
#   NCZ_ISO_VOLUME_ID   "NCZ_CYGNUS"           (ISO 9660: [A-Z0-9_], <= 32)
#
# Exits (does not return) if release.conf is unreadable or lacks an identity
# field: a gate must not build an ambiguously-labelled medium.

# shellcheck disable=SC2034  # the two exports below are consumed by the sourcing script
# shellcheck disable=SC1091  # release.conf is resolved at runtime, not statically

# Resolve the repo root from THIS file's location (build/lib/ -> repo root).
_ncz_ri_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ ! -r "$_ncz_ri_root/release.conf" ]; then
    echo "release-identity: cannot read $_ncz_ri_root/release.conf" >&2
    exit 1
fi

# shellcheck source=../../release.conf
. "$_ncz_ri_root/release.conf"
: "${NCZ_PRODUCT_NAME:?release.conf did not define NCZ_PRODUCT_NAME}"
: "${NCZ_RELEASE_VERSION:?release.conf did not define NCZ_RELEASE_VERSION}"
: "${NCZ_RELEASE_CODENAME:?release.conf did not define NCZ_RELEASE_CODENAME}"

NCZ_RELEASE_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"

# ISO 9660 volume ids are upper case, digits and underscore, at most 32 chars.
NCZ_ISO_VOLUME_ID="NCZ_$(printf %s "$NCZ_RELEASE_CODENAME" \
    | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_' | cut -c1-28)"

unset _ncz_ri_root
