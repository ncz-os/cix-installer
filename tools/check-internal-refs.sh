#!/usr/bin/env bash
# Usage: check-internal-refs.sh BASE [TIP]
# Omit TIP to check tracked working-tree changes against BASE.
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    echo 'Usage: check-internal-refs.sh BASE [TIP]' >&2
    exit 2
fi

checker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-internal-refs.py"
cd "$(git rev-parse --show-toplevel)"
base=$(git rev-parse --verify --end-of-options "$1^{commit}")
revisions=("$base")
if (( $# == 2 )); then
    revisions+=("$(git rev-parse --verify --end-of-options "$2^{commit}")")
fi

git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv \
    --no-renames --unified=0 "${revisions[@]}" -- |
    python3 "$checker"
