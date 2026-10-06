#!/bin/bash
# test-t2smc-range.sh -- compile and run the userspace boundary tests for the
# t2smc range validators.
#
# The validators are added by assets/kernel/t2smc/patches/0001-t2smc-range-checks.patch
# (as t2smc_range.h). To test exactly what DKMS builds, reproduce the DKMS tree:
# post-install/56-t2-dkms.sh flattens assets/kernel/t2smc/src/ into /usr/src/t2smc-0.1/,
# so the patch applies with -p1 at the module root (no src/ prefix). Apply it to a
# scratch copy of the flattened vendored source and compile the test against that.
#
# Every vendored t2smc patch is applied in order, so the header under test is
# the exact one DKMS compiles.  tests/test_t2smc_range.c covers the range
# predicates plus fault injection for S1 (temperature-discovery capacity),
# S2 (cache fill return value) and S3 (fan writes: rejection before
# narrowing, no needless F%dTg read, factory-envelope floor).  The
# "fail-before" checks reproduce the pre-fix behaviour inside the same binary
# to prove the tests detect the old defects.
#
# No kernel, no hardware, no module load.
#
# Run: bash build/test-t2smc-range.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MOD="$ROOT/assets/kernel/t2smc"
TESTC="$MOD/tests/test_t2smc_range.c"

CC="${CC:-cc}"

SCRATCH="$(mktemp -d "$ROOT/.t2smc-range-test.XXXXXX")" || exit 2
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

cp "$MOD/src/t2smc.c" "$MOD/src/Makefile" "$SCRATCH/"

# Apply every vendored t2smc patch in numeric order so the test exercises the
# final DKMS output (the validators + every hardening patch).
for p in "$MOD"/patches/*.patch; do
	if ! ( cd "$SCRATCH" && patch -p1 --silent < "$p" ); then
		echo "FAIL: could not apply $p to a pristine copy" >&2
		exit 2
	fi
done

# Strip patch's automatic .orig backups so the source-tree-digest stays clean.
find "$SCRATCH" -name '*.orig' -delete

if [ ! -f "$SCRATCH/t2smc_range.h" ]; then
	echo "FAIL: patch series did not add t2smc_range.h" >&2
	exit 2
fi

if ! "$CC" -std=c11 -Wall -Wextra -Werror -I "$SCRATCH" \
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