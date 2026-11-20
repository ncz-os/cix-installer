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
import re
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


# --- the screensaver plugin's ABI contract -----------------------------------

def read_ssplugin_lock(path):
    """Read post-install/lib/ncz-screensavers-plugin.lock.

    The lock is the single place that says which payload the shipped plugin was built
    against and which libsingularity it links. It is shell assignments, so it is parsed
    here once instead of grepped four times.
    """
    out = {"version": None, "abi_lib": None, "payload": {}, "libsha": {}, "package": None}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        # keys carry the arch in lower case (..._SHA256_arm64), so the key pattern has
        # to accept lower case or the per-arch rows silently vanish
        m = re.match(r'^(NCZ_SSPLUGIN_[A-Za-z0-9_]+)=["\']?([^"\'\n]*)["\']?\s*$', line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key == "NCZ_SSPLUGIN_VERSION":
            out["version"] = val
        elif key == "NCZ_SSPLUGIN_ABI_LIB":
            out["abi_lib"] = val
        elif key == "NCZ_SSPLUGIN_PACKAGE":
            out["package"] = val
        elif key.startswith("NCZ_SSPLUGIN_PAYLOAD_"):
            out["payload"][key[len("NCZ_SSPLUGIN_PAYLOAD_"):].lower()] = val
        elif key.startswith("NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_"):
            out["libsha"][key[len("NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_"):].lower()] = val
    return out


def abi_verdict(lock, arch, payload_version, lib_sha):
    """Decide whether a payload satisfies the plugin ABI the lock records.

    The same rule as post-install/lib/ncz-ssplugin-install.sh::ssplugin_abi_verdict:
    the payload version matches the locked one, OR the libsingularity it ships is
    byte-identical to the locked library. Anything else is a mismatch - which is not a
    formality: it means the plugin the image installs was never built against this
    payload, and no gate had looked until now.
    """
    locked_payload = lock.get("payload", {}).get(arch)
    locked_lib = lock.get("libsha", {}).get(arch)
    out = {"arch": arch, "payload_version": payload_version, "lib_sha": lib_sha,
           "locked_payload": locked_payload, "locked_libsha": locked_lib,
           "ok": False, "verdict": "mismatch", "why": ""}
    if not locked_payload and not locked_lib:
        out["why"] = "the lock has no row for %s" % arch
        return out
    if payload_version and locked_payload and payload_version == locked_payload:
        out["ok"] = True
        out["verdict"] = "version-match"
        out["why"] = "payload version %s is the one the plugin was built against" % payload_version
        return out
    if lib_sha and locked_lib and lib_sha == locked_lib:
        out["ok"] = True
        out["verdict"] = "lib-identical"
        out["why"] = ("payload %s differs from the locked %s, but libsingularity is "
                      "byte-identical (%s)" % (payload_version, locked_payload, lib_sha[:12]))
        return out
    out["why"] = ("payload %s ships libsingularity %s, the plugin lock expects %s from payload %s"
                  % (payload_version, (lib_sha or "?")[:12], (locked_lib or "?")[:12],
                     locked_payload))
    return out


LIBSINGULARITY_SONAME = "libsingularity.so.0"


def symbol_abi_verdict(baseline_syms, candidate_syms, plugin_undef, needed=(),
                       soname=LIBSINGULARITY_SONAME):
    """Decide whether a plugin built against one payload still resolves on another.

    This answers the question a sha mismatch cannot: the lock's identity rule says
    "rebuild against the exact payload", which is stricter than "the binary still
    works". Given the exports of the baseline library, the exports of the candidate
    library and the plugin's undefined symbols, a pass means

      * the plugin still declares the library's SONAME as NEEDED,
      * the candidate exports every symbol the baseline exported (a superset),
      * and every symbol the plugin took from the baseline is present in the candidate.

    Anything it cannot prove is a failure, not a pass: an empty baseline proves nothing.
    """
    base = set(s for s in baseline_syms if s)
    cand = set(s for s in candidate_syms if s)
    undef = set(s for s in plugin_undef if s)
    need = [n for n in needed if n]
    out = {"soname": soname, "soname_ok": None, "baseline_symbols": len(base),
           "candidate_symbols": len(cand), "plugin_imports": 0, "removed": [],
           "unsatisfied": [], "ok": False, "why": ""}

    # No DT_NEEDED list is not "nothing to check": it is a failed read, and a plugin whose
    # dependency list could not be read has not been shown to link the library at all.
    if not need:
        out["why"] = "no DT_NEEDED list: cannot prove the plugin links %s" % soname
        return out
    out["soname_ok"] = soname in need
    if not out["soname_ok"]:
        out["why"] = "the plugin does not declare %s as NEEDED (it links %s)" % (
            soname, ", ".join(need))
        return out

    if not base:
        out["why"] = "no baseline symbols: nothing to compare, so nothing is proven"
        return out
    if not cand:
        out["why"] = "no candidate symbols: the library could not be read"
        return out

    removed = sorted(base - cand)
    imports = sorted(undef & base)
    unsatisfied = sorted(set(imports) - cand)
    out["removed"] = removed
    out["unsatisfied"] = unsatisfied
    out["plugin_imports"] = len(imports)

    if removed:
        out["why"] = "the candidate dropped %d symbol(s) the baseline exported, e.g. %s" % (
            len(removed), ", ".join(removed[:3]))
        return out
    if unsatisfied:
        out["why"] = ("the plugin takes %d symbol(s) from the baseline that the candidate "
                      "does not export, e.g. %s" % (len(unsatisfied),
                                                    ", ".join(unsatisfied[:3])))
        return out
    out["ok"] = True
    out["why"] = ("superset (+%d) and all %d symbol(s) the plugin imports are present"
                  % (len(cand) - len(base), len(imports)))
    return out


# --- stage 1 input: the current pin inventory -------------------------------

def read_pins(root):
    """Read what the tree is pinned TO, as structured data.

    Stage 1 has to compare candidates against the current pins, so the current pins
    need one machine-readable shape rather than four formats parsed ad hoc. This reads
    only; nothing here decides anything.

    Returns {forky: {snapshot, arches}, runtime: {...}, payload: {arch: {...}},
             singularity: {superproject, count}, sources: {file: found|missing}}
    """
    out = {"forky": {"snapshot": None, "arches": {}},
           "runtime": {}, "payload": {}, "singularity": {}, "sources": {}}

    def path(rel):
        return os.path.join(root, rel)

    # manifests/base.pin: arch 	 substrate 	 date 	 snapshot 	 coverage 	 iso
    bp = path("manifests/base.pin")
    if os.path.exists(bp):
        out["sources"]["base.pin"] = "found"
        for line in open(bp, encoding="utf-8", errors="replace"):
            if line.startswith("#") or not line.strip():
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) >= 5:
                out["forky"]["arches"][f[0]] = {"substrate": f[1], "snapshot": f[3],
                                                "coverage": f[4]}
                out["forky"]["snapshot"] = out["forky"]["snapshot"] or f[3]
    else:
        out["sources"]["base.pin"] = "missing"

    # release.conf: shell assignments
    rc = path("release.conf")
    if os.path.exists(rc):
        out["sources"]["release.conf"] = "found"
        for line in open(rc, encoding="utf-8", errors="replace"):
            m = re.match(r'^NCZ_BASE_MIRROR_SNAPSHOT="?([^"\n]*)"?', line)
            if m:
                out["forky"]["snapshot"] = m.group(1)
            for key, name in (("NCZ_LIBDRM_NCZ_REV", "libdrm"),
                              ("NCZ_DKMS_DEB_REV", "dkms")):
                m = re.match(r'^%s="?([^"\n]*)"?' % key, line)
                if m:
                    out["runtime"][name] = m.group(1)
    else:
        out["sources"]["release.conf"] = "missing"

    # manifests/singularity-payload.tsv: arch \t sha256 \t deb
    sp = path("manifests/singularity-payload.tsv")
    if os.path.exists(sp):
        out["sources"]["singularity-payload.tsv"] = "found"
        for line in open(sp, encoding="utf-8", errors="replace"):
            if line.startswith("#") or not line.strip():
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) == 3:
                out["payload"][f[0]] = {"sha256": f[1], "deb": f[2]}
    else:
        out["sources"]["singularity-payload.tsv"] = "missing"

    # assets/singularity/upstream-pins.tsv: path \t url \t branch \t sha
    up = path("assets/singularity/upstream-pins.tsv")
    if os.path.exists(up):
        out["sources"]["upstream-pins.tsv"] = "found"
        count = 0
        for line in open(up, encoding="utf-8", errors="replace"):
            if line.startswith("#") or not line.strip():
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) == 4:
                count += 1
                if f[0] == ".":
                    out["singularity"]["superproject"] = {"sha": f[3], "branch": f[2]}
        out["singularity"]["count"] = count
    else:
        out["sources"]["upstream-pins.tsv"] = "missing"

    return out


# --- stage 3 composition: rehearse or write the proposal ---------------------

def compose_proposal(spec, write=False, replace=None):
    """Compose the stage-3 artefacts: delta report, changelog, transactional pin move.

    spec = {"root": dir, "changes": {relpath: content}, "old": {pkg: ver},
            "new": {pkg: ver}, "evidence": [...], "title": str,
            "changelog_path": relpath}

    Dry run by default. Nothing is written unless write=True, and even then the pin move
    goes through apply_pin_move, which restores every file if one write fails. The
    changelog path is supplied rather than derived from the clock, so the same spec
    produces the same result twice.
    """
    old = spec.get("old", {})
    new = spec.get("new", {})
    delta = classify_delta(old, new, max_delta=10 ** 9, allow_removals=True)
    changelog = render_changelog(old, new, evidence=spec.get("evidence"),
                                 title=spec.get("title", "Substrate pin update"))
    changes = dict(spec.get("changes", {}))
    cpath = spec.get("changelog_path")
    if cpath:
        # In the SAME transaction as the pins: a changelog written after the move leaves a
        # half-committed proposal when it fails, which is the state apply_pin_move exists
        # to make impossible.
        changes[cpath] = changelog
    out = {"dry_run": not write, "delta": delta, "changelog_bytes": len(changelog),
           "written": [], "error": None}
    if not write:
        return out

    applied = apply_pin_move(spec["root"], changes, replace=replace)
    out["applied"] = applied
    if not applied["ok"]:
        out["error"] = applied["error"]
        return out
    out["written"] = list(applied["written"])
    return out


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
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
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


def _cmd_pins(args):
    print(json.dumps(read_pins(args.root), indent=2, sort_keys=True))
    return 0


def _cmd_propose(args):
    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)
    out = compose_proposal(spec, write=args.write)
    print(json.dumps(out, indent=2))
    return 0 if out.get("error") is None else 2


def _cmd_abi(args):
    lock = read_ssplugin_lock(args.lock)
    out = abi_verdict(lock, args.arch, args.payload_version, args.lib_sha)
    print(json.dumps(out, indent=2, sort_keys=True))
    # one readable line last: the CI driver reports the last line of a gate's output
    print("abi: %s - %s" % (out["verdict"], out["why"]))
    return 0 if out["ok"] else 1


def _read_list(path):
    if not path:
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return [line.strip() for line in f if line.strip()]


def _cmd_abi_symbols(args):
    out = symbol_abi_verdict(_read_list(args.baseline), _read_list(args.candidate),
                             _read_list(args.plugin), _read_list(args.needed),
                             soname=args.soname)
    print(json.dumps(out, indent=2, sort_keys=True))
    print("abi-symbols: %s - %s" % ("OK" if out["ok"] else "MISMATCH", out["why"]))
    return 0 if out["ok"] else 1


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

    pn = sub.add_parser("pins", help="read the current pin inventory as JSON")
    pn.add_argument("--root", default=os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    pn.set_defaults(func=_cmd_pins)

    absym = sub.add_parser("abi-symbols", help="stage 6: does the plugin still resolve on a payload")
    absym.add_argument("--baseline", required=True, help="file of the baseline library's exported symbols")
    absym.add_argument("--candidate", required=True, help="file of the candidate library's exported symbols")
    absym.add_argument("--plugin", required=True, help="file of the plugin's undefined symbols")
    absym.add_argument("--needed", default="", help="file of the plugin's DT_NEEDED entries")
    absym.add_argument("--soname", default=LIBSINGULARITY_SONAME)
    absym.set_defaults(func=_cmd_abi_symbols)

    ab = sub.add_parser("abi", help="stage 6: does a payload satisfy the plugin ABI lock")
    ab.add_argument("--lock", required=True, help="post-install/lib/ncz-screensavers-plugin.lock")
    ab.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ab.add_argument("--payload-version", default="")
    ab.add_argument("--lib-sha", default="")
    ab.set_defaults(func=_cmd_abi)

    pr = sub.add_parser("propose", help="stage 3: rehearse or write a pin move")
    pr.add_argument("spec", help="JSON: root, changes, old, new, evidence, changelog_path")
    pr.add_argument("--write", action="store_true", help="actually write (default is a dry run)")
    pr.set_defaults(func=_cmd_propose)

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
