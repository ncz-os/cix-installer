#!/bin/bash
# test-singularity-shaders-gate.sh -- both-direction tests for
# build/check-singularity-shaders.sh (the SceneFX/libmali static gate).
#
# The gate is only useful if it FAILS CLOSED: it must reject a quoted `#error`
# and also reject a read/tooling/format failure (non-ELF, strings error,
# shader-less binary).  Each case below asserts the exact exit code.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-singularity-shaders.sh"
[ -x "$GATE" ] || [ -f "$GATE" ] || { echo "missing $GATE" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-shadergate.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { local want="$1" got="$2" what="$3"; if [ "$want" = "$got" ]; then echo "ok   $what"; pass=$((pass+1)); else echo "FAIL $what (want rc=$want got rc=$got)"; fail=$((fail+1)); fi; }

# an ELF magic prefix + printable payload (strings sees the payload)
mk_elf() { { printf '\177ELF'; printf '%s\n' "$1"; } > "$2"; }

mk_elf '#error "Missing shader preamble"' "$T/quoted"
mk_elf '#error Missing shader preamble'   "$T/unquoted"
mk_elf 'nothing shader-ish here'          "$T/noshader"
printf 'not an elf\n#error "x"\n'          > "$T/notelf"

"$GATE" "$T/quoted"   >/dev/null 2>&1; check 1 $? "quoted #error FAILS closed"
"$GATE" "$T/unquoted" >/dev/null 2>&1; check 0 $? "unquoted #error passes"
"$GATE" "$T/notelf"   >/dev/null 2>&1; check 2 $? "non-ELF is rejected (rc=2)"
"$GATE" "$T/noshader" >/dev/null 2>&1; check 1 $? "shader-less ELF FAILS closed"
NCZ_SHADER_GATE_ALLOW_NO_SCENEFX=1 "$GATE" "$T/noshader" >/dev/null 2>&1; check 0 $? "shader-less ELF passes with the override"
"$GATE" "$T/does-not-exist" >/dev/null 2>&1; check 2 $? "missing file is rejected"
"$GATE" >/dev/null 2>&1; check 2 $? "no argument is a usage error (rc=2)"

# both binaries at once: any bad one fails the run
"$GATE" "$T/unquoted" "$T/quoted" >/dev/null 2>&1; check 1 $? "one bad binary fails the whole run"

echo "shader-gate tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
