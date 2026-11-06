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

def decide(gates_green, coverage_ok, digests_equal, delta, automerge_enabled,
           snapshot_ok=True):
    """The only place allowed to say 'merge'."""
    blockers = []
    if not gates_green:
        blockers.append("gates not green on both arches")
    if not coverage_ok:
        blockers.append("substrate coverage below the configured minimum")
    if not snapshot_ok:
        blockers.append("arches measured different snapshots")
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


# --- stage 2: prove aggregation ---------------------------------------------

def aggregate_proof(arch_rows, min_coverage=99.0):
    """Combine the per-arch proof results into booleans for `decide`.

    arch_rows = {"amd64": {snapshot, coverage, inrelease_sha256}, "arm64": {...}}

    Three things must hold, and each of them has failed in the field:
      * both arches measured at or above the coverage floor (F1 - a partial
        index must never be scored as low coverage);
      * both arches on the SAME snapshot, because release.conf carries exactly
        one and a split leaves primary and arm64 building different substrates
        (F3);
      * the InRelease digest recorded independently on each host is identical
        (F5 - two hosts, two fetches, one answer).
    """
    blockers = []
    missing = [a for a in ("amd64", "arm64") if not arch_rows.get(a)]
    if missing:
        blockers.append("no proof for: " + ", ".join(missing))
        return {"coverage_ok": False, "digests_equal": False,
                "snapshot": None, "blockers": blockers}

    rows = [arch_rows["amd64"], arch_rows["arm64"]]
    coverage_ok = True
    for arch, row in zip(("amd64", "arm64"), rows):
        cov = row.get("coverage")
        if cov is None or float(cov) < float(min_coverage):
            coverage_ok = False
            blockers.append("%s coverage %s below minimum %s"
                            % (arch, cov, min_coverage))

    snaps = {row.get("snapshot") for row in rows}
    snapshot_ok = len(snaps) == 1 and None not in snaps
    if not snapshot_ok:
        blockers.append("arches measured different snapshots: "
                        + ", ".join(sorted(str(s) for s in snaps)))

    shas = [row.get("inrelease_sha256") for row in rows]
    digests_equal = bool(shas[0]) and shas[0] == shas[1]
    if not digests_equal:
        blockers.append("InRelease digests missing or unequal between hosts")

    return {"coverage_ok": coverage_ok,
            "snapshot_ok": snapshot_ok,
            "digests_equal": digests_equal,
            "snapshot": next(iter(snaps)) if snapshot_ok else None,
            "blockers": blockers}


# --- stage 8: retention -----------------------------------------------------

def retention_plan(items, validated=None, keep_candidates=1):
    """Keep the validated pin plus at most N in-flight candidates; prune the rest.

    items = [{"name": ..., "created": <epoch>, "kind": "pin-branch"|"candidate"}]
    A validated pin is never pruned, and neither is the newest candidate: that
    is the one currently being proven.  Everything older goes.
    """
    ordered = sorted(items, key=lambda i: i.get("created", 0), reverse=True)
    keep, prune = [], []
    candidates_kept = 0
    for item in ordered:
        if validated is not None and item.get("name") == validated:
            keep.append(item)
            continue
        if candidates_kept < keep_candidates:
            keep.append(item)
            candidates_kept += 1
            continue
        prune.append(item)
    return {"keep": [i.get("name") for i in keep],
            "prune": [i.get("name") for i in prune]}


# --- stage 6: gate aggregation ----------------------------------------------

def aggregate_gates(results):
    """Decide whether the gate suite is green.

    results = [{"name": ..., "status": "pass"|"fail"|"skip"|"error"}]

    Only "pass" counts. A gate that DID NOT RUN is a failure, not a pass - the design
    note says so explicitly, because a suite that silently skips a gate reports green
    while proving less than it claims. An empty suite is also not green: nothing was
    proven.
    """
    blockers = []
    if not results:
        blockers.append("no gates ran")
    for r in results:
        name = r.get("name", "<unnamed>")
        status = r.get("status", "error")
        if status == "pass":
            continue
        if status == "skip":
            blockers.append("gate %s was SKIPPED (counted as a failure)" % name)
        else:
            blockers.append("gate %s: %s" % (name, status))
    return {"green": not blockers, "ran": len(results), "blockers": blockers}


# --- rehearsal: the whole verdict in one call -------------------------------

def rehearse(spec, automerge=False, min_coverage=99.0, max_delta=150,
             allow_removals=False):
    """Compose stages 2, 6 and 7 into one verdict, the way a CI dry run would.

    spec = {"arches": {amd64: {...}, arm64: {...}},
            "gates": [{name, status}],
            "old": {pkg: version}, "new": {pkg: version}}

    Nothing here is new logic - it is the composition, so that a reviewer can see the
    three inputs and the one answer together, and so the pipeline has a single call.
    """
    proof = aggregate_proof(spec.get("arches", {}), min_coverage=min_coverage)
    gates = aggregate_gates(spec.get("gates", []))
    delta = classify_delta(spec.get("old", {}), spec.get("new", {}),
                           max_delta=max_delta, allow_removals=allow_removals)
    out = decide(gates_green=gates["green"],
                 coverage_ok=proof["coverage_ok"],
                 digests_equal=proof["digests_equal"],
                 delta=delta,
                 automerge_enabled=automerge,
                 snapshot_ok=proof["snapshot_ok"])
    # decide() summarises a red suite as "gates not green"; a verdict that says only
    # that hides WHICH gate failed, so replace the summary with the specifics.
    blockers = []
    for b in out["blockers"]:
        if b == "gates not green on both arches" and gates["blockers"]:
            blockers.extend(gates["blockers"])
        else:
            blockers.append(b)
    return {"decision": out["decision"], "blockers": blockers,
            "proof": proof, "gates": gates, "delta": delta}


# --- stage 3: transactional pin move + changelog ----------------------------

def apply_pin_move(root, changes, replace=None):
    """Write several files as one transaction.

    A pin move touches base.pin, release.conf, forky-snapshot.tsv and
    determinism.pin.  If a single write fails the tree is left half-moved --
    release.conf on the new snapshot while base.pin still carries the old rows,
    or the reverse -- which is an unbuildable substrate that still looks pinned
    (F5).  Staging every file first and renaming afterwards shrinks the window
    but does not remove it, so the originals are kept in memory and restored on
    the first failure.

    Returns dict(ok, written, rolled_back, error).
    """
    replace = replace or os.replace
    originals = {}
    staged = []
    written = []
    for rel, content in changes.items():
        path = os.path.join(root, rel)
        try:
            with open(path, "r", encoding="utf-8") as f:
                originals[path] = f.read()
        except FileNotFoundError:
            originals[path] = None
        tmp = path + ".ncz-tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        staged.append((path, tmp))
    try:
        for path, tmp in staged:
            replace(tmp, path)
            written.append(path)
    except OSError as exc:
        rolled = []
        for path in written:
            orig = originals.get(path)
            try:
                if orig is None:
                    os.unlink(path)
                else:
                    with open(path, "w", encoding="utf-8") as f:
                        f.write(orig)
                rolled.append(path)
            except OSError:
                pass
        for _, tmp in staged:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return {"ok": False, "written": written, "rolled_back": rolled,
                "error": str(exc)}
    return {"ok": True, "written": written, "rolled_back": [], "error": None}


def render_changelog(old, new, evidence=None, title="Substrate pin update", cap=50):
    """Markdown changelog for a pin move. Every list is capped and counted."""
    delta = classify_delta(old, new, max_delta=10 ** 9, allow_removals=True)
    lines = ["# %s" % title, "",
             "%d package changes: %d added, %d removed, %d changed."
             % (delta["count"], len(delta["added"]), len(delta["removed"]),
                len(delta["changed"])), ""]

    def block(heading, items):
        if not items:
            return
        lines.append("## %s (%d)" % (heading, len(items)))
        for name in items[:cap]:
            lines.append("- `%s`" % name)
        if len(items) > cap:
            lines.append("- ... and %d more" % (len(items) - cap))
        lines.append("")

    block("Added", delta["added"])
    block("Removed", delta["removed"])

    if delta["changed"]:
        lines.append("## Changed (%d)" % len(delta["changed"]))
        for name in delta["changed"][:cap]:
            lines.append("- `%s` %s -> %s" % (name, old.get(name, "?"), new.get(name, "?")))
        if len(delta["changed"]) > cap:
            lines.append("- ... and %d more" % (len(delta["changed"]) - cap))
        lines.append("")

    if delta["major_bumps"]:
        lines.append("## Major version bumps (review required)")
        for b in delta["major_bumps"]:
            lines.append("- `%s` %s -> %s" % (b["name"], b["old"], b["new"]))
        lines.append("")

    if evidence:
        lines.append("## Evidence")
        for e in evidence:
            lines.append("- %s" % e)
    return "\n".join(lines).rstrip() + "\n"


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
                 automerge_enabled=args.automerge,
                 snapshot_ok=payload.get("snapshot_ok", True))
    out["delta"] = delta
    print(json.dumps(out, indent=2))
    return 0


def _cmd_apply_pin(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    result = apply_pin_move(spec["root"], spec["changes"])
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 2


def _cmd_changelog(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    text = render_changelog(spec.get("old", {}), spec.get("new", {}),
                            evidence=spec.get("evidence"),
                            title=spec.get("title", "Substrate pin update"))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote %s" % args.out)
    else:
        sys.stdout.write(text)
    return 0


def _cmd_aggregate(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    rows = spec.get("arches", spec)
    out = aggregate_proof(rows, min_coverage=args.min_coverage)
    print(json.dumps(out, indent=2))
    return 0


def _cmd_retention(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    out = retention_plan(spec.get("items", []),
                         validated=spec.get("validated"),
                         keep_candidates=int(spec.get("keep_candidates", 1)))
    print(json.dumps(out, indent=2))
    return 0


def _cmd_gates(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    out = aggregate_gates(spec if isinstance(spec, list) else spec.get("gates", []))
    print(json.dumps(out, indent=2))
    return 0 if out["green"] else 1


def _cmd_rehearse(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    out = rehearse(spec, automerge=args.automerge, max_delta=args.max_delta)
    print(json.dumps(out, indent=2))
    return 0 if out["decision"] == "auto-merge" else 0


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

    a = sub.add_parser("apply-pin", help="stage 3: transactional pin move")
    a.add_argument("spec", help="JSON: {\"root\": path, \"changes\": {relpath: content}}")
    a.set_defaults(func=_cmd_apply_pin)

    c = sub.add_parser("changelog", help="stage 3: render a pin-move changelog")
    c.add_argument("spec", help="JSON: {\"old\": {pkg: ver}, \"new\": {...}, \"evidence\": [...]}")
    c.add_argument("--out", default=None)
    c.set_defaults(func=_cmd_changelog)

    g = sub.add_parser("aggregate", help="stage 2: combine per-arch proof results")
    g.add_argument("spec", help="JSON: {\"amd64\": {...}, \"arm64\": {...}} or {\"arches\": {...}}")
    g.add_argument("--min-coverage", type=float,
                   default=float(os.environ.get("NCZ_CI_MIN_COVERAGE", "99")))
    g.set_defaults(func=_cmd_aggregate)

    g2 = sub.add_parser("gates", help="stage 6: aggregate gate results")
    g2.add_argument("spec", help="JSON: [{\"name\": ..., \"status\": pass|fail|skip|error}, ...]")
    g2.set_defaults(func=_cmd_gates)

    rh = sub.add_parser("rehearse", help="compose stages 2+6+7 into one verdict")
    rh.add_argument("spec", help="JSON: arches, gates, old, new")
    rh.add_argument("--automerge", action="store_true")
    rh.add_argument("--max-delta", type=int,
                    default=int(os.environ.get("NCZ_CI_MAX_PKG_DELTA", "150")))
    rh.set_defaults(func=_cmd_rehearse)

    r = sub.add_parser("retention", help="stage 8: what to keep and what to prune")
    r.add_argument("spec", help="JSON: {\"items\": [...], \"validated\": name, \"keep_candidates\": 1}")
    r.set_defaults(func=_cmd_retention)

    args = ap.parse_args(argv)
    if args.cmd == "preflight" and not args.base:
        print("substrate-ci: --base (or NCZ_BASE_MIRROR) is required", file=sys.stderr)
        return 1
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
