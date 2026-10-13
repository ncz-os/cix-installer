#!/usr/bin/env python3
"""layerplan.py -- per-layer input fingerprints and the reuse/rebuild plan.

This is the single place that answers two questions for the image build:

  1. "Is this cached layer still valid for the current inputs?"  (fingerprint)
  2. "Which layers must be rebuilt for this build mode / component set?"
     (plan)

Why a fingerprint and not the git commit
----------------------------------------
The determinism contract is content-addressed.  A layer's fingerprint is a
sha256 over the *content* of every input that goes into the layer -- package
lists, hook scripts, asset trees, kernel/payload debs by sha256, the upstream
and substrate pins, and (recursively) the layers below it.  It deliberately does
NOT include the git commit SHA or SOURCE_DATE_EPOCH: if it did, every commit --
even a docs-only commit -- would invalidate every layer and a "quick respin"
could never reuse anything.  The commit SHA and SOURCE_DATE_EPOCH are part of
the *image* fingerprint and the run receipt, where they belong.

Dependency chain
----------------
    mirror -> base -> desktop -> hotfix
A change to a lower layer's inputs changes its fingerprint, which changes every
layer above it, so dependents are rebuilt against the new bytes.  This is what
makes "the final image from a quick respin equals a full build from the same
pins" true: an unchanged layer keeps its fingerprint and its bytes; a changed
layer is rebuilt against the same lower-layer bytes a full build would use.

Layout this module assumes (repo-relative)
------------------------------------------
  manifests/*.pkgs, *.tsv, base.pin     package lists + pins
  post-install/                         installer hooks
  assets/{gpu,audio,display,refind,grub,branding,dracut,regreet,diag,keys,
          dev,docs,embedkit,intel,wallpaper,npu,firmware,sky1-firmware,...}
  assets/kernel/                        kernel channel layout + KVER
  assets/singularity/                   Singularity payload source pins
  assets/cix-debs/                      prebuilt payload debs
  build/*.sh                            the scripts that build the layers

Commands
--------
  fingerprint --layer L --arch A [--root DIR] [--pin FILE]
  plan        --arch A --mode M [--components c1,c2] [--layers-dir DIR]
              [--root DIR] [--pin FILE]     -> JSON plan on stdout
  write-stamps --arch A --layers-dir DIR [--root DIR] [--pin FILE]
  check       --layer L --arch A --layers-dir DIR [--root DIR] [--pin FILE]
  components  C1,C2                        -> the layers they affect, one per line
  selftest

Exit codes: 0 ok, 1 check failed / invariant violation, 2 usage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# --- reuse the one implementation of the pin primitives ---------------------
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # noqa: E402
try:
    import reproducible  # type: ignore
except Exception:  # pragma: no cover - only if run from a broken tree
    reproducible = None  # type: ignore


# ---------------------------------------------------------------------------
# The input registry: every input of every layer, declared once.
# ---------------------------------------------------------------------------
# Spec forms:
#   ("path",  rel)          a file or a directory tree under ROOT
#   ("glob",  relpattern)   every matching path under ROOT
#   ("dep",   layer)        the fingerprint of another layer (dependency)
#   ("pin",   name)         a resolved pin value (substrate/snapshot/kernel/...)
#   ("kernel-layout",)      the assets/kernel directory/symlink layout + KVER
LAYERS = ("mirror", "base", "desktop", "hotfix")

# Asset dirs the base rootfs copies verbatim.  Keep in sync with
# build/build-squashfs-layers.sh's staging loop; the r202 report found that
# assets/wallpaper and post-install were MISSING from the old base stamp, so
# a change to either never reached the image on a reused base.
_BASE_ASSET_DIRS = (
    "gpu", "audio", "display", "refind", "grub", "branding", "dracut",
    "regreet", "diag", "keys", "dev", "docs", "embedkit", "intel",
)
# dracut is Sky1-only: not staged into an amd64 base.
_SKY1_ONLY_ALL = {"dracut"}

REGISTRY: dict[str, list[tuple]] = {
    "mirror": [
        ("path", "release.conf"),
        ("path", "manifests/build-inputs.tsv"),
        ("path", "manifests/forky-snapshot.tsv"),
        ("path", "manifests/ncz-packages.tsv"),
        ("path", "manifests/vendor-debs.tsv"),
        ("path", "manifests/vendor-repos.tsv"),
        ("glob", "manifests/*.pkgs"),
        ("path", "build/build-forky-mirror.sh"),
        ("path", "build/build-desktop-mirror.sh"),
        ("path", "build/build-vendor-mirror.sh"),
        ("path", "build/lib/mirror-apt-opts.sh"),
        ("pin", "snapshot"),
        ("pin", "substrate_sha256"),
    ],
    "base": [
        ("dep", "mirror"),
        ("path", "release.conf"),
        ("glob", "manifests/installer-base*.pkgs"),
        ("path", "manifests/build-inputs.tsv"),
        ("path", "manifests/firmware.pkgs"),
        ("path", "manifests/firmware-arm64.pkgs"),
        ("path", "manifests/firmware-bom.allow"),
        ("path", "manifests/firmware-bom-arm64.allow"),
        ("path", "manifests/net-firmware.tsv"),
        ("path", "post-install"),            # r202 gap #5 (post-install)
        ("path", "assets/wallpaper"),        # r202 gap #5 (wallpaper)
        # The hand-edited asset dirs build_base copies verbatim.  _BASE_ASSET_DIRS
        # was declared but never registered, so an edit to assets/gpu, audio,
        # intel, ... left the base fingerprint unchanged and a respin reused a
        # stale base.squashfs (the 2026-09-29 failure the stamp exists for).
        *[("path", f"assets/{d}") for d in _BASE_ASSET_DIRS],
        ("path", "assets/npu"),
        ("path", "assets/firmware"),
        ("path", "assets/sky1-firmware"),
        ("path", "assets/ssh-udebs"),
        ("path", "assets/hostnames"),
        ("path", "assets/perf"),
        ("path", "build/build-squashfs-layers.sh"),
        ("path", "build/build-base-rootfs.sh"),
        ("path", "build/build-role-delta-mkosi.sh"),
        ("path", "build/build-kernel-debs.sh"),
        ("path", "build/stage-amd64-kernel.sh"),
        ("path", "build/kernel-manifest.py"),
        ("path", "assets/kernel-manifest.json"),  # kernel deb sha256 pins
        ("kernel-layout",),
        ("pin", "kernel_kver"),
        ("pin", "substrate_sha256"),
    ],
    "desktop": [
        ("dep", "base"),
        ("glob", "manifests/desktop*.pkgs"),
        ("path", "manifests/install-extra.pkgs"),
        ("path", "assets/singularity"),      # upstream pin + patch queue
        ("path", "assets/wallpaper"),        # wallpaper packs land in desktop
        ("path", "assets/cix-debs"),         # prebuilt payload debs
        ("path", "build/build-desktop-mirror.sh"),
        ("path", "build/build-wallpaper-contrib-deb.sh"),
        ("path", "build/build-role-delta-mkosi.sh"),
        ("path", "build/build-squashfs-layers.sh"),
        ("pin", "singularity_upstream_pin"),
    ],
    "hotfix": [
        ("dep", "desktop"),
        ("glob", "assets/cix-debs/ncz-singularity-desktop_*.deb"),
        ("path", "build/build-squashfs-layers.sh"),
        ("pin", "singularity_payload_sha256"),
    ],
}

# The image is reassembled from the layers + mirror on every build, so it has no
# reuse stamp; its inputs are listed for the receipt/plan only.
IMAGE_INPUTS = [
    ("dep", "base"), ("dep", "desktop"), ("dep", "hotfix"),
    ("path", "build/iso"), ("path", "preseed"), ("path", "assets/refind"),
    ("path", "assets/grub"), ("path", "manifests/installer-base*.pkgs"),
]

# component -> the layers its inputs live in
COMPONENTS: dict[str, tuple[str, ...]] = {
    "kernel": ("base",),
    "base-assets": ("base",),
    "apt-policy": ("base",),
    "post-install": ("base",),
    "base": ("base",),
    "desktop": ("desktop",),
    "desktop-mirror": ("desktop",),
    "singularity": ("desktop", "hotfix"),
    "screensavers": ("desktop",),
    "wallpapers": ("desktop",),
    "plugins": ("desktop",),
    "installer-initrd": (),
    "preseed": (),
    "image": (),
}

_MODE_LAYERS: dict[str, dict[str, str]] = {
    # explicit per-layer decision; "auto" = fingerprint decides
    "full":            {"mirror": "rebuild", "base": "rebuild", "desktop": "rebuild", "hotfix": "rebuild"},
    "respin":          {"mirror": "auto", "base": "auto", "desktop": "auto", "hotfix": "auto"},
    "quick-respin":    {"mirror": "auto", "base": "auto", "desktop": "auto", "hotfix": "auto"},
    "rebuild-base":    {"mirror": "auto", "base": "rebuild", "desktop": "rebuild", "hotfix": "rebuild"},
    "rebuild-desktop": {"mirror": "auto", "base": "auto", "desktop": "rebuild", "hotfix": "rebuild"},
    "rebuild-hotfix":  {"mirror": "auto", "base": "auto", "desktop": "auto", "hotfix": "rebuild"},
    "components":      {"mirror": "auto", "base": "auto", "desktop": "auto", "hotfix": "auto"},
    "only-image":      {"mirror": "reuse", "base": "reuse", "desktop": "reuse", "hotfix": "reuse"},
}

_DEP_ORDER = ("mirror", "base", "desktop", "hotfix")
_DEPENDENTS = {
    "mirror": ("base", "desktop", "hotfix"),
    "base": ("desktop", "hotfix"),
    "desktop": ("hotfix",),
    "hotfix": (),
}


def _is_sky1_only(entry: str) -> bool:
    return entry in _SKY1_ONLY_ALL


def _iter_tree(root: Path, rel: str):
    """Yield (relpath, kind, value) for a file/dir/symlink under root/rel.

    kind is "f" (regular file, value=sha256), "l" (symlink, value=target),
    or "d" (directory, value="").  Directories yield nothing but their
    children; absent paths yield nothing.
    """
    base = root / rel
    if not base.exists() and not base.is_symlink():
        return
    if base.is_symlink():
        yield rel, "l", os.readlink(base)
        return
    if base.is_file():
        yield rel, "f", _sha256_file(base)
        return
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        dirnames.sort()
        for name in sorted(filenames):
            p = Path(dirpath) / name
            r = str(p.relative_to(root))
            if p.is_symlink():
                yield r, "l", os.readlink(p)
            elif p.is_file():
                yield r, "f", _sha256_file(p)
        # record symlinked dirs (os.walk lists them in dirnames but does not
        # descend when followlinks=False).
        for name in list(dirnames):
            p = Path(dirpath) / name
            if p.is_symlink():
                yield str(p.relative_to(root)), "l", os.readlink(p)
                dirnames.remove(name)


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _resolve_pin(name: str, arch: str, root: Path, pin_file: Path) -> str:
    """Resolve a named pin, tolerating both base.pin shapes:

      * key<TAB>value rows (this branch's gen-base-pin.sh), and
      * the arch-major rows used by fix/r203-provenance-20261010
        (arch<TAB>substrate_sha256<TAB>substrate_date<TAB>snapshot<TAB>cov<TAB>url).
    """
    text = ""
    if pin_file and Path(pin_file).is_file():
        text = Path(pin_file).read_text()
    rows: dict[str, str] = {}
    arch_row: dict[int, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 4 and re.fullmatch(r"(amd64|arm64)", parts[0]):
            if parts[0] == arch:
                arch_row = {i: p for i, p in enumerate(parts)}
            continue
        if len(parts) >= 2:
            rows[parts[0]] = parts[1]

    def pick(*keys: str) -> str:
        for k in keys:
            if k in rows and rows[k]:
                return rows[k]
        return ""

    if name == "snapshot":
        v = pick("snapshot", "NCZ_BASE_MIRROR_SNAPSHOT")
        if v:
            return v
        # arch-major: column 3 is the snapshot
        if arch_row.get(3, ""):
            return arch_row[3]
        # release.conf fallback
        conf = root / "release.conf"
        if conf.is_file():
            for ln in conf.read_text().splitlines():
                m = re.match(r'\s*NCZ_BASE_MIRROR_SNAPSHOT="?([^"#]+)"?', ln)
                if m:
                    return m.group(1).strip()
        return ""
    if name == "substrate_sha256":
        v = pick(f"substrate_sha256_{arch}", "substrate_sha256")
        if v:
            return v
        if re.fullmatch(r"[0-9a-f]{64}", arch_row.get(1, "")):
            return arch_row[1]
        return ""
    if name == "kernel_kver":
        v = pick(f"kernel_kver_{arch}", "kernel_kver")
        if v:
            return v
        kf = root / "assets/kernel/amd64-stable/KVER"
        if arch == "amd64" and kf.is_file():
            return kf.read_text().strip()
        kl = root / "assets/kernel/mainline/KVER"
        if kl.is_file():
            return kl.read_text().strip()
        return ""
    if name == "singularity_upstream_pin":
        v = pick("singularity_upstream_pin")
        if v:
            return v
        pins = root / "assets/singularity/upstream-pins.tsv"
        if pins.is_file():
            for ln in pins.read_text().splitlines():
                if ln.startswith("#") or not ln.strip():
                    continue
                parts = ln.split("\t")
                if parts and parts[0] == ".":
                    return parts[3] if len(parts) > 3 else ""
        return ""
    if name == "singularity_payload_sha256":
        return pick(f"singularity_payload_sha256_{arch}", "singularity_payload_sha256")
    return pick(name)


def layer_fingerprint(layer: str, arch: str, root: Path, pin_file: Path,
                      _seen: frozenset = frozenset()) -> str:
    """sha256 over the content of every declared input of `layer`.

    Deterministic given the input CONTENT.  Excludes the git commit SHA and
    SOURCE_DATE_EPOCH on purpose (see the module docstring).
    """
    if layer not in REGISTRY:
        raise ValueError(f"unknown layer: {layer}")
    if layer in _seen:
        raise ValueError(f"layer dependency cycle at {layer}")
    seen = _seen | {layer}
    h = hashlib.sha256()
    h.update(f"ncz-layer/v1\x00{layer}\x00{arch}\x00".encode())
    lines: list[str] = []
    for spec in REGISTRY[layer]:
        kind = spec[0]
        if kind == "dep":
            lines.append(f"dep:{spec[1]}={layer_fingerprint(spec[1], arch, root, pin_file, seen)}")
        elif kind == "path":
            rel = spec[1]
            if _is_sky1_only(rel.split("/")[-1]) and arch == "amd64":
                lines.append(f"skip:{rel} (sky1-only)")
                continue
            got = list(_iter_tree(root, rel))
            if not got:
                lines.append(f"missing:{rel}")
                continue
            for r, k, v in sorted(got):
                lines.append(f"{k}:{r}={v}")
        elif kind == "glob":
            import glob as _glob
            paths = sorted(_glob.glob(str(root / spec[1]), recursive=True))
            if not paths:
                lines.append(f"missing-glob:{spec[1]}")
            for p in paths:
                rel = str(Path(p).relative_to(root)) if Path(p).is_relative_to(root) else p
                if _is_sky1_only(Path(p).name) and arch == "amd64":
                    lines.append(f"skip:{rel} (sky1-only)")
                    continue
                got = list(_iter_tree(root, rel))
                for r, k, v in sorted(got):
                    lines.append(f"{k}:{r}={v}")
        elif kind == "kernel-layout":
            kernel = root / "assets/kernel"
            if kernel.is_dir():
                for name in sorted(os.listdir(kernel)):
                    p = kernel / name
                    if p.is_symlink():
                        lines.append(f"kl:{name}->{os.readlink(p)}")
                    elif p.is_dir():
                        kver = p / "KVER"
                        if kver.is_file():
                            lines.append(f"kl:{name}/KVER={kver.read_text().strip()}")
                        else:
                            lines.append(f"kl:{name}/")
                for f in sorted(os.listdir(kernel)):
                    fp = kernel / f
                    if fp.is_file() and not fp.is_symlink():
                        lines.append(f"kf:{f}={_sha256_file(fp)}")
        elif kind == "pin":
            lines.append(f"pin:{spec[1]}={_resolve_pin(spec[1], arch, root, pin_file)}")
        else:
            raise ValueError(f"unknown spec kind: {kind}")
    for ln in sorted(lines):
        h.update(ln.encode() + b"\n")
    return h.hexdigest()


def _stamp_path(layers_dir: Path, layer: str) -> Path:
    return layers_dir / f"{layer}.build-fingerprint"


def _layer_artifact(layers_dir: Path, layer: str) -> Path:
    return layers_dir / {
        "mirror": "..", "base": "base.squashfs",
        "desktop": "desktop.squashfs", "hotfix": "desktop-hotfix.squashfs",
    }[layer]


def fingerprint_ok(layer: str, arch: str, root: Path, pin_file: Path,
                   layers_dir: Path) -> bool:
    """True when the layer's artifact + stamp exist and the stamp matches."""
    if layer == "mirror":
        # the mirror is a directory; its stamp lives beside the layers
        stamp = _stamp_path(layers_dir, layer)
        return stamp.is_file() and stamp.read_text().strip() == \
            layer_fingerprint(layer, arch, root, pin_file)
    art = _layer_artifact(layers_dir, layer)
    stamp = _stamp_path(layers_dir, layer)
    if not art.is_file() or not stamp.is_file():
        return False
    return stamp.read_text().strip() == layer_fingerprint(layer, arch, root, pin_file)


def build_plan(arch: str, mode: str, root: Path, pin_file: Path,
               layers_dir: Path, components: list[str]) -> dict:
    if mode not in _MODE_LAYERS:
        raise ValueError(f"unknown mode: {mode}")
    decisions: dict[str, str] = {}
    reasons: dict[str, str] = {}
    base_decisions = dict(_MODE_LAYERS[mode])

    # components force their layers (and, transitively, dependents) to rebuild
    forced: set[str] = set()
    if mode == "components":
        if not components:
            raise ValueError("--components requires a non-empty component list")
        for c in components:
            if c not in COMPONENTS:
                raise ValueError(f"unknown component: {c}")
            forced.update(COMPONENTS[c])
    for lyr in reversed(_DEP_ORDER):  # hotfix -> desktop -> base -> mirror
        if lyr in forced:
            decisions[lyr] = "rebuild"
            reasons[lyr] = "component input changed"
            continue
        want = base_decisions[lyr]
        if want == "reuse":
            decisions[lyr] = "reuse"
            reasons[lyr] = "mode reuses layers"
        elif want == "rebuild":
            decisions[lyr] = "rebuild"
            reasons[lyr] = f"mode {mode}"
        else:  # auto
            if fingerprint_ok(lyr, arch, root, pin_file, layers_dir):
                decisions[lyr] = "reuse"
                reasons[lyr] = "fingerprint unchanged"
            else:
                decisions[lyr] = "rebuild"
                reasons[lyr] = "fingerprint changed or layer missing"

    # propagate: if any layer is rebuilt, every layer above it must rebuild
    for lyr in _DEP_ORDER:
        if decisions[lyr] == "rebuild":
            for dep in _DEPENDENTS[lyr]:
                if decisions[dep] == "reuse":
                    decisions[dep] = "rebuild"
                    reasons[dep] = f"depends on rebuilt {lyr}"

    fingerprints = {lyr: layer_fingerprint(lyr, arch, root, pin_file) for lyr in _DEP_ORDER}
    return {
        "arch": arch, "mode": mode, "components": components,
        "layers": decisions, "reasons": reasons, "fingerprints": fingerprints,
        "image": "rebuild",
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--arch", required=True)
        p.add_argument("--root", type=Path, default=None)
        p.add_argument("--pin", type=Path, default=None)

    p = sub.add_parser("fingerprint"); p.add_argument("--layer", required=True); common(p)
    p = sub.add_parser("plan")
    common(p)
    p.add_argument("--mode", required=True)
    p.add_argument("--components", default="")
    p.add_argument("--layers-dir", type=Path, default=None)
    p = sub.add_parser("write-stamps"); common(p); p.add_argument("--layers-dir", required=True, type=Path)
    p = sub.add_parser("check"); p.add_argument("--layer", required=True); common(p); p.add_argument("--layers-dir", required=True, type=Path)
    p = sub.add_parser("components"); p.add_argument("list", nargs="?", default="")
    sub.add_parser("selftest")

    args = ap.parse_args(argv)

    root = args.root if getattr(args, "root", None) else Path(__file__).resolve().parents[2]
    pin = args.pin if getattr(args, "pin", None) else root / "manifests/base.pin"

    try:
        if args.cmd == "fingerprint":
            print(layer_fingerprint(args.layer, args.arch, root, pin))
        elif args.cmd == "plan":
            comps = [c for c in args.components.split(",") if c]
            ld = args.layers_dir or (root / "assets/squashfs")
            print(json.dumps(build_plan(args.arch, args.mode, root, pin, ld, comps),
                             indent=2, sort_keys=True))
        elif args.cmd == "write-stamps":
            for lyr in _DEP_ORDER:
                fp = layer_fingerprint(lyr, args.arch, root, pin)
                sp = _stamp_path(args.layers_dir, lyr)
                sp.write_text(fp + "\n")
                print(f"{lyr}\t{fp}")
        elif args.cmd == "check":
            sys.exit(0 if fingerprint_ok(args.layer, args.arch, root, pin, args.layers_dir) else 1)
        elif args.cmd == "components":
            out: list[str] = []
            for c in [x for x in args.list.split(",") if x]:
                if c not in COMPONENTS:
                    print(f"unknown component: {c}", file=sys.stderr)
                    return 2
                out.extend(COMPONENTS[c])
            for lyr in _DEP_ORDER:
                if lyr in out:
                    print(lyr)
        elif args.cmd == "selftest":
            return selftest()
    except (ValueError, OSError) as exc:
        print(f"layerplan.py: {exc}", file=sys.stderr)
        return 1
    return 0


def selftest() -> int:
    fails = 0

    def check(cond, what):
        nonlocal fails
        if cond:
            print(f"ok   {what}")
        else:
            print(f"FAIL {what}")
            fails += 1

    # registry sanity: every "dep" names a real layer; every layer reachable
    for lyr, specs in REGISTRY.items():
        for spec in specs:
            if spec[0] == "dep":
                check(spec[1] in REGISTRY, f"{lyr}: dep {spec[1]} exists")
    check(set(REGISTRY) == set(LAYERS), "registry covers every layer")
    base_paths = {s[1] for s in REGISTRY["base"] if s[0] == "path"}
    for d in _BASE_ASSET_DIRS:
        check(f"assets/{d}" in base_paths, f"base fingerprint covers assets/{d}")
    check(IMAGE_INPUTS and IMAGE_INPUTS[0][0] == "dep", "image inputs declared")
    for c, ls in COMPONENTS.items():
        check(all(l in LAYERS for l in ls), f"component {c} maps to real layers")
    print(f"\nlayerplan.py selftest: {'PASS' if not fails else 'FAIL'} ({fails} failure(s))")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
