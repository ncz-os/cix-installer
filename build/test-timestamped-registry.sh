#!/usr/bin/env bash
# test-timestamped-registry.sh -- manifests/ncz-timestamped.tsv must describe the
# artifacts this tree actually ships.
#
# WHY. The registry authorizes build-timestamped NCZ packages by NAME + ARCH + a
# VERSION regex, with the bytes pinned separately by the image receipt.  The
# regex is therefore a shape gate: if it does not match what the producer emits,
# every build fails closed with "unknown origin" and the package can never ship.
#
# That is exactly what happened (measured on HYDRA, cycle 482): both rows required
# ^<ts>+bk0+tgz<hex>$ while build/build-singularity-deb.sh sets GIT_TAG to
# "git<sha8>" when building from a git tree, and the --sources pinned path ships
# the prebuilt ...+bk0+git6427e9c4.  The pinned build could never pass the gate on
# its own registry.
#
# This suite ties the two committed files together: every registry row must match
# the version carried by the artifact the tree ships for that name+arch, so the
# next rename on either side fails here instead of in a 40-minute build.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REG="$ROOT/manifests/ncz-timestamped.tsv"
PAYLOAD="$ROOT/manifests/singularity-payload.tsv"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

[ -s "$REG" ] || { echo "missing $REG"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

python3 - "$ROOT" <<'PY' > /tmp/tsreg.$$ 2>&1
import os, re, sys
root = sys.argv[1]

def rows(path, ncols):
    out = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip() or line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) < ncols:
                print(f"FAIL {os.path.basename(path)}:{n} needs {ncols} columns, has {len(f)}")
                continue
            out.append((n, f))
    return out

reg = rows(os.path.join(root, "manifests/ncz-timestamped.tsv"), 6)
if not reg:
    print("FAIL manifests/ncz-timestamped.tsv has no data rows")
    sys.exit(0)

# What the tree ships, from the payload manifest's filenames:
#   ncz-singularity-desktop_<version>_<arch>.deb
shipped = {}
for n, f in rows(os.path.join(root, "manifests/singularity-payload.tsv"), 3):
    arch, _sha, fn = f[0], f[1], f[2]
    base = fn[:-4] if fn.endswith(".deb") else fn
    parts = base.rsplit("_", 2)
    if len(parts) != 3:
        print(f"FAIL singularity-payload.tsv:{n} filename is not name_version_arch.deb: {fn}")
        continue
    shipped[(parts[0], parts[2])] = parts[1]

checked = 0
for n, f in reg:
    name, rx, arch = f[0], f[1], f[2]
    try:
        compiled = re.compile(rx)
    except re.error as e:
        print(f"FAIL ncz-timestamped.tsv:{n} version_regex does not compile: {e}")
        continue
    ver = shipped.get((name, arch))
    if ver is None:
        print(f"SKIP {name} ({arch}) :: the tree ships no such artifact in singularity-payload.tsv")
        continue
    checked += 1
    if compiled.match(ver):
        print(f"PASS {name} ({arch}) :: registry regex matches the shipped version {ver}")
    else:
        print(f"FAIL {name} ({arch}) :: registry regex {rx} does not match the shipped version {ver}")
        print(f"        the producer emits what the tree ships; the registry row is stale")

if checked == 0:
    print("FAIL no registry row could be checked against a shipped artifact -- this test is vacuous")
PY
rc=$?
while IFS= read -r line; do
    case "$line" in
        PASS*) ok "${line#PASS }" ;;
        FAIL*) bad "${line#FAIL }" ;;
        SKIP*) echo "  SKIP  ${line#SKIP }" ;;
    esac
done < /tmp/tsreg.$$
rm -f /tmp/tsreg.$$

[ "$rc" = 0 ] || bad "the registry/shipped cross-check itself failed (rc=$rc)"
echo "test-timestamped-registry: $pass passed, $fail failed"
[ "$fail" = 0 ]
