#!/bin/bash
# Fail-closed drift check: re-hash the staged amd64 pool debs against the
# sha256s recorded in manifests/ncz-packages.tsv (the hash authority; the
# amd64-stable manifest pins the build, the tsv pins the artifacts) and
# assert build-level coherence across the pin files. CI / pre-image-build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import csv, glob, os, subprocess, sys
root = sys.argv[1]
m = {}
for line in open(os.path.join(root, "assets/kernel/amd64-stable-manifest.json")):
    pass
import json
m = json.load(open(os.path.join(root, "assets/kernel/amd64-stable-manifest.json")))
kver = open(os.path.join(root, "assets/kernel/amd64-stable/KVER")).read().strip()
pkgv = open(os.path.join(root, "assets/kernel/amd64-stable/PKGVERSION")).read().strip()
assert kver == m["kver"], f"KVER file {kver} != manifest kver {m['kver']}"
assert pkgv == m["package_revision"], f"PKGVERSION {pkgv} != manifest package_revision {m['package_revision']}"
pool = os.path.join("/mnt/argonas/datapool/yocto-shared", m["staging_pool_relative"])
imgs = glob.glob(os.path.join(pool, "linux-image-*.deb"))
hdrs = glob.glob(os.path.join(pool, "linux-headers-*.deb"))
assert len(imgs) == 1 and len(hdrs) == 1, f"pool must hold exactly 1 image + 1 headers deb (found {len(imgs)} / {len(hdrs)})"
tsv = {}
with open(os.path.join(root, "manifests/ncz-packages.tsv")) as f:
    for row in csv.reader(f, delimiter="\t"):
        if len(row) >= 4 and row[0] in ("linux-image-7.3.3-t2-ncz", "linux-headers-7.3.3-t2-ncz"):
            tsv[row[0]] = (row[1], row[3])
assert set(tsv) == {"linux-image-7.3.3-t2-ncz", "linux-headers-7.3.3-t2-ncz"}, f"tsv kernel rows incomplete: {set(tsv)}"
for deb, want_sha in ((imgs[0], tsv["linux-image-7.3.3-t2-ncz"][1]), (hdrs[0], tsv["linux-headers-7.3.3-t2-ncz"][1])):
    got = subprocess.check_output(["sha256sum", deb]).decode().split()[0]
    assert got == want_sha, f"sha256 drift for {deb}: tsv {want_sha} != pool {got}"
for name, (ver, _) in tsv.items():
    assert ver == pkgv, f"tsv {name} version {ver} != PKGVERSION {pkgv}"
print("check-amd64-manifest: PASS (pair count + sha256s + version coherence)")
PY
