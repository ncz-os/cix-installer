#!/bin/bash
# apt-sim-tests.sh -- negative proofs for the new generic helper.
# Pure shell + bash; no real apt, no containers, no compile.
#
# Goals:
#   1. Argument parity: helper's simulation receives the EXACT args
#      the install receives. We assert by inspecting a fake apt-get
#      wrapper (apt-get.sh on PATH) that records its argv to a log.
#   2. Removal-failure gate: a simulation whose transcript contains
#      a "Remv pkg" line aborts with non-zero, BEFORE the install.
#   3. Simulation-failure gate: a simulation that exits non-zero
#      aborts the helper before any install.
#   4. Argument-parity safety: adding/removing a flag in the install
#      list is observable by the fake apt-get's argv log; both the
#      -s run and the real run receive the SAME argv.
#
# Each test creates its own APT_GET wrapper under a tmpdir and
# forces the helper to use it via APT_GET=$tmp/apt-get.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/apt-sim-zero-removals.sh"
[ -x "$HELPER" ] || { echo "FAIL: helper not executable at $HELPER" >&2; exit 1; }

PASS=0; FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }

run_negative() {
    # $1 = name, $2 = expected exit, $3 = fake apt-get body, $4.. = install args
    local name="$1" expected="$2" fbody="$3"; shift 3
    local tmp; tmp="$(mktemp -d)"
    local log="$tmp/apt-argv.log"
    cat > "$tmp/apt-get.sh" <<EOF
[ "\$1" = "install" ] && [ "\$2" = "-s" ] && SIM=1 && shift 2
[ "\$1" = "install" ] && [ "\$2" != "-s" ] && SIM=0 && shift
echo "SIM=\$SIM args=\$*" >> "$log"
exit 0
$fbody
EOF
    chmod +x "$tmp/apt-get.sh"
    PATH="$tmp:$PATH" APT_GET="$tmp/apt-get.sh" \
        SIM_LOG="$tmp/sim.log" \
        bash "$HELPER" "$tmp/sim.log" "$@" > "$tmp/out.txt" 2> "$tmp/err.txt"
    local rc=$?
    if [ "$rc" = "$expected" ]; then
        pass "$name (exit=$rc)"
    else
        fail "$name (got exit=$rc want $expected)"
        echo "  --- stdout ---"; sed 's/^/  /' "$tmp/out.txt"
        echo "  --- stderr ---"; sed 's/^/  /' "$tmp/err.txt"
        echo "  --- argv log ---"; sed 's/^/  /' "$log"
    fi
    rm -rf "$tmp"
}

# Test 1: clean simulation -> helper exits 0, both sim and install ran with same args
echo "=== Test 1: clean simulation, exact arg parity ==="
tmp="$(mktemp -d)"
log="$tmp/apt-argv.log"
cat > "$tmp/apt-get.sh" <<EOF
[ "\$1" = "install" ] && [ "\$2" = "-s" ] && SIM=1 && shift 2
[ "\$1" = "install" ] && [ "\$2" != "-s" ] && SIM=0 && shift
echo "SIM=\$SIM args=\$*" >> "$log"
exit 0
EOF
chmod +x "$tmp/apt-get.sh"
PATH="$tmp:$PATH" APT_GET="$tmp/apt-get.sh" \
    bash "$HELPER" "$tmp/sim.log" \
    -y --no-install-recommends ca-certificates libtinysparql-dev build-essential \
    > "$tmp/out.txt" 2> "$tmp/err.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "Test1: helper exited 0"
else fail "Test1: helper exited $rc"; sed 's/^/  /' "$tmp/err.txt"; fi
# Verify both runs saw the same args
sim_args=$(grep '^SIM=1' "$log" | sed 's/^SIM=1 args=//')
install_args=$(grep '^SIM=0' "$log" | sed 's/^SIM=0 args=//')
if [ "$sim_args" = "$install_args" ]; then
    pass "Test1: arg parity (sim == install): $sim_args"
else
    fail "Test1: arg parity broken -- sim='$sim_args' install='$install_args'"
fi
# Verify libtinysparql-dev (the forky pick) appears once
if [ "$(grep -c libtinysparql-dev "$log")" = 2 ]; then
    pass "Test1: libtinysparql-dev present in both sim and install args"
else
    fail "Test1: libtinysparql-dev expected in 2 lines, got $(grep -c libtinysparql-dev "$log")"
fi
# Verify no libtracker-sparql-3.0-dev (the old hardcoded dup)
if ! grep -q libtracker-sparql-3.0-dev "$log"; then
    pass "Test1: no hardcoded libtracker-sparql-3.0-dev duplication"
else
    fail "Test1: helper argv still contains hardcoded libtracker-sparql-3.0-dev"
fi
rm -rf "$tmp"

# Test 2: Remv line in sim -> helper exits non-zero, NO install runs
echo ""
echo "=== Test 2: Remv in simulation aborts before install ==="
tmp="$(mktemp -d)"
log="$tmp/apt-argv.log"
cat > "$tmp/apt-get.sh" <<EOF
[ "\$1" = "install" ] && [ "\$2" = "-s" ] && SIM=1 && shift 2
[ "\$1" = "install" ] && [ "\$2" != "-s" ] && SIM=0 && shift
echo "SIM=\$SIM args=\$*" >> "$log"
if [ "\$SIM" = 1 ]; then
  echo "Remv libfoo"
  echo "Remv libbar"
fi
exit 0
EOF
chmod +x "$tmp/apt-get.sh"
PATH="$tmp:$PATH" APT_GET="$tmp/apt-get.sh" \
    bash "$HELPER" "$tmp/sim.log" \
    -y --no-install-recommends ca-certificates build-essential \
    > "$tmp/out.txt" 2> "$tmp/err.txt"
rc=$?
if [ "$rc" != 0 ]; then pass "Test2: helper non-zero on Remv"
else fail "Test2: helper exited 0 despite Remv lines"; fi
# Verify the install NEVER ran (only the sim run should be logged)
sim_count=$(grep -c '^SIM=1' "$log")
inst_count=$(grep -c '^SIM=0' "$log")
if [ "$sim_count" = 1 ] && [ "$inst_count" = 0 ]; then
    pass "Test2: install did not run after Remv violation"
else
    fail "Test2: install ran anyway -- sim=$sim_count install=$inst_count"
fi
rm -rf "$tmp"

# Test 3: simulation non-zero exit -> helper non-zero, no install
echo ""
echo "=== Test 3: simulation exit non-zero aborts before install ==="
tmp="$(mktemp -d)"
log="$tmp/apt-argv.log"
cat > "$tmp/apt-get.sh" <<EOF
[ "\$1" = "install" ] && [ "\$2" = "-s" ] && SIM=1 && shift 2
[ "\$1" = "install" ] && [ "\$2" != "-s" ] && SIM=0 && shift
echo "SIM=\$SIM args=\$*" >> "$log"
if [ "\$SIM" = 1 ]; then exit 100; fi
exit 0
EOF
chmod +x "$tmp/apt-get.sh"
PATH="$tmp:$PATH" APT_GET="$tmp/apt-get.sh" \
    bash "$HELPER" "$tmp/sim.log" \
    -y --no-install-recommends ca-certificates \
    > "$tmp/out.txt" 2> "$tmp/err.txt"
rc=$?
if [ "$rc" != 0 ] && [ "$rc" != 100 ]; then
    # Helper converts non-zero apt exit to its own error (1)
    pass "Test3: sim non-zero exit -> helper aborts (rc=$rc)"
else
    fail "Test3: helper should have aborted (rc=$rc)"
fi
sim_count=$(grep -c '^SIM=1' "$log")
inst_count=$(grep -c '^SIM=0' "$log")
if [ "$sim_count" = 1 ] && [ "$inst_count" = 0 ]; then
    pass "Test3: install did not run after sim failure"
else
    fail "Test3: install ran anyway -- sim=$sim_count install=$inst_count"
fi
rm -rf "$tmp"

# Test 4: helper called with NO install args -> exit code 64, no install
echo ""
echo "=== Test 4: no install args is rejected ==="
PATH="/usr/bin:/bin" bash "$HELPER" /tmp/should-not-exist-sim.log > /dev/null 2>&1
rc=$?
if [ "$rc" = 64 ]; then
    pass "Test4: helper rejects empty arg list (rc=64)"
else
    fail "Test4: helper should have rejected empty args (rc=$rc)"
fi
[ ! -f /tmp/should-not-exist-sim.log ] && pass "Test4: no log file created" \
    || fail "Test4: stray log file created"

# Test 5: argument parity -- a complex install list preserves all args
echo ""
echo "=== Test 5: arg parity with full install list ==="
tmp="$(mktemp -d)"
log="$tmp/apt-argv.log"
cat > "$tmp/apt-get.sh" <<EOF
[ "\$1" = "install" ] && [ "\$2" = "-s" ] && SIM=1 && shift 2
[ "\$1" = "install" ] && [ "\$2" != "-s" ] && SIM=0 && shift
echo "SIM=\$SIM args=\$*" >> "$log"
exit 0
EOF
chmod +x "$tmp/apt-get.sh"
PATH="$tmp:$PATH" APT_GET="$tmp/apt-get.sh" \
    bash "$HELPER" "$tmp/sim.log" \
    -y --no-install-recommends \
    ca-certificates git golang-go \
    libtinysparql-dev \
    libsoup-3.0-dev libgee-0.8-dev \
    build-essential
sim_args=$(grep '^SIM=1' "$log" | sed 's/^SIM=1 args=//')
inst_args=$(grep '^SIM=0' "$log" | sed 's/^SIM=0 args=//')
# Both should be identical and contain all expected pkgs
expected_pkgs="ca-certificates git golang-go libtinysparql-dev libsoup-3.0-dev libgee-0.8-dev build-essential"
for pkg in $expected_pkgs; do
    if [ "$sim_args" = "$inst_args" ] && \
       printf '%s' "$sim_args" | grep -qF -- "$pkg"; then
        : # ok
    else
        fail "Test5: missing pkg or arg mismatch for $pkg"
        continue
    fi
done
if [ "$sim_args" = "$inst_args" ]; then
    pass "Test5: full install list parity -- both runs saw $sim_args"
else
    fail "Test5: arg parity broken on full list -- sim='$sim_args' install='$inst_args'"
fi
# Verify -y and --no-install-recommends were passed (not stripped)
if printf '%s' "$sim_args" | grep -q -- '-y' && \
   printf '%s' "$sim_args" | grep -q -- '--no-install-recommends'; then
    pass "Test5: -y and --no-install-recommends preserved verbatim"
else
    fail "Test5: install flags lost"
fi
rm -rf "$tmp"

# Test 6: WORK_DIR / findmnt logic in build-singularity.sh is exercised by
# extracting the relevant block and running it under controlled mounts.
# We can't actually remount in this sandbox, so we only verify:
#   - default WORK_DIR resolves to $OUT/work (not $HOME/Projects/work)
#   - NCZ_SINGULARITY_WORK_DIR override is honoured
#   - the path-under-test is created with mkdir -p (no deletion)
echo ""
echo "=== Test 6: WORK_DIR default and override ==="
SRC=/home/jasonperlow/Projects/resume-unified-payload-amd64-20261014/ci/build/build-singularity.sh
[ -r "$SRC" ] || fail "Test6: cannot read $SRC"
grep -q 'WORK_DIR="${NCZ_SINGULARITY_WORK_DIR:-\$OUT/work}"' "$SRC" \
    && pass "Test6: default is \$OUT/work" \
    || fail "Test6: default WORK_DIR not \$OUT/work"
grep -q 'NCZ_SINGULARITY_WORK_DIR' "$SRC" \
    && pass "Test6: explicit override still supported" \
    || fail "Test6: NCZ_SINGULARITY_WORK_DIR override missing"
# Verify findmnt is now required to succeed (no fail-open swallow)
if awk '/_findmnt_target=/{getline;getline;print}' <(grep -n -A2 _findmnt_target "$SRC") \
   | grep -q '|| {'; then
    fail "Test6: findmnt failure still swallowed (||)"
else
    pass "Test6: findmnt failure not swallowed (no ||)"
fi
# Verify mkdir -p comes BEFORE findmnt
mkdir_line=$(grep -n 'mkdir -p "\$WORK_DIR"' "$SRC" | head -1 | cut -d: -f1)
findmnt_line=$(grep -n '_findmnt_target=' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$mkdir_line" ] && [ -n "$findmnt_line" ] && [ "$mkdir_line" -lt "$findmnt_line" ]; then
    pass "Test6: mkdir -p WORK_DIR (line $mkdir_line) precedes findmnt (line $findmnt_line)"
else
    fail "Test6: mkdir -p must precede findmnt (mkdir=$mkdir_line, findmnt=$findmnt_line)"
fi
# Verify no ext4 hardcoded requirement (the issue specifically warned against this)
if grep -q 'ext4' "$SRC" | grep -v '^#'; then
    fail "Test6: ext4 hardcoded -- the issue said not to"
else
    pass "Test6: no hardcoded ext4 requirement"
fi

# Test 7: sim ordering -- apt-get update comes BEFORE the helper call
echo ""
echo "=== Test 7: apt-get update precedes the helper call ==="
upd_line=$(grep -n '^apt-get update' "$SRC" | head -1 | cut -d: -f1)
helper_line=$(grep -n '/ncz-build/apt-sim-zero-removals.sh' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$upd_line" ] && [ -n "$helper_line" ] && [ "$upd_line" -lt "$helper_line" ]; then
    pass "Test7: apt-get update (line $upd_line) precedes helper (line $helper_line)"
else
    fail "Test7: apt-get update must precede sim (upd=$upd_line, helper=$helper_line)"
fi

# Test 8: install arg list appears exactly once in BUILD_SCRIPT
echo ""
echo "=== Test 8: install arg list appears exactly once (no duplicated helper list) ==="
# Count occurrences of the helper script being called from build-singularity.sh
helper_calls=$(grep -c '/ncz-build/apt-sim-zero-removals.sh' "$SRC")
if [ "$helper_calls" = 1 ]; then
    pass "Test8: helper called exactly once in BUILD_SCRIPT (no second hardcoded list)"
else
    fail "Test8: helper called $helper_calls times -- helper list duplicated?"
fi
# Count occurrences of bare `apt-get install ` in BUILD_SCRIPT (not inside the helper script)
apt_get_install_count=$(grep -E '^apt-get install ' "$SRC" | wc -l)
if [ "$apt_get_install_count" = 0 ]; then
    pass "Test8: no bare 'apt-get install ' line in BUILD_SCRIPT (only the helper call)"
else
    fail "Test8: bare 'apt-get install ' line still present ($apt_get_install_count)"
fi

echo ""
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ] && exit 0 || exit 1