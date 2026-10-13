#!/bin/bash
# test-vendor-alias.sh -- build/lib/vendor_alias.py resolves a vendor alias through a signed
# index, stages the newest deb, records it in the ledgers, is idempotent, and refuses every
# broken link of the chain. Hermetic: a local file:// repository signed by a throwaway key.
# Also checks the committed ledgers: every alias row is recorded with the same bytes in
# vendor-debs.tsv and build-inputs.tsv, and the builders use the pinned staged deb.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }
for t in gpg gpgv dpkg dpkg-deb sha256sum python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not available"; exit 0; }
done
T="$(mktemp -d "${TMPDIR:-/var/tmp}/valias.XXXXXX")"
export GNUPGHOME="$T/g"; mkdir -m 700 "$GNUPGHOME"
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1; rm -rf "$T"' EXIT
PY=(python3 -I "$ROOT/build/lib/vendor_alias.py")

gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'test repo <t@example.invalid>' rsa2048 sign never >/dev/null 2>&1
FPR="$(gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[ -n "$FPR" ] || { echo "SKIP: cannot create a test key"; exit 0; }
gpg --batch --armor --export "$FPR" > "$T/key.asc"

mkdeb() {   # <pkg> <ver> <arch> <out>
    local d="$T/b-$1-$2-$3"; mkdir -p "$d/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: t\n' "$1" "$2" "$3" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$d" "$4" >/dev/null
}
R="$T/repo"; mkdir -p "$R/pool" "$R/dists/stable/main/binary-amd64" "$R/dists/stable/main/binary-arm64"
mkrepo() {  # <mode inrelease|release> <versions...>; newest is not listed last on purpose
    local mode="$1"; shift
    local a v f
    for a in amd64 arm64; do
        : > "$R/dists/stable/main/binary-$a/Packages"
        for v in "$@"; do
            f="pool/browser-stable_${v}_$a.deb"; [ -f "$R/$f" ] || mkdeb browser-stable "$v" "$a" "$R/$f"
            printf 'Package: browser-stable\nVersion: %s\nArchitecture: %s\nFilename: %s\nSize: %s\nSHA256: %s\n\n' \
                "$v" "$a" "$f" "$(stat -c %s "$R/$f")" "$(sha256sum "$R/$f" | cut -d' ' -f1)" >> "$R/dists/stable/main/binary-$a/Packages"
        done
        f="pool/browser-snapshot_99.0-1_$a.deb"; [ -f "$R/$f" ] || mkdeb browser-snapshot 99.0-1 "$a" "$R/$f"
        printf 'Package: browser-snapshot\nVersion: 99.0-1\nArchitecture: %s\nFilename: %s\nSize: 1\nSHA256: %s\n\n' "$a" "$f" "$(printf '0%.0s' {1..64})" >> "$R/dists/stable/main/binary-$a/Packages"
    done
    {
        printf 'Origin: test\nSuite: stable\nArchitectures: amd64 arm64\nComponents: main\nSHA256:\n'
        for a in amd64 arm64; do
            f="$R/dists/stable/main/binary-$a/Packages"
            printf ' %s %s main/binary-%s/Packages\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")" "$a"
        done
    } > "$R/dists/stable/Release"
    rm -f "$R/dists/stable/InRelease" "$R/dists/stable/Release.gpg"
    if [ "$mode" = inrelease ]; then
        gpg --batch --pinentry-mode loopback --passphrase '' -u "$FPR" --clearsign -o "$R/dists/stable/InRelease" "$R/dists/stable/Release"
    else
        gpg --batch --pinentry-mode loopback --passphrase '' -u "$FPR" --detach-sign -o "$R/dists/stable/Release.gpg" "$R/dists/stable/Release"
    fi
}
mktree() {  # <mode> <fpr>: a minimal repo root carrying the ledgers the tool rewrites
    local W="$T/root"; rm -rf "$W"; mkdir -p "$W/manifests" "$W/build" "$W/sbom"
    cp "$T/key.asc" "$W/build/test-keyring.asc"
    printf 'browser-stable\tfile://%s\tstable\tmain\t%s\tbuild/test-keyring.asc\t%s\tassets/browser\tamd64,arm64\tTest Vendor\ttest browser\n' "$R" "$1" "$2" > "$W/manifests/vendor-aliases.tsv"
    printf 'browser-stable\t1.0-1\tamd64\tTest Vendor\thttps://example.invalid/a.deb\t%s\told\nbrowser-stable\t1.0-1\tarm64\tTest Vendor\thttps://example.invalid/b.deb\t%s\told\n' \
        "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" > "$W/manifests/vendor-debs.tsv"
    printf 'amd64\tassets/other.bin\t%s\t1\tother\namd64\tassets/browser/browser-stable_1.0-1_amd64.deb\t%s\t1\told\narm64\tassets/browser/browser-stable_1.0-1_arm64.deb\t%s\t1\told\n' \
        "$(printf 'c%.0s' {1..64})" "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" > "$W/manifests/build-inputs.tsv"
    printf '# sbom\nassets/browser/browser-stable_1.0-1_arm64.deb|1|%s\n' "$(printf 'b%.0s' {1..64})" > "$W/sbom/expected-assets.txt"
    mkdir -p "$W/assets/browser"; mkdeb browser-stable 1.0-1 amd64 "$W/assets/browser/browser-stable_1.0-1_amd64.deb"
    echo "$W"
}

for mode in inrelease release; do
    mkrepo "$mode" 1.10-1 1.9-1 1.2-1
    W="$(mktree "$mode" "$FPR")"
    "${PY[@]}" check "$W" browser-stable >/dev/null 2>&1; rc=$?
    [ "$rc" = 10 ] && ok "[$mode] check reports a pin behind its alias (exit 10)" || bad "[$mode] check exit $rc, expected 10"
    if "${PY[@]}" refresh "$W" browser-stable > "$T/out" 2>&1; then ok "[$mode] refresh succeeds"; else bad "[$mode] refresh failed: $(tail -3 "$T/out")"; fi
    v="$(awk -F'\t' '$1=="browser-stable" && $3=="amd64"{print $2}' "$W/manifests/vendor-debs.tsv")"
    [ "$v" = 1.10-1 ] && ok "[$mode] newest version by dpkg ordering (1.10-1 > 1.9-1)" || bad "[$mode] resolved $v"
    s="$(sha256sum "$R/pool/browser-stable_1.10-1_arm64.deb" | cut -d' ' -f1)"
    grep -q "^browser-stable	1.10-1	arm64	Test Vendor	file://$R/pool/browser-stable_1.10-1_arm64.deb	$s	test browser; alias browser-stable" "$W/manifests/vendor-debs.tsv" \
        && ok "[$mode] vendor-debs row records alias, resolved version, URL and sha256" || bad "[$mode] vendor-debs row wrong"
    grep -q "^arm64	assets/browser/browser-stable_1.10-1_arm64.deb	$s	" "$W/manifests/build-inputs.tsv" && ok "[$mode] build-inputs row rewritten" || bad "[$mode] build-inputs row"
    [ "$(grep -c 'assets/browser/' "$W/manifests/build-inputs.tsv")" = 2 ] && grep -q '^amd64	assets/other.bin' "$W/manifests/build-inputs.tsv" \
        && ok "[$mode] one build-inputs row per arch, other rows kept" || bad "[$mode] build-inputs row count"
    grep -q "^assets/browser/browser-stable_1.10-1_arm64.deb|" "$W/sbom/expected-assets.txt" && ! grep -q '1.0-1' "$W/sbom/expected-assets.txt" \
        && ok "[$mode] sbom row updated in place" || bad "[$mode] sbom row"
    [ ! -e "$W/assets/browser/browser-stable_1.0-1_amd64.deb" ] && [ -f "$W/assets/browser/browser-stable_1.10-1_amd64.deb" ] \
        && ok "[$mode] superseded local deb removed, resolved deb staged" || bad "[$mode] staged files"
    h1="$(cat "$W"/manifests/*.tsv "$W/sbom/expected-assets.txt" | sha256sum)"; m1="$(stat -c %Y "$W/assets/browser/browser-stable_1.10-1_amd64.deb")"
    sleep 1
    "${PY[@]}" refresh "$W" browser-stable > "$T/out2" 2>&1
    h2="$(cat "$W"/manifests/*.tsv "$W/sbom/expected-assets.txt" | sha256sum)"; m2="$(stat -c %Y "$W/assets/browser/browser-stable_1.10-1_amd64.deb")"
    [ "$h1" = "$h2" ] && [ "$m1" = "$m2" ] && grep -q 'ledgers unchanged' "$T/out2" && grep -q 'already staged' "$T/out2" \
        && ok "[$mode] second run is a no-op (no download, ledgers byte-identical)" || bad "[$mode] not idempotent"
    "${PY[@]}" check "$W" browser-stable >/dev/null 2>&1 && ok "[$mode] check exit 0 when current" || bad "[$mode] check not 0 when current"
done

# Broken chain links (release mode).
mkrepo release 2.0-1
W="$(mktree release "$(printf 'F%.0s' {1..40})")"
"${PY[@]}" refresh "$W" browser-stable >/dev/null 2>&1 && bad "a keyring whose fingerprint is not pinned was accepted" || ok "keyring fingerprint not pinned -> refused"
W="$(mktree release "$FPR")"
printf 'X' >> "$R/dists/stable/Release"
"${PY[@]}" refresh "$W" browser-stable >/dev/null 2>&1 && bad "a Release with a bad signature was accepted" || ok "bad Release signature -> refused"
mkrepo release 2.0-1
printf 'Package: browser-stable\nVersion: 9.0-1\nArchitecture: amd64\nFilename: x\nSize: 1\nSHA256: %s\n\n' "$(printf '0%.0s' {1..64})" >> "$R/dists/stable/main/binary-amd64/Packages"
"${PY[@]}" refresh "$W" browser-stable >/dev/null 2>&1 && bad "a Packages file not matching the signed index was accepted" || ok "Packages sha256 not in the signed index -> refused"
mkrepo release 2.0-1
cp "$R/pool/browser-stable_2.0-1_arm64.deb" "$T/keep.deb"; printf 'X' >> "$R/pool/browser-stable_2.0-1_arm64.deb"
"${PY[@]}" refresh "$W" browser-stable >/dev/null 2>&1 && bad "a deb with other bytes than the index was accepted" || ok "deb sha256 mismatch -> refused"
[ ! -e "$W/assets/browser/browser-stable_2.0-1_arm64.deb" ] && ok "no partial deb left behind" || bad "partial deb left behind"
cp "$T/keep.deb" "$R/pool/browser-stable_2.0-1_arm64.deb"
mkrepo inrelease 2.0-1
W="$(mktree release "$FPR")"
"${PY[@]}" refresh "$W" browser-stable >/dev/null 2>&1 && bad "release mode accepted a repo without Release.gpg" || ok "missing detached signature -> refused"

# The committed ledgers.
while IFS=$'\t' read -r pkg _ _ _ _ _ _ dir arches _; do
    case "$pkg" in ''|'#'*) continue ;; esac
    for a in ${arches//,/ }; do
        row="$(awk -F'\t' -v p="$pkg" -v a="$a" '$1==p && $3==a' "$ROOT/manifests/vendor-debs.tsv")"
        v="$(printf '%s' "$row" | cut -f2)"; s="$(printf '%s' "$row" | cut -f6)"
        [ "$(printf '%s\n' "$row" | grep -c .)" = 1 ] && printf '%s' "$row" | grep "alias $pkg from " >/dev/null \
            && ok "vendor-debs: $pkg/$a recorded from its alias ($v)" || bad "vendor-debs: $pkg/$a not recorded from its alias"
        grep -q "^$a	$dir/${pkg}_${v}_$a.deb	$s	" "$ROOT/manifests/build-inputs.tsv" \
            && ok "build-inputs: $pkg/$a $v staged with the same sha256" || bad "build-inputs: $pkg/$a $v not staged with the same sha256"
    done
done < "$ROOT/manifests/vendor-aliases.tsv"
grep -q 'ncz_vendor_staged_deb "$ROOT" vivaldi-stable' "$ROOT/build/build-squashfs-layers.sh" \
    && ok "layer builder stages only the pinned Vivaldi deb" || bad "layer builder copies assets/vivaldi wholesale"
! grep -Eq 'vivaldi-stable_[0-9]' "$ROOT/post-install/52-vivaldi.sh" && ok "52-vivaldi.sh names no Vivaldi version" || bad "52-vivaldi.sh hard-codes a version"
grep -q 'refresh-vendor-debs.sh' "$ROOT/build/refresh-vivaldi.sh" && grep -q 'refresh-vendor-debs.sh' "$ROOT/build/refresh-google-chrome.sh" \
    && ok "refresh-vivaldi.sh and refresh-google-chrome.sh use the alias resolver" || bad "refresh wrappers"
echo "test-vendor-alias: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
