#!/bin/bash
# test-stage-amd64-kernel.sh -- build/stage-amd64-kernel.sh must stage the
# EXACT pool build the amd64 manifest pins, not the first same-name match.
#
# Why (2026-11-07, rc4 repin): the kernel-staging pool holds THREE dirs with
# KVER 7.3.1-t2-ncz and linux-image-7.3.1-t2-ncz_7.3.1-r295_amd64.deb:
#   amd64-t2-7.3.1-r295-20261101/          (2026-11-01 build, never booted)
#   amd64-t2-7.3.1-r295-hydra-20261102/    (the build CHIMERA/PEGASUS run)
#   amd64-t2-7.3.1-r295-hydra-20261102-repacked/  (same payload, NCZ Maintainer)
# KVER + PKGVERSION cannot tell them apart and the glob takes the first one, a
# different binary from the one the manifest's sha256 and boot evidence name.
# The manifest's staging_pool_relative now selects the dir, and every staged
# deb must match the manifest's artifacts sha256.
#
# Run: bash build/test-stage-amd64-kernel.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-$HOME}/.stage-amd64-kernel-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

K=7.3.1-t2-ncz; P=7.3.1-r295
POOL="$W/shared/kernel-staging"
mkpooldir() {  # <name> <content-tag>
    local d="$POOL/$1/$K"
    mkdir -p "$d"; printf '%s\n' "$K" > "$d/KVER"; printf '%s\n' "$P" > "$d/PKGVERSION"
    printf '%s-img\n' "$2" > "$d/linux-image-${K}_${P}_amd64.deb"
    printf '%s-hdr\n' "$2" > "$d/linux-headers-${K}_${P}_amd64.deb"
}
mkpooldir amd64-t2-7.3.1-r295-20261101 nov01
mkpooldir amd64-t2-7.3.1-r295-hydra-20261102 hydra
mkpooldir amd64-t2-7.3.1-r295-hydra-20261102-repacked repacked
sha() { sha256sum "$1" | cut -d' ' -f1; }

# mkrepo <dir> <staging_pool_relative or ""> <img-sha> <hdr-sha>
mkrepo() {
    local r="$1" rel="$2" is="$3" hs="$4"
    mkdir -p "$r/build/lib" "$r/assets/kernel/amd64-stable"
    cp "$REPO/build/stage-amd64-kernel.sh" "$r/build/"
    cp "$REPO/build/lib/ncz-site.sh" "$r/build/lib/"
    printf '%s\n' "$K" > "$r/assets/kernel/amd64-stable/KVER"
    printf '%s\n' "$P" > "$r/assets/kernel/amd64-stable/PKGVERSION"
    python3 - "$r/assets/kernel/amd64-stable-manifest.json" "$rel" "$is" "$hs" "$K" "$P" <<'PY'
import json, sys
out, rel, isha, hsha, k, p = sys.argv[1:]
d = {"schema": 1, "kver": k, "package_revision": p, "artifacts": {
    f"linux-image-{k}_{p}_amd64.deb": {"sha256": isha},
    f"linux-headers-{k}_{p}_amd64.deb": {"sha256": hsha}}}
if rel:
    d["staging_pool_relative"] = rel
json.dump(d, open(out, "w"), indent=1)
PY
}
stage() { NCZ_YOCTO_SHARED_DIR="$W/shared" XDG_CONFIG_HOME="$W/noconf" bash "$1/build/stage-amd64-kernel.sh" default 2>&1; }

RP="$POOL/amd64-t2-7.3.1-r295-hydra-20261102-repacked/$K"
RIS=$(sha "$RP/linux-image-${K}_${P}_amd64.deb"); RHS=$(sha "$RP/linux-headers-${K}_${P}_amd64.deb")

echo "=== the manifest's pool dir is staged, not the first same-KVER match ==="
r="$W/r1"; mkrepo "$r" "kernel-staging/amd64-t2-7.3.1-r295-hydra-20261102-repacked/$K" "$RIS" "$RHS"
out=$(stage "$r"); rc=$?
got=$(cat "$r/assets/kernel/amd64-stable/linux-image-${K}_${P}_amd64.deb" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$got" = repacked-img ]; then ok "staged the repacked dir named by staging_pool_relative"
else bad "staged '$got' (rc=$rc), wanted repacked-img" "$out"; fi

echo "=== a staged deb whose sha256 differs from the manifest is refused ==="
r="$W/r2"; mkrepo "$r" "kernel-staging/amd64-t2-7.3.1-r295-hydra-20261102-repacked/$K" "$(printf '%064d' 0)" "$RHS"
out=$(stage "$r"); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q sha256 \
   && ! ls "$r/assets/kernel/amd64-stable/"*.deb >/dev/null 2>&1; then
    ok "sha256 mismatch refused and nothing left staged (rc=$rc)"
else bad "sha256 mismatch not refused cleanly (rc=$rc)" "$out"; fi

echo "=== a manifest naming a pool dir that does not exist is refused ==="
r="$W/r3"; mkrepo "$r" "kernel-staging/amd64-t2-7.3.1-r295-gone/$K" "$RIS" "$RHS"
out=$(stage "$r"); rc=$?
[ "$rc" != 0 ] && ok "missing manifest pool dir refused (rc=$rc)" || bad "missing manifest pool dir accepted" "$out"

echo "=== a manifest pool path outside kernel-staging/ is refused ==="
r="$W/r4"; mkrepo "$r" "../../etc/$K" "$RIS" "$RHS"
out=$(stage "$r"); rc=$?
[ "$rc" != 0 ] && ok "pool path outside kernel-staging refused (rc=$rc)" || bad "pool path outside kernel-staging accepted" "$out"

echo "=== AMD64_SRC override still wins, and is still sha256-checked ==="
r="$W/r5"; mkrepo "$r" "kernel-staging/amd64-t2-7.3.1-r295-hydra-20261102-repacked/$K" "$RIS" "$RHS"
out=$(AMD64_SRC="$POOL/amd64-t2-7.3.1-r295-20261101/$K" stage "$r"); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q sha256 \
    && ok "AMD64_SRC pointing at another build is refused by the sha256 check (rc=$rc)" \
    || bad "AMD64_SRC to a different build was staged" "$out"

echo "=== the 7.4 kernel line stages (operator 2026-11-09 22:20Z: kernel line = 7.4.x) ==="
K74=7.4.0-rc2-t2-ncz; P74=7.4.0-rc2-2
D74="$POOL/amd64-t2-rc2-20261109/$K74"; mkdir -p "$D74"
printf '%s\n' "$K74" > "$D74/KVER"; printf '%s\n' "$P74" > "$D74/PKGVERSION"
printf 'img74\n' > "$D74/linux-image-${K74}_${P74}_amd64.deb"
printf 'hdr74\n' > "$D74/linux-headers-${K74}_${P74}_amd64.deb"
r="$W/r74"; mkdir -p "$r/build/lib" "$r/assets/kernel/amd64-stable"
cp "$REPO/build/stage-amd64-kernel.sh" "$r/build/"
cp "$REPO/build/lib/ncz-site.sh" "$r/build/lib/"
printf '%s\n' "$K74" > "$r/assets/kernel/amd64-stable/KVER"
printf '%s\n' "$P74" > "$r/assets/kernel/amd64-stable/PKGVERSION"
I74=$(sha "$D74/linux-image-${K74}_${P74}_amd64.deb"); H74=$(sha "$D74/linux-headers-${K74}_${P74}_amd64.deb")
python3 - "$r/assets/kernel/amd64-stable-manifest.json" "$I74" "$H74" "$K74" "$P74" <<'PY'
import json, sys
out, isha, hsha, k, p = sys.argv[1:]
json.dump({"schema": 1, "kver": k, "package_revision": p,
           "staging_pool_relative": f"kernel-staging/amd64-t2-rc2-20261109/{k}",
           "artifacts": {f"linux-image-{k}_{p}_amd64.deb": {"sha256": isha},
                         f"linux-headers-{k}_{p}_amd64.deb": {"sha256": hsha}}}, open(out, "w"), indent=1)
PY
out=$(stage "$r"); rc=$?
got=$(cat "$r/assets/kernel/amd64-stable/linux-image-${K74}_${P74}_amd64.deb" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$got" = img74 ]; then ok "7.4.0-rc2-t2-ncz staged (7.4 kernel line accepted)"
else bad "7.4 kernel rejected by the series guard (rc=$rc)" "$out"; fi

echo "=== the real manifest names an existing pool dir form and pins both debs ==="
python3 - "$REPO/assets/kernel/amd64-stable-manifest.json" <<'PY' && ok "real manifest: staging_pool_relative + image/headers sha256 present" || bad "real manifest lacks staging_pool_relative or deb sha256"
import json, sys
d = json.load(open(sys.argv[1]))
k, p = d["kver"], d["package_revision"]
rel = d.get("staging_pool_relative", "")
assert rel.startswith("kernel-staging/") and ".." not in rel.split("/"), rel
for n in (f"linux-image-{k}_{p}_amd64.deb", f"linux-headers-{k}_{p}_amd64.deb"):
    s = d["artifacts"][n]["sha256"]
    assert len(s) == 64 and all(c in "0123456789abcdef" for c in s), n
PY

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
