"""The NPU SSDT stager gives the same medium from a fresh clone and a copy.

Measured 2026-11-07 (arm64, ULTRA): an image assembled from a FRESH clone of
one commit failed the shipped-secret scan with "npu-acpi-override.cpio: cpio
entry with an empty name at 0". In a fresh clone the tracked .asl is newer
than any copied .aml, so ensure_npu_ssdt_aml() recompiled and rewrote the
early CPIO with its own newc writer, which left out c_ino (12 header fields,
not 13) and wrote a trailer with namesize 0: every reader rejects it. A copied
tree (older .asl mtime) reused its CPIO from build/build-npu-ssdt.sh, so the
two media differed and the fresh-clone one could not ship.

Run: python3 -m pytest build/iso/tests/test_ncz_ssdt_reproducible.py -q
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
STAGER = REPO_ROOT / "build" / "iso" / "ncz_ssdt.py"


@pytest.fixture(scope="module")
def ssdt():
    spec = importlib.util.spec_from_file_location("ncz_ssdt", STAGER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _aml(n: int = 0) -> bytes:
    body = b"CIXH4010" * 3 + bytes([n]) * 16
    length = 36 + len(body)
    return b"SSDT" + length.to_bytes(4, "little") + b"\0" * 28 + body


def _parse_newc(data: bytes) -> list[tuple[str, int, int, bytes]]:
    """(name, mode, nlink, data) per entry; strict 13-field newc."""
    out, off = [], 0
    while True:
        hdr = data[off:off + 110]
        assert hdr[:6] == b"070701", f"bad magic at {off}"
        f = [int(hdr[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        namesize, filesize = f[11], f[6]
        assert namesize > 1, f"empty name at {off}"
        name = data[off + 110:off + 110 + namesize - 1].decode()
        off += 110 + namesize
        off += (-off) % 4
        body = data[off:off + filesize]
        off += filesize
        off += (-off) % 4
        if name == "TRAILER!!!":
            assert not data[off:].strip(b"\0"), "data after the trailer"
            return out
        out.append((name, f[1], f[4], body))


def _repo(tmp: Path, aml: bytes | None = None) -> Path:
    npu = tmp / "assets" / "npu"
    npu.mkdir(parents=True)
    (npu / "ssdt-npucre.asl").write_text("DefinitionBlock () {}\n")
    if aml is not None:
        (npu / "ssdt-npucre.aml").write_bytes(aml)
    return tmp


def test_early_cpio_is_valid_newc(ssdt, tmp_path):
    repo = _repo(tmp_path, _aml())
    npu = repo / "assets" / "npu"
    ssdt._write_early_cpio(npu / "ssdt-npucre.aml", npu / "x.cpio", lambda s: None)
    entries = _parse_newc((npu / "x.cpio").read_bytes())
    assert [e[0] for e in entries] == [
        "kernel", "kernel/firmware", "kernel/firmware/acpi",
        "kernel/firmware/acpi/ssdt-npucre.aml",
    ]
    assert entries[-1][3] == _aml()


@pytest.mark.skipif(not shutil.which("cpio"), reason="cpio not available")
def test_early_cpio_matches_build_npu_ssdt(ssdt, tmp_path):
    """Byte-identical to build/build-npu-ssdt.sh's GNU cpio archive, so the
    medium does not depend on which of the two produced it."""
    repo = _repo(tmp_path, _aml(7))
    npu = repo / "assets" / "npu"
    ssdt._write_early_cpio(npu / "ssdt-npucre.aml", npu / "py.cpio", lambda s: None)
    root = tmp_path / "root"
    (root / "kernel" / "firmware" / "acpi").mkdir(parents=True)
    shutil.copyfile(npu / "ssdt-npucre.aml",
                    root / "kernel" / "firmware" / "acpi" / "ssdt-npucre.aml")
    subprocess.run(["find", str(root), "-exec", "touch", "-h", "-d", "@0", "{}", "+"],
                   check=True)
    os.chmod(root / "kernel" / "firmware" / "acpi" / "ssdt-npucre.aml", 0o644)
    for d in ("kernel", "kernel/firmware", "kernel/firmware/acpi"):
        os.chmod(root / d, 0o755)
    names = b"\0".join(sorted([b"kernel", b"kernel/firmware", b"kernel/firmware/acpi",
                               b"kernel/firmware/acpi/ssdt-npucre.aml"])) + b"\0"
    gnu = subprocess.run(
        ["cpio", "--null", "-o", "-H", "newc", "--owner=0:0", "--reproducible", "--quiet"],
        input=names, cwd=root, capture_output=True, check=True,
    ).stdout
    assert (npu / "py.cpio").read_bytes() == gnu


def _no_compile(*a, **k):
    raise AssertionError("recompiled although the table matches its source")


def test_reuse_does_not_depend_on_mtimes(ssdt, tmp_path, monkeypatch):
    """A fresh checkout (.asl newer than the .aml) and a copied tree (.asl
    older) make the same decision: the .aml is reused when it was built from
    this exact .asl, whatever the file times."""
    repo = _repo(tmp_path, _aml())
    npu = repo / "assets" / "npu"
    calls = []
    monkeypatch.setattr(ssdt, "_compile",
                        lambda asl, aml, r, log: (calls.append(1), aml.write_bytes(_aml()),
                                                  ssdt._stamp_source(asl, aml)))
    ssdt.ensure_npu_ssdt_aml(repo, "arm64", log=lambda s: None)  # no stamp yet
    assert calls == [1]
    first = (npu / "npu-acpi-override.cpio").read_bytes()
    monkeypatch.setattr(ssdt, "_compile", _no_compile)
    for asl_t, aml_t in ((2000, 1000), (1000, 2000)):
        os.utime(npu / "ssdt-npucre.asl", (asl_t, asl_t))
        os.utime(npu / "ssdt-npucre.aml", (aml_t, aml_t))
        os.utime(npu / "npu-acpi-override.cpio", (500, 500))
        ssdt.ensure_npu_ssdt_aml(repo, "arm64", log=lambda s: None)
        assert (npu / "npu-acpi-override.cpio").read_bytes() == first


def test_changed_source_recompiles(ssdt, tmp_path, monkeypatch):
    repo = _repo(tmp_path, _aml())
    npu = repo / "assets" / "npu"
    ssdt._stamp_source(npu / "ssdt-npucre.asl", npu / "ssdt-npucre.aml")
    (npu / "ssdt-npucre.asl").write_text("DefinitionBlock () { changed }\n")
    os.utime(npu / "ssdt-npucre.asl", (1, 1))  # older than the .aml
    calls = []
    monkeypatch.setattr(ssdt, "_compile",
                        lambda asl, aml, r, log: (calls.append(1), aml.write_bytes(_aml(1)),
                                                  ssdt._stamp_source(asl, aml)))
    ssdt.ensure_npu_ssdt_aml(repo, "arm64", log=lambda s: None)
    assert calls == [1]


def test_wrong_cpio_is_rewritten_even_when_newer(ssdt, tmp_path, monkeypatch):
    repo = _repo(tmp_path, _aml())
    npu = repo / "assets" / "npu"
    ssdt._stamp_source(npu / "ssdt-npucre.asl", npu / "ssdt-npucre.aml")
    bad = npu / "npu-acpi-override.cpio"
    bad.write_bytes(b"070701" + b"0" * 200)
    os.utime(bad, (4_000_000_000, 4_000_000_000))
    monkeypatch.setattr(ssdt, "_compile", _no_compile)
    ssdt.ensure_npu_ssdt_aml(repo, "arm64", log=lambda s: None)
    entries = _parse_newc(bad.read_bytes())
    assert entries[-1][3] == _aml()
