#!/usr/bin/env python3
"""Tests for assets/display/ncz-display-scale (docs/HIDPI-SCALING.md).

Run:  python3 -m pytest build/test_display_scale.py
  or: python3 build/test_display_scale.py

The wlr-randr fixtures are real `wlr-randr --json` shapes; CHIMERA's is
copied from the MacBookPro16,1 panel (3072x1920, 340x220 mm) on 2026-10-06.
"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE.parent / "assets" / "display" / "ncz-display-scale"

sys.dont_write_bytecode = True  # no __pycache__ next to the shipped helper
_loader = importlib.machinery.SourceFileLoader("ncz_display_scale", str(HELPER))
_spec = importlib.util.spec_from_loader("ncz_display_scale", _loader)
nds = importlib.util.module_from_spec(_spec)
_loader.exec_module(nds)


def mode(w, h, refresh=60.0, preferred=False, current=False):
    return {
        "width": w,
        "height": h,
        "refresh": refresh,
        "preferred": preferred,
        "current": current,
    }


def output(
    name, mm, modes, scale=1.0, enabled=True, make="Maker", model="Panel", serial=None
):
    return {
        "name": name,
        "make": make,
        "model": model,
        "serial": serial,
        "physical_size": {"width": mm[0], "height": mm[1]},
        "enabled": enabled,
        "scale": scale,
        "modes": modes,
    }


CHIMERA = output(
    "eDP-1",
    (340, 220),
    [
        mode(3072, 1920, preferred=True, current=True),
        mode(1920, 1200),
        mode(1920, 1080),
        mode(1680, 1050),
        mode(1024, 768),
    ],
    make="Apple Computer Inc",
    model="Color LCD",
)
MONITOR_4K_27 = output(
    "DP-2",
    (597, 336),
    [
        mode(3840, 2160, 59.997, preferred=True, current=True),
        mode(2560, 1440),
        mode(1920, 1080, 60.0),
        mode(1920, 1080, 50.0),
    ],
)
MONITOR_NO_EDID_SIZE = output(
    "HDMI-A-1", (0, 0), [mode(1920, 1080, preferred=True, current=True)]
)
MONITOR_1200P = output(
    "DP-1",
    (518, 324),
    [mode(1920, 1200, preferred=True, current=True), mode(1920, 1080)],
)


class FakeRandr:
    """Stands in for subprocess.run(["wlr-randr", ...])."""

    def __init__(self, outputs, json_rc=0, set_rc=0):
        self.outputs = outputs
        self.json_rc = json_rc
        self.set_rc = set_rc
        self.calls = []

    def __call__(self, argv, **_kw):
        assert argv[0] == "wlr-randr"
        if argv[1:] == ["--json"]:
            return subprocess.CompletedProcess(
                argv, self.json_rc, json.dumps(self.outputs), ""
            )
        self.calls.append(argv[1:])
        return subprocess.CompletedProcess(argv, self.set_rc, "", "")


class PolicyTest(unittest.TestCase):
    def check(self, mode_px, mm, want):
        got, why = nds.policy_scale(*mode_px, *mm)
        self.assertEqual(
            got, want, f"{mode_px} on {mm} mm -> {got} ({why}), want {want}"
        )

    def test_retina_panels_get_2x(self):
        self.check((3072, 1920), (340, 220), 2.0)  # MacBookPro16,1, 227 ppi
        self.check((2880, 1800), (331, 207), 2.0)  # 15" Retina
        self.check((3840, 2160), (344, 194), 2.0)  # 15.6" 4K laptop

    def test_mid_density_gets_1_5x(self):
        self.check((3840, 2160), (597, 336), 1.5)  # 27" 4K, 163 ppi
        self.check((1920, 1080), (309, 174), 1.5)  # 14" FHD, 157 ppi
        self.check((3840, 2160), (527, 296), 1.5)  # 24" 4K, 184 ppi

    def test_ordinary_monitors_stay_1x(self):
        self.check((1920, 1080), (527, 296), 1.0)  # 24" FHD
        self.check((2560, 1440), (597, 336), 1.0)  # 27" QHD
        self.check((3840, 2160), (698, 393), 1.0)  # 32" 4K, 137 ppi
        self.check((1366, 768), (344, 194), 1.0)
        self.check((1024, 768), (304, 228), 1.0)

    def test_a_downscaled_mode_on_a_retina_panel_is_judged_by_its_own_density(self):
        self.check((1920, 1200), (340, 220), 1.0)  # 142 ppi

    def test_untrustworthy_sizes_fall_back_to_1x(self):
        self.check((3840, 2160), (0, 0), 1.0)  # no EDID size (KVM, projector)
        self.check((3840, 2160), (160, 0), 1.0)
        self.check((3840, 2160), (16, 9), 1.0)  # aspect-ratio-only EDID
        self.check((3840, 2160), (400, 400), 1.0)  # square size on a 16:9 mode
        self.check((0, 0), (340, 220), 1.0)

    def test_tv_sized_panels_stay_1x(self):
        self.check((3840, 2160), (1428, 803), 1.0)  # 65" TV

    def test_cli_policy(self):
        res = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "policy",
                "--mode",
                "3072x1920",
                "--phys",
                "340x220",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertTrue(res.stdout.startswith("2 "), res.stdout)


class GreeterTest(unittest.TestCase):
    def test_16_10_panel_gets_same_aspect_mode_not_letterboxed_1080p(self):
        self.assertEqual(nds.greeter_mode(CHIMERA)["height"], 1200)
        fake = FakeRandr([CHIMERA])
        self.assertEqual(nds.cmd_greeter(False, runner=fake), 0)
        self.assertEqual(
            fake.calls,
            [["--output", "eDP-1", "--mode", "1920x1200@60.000000Hz", "--scale", "1"]],
        )

    def test_4k_monitor_never_scans_out_4k(self):
        m = nds.greeter_mode(MONITOR_4K_27)
        self.assertEqual((m["width"], m["height"], m["refresh"]), (1920, 1080, 60.0))
        fake = FakeRandr([MONITOR_4K_27])
        nds.cmd_greeter(False, runner=fake)
        self.assertFalse(
            any("3840" in " ".join(c) or "2160" in " ".join(c) for c in fake.calls),
            fake.calls,
        )

    def test_native_1200p_monitor_keeps_its_mode(self):
        self.assertEqual(nds.greeter_mode(MONITOR_1200P)["height"], 1200)

    def test_falls_back_to_plain_mode_spelling(self):
        class FirstFails(FakeRandr):
            def __call__(self, argv, **kw):
                res = super().__call__(argv, **kw)
                if argv[1:] != ["--json"] and "@" in " ".join(argv):
                    return subprocess.CompletedProcess(argv, 1, "", "")
                return res

        fake = FirstFails([CHIMERA])
        nds.cmd_greeter(False, runner=fake)
        self.assertEqual(
            fake.calls[-1], ["--output", "eDP-1", "--mode", "1920x1200", "--scale", "1"]
        )

    def test_unreadable_outputs_return_1_so_the_autostart_falls_back(self):
        self.assertEqual(nds.cmd_greeter(False, runner=FakeRandr([], json_rc=1)), 1)

    def test_disabled_outputs_are_left_alone(self):
        off = dict(CHIMERA, enabled=False)
        fake = FakeRandr([off])
        nds.cmd_greeter(False, runner=fake)
        self.assertEqual(fake.calls, [])


class SessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {
            "XDG_STATE_HOME": f"{self.tmp.name}/state",
            "XDG_CONFIG_HOME": f"{self.tmp.name}/config",
        }
        self.old = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def run_session(self, outputs):
        fake = FakeRandr(outputs)
        self.assertEqual(
            nds.cmd_session(0, False, runner=fake, sleep=lambda _s: None), 0
        )
        return fake

    def stamps(self):
        d = Path(self.env["XDG_STATE_HOME"]) / "ncz" / "display-scale"
        return sorted(d.glob("*.json")) if d.exists() else []

    def test_raises_a_hidpi_panel_left_at_1x(self):
        fake = self.run_session([CHIMERA])
        self.assertEqual(fake.calls, [["--output", "eDP-1", "--scale", "2"]])
        self.assertEqual(len(self.stamps()), 1)
        self.assertEqual(json.loads(self.stamps()[0].read_text())["action"], "applied")

    def test_first_login_only(self):
        self.run_session([CHIMERA])
        again = self.run_session([CHIMERA])  # user lowered it back to 1.0 since
        self.assertEqual(again.calls, [])

    def test_keeps_a_scale_the_shell_already_chose(self):
        fake = self.run_session([dict(CHIMERA, scale=1.75)])
        self.assertEqual(fake.calls, [])
        self.assertEqual(json.loads(self.stamps()[0].read_text())["action"], "kept")

    def test_never_touches_anything_once_display_settings_were_saved(self):
        cfg = Path(self.env["XDG_CONFIG_HOME"]) / "singularity" / "displays.json"
        cfg.parent.mkdir(parents=True)
        cfg.write_text('{"monitors": []}')
        fake = self.run_session([CHIMERA])
        self.assertEqual(fake.calls, [])
        self.assertEqual(self.stamps(), [])

    def test_monitor_without_edid_size_stays_1x(self):
        fake = self.run_session([MONITOR_NO_EDID_SIZE])
        self.assertEqual(fake.calls, [])

    def test_new_display_later_is_still_handled_once(self):
        self.run_session([CHIMERA])
        fake = self.run_session([dict(CHIMERA, scale=2.0), MONITOR_4K_27])
        self.assertEqual(fake.calls, [["--output", "DP-2", "--scale", "1.5"]])

    def test_failed_apply_is_not_recorded_so_it_retries_next_login(self):
        fake = FakeRandr([CHIMERA], set_rc=1)
        nds.cmd_session(0, False, runner=fake, sleep=lambda _s: None)
        self.assertEqual(self.stamps(), [])

    def test_cli_never_fails_without_wlr_randr(self):
        env = dict(os.environ, PATH="/nonexistent")
        res = subprocess.run(
            [sys.executable, str(HELPER), "session", "--settle", "0"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0, res.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
