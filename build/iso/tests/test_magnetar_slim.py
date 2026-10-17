#!/usr/bin/env python3
"""Tests for the Magnetar slim layout (fix/p3-magnetar-slim-20261017).

Three units are covered, each with the property that made it worth writing
rather than asserting:

  * build/lib/magnetar_substrate.py -- the keep-set is derived from a MEASURED
    initrd package list and the real pool's Depends:, never from a guess. The
    tests build a fake pool + fake initrd status, then assert the invariants:
    a dependency closure that is entirely resolvable from what is kept or what
    the initrd already has, the NIC/ssh/netcfg udebs always kept, a stale keep
    manifest rejected, and the specific regression that an early revision of
    this module introduced and a measurement caught (nic-modules must NOT be
    droppable).
  * write-usb-image.py --compress -- real xz and zstd runs over a real file,
    with the receipt fields checked, and a missing compressor reported as a
    hard failure instead of a fabricated size.
  * build-refind-esp.py --size-mib 0 -- the ESP is sized to its content and
    never below the floor _required_esp_mib() computes.

Run: python3 -m pytest build/iso/tests/test_magnetar_slim.py -q
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SUBSTRATE_MOD = REPO_ROOT / "build" / "lib" / "magnetar_substrate.py"
WRITER = REPO_ROOT / "build" / "iso" / "write-usb-image.py"
ESP_BUILDER = REPO_ROOT / "build" / "iso" / "build-refind-esp.py"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader, f"cannot load {path}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def substrate():
    return _load(SUBSTRATE_MOD, "magnetar_substrate")


@pytest.fixture(scope="module")
def writer():
    return _load(WRITER, "write_usb_image")


# ---------------------------------------------------------------------------
# building a pool without dpkg: a udeb is a tar-or-ar file; the module only
# ever asks `dpkg-deb -f <file> Depends`, so a stub on PATH is enough and the
# test stays hermetic (no Debian host required).
# ---------------------------------------------------------------------------
@pytest.fixture()
def fake_dpkg(tmp_path, monkeypatch):
    """`dpkg-deb -f <file> Depends` reads <file>.depends beside the file."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    stub = bindir / "dpkg-deb"
    stub.write_text(
        "#!/bin/sh\n"
        "# $1=-f $2=file $3=field\n"
        "[ \"$1\" = -f ] || exit 1\n"
        "case \"$3\" in\n"
        "  Depends)\n"
        "    f=\"$2.depends\"\n"
        "    [ -f \"$f\" ] || exit 0\n"
        "    cat \"$f\"\n"
        "    ;;\n"
        "  Package)\n"
        "    # <file>.package overrides; otherwise the basename before _\n"
        "    if [ -f \"$2.package\" ]; then\n"
        "      cat \"$2.package\"\n"
        "      exit 0\n"
        "    fi\n"
        "    b=$(basename \"$2\")\n"
        "    printf '%s\\n' \"${b%%_*}\"\n"
        "    ;;\n"
        "  *)\n"
        "    exit 0\n"
        "    ;;\n"
        "esac\n"
    )
    stub.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    return None


def make_pool(root: Path, packages: dict[str, tuple[int, str]]) -> None:
    """packages: name -> (size, Depends-field)."""
    for name, (size, depends) in packages.items():
        path = root / "main" / name[0] / f"{name}_{size}.udeb"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        if depends:
            (path.parent / f"{path.name}.depends").write_text(depends + "\n")


def write_status(path: Path, names: list[str]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"Package: {n}\nStatus: install ok installed\n\n"
                            for n in names))
    return path


# ---------------------------------------------------------------------------
# magnetar_substrate
# ---------------------------------------------------------------------------
POOL = {
    # already in the initrd -> keep (anna never fetches it)
    "libc6-udeb": (4000, ""),
    "partman-base": (9000, "libc6-udeb"),
    # runtime-required by the install path, NOT in the initrd
    "netcfg": (5000, "libc6-udeb, libiw30-udeb, ethernet-card-detection"),
    "net-retriever": (3000, "netcfg"),
    "netcfg-static": (2000, "netcfg"),
    # NIC drivers installed by preseed/early_command by path
    "nic-modules-7.2.9-amd64-di": (1000, ""),
    # diagnostics stack, kept by the manifest
    "openssh-server-udeb": (800, "openssh-client-udeb"),
    "openssh-client-udeb": (700, "libc6-udeb"),
    # pure dead weight
    "espeakup-udeb": (600, ""),
    "partman-crypto": (500, ""),
    "save-logs": (400, ""),
    "xfs-modules-7.2.9-amd64-di": (300, ""),
    "btrfs-modules-7.2.9-amd64-di": (250, ""),
    # dependency of a kept package, absent from the initrd
    "libiw30-udeb": (100, "libc6-udeb"),
}
INITRD = ["libc6-udeb", "partman-base"]


def test_keep_set_is_a_real_dependency_closure(substrate, tmp_path, fake_dpkg):
    pool_root = tmp_path / "pool"
    make_pool(pool_root, POOL)
    status = write_status(tmp_path / "status", INITRD)
    builtin = substrate.measure_substrate_initrd(status)
    pool = substrate.Pool(pool_root)
    keep_tsv = tmp_path / "keep.tsv"
    keep_tsv.write_text("openssh-server-udeb\tdiag-console installs it by path\n"
                        "openssh-client-udeb\tdiag-console installs it by path\n")
    extra, extra_reasons = substrate.load_keep_tsv(keep_tsv)
    kept, reasons = substrate.keep_set(pool, "amd64", "amd64", builtin,
                                       extra, extra_reasons)

    assert "libc6-udeb" in kept, "an initrd builtin is kept (it is already installed)"
    assert "netcfg" in kept and "net-retriever" in kept
    assert "nic-modules-7.2.9-amd64-di" in kept, \
        "the ONLY source of NIC drivers before the network exists"
    assert "openssh-server-udeb" in kept and "openssh-client-udeb" in kept
    assert "libiw30-udeb" in kept, "a dependency absent from the initrd must be staged"
    for dead in ("espeakup-udeb", "partman-crypto", "save-logs",
                 "xfs-modules-7.2.9-amd64-di", "btrfs-modules-7.2.9-amd64-di"):
        assert dead not in kept, f"{dead} is unreachable from the preseed path"

    # Invariant that makes the shrink safe: every Depends: alternative of every
    # kept udeb resolves to something kept, something already in the initrd, or
    # a virtual package no udeb provides.
    deps = substrate.read_depends(pool)
    for pkg in kept:
        for token in deps.get(pkg, ()):
            name = substrate.package_name_of(token)
            if not name or name in kept or name in builtin:
                continue
            if name not in pool:
                continue  # virtual (ethernet-card-detection, ...)
            raise AssertionError(
                f"{pkg} depends on {name}, which is dropped and not in the initrd")
    assert all(reasons[p] for p in kept), "every kept package has a reason"


def test_flavour_module_drop_rule_is_conservative(substrate):
    """The rule that dropped nic-modules by mistake must never come back."""
    for keep in ("nic-modules-7.2.9-amd64-di", "crypto-modules-7.2.9-amd64-di",
                 "btrfs-modules-7.2.9-amd64-di", "base-modules-7.2.9-amd64-di",
                 "sata-modules-7.2.9-amd64-di"):
        assert not substrate.is_droppable_driver_udeb(keep, "amd64", "amd64"), \
            f"{keep} must be kept: the initrd or the install path needs it"
    for fs in ("xfs", "jfs"):
        assert substrate.is_droppable_driver_udeb(f"{fs}-modules-7.2.9-amd64-di",
                                                  "amd64", "amd64"), (
            "every droppable family must also produce a drop REASON; a family "
            "in is_droppable_driver_udeb without a DROPPABLE_FS_MODULES entry "
            "is a KeyError at build time (found on a real run 2026-10-17)")

def test_every_droppable_family_has_a_reason(substrate):
    """is_droppable_driver_udeb() and drop_reason() must agree on every key."""
    for family in substrate.DROPPABLE_FS_MODULES:
        name = f"{family}-7.2.9-amd64-di"
        assert substrate.is_droppable_driver_udeb(name, "amd64", "amd64")
        why = substrate.drop_reason(name, "amd64", "amd64", set())
        assert why == substrate.DROPPABLE_FS_MODULES[family]
    assert not substrate.is_droppable_driver_udeb("xfs-modules-7.2.9-arm64-di",
                                                  "amd64", "amd64"), \
        "a module udeb for another arch is not ours to judge"


def test_runtime_required_udebs_are_kept_even_if_not_in_initrd(substrate):
    for name in ("netcfg", "net-retriever"):
        assert name in substrate.RUNTIME_REQUIRED_UDEBS


def test_missing_runtime_udeb_aborts_the_build(substrate, tmp_path, fake_dpkg):
    """A pool without netcfg is not the substrate this module was measured
    against; shipping it would boot an installer that cannot configure a
    network. That must fail the build, not warn."""
    pool_root = tmp_path / "pool"
    thin = {k: v for k, v in POOL.items() if k not in ("netcfg", "net-retriever")}
    make_pool(pool_root, thin)
    status = write_status(tmp_path / "status", INITRD)
    pool = substrate.Pool(pool_root)
    with pytest.raises(SystemExit, match="netcfg"):
        substrate.keep_set(pool, "amd64", "amd64",
                           substrate.measure_substrate_initrd(status), set(), {})


def test_stale_keep_manifest_is_rejected(substrate, tmp_path, fake_dpkg):
    pool_root = tmp_path / "pool"
    make_pool(pool_root, POOL)
    status = write_status(tmp_path / "status", INITRD)
    pool = substrate.Pool(pool_root)
    keep_tsv = tmp_path / "keep.tsv"
    keep_tsv.write_text("not-in-the-pool\tstale\n")
    extra, reasons = substrate.load_keep_tsv(keep_tsv)
    with pytest.raises(SystemExit, match="not"):
        substrate.keep_set(pool, "amd64", "amd64",
                           substrate.measure_substrate_initrd(status),
                           extra, reasons)


def test_duplicate_keep_entry_is_rejected(substrate, tmp_path):
    keep_tsv = tmp_path / "keep.tsv"
    keep_tsv.write_text("openssh-server-udeb\ta\nopenssh-server-udeb\tb\n")
    with pytest.raises(SystemExit, match="twice"):
        substrate.load_keep_tsv(keep_tsv)


def test_real_keep_manifest_parses(substrate):
    extra, reasons = substrate.load_keep_tsv(
        REPO_ROOT / "manifests" / "magnetar-substrate-keep.tsv")
    assert "openssh-server-udeb" in extra
    assert all(reasons.values()), "every manifest line carries its reason"


def test_empty_pool_is_an_error(substrate, tmp_path, fake_dpkg):
    pool_root = tmp_path / "empty"
    pool_root.mkdir()
    with pytest.raises(SystemExit):
        substrate.main(["--installer-pool", str(pool_root),
                        "--initrd-status", str(write_status(tmp_path / "s", INITRD))])


def test_measurement_is_required_not_assumed(substrate, tmp_path, fake_dpkg):
    """No initrd evidence -> no keep-set. The task forbids guessing."""
    pool_root = tmp_path / "pool"
    make_pool(pool_root, POOL)
    with pytest.raises(SystemExit, match="--initrd"):
        substrate.main(["--installer-pool", str(pool_root)])


# ---------------------------------------------------------------------------
# write-usb-image.py --compress
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("kind,binname", [("xz", "xz"), ("zst", "zstd")])
def test_compress_reports_measured_sizes(writer, tmp_path, kind, binname):
    if not __import__("shutil").which(binname):
        pytest.skip(f"{binname} not installed")
    image = tmp_path / "disk.img"
    image.write_bytes(b"\0" * (1 << 20) + os.urandom(64 << 10))
    info = writer.compress_image(image, kind)
    out = Path(info["path"])
    assert out.name == f"disk.img.{kind}"
    assert out.is_file()
    assert info["raw_size"] == image.stat().st_size
    assert info["compressed_size"] == out.stat().st_size
    assert info["sha256"] == writer.sha256_file(out)
    assert info["ratio"] == round(info["raw_size"] / info["compressed_size"], 3)
    # The archive must reproduce the input byte for byte.
    if kind == "xz":
        raw = subprocess.run(["xz", "-dc", str(out)], capture_output=True,
                             check=True).stdout
    else:
        raw = subprocess.run(["zstd", "-dc", str(out)], capture_output=True,
                             check=True).stdout
    assert raw == image.read_bytes()


def test_compress_none_writes_no_archive(writer, tmp_path):
    image = tmp_path / "disk.img"
    image.write_bytes(b"x")
    assert writer.compress_image(image, "none") is None
    assert not list(tmp_path.glob("disk.img.*"))


def test_failed_compressor_leaves_no_archive(writer, tmp_path, monkeypatch):
    image = tmp_path / "disk.img"
    image.write_bytes(b"x")
    monkeypatch.setattr(writer.shutil, "which", lambda name: "/bin/false")

    def boom(cmd, *a, **kw):
        kw["stdout"].write(b"partial")
        raise subprocess.CalledProcessError(1, cmd)

    monkeypatch.setattr(writer.subprocess, "run", boom)
    with pytest.raises(subprocess.CalledProcessError):
        writer.compress_image(image, "xz")
    assert not list(tmp_path.glob("disk.img.*"))


def test_missing_compressor_fails_loudly(writer, tmp_path, monkeypatch):
    image = tmp_path / "disk.img"
    image.write_bytes(b"x")
    monkeypatch.setattr(writer.shutil, "which", lambda name: None)
    with pytest.raises(RuntimeError, match="refusing to report a compressed size"):
        writer.compress_image(image, "xz")
    assert not (tmp_path / "disk.img.xz").exists()


# ---------------------------------------------------------------------------
# build-refind-esp.py: content-sized ESP
# ---------------------------------------------------------------------------
def _required_esp_mib():
    mod = _load(ESP_BUILDER, "build_refind_esp")
    return mod._required_esp_mib


def test_esp_is_sized_to_content(tmp_path):
    required = _required_esp_mib()
    root = tmp_path / "esp"
    root.mkdir()
    (root / "EFI" / "BOOT").mkdir(parents=True)
    (root / "EFI" / "BOOT" / "BOOTX64.EFI").write_bytes(b"x" * (3 << 20))
    (root / "linux").write_bytes(b"x" * (9 << 20))
    (root / "initrd.gz").write_bytes(b"x" * (40 << 20))
    # 52 MiB of content -> no 256 MiB floor any more.
    mib = required(root, 0)
    assert mib < 100 and mib >= 1
    total = 52 << 20
    assert mib * 1024 * 1024 >= total
    # The floor still grows past a too-small request (the 2026-09-26 bug).
    assert required(root, 1) == mib
    assert required(root, 512) == 512


def test_esp_floor_is_never_zero(tmp_path):
    root = tmp_path / "empty"
    root.mkdir()
    assert _required_esp_mib()(root, 0) >= 1


def test_esp_test_does_not_leak_artifacts_into_repo(tmp_path):
    """Regression: the ESP test once wrote a 9 MiB "linux" blob into the repo
    root (2026-10-17 review), because the fixture root was not created before
    use and the size probe fell back to the CWD. Keep the probe anchored to
    tmp_path and assert that nothing appears at the top level of the worktree.
    """
    repo = Path(__file__).resolve().parents[3]
    before = {p.name for p in repo.iterdir()}
    required = _required_esp_mib()
    root = tmp_path / "esp"
    (root / "EFI" / "BOOT").mkdir(parents=True)
    (root / "linux").write_bytes(b"x" * (9 << 20))
    assert required(root, 0) >= 1
    after = {p.name for p in repo.iterdir()}
    assert after == before, f"repo root gained {after - before}"


# ---------------------------------------------------------------------------
# Review follow-ups (2026-10-17): the symbols the writer relies on must exist
# on the substrate module, and closure() must actually return its tuple.
# ---------------------------------------------------------------------------
def test_writer_symbols_exist_on_substrate_module():
    """write-usb-image.py reads these off the loaded module by name; an absent
    symbol would be an AttributeError only on the --di-initrd-less path."""
    mod = _load(SUBSTRATE_MOD, "magnetar_substrate")
    for name in ("INITRD_BUILTIN_EXPECTED_SAMPLE", "measure_substrate_initrd",
                 "load_keep_tsv", "keep_set", "drop_reason", "Pool",
                 "closure"):
        assert hasattr(mod, name), f"magnetar_substrate is missing {name}"
    assert isinstance(mod.INITRD_BUILTIN_EXPECTED_SAMPLE, (set, frozenset, tuple, list))
    assert mod.INITRD_BUILTIN_EXPECTED_SAMPLE


def test_closure_returns_complete_result(tmp_path):
    """closure() must terminate and return (kept, reasons) with reasons
    covering every kept package that was pulled in as a dependency."""
    mod = _load(SUBSTRATE_MOD, "magnetar_substrate")
    pool_root = tmp_path / "pool" / "main"
    pool_root.mkdir(parents=True)
    for name in ("alpha", "beta", "gamma"):
        (pool_root / f"{name}_1.udeb").write_bytes(b"x")
    pool = mod.Pool(tmp_path / "pool")
    deps = {"alpha": ["beta"], "beta": ["gamma"]}
    kept, reasons = mod.closure({"alpha"}, pool, deps, set())
    assert kept == {"alpha", "beta", "gamma"}
    assert reasons["beta"] == "dependency of alpha"
    assert reasons["gamma"] == "dependency of beta"
    assert isinstance(reasons, dict)


def test_closure_skips_and_records_initrd_builtin(tmp_path):
    mod = _load(SUBSTRATE_MOD, "magnetar_substrate")
    pool_root = tmp_path / "pool" / "main"
    pool_root.mkdir(parents=True)
    for name in ("alpha", "beta"):
        (pool_root / f"{name}_1.udeb").write_bytes(b"x")
    pool = mod.Pool(tmp_path / "pool")
    kept, reasons = mod.closure({"alpha"}, pool, {"alpha": ["beta"]}, {"beta"})
    assert kept == {"alpha"}
    assert "initrd" in reasons["beta"]


def test_closure_terminates_on_cycle(tmp_path):
    mod = _load(SUBSTRATE_MOD, "magnetar_substrate")
    pool_root = tmp_path / "pool" / "main"
    pool_root.mkdir(parents=True)
    for name in ("a", "b"):
        (pool_root / f"{name}_1.udeb").write_bytes(b"x")
    pool = mod.Pool(tmp_path / "pool")
    kept, _ = mod.closure({"a"}, pool, {"a": ["b"], "b": ["a"]}, set())
    assert kept == {"a", "b"}


def test_load_keep_tsv_rejects_space_separated_row(tmp_path, substrate):
    """A space instead of a tab would turn the whole row into one bogus
    package name and silently shrink the medium."""
    keep = tmp_path / "keep.tsv"
    keep.write_text("openssh-server-udeb diag-console installs it\n")
    with pytest.raises(SystemExit, match="expected name<TAB>reason"):
        substrate.load_keep_tsv(keep)


def test_load_keep_tsv_accepts_well_formed_rows(tmp_path, substrate):
    keep = tmp_path / "keep.tsv"
    keep.write_text("# comment\n\nopenssh-server-udeb\tdiag-console\n")
    names, reasons = substrate.load_keep_tsv(keep)
    assert names == {"openssh-server-udeb"}
    assert reasons["openssh-server-udeb"] == "diag-console"


def test_pool_rejects_control_filename_mismatch(tmp_path, substrate, fake_dpkg):
    """Pool keys come from filenames; if the Package: field disagrees the
    index is wrong and the closure would be silently corrupted."""
    pool_root = tmp_path / "pool"
    bad = pool_root / "main" / "a" / "not-anna_1.udeb"
    bad.parent.mkdir(parents=True)
    bad.write_bytes(b"x")
    (bad.parent / f"{bad.name}.package").write_text("anna\n")
    # The stub reports the filename stem, so make the file disagree by name.
    with pytest.raises(SystemExit, match="filed as"):
        substrate.Pool(pool_root)


# ---------------------------------------------------------------------------
# 2026-10-17 review: the build path drops ONLY provable classes.
# ---------------------------------------------------------------------------
NEVER_DROP = ("partman-btrfs", "partman-base", "partman-auto", "partman-ext3",
              "partman-target", "partman-partitioning", "partman-basicfilesystems",
              "base-installer", "bootstrap-base", "debootstrap-udeb", "pkgsel",
              "choose-mirror", "clock-setup", "finish-install", "apt-setup-udeb",
              "user-setup-udeb", "netcfg", "net-retriever", "nobootloader",
              "grub-installer", "systemd-boot-installer", "save-logs",
              "btrfs-modules-7.2.9-amd64-di")


def _pool(tmp_path, substrate, packages):
    make_pool(tmp_path / "pool", packages)
    return substrate.Pool(tmp_path / "pool")


@pytest.mark.parametrize("name", NEVER_DROP)
def test_install_path_udebs_have_no_drop_reason(substrate, name):
    assert substrate.provable_drop_reason(name, "amd64", "amd64") is None


def test_slim_keep_set_drops_only_provable_classes(substrate, tmp_path, fake_dpkg):
    pool = _pool(tmp_path, substrate, {
        "partman-base": (100, ""),
        "partman-btrfs": (100, "partman-base"),
        "partman-lvm": (100, "partman-base"),
        "xfs-modules-7.2.9-amd64-di": (100, ""),
        "some-unknown-udeb": (100, ""),
    })
    kept, _ = substrate.slim_keep_set(pool, "amd64", "amd64", set(), set(), {})
    assert set(pool.keys()) - kept == {"partman-lvm", "xfs-modules-7.2.9-amd64-di"}


def test_slim_keep_set_keeps_a_droppable_udeb_a_kept_one_depends_on(
        substrate, tmp_path, fake_dpkg):
    pool = _pool(tmp_path, substrate, {
        "partman-lvm": (100, ""),
        "needs-lvm": (100, "partman-lvm"),
    })
    kept, _ = substrate.slim_keep_set(pool, "amd64", "amd64", set(), set(), {})
    assert "partman-lvm" in kept


def test_initrd_status_is_read_from_the_compressed_initrd(substrate, tmp_path):
    import gzip
    import shutil
    if not shutil.which("cpio"):
        pytest.skip("cpio not installed")
    tree = tmp_path / "tree" / "var" / "lib" / "dpkg"
    tree.mkdir(parents=True)
    (tree / "status").write_text("Package: anna\nStatus: install ok installed\n\n"
                                 "Package: main-menu\n")
    cpio = subprocess.run(["cpio", "-o", "-H", "newc", "--quiet"],
                          cwd=tmp_path / "tree", input=b"var/lib/dpkg/status\n",
                          capture_output=True, check=True).stdout
    initrd = tmp_path / "initrd.gz"
    initrd.write_bytes(gzip.compress(cpio))
    got = substrate._initrd_status_packages(initrd, tmp_path)
    assert got == {"anna", "main-menu"}


def test_substrate_cut_is_off_by_default(writer, monkeypatch):
    monkeypatch.delenv("NCZ_MAGNETAR_SLIM_SUBSTRATE", raising=False)
    assert writer.slim_substrate_enabled() is False
    monkeypatch.setenv("NCZ_MAGNETAR_SLIM_SUBSTRATE", "1")
    assert writer.slim_substrate_enabled() is True


def test_underscore_module_names_are_recognised(substrate):
    reason = substrate.DROPPABLE_FS_MODULES["xfs-modules"]
    assert substrate.provable_drop_reason("xfs_modules-7.2.9-amd64-di", "amd64", "amd64") == reason
    assert substrate.drop_reason("xfs_modules-7.2.9-amd64-di", "amd64", "amd64", set()) == reason
    assert substrate.provable_drop_reason("nic_modules-7.2.9-amd64-di", "amd64", "amd64") is None


def test_xz_output_does_not_depend_on_thread_count(writer, tmp_path):
    import shutil
    if not shutil.which("xz"):
        pytest.skip("xz not installed")
    image = tmp_path / "disk.img"
    image.write_bytes(os.urandom(1 << 16) * 64)
    a = writer.compress_image(image, "xz", 1)["sha256"]
    one = subprocess.run(["xz", "-c", "-1", "-T1", str(image)],
                         capture_output=True, check=True).stdout
    assert __import__("hashlib").sha256(one).hexdigest() == a


def test_unreadable_initrd_keeps_more_not_less(writer, substrate, tmp_path, fake_dpkg,
                                               monkeypatch):
    stage = tmp_path / "stage"
    make_pool(stage / "pool", {"partman-base": (100, ""), "partman-lvm": (100, "")})
    monkeypatch.setattr(writer, "release_codename", lambda: "forky")
    (stage / "dists" / "forky" / "main" / "debian-installer" / "binary-amd64").mkdir(parents=True)
    calls = []
    real_run = subprocess.run

    def fake_run(cmd, *a, **kw):
        if cmd and cmd[0] == "dpkg-scanpackages":
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0)
        return real_run(cmd, *a, **kw)

    monkeypatch.setattr(writer.subprocess, "run", fake_run)
    bad = tmp_path / "initrd.gz"
    bad.write_bytes(b"\x1f\x8bnot really gzip")
    receipt = writer.slim_installer_pool(stage, "amd64", stage / "pool", bad)
    assert "measurement failed" in receipt["basis"]
    assert "partman-base" in receipt["kept"]
    assert [d["package"] for d in receipt["dropped"]] == ["partman-lvm"]
    assert calls


def test_unreadable_control_fails_the_closure(substrate, tmp_path, monkeypatch):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    stub = bindir / "dpkg-deb"
    stub.write_text("#!/bin/sh\n[ \"$3\" = Package ] && { b=$(basename \"$2\"); "
                    "printf '%s\\n' \"${b%%_*}\"; exit 0; }\necho broken >&2; exit 2\n")
    stub.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    make_pool(tmp_path / "pool", {"partman-base": (10, "")})
    pool = substrate.Pool(tmp_path / "pool")
    with pytest.raises(SystemExit, match="cannot read Depends"):
        substrate.slim_keep_set(pool, "amd64", "amd64", set(), set(), {})


def test_slim_reasons_only_describe_kept_udebs(substrate, tmp_path, fake_dpkg):
    make_pool(tmp_path / "pool", {"partman-base": (10, ""), "partman-lvm": (10, "")})
    pool = substrate.Pool(tmp_path / "pool")
    kept, reasons = substrate.slim_keep_set(pool, "amd64", "amd64", set(), set(), {})
    assert set(reasons) <= kept
