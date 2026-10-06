#!/bin/bash
# test-t2-dkms-provenance.sh -- fail if any vendored T2 DKMS module is missing
# provenance.
#
# The four out-of-tree T2 modules under assets/kernel/ are copied from the
# KaiT2en-Fedora tree. Without a PROVENANCE file we cannot tell which upstream
# commit a vendored tree came from, cannot audit local edits, and cannot
# re-sync. This test enforces the minimum a PROVENANCE file must carry:
#   * a 40-hex upstream commit
#   * an SPDX-License-Identifier line
#   * a Source URL
# and that the vendored source it describes is actually present.
#
# Run: bash build/test-t2-dkms-provenance.sh
# Exit 0 = all PASS, non-zero = one or more FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ASSETS="$ROOT/assets/kernel"

MODULES="t2smc t2gmux t2smp t2thunderbolt"

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

for m in $MODULES; do
    prov="$ASSETS/$m/PROVENANCE"
    echo "== $m =="

    if [ ! -f "$prov" ]; then
        fail "$m: PROVENANCE missing ($prov)"
        continue
    fi

    if grep -Eq '^Upstream commit: [0-9a-f]{40}$' "$prov"; then
        pass "$m: 40-hex upstream commit present"
    else
        fail "$m: no 'Upstream commit: <40-hex>' line in PROVENANCE"
    fi

    if grep -Eq '^SPDX-License-Identifier: .+' "$prov"; then
        pass "$m: SPDX licence line present"
    else
        fail "$m: no 'SPDX-License-Identifier:' line in PROVENANCE"
    fi

    if grep -Eq '^Source: https?://' "$prov"; then
        pass "$m: Source URL present"
    else
        fail "$m: no 'Source: <url>' line in PROVENANCE"
    fi

    if [ -f "$ASSETS/$m/src/$m.c" ]; then
        pass "$m: vendored src/$m.c present"
    else
        fail "$m: vendored src/$m.c missing"
    fi

    if [ -f "$ASSETS/$m/dkms.conf" ]; then
        pass "$m: dkms.conf present"
    else
        fail "$m: dkms.conf missing"
    fi
done

echo
echo "t2-dkms-provenance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
