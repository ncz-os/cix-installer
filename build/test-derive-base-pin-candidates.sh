#!/bin/bash
# test-derive-base-pin-candidates.sh -- the snapshot candidates that
# build/derive-base-pin.py measures include every real snapshot.debian.org
# archive run on the days around the substrate date, not only the fixed grid.
#
# A grid point resolves to the latest archive run at or before it, so a run
# between two grid points (about every six hours) is never measured unless it
# is a candidate itself.  Offline: the month listing is a fixture.
#
# Run: bash build/test-derive-base-pin-candidates.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
python3 -I - "$HERE/derive-base-pin.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dbp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ok = fail = 0
def check(cond, what):
    global ok, fail
    if cond: ok += 1; print(f"  PASS  {what}")
    else: fail += 1; print(f"  FAIL  {what}")
listing = ('<a href="20261009T203000Z/">x</a> <a href="20261011T202655Z/">x</a>'
           '<a href="20261012T023456Z/">x</a> <a href="20261012T082414Z/">x</a>'
           '<a href="20261015T023000Z/">x</a>')
calls = []
def fake(y, mo):
    calls.append((y, mo)); return listing
date = "Mon, 12 Oct 2026 02:15:03 UTC"
c = m.candidate_timestamps(date, listing=fake)
check("20261012T023456Z" in c, "a run between grid points is a candidate")
check("20261011T202655Z" in c and "20261012T082414Z" in c, "every run on the window days is a candidate")
check("20261009T203000Z" not in c and "20261015T023000Z" not in c, "runs outside the window are not candidates")
check("20261012T120000Z" in c and "20261010T000000Z" in c, "the fixed grid is kept")
check(c == sorted(set(c)), "candidates are sorted and unique")
check(calls == [(2026, 10)], "one month listing per month in the window")
g = m.candidate_timestamps(date, listing=lambda y, mo: "")
check(len(g) == 12 and all(t[9:15] in ("000000", "120000", "235959") for t in g),
      "an unreachable listing falls back to the fixed grid")
two = m.candidate_timestamps("Thu, 01 Oct 2026 02:15:03 UTC", listing=fake)
check(calls[-2:] == [(2026, 9), (2026, 10)], "a window spanning two months reads both listings")
check(m.archive_runs("20261012T023456Z 2026101T0Z 20261012T02345Z", {"20261012"}) == ["20261012T023456Z"],
      "only well-formed timestamps are runs")
print(f"derive-base-pin candidates: {ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
PY
