"""Static gate over post-install hooks (FB152). Read-only; never executes.

Three per-script properties over ``post-install/*.sh``:
1. ``bash -n`` parses cleanly.
2. Strict mode (``set -e``) or a ``strict`` exemption in the allowlist.
3. Writers (reference ``/etc/`` or ``/usr/``) show an idempotence guard or
   carry an ``idempotence`` exemption.

``55*`` hooks are scanned and reported but never fail the suite
(report-only per the brief). The planted-script tests prove the gate fires.
Only the standard library plus pytest are used.
"""

from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess

import pytest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[0]
DEFAULT_SCAN = ROOT / "post-install"
ALLOWLIST_PATH = HERE / "postinstall_gate_allowlist.json"

REPORT_ONLY_PREFIXES = ("55-",)
VALID_PROPERTIES = ("strict", "idempotence")

STRICT_RE = re.compile(r"^[ \t]*set[ \t]+-[a-z]*e", re.MULTILINE)
WRITE_RE = re.compile(r"/etc/|/usr/")
# Deliberately tight: bare words like marker/stamp also match comment prose
# ("timestamp"), and bare is-enabled/is-active match strings anywhere. Every
# guarded hook in the corpus matches at least one of the tokens below, so a
# future hook relying only on prose must say so in the allowlist instead.
GUARD_PATTERNS = (
    r"\[ -[fe] ",
    r"grep -q",
    r"install -m",
    r"mkdir -p",
    r"\|\| true",
    r"command -v",
    r"systemctl is-enabled",
    r"systemctl is-active",
    r"cmp -s",
)
GUARD_RES = [re.compile(p) for p in GUARD_PATTERNS]


def load_allowlist() -> dict[str, dict[str, str]]:
    doc = json.loads(ALLOWLIST_PATH.read_text())
    return doc["exemptions"]


def live_scripts(scan_dir: pathlib.Path) -> list[pathlib.Path]:
    return sorted(scan_dir.glob("*.sh"))


def is_report_only(path: pathlib.Path) -> bool:
    return path.name.startswith(REPORT_ONLY_PREFIXES)


def check_script(path: pathlib.Path) -> dict:
    src = path.read_text(errors="replace")
    bash = shutil.which("bash")
    if bash is None:
        syntax: bool | None = None
    else:
        proc = subprocess.run(
            [bash, "-n", str(path)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        syntax = proc.returncode == 0
    return {
        "name": path.name,
        "syntax_ok": syntax,
        "strict": bool(STRICT_RE.search(src)),
        "writer": bool(WRITE_RE.search(src)),
        "guarded": any(r.search(src) for r in GUARD_RES),
        "report_only": is_report_only(path),
    }


def scan(scan_dir: pathlib.Path = DEFAULT_SCAN) -> list[dict]:
    return [check_script(p) for p in live_scripts(scan_dir)]


def test_all_scripts_pass_bash_n():
    if shutil.which("bash") is None:
        pytest.skip("bash is not on PATH, so `bash -n` cannot run here")
    failures = [c["name"] for c in scan() if c["syntax_ok"] is not True]
    assert not failures, f"syntax failures: {failures}"


def test_strict_mode_or_allowlisted():
    allow = load_allowlist()
    bad = [
        c["name"]
        for c in scan()
        if not c["report_only"]
        and not c["strict"]
        and "strict" not in allow.get(c["name"], {})
    ]
    assert not bad, f"missing set -e with no allowlist entry: {bad}"


def test_writers_have_idempotence_guard_or_allowlisted():
    allow = load_allowlist()
    bad = [
        c["name"]
        for c in scan()
        if not c["report_only"]
        and c["writer"]
        and not c["guarded"]
        and "idempotence" not in allow.get(c["name"], {})
    ]
    assert not bad, f"writers without a guard or exemption: {bad}"


def test_allowlist_is_exact():
    allow = load_allowlist()
    live = {p.name for p in live_scripts(DEFAULT_SCAN)}
    current = {c["name"]: c for c in scan()}
    for name, props in allow.items():
        assert name in live, f"orphan allowlist entry: {name}"
        assert not name.startswith(REPORT_ONLY_PREFIXES), (
            f"report-only hooks are never allowlisted: {name}"
        )
        assert set(props) <= set(VALID_PROPERTIES), f"bad property in {name}: {props}"
        for prop, reason in props.items():
            assert reason.strip(), f"empty reason for {name}:{prop}"
            check = current[name]
            if prop == "strict":
                assert not check["strict"], (
                    f"{name} now declares set -e; drop its allowlist entry"
                )
            else:
                assert check["writer"] and not check["guarded"], (
                    f"{name} no longer needs an idempotence exemption"
                )


def test_excluded_paths_are_report_only():
    names = [c["name"] for c in scan()]
    fifties = [n for n in names if n.startswith(REPORT_ONLY_PREFIXES)]
    assert fifties, "expected the 55* hooks to be scanned"
    allow = load_allowlist()
    assert not any(n in allow for n in fifties)


def _write_planted(tmp: pathlib.Path) -> None:
    (tmp / "bad-syntax.sh").write_text("#!/bin/bash\nif then\n")
    (tmp / "no-strict.sh").write_text("#!/bin/bash\necho hi\n")
    (tmp / "unguarded-write.sh").write_text(
        "#!/bin/bash\nset -e\necho planted > /etc/fb152-planted\n"
    )


def test_gate_fires_on_planted_bad_script(tmp_path: pathlib.Path):
    if shutil.which("bash") is None:
        pytest.skip("bash is not on PATH, so `bash -n` cannot run here")
    _write_planted(tmp_path)
    results = {c["name"]: c for c in scan(tmp_path)}
    assert results["bad-syntax.sh"]["syntax_ok"] is False
    assert results["no-strict.sh"]["strict"] is False
    unguarded = results["unguarded-write.sh"]
    assert unguarded["writer"] is True and unguarded["guarded"] is False
