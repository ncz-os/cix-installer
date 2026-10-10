#!/bin/bash
# check-sid-exceptions.sh -- track the reviewed sid exceptions and enforce the
# "gradually replace with forky" loop.
#
#   * every manifests/sid-exceptions.tsv row is compared with the PINNED forky
#     snapshot and the LATEST forky (deb.debian.org / rmadison);
#   * a row forky now provides at >= the recorded version is GRADUATED and must
#     be removed ("use forky"); an expired review_by must be re-reviewed;
#   * writes docs/SID-EXCEPTIONS.md (generated) and prints the per-arch sid
#     component count + trend;
#   * --receipt <img>.receipt.json records the count in the image receipt.
#
# Usage:
#   build/check-sid-exceptions.sh [--strict] [--offline] [--receipt FILE]
# Exit 0 = no action; 1 = a GRADUATED/EXPIRED row (--strict) or a finding;
#      2 = usage/IO error.
#
# This is a stage in the refresh/pin flow (make sid-exceptions /
# refresh-substrate.sh); the provenance gate independently FAILS a shipped image
# that carries a graduated or expired exception.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec python3 -I "$HERE/check-sid-exceptions.py" "$@"
