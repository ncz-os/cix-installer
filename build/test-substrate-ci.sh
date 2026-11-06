#!/bin/bash
# test-substrate-ci.sh -- offline tests for build/substrate-ci.py, the decision
# core of the automatic substrate CI (design: docs/automatic-substrate-ci.md).
#
# Every case here encodes a failure that was observed in the field on
# 2026-11-06 while moving one pin by hand, so a regression turns a real incident
# into a red test instead of another bad pin:
#   F1  a 200 response with zero bytes must never count as healthy
#   F1  a 404 means "absent", not "service down" (and vice versa)
#   F3  degraded mirror is a no-op alert, not a failed pipeline
#   F5  a pin that cannot authorize its own probes is a hard stop
#   -   delta ceilings, removals and major bumps route to review, never merge
#
# No network: probe_mirror takes an injected fetch.
#
# Run: bash build/test-substrate-ci.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
python3 -I - "$HERE/substrate-ci.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("sci", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ok = fail = 0


def check(cond, what):
    global ok, fail
    if cond:
        ok += 1
        print("  PASS  %s" % what)
    else:
        fail += 1
        print("  FAIL  %s" % what)


def fetch_all(status, nbytes=1000):
    return lambda url: (status, nbytes)


# ---- probe classification --------------------------------------------------
paths = ("dists/forky/Release",)
p = m.probe_mirror("https://snap.example/debian/X", paths, fetch=fetch_all(200), retries=(0,))
check(p[0]["verdict"] == "ok", "200 with bytes -> ok")

p = m.probe_mirror("https://snap.example/debian/X", paths, fetch=fetch_all(200, 0), retries=(0,))
check(p[0]["verdict"] == "empty", "F1: 200 with ZERO bytes is never healthy")

p = m.probe_mirror("https://snap.example/debian/X", paths, fetch=fetch_all(404), retries=(0,))
check(p[0]["verdict"] == "absent", "404 -> absent (not a service failure)")

p = m.probe_mirror("https://snap.example/debian/X", paths, fetch=fetch_all(503), retries=(0,))
check(p[0]["verdict"] == "unreachable", "503 -> unreachable")

# retries actually retry, and stop as soon as one succeeds
calls = []
def flaky(url):
    calls.append(1)
    return (503, 0) if len(calls) < 3 else (200, 500)
p = m.probe_mirror("https://snap.example/debian/X", paths, fetch=flaky, retries=(0, 0, 0))
check(len(calls) == 3 and p[0]["verdict"] == "ok",
      "transient 503 then 200 -> ok after retries (%d attempts)" % len(calls))

# ---- preflight decisions ---------------------------------------------------
allok = [{"path": "a", "verdict": "ok", "status": 200, "bytes": 10}]
one_bad = allok + [{"path": "b", "verdict": "unreachable", "status": 504, "bytes": 0}]
one_absent = allok + [{"path": "b", "verdict": "absent", "status": 404, "bytes": 0}]

r = m.preflight(allok, pin_age_days=2, max_age_days=14)
check(r["decision"] == "proceed" and r["exit_code"] == 0, "healthy mirror + fresh pin -> proceed")

r = m.preflight(one_bad, pin_age_days=2, max_age_days=14)
check(r["decision"] == "degraded" and r["exit_code"] == 0,
      "F3: degraded mirror is exit 0 (alert, not a failed pipeline)")

r = m.preflight(one_absent, pin_age_days=2, max_age_days=14)
check(r["decision"] == "broken-pin" and r["exit_code"] == 2,
      "F5: pin cannot authorize a probe -> hard stop (exit 2)")

r = m.preflight(allok, pin_age_days=14, max_age_days=14)
check(r["decision"] == "expired" and r["exit_code"] == 2,
      "pin at MAX_AGE -> expired, exit 2")

r = m.preflight(allok, pin_age_days=11, max_age_days=14)
check(r["decision"] == "proceed-expiry-warning" and r["exit_code"] == 0,
      "pin within 3 days of expiry -> proceed with a warning")

r = m.preflight(allok, pin_age_days=None, max_age_days=14)
check(r["decision"] == "proceed", "unknown pin age does not block (age is measured elsewhere)")

# ---- delta classification --------------------------------------------------
old = {"a": "1.0-1", "b": "2.1-3", "c": "3.0-1"}

r = m.classify_delta(old, {"a": "1.0-2", "b": "2.1-4", "c": "3.0-1"})
check(r["decision"] == "auto-merge-eligible" and r["count"] == 2,
      "two patch-version changes -> auto-merge eligible")

r = m.classify_delta(old, dict(old, extra="1.0-1"), max_delta=150)
check(r["decision"] == "auto-merge-eligible", "one added package stays inside the envelope")

big = dict(old)
for i in range(151):
    big["pkg%03d" % i] = "1.0-1"
r = m.classify_delta(old, big, max_delta=150)
check(r["decision"] == "review" and any("exceeds max_delta" in x for x in r["reasons"]),
      "delta above the ceiling -> review")

r = m.classify_delta(old, {"a": "1.0-1", "b": "2.1-3"})
check(r["decision"] == "review" and any("removals not allowed" in x for x in r["reasons"]),
      "a removed package -> review")

r = m.classify_delta(old, {"a": "2.0-1", "b": "2.1-3", "c": "3.0-1"})
check(r["decision"] == "review" and r["major_bumps"],
      "a major version bump -> review")

r = m.classify_delta({"a": "1:2.3-1"}, {"a": "1:2.3-2"})
check(r["decision"] == "auto-merge-eligible",
      "epoch is not mistaken for a major bump")

# ---- final decision --------------------------------------------------------
good_delta = m.classify_delta(old, {"a": "1.0-2", "b": "2.1-3", "c": "3.0-1"})

d = m.decide(True, True, True, good_delta, automerge_enabled=True)
check(d["decision"] == "auto-merge", "all gates green + inside delta + switch on -> auto-merge")

d = m.decide(True, True, True, good_delta, automerge_enabled=False)
check(d["decision"] == "open-mr" and any("NCZ_CI_AUTOMERGE" in b for b in d["blockers"]),
      "default posture is to open an MR")

d = m.decide(True, True, False, good_delta, automerge_enabled=True)
check(d["decision"] == "open-mr" and any("digests differ" in b for b in d["blockers"]),
      "F5: unequal two-host digests block auto-merge")

d = m.decide(False, True, True, good_delta, automerge_enabled=True)
check(d["decision"] == "open-mr", "red gates on one arch block auto-merge")

d = m.decide(True, False, True, good_delta, automerge_enabled=True)
check(d["decision"] == "open-mr", "coverage below minimum blocks auto-merge")

d = m.decide(True, True, True, m.classify_delta(old, {"a": "1.0-1"}), automerge_enabled=True)
check(d["decision"] == "open-mr", "a removable delta blocks auto-merge even with green gates")

print("\n%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)
PY
