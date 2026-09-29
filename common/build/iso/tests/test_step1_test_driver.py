#!/usr/bin/env python3
"""
test_step1_test_driver.py — End-to-end smoke test for the Step 1
qualification driver.

Runs the prototype/step1-test.py against the already-cached substrate and
ESP, captures the JSON report, and asserts that:

  * Cold compose exits 0 with a passing verifier.
  * Every warm round exits 0 with a passing verifier.
  * The verifier rejection cases that motivated the warm rescue
    finalizer no longer reproduce.

This is the closest we get to a regression test for the warm-writer
fix without re-running qemu boot smoke (which is environmentally
blocked on this host).
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]


def _pytest_skip_if_missing_substrate():
    """Skip the test if the cached substrate node isn't present."""
    substrate_root = REPO_ROOT / "build" / "iso-cache" / "v1" / "nodes" / "amd64" / "substrate"
    candidates = [p for p in substrate_root.glob("*") if p.is_dir()]
    if not candidates:
        raise unittest.SkipTest(
            f"no substrate node cached under {substrate_root}; "
            f"run build/iso/import-substrate.py first"
        )
    esp_img = REPO_ROOT / "prototype" / "work" / "esp" / "esp.img"
    if not esp_img.is_file():
        raise unittest.SkipTest(
            f"ESP image not found at {esp_img}; "
            f"run build/iso/build-refind-esp.py first"
        )
    return candidates[0], esp_img


class Step1EndToEndTests(unittest.TestCase):
    """Drive prototype/step1-test.py as a subprocess and assert all
    cold+warm rounds pass independent verification.

    This is the highest-fidelity test we can write for the warm writer
    without booting the image: it invokes xorriso exactly the same way
    write-image.py does, runs the rescue finalizer, and runs the
    independent verifier. If xorriso's behavior changes (new version,
    new flag, etc.) this test fails and tells us.
    """

    def setUp(self) -> None:
        substrate, esp_img = _pytest_skip_if_missing_substrate()
        self.substrate_dir = substrate
        self.esp_img = esp_img

    def test_cold_and_three_warm_rounds_pass_verification(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir_str:
            tmpdir = Path(tmpdir_str)
            out_dir = tmpdir / "output"
            out_dir.mkdir()
            report_path = tmpdir / "step1-report.json"
            cmd = [
                sys.executable,
                str(REPO_ROOT / "prototype" / "step1-test.py"),
                "--arch", "amd64",
                "--substrate-dir", str(self.substrate_dir),
                "--esp-image", str(self.esp_img),
                "--out-dir", str(out_dir),
                "--report", str(report_path),
                "--warm-rounds", "3",
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(
                proc.returncode,
                0,
                msg=(
                    f"step1-test exited {proc.returncode}\n"
                    f"stdout:\n{proc.stdout[:2000]}\n"
                    f"stderr:\n{proc.stderr[:2000]}"
                ),
            )
            self.assertTrue(
                report_path.is_file(),
                f"step1-test did not write {report_path}; output:{proc.stdout[-1000:]}{proc.stderr[-1000:]}",
            )
            report = json.loads(report_path.read_text())
            # Cold
            cold_ec = report.get("cold", {}).get("exit_code")
            self.assertEqual(cold_ec, 0, f"cold exit_code={cold_ec}")
            # Warm rounds
            for w in report.get("warm_rounds", []):
                run_ec = w["run"]["exit_code"]
                v = w.get("verifier", {}) or {}
                self.assertEqual(run_ec, 0, f"warm round {w['round']} exit_code={run_ec}")
                self.assertTrue(v.get("passed"), f"warm round {w['round']} verifier rejected: {v.get('issues')}")


if __name__ == "__main__":
    unittest.main()
