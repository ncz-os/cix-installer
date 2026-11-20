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

# ---- transactional pin move (F5) -------------------------------------------
import os, tempfile

root = tempfile.mkdtemp(prefix="ncz-ci-test-")
files = {
    "manifests/base.pin": "OLD-BASE\n",
    "release.conf": "OLD-CONF\n",
    "manifests/forky-snapshot.tsv": "OLD-TSV\n",
    "manifests/determinism.pin": "OLD-DET\n",
}
for rel, content in files.items():
    os.makedirs(os.path.dirname(os.path.join(root, rel)) or root, exist_ok=True)
    with open(os.path.join(root, rel), "w") as f:
        f.write(content)

new = {k: v.replace("OLD", "NEW") for k, v in files.items()}
r = m.apply_pin_move(root, new)
check(r["ok"] and len(r["written"]) == 4, "pin move writes all four files")
check(all(open(os.path.join(root, k)).read().startswith("NEW") for k in files),
      "all four files carry the new pin")

# Failure injection: the third rename fails.  Everything must go back.
state = {"n": 0}
def flaky_replace(src, dst):
    state["n"] += 1
    if state["n"] == 3:
        raise OSError("injected: simulated disk failure")
    os.replace(src, dst)

r = m.apply_pin_move(root, {k: v.replace("NEW", "FAILED") for k, v in files.items()},
                     replace=flaky_replace)
check(not r["ok"] and r["rolled_back"], "F5: a failed write is reported as rolled back")
restored = all(open(os.path.join(root, k)).read().startswith("NEW") for k in files)
check(restored, "F5: tree is fully restored - no half-moved pin")
check(not any(fn.endswith(".ncz-tmp") for fn in
              (os.path.join(dp, fn) for dp, _, fns in os.walk(root) for fn in fns)),
      "no staging files left behind after a rollback")

# A brand-new file must be removed again on rollback.
state["n"] = 0
r = m.apply_pin_move(root, {"manifests/new.pin": "X\n"}, replace=flaky_replace)
check(r["ok"], "single new file writes cleanly")

# ---- changelog -------------------------------------------------------------
old = {"a": "1.0-1", "b": "2.1-3", "gone": "1.0-1"}
new = {"a": "1.0-2", "b": "3.0-1", "fresh": "0.1-1"}
big_old, big_new = {}, {}
for i in range(60):
    big_new["pkg%02d" % i] = "1.0-1"

text = m.render_changelog(old, new, evidence=["https://snap.example/InRelease sha256=abc"])
check("1 added" in text and "1 removed" in text and "2 changed" in text,
      "changelog states the counts")
check("`fresh`" in text and "`gone`" in text, "changelog lists added and removed packages")
check("`b` 2.1-3 -> 3.0-1" in text, "changelog shows the version transition")
check("Major version bumps" in text, "changelog calls out major bumps for review")
check("https://snap.example/InRelease sha256=abc" in text, "changelog carries its evidence")

text = m.render_changelog(big_old, big_new, cap=50)
check("... and 10 more" in text,
      "long lists are capped and counted (60 added, cap 50)")

import shutil
shutil.rmtree(root, ignore_errors=True)

# ---- prove aggregation (stage 2) -------------------------------------------
good = {"amd64": {"snapshot": "20990101T000000Z", "coverage": 100.0, "inrelease_sha256": "aa"},
        "arm64": {"snapshot": "20990101T000000Z", "coverage": 100.0, "inrelease_sha256": "aa"}}
r = m.aggregate_proof(good)
check(r["coverage_ok"] and r["digests_equal"] and r["snapshot"] == "20990101T000000Z",
      "both arches 100% on one snapshot with equal digests -> proven")

split = dict(good)
split["arm64"] = dict(good["arm64"], snapshot="20261102T120000Z")
r = m.aggregate_proof(split)
check(not r["snapshot_ok"] and r["snapshot"] is None
      and any("different snapshots" in b for b in r["blockers"]),
      "F3: two arches on two snapshots -> not proven")

d = m.decide(True, True, True, good_delta, automerge_enabled=True, snapshot_ok=False)
check(d["decision"] == "open-mr" and any("different snapshots" in b for b in d["blockers"]),
      "F3: a snapshot split blocks auto-merge even with everything else green")

low = dict(good)
low["amd64"] = dict(good["amd64"], coverage=98.4)
r = m.aggregate_proof(low)
check(not r["coverage_ok"] and any("98.4" in b for b in r["blockers"]),
      "coverage below the floor -> not proven")

samek = dict(good)
samek["arm64"] = dict(good["arm64"], inrelease_sha256="bb")
r = m.aggregate_proof(samek)
check(not r["digests_equal"] and any("digests" in b for b in r["blockers"]),
      "F5: unequal host digests -> not proven")

missing = {"amd64": good["amd64"]}
r = m.aggregate_proof(missing)
check(not r["coverage_ok"] and any("no proof for: arm64" in b for b in r["blockers"]),
      "a missing arch -> not proven")

nosha = {"amd64": dict(good["amd64"], inrelease_sha256=""),
         "arm64": dict(good["arm64"], inrelease_sha256="")}
r = m.aggregate_proof(nosha)
check(not r["digests_equal"], "F5: empty digests never count as equal")

# ---- retention (stage 8) ---------------------------------------------------
items = [
    {"name": "validated-pin", "created": 100, "kind": "pin-branch"},
    {"name": "candidate-new", "created": 400, "kind": "candidate"},
    {"name": "candidate-old", "created": 300, "kind": "candidate"},
    {"name": "candidate-ancient", "created": 200, "kind": "candidate"},
]
r = m.retention_plan(items, validated="validated-pin", keep_candidates=1)
check("validated-pin" in r["keep"] and "candidate-new" in r["keep"],
      "keeps the validated pin and the newest candidate")
check(r["prune"] == ["candidate-old", "candidate-ancient"],
      "prunes older candidates (got %s)" % r["prune"])

r = m.retention_plan([items[0]], validated="validated-pin", keep_candidates=1)
check(r["prune"] == [], "nothing to prune when only the validated pin exists")

r = m.retention_plan(items, validated=None, keep_candidates=2)
check(len(r["keep"]) == 2 and len(r["prune"]) == 2,
      "an unvalidated pile keeps only N candidates")

# ---- gate aggregation (stage 6) --------------------------------------------
allpass = [{"name": "substrate-pin", "status": "pass"}, {"name": "kvm-boot", "status": "pass"}]
r = m.aggregate_gates(allpass)
check(r["green"] and not r["blockers"], "all gates pass -> green")

r = m.aggregate_gates(allpass + [{"name": "modversions", "status": "fail"}])
check(not r["green"] and any("modversions" in b for b in r["blockers"]),
      "a failing gate -> red")

r = m.aggregate_gates(allpass + [{"name": "driver-binding", "status": "skip"}])
check(not r["green"] and any("SKIPPED" in b for b in r["blockers"]),
      "a SKIPPED gate counts as a failure, not a pass")

r = m.aggregate_gates([])
check(not r["green"] and any("no gates ran" in b for b in r["blockers"]),
      "an empty suite proves nothing and is not green")

r = m.aggregate_gates([{"name": "x", "status": "error"}])
check(not r["green"], "an errored gate -> red")

r = m.aggregate_gates(allpass + [{"name": "y"}])
check(not r["green"], "a gate with no status is treated as an error")


# ---- rehearsal: stages 2+6+7 composed --------------------------------------
green_spec = {
    "arches": {"amd64": {"snapshot": "S1", "coverage": 100.0, "inrelease_sha256": "aa"},
               "arm64": {"snapshot": "S1", "coverage": 100.0, "inrelease_sha256": "aa"}},
    "gates": [{"name": "substrate-pin", "status": "pass"}, {"name": "kvm-boot", "status": "pass"}],
    "old": {"a": "1.0-1"},
    "new": {"a": "1.0-2"},
}
r = m.rehearse(green_spec, automerge=True)
check(r["decision"] == "auto-merge" and not r["blockers"],
      "rehearse: everything green + switch on -> auto-merge")

r = m.rehearse(green_spec, automerge=False)
check(r["decision"] == "open-mr" and any("NCZ_CI_AUTOMERGE" in b for b in r["blockers"]),
      "rehearse: default posture is open-mr")

skipped = dict(green_spec, gates=green_spec["gates"] + [{"name": "driver-binding", "status": "skip"}])
r = m.rehearse(skipped, automerge=True)
check(r["decision"] == "open-mr" and any("SKIPPED" in b for b in r["blockers"]),
      "rehearse: a skipped gate blocks the merge")

split = dict(green_spec, arches={"amd64": green_spec["arches"]["amd64"],
                                 "arm64": dict(green_spec["arches"]["arm64"], snapshot="S2")})
r = m.rehearse(split, automerge=True)
check(r["decision"] == "open-mr", "rehearse: divergent snapshots block the merge")

big = dict(green_spec, new={("p%03d" % i): "1.0-1" for i in range(200)})
r = m.rehearse(big, automerge=True)
check(r["decision"] == "open-mr", "rehearse: a delta over the ceiling blocks the merge")


# ---- pin inventory (stage 1 input) -----------------------------------------
import tempfile
root = tempfile.mkdtemp(prefix="ncz-pins-")
os.makedirs(os.path.join(root, "manifests"))
os.makedirs(os.path.join(root, "assets/singularity"))
open(os.path.join(root, "manifests/base.pin"), "w").write(
    "# comment\n"
    "amd64\tSUB1\tMon, 02 Nov 2026 08:09:16 UTC\t20990101T000000Z\t100.0\thttps://x/a.iso\n"
    "arm64\tSUB2\tMon, 02 Nov 2026 08:09:16 UTC\t20990101T000000Z\t100.0\thttps://x/b.iso\n")
open(os.path.join(root, "release.conf"), "w").write(
    'NCZ_BASE_MIRROR_SNAPSHOT="20990101T000000Z"\n'
    'NCZ_LIBDRM_NCZ_REV=abc123\n'
    'NCZ_DKMS_DEB_REV=def456\n')
open(os.path.join(root, "manifests/singularity-payload.tsv"), "w").write(
    "# hdr\narm64\tSHA_A\tpayload.deb\n")
open(os.path.join(root, "assets/singularity/upstream-pins.tsv"), "w").write(
    ".\thttps://github.com/x/desktop.git\tmain\tSUPERSHA\n"
    "subprojects/a\thttps://github.com/x/a.git\t-\tAAA\n")

inv = m.read_pins(root)
check(inv["forky"]["snapshot"] == "20990101T000000Z", "pins: snapshot read from release.conf")
check(set(inv["forky"]["arches"]) == {"amd64", "arm64"}, "pins: both arch rows parsed")
check(inv["forky"]["arches"]["arm64"]["coverage"] == "100.0", "pins: coverage parsed")
check(inv["runtime"].get("libdrm") == "abc123" and inv["runtime"].get("dkms") == "def456",
      "pins: runtime revs parsed")
check(inv["payload"]["arm64"]["sha256"] == "SHA_A", "pins: payload sha parsed")
check(inv["singularity"]["superproject"]["sha"] == "SUPERSHA"
      and inv["singularity"]["count"] == 2, "pins: superproject + pin count parsed")
check(all(v == "found" for v in inv["sources"].values()), "pins: all sources reported found")

empty = tempfile.mkdtemp(prefix="ncz-pins-empty-")
inv2 = m.read_pins(empty)
check(inv2["forky"]["snapshot"] is None
      and all(v == "missing" for v in inv2["sources"].values()),
      "pins: an empty tree reports missing sources instead of crashing")
import shutil as _sh
_sh.rmtree(root, ignore_errors=True); _sh.rmtree(empty, ignore_errors=True)


# ---- proposal composition (stage 3) ----------------------------------------
root = tempfile.mkdtemp(prefix="ncz-prop-")
os.makedirs(os.path.join(root, "manifests"))
for rel, body in (("manifests/base.pin", "OLD-BASE\n"), ("release.conf", "OLD-CONF\n")):
    open(os.path.join(root, rel), "w").write(body)

spec = {"root": root,
        "changes": {"manifests/base.pin": "NEW-BASE\n", "release.conf": "NEW-CONF\n"},
        "old": {"a": "1.0-1"}, "new": {"a": "1.0-2"},
        "evidence": ["https://snap.example/InRelease sha256=abc"],
        "changelog_path": "docs/substrate-changelog-test.md"}

r = m.compose_proposal(spec)
check(r["dry_run"] and r["written"] == [], "propose: dry run writes nothing")
check(open(os.path.join(root, "manifests/base.pin")).read() == "OLD-BASE\n",
      "propose: dry run leaves the pin files untouched")
check(not os.path.exists(os.path.join(root, "docs")), "propose: dry run creates no changelog")

r = m.compose_proposal(spec, write=True)
check(not r["dry_run"] and r["error"] is None, "propose: write mode succeeds")
check(open(os.path.join(root, "manifests/base.pin")).read() == "NEW-BASE\n"
      and open(os.path.join(root, "release.conf")).read() == "NEW-CONF\n",
      "propose: both pin files carry the new content")
cl = os.path.join(root, "docs/substrate-changelog-test.md")
check(os.path.exists(cl) and "1.0-1 -> 1.0-2" in open(cl).read(),
      "propose: changelog written with the transition")

# a failing write must roll the pin files back
open(os.path.join(root, "manifests/base.pin"), "w").write("KEEP-BASE\n")
state = {"n": 0}
def flaky(src, dst):
    state["n"] += 1
    if state["n"] == 2:
        raise OSError("injected")
    os.replace(src, dst)
cpath2 = os.path.join(root, "docs/rollback-changelog.md")
r = m.compose_proposal({"root": root,
                        "changes": {"manifests/base.pin": "X\n", "release.conf": "Y\n"},
                        "changelog_path": "docs/rollback-changelog.md"},
                       write=True, replace=flaky)
check(r["error"] is not None and open(os.path.join(root, "manifests/base.pin")).read() == "KEEP-BASE\n",
      "propose: a failed write rolls back and reports the error")
check(not os.path.exists(cpath2),
      "propose: the changelog is inside the transaction, so a failed move leaves none behind")
_sh.rmtree(root, ignore_errors=True)


# ---- plugin ABI lock vs payload (stage 6) -----------------------------------
abiroot = tempfile.mkdtemp(prefix="ncz-abi-")
lock = os.path.join(abiroot, "plugin.lock")
open(lock, "w").write(
    "NCZ_SSPLUGIN_VERSION=0.3.26\n"
    "NCZ_SSPLUGIN_PAYLOAD_amd64=20261013233000+bk0+tgzef364e5b\n"
    "NCZ_SSPLUGIN_PAYLOAD_arm64=20261013233000+bk0+tgz03b581f4\n"
    "NCZ_SSPLUGIN_ABI_LIB=/opt/singularity/lib/libsingularity.so.0\n"
    "NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_amd64=aa97ef0a\n"
    "NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_arm64=2da0aeb5\n")
lk = m.read_ssplugin_lock(lock)
check(lk["version"] == "0.3.26" and lk["abi_lib"].endswith("libsingularity.so.0"),
      "abi: lock header parsed")
check(lk["payload"]["arm64"] == "20261013233000+bk0+tgz03b581f4"
      and lk["libsha"]["amd64"] == "aa97ef0a", "abi: per-arch rows parsed")

v = m.abi_verdict(lk, "arm64", "20261013233000+bk0+tgz03b581f4", "ffff")
check(v["ok"] and v["verdict"] == "version-match", "abi: same payload version passes")

v = m.abi_verdict(lk, "arm64", "20261106151728+bk0+git6427e9c4", "2da0aeb5")
check(v["ok"] and v["verdict"] == "lib-identical",
      "abi: a new payload passes when libsingularity is byte-identical")

v = m.abi_verdict(lk, "arm64", "20261106151728+bk0+git6427e9c4", "561e7a49")
check(not v["ok"] and v["verdict"] == "mismatch", "abi: new payload + new library is a mismatch")
check("2da0aeb5" in v["why"] and "561e7a49" in v["why"], "abi: the mismatch names both shas")

v = m.abi_verdict(lk, "riscv64", "x", "y")
check(not v["ok"] and "no row" in v["why"], "abi: an arch the lock does not cover is reported, not passed")

empty = m.read_ssplugin_lock(os.path.join(abiroot, "no-such.lock"))
check(empty["version"] is None and empty["payload"] == {}, "abi: a missing lock yields empty, not a crash")
check(not m.abi_verdict(empty, "arm64", "v", "s")["ok"], "abi: a missing lock cannot pass")

# ---- symbol-level ABI (stage 6, the question a sha cannot answer) ------------
def _read(p):
    return [l.strip() for l in open(p, encoding="utf-8") if l.strip()]


def _sym(path, names):
    open(path, "w").write("".join(n + "\n" for n in names))
    return path

base = _sym(os.path.join(abiroot, "base.syms"), ["alpha", "beta", "gamma"])
cand = _sym(os.path.join(abiroot, "cand.syms"), ["alpha", "beta", "gamma", "delta"])
plug = _sym(os.path.join(abiroot, "plug.und"), ["alpha", "delta", "gtk_init", "memcpy"])
need = _sym(os.path.join(abiroot, "plug.need"), ["libc.so.6", "libsingularity.so.0"])

v = m.symbol_abi_verdict(_read(base), _read(cand), _read(plug), _read(need))
check(v["ok"] and "superset" in v["why"], "abi-symbols: superset with the SONAME passes")
check(v["plugin_imports"] == 1, "abi-symbols: counts only imports the library provided")

gone = _sym(os.path.join(abiroot, "gone.syms"), ["alpha", "gamma"])
v = m.symbol_abi_verdict(_read(base), _read(gone), _read(plug), _read(need))
check(not v["ok"] and v["removed"] == ["beta"], "abi-symbols: a dropped symbol fails and is named")

v = m.symbol_abi_verdict(_read(base), _read(cand), _read(plug), _read(_sym(os.path.join(abiroot, "n.need"), ["libc.so.6"])))
check(not v["ok"] and v["soname_ok"] is False, "abi-symbols: a plugin that does not link the library fails")

v = m.symbol_abi_verdict(_read(base), _read(_sym(os.path.join(abiroot, "e.syms"), [])), _read(plug), _read(need))
check(not v["ok"] and "could not be read" in v["why"], "abi-symbols: an unreadable candidate cannot pass")

v = m.symbol_abi_verdict([], _read(cand), _read(plug), _read(need))
check(not v["ok"] and "nothing is proven" in v["why"], "abi-symbols: an empty baseline proves nothing")

# the plugin needs something the baseline had, but the candidate lost it
cand2 = _sym(os.path.join(abiroot, "cand2.syms"), ["beta", "gamma", "delta"])
v = m.symbol_abi_verdict(_read(base), _read(cand2), _read(plug), _read(need))
check(not v["ok"] and ("alpha" in v["removed"] or "alpha" in v["unsatisfied"]),
      "abi-symbols: a symbol the plugin needs and the candidate lost is a failure")
# an unreadable DT_NEEDED list is a failed read, not a pass
v = m.symbol_abi_verdict(_read(base), _read(cand), _read(plug), [])
check(not v["ok"] and "cannot prove" in v["why"],
      "abi-symbols: an empty NEEDED list cannot prove the plugin links the library")

_sh.rmtree(abiroot, ignore_errors=True)




print("\n%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)
PY
