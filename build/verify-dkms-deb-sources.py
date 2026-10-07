#!/usr/bin/env python3
"""verify-dkms-deb-sources.py: every accelerator DKMS .deb staged in
assets/cix-debs/ must carry the SAME source as assets/kernel/<driver>/.

WHY (2026-10-07, O6N on the r285 7.3.0-rc6-sky1-ncz kernel). The image shipped
panthor-cix-dkms_7.2.0+ncz1_all.deb built on 2026-09-25, before the 7.3 port
of panthor_drv.c (DRIVER_GEM_GPUVA was removed upstream in v7.3, 21fcb222f0d1).
First-boot DKMS failed with

    panthor_drv.c:1785:54: error: 'DRIVER_GEM_GPUVA' undeclared

so the installed system had no panthor.ko at all, while assets/kernel/panthor/
(the source every gate and overlay build looks at) had compiled cleanly against
r285 since r279. The same image's cix-gpu-kmd-dkms_1.0+ncz1_all.deb also
predated the mali detach fix (b11ee9e1) in assets/kernel/mali/src/.

How a stale deb survives: build/build-dkms-debs.sh versions the deb from
dkms.conf PACKAGE_VERSION plus +ncz<rev>, which does not change when the source
does, so a rebuilt deb has the SAME filename as the stale one, and asset
staging that copies without clobbering keeps the old file. Nothing compared
the deb payload with the source tree.

WHAT IT CHECKS, per driver whose assets/kernel/<drv>/dkms.conf exists:
  - at most one <PACKAGE_NAME>-dkms_*.deb in the deb dir (post-install picks
    the first `ls` match, so two versions make the choice arbitrary);
  - when one exists, its /usr/src/<NAME>-<VERSION>/ tree carries exactly the
    source files build/build-dkms-debs.sh would stage today (same set, same
    bytes). Prebuilt .ko files and build artifacts are ignored.
A driver with no dkms.conf in the tree, or no deb staged, is reported and
skipped: presence of each deb is verify-arm64-inputs.sh's job, not this one.

--overlays [KVER]: the prebuilt overlay side of the same rule. Each
assets/kernel/<drv>/<kver>/ dir must exist and carry SOURCE.sha256, written by
build/build-accel-overlays.sh when it compiled that overlay, equal to the
digest of today's assets/kernel/<drv> source (--source-digest DRV prints it).
Together with verify-overlay-modversions.py (CRCs vs the pinned kernel) this
means a kernel bump cannot ship without a panthor.ko compiled from the current
source against that kernel.

Usage:
  build/verify-dkms-deb-sources.py [--root DIR] [--deb-dir DIR] [--driver D ...]
  build/verify-dkms-deb-sources.py [--root DIR] --overlays [KVER] [--driver D ...]
  build/verify-dkms-deb-sources.py [--root DIR] --source-digest DRV
Environment: VERIFY_ROOT (same as --root).

Exit: 0 pass, 1 gate failure (every failure printed), 2 bad invocation.
"""

import argparse
import glob
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile

DRIVERS = ("panthor", "mali", "vpu", "npu")

# Mirrors build/build-dkms-debs.sh: what goes into /usr/src/<NAME>-<VER>/.
#   panthor: the whole asset dir minus build artifacts, patches/ and the
#            per-KVER prebuilt overlay dirs
#   others:  src/ plus dkms.conf
ARTIFACT_SUFFIXES = (".o", ".ko", ".cmd", ".a", ".order", ".symvers")


def is_artifact(rel):
    base = os.path.basename(rel)
    if base in ("Module.symvers", "modules.order"):
        return True
    if ".mod" in base:  # foo.mod, foo.mod.c, foo.mod.o
        return True
    return base.endswith(ARTIFACT_SUFFIXES)


def is_kver_dir(name):
    # 7.2.0-sky1-ncz, 7.3.0-rc6-sky1-ncz, ...: per-kernel prebuilt overlays
    return name[:1].isdigit() and "." in name and "-" in name


def conf_get(path, key):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def expected_tree(root, drv):
    """Return {relpath: sha256} build-dkms-debs.sh would stage for drv."""
    asset = os.path.join(root, "assets", "kernel", drv)
    out = {}
    if drv == "panthor":
        base = asset
        for dirpath, dirnames, filenames in os.walk(base):
            rel_dir = os.path.relpath(dirpath, base)
            if rel_dir == ".":
                dirnames[:] = [
                    d for d in dirnames if d != "patches" and not is_kver_dir(d)
                ]
            for fn in filenames:
                rel = os.path.normpath(os.path.join(rel_dir, fn))
                if is_artifact(rel):
                    continue
                with open(os.path.join(dirpath, fn), "rb") as f:
                    out[rel] = sha256(f.read())
    else:
        base = os.path.join(asset, "src")
        if not os.path.isdir(base):
            return None
        for dirpath, _dirnames, filenames in os.walk(base):
            rel_dir = os.path.relpath(dirpath, base)
            for fn in filenames:
                rel = os.path.normpath(os.path.join(rel_dir, fn))
                if is_artifact(rel):
                    continue
                with open(os.path.join(dirpath, fn), "rb") as f:
                    out[rel] = sha256(f.read())
        with open(os.path.join(asset, "dkms.conf"), "rb") as f:
            out["dkms.conf"] = sha256(f.read())
    return out


def ar_members(path):
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("not an ar archive")
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                return
            name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
            size = int(hdr[48:58].decode("ascii").strip())
            data = f.read(size)
            if size % 2:
                f.read(1)
            yield name, data


def deb_data_tar(path):
    """Return the deb's data tarball as a tarfile.TarFile."""
    if shutil.which("dpkg-deb"):
        p = subprocess.run(
            ["dpkg-deb", "--fsys-tarfile", path], capture_output=True, check=False
        )
        if p.returncode != 0:
            raise ValueError(
                "dpkg-deb --fsys-tarfile failed: "
                + p.stderr.decode(errors="replace").strip()
            )
        return tarfile.open(fileobj=io.BytesIO(p.stdout), mode="r:")
    for name, data in ar_members(path):
        if not name.startswith("data.tar"):
            continue
        if name.endswith(".zst"):
            if not shutil.which("zstd"):
                raise ValueError("data.tar.zst needs dpkg-deb or zstd")
            p = subprocess.run(
                ["zstd", "-dc"], input=data, capture_output=True, check=True
            )
            data = p.stdout
            return tarfile.open(fileobj=io.BytesIO(data), mode="r:")
        return tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    raise ValueError("no data.tar member")


def deb_tree(path, prefix):
    """Return {relpath: sha256} for regular files under prefix in the deb."""
    out = {}
    with deb_data_tar(path) as tf:
        for m in tf:
            if not m.isfile():
                continue
            name = m.name
            name = name.removeprefix("./")
            if not name.startswith(prefix):
                continue
            rel = os.path.normpath(name[len(prefix) :])
            if is_artifact(rel):
                continue
            if drv_kver_path(rel):
                continue
            out[rel] = sha256(tf.extractfile(m).read())
    return out


def drv_kver_path(rel):
    first = rel.split("/", 1)[0]
    return "/" in rel and is_kver_dir(first)


def source_digest(tree):
    """One sha256 over the staged source set: sorted '<sha256>  <relpath>' lines."""
    lines = "".join(f"{tree[k]}  {k}\n" for k in sorted(tree))
    return sha256(lines.encode())


def pinned_kver(root):
    path = os.path.join(root, "assets", "kernel-manifest.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)["variants"]["mainline"]["kver"]
    except (OSError, ValueError, KeyError, TypeError):
        return None


def check_overlays(root, drivers, kver):
    """Every <drv>/<kver>/ overlay dir must carry SOURCE.sha256 equal to the
    digest of today's assets/kernel/<drv> source (written by
    build/build-accel-overlays.sh when it compiles the overlay)."""
    failures = 0
    for drv in drivers:
        if not os.path.isfile(os.path.join(root, "assets", "kernel", drv, "dkms.conf")):
            print(f"SKIP {drv}: no assets/kernel/{drv}/dkms.conf")
            continue
        want_tree = expected_tree(root, drv)
        if want_tree is None:
            print(f"SKIP {drv}: no assets/kernel/{drv}/src")
            continue
        want = source_digest(want_tree)
        rel = os.path.join("assets", "kernel", drv, kver)
        stamp = os.path.join(root, rel, "SOURCE.sha256")
        if not os.path.isdir(os.path.join(root, rel)):
            print(f"FAIL {drv}: no overlay dir {rel}/ for the pinned kernel")
            failures += 1
            continue
        try:
            with open(stamp, encoding="utf-8") as f:
                words = f.read().split()
            have = words[0] if words else ""
        except OSError:
            have = None
        if have is None:
            print(
                f"FAIL {drv}: {rel}/SOURCE.sha256 missing; rebuild the overlay with "
                "build/build-accel-overlays.sh so it records the source it compiled"
            )
            failures += 1
        elif have != want:
            print(
                f"FAIL {drv}: {rel} was built from other source "
                f"(stamp {have[:12]}, assets/kernel/{drv} is {want[:12]}); "
                "rebuild with build/build-accel-overlays.sh"
            )
            failures += 1
        else:
            print(f"OK {drv}: {rel} built from current source ({want[:12]})")
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", default=os.environ.get("VERIFY_ROOT"))
    ap.add_argument("--deb-dir")
    ap.add_argument("--driver", action="append", choices=DRIVERS)
    ap.add_argument(
        "--source-digest",
        metavar="DRV",
        choices=DRIVERS,
        help="print the source digest of assets/kernel/DRV and exit",
    )
    ap.add_argument(
        "--overlays",
        nargs="?",
        const="",
        metavar="KVER",
        help="check overlay SOURCE.sha256 stamps instead of debs "
        "(KVER defaults to assets/kernel-manifest.json variants.mainline.kver)",
    )
    args = ap.parse_args()

    root = args.root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if args.source_digest:
        tree = expected_tree(root, args.source_digest)
        if not tree:
            print(f"no source for {args.source_digest} under {root}", file=sys.stderr)
            return 2
        print(source_digest(tree))
        return 0
    if args.overlays is not None:
        kver = args.overlays or pinned_kver(root)
        if not kver:
            print("verify-dkms-deb-sources: overlays: SKIP (no pinned kver)")
            return 0
        failures = check_overlays(root, args.driver or list(DRIVERS), kver)
        if failures:
            print(f"verify-dkms-deb-sources: overlays {kver}: FAIL ({failures})")
            return 1
        print(f"verify-dkms-deb-sources: overlays {kver}: PASS")
        return 0
    deb_dir = args.deb_dir or os.path.join(root, "assets", "cix-debs")
    drivers = args.driver or list(DRIVERS)
    if not os.path.isdir(deb_dir):
        print(f"verify-dkms-deb-sources: deb dir not found: {deb_dir}", file=sys.stderr)
        return 2

    failures = 0
    checked = 0
    for drv in drivers:
        conf = os.path.join(root, "assets", "kernel", drv, "dkms.conf")
        if not os.path.isfile(conf):
            print(f"SKIP {drv}: no {conf}")
            continue
        name = conf_get(conf, "PACKAGE_NAME")
        ver = conf_get(conf, "PACKAGE_VERSION")
        if not name or not ver:
            print(f"FAIL {drv}: {conf} has no PACKAGE_NAME/PACKAGE_VERSION")
            failures += 1
            continue
        debs = sorted(glob.glob(os.path.join(deb_dir, f"{name}-dkms_*.deb")))
        if not debs:
            print(f"SKIP {drv}: no {name}-dkms_*.deb in {deb_dir}")
            continue
        if len(debs) > 1:
            print(
                f"FAIL {drv}: {len(debs)} {name}-dkms debs staged, expected one: "
                + " ".join(os.path.basename(d) for d in debs)
            )
            failures += 1
            continue
        deb = debs[0]
        want = expected_tree(root, drv)
        if want is None:
            print(f"SKIP {drv}: no assets/kernel/{drv}/src")
            continue
        try:
            have = deb_tree(deb, f"usr/src/{name}-{ver}/")
        except (
            ValueError,
            OSError,
            tarfile.TarError,
            subprocess.CalledProcessError,
        ) as e:
            print(f"FAIL {drv}: cannot read {os.path.basename(deb)}: {e}")
            failures += 1
            continue
        checked += 1
        if not have:
            print(
                f"FAIL {drv}: {os.path.basename(deb)} has no usr/src/{name}-{ver}/ "
                "(PACKAGE_VERSION changed since it was built?)"
            )
            failures += 1
            continue
        missing = sorted(set(want) - set(have))
        extra = sorted(set(have) - set(want))
        differ = sorted(k for k in set(want) & set(have) if want[k] != have[k])
        if missing or extra or differ:
            failures += 1
            print(
                f"FAIL {drv}: {os.path.basename(deb)} does not match "
                f"assets/kernel/{drv} (differ={len(differ)} missing={len(missing)} "
                f"extra={len(extra)}); rebuild it with build/build-dkms-debs.sh {drv}"
            )
            for label, items in (
                ("differ", differ),
                ("missing", missing),
                ("extra", extra),
            ):
                for k in items[:20]:
                    print(f"    {label}: {k}")
                if len(items) > 20:
                    print(f"    {label}: ... {len(items) - 20} more")
        else:
            print(
                f"OK {drv}: {os.path.basename(deb)} matches assets/kernel/{drv} ({len(want)} files)"
            )

    if failures:
        print(
            f"verify-dkms-deb-sources: FAIL ({failures} failure(s), {checked} deb(s) read)"
        )
        return 1
    print(f"verify-dkms-deb-sources: PASS ({checked} deb(s) checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
