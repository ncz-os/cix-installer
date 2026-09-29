#!/bin/bash
# test-late-union-sync.sh -- regression test for preseed/late.sh's asset
# union-sync when the baked layer carries a DANGLING absolute symlink where the
# install media has a populated directory (assets/kernel/mainline).
#
# Extracts the union-sync subshell from late.sh and runs it under `set -e`
# (late.sh's mode) against a fixture, with both a dangling link at
# kernel/mainline and a directory that sorts LAST in `find` order beneath it -- the
# exact shape that killed the 2026-09-29 arm64 install. A control run with the
# pre-fix loop must fail, so the test proves it can detect the defect.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LATE="$HERE/../preseed/late.sh"
SH="${TEST_SH:-sh}"

W="$(mktemp -d -t late-union.XXXXXX)"
trap 'rm -rf "$W"' EXIT

extract() {   # $1 = mode: fixed|prefix
    python3 - "$LATE" "$1" <<'EOF'
import sys
s = open(sys.argv[1]).read()
a = s.index('        ( cd "$SRC/assets" || exit 0')
b = s.index("          true )", a) + len("          true )") if "          true )" in s[a:] else None
if b is None:
    b = s.index("          done )", a) + len("          done )")
blk = s[a:b]
if sys.argv[2] == "prefix":
    # the pre-fix behavior: plain mkdir -p, status of last iteration decides
    import re
    blk = re.sub(r'if \[ -L "\$DSTA/\$d" \].*?fi\n\s*mkdir -p "\$DSTA/\$d" \|\| \\\n\s*echo [^\n]*\n',
                 'mkdir -p "$DSTA/$d"\n', blk, flags=re.S)
    blk = blk.replace("          true )", "          )")
print(blk)
EOF
}

run_case() {  # $1 name  $2 mode  $3 expected rc
    local name="$1" mode="$2" want="$3" src="$W/src-$RANDOM" dsta rc
    dsta="$W/dst-$RANDOM"
    mkdir -p "$src/assets/kernel/mainline/headers-dir/zzz/deep" "$dsta/kernel"
    echo k > "$src/assets/kernel/mainline/KVER"
    echo d > "$src/assets/kernel/mainline/headers-dir/zzz/deep/file"
    ln -s /nonexistent/kernel-staging/r277 "$dsta/kernel/mainline"          # dangling, like base.squashfs
    {
        echo 'set -e'
        echo "SRC=$src DSTA=$dsta"
        extract "$mode"
        echo 'echo union-done'
    } > "$W/run.sh"
    "$SH" "$W/run.sh" > "$W/out" 2>&1; rc=$?
    if [ "$rc" = "$want" ] && { [ "$want" != 0 ] || [ -f "$dsta/kernel/mainline/headers-dir/zzz/deep/file" ]; }; then
        echo "PASS  $name (rc=$rc)"; PASS=$((PASS + 1))
    else
        echo "FAIL  $name: rc=$rc want=$want"; sed 's/^/      /' "$W/out"; FAILS=$((FAILS + 1))
    fi
}
PASS=0; FAILS=0
run_case "fixed union-sync replaces the dangling mainline link and copies the tree" fixed 0
run_case "control: pre-fix loop dies on the dangling link (test can detect it)" prefix 1
echo "late union-sync tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
