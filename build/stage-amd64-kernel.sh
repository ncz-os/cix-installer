#!/bin/bash
# Stage only the committed, hash-bound amd64 release image/headers pair.
# No filename search, package rename, or KVER-sidecar-only authorization.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-default}" in
    default|stable|all|"") ;;
    edge) echo "ERROR: amd64 edge channel is retired" >&2; exit 2 ;;
    *) echo "usage: $0 [default|stable|all]" >&2; exit 2 ;;
esac
manifest="$ROOT/assets/kernel/amd64-stable-manifest.json"
pin_file="$ROOT/assets/kernel/amd64-stable/KVER"
[ -s "$manifest" ] && [ -s "$pin_file" ] || {
    echo "ERROR: committed amd64 manifest or KVER missing" >&2; exit 1;
}
wanted=$(tr -d '[:space:]' < "$pin_file")
pool=$(python3 - "$manifest" "$wanted" <<'PY'
import json
import sys
from pathlib import PurePosixPath

m = json.load(open(sys.argv[1], encoding="utf-8"))
kver = sys.argv[2]
if m.get("arch") != "amd64" or m.get("kver") != kver:
    sys.exit("ERROR: manifest arch/KVER disagrees with committed pin")
if not kver.startswith("7.3.") or m.get("identity", {}).get("kernel_release") != kver:
    sys.exit("ERROR: manifest is not the pinned unified 7.3 kernel")
pool = m.get("staging_pool_relative", "")
p = PurePosixPath(pool)
if p.is_absolute() or ".." in p.parts or not p.parts or p.parts[0] != "kernel-staging":
    sys.exit("ERROR: invalid committed kernel pool path")
print(pool)
PY
)
src="${AMD64_SRC:-}"
if [ -z "$src" ]; then
    for shared in /mnt/argonas/datapool/yocto-shared /mnt/argonas-yocto-shared /mnt/yocto-shared; do
        [ -d "$shared/$pool" ] || continue
        src="$shared/$pool"
        break
    done
fi
[ -n "$src" ] && [ -d "$src" ] || {
    echo "ERROR: pinned kernel pool unavailable: $pool" >&2; exit 1;
}
verify_payload() {
    python3 - "$manifest" "$wanted" "$1" <<'PY'
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

m = json.load(open(sys.argv[1], encoding="utf-8"))
kver, root = sys.argv[2], Path(sys.argv[3])
identity = m["identity"]
expected = {}
for kind in ("image", "headers"):
    package = identity[f"{kind}_deb_package"]
    version = identity[f"{kind}_deb_version"]
    if package != f"linux-{kind}-{kver}":
        sys.exit("ERROR: kernel package name disagrees with KVER")
    expected[f"{package}_{version}_amd64.deb"] = (package, version)
names = set(expected) | {f"kernel_config_{kver}", f"PROVENANCE-{kver}"}
if set(m.get("artifacts", {})) != names:
    sys.exit("ERROR: manifest must bind exactly image, headers, config and provenance")
for name in sorted(names):
    if Path(name).name != name:
        sys.exit("ERROR: unsafe artifact basename")
    f = root / name
    row = m["artifacts"][name]
    if f.is_symlink() or not f.is_file():
        sys.exit(f"ERROR: missing or symlinked artifact: {f}")
    digest = row.get("sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or f.stat().st_size != row.get("size"):
        sys.exit(f"ERROR: artifact size/hash metadata mismatch: {name}")
    h = hashlib.sha256()
    with f.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    if h.hexdigest() != digest:
        sys.exit(f"ERROR: artifact SHA256 mismatch: {name}")
    if name in expected:
        package, version = expected[name]
        for field, value in (("Package", package), ("Version", version), ("Architecture", "amd64")):
            got = subprocess.check_output(["dpkg-deb", "-f", str(f), field], text=True).strip()
            if got != value:
                sys.exit(f"ERROR: {name} control {field} mismatch")
provenance = (root / f"PROVENANCE-{kver}").read_text()
for key, value in (("kernel_release", kver), ("anfe_wunner_test", "0"),
                   ("source_commit", m["source"]["base_commit"]),
                   ("t2_repo_commit", m["source"]["t2_repo_commit"])):
    if provenance.splitlines().count(f"{key}={value}") != 1:
        sys.exit(f"ERROR: provenance {key} disagrees with committed manifest")
sidecar = root / "KVER"
if sidecar.exists() and sidecar.read_text().strip() != kver:
    sys.exit("ERROR: optional source KVER sidecar disagrees")
PY
}
# Validate everything BEFORE touching any prior staged candidate files.
verify_payload "$src"
dest="$ROOT/assets/kernel/amd64-stable"
mkdir -p "$dest"
# Only the explicitly named image and headers are staged; never glob-copy
# linux-libc-dev or the >1GiB debug package into the installer kernel payload.
staged_debs=()
for kind in image headers; do
    name=$(python3 - "$manifest" "$kind" <<'PY'
import json
import sys
m = json.load(open(sys.argv[1], encoding="utf-8"))["identity"]
kind = sys.argv[2]
print(f'{m[f"{kind}_deb_package"]}_{m[f"{kind}_deb_version"]}_amd64.deb')
PY
)
    staged_debs+=("$name")
    cp -f -- "$src/$name" "$dest/$name"
done
cp -f -- "$src/kernel_config_$wanted" "$src/PROVENANCE-$wanted" "$dest/"
verify_payload "$dest"
# Preserve the tracked pin; remove only obsolete debs from this staging dir
# after the complete new payload has been copied and checked.
for old in "$dest"/linux-image-*_amd64.deb "$dest"/linux-headers-*_amd64.deb; do
    [ -f "$old" ] || continue
    case "${old##*/}" in
        "${staged_debs[0]}"|"${staged_debs[1]}") ;;
        *) rm -f -- "$old" ;;
    esac
done
echo "[stage-amd64-kernel] verified committed payload: $wanted"
