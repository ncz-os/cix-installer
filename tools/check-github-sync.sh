#!/bin/bash
# check-github-sync.sh -- verify that GitHub matches GitLab.
#
# For every GitLab branch and tag, the expected tree is the GitLab tree with the
# copy's exclusions applied (blobs over the GitHub file limit or in
# tools/github-sync/strip-blobs.txt left out, listed text replaced). It must
# equal the tree of the GitHub ref of the same name. Refs only on one side are
# reported too. Exit 0 = in sync, 1 = drift, 2 = setup error.
#
#   tools/check-github-sync.sh [--repo NAME]... [--verbose] [--report out.tsv]
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec python3 "$HERE/github-sync/ghsync.py" check "$@"
