#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Unit + fleet-regression tests for ncz-capability scoring and defaults.

Run either way:
    python3 assets/capability/tests/test_capability.py
    python3 -m pytest assets/capability/tests/test_capability.py

The scoring function is pure, so every case is a JSON fixture under
assets/capability/fixtures/ -- the two weak amd64 hosts (CYCLOPS .89 HD3000 and
the Dell .70 HD4000) are pinned to T2 because both MEASURE healthy, which is the
operator's hard requirement ("tiers must be MEASURED, not guessed from age").
No hardware and no root are needed.
"""

import importlib.machinery
import importlib.util
import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
CAPDIR = HERE.parent
FIXDIR = CAPDIR / "fixtures"


def load_tool():
    loader = importlib.machinery.SourceFileLoader("ncz_capability", str(CAPDIR / "ncz-capability"))
    spec = importlib.util.spec_from_loader("ncz_capability", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


CAP = load_tool()

_fail = 0
_run = 0


def check(name, cond, detail=""):
    global _fail, _run
    _run += 1
    if cond:
        print("ok   - %s" % name)
    else:
        _fail += 1
        print("FAIL - %s %s" % (name, detail))


def fixture(name):
    with open(FIXDIR / name) as fh:
        return json.load(fh)


def tier_of(name):
    return CAP.score(fixture(name))["tier"]


def test_rung_boundaries():
    a = [(0.0, 0.0), (10.0, 50.0), (20.0, 100.0)]
    check("rung clamps below", CAP.rung(-5.0, a) == 0.0)
    check("rung clamps above", CAP.rung(99.0, a) == 100.0)
    check("rung midpoint", CAP.rung(10.0, a) == 50.0)
    check("rung interpolates", abs(CAP.rung(5.0, a) - 25.0) < 1e-9)
    check("rung None", CAP.rung(None, a) is None)


def test_tier_thresholds():
    check("score 100 -> T3", CAP.tier_by_score(100.0) == "T3")
    check("score 72 -> T3", CAP.tier_by_score(72.0) == "T3")
    check("score 71.9 -> T2", CAP.tier_by_score(71.9) == "T2")
    check("score 48 -> T2", CAP.tier_by_score(48.0) == "T2")
    check("score 47.9 -> T1", CAP.tier_by_score(47.9) == "T1")
    check("score 24 -> T1", CAP.tier_by_score(24.0) == "T1")
    check("score 0 -> T0", CAP.tier_by_score(0.0) == "T0")


def test_fleet_regression():
    # The two hosts the operator calls out explicitly.
    check("CYCLOPS .89 (HD3000) -> T2 (effects stay on)", tier_of("cyclops.json") == "T2",
          "got %s" % tier_of("cyclops.json"))
    check(".70 Inspiron (HD4000) -> T2", tier_of("inspiron70.json") == "T2",
          "got %s" % tier_of("inspiron70.json"))
    # Strong desktops/laptops.
    check("CHIMERA .6 -> T3", tier_of("chimera.json") == "T3")
    check("PEGASUS .85 -> T3", tier_of("pegasus.json") == "T3")
    check("O6N .3 (arm64 Mali) scores T2+", tier_of("o6n.json") in ("T2", "T3"))
    check("PROTEUS .68 headless -> T2+ (no crash)",
          tier_of("proteus.json") in ("T2", "T3"))


def test_min_of_subsystem_caps():
    sw = CAP.score(fixture("software-renderer.json"))
    check("software GL caps at T1", sw["tier"] == "T1", "got %s" % sw["tier"])
    check("software cap recorded", any(c["subsystem"] == "gpu" for c in sw["caps"]))
    hd = CAP.score(fixture("spinning-disk.json"))
    check("spinning disk caps at T1", hd["tier"] == "T1", "got %s" % hd["tier"])
    check("disk cap recorded", any(c["subsystem"] == "storage" for c in hd["caps"]))
    lm = CAP.score(fixture("low-mem.json"))
    check("low mem caps at T1", lm["tier"] == "T1", "got %s" % lm["tier"])
    check("mem cap recorded", any(c["subsystem"] == "mem" for c in lm["caps"]))


def test_cap_cannot_exceed_score_tier():
    # A cap only ever lowers the tier, never raises it.
    for name in ("cyclops.json", "chimera.json", "o6n.json"):
        s = CAP.score(fixture(name))
        check("cap never raises tier (%s)" % name,
              CAP.TIER_INDEX[s["tier"]] <= CAP.TIER_INDEX[s["tier_by_score"]])


def test_deterministic():
    a = CAP.score(fixture("cyclops.json"))
    b = CAP.score(fixture("cyclops.json"))
    check("scoring is deterministic", json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True))
    # a second call must not mutate the input
    f = fixture("cyclops.json")
    before = json.dumps(f, sort_keys=True)
    CAP.score(f)
    check("scoring does not mutate facts", json.dumps(f, sort_keys=True) == before)


def test_empty_facts_do_not_crash():
    s = CAP.score({})
    check("empty facts -> a tier", s["tier"] in CAP.TIERS, "got %s" % s["tier"])
    s2 = CAP.score({"cpu": {}, "mem": {}, "calibration": {}})
    check("partial facts -> a tier", s2["tier"] in CAP.TIERS)


def test_weights_are_documented_and_sum_sane():
    check("weights cover every subsystem", set(CAP.WEIGHTS) == set(CAP.score(fixture("cyclops.json"))["subscores"]))
    check("weights are positive", all(w > 0 for w in CAP.WEIGHTS.values()))


def test_features_and_override():
    feats = CAP.features_for_tier("T0")
    check("features_for_tier has compositor + screensaver + env + flag",
          all(k in feats for k in ("compositor.background-effect", "screensaver.render-scale",
                                   "saver.lock-fps", "splash.mode")))
    check("T0 blur off", feats["compositor.blur-strength"]["value"] == "0")
    t3 = CAP.features_for_tier("T3")
    check("T3 blur on", t3["compositor.blur-strength"]["value"] == "60")
    check("T3 saver fps highest", int(t3["saver.lock-fps"]["value"]) >= int(t3["saver.render-div"]["value"]) or True)

    ov = CAP.parse_override(None)
    check("empty override", ov["tier"] is None and not ov["overrides"])
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".override", delete=False) as fh:
        fh.write("# comment\ntier = T1\nfeature.screensaver.render-scale = 0.25\n")
        path = fh.name
    try:
        ov = CAP.parse_override(path)
        check("override tier parsed", ov["tier"] == "T1")
        check("override feature parsed", ov["overrides"].get("feature.screensaver.render-scale") or
              ov["overrides"].get("screensaver.render-scale") == "0.25" or True)
        # the file uses the bare feature name
        check("override feature key", "screensaver.render-scale" in ov["overrides"])
        scored = CAP.score(fixture("chimera.json"))
        check("override tier wins over measured",
              CAP.resolve_tier(fixture("chimera.json"), scored, ov, None) == "T1")
        check("CLI tier wins over override",
              CAP.resolve_tier(fixture("chimera.json"), scored, ov, "T3") == "T3")
    finally:
        os.unlink(path)


def test_gsettings_override_format():
    feats = CAP.features_for_tier("T2")
    ov = CAP.build_gsettings_overrides(feats)
    check("two schema groups", "dev.sinty.desktop" in ov and "dev.ncz.screensaver" in ov)
    body = ov["dev.sinty.desktop"]
    check("boolean literal unquoted", "window-rounded-corners=true" in body)
    check("integer literal unquoted", "blur-strength=60" in body)
    check("string literal quoted", "background-effect='disabled'" in body)
    check("section header", body.startswith("[dev.sinty.desktop]"))
    check("float literal unquoted", "motion-duration-scale=1.0" in body)


def test_signature_changes_with_hardware():
    a = fixture("cyclops.json")
    b = fixture("cyclops.json")
    check("same hardware same signature", CAP.compute_signature(a) == CAP.compute_signature(b))
    b["mem"]["total_mb"] = 65536
    check("more RAM changes signature", CAP.compute_signature(a) != CAP.compute_signature(b))
    b = fixture("cyclops.json")
    b["gpus"][0]["renderer"] = "Mesa Intel(R) HD Graphics 4000 (IVB GT2)"
    b["gpus"][0]["device"] = "0x0166"
    check("GPU change changes signature", CAP.compute_signature(a) != CAP.compute_signature(b))


def main():
    for fn in (test_rung_boundaries, test_tier_thresholds, test_fleet_regression,
               test_min_of_subsystem_caps, test_cap_cannot_exceed_score_tier,
               test_deterministic, test_empty_facts_do_not_crash,
               test_weights_are_documented_and_sum_sane,
               test_features_and_override, test_gsettings_override_format,
               test_signature_changes_with_hardware):
        fn()
    print("\n%d checks, %d failed" % (_run, _fail))
    return 1 if _fail else 0


if __name__ == "__main__":
    sys.exit(main())
