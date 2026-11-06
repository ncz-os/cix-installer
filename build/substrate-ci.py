#!/usr/bin/env python3
"""substrate-ci.py -- decision core for the automatic substrate CI.

Design: docs/automatic-substrate-ci.md.  This module owns the parts that must
never be wrong, and keeps them pure so they can be tested offline:

  * stage 0 preflight -- is the mirror healthy enough to move a pin at all, and
    how close is the current pin to expiry?
  * delta classification -- may this move auto-merge, or does it go to review?
  * the final decision -- gates x coverage x digests x delta x switch

Network access happens in exactly one place (`fetch_url`) and every caller can
inject a replacement, so the whole decision surface is testable without a
network (build/test-substrate-ci.sh).

Exit codes for `preflight`:
  0   proceed (healthy)        0   degraded (deliberately NOT a failure: see below)
  2   pin expired -- every build will refuse, this must be loud
  1   tool/config error

A degraded mirror exiting 0 is intentional.  A pipeline that fails whenever
snapshot.debian.org has a bad morning trains people to ignore it; the alert is
what matters, and no pin motion happens either way.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

# --- stage 0: preflight -----------------------------------------------------

DEFAULT_PROBES = (
    "dists/forky/Release",
    "dists/forky/InRelease",
)


def fetch_url(url, timeout=45):
    """Return (status, nbytes). status 0 means the request itself failed."""
    req = urllib.request.Request(url, headers={"User-Agent": "ncz-substrate-ci/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            return int(getattr(r, "status", 200) or 200), len(body)
    except urllib.error.HTTPError as e:
        try:
            body = e.read()
        except Exception:
            body = b""
        return int(e.code), len(body)
    except Exception:
        return 0, 0


def probe_mirror(base, paths=DEFAULT_PROBES, fetch=None, retries=(0, 5, 15)):
    """Probe a few objects. Each path is retried; 404 is a distinct answer.

    404 means "this object is genuinely absent from this snapshot"; anything
    else that is not 200 is a service problem.  Collapsing the two is exactly
    the bug that scored a 0-byte index as "component absent" (F1).
    """
    fetch = fetch or fetch_url
    out = []
    for path in paths:
        url = base.rstrip("/") + "/" + path.lstrip("/")
        last = (0, 0)
        attempts = 0
        for delay in retries:
            if delay:
                time.sleep(delay)
            attempts += 1
            status, nbytes = fetch(url)
            last = (status, nbytes)
            if status in (200, 404):
                break
        status, nbytes = last
        if status == 200 and nbytes > 0:
            verdict = "ok"
        elif status == 404:
            verdict = "absent"
        elif status == 200:
            verdict = "empty"          # 200 with zero bytes is never healthy
        else:
            verdict = "unreachable"
        out.append({"path": path, "url": url, "status": status,
                    "bytes": nbytes, "attempts": attempts, "verdict": verdict})
    return out


def preflight(probes, pin_age_days, max_age_days):
    """Decide whether the pipeline may resolve/move a pin.

    Returns dict(decision, exit_code, reasons).
    """
    reasons = []
    unreachable = [p for p in probes if p["verdict"] in ("unreachable", "empty")]
    absent = [p for p in probes if p["verdict"] == "absent"]
    if absent:
        # A pinned snapshot must contain every probed object; absence there is
        # a pin problem, not weather.
        reasons.append("pin does not authorize: " + ", ".join(p["path"] for p in absent))
        return {"decision": "broken-pin", "exit_code": 2, "reasons": reasons}
    if unreachable:
        reasons.append("mirror degraded: %d/%d probes unreachable (%s)" % (
            len(unreachable), len(probes),
            ", ".join("%s -> %s" % (p["path"], p["status"] or "error") for p in unreachable)))
        return {"decision": "degraded", "exit_code": 0, "reasons": reasons}
    if max_age_days is not None and pin_age_days is not None:
        if pin_age_days >= max_age_days:
            reasons.append("pin is %d days old, MAX_AGE is %d: builds will refuse"
                           % (pin_age_days, max_age_days))
            return {"decision": "expired", "exit_code": 2, "reasons": reasons}
        if pin_age_days >= max_age_days - 3:
            reasons.append("pin is %d days old, expiry at %d days"
                           % (pin_age_days, max_age_days))
            return {"decision": "proceed-expiry-warning", "exit_code": 0, "reasons": reasons}
    reasons.append("mirror healthy, %d/%d probes served" % (
        sum(1 for p in probes if p["verdict"] == "ok"), len(probes)))
    return {"decision": "proceed", "exit_code": 0, "reasons": reasons}


# --- delta classification ---------------------------------------------------

def _major(version):
    """Upstream major of a Debian version string, or None if unparseable."""
    if not version:
        return None
    v = str(version)
    # strip epoch and revision, keep upstream_version
    if ":" in v:
        v = v.split(":", 1)[1]
    if "-" in v:
        v = v.rsplit("-", 1)[0]
    head = v
    for sep in ("~", "+", "."):
        head = head.split(sep, 1)[0]
    digits = ""
    for ch in head:
        if ch.isdigit():
            digits += ch
        else:
            break
    return int(digits) if digits else None


def classify_delta(old, new, max_delta=150, allow_removals=False):
    """old/new are {package: version}. Returns dict with decision + reasons."""
    reasons = []
    old_names, new_names = set(old), set(new)
    added = sorted(new_names - old_names)
    removed = sorted(old_names - new_names)
    changed = sorted(n for n in (old_names & new_names) if old[n] != new[n])
    count = len(added) + len(removed) + len(changed)
    majors = []
    for name in changed:
        a, b = _major(old[name]), _major(new[name])
        if a is not None and b is not None and a != b:
            majors.append((name, old[name], new[name]))
    reasons.append("%d delta (%d added, %d removed, %d changed)"
                   % (count, len(added), len(removed), len(changed)))
    review = []
    if count > max_delta:
        review.append("delta %d exceeds max_delta %d" % (count, max_delta))
    if removed and not allow_removals:
        review.append("removals not allowed: " + ", ".join(removed[:10]))
    if majors:
        review.append("major version bumps: " + ", ".join(
            "%s %s->%s" % m for m in majors[:10]))
    decision = "review" if review else "auto-merge-eligible"
    return {"decision": decision, "count": count, "added": added,
            "removed": removed, "changed": changed,
            "major_bumps": [{"name": n, "old": o, "new": v} for n, o, v in majors],
            "reasons": reasons + review}


# --- final decision ---------------------------------------------------------

def decide(gates_green, coverage_ok, digests_equal, delta, automerge_enabled):
    """The only place allowed to say 'merge'."""
    blockers = []
    if not gates_green:
        blockers.append("gates not green on both arches")
    if not coverage_ok:
        blockers.append("substrate coverage below the configured minimum")
    if not digests_equal:
        blockers.append("InRelease digests differ between the two hosts")
    if delta.get("decision") != "auto-merge-eligible":
        blockers.append("delta outside the auto-merge envelope: "
                        + "; ".join(delta.get("reasons") or ["classified review"]))
    if not automerge_enabled:
        blockers.append("auto-merge is disabled (NCZ_CI_AUTOMERGE)")
    if blockers:
        return {"decision": "open-mr", "blockers": blockers}
    return {"decision": "auto-merge", "blockers": []}


# --- CLI --------------------------------------------------------------------

def _cmd_preflight(args):
    base = args.base
    probes = probe_mirror(base, retries=(0, 5, 15) if not args.no_retry else (0,))
    result = preflight(probes, args.pin_age_days, args.max_age_days)
    result["probes"] = probes
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print("substrate-ci preflight: %s" % result["decision"])
        for p in probes:
            print("  %-28s %-11s %s %d B" % (p["path"], p["verdict"], p["status"], p["bytes"]))
        for r in result["reasons"]:
            print("  - %s" % r)
    return result["exit_code"]


def _cmd_decide(args):
    with open(args.delta, "r", encoding="utf-8") as f:
        payload = json.load(f)
    delta = classify_delta(payload.get("old", {}), payload.get("new", {}),
                           max_delta=args.max_delta,
                           allow_removals=args.allow_removals)
    out = decide(gates_green=payload.get("gates_green", False),
                 coverage_ok=payload.get("coverage_ok", False),
                 digests_equal=payload.get("digests_equal", False),
                 delta=delta,
                 automerge_enabled=args.automerge)
    out["delta"] = delta
    print(json.dumps(out, indent=2))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="automatic substrate CI decision core")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("preflight", help="stage 0: mirror health + pin age")
    p.add_argument("--base", default=os.environ.get("NCZ_BASE_MIRROR", ""),
                   help="snapshot base URL (default $NCZ_BASE_MIRROR)")
    p.add_argument("--pin-age-days", type=int, default=None)
    p.add_argument("--max-age-days", type=int,
                   default=int(os.environ.get("NCZ_BASE_MIRROR_SNAPSHOT_MAX_AGE_DAYS", "14")))
    p.add_argument("--no-retry", action="store_true")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=_cmd_preflight)

    d = sub.add_parser("decide", help="stage 7: auto-merge or open an MR")
    d.add_argument("delta", help="JSON with old/new package maps and gate booleans")
    d.add_argument("--max-delta", type=int,
                   default=int(os.environ.get("NCZ_CI_MAX_PKG_DELTA", "150")))
    d.add_argument("--allow-removals", action="store_true")
    d.add_argument("--automerge", action="store_true",
                   help="honour NCZ_CI_AUTOMERGE=1 (default is to open an MR)")
    d.set_defaults(func=_cmd_decide)

    args = ap.parse_args(argv)
    if args.cmd == "preflight" and not args.base:
        print("substrate-ci: --base (or NCZ_BASE_MIRROR) is required", file=sys.stderr)
        return 1
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
