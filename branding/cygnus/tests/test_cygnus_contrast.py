#!/usr/bin/env python3
"""Contrast gate for the Cygnus color system (branding/cygnus/tokens.json).

Runs with plain python3 (no pytest needed) or under pytest.
Fails if any declared pair drops below its WCAG 2.x minimum, if the
console palettes break readability, if the newt palette paints text on
an unreadable background, or if a generated file is stale.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
ROOT = HERE.parents[1]  # branding/cygnus
TOKENS = ROOT / "tokens.json"

NEWT_SLOTS = {
    "black": 0,
    "red": 1,
    "green": 2,
    "brown": 3,
    "blue": 4,
    "magenta": 5,
    "cyan": 6,
    "lightgray": 7,
    "gray": 8,
    "brightred": 9,
    "brightgreen": 10,
    "yellow": 11,
    "brightblue": 12,
    "brightmagenta": 13,
    "brightcyan": 14,
    "white": 15,
}


def _lin(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hex_color: str) -> float:
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i : i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b)


def contrast(a: str, b: str) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def load() -> dict:
    return json.loads(TOKENS.read_text())


def check_modes(t: dict) -> list[str]:
    errs = []
    for mode, roles in t["modes"].items():
        for fg, bg, minimum in t["contrast"]["mode-pairs"]:
            ratio = contrast(roles[fg], roles[bg])
            if ratio + 1e-9 < minimum:
                errs.append(
                    f"{mode}: {fg} {roles[fg]} on {bg} {roles[bg]} = {ratio:.2f} < {minimum}"
                )
    return errs


def check_console(t: dict) -> list[str]:
    errs = []
    tty = t["console"]["tty"]
    # Installed system: every non-black foreground readable on the black slot.
    # Slot 8 (bright black) is the conventional dim color: UI minimum only.
    for i in range(1, 16):
        minimum = 3.0 if i == 8 else 4.5
        r = contrast(tty[i], tty[0])
        if r + 1e-9 < minimum:
            errs.append(
                f"console.tty slot {i} {tty[i]} on slot 0 = {r:.2f} < {minimum}"
            )
    inst = t["console"]["installer"]
    for i in (1, 2, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15):
        r = contrast(inst[i], inst[0])
        if r + 1e-9 < 3.0:
            errs.append(
                f"console.installer slot {i} {inst[i]} on slot 0 = {r:.2f} < 3.0"
            )
    for name in ("tty", "installer"):
        if len(t["console"][name]) != 16:
            errs.append(f"console.{name} must have 16 entries")
    return errs


def check_newt(t: dict) -> list[str]:
    errs = []
    inst = t["console"]["installer"]
    for elem, (fg, bg) in t["newt"]["palette"].items():
        if NEWT_SLOTS[bg] > 7:
            errs.append(
                f"newt {elem}: background {bg} is a bright slot (VT backgrounds are 0-7)"
            )
            continue
        if elem in ("shadow",):
            continue
        minimum = (
            3.0 if elem in ("border", "disentry", "emptyscale", "fullscale") else 4.5
        )
        r = contrast(inst[NEWT_SLOTS[fg]], inst[NEWT_SLOTS[bg]])
        if r + 1e-9 < minimum:
            errs.append(f"newt {elem}: {fg} on {bg} = {r:.2f} < {minimum}")
    return errs


def _resolve(t: dict, ref: str) -> str:
    if ref.startswith("#"):
        return ref
    if "." in ref:
        mode, role = ref.split(".", 1)
        return t["modes"][mode][role]
    return t["singularity"][ref]


def check_singularity(t: dict) -> list[str]:
    """The one accent hex Singularity paints with white text on top."""
    errs = []
    for fg, bg, minimum in t["contrast"]["singularity-pairs"]:
        a, b = _resolve(t, fg), _resolve(t, bg)
        r = contrast(a, b)
        if r + 1e-9 < minimum:
            errs.append(f"singularity: {fg} {a} on {bg} {b} = {r:.2f} < {minimum}")
    return errs


def check_generated_fresh() -> list[str]:
    gen = ROOT / "tools" / "gen-cygnus.py"
    if not gen.exists():
        return []
    p = subprocess.run(
        [sys.executable, str(gen), "--check"],
        capture_output=True,
        text=True,
        check=False,
    )
    if p.returncode != 0:
        return [
            "generated files are stale: run branding/cygnus/tools/gen-cygnus.py\n"
            + p.stdout
            + p.stderr
        ]
    return []


def test_mode_contrast():
    assert not check_modes(load()), check_modes(load())


def test_console_contrast():
    assert not check_console(load()), check_console(load())


def test_newt_contrast():
    assert not check_newt(load()), check_newt(load())


def test_singularity_accent():
    assert not check_singularity(load()), check_singularity(load())


def test_generated_fresh():
    assert not check_generated_fresh(), check_generated_fresh()


def main() -> int:
    t = load()
    errs = (
        check_modes(t)
        + check_console(t)
        + check_newt(t)
        + check_singularity(t)
        + check_generated_fresh()
    )
    for mode, roles in t["modes"].items():
        for fg, bg, _ in t["contrast"]["mode-pairs"]:
            print(
                f"{mode:5} {fg:>15} on {bg:<12} {contrast(roles[fg], roles[bg]):5.2f}"
            )
    if errs:
        print("\nFAIL", *errs, sep="\n  ")
        return 1
    print("\nOK: all Cygnus contrast gates pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
