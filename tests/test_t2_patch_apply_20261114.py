"""Sequential dry-run of the six T2 hardening patches.

Copies the vendored src/ trees to a temp dir, applies the gmux patches
(0001..0003) and the t2smc patches kept after the 8c7f725 re-vendor
(0001, 0003, 0005) in dkms.conf order with `patch -p1`,
and fails if any patch does not apply cleanly.  Guards the rebase: a
patch that silently stops applying would ship unpatched drivers to DKMS.

A second set of assertions checks that the *hardening semantics* survive
the rebase, not just that the hunks land.  Re-vendoring upstream can make
a patch apply while turning it into a no-op, so each behaviour below is
grep-verified in the patched source:

  gmux  - bounded acknowledge loop, quiescing flag, error recording
  smc   - fan-envelope validation, range checks, RTC offset validation,
          cache-init, telemetry error propagation

t2smc patches 0002 (temperature discovery) and 0004 (charge limit) were
dropped because upstream 8c7f725 contains those fixes; the pristine-source
tests below prove that on the vendored file, so a future re-vendor that
loses them fails here instead of shipping the old defect.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GMUX_SRC = ROOT / "assets/kernel/t2gmux/src/t2gmux.c"
SMC_SRC = ROOT / "assets/kernel/t2smc/src/t2smc.c"
GMUX_PATCHES = [
    ROOT / "assets/kernel/t2gmux/patches/0001-t2gmux-bounded-drain.patch",
    ROOT / "assets/kernel/t2gmux/patches/0002-t2gmux-pm-quiesce.patch",
    ROOT / "assets/kernel/t2gmux/patches/0003-t2gmux-error-recording.patch",
]
SMC_PATCHES = [
    ROOT / "assets/kernel/t2smc/patches/0001-t2smc-range-checks.patch",
    ROOT / "assets/kernel/t2smc/patches/0003-t2smc-cache-init.patch",
    ROOT / "assets/kernel/t2smc/patches/0005-t2smc-telemetry-robust.patch",
]


def _apply_sequence(workdir: pathlib.Path, src: pathlib.Path,
                    patches: list[pathlib.Path]) -> None:
    shutil.copy(src, workdir / src.name)
    for patch in patches:
        assert patch.is_file(), f"missing patch file: {patch}"
        proc = subprocess.run(
            ["patch", "-p1", "--fuzz=0", "--dry-run",
             "-i", str(patch)],
            cwd=workdir, capture_output=True, text=True,
        )
        assert proc.returncode == 0, (
            f"{patch.name} does not apply cleanly:\n{proc.stdout}\n{proc.stderr}"
        )
        real = subprocess.run(
            ["patch", "-p1", "--fuzz=0", "-i", str(patch)],
            cwd=workdir, capture_output=True, text=True,
        )
        assert real.returncode == 0, (
            f"{patch.name} failed to apply:\n{real.stdout}\n{real.stderr}"
        )


def _patched_text(src: pathlib.Path, patches: list[pathlib.Path]) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        workdir = pathlib.Path(tmp)
        _apply_sequence(workdir, src, patches)
        return (workdir / src.name).read_text()


def test_t2gmux_patches_apply_sequentially():
    with tempfile.TemporaryDirectory() as tmp:
        _apply_sequence(pathlib.Path(tmp), GMUX_SRC, GMUX_PATCHES)


def test_t2smc_patches_apply_sequentially():
    with tempfile.TemporaryDirectory() as tmp:
        _apply_sequence(pathlib.Path(tmp), SMC_SRC, SMC_PATCHES)


def test_t2gmux_hardening_semantics_survive_rebase():
    text = _patched_text(GMUX_SRC, GMUX_PATCHES)

    # 0001: the acknowledge loop must be bounded, not `while (status)`.
    assert "while (status && drains++ < 32)" in text, (
        "bounded drain loop is missing: a stuck interrupt would hold "
        "power_lock forever"
    )
    assert "while (status) {" not in text, "unbounded acknowledge loop is back"

    # 0002: a quiescing flag set before gmux_stop_interrupts().
    assert "bool quiescing;" in text, "quiescing flag missing from the device"
    assert "if (gmux_data->quiescing)" in text, (
        "interrupt worker does not check the quiescing flag"
    )
    assert text.count("gmux_data->quiescing = true;") >= 2, (
        "suspend and shutdown must both set quiescing"
    )
    for hook in ("gmux_suspend", "gmux_shutdown"):
        assert f"{hook}(struct" in text, f"{hook} is missing"
        body = text.split(f"{hook}(struct", 1)[1].split("\n}", 1)[0]
        assert "quiescing = true;" in body, f"{hook} does not set quiescing"
        assert body.index("quiescing = true;") < body.index(
            "\n\tgmux_stop_interrupts(gmux_data);"
        ), f"{hook} sets quiescing after quiescing interrupts"

    # 0003: error recording from the MMIO accessors through the power path.
    assert "int last_mmio_error;" in text, "last_mmio_error field missing"
    assert "last_mmio_error = -EBUSY;" in text, "busy error is not recorded"
    assert "last_mmio_error = -ETIMEDOUT;" in text, "timeout is not recorded"
    assert "ret = gmux_data->last_mmio_error;" in text, (
        "the power path does not report a recorded mailbox failure"
    )


def test_t2smc_hardening_semantics_survive_rebase():
    with tempfile.TemporaryDirectory() as tmp:
        workdir = pathlib.Path(tmp)
        _apply_sequence(workdir, SMC_SRC, SMC_PATCHES)
        text = (workdir / SMC_SRC.name).read_text()
        header = (workdir / "t2smc_range.h").read_text()

    # 0001: the range validator is included and actually consulted.
    assert '#include "t2smc_range.h"' in text, "range header not included"
    assert "t2smc_fan_write_check(" in text, "fan writes are not validated"
    assert "t2smc_fan_envelope(t2, channel" in text, (
        "fan writes do not validate against the factory envelope"
    )
    assert "t2smc_rtc_offset_valid(" in text, "CLKO writes are not range-checked"
    assert "channel < 0 ||" in text, "negative hwmon channels are not rejected"
    assert text.count("t2smc_capture_fan_envelope(struct t2smc_device *t2)\n{") == 1, (
        "fan envelope capture must be defined exactly once"
    )

    # The header must carry the validator bodies, not just declarations,
    # and no helper whose caller was dropped with its patch.
    for symbol in ("t2smc_fan_speed_valid", "t2smc_fan_write_check",
                   "t2smc_rtc_offset_valid", "t2smc_rtc_offset_wrap"):
        assert symbol in header, f"{symbol} missing from t2smc_range.h"
    for dead in ("t2smc_charge_limit_valid", "t2smc_temp_alloc_count"):
        assert dead not in header, f"{dead} is dead code once its patch is gone"

    # Fan target 0 hands the fan back to the SMC (upstream 513a82d) and must
    # NOT be range-checked: the validator would reject it as below the floor.
    target = text.split("case hwmon_fan_target:", 2)[2].split("default:", 1)[0]
    assert target.index("if (!val)") < target.index("t2smc_fan_write_check("), (
        "fan target 0 (hand back to SMC) must be handled before range checks"
    )
    assert target.index("t2smc_fan_write_check(") < target.index(
        "t2smc_write_fan_manual(t2, channel, 1)"
    ), "a rejected target must not leave the fan pinned in manual mode"

    # 0003: cache lookup return value initialised.
    entry = text.split("t2smc_get_entry_by_index(struct", 1)[1].split("\n}", 1)[0]
    assert "int ret = 0;" in entry, "t2smc_get_entry_by_index ret not initialised"

    # 0005: telemetry reads propagate errors instead of emitting values.
    assert "if (ret)\n\t\t\treturn ret;" in text, (
        "telemetry reads no longer check the read status"
    )
    power = text.split("static ssize_t t2smc_power_show(", 1)[1].split(
        "\n}", 1
    )[0]
    neg = power.index("val = -val;")
    assert "if (ret)\n\t\t\treturn ret;" in power[:neg].rsplit("case ", 1)[1], (
        "battery power must return on a read error before negating val"
    )
    assert "(magnitude >> (64 - exponent)) != 0" in text, (
        "float telemetry shift is no longer saturated before overflowing u64"
    )


def test_t2smc_upstream_contains_the_dropped_0002_and_0004_fixes():
    """The vendored pristine source must itself hold what 0002/0004 fixed."""
    text = SMC_SRC.read_text()

    # 0002 (temperature discovery): single pass, allocate the whole candidate
    # range, publish the populated count.  No two-pass sizing by success count.
    disc = text.split("static int t2smc_discover_sensors(", 1)[1].split("\n}", 1)[0]
    assert "kcalloc(end - begin, sizeof(set->keys[0])" in disc, (
        "sensor array is not sized for the full candidate range"
    )
    assert "set->count = n;" in disc, "populated count is not published"
    assert "t2->temp_count" not in text, "old two-pass temp_count logic is back"

    # 0004 (charge limit): CHLS only, validated before the write, one lock
    # around the set/get transaction, no CHWA/BCLM write path.
    assert "CHWA" not in text, "a CHWA write path appeared upstream: review it"
    setter = text.split("static int t2smc_set_charge_limit(", 1)[1].split(
        "\n}", 1
    )[0]
    assert setter.index("val < 1 || val > 100") < setter.index(
        "t2smc_write_chls("
    ), "charge limit must be validated before the first write"
    assert "mutex_lock(&t2->charge_lock);" in setter, "setter lost its lock"
    shown = text.split("static ssize_t charge_limit_show(", 1)[1].split(
        "\n}", 1
    )[0]
    assert "mutex_lock(&t2->charge_lock);" in shown, "getter lost its lock"
    writer = text.split("static int t2smc_write_chls(", 1)[1].split("\n}", 1)[0]
    assert "lockdep_assert_held(&t2->charge_lock);" in writer
