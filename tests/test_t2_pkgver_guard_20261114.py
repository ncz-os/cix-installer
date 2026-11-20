"""PACKAGE_VERSION <-> content-identity guard for the vendored T2 DKMS modules.

Why: on 2026-11-14 a test machine re-shipped a stale, defective t2smc build after a
re-vendor because both the old and the new tree claimed PACKAGE_VERSION 0.1 --
the version did not change when the vendored content did, so a stale dkms cache
happily re-used the previous module.  Upstream does not bump PACKAGE_VERSION on
content change; we deliberately diverge.

Rule (also stated in assets/kernel/{t2smc,t2gmux}/dkms.conf and PROVENANCE):
any change to src/** or patches/*.patch MUST bump PACKAGE_VERSION (monotonic)
and record the new content identity in the PROVENANCE "Content-Identity Ledger".

This guard enforces, for each of assets/kernel/{t2smc,t2gmux}:
1. The PROVENANCE ledger parses and is a bijection: every PACKAGE_VERSION maps
   to exactly one content digest and every digest to exactly one version.
2. The CURRENT content digest (sha256 over sorted "relpath <file-sha256>\\n"
   lines for src/** and patches/*.patch) equals the ledger entry for the
   PACKAGE_VERSION currently declared in dkms.conf -- so a content change
   without a PACKAGE_VERSION bump fails here, as does a version bump without
   a ledger entry.
3. Every place that repeats the version agrees with dkms.conf:
   manifests/components.tsv (version column), and for t2gmux the vendored
   MODULE_VERSION (already covered by test_t2_dkms_conf_20261114.py, kept
   here as a cheap cross-check).

Both-ways proof (run against real trees):
- pre-bump tree (dkms.conf PACKAGE_VERSION 0.1, content = the 8c7f725
  re-vendor): FAIL -- the current digest is registered under 0.2, not 0.1.
- this tree (0.2 with ledger entry): PASS.
- tamper (flip one byte of src/t2smc.c): FAIL -- digest matches no ledger
  entry for 0.2.
"""

from __future__ import annotations

import hashlib
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULES = {
    "t2smc": ROOT / "assets/kernel/t2smc",
    "t2gmux": ROOT / "assets/kernel/t2gmux",
}

LEDGER_RE = re.compile(
    r"^\s*PACKAGE_VERSION\s+(\S+)\s+([0-9a-f]{64})\b", re.MULTILINE
)
PKGVER_RE = re.compile(r'^PACKAGE_VERSION="([^"]+)"', re.MULTILINE)


def content_digest(moddir: pathlib.Path) -> str:
    """sha256 over sorted 'relpath <file-sha256>\\n' lines for the DKMS inputs."""
    files = [p for p in (moddir / "src").rglob("*") if p.is_file()]
    files += [p for p in (moddir / "patches").glob("*.patch")]
    assert files, f"{moddir}: no src/** or patches/*.patch content to hash"
    h = hashlib.sha256()
    for p in sorted(files, key=lambda p: p.relative_to(moddir).as_posix()):
        rel = p.relative_to(moddir).as_posix()
        fh = hashlib.sha256(p.read_bytes()).hexdigest()
        h.update(f"{rel} {fh}\n".encode())
    return h.hexdigest()


def parse_ledger(moddir: pathlib.Path) -> dict[str, str]:
    text = (moddir / "PROVENANCE").read_text()
    entries = {m.group(1): m.group(2) for m in LEDGER_RE.finditer(text)}
    assert entries, f"{moddir.name}: no Content-Identity Ledger entries in PROVENANCE"
    return entries


def declared_pkgver(moddir: pathlib.Path) -> str:
    m = PKGVER_RE.search((moddir / "dkms.conf").read_text())
    assert m is not None, f"{moddir.name}: PACKAGE_VERSION missing from dkms.conf"
    return m.group(1)


def _tsv_versions() -> dict[str, str]:
    out: dict[str, str] = {}
    for line in (ROOT / "manifests/components.tsv").read_text().splitlines():
        f = line.split("\t")
        if len(f) > 6 and f[0] in MODULES and f[1] == "dkms":
            out[f[0]] = f[6]
    return out


def test_ledger_is_a_bijection():
    for name, moddir in MODULES.items():
        entries = parse_ledger(moddir)
        digests = list(entries.values())
        assert len(digests) == len(set(digests)), (
            f"{name}: two PACKAGE_VERSIONs map to the same content digest "
            f"in the PROVENANCE ledger: {entries}"
        )
        # parse_ledger collapses duplicate keys (dict comprehension), so detect
        # duplicates on the raw matches: raw count must equal dict length.
        raw = LEDGER_RE.findall((moddir / "PROVENANCE").read_text())
        assert len(raw) == len(entries), (
            f"{name}: duplicate PACKAGE_VERSION keys in the PROVENANCE ledger "
            f"({len(raw)} entries listed, {len(entries)} distinct): {raw}"
        )


def test_current_content_matches_the_pkgver_declared_in_dkms_conf():
    for name, moddir in MODULES.items():
        entries = parse_ledger(moddir)
        ver = declared_pkgver(moddir)
        assert ver in entries, (
            f"{name}: dkms.conf PACKAGE_VERSION {ver!r} has no entry in the "
            f"PROVENANCE Content-Identity Ledger (have {sorted(entries)}); "
            f"a content change without a version bump (or vice versa) is exactly "
            f"what this guard rejects"
        )
        current = content_digest(moddir)
        assert current == entries[ver], (
            f"{name}: vendored content digest {current} does not match the "
            f"ledger entry for PACKAGE_VERSION {ver!r} ({entries[ver]}); "
            f"src/** or patches/*.patch changed without bumping PACKAGE_VERSION "
            f"and updating the ledger"
        )


def test_pkgver_references_agree_everywhere():
    tsv = _tsv_versions()
    assert set(tsv) == set(MODULES), (
        f"components.tsv dkms rows found for {sorted(tsv)}, expected {sorted(MODULES)}"
    )
    for name, moddir in MODULES.items():
        ver = declared_pkgver(moddir)
        assert tsv[name] == ver, (
            f"{name}: manifests/components.tsv says {tsv[name]!r} but dkms.conf "
            f"says {ver!r}"
        )
    # t2gmux also carries MODULE_VERSION in the vendored source; it must agree.
    src = (MODULES["t2gmux"] / "src/t2gmux.c").read_text()
    mv = re.search(r'^MODULE_VERSION\("([^"]+)"\);', src, re.MULTILINE)
    assert mv is not None, "MODULE_VERSION missing from vendored t2gmux.c"
    assert mv.group(1) == declared_pkgver(MODULES["t2gmux"]), (
        f"t2gmux MODULE_VERSION {mv.group(1)!r} does not match dkms.conf "
        f"PACKAGE_VERSION {declared_pkgver(MODULES['t2gmux'])!r}"
    )
