#!/usr/bin/env bash
# test-stage-singularity-payload-store.sh -- the artifact store must be a real
# source for the pinned payload, and the pin's sha256 must still be the authority.
#
# WHY. On 2026-11-06 the pin named payloads that were in no store and not in the
# published repo (which was six weeks behind), so a fresh host could not build.
# The debs are now in ARGONAS ncz-singularity-debs/payload-20261106222540/, but
# stage-singularity-payload.sh only consulted local assets, a payload dir and the
# network -- the store was unreachable in practice. This test pins the new
# behaviour, and pins the two ways it could go wrong: a store copy with the wrong
# bytes must be refused, and an empty store must fail closed rather than "succeed".
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-payload-store.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

# A minimal repo whose pin names our fixture deb, so the real script runs unmodified.
mk_repo() {  # mk_repo <sha> <file>
    local sha="$1" file="$2"
    mkdir -p "$T/repo/build/lib" "$T/repo/manifests" "$T/repo/assets/cix-debs"
    cp -f "$REPO/build/stage-singularity-payload.sh" "$T/repo/build/"
    cp -f "$REPO/build/lib/ncz-site.sh" "$T/repo/build/lib/" 2>/dev/null || true
    printf '# fixture\namd64\t%s\t%s\n' "$sha" "$file" > "$T/repo/manifests/singularity-payload.tsv"
}
FILE="ncz-singularity-desktop_99999999999999+bk0+tgzfixture_amd64.deb"

# fixture bytes
mkdir -p "$T/fixture"
head -c 4096 /dev/urandom > "$T/fixture/$FILE"
GOOD="$(sha256sum "$T/fixture/$FILE" | cut -d' ' -f1)"
BAD="$(printf 'not the same bytes' | sha256sum | cut -d' ' -f1)"

run() {  # run <store-root-or-empty> -> runs the stager offline; sets RC/OUT
    local root="$1"
    OUT="$(cd "$T/repo" && env NCZ_PAYLOAD_SRC_ROOT="$root" TMPDIR="$T" \
        bash build/stage-singularity-payload.sh --arch amd64 --offline 2>&1)"; RC=$?
}

# --- 1. a matching store copy is staged, offline -----------------------------------
mk_repo "$GOOD" "$FILE"
mkdir -p "$T/store/ncz-singularity-debs/payload-20261106222540/amd64"
cp -f "$T/fixture/$FILE" "$T/store/ncz-singularity-debs/payload-20261106222540/amd64/"
run "$T/store"
if [ "$RC" = 0 ] && [ -s "$T/repo/assets/cix-debs/$FILE" ]; then
    ok "a pinned deb is staged from the store with no network"
else
    bad "a pinned deb is staged from the store with no network" "$OUT"
fi
[ "$(sha256sum "$T/repo/assets/cix-debs/$FILE" 2>/dev/null | cut -d' ' -f1)" = "$GOOD" ] \
    && ok "the staged file is byte-identical to the pin" \
    || bad "the staged file is byte-identical to the pin"

# --- 2. a store copy with the wrong bytes is refused, not installed ----------------
rm -f "$T/repo/assets/cix-debs/$FILE"
mkdir -p "$T/store2/ncz-singularity-debs/payload-20261106222540/amd64"
printf 'wrong bytes\n' > "$T/store2/ncz-singularity-debs/payload-20261106222540/amd64/$FILE"
run "$T/store2"
if [ "$RC" != 0 ] && [ ! -e "$T/repo/assets/cix-debs/$FILE" ]; then
    ok "a wrong-sha store copy is refused and nothing is staged"
else
    bad "a wrong-sha store copy is refused and nothing is staged" "rc=$RC $(printf '%s' "$OUT" | tail -2)"
fi
printf '%s' "$OUT" | grep -q 'not used' \
    && ok "the refusal names the sha mismatch" \
    || bad "the refusal names the sha mismatch" "$(printf '%s' "$OUT" | tail -2)"

# --- 3. the right copy wins over a wrong one in a newer label ---------------------
rm -f "$T/repo/assets/cix-debs/$FILE"
mkdir -p "$T/store3/ncz-singularity-debs/payload-99999999999999/amd64" \
         "$T/store3/ncz-singularity-debs/payload-20261106222540/amd64"
printf 'wrong bytes\n' > "$T/store3/ncz-singularity-debs/payload-99999999999999/amd64/$FILE"
cp -f "$T/fixture/$FILE" "$T/store3/ncz-singularity-debs/payload-20261106222540/amd64/"
run "$T/store3"
if [ "$RC" = 0 ] && [ "$(sha256sum "$T/repo/assets/cix-debs/$FILE" 2>/dev/null | cut -d' ' -f1)" = "$GOOD" ]; then
    ok "a newer label with wrong bytes does not shadow the matching one"
else
    bad "a newer label with wrong bytes does not shadow the matching one" "rc=$RC"
fi

# --- 4. an empty store fails closed ------------------------------------------------
rm -f "$T/repo/assets/cix-debs/$FILE"
mkdir -p "$T/empty"
run "$T/empty"
[ "$RC" != 0 ] && ok "an empty store fails closed rather than reporting success" \
    || bad "an empty store fails closed rather than reporting success"

echo "test-stage-singularity-payload-store: $pass passed, $fail failed"
[ "$fail" = 0 ]
