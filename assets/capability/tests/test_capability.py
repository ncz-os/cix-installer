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
    t0 = CAP.features_for_tier("T0")
    t3 = CAP.features_for_tier("T3")
    # T3 must be strictly richer than T0 on both the saver frame rate and render
    # resolution (guard against a copy/paste in the TSV collapsing two tiers).
    check("T3 saver fps > T0 saver fps",
          int(t3["saver.lock-fps"]["value"]) > int(t0["saver.lock-fps"]["value"]),
          "T3=%s T0=%s" % (t3["saver.lock-fps"]["value"], t0["saver.lock-fps"]["value"]))
    check("T3 render-div < T0 render-div (higher resolution)",
          int(t3["saver.render-div"]["value"]) < int(t0["saver.render-div"]["value"]))

    ov = CAP.parse_override(None)
    check("empty override", ov["tier"] is None and not ov["overrides"])
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".override", delete=False) as fh:
        fh.write("# comment\ntier = T1\nfeature.screensaver.render-scale = 0.25\n")
        path = fh.name
    try:
        ov = CAP.parse_override(path)
        check("override tier parsed", ov["tier"] == "T1")
        check("override feature parsed", ov["overrides"].get("screensaver.render-scale") == "0.25",
              "got %r" % ov["overrides"])
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


# ---------------------------------------------------------------------------
# First-boot measured saver pool (step 2)
# ---------------------------------------------------------------------------

def _saver_facts(renderer="Mesa Intel(R) HD Graphics 4000 (IVB GT2)", gl_version="OpenGL ES 3.0 Mesa 26.1.6",
                 software=False, outputs=1, width=1366, height=768):
    gpu = {"card": "card0", "vendor": "0x8086", "device": "0x0166", "driver": "i915",
           "boot_vga": True, "renderer": renderer, "gl_version": gl_version,
           "software": software, "class": "weak"}
    return {
        "gpus": [gpu], "display": {"outputs": outputs, "max_width": width, "max_height": height},
        "calibration": {"gpu_renderer": renderer, "gpu_version": gl_version},
        "platform": {"hostname": "test"}, "cpu": {}, "mem": {}, "storage": {}, "thermal": {},
    }


def test_saver_manifest_and_classes():
    doc = CAP.load_saver_manifest()
    check("saver manifest loads", bool(doc.get("savers")), "path=%s" % doc.get("_path"))
    if not doc.get("savers"):
        return
    check("renderer maps to hd4000",
          CAP.saver_reference_class("Mesa Intel(R) HD Graphics 4000 (IVB GT2)") == "hd4000")
    check("unknown renderer uses coarse class",
          CAP.saver_reference_class("Mystery GPU", "mid") == "mali_g720")
    check("gles parse", CAP.gpu_gles_version(_saver_facts()) ==
          (3, 0, "OpenGL ES 3.0 Mesa 26.1.6"))
    check("gles compare 3.0 >= 3.0", CAP._gles_at_least((3, 0), "3.0"))
    check("gles compare 3.0 < 3.2", not CAP._gles_at_least((3, 0), "3.2"))
    pool, excluded = CAP.manifest_fallback_pool(doc, "hd4000")
    pool_by = {p["id"]: p["scale"] for p in pool}
    check("manifest fallback pools fractasia native", pool_by.get("fractasia_gles3") == 1.0)
    check("manifest fallback scales blackhole 0.25", pool_by.get("blackhole_gles3") == 0.25)
    check("manifest fallback excludes hyprsaver on hd4000",
          any(e["id"] == "hyprsaver_aurora_gles3" for e in excluded))
    # candidates honour min_gles
    cands = CAP.saver_candidates(doc, (3, 0))
    check("hyprsaver not a GLES3.0 candidate", "hyprsaver_aurora_gles3" not in cands)
    check("fractasia is a GLES3.0 candidate", "fractasia_gles3" in cands)
    cands32 = CAP.saver_candidates(doc, (3, 2))
    check("hyprsaver is a GLES3.2 candidate", "hyprsaver_aurora_gles3" in cands32)


def test_saver_pool_fallbacks():
    doc = CAP.load_saver_manifest()
    if not doc.get("savers"):
        check("saver manifest present for fallback test", False)
        return
    # T3 (arm64 Mali): benchmark is skipped, manifest fallback is used
    r = CAP.saver_bench(_saver_facts(), {"tier": "T3"}, manifest=doc)
    check("T3 uses manifest fallback", r["saver_pool_source"] == "manifest-fallback", str(r)[:200])
    # software GPU
    r = CAP.saver_bench(_saver_facts(software=True), {"tier": "T2"}, manifest=doc)
    check("software GPU skipped", r["saver_pool_source"] == "manifest-fallback")
    # headless
    r = CAP.saver_bench(_saver_facts(outputs=0), {"tier": "T2"}, manifest=doc)
    check("headless skipped", r["saver_pool_source"] == "manifest-fallback")
    # no manifest at all
    r = CAP.saver_bench(_saver_facts(), {"tier": "T2"}, manifest={})
    check("no manifest -> unavailable", r["saver_pool_source"] == "unavailable")


def test_saver_pool_measured():
    doc = CAP.load_saver_manifest()
    if not doc.get("savers"):
        return
    facts = _saver_facts()
    # synthetic measurement: every saver is 60 fps at native
    orig_find, orig_bench = CAP.find_saver_binary, CAP.bench_saver_once
    CAP.find_saver_binary = lambda hid, root="": "/tmp/%s" % hid
    CAP.bench_saver_once = lambda hid, scale, display, binary, **kw: {
        "hack": hid, "scale": scale, "fps": 60.0, "p95_ms": 16.6,
        "frames": 120, "error": None, "renderer": "fake"}
    try:
        r = CAP.saver_bench(facts, {"tier": "T2"}, manifest=doc, budget=30.0)
    finally:
        CAP.find_saver_binary, CAP.bench_saver_once = orig_find, orig_bench
    check("benchmark ran", r["saver_pool_source"] == "measured", str(r)[:200])
    check("benchmark pooled something", len(r["saver_pool"]) >= 1)
    check("benchmark scaled within budget", r["saver_pool_elapsed_s"] <= 30.0 + 1.0)
    check("benchmark recorded reference class", r["saver_pool_reference_class"] == "hd4000")
    check("every measured entry has a scale in {1.0,0.5,0.25}",
          all(p["scale"] in (1.0, 0.5, 0.25) for p in r["saver_pool"]))


def test_saver_bench_scale_fall():
    doc = CAP.load_saver_manifest()
    if not doc.get("savers"):
        return
    facts = _saver_facts()
    orig_find, orig_bench = CAP.find_saver_binary, CAP.bench_saver_once
    CAP.find_saver_binary = lambda hid, root="": "/tmp/%s" % hid
    calls = []

    def fake(hid, scale, display, binary, **kw):
        calls.append(scale)
        # native fails, 0.5 reaches 45 fps
        fps = 12.0 if scale == 1.0 else 45.0
        return {"hack": hid, "scale": scale, "fps": fps, "p95_ms": 20.0,
                "frames": 100, "error": None}
    CAP.bench_saver_once = fake
    try:
        r = CAP.saver_bench(facts, {"tier": "T2"}, manifest=doc, budget=30.0)
    finally:
        CAP.find_saver_binary, CAP.bench_saver_once = orig_find, orig_bench
    check("fall to 0.5 when native is slow", 0.5 in calls, str(calls[:6]))
    check("some entries use scale 0.5", any(p["scale"] == 0.5 for p in r["saver_pool"]))


def test_bench_saver_protocol():
    """Drive bench_saver_once with a fake off-screen child that speaks the
    lock_framesrc protocol (skipped where AF_UNIX SOCK_SEQPACKET is absent)."""
    import socket as _socket
    try:
        _socket.socket(_socket.AF_UNIX, _socket.SOCK_SEQPACKET).close()
    except OSError:
        check("saver bench protocol (skipped: no SOCK_SEQPACKET)", True)
        return
    import stat
    import tempfile
    import textwrap
    child = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
    child.write(textwrap.dedent("""
        #!/usr/bin/env python3
        import os, socket, struct, sys, time
        spath = os.environ["NCZ_FEED_SOCKET"]
        s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        s.connect(spath)
        MAGIC = 0x4C465331
        def send(mtype, payload=b"", fd=None):
            data = struct.pack("<IHHI", MAGIC, mtype, 0, len(payload)) + payload
            if fd is None:
                s.sendall(data)
            else:
                s.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("i", fd))])
        send(1, struct.pack("<III", 1, 1, 0))       # HELLO
        s.recv(65535)                                # WELCOME
        fd = os.open(sys.argv[1], os.O_RDONLY)
        for i in range(420):
            send(2, struct.pack("<IIIIIIIII", i, 0x5A5E5A5E, 2, 2, 8, 0, 1), fd=fd)
            time.sleep(1.0 / 60.0)
        send(3, b"")                                 # BYE
    """).lstrip())
    child.close()
    os.chmod(child.name, os.stat(child.name).st_mode | stat.S_IEXEC)
    framefile = tempfile.NamedTemporaryFile(delete=False)
    framefile.write(b"\0" * 64)
    framefile.close()
    try:
        r = CAP.bench_saver_once("fake_gles3", 1.0, (640, 480), child.name,
                                 seconds=1.0, warmup=0.2)
    finally:
        os.unlink(child.name)
        os.unlink(framefile.name)
    check("bench protocol produced fps", r.get("fps") is not None, str(r)[:200])
    check("bench protocol fps near 60", r.get("fps") and 40 <= r["fps"] <= 90,
          "fps=%s" % r.get("fps"))
    check("bench protocol recorded p95", r.get("p95_ms") is not None)


def main():
    for fn in (test_rung_boundaries, test_tier_thresholds, test_fleet_regression,
               test_min_of_subsystem_caps, test_cap_cannot_exceed_score_tier,
               test_deterministic, test_empty_facts_do_not_crash,
               test_weights_are_documented_and_sum_sane,
               test_features_and_override, test_gsettings_override_format,
               test_signature_changes_with_hardware,
               test_saver_manifest_and_classes, test_saver_pool_fallbacks,
               test_saver_pool_measured, test_saver_bench_scale_fall,
               test_bench_saver_protocol):
        fn()
    print("\n%d checks, %d failed" % (_run, _fail))
    return 1 if _fail else 0


if __name__ == "__main__":
    sys.exit(main())
