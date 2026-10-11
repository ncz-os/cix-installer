#!/bin/bash
# test-firmware-arch-bom.sh -- the arch-scoped firmware closure gate.
#
# Proves, with fabricated real .debs (dpkg-deb) and a synthetic published
# index, that build/verify-firmware-bom.sh accepts the arm64 trim
# (manifests/firmware-arm64.pkgs + manifests/firmware-bom-arm64.allow) AND the
# unchanged amd64 BOM (manifests/firmware.pkgs), and rejects every way the two
# can drift from the published set. Also asserts the wiring: the arm64 keep set
# and exclude list exactly partition manifests/firmware.pkgs, and the mirror /
# install / initrd builders and the target verifier select the arch-scoped BOM.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/build/verify-firmware-bom.sh"
FULL="$ROOT/manifests/firmware.pkgs"
AKEEP="$ROOT/manifests/firmware-arm64.pkgs"
AALLOW="$ROOT/manifests/firmware-bom-arm64.allow"
PASS=0; FAIL=0
ok()  { echo "PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/fwbom-arch.XXXXXX")"
trap 'rm -rf "$W"' EXIT

list() { sed 's/#.*//' "$1" | awk 'NF {print $1}' | sort -u; }

# --- 1. the arm64 keep set and exclude list partition the full BOM ----------
if [ -f "$AKEEP" ] && [ -f "$AALLOW" ]; then
    if [ -z "$(comm -12 <(list "$AKEEP") <(list "$AALLOW"))" ]; then
        ok "arm64 keep and exclude lists are disjoint"
    else
        bad "a package is both kept and dropped on arm64"
    fi
    if diff <(list "$FULL") <(cat <(list "$AKEEP") <(list "$AALLOW") | sort -u) >/dev/null; then
        ok "arm64 keep U exclude == firmware.pkgs"
    else
        bad "arm64 keep U exclude != firmware.pkgs"
        diff <(list "$FULL") <(cat <(list "$AKEEP") <(list "$AALLOW") | sort -u) | sed 's/^/      /'
    fi
else
    bad "manifests/firmware-arm64.pkgs or firmware-bom-arm64.allow missing"
fi

# --- 2. synthetic mirror: a real .deb per full-BOM package + published index -
mkdir -p "$W/mirror/pool/main" "$W/mirror/.ncz-published-packages/arm64" "$W/mirror/.ncz-published-packages/amd64" "$W/pub"
for p in $(list "$FULL"); do
    d="$W/tree/$p"; mkdir -p "$d/DEBIAN"
    printf 'Package: %s\nVersion: 20260916-1\nArchitecture: all\nMaintainer: t <t@x.invalid>\nDescription: fixture\n' "$p" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -Zgzip -b "$d" "$W/mirror/pool/main/${p}_20260916-1_all.deb" >/dev/null
done
# firmware-*.deb are Architecture: all, so the arm64 and amd64 published
# firmware name sets are identical -- one index serves both.
{ for p in $(list "$FULL"); do printf 'Package: %s\nVersion: 20260916-1\nArchitecture: all\n\n' "$p"; done; } > "$W/pub/Packages"
for a in arm64 amd64; do cp "$W/pub/Packages" "$W/mirror/.ncz-published-packages/$a/Packages"; done

expect_pass() { # <arch> [label]
    local out rc
    out="$(bash "$VERIFY" --mirror "$W/mirror" --arch "$1" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then ok "${2:-$1} closure gate PASSES ($(printf '%s' "$out" | sed 's/.*PASS: //'))"
    else bad "${2:-$1} closure gate unexpectedly failed: $out"; fi
}

expect_pass arm64 "arm64 trimmed BOM"
expect_pass amd64 "unchanged amd64 BOM"

# --- 3. negatives: every drift path must fail closed ------------------------
neg() { # <label> <expected-regex> <args...>
    local label="$1" re="$2"; shift 2
    local out rc
    out="$(bash "$VERIFY" "$@" 2>&1)"; rc=$?
    if [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q -- "$re"; then ok "$label"
    else bad "$label (rc=$rc): $out"; fi
}

# 3a. a published firmware package in neither the BOM nor the allow-list
{ cat "$W/pub/Packages"; printf 'Package: firmware-example-extra\nVersion: 1\nArchitecture: all\n\n'; } > "$W/pub/Packages-extra"
neg "published-but-unaccounted package fails" "missing from" \
    --mirror "$W/mirror" --arch arm64 --published-index "$W/pub/Packages-extra"

# 3b. allow-list names a package not published for the arch
printf '# fixture\nfirmware-not-published-anywhere\n' > "$W/pub/bogus.allow"
neg "allow-list naming an unpublished package fails" "not published" \
    --mirror "$W/mirror" --arch arm64 --allow-list "$W/pub/bogus.allow"

# 3c. a package declared (kept) and also allowed (dropped) -- contradictory
{ list "$AKEEP"; echo firmware-qcom-dsp; } > "$W/pub/overlap.pkgs"
neg "declared and allowed overlap fails" "also present in" \
    --mirror "$W/mirror" --arch arm64 --bom "$W/pub/overlap.pkgs"

# 3d. a required package absent from the mirror pool
mkdir -p "$W/short"
cp -a "$W/mirror/.ncz-published-packages" "$W/short/"
mkdir -p "$W/short/pool/main"
for p in $(list "$AKEEP"); do cp "$W/mirror/pool/main/${p}_"*_all.deb "$W/short/pool/main/"; done
neg "required package missing from the pool fails" "missing published firmware" \
    --mirror "$W/short" --arch amd64

# --- 4. wiring: every builder/verifier honours the arch-scoped BOM ----------
grep -q '_seed_for firmware' "$ROOT/build/build-forky-mirror.sh" \
    && ok "mirror builder seeds _seed_for firmware" \
    || bad "build-forky-mirror.sh does not use _seed_for firmware"
grep -q '_seed_manifest_for firmware' "$ROOT/build/verify-offline-mirror-seeds.sh" \
    && ok "offline-mirror seed verifier is arch-scoped" \
    || bad "verify-offline-mirror-seeds.sh is not arch-scoped"
grep -q 'firmware-\$_fw_arch.pkgs' "$ROOT/post-install/13-firmware-bom.sh" \
    && ok "install hook selects the arch-scoped BOM" \
    || bad "13-firmware-bom.sh does not select the arch-scoped BOM"
grep -q 'firmware-\$ARCH.pkgs' "$ROOT/build/build-installer-image.sh" \
    && ok "installer initrd builder passes the arch-scoped BOM" \
    || bad "build-installer-image.sh does not pass the arch-scoped BOM"
grep -q 'firmware-\$ARCH.pkgs' "$ROOT/build/verify-installed-target.sh" \
    && ok "installed-target verifier is arch-scoped" \
    || bad "verify-installed-target.sh does not select the arch-scoped BOM"

echo "--- test-firmware-arch-bom: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
