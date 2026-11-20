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
pool = os.path.join(os.environ.get("NCZ_KERNEL_POOL_ROOT", os.path.join(root, "downloads")), m["staging_pool_relative"])
if not os.path.isdir(pool) and not (m.get("artifacts") or {}):
    # Transitional-state rule: the ledger may carry the explicit NULL
    # placeholder (never an empty field) for the not-yet-staged -2 build, but
    # once the pool exists the real sha256s must be present in both places.
    print(f"check-amd64-manifest: BLOCKED: the pinned amd64 build ({kver} {pkgv}) is not staged yet: {pool} does not exist", file=sys.stderr)
    print("                    and the manifest records no deb sha256s (notes_missing_hashes); the ledger "
          "rows carry the NULL placeholder (see manifests/ncz-packages.tsv header). Stage it "
          "(build/stage-amd64-kernel.sh) and record the -2 hashes before any image build.", file=sys.stderr)
    sys.exit(2)
imgs = glob.glob(os.path.join(pool, "linux-image-*.deb"))
hdrs = glob.glob(os.path.join(pool, "linux-headers-*.deb"))
assert len(imgs) == 1 and len(hdrs) == 1, f"pool must hold exactly 1 image + 1 headers deb (found {len(imgs)} / {len(hdrs)})"
tsv = {}
with open(os.path.join(root, "manifests/ncz-packages.tsv")) as f:
    for row in csv.reader(f, delimiter="\t"):
        if len(row) >= 4 and row[0] in (f"linux-image-{kver}", f"linux-headers-{kver}"):
            tsv[row[0]] = (row[1], row[3])
want_rows = {f"linux-image-{kver}", f"linux-headers-{kver}"}
assert set(tsv) == want_rows, f"tsv kernel rows incomplete: {set(tsv)}"
for deb, want_sha in ((imgs[0], tsv[f"linux-image-{kver}"][1]), (hdrs[0], tsv[f"linux-headers-{kver}"][1])):
    got = subprocess.check_output(["sha256sum", deb]).decode().split()[0]
    assert got == want_sha, f"sha256 drift for {deb}: tsv {want_sha} != pool {got}"
for name, (ver, _) in tsv.items():
    assert ver == pkgv, f"tsv {name} version {ver} != PKGVERSION {pkgv}"
print("check-amd64-manifest: PASS (pair count + sha256s + version coherence)")
PY
