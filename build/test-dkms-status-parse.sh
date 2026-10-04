#!/bin/bash
# test-dkms-status-parse.sh -- prove ncz_dkms_registered_pkgvers (extracted
# from build/build-kernel-debs.sh) parses every `dkms status` line shape
# the postinst sees on the board and never emits a trailing ':'.
#
# Why this test exists: the 7.2.8 -> 7.2.9 OTA on O6N (2026-10-04) failed
# with `The module/version combo: panthor-cix/7.2.0: is not located in the
# DKMS tree`. Root cause: the loop's `awk -F, ... | awk '{print $1}'`
# pipeline left the colon on registered-but-never-built lines (no comma
# before the colon, so the split never happened) and every dkms call for
# that package then died. ncz_dkms_registered_pkgvers is the fix.
#
# The function lives inside the linux-headers-cixmini postinst heredoc in
# build/build-kernel-debs.sh, framed by `# BEGIN ncz_dkms_registered_pkgvers`
# and `# END ncz_dkms_registered_pkgvers` markers so we can grep the source
# file, strip the heredoc indentation, and source the function here without
# having to invoke dpkg-deb/extract the postinst file.
#
# Run: bash build/test-dkms-status-parse.sh
# Exit 0 = all PASS, non-zero = one or more FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/build/build-kernel-debs.sh"

[ -f "$SRC" ] || { echo "EXTRACT FAILED: $SRC not found" >&2; exit 2; }

PASS=0
FAIL=0

# Pretty-print a multi-line expected/actual for diff-style failure output.
dump_lines() {
    printf '%s\n' "$1" | sed 's/^/        | /'
}

# Assert two strings are equal. The "want" string is a here-doc with newlines
# preserved by the caller; "got" is whatever the function printed.
expect() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        echo "        want:"
        dump_lines "$want"
        echo "        got :"
        dump_lines "$got"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# 1. Extract the function definition from build/build-kernel-debs.sh between
#    the marker lines. The block lives inside the postinst heredoc, which is
#    itself inside a build-script function, so every line has leading
#    whitespace; strip it so the body is valid bash at top level when sourced.
# ---------------------------------------------------------------------------
func_text=$(awk '
    /# BEGIN ncz_dkms_registered_pkgvers/ { inblk=1; next }
    /# END ncz_dkms_registered_pkgvers/   { inblk=0 }
    inblk { sub(/^[ \t]+/, ""); print }
' "$SRC")
if [ -z "$func_text" ]; then
    echo "EXTRACT FAILED: could not find ncz_dkms_registered_pkgvers markers in $SRC" >&2
    exit 2
fi

# Source the function into this shell.
eval "$func_text"

# Sanity: the function is actually defined.
if ! declare -F ncz_dkms_registered_pkgvers >/dev/null; then
    echo "EXTRACT FAILED: function did not register in this shell after eval" >&2
    echo "Extracted text:" >&2
    printf '%s\n' "$func_text" | sed 's/^/    /' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Fixtures.
# ---------------------------------------------------------------------------

# (a) The real O6N `dkms status` that broke 7.2.8 -> 7.2.9.
read -r -d '' fixture_a <<'EOF' || true
aipu/6.2.0, 7.3.0-rc5-sky1-ncz, aarch64: installed
cix-gpu-kmd/1.0: added
cix-vpu-driver/1.0.2-ncz1, 7.3.0-rc5-sky1-ncz, aarch64: installed (Original modules exist)
panthor-cix/7.2.0: added
EOF
want_a='aipu/6.2.0
cix-gpu-kmd/1.0
cix-vpu-driver/1.0.2-ncz1
panthor-cix/7.2.0'

# (b) Only `added` lines (the shape that broke the old pipeline).
read -r -d '' fixture_b <<'EOF' || true
cix-gpu-kmd/1.0: added
panthor-cix/7.2.0: added
EOF
want_b='cix-gpu-kmd/1.0
panthor-cix/7.2.0'

# (c) Only built/installed lines (the shape the old pipeline got right).
read -r -d '' fixture_c <<'EOF' || true
aipu/6.2.0, 7.3.0-rc5-sky1-ncz, aarch64: installed
cix-vpu-driver/1.0.2-ncz1, 7.3.0-rc5-sky1-ncz, aarch64: built
EOF
want_c='aipu/6.2.0
cix-vpu-driver/1.0.2-ncz1'

# (d) Empty input -- nothing registered.
fixture_d=''
want_d=''

# (e) Line with extra leading/trailing spaces and a bare blank line.
read -r -d '' fixture_e <<'EOF' || true
   aipu/6.2.0, 7.3.0-rc5-sky1-ncz, aarch64: installed

  cix-gpu-kmd/1.0: added   
EOF
want_e='aipu/6.2.0
cix-gpu-kmd/1.0'

# ---------------------------------------------------------------------------
# 3. Run the fixtures through ncz_dkms_registered_pkgvers.
# ---------------------------------------------------------------------------
# printf eats trailing newlines, so append one explicitly to each fixture
# (sort -u / awk are line-oriented and the last fixture line must end in
# newline to be processed).
run_fixture() {
    local label="$1" want="$2" input="$3"
    local got
    got="$(printf '%s\n' "$input" | ncz_dkms_registered_pkgvers)"
    expect "$label" "$want" "$got"
}

echo "=== (a) real O6N dkms status (the bug case) ==="
run_fixture "parses installed + added + (Original modules exist)" "$want_a" "$fixture_a"

echo '=== (b) only `added` lines ==='
run_fixture "no comma before the colon, no trailing colon" "$want_b" "$fixture_b"

echo "=== (c) only built/installed lines ==="
run_fixture "strips ', kver, arch: installed|built' tail" "$want_c" "$fixture_c"

echo "=== (d) empty input ==="
run_fixture "empty input produces empty output" "$want_d" "$fixture_d"

echo "=== (e) line with extra leading/trailing spaces + blank line ==="
run_fixture "tolerates whitespace and blank lines" "$want_e" "$fixture_e"

# ---------------------------------------------------------------------------
# 4. Regression guard: NO output line of the function contains a ':' on any
#    of the inputs that contain real dkms-status lines. The whole bug class
#    reduces to "the function returned a string with a trailing colon", so
#    belt-and-braces assert it directly.
# ---------------------------------------------------------------------------
echo "=== regression guard: no ':' in any emitted line across fixtures (a), (b), (c), (e) ==="
all_out="$(printf '%s\n%s\n%s\n%s\n' "$fixture_a" "$fixture_b" "$fixture_c" "$fixture_e" | ncz_dkms_registered_pkgvers)"
if printf '%s\n' "$all_out" | grep -q ':'; then
    echo "  FAIL  function emitted a colon-bearing line:"
    printf '%s\n' "$all_out" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
else
    echo "  PASS  no ':' anywhere"
    echo "        emitted:"
    dump_lines "$all_out"
    PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# 5. Negative control: run the OLD pipeline on fixture (a) and prove it
#    DOES produce a colon. If this assertion ever fails the bug has
#    mysteriously healed itself OR the fixture has been changed -- either
#    way, the test must fail loudly so the change is visible.
# ---------------------------------------------------------------------------
echo '=== negative control: old `awk -F, ... | awk ... | sort -u` pipeline on fixture (a) ==='
old_out="$(printf '%s\n' "$fixture_a" | awk -F',' '{print $1}' | awk '{print $1}' | sort -u)"
if printf '%s\n' "$old_out" | grep -q ':'; then
    echo "  PASS  old pipeline still reproduces the bug:"
    dump_lines "$old_out"
    PASS=$((PASS + 1))
else
    echo "  FAIL  old pipeline no longer reproduces the bug:"
    dump_lines "$old_out"
    echo "        (fixture or pipeline has drifted; investigate before relaxing the test)"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 6. Belt-and-braces: confirm the old pipeline's bad output really is the
#    bad output we think it is, so a future refactor that "fixes" the old
#    pipeline by accident still trips a test.
# ---------------------------------------------------------------------------
echo "=== negative control: old pipeline on fixture (a) emits exactly the buggy 4 lines ==="
want_old='aipu/6.2.0
cix-gpu-kmd/1.0:
cix-vpu-driver/1.0.2-ncz1
panthor-cix/7.2.0:'
expect "old pipeline emits exactly the documented buggy output" "$want_old" "$old_out"

echo
echo "=== dkms status parse test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]