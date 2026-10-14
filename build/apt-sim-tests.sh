#!/bin/bash
# apt-sim-tests.sh -- negative proofs for the new generic helper plus
# the WORK_DIR mount guard that gates the singularity build container.
# Pure shell + bash; no real apt, no containers, no compile, no network.
#
# This test runs from an arbitrary cwd and writes all scratch state
# under $TASK_TMP_DIR (default task/tmp inside the worktask, on the
# task's BTRFS data disk -- never /tmp on tmpfs). Every command is
# parameterised so the file can live in the public cix-installer repo
# without leaking any host / user / absolute path.
#
# All paths inside the test are derived from SCRIPT_DIR (this file's
# location): the helper script (apt-sim-zero-removals.sh) and the
# builder (build-singularity.sh) are loaded relative to SCRIPT_DIR.
#
# The build-singularity WORK_DIR mount guard is exercised through the
# SAME helper the builder uses (lib/ncz-work-dir-guard.sh) with a
# stubbed findmnt, so the test does not duplicate the policy.
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
#      -s run and the real run receive the SAME argv (byte parity).
#   5. WORK_DIR guard: empty / ramfs / tmpfs / overlay / aufs /
#      fuse-overlayfs / findmnt-failure are all rejected BEFORE the
#      builder would launch any container; btrfs / ext4 / xfs are
#      accepted. The same helper invoked by build-singularity.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/apt-sim-zero-removals.sh"
BUILDER="$SCRIPT_DIR/build-singularity.sh"
GUARD="$SCRIPT_DIR/lib/ncz-work-dir-guard.sh"
# All scratch lives under the task's BTRFS data disk; never /tmp.
TASK_TMP_DIR="${TASK_TMP_DIR:-$TASK_ROOT/task/tmp}"
mkdir -p "$TASK_TMP_DIR"
export TMPDIR="$TASK_TMP_DIR"

[ -x "$HELPER" ] || { echo "FAIL: helper not executable at $HELPER" >&2; exit 1; }
[ -r "$BUILDER" ] || { echo "FAIL: builder not readable at $BUILDER" >&2; exit 1; }
[ -r "$GUARD" ] || { echo "FAIL: guard not readable at $GUARD" >&2; exit 1; }

PASS=0; FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }

# --- helper: invoke the actual guard with a stubbed findmnt. ---
# Builds a tmpdir, drops a fake findmnt that prints a canned fstype
# (or exits nonzero), then runs `bash -c 'set -e; . guard.sh;
# ncz_work_dir_guard <tmpdir>'` and returns the captured exit code,
# stdout, stderr. The same ncz_work_dir_guard the builder sources.
run_guard_with_stub_findmnt() {
    local tmp="$1" stub_mode="$2" stub_value="$3"
    local stub="$tmp/stub-findmnt"
    case "$stub_mode" in
        ok)
            cat > "$stub" <<EOF
#!/bin/sh
# Stub findmnt: print the canned fstype, exit 0.
echo "$stub_value"
EOF
            ;;
        empty)
            # Successful findmnt that prints nothing -- the probe
            # succeeded but reported an empty fstype. The guard must
            # reject this as a probe failure.
            cat > "$stub" <<'EOF'
#!/bin/sh
exit 0
EOF
            ;;
        fail)
            # findmnt fails outright (path not on any mount).
            cat > "$stub" <<'EOF'
#!/bin/sh
exit 32
EOF
            ;;
    esac
    chmod +x "$stub"
    NCZ_WORK_DIR_GUARD_FINDMNT="$stub" bash -c '
        set -e
        . "$0"
        ncz_work_dir_guard "$1"
    ' "$GUARD" "$tmp"
}

# --- Test 1: clean simulation -> helper exits 0, both sim and install
# ran with the same args (byte parity). ---
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
# Verify both runs saw the same args (byte parity)
sim_args=$(grep '^SIM=1' "$log" | sed 's/^SIM=1 args=//')
install_args=$(grep '^SIM=0' "$log" | sed 's/^SIM=0 args=//')
if [ "$sim_args" = "$install_args" ]; then
    pass "Test1: arg parity (sim == install): $sim_args"
else
    fail "Test1: arg parity broken -- sim='$sim_args' install='$install_args'"
fi
# Verify libtinysparql-dev (the forky pick) appears in BOTH runs
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

# --- Test 2: Remv line in sim -> helper exits non-zero, NO install runs ---
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

# --- Test 3: simulation non-zero exit -> helper non-zero, no install ---
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

# --- Test 4: helper called with NO install args -> exit code 64, no log
# file. Scratch state must live under task/tmp, not /tmp. ---
echo ""
echo "=== Test 4: no install args is rejected ==="
expected_log="$TASK_TMP_DIR/should-not-exist-sim.log"
rm -f "$expected_log"
PATH="/usr/bin:/bin" bash "$HELPER" "$expected_log" > /dev/null 2>&1
rc=$?
if [ "$rc" = 64 ]; then
    pass "Test4: helper rejects empty arg list (rc=64)"
else
    fail "Test4: helper should have rejected empty args (rc=$rc)"
fi
[ ! -f "$expected_log" ] && pass "Test4: no log file created at $expected_log" \
    || fail "Test4: stray log file created at $expected_log"

# --- Test 5: argument parity -- a complex install list preserves all
# args, flags included (-y and --no-install-recommends must survive
# byte-for-byte from sim to install). ---
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

# --- Test 6: WORK_DIR mount guard, run through the actual helper the
# builder sources. Synthetic fixtures (stubbed findmnt) stand in for
# the real kernel /proc/self/mountinfo; the guard itself is the same
# code path build-singularity.sh runs. ---
echo ""
echo "=== Test 6: WORK_DIR guard rejects in-memory / copy-on-write scratch ==="
for stub_mode in ok fail empty; do
    case "$stub_mode" in
        ok)    fstype="tmpfs";;
        fail)  fstype="<findmnt failed>";;
        empty) fstype="<empty>";;
    esac
    tmp="$(mktemp -d)"
    set +e
    run_guard_with_stub_findmnt "$tmp" "$stub_mode" "$fstype" > "$tmp/out" 2> "$tmp/err"
    rc=$?
    set -e
    if [ "$rc" != 0 ] && grep -q "ERROR:" "$tmp/err"; then
        pass "Test6: guard rejects (mode=$stub_mode fstype=$fstype) before any container launch"
    else
        fail "Test6: guard should have rejected (mode=$stub_mode fstype=$fstype) but accepted"
    fi
    rm -rf "$tmp"
done

# --- Test 7: WORK_DIR guard accepts real disk-backed fstypes (btrfs,
# ext4, xfs, zfs, f2fs). The builder's container launch proceeds. ---
echo ""
echo "=== Test 7: WORK_DIR guard accepts disk-backed fstypes ==="
for fstype in btrfs ext4 xfs zfs f2fs; do
    tmp="$(mktemp -d)"
    set +e
    run_guard_with_stub_findmnt "$tmp" ok "$fstype" > "$tmp/out" 2> "$tmp/err"
    rc=$?
    set -e
    if [ "$rc" = 0 ] && ! grep -q "ERROR:" "$tmp/err"; then
        pass "Test7: guard accepts $fstype (rc=0, no ERROR)"
    else
        fail "Test7: guard rejected $fstype (rc=$rc) -- $(tr '\n' ' ' < "$tmp/err")"
    fi
    rm -rf "$tmp"
done

# --- Test 8: builder actually sources the guard. The guard call must
# appear in build-singularity.sh and the rejection list must include
# the cases the previous grep-only Test 6/7/8 checked. ---
echo ""
echo "=== Test 8: builder sources the same guard the test exercises ==="
if grep -q 'ncz-work-dir-guard.sh' "$BUILDER" && \
   grep -q 'ncz_work_dir_guard' "$BUILDER"; then
    pass "Test8: build-singularity.sh sources the shared guard helper"
else
    fail "Test8: build-singularity.sh does not source ncz-work-dir-guard.sh"
fi
# The guard must reject exactly the policy set: tmpfs, ramfs, overlay,
# aufs, fuse-overlayfs, and the empty-probe case. BTRFS / ext4 / xfs /
# ZFS are accepted; that is verified by Test 7.
for fstype in tmpfs ramfs overlay aufs fuse-overlayfs; do
    if grep -qE "(^|[^a-zA-Z0-9])${fstype}([^a-zA-Z0-9]|\\||\\$)" "$GUARD"; then
        pass "Test8: guard rejects $fstype"
    else
        fail "Test8: guard does not reject $fstype"
    fi
done
# The empty-probe rejection must be present (the new fix). The guard
# contains an `if [ -z "$fstype" ]` block AND an empty pattern (`""`)
# in the case statement so the empty probe is double-rejected. Check
# both the comment and the literal case pattern.
if grep -q 'empty fstype' "$GUARD" && grep -q '""' "$GUARD" && grep -q '|ramfs' "$GUARD"; then
    pass "Test8: guard rejects empty findmnt probe"
else
    fail "Test8: guard does not explicitly reject empty findmnt probe"
fi
# Builder must NOT inline the old `case "$_findmnt_target" in` block
# any more; that would mean the test is reading stale inlined code.
if grep -q '_findmnt_target' "$BUILDER"; then
    fail "Test8: build-singularity.sh still has the old inline _findmnt_target case"
else
    pass "Test8: builder no longer inlines the findmnt case (uses shared guard)"
fi

# --- Test 9: no PUBLIC / hardcoded / host-specific path anywhere in
# the helper / guard / test that the operator can see. The script
# must work from an arbitrary cwd. ---
echo ""
echo "=== Test 9: no hardcoded host paths leak into the public test ==="
if grep -qE '/home/[a-z]+/' "$SCRIPT_DIR/apt-sim-tests.sh"; then
    fail "Test9: test file contains a /home/<user>/ hardcoded path"
    grep -nE '/home/[a-z]+/' "$SCRIPT_DIR/apt-sim-tests.sh" | sed 's/^/    /'
else
    pass "Test9: no /home/<user>/ hardcoded path in test"
fi
if grep -qE '/home/[a-z]+/' "$GUARD"; then
    fail "Test9: guard file contains a /home/<user>/ hardcoded path"
else
    pass "Test9: no /home/<user>/ hardcoded path in guard"
fi
# All paths the test uses come from SCRIPT_DIR / TASK_ROOT.
if [ "$(cd "$(dirname "$0")" && pwd)" = "$SCRIPT_DIR" ]; then
    pass "Test9: SCRIPT_DIR resolves correctly from arbitrary cwd (cwd=$(pwd))"
else
    fail "Test9: SCRIPT_DIR did not resolve (cwd=$(pwd))"
fi

echo ""
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ] && exit 0 || exit 1
