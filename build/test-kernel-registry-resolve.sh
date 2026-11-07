#!/bin/bash
# test-kernel-registry-resolve.sh -- build-time kernel resolution from the kernel-ci registry.
# Builds throwaway registries (same checksum + hash-chain format kernel-ci writes) in a scratch
# dir and checks build/resolve-kernel-from-registry.py and its wiring into the build scripts.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/build/resolve-kernel-from-registry.py"
W="$(mktemp -d "${TMPDIR:-$ROOT/build}/.kreg-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }

mkreg() {  # mkreg <out> <amd64-current> <amd64-retired-csv> [tamper|break-history|retired-current]
    python3 - "$@" <<'PY'
import hashlib, json, sys
out, cur, retired = sys.argv[1], sys.argv[2], [r for r in sys.argv[3].split(",") if r]
mode = sys.argv[4] if len(sys.argv) > 4 else ""
c = lambda o: json.dumps(o, sort_keys=True, separators=(",", ":")).encode()
kver, rev = cur.rsplit("+", 1)
t2 = {"arch": "amd64", "current": cur, "retired": [dict(zip(("kver", "rev"), r.rsplit("+", 1))) for r in retired],
      "builds": {cur: {"kver": kver, "rev": rev, "state": "current", "staged_dir": "/pool/" + cur, "source": {}}}}
sky = {"arch": "arm64", "current": "7.3.0-sky1-ncz+r293", "retired": [],
       "builds": {"7.3.0-sky1-ncz+r293": {"kver": "7.3.0-sky1-ncz", "rev": "r293", "state": "current",
                  "staged_dir": "/pool/r292", "source": {"release": "r292-7.3.0-sky1-ncz-20261023"}}}}
if mode == "retired-current":
    t2["retired"].append({"kver": kver, "rev": rev})
rec = {"seq": 1, "at": "x", "action": "seed", "tree": "t2-amd64", "actor": "t", "prev": ""}
rec["hash"] = hashlib.sha256(c(rec)).hexdigest()
doc = {"schema": 1, "trees": {"t2-amd64": t2, "sky1-arm64": sky}, "history": [rec]}
if mode == "break-history":
    rec["actor"] = "someone else"
doc["checksum"] = hashlib.sha256(c(doc)).hexdigest()
if mode == "tamper":
    doc["trees"]["t2-amd64"]["current"] = "7.9.9-t2-ncz+r999"
open(out, "w").write(json.dumps(doc))
PY
}
mkroot() {  # a tree with committed pins: amd64 <kver> <pkgversion>
    mkdir -p "$W/root/assets/kernel/amd64-stable"
    echo "$1" > "$W/root/assets/kernel/amd64-stable/KVER"
    echo "$2" > "$W/root/assets/kernel/amd64-stable/PKGVERSION"
    echo "r292-7.3.0-sky1-ncz-20261023" > "$W/root/assets/kernel/mainline.release"
}
res() { python3 "$R" --root "$W/root" "$@" 2>"$W/err"; }

mkroot 7.3.0-t2-ncz 7.3.0-2
mkreg "$W/reg.json" "7.3.1-t2-ncz+r295" "7.3.0-t2-ncz+*"
out="$(res --arch amd64 --registry "$W/reg.json")" && grep -qx "NCZ_KERNEL_KVER=7.3.1-t2-ncz" <<<"$out" \
    && grep -qx "NCZ_KERNEL_PKGVERSION=7.3.1-r295" <<<"$out" && grep -qx "NCZ_KERNEL_SOURCE=registry" <<<"$out" \
    && grep -qx "NCZ_KERNEL_STAGED_DIR=/pool/7.3.1-t2-ncz+r295" <<<"$out" && grep -qx "NCZ_KERNEL_PIN_DRIFT=1" <<<"$out" \
    && ok "registry current wins over a stale committed pin" || no "registry current: $out $(cat "$W/err")"
out="$(res --arch arm64 --registry "$W/reg.json")" && grep -qx "NCZ_KERNEL_RELEASE=r292-7.3.0-sky1-ncz-20261023" <<<"$out" \
    && ok "arm64 resolves the Sky1 staging release" || no "arm64: $out"
res --arch amd64 --registry "$W/missing.json" >/dev/null; [ $? -eq 3 ] && ok "missing registry refused without the flag" || no "missing registry"
out="$(res --arch amd64 --registry "$W/missing.json" --allow-committed-manifests)" && grep -qx "NCZ_KERNEL_SOURCE=committed-manifests" <<<"$out" \
    && ok "--allow-committed-manifests falls back when the registry is absent" || no "fallback: $out"
res --arch amd64 --registry "$W/reg.json" --allow-committed-manifests >/dev/null; [ $? -eq 3 ] && grep -q RETIRED "$W/err" \
    && ok "fallback refuses a committed pin the registry retired" || no "retired fallback $(cat "$W/err")"
mkroot 7.3.1-t2-ncz 7.3.1-r295
out="$(res --arch amd64 --registry "$W/reg.json" --allow-committed-manifests)" && grep -qx "NCZ_KERNEL_KVER=7.3.1-t2-ncz" <<<"$out" \
    && ok "fallback accepts a live committed pin" || no "live fallback: $out $(cat "$W/err")"
for mode in tamper break-history retired-current; do
    mkreg "$W/bad.json" "7.3.1-t2-ncz+r295" "" "$mode"
    res --arch amd64 --registry "$W/bad.json" >/dev/null; [ $? -eq 3 ] && ok "refused: $mode" || no "accepted $mode"
done
grep -q 'resolve-kernel-from-registry.py' "$ROOT/build/build-image.sh" && grep -q -- '--kernel-from-manifests' "$ROOT/build/build-image.sh" \
    && ok "build-image.sh resolves the kernel from the registry" || no "build-image.sh wiring"
grep -q 'NCZ_KERNEL_KVER' "$ROOT/build/stage-amd64-kernel.sh" && grep -q 'NCZ_KERNEL_STAGED_DIR' "$ROOT/build/stage-amd64-kernel.sh" \
    && ok "stage-amd64-kernel.sh stages the resolved kernel" || no "stage-amd64-kernel.sh wiring"
grep -q 'NCZ_KERNEL_RELEASE' "$ROOT/build/link-kernel-mainline.sh" && ok "link-kernel-mainline.sh links the resolved release" || no "link wiring"
echo "test-kernel-registry-resolve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
