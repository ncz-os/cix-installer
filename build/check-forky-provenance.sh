#!/bin/bash
# check-forky-provenance.sh -- every package must have exactly one origin:
#   NCZ (our namespace / +ncz builds), a reviewed vendor deb (manifests/vendor-debs.tsv,
#   sha256-pinned), or byte-identical to the pinned Debian forky snapshot
#   (release.conf NCZ_BASE_MIRROR_SNAPSHOT). Anything else -- Ubuntu, another Debian
#   suite or an older snapshot, unknown origin -- fails. No allow-by-reason escape hatch.
# Also audits apt sources/preferences (only forky + the NCZ repo + offline pools + the
# reviewed vendor repos in manifests/vendor-repos.tsv) and os-release (no Ubuntu lineage).
#
# Usage: build/check-forky-provenance.sh SCAN...    (see build/forky-provenance.py --help)
#   --image IMG --work DIR     a finished .img (no root, no loop mount: uses debugfs)
#   --debs DIR | --packages F | --status F | --rootfs DIR | --squashfs F
# The snapshot index is verified against the committed trust metadata
# (manifests/forky-snapshot.tsv) every run, so its directory may live anywhere
# the caller chooses; full callers pass --index-dir (ship-image.sh does).
# Exit 0 clean, 1 violations, 2 usage / no index (fails closed).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# No HOME-derived, environment-steerable cache and no trust-root override: the
# Python verifier owns the trust root (this checkout) and cryptographically
# verifies the index contents.  --ubuntu-only (offline lint) needs no index.
exec python3 -I "$HERE/forky-provenance.py" "$@"
