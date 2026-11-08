#!/usr/bin/env bash
# test-one-kernel-entrypoint-parity.sh -- the two image entrypoints must produce
# the same /cdrom pool.
#
# WHY. The one-kernel policy (docs/ONE-KERNEL.md) removes the substrate's Debian
# kernel/module/binary udebs from the copied pool.  That strip runs only when
# NCZ_ONE_KERNEL=1, and today:
#
#   Makefile:228        NCZ_ONE_KERNEL ?= 1   +  export   -> make release-image STRIPS
#   build/build-image.sh  never sets it                    -> the documented
#                                                            "single entrypoint"
#                                                            does NOT strip
#
# So the same tree produces two different images depending on how you invoke it,
# and the provenance gate then reports ~32 udebs that one invocation would have
# removed.  That is why the class-K question could not be answered by reading the
# policy: the policy is applied by only one of the two entrypoints.
#
# build-image.sh now sets the same default (NCZ_ONE_KERNEL="${NCZ_ONE_KERNEL:-1}"),
# so NCZ_EXPECT_ONE_KERNEL_ALIGNED defaults to 1 and the parity assertion is
# hard-red if anyone removes it again (NCZ_EXPECT_ONE_KERNEL_ALIGNED=0 restores
# the old XFAIL report).
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MK="$ROOT/Makefile"
BI="$ROOT/build/build-image.sh"
pass=0; fail=0; xfail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
xf()  { xfail=$((xfail + 1)); echo "  XFAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

[ -s "$MK" ] || { echo "missing $MK"; exit 1; }
[ -s "$BI" ] || { echo "missing $BI"; exit 1; }

# 1. the policy is real and the Makefile applies it
grep -qE '^NCZ_ONE_KERNEL[[:space:]]*\?=[[:space:]]*1' "$MK" \
    && ok "the Makefile defaults NCZ_ONE_KERNEL to 1" \
    || bad "the Makefile no longer defaults NCZ_ONE_KERNEL=1 -- one-kernel policy changed"
grep -qE '^export[[:space:]]+NCZ_ONE_KERNEL' "$MK" \
    && ok "the Makefile exports it to the build" \
    || bad "the Makefile does not export NCZ_ONE_KERNEL"

# 2. does the build script apply the same policy by itself?
bi_sets=0
grep -qE 'NCZ_ONE_KERNEL' "$BI" && bi_sets=1

if [ "$bi_sets" = 0 ]; then
    # the known defect
    if [ "${NCZ_EXPECT_ONE_KERNEL_ALIGNED:-1}" = 1 ]; then
        bad "build-image.sh still does not set NCZ_ONE_KERNEL (expected aligned)"
    else
        xf "build-image.sh does not set NCZ_ONE_KERNEL: 'make release-image' strips the substrate kernel udebs and build-image.sh does not (known defect)"
    fi
else
    # once it sets it, the value must be a 1 default, not a passthrough
    python3 - "$BI" <<'PY' || bad "build-image.sh sets NCZ_ONE_KERNEL but not to a default of 1"
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# accept either a plain assignment default or the -? : "..." form the script uses
m = re.search(r'NCZ_ONE_KERNEL="?\$\{NCZ_ONE_KERNEL:-1\}"?', src) or \
    re.search(r'^NCZ_ONE_KERNEL=1\b', src, re.M) or \
    re.search(r'export\s+NCZ_ONE_KERNEL=1\b', src)
sys.exit(0 if m else 1)
PY
    ok "build-image.sh sets NCZ_ONE_KERNEL=1 by default"
    if [ "${NCZ_EXPECT_ONE_KERNEL_ALIGNED:-1}" = 1 ]; then
        ok "the two entrypoints agree (fix verified)"
    else
        echo "  NOTE  the divergence is fixed; flip NCZ_EXPECT_ONE_KERNEL_ALIGNED=1 in CI"
    fi
fi

# 3. and the strip itself must still be gated on that variable -- if the writer
#    ever strips unconditionally, this test's premise is wrong.
grep -qE 'environ\.get\("NCZ_ONE_KERNEL"\)' "$ROOT/build/iso/write-usb-image.py" \
    && ok "the ISO writer still gates the strip on NCZ_ONE_KERNEL" \
    || bad "the ISO writer no longer reads NCZ_ONE_KERNEL -- the strip is unconditional and this test is stale"

echo "one-kernel entrypoint parity: $pass passed, $fail failed, $xfail xfail"
[ "$fail" = 0 ]
