#!/bin/bash
# test-stage-singularity-payload.sh -- build/stage-singularity-payload.sh stages
# exactly the pinned payload deb, and fails closed otherwise (both directions).
# Uses a file:// repository fixture; no network.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

T="$(mktemp -d "${TMPDIR:-$ROOT/build}/test-ssp.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# fixture tree: the script plus a pin and an empty assets/cix-debs
mk_tree() { # $1 dir
    mkdir -p "$1/build" "$1/manifests" "$1/assets/cix-debs"
    cp "$ROOT/build/stage-singularity-payload.sh" "$1/build/"
}
F=ncz-singularity-desktop_20990101000000+bk0+tgzdeadbeef_amd64.deb
REPO="$T/repo"; mkdir -p "$REPO/pool/n" "$REPO/dists/any/main/binary-amd64"
printf 'payload-bytes\n' > "$REPO/pool/n/$F"
SHA="$(sha256sum "$REPO/pool/n/$F" | awk '{print $1}')"
write_index() { # $1 sha to advertise
    printf 'Package: ncz-singularity-desktop\nVersion: 20990101000000+bk0+tgzdeadbeef\nArchitecture: amd64\nFilename: pool/n/%s\nSHA256: %s\n\n' "$F" "$1" \
        > "$REPO/dists/any/main/binary-amd64/Packages"
}
pin() { printf '# test pin\namd64\t%s\t%s\n' "$1" "$F" > "$2/manifests/singularity-payload.tsv"; }

# 1. fetch from the repository index when not staged
A="$T/a"; mk_tree "$A"; pin "$SHA" "$A"; write_index "$SHA"
if NCZ_APT_BASE="file://$REPO" bash "$A/build/stage-singularity-payload.sh" --arch amd64 >"$T/o1" 2>&1 \
   && [ "$(sha256sum "$A/assets/cix-debs/$F" | awk '{print $1}')" = "$SHA" ]; then
    ok "stages the pinned deb from the repository (sha256 verified)"
else bad "did not stage the pinned deb"; cat "$T/o1"; fi

# 2. idempotent and offline once staged (repository unreachable)
if NCZ_APT_BASE="file://$T/nonexistent" bash "$A/build/stage-singularity-payload.sh" --arch amd64 --offline >/dev/null 2>&1; then
    ok "idempotent and offline when already staged"
else bad "re-run failed although the pinned deb is staged"; fi
bash "$A/build/stage-singularity-payload.sh" --arch amd64 --check >/dev/null 2>&1 \
    && ok "--check passes when staged" || bad "--check failed when staged"

# 3. index advertises a different sha -> refuse before download
B="$T/b"; mk_tree "$B"; pin "$SHA" "$B"; write_index "$(printf '0%.0s' $(seq 64))"
if NCZ_APT_BASE="file://$REPO" bash "$B/build/stage-singularity-payload.sh" --arch amd64 >/dev/null 2>&1; then
    bad "accepted an index row whose sha256 differs from the pin"
else ok "refuses an index row whose sha256 differs from the pin"; fi
[ ! -e "$B/assets/cix-debs/$F" ] && ok "nothing staged after the refusal" || bad "a file was staged after the refusal"

# 4. index matches but the bytes do not -> refuse
C="$T/c"; mk_tree "$C"; pin "$SHA" "$C"; write_index "$SHA"
cp "$REPO/pool/n/$F" "$T/good.deb"; printf 'tampered\n' > "$REPO/pool/n/$F"
if NCZ_APT_BASE="file://$REPO" bash "$C/build/stage-singularity-payload.sh" --arch amd64 >/dev/null 2>&1; then
    bad "accepted downloaded bytes that do not match the pin"
else ok "refuses downloaded bytes that do not match the pin"; fi
[ ! -e "$C/assets/cix-debs/$F" ] && ok "tampered bytes not staged" || bad "tampered bytes were staged"
cp "$T/good.deb" "$REPO/pool/n/$F"

# 5. a wrong file already at the destination is not silently used
D="$T/d"; mk_tree "$D"; pin "$SHA" "$D"; printf 'stale\n' > "$D/assets/cix-debs/$F"
if NCZ_APT_BASE="file://$REPO" bash "$D/build/stage-singularity-payload.sh" --arch amd64 >/dev/null 2>&1; then
    bad "used a staged file whose sha256 differs from the pin"
else ok "refuses a staged file whose sha256 differs from the pin"; fi

# 6. offline and not staged -> fail; local directory source works offline
E="$T/e"; mk_tree "$E"; pin "$SHA" "$E"
if bash "$E/build/stage-singularity-payload.sh" --arch amd64 --offline >/dev/null 2>&1; then
    bad "--offline passed with nothing staged"
else ok "--offline fails when nothing is staged"; fi
mkdir -p "$T/local"; cp "$T/good.deb" "$T/local/$F"
if NCZ_SINGULARITY_PAYLOAD_DIR="$T/local" bash "$E/build/stage-singularity-payload.sh" --arch amd64 --offline >/dev/null 2>&1 \
   && [ -f "$E/assets/cix-debs/$F" ]; then
    ok "stages from NCZ_SINGULARITY_PAYLOAD_DIR offline"
else bad "did not stage from NCZ_SINGULARITY_PAYLOAD_DIR"; fi

# 7. missing pin row / bad usage
G="$T/g"; mk_tree "$G"; printf '# empty\n' > "$G/manifests/singularity-payload.tsv"
bash "$G/build/stage-singularity-payload.sh" --arch amd64 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "no pin row fails closed (rc=1)" || bad "no pin row rc=$rc"
bash "$G/build/stage-singularity-payload.sh" --arch sparc >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "bad --arch is a usage error (rc=2)" || bad "bad --arch rc=$rc"

# 8. the entrypoint uses the stager for --sources pinned
grep -q 'build/stage-singularity-payload.sh' "$ROOT/build/build-image.sh" \
    && ok "build-image.sh stages the pinned payload via stage-singularity-payload.sh" \
    || bad "build-image.sh does not call stage-singularity-payload.sh"

# 9. the committed pin rows are well formed for both arches
for a in amd64 arm64; do
    p="$(bash "$ROOT/build/stage-singularity-payload.sh" --arch "$a" --print-path 2>/dev/null)"
    case "$p" in */assets/cix-debs/ncz-singularity-desktop_*_"$a".deb) ok "committed $a pin row resolves to $(basename "$p")" ;;
        *) bad "committed $a pin row does not resolve: '$p'" ;; esac
done

printf '\n== stage-singularity-payload tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
