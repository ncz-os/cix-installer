#!/bin/bash
# test-t2smc-range.sh -- compile and run the userspace boundary tests for the
# t2smc range validators.
#
# The validators are added by assets/kernel/t2smc/patches/0001-t2smc-range-checks.patch
# (as src/t2smc_range.h). To test exactly what DKMS builds, apply the patch to
# a scratch copy of the vendored source and compile the test against that.
#
# No kernel, no hardware, no module load.
#
# Run: bash build/test-t2smc-range.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MOD="$ROOT/assets/kernel/t2smc"
PATCH="$MOD/patches/0001-t2smc-range-checks.patch"
TESTC="$MOD/tests/test_t2smc_range.c"

CC="${CC:-cc}"

SCRATCH="$(mktemp -d "$ROOT/.t2smc-range-test.XXXXXX")" || exit 2
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

mkdir -p "$SCRATCH/src"
cp "$MOD/src/t2smc.c" "$MOD/src/Makefile" "$SCRATCH/src/"
if ! ( cd "$SCRATCH" && patch -p1 --silent < "$PATCH" ); then
    echo "FAIL: could not apply $PATCH to a pristine copy" >&2
    exit 2
fi

if [ ! -f "$SCRATCH/src/t2smc_range.h" ]; then
    echo "FAIL: patch did not add src/t2smc_range.h" >&2
    exit 2
fi

if ! "$CC" -std=c11 -Wall -Wextra -Werror -I "$SCRATCH/src" \
        "$TESTC" -o "$SCRATCH/test_t2smc_range"; then
    echo "FAIL: test compile failed" >&2
    exit 2
fi

"$SCRATCH/test_t2smc_range"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: t2smc range tests failed (rc=$rc)" >&2
    exit 1
fi
echo "PASS: t2smc range tests"
exit 0
