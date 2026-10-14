#!/bin/bash
# apt-sim-zero-removals.sh — generic apt-get install -s gate that
# executes the SAME transaction it just simulated, against the SAME
# base. Designed to be called in place of an `apt-get install` so
# BUILD_SCRIPT cannot drift its package list away from the gate.
#
# Lives OUTSIDE the in-container BUILD_SCRIPT (which is one
# single-quoted string and cannot itself contain unescaped quotes) so
# the exact dependency list, error messages, and exit semantics are
# normal shell code that uses shell quoting freely.
#
# Contract:
#   - $1 = path inside the container where the simulation log should land.
#   - $2..$@ = the EXACT, already-expanded install arguments (flags and
#     package names) the caller intends to pass to `apt-get install`,
#     minus the leading `apt-get install` verb. Same args are used for
#     the simulation and the real install -- the gate is the SAME
#     transaction by construction, not by hope.
#   - Runs `apt-get install -s` with $2..$@ and the SAME -y / standard
#     install verb simulation respects. Exits 0 only when:
#       (a) the simulation succeeds (apt-get exit 0), AND
#       (b) no "Remv " line appears in the simulation output.
#     ANY Remv (or any non-zero apt exit) is fatal -- builds never
#     resume from a partial / zero-removals violation.
#   - On a clean simulation, runs the REAL `apt-get install` with the
#     SAME $2..$@ and propagates its exit status to the caller.
#   - Never touches /opt, kernel modules, real devices, or the host.
#
# This script is bind-mounted read-only at /ncz-build and invoked from
# BUILD_SCRIPT IN PLACE OF the bare `apt-get install` line, so the
# original install argument list appears exactly once in BUILD_SCRIPT.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SIM_LOG="${1:?apt-sim-zero-removals.sh: missing SIM_LOG path argument}"
shift
# Nothing to do if the caller handed us no install arguments -- a
# bare `apt-get install` is a no-op that apt will reject, and we want
# that rejection to come from this helper (with audit) not silently.
if [ "$#" -lt 1 ]; then
    echo "ERROR: apt-sim-zero-removals.sh called with no install arguments" >&2
    exit 64
fi
INSTALL_ARGS=("$@")
mkdir -p "$(dirname "$SIM_LOG")"
# A short banner makes the simulation distinguishable from a real install
# log if both end up side-by-side in /work/tmp for triage.
{
    echo "== zero-removals pre-flight: apt-get install -s =="
    date -u +"  start: %Y-%m-%dT%H:%M:%SZ"
    echo "  args: ${INSTALL_ARGS[*]}"
} > "$SIM_LOG"

# Run the simulation against the SAME args the real install will use.
# apt-get install -s shares its flag parser with `apt-get install`, so
# every -y, --no-install-recommends, package-name, etc. is honoured
# identically. We do NOT add a synthetic -y here -- the caller is the
# sole source of install flags, so the simulation's argv is the install's
# argv verbatim (otherwise arg parity, the entire point of this helper,
# is broken: the simulation runs with [-y, -y, ...] while the install
# runs with [-y, ...], and they diverge the moment the caller's flags
# change).
APT_GET="${APT_GET:-apt-get}"
if ! "$APT_GET" install -s "${INSTALL_ARGS[@]}" >> "$SIM_LOG" 2>&1; then
    {
        echo
        echo "ERROR: zero-removals pre-flight FAILED (apt-get install -s returned non-zero)." >&2
        echo "       See $SIM_LOG for the full simulation transcript." >&2
    } >&2
    grep '^E: ' "$SIM_LOG" | head -40 >&2 || true
    exit 1
fi

# Zero-removals gate: ANY package that apt would REMOVE during the install
# is a fatal build failure. Caught cases:
#   - a Conflicts/Replaces between a -dev we pulled and a runtime lib the
#     shipped system still needs (the most common real-world failure mode);
#   - a base image (debian:${codename}) whose package set no longer matches
#     the pinned snapshot, so a refactored metapackage is on its way out.
# No bypass: --allow-downgrades, --no-trusted, --allow-unauthenticated, and
# -t (target-release) are explicitly NOT honoured. If the dependency
# resolution itself is wrong, the build aborts here.
if grep -E '^Remv ' "$SIM_LOG"; then
    {
        echo
        echo "ERROR: zero-removals gate violated -- dependency simulation would REMOVE packages." >&2
        echo "       See $SIM_LOG for the full simulation transcript." >&2
        echo "       Adjust the dependency set (or the upstream pins) and rebuild." >&2
    } >&2
    exit 1
fi

{
    echo
    echo "== zero-removals pre-flight: clean (no Remv lines) =="
    date -u +"  end:   %Y-%m-%dT%H:%M:%SZ"
} >> "$SIM_LOG"

# Simulation clean -- execute the SAME transaction for real, with the
# SAME arguments. Argument parity is what makes this a real gate and
# not a coincidence; a divergent `apt-get install` here would undo the
# entire purpose of the simulation.
"$APT_GET" install "${INSTALL_ARGS[@]}"