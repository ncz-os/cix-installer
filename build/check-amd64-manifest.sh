#!/bin/bash
# Fail-closed drift check: re-hash the staged amd64 pool debs against the
# hand-authored manifest. Run in CI / before image builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/assets/kernel/amd64-stable-manifest.json"
python3 - "$M" <<'PY'
import json, subprocess, sys, glob, os
m = json.load(open(sys.argv[1]))
pool = os.path.join("/mnt/argonas/datapool/yocto-shared", m["staging_pool_relative"])
imgs = glob.glob(os.path.join(pool, "linux-image-*.deb"))
hdrs = glob.glob(os.path.join(pool, "linux-headers-*.deb"))
assert len(imgs) == 1 and len(hdrs) == 1, f"pool must hold exactly 1 image + 1 headers deb (found {len(imgs)} / {len(hdrs)})"
for want in m["kernel_debs"]:
    f = os.path.join(pool, os.path.basename(want["file"]))
    assert os.path.exists(f), f"missing {f}"
    got = subprocess.check_output(["sha256sum", f]).decode().split()[0]
    assert got == want["sha256"], f"sha256 drift for {f}: manifest {want['sha256']} != pool {got}"
print("check-amd64-manifest: PASS (pair count + sha256s match)")
PY
