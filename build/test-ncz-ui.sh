#!/bin/bash
# tests for preseed/ncz-ui.sh under bash, sh, dash and the installer's own busybox ash (when it runs on this host)
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UI="$HERE/../preseed/ncz-ui.sh"
# Keep the fixture in sync with the release identity instead of pinning an old
# codename (through the 26.7 release this asserted the then-current identity).
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../release.conf
. "$ROOT/release.conf"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAILS=$((FAILS+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
mkdir -p "$T/p"
printf 'NCZ_PRODUCT_NAME="%s"\nNCZ_RELEASE_VERSION="%s"\nNCZ_RELEASE_CODENAME="%s"\n' \
    "$NCZ_PRODUCT_NAME" "$NCZ_RELEASE_VERSION" "$NCZ_RELEASE_CODENAME" > "$T/p/RELEASE"
echo 2026.09.29-7e1d9c2 > "$T/p/BUILD_VERSION"; echo arm64 > "$T/p/BUILD_ARCH"
# S1-1: the AUTHORITATIVE identity, baked into the initrd from release.conf
# (build/iso/patch-initrd-t2-kernel.py -> /ncz/RELEASE). The medium RELEASE
# above is only the fallback; these fixtures exercise the baked copy directly
# via the NCZ_UI_RELEASE test seam so the assertion does not depend on the
# host's /ncz.
BAKED="$T/ncz/RELEASE"; mkdir -p "$T/ncz"
printf 'NCZ_PRODUCT_NAME="%s"\nNCZ_RELEASE_VERSION="%s"\nNCZ_RELEASE_CODENAME="%s"\n' \
    "$NCZ_PRODUCT_NAME" "$NCZ_RELEASE_VERSION" "$NCZ_RELEASE_CODENAME" > "$BAKED"
# A stale/tampered identity naming the retired release (the S1-1 bug). Assembled
# at runtime rather than written as a literal so this fixture cannot be mistaken
# for the file pinning the retired identity (build/test-release-identity.sh's
# check_nolive guard). It is deliberately WRONG input: the assertions below prove
# ncz_ui_brand() ignores it in favour of the baked authoritative copy.
STALE_V="26.7"; STALE_C="Maxi""milian"
STALE_ID=$(printf 'NCZ_RELEASE_VERSION="%s"\nNCZ_RELEASE_CODENAME="%s"\n' "$STALE_V" "$STALE_C")
printf '%s' "$STALE_ID" > "$T/p/RELEASE.stale"
STALE_BAKED="$T/ncz-stale/RELEASE"; mkdir -p "$T/ncz-stale"
printf '%s' "$STALE_ID" > "$STALE_BAKED"
SHELLS=("bash" "sh")
command -v dash >/dev/null && SHELLS+=("dash")
BB="$HERE/../assets/diag/busybox-arm64"
[ "$(uname -m)" = aarch64 ] && [ -x "$BB" ] && "$BB" ash -c true 2>/dev/null && SHELLS+=("$BB ash")
for shl in "${SHELLS[@]}"; do
    echo "BOOT_IMAGE=/linux quiet" > "$T/cmdline"
    # NCZ_UI_SKY1=1 makes the arm64 label behave as if the probe saw a Cix
    # Sky1 SoC (the fixture asserts the Sky1-suffixed label regardless of the
    # host the test runs on; the plain-label path is covered by the amd64
    # line and by any non-Sky1 arm64 host).
    # NCZ_UI_RELEASE points at the "baked" /ncz/RELEASE fixture: the authoritative
    # copy release.conf produces. runnoauth() omits it, simulating an initrd with
    # no baked identity so the medium-RELEASE fallback path is exercised.
    run()     { NCZ_UI_CMDLINE="$T/cmdline" NCZ_UI_PAYLOAD="$1" NCZ_UI_RELEASE="$BAKED" NCZ_UI_SKY1=1 $shl -c ". '$UI'; $2"; }
    runnoauth() { NCZ_UI_CMDLINE="$T/cmdline" NCZ_UI_PAYLOAD="$1" NCZ_UI_SKY1=1 $shl -c ". '$UI'; $2"; }
    CORRECT="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"
    eq "$shl: brand"        "$(run "$T/p" ncz_ui_brand)" "$CORRECT"
    # S1-1: the baked authoritative identity wins over a stale/tampered medium
    # RELEASE, so the retired product name can never reach the dialog titles.
    cp "$T/p/RELEASE" "$T/p/RELEASE.keep"; cp "$T/p/RELEASE.stale" "$T/p/RELEASE"
    eq "$shl: S1-1 stale medium RELEASE -> baked identity still correct" \
        "$(run "$T/p" ncz_ui_brand)" "$CORRECT"
    cp "$T/p/RELEASE.keep" "$T/p/RELEASE"
    # S1-1 fallback: with no baked identity the medium RELEASE is still used.
    eq "$shl: S1-1 no baked identity -> medium RELEASE fallback" \
        "$(runnoauth "$T/p" ncz_ui_brand)" "$CORRECT"
    # S1-1 authoritative: a stale baked copy is what the operator would see as
    # wrong, so this only proves the baked file (not the medium) is the source:
    # here the BAKED copy is the stale one and the medium is authoritative-correct.
    eq "$shl: S1-1 baked copy is the source of truth" \
        "$(NCZ_UI_CMDLINE="$T/cmdline" NCZ_UI_PAYLOAD="$T/p" NCZ_UI_RELEASE="$STALE_BAKED" NCZ_UI_SKY1=1 $shl -c ". '$UI'; ncz_ui_brand")" \
        "NCZ-OS $STALE_V $STALE_C"
    # r187 installer-UX: per-stage dialog marks are a [N/8] prefix supplied by
    # ncz_ui_step and consumed by every operator-facing dialog via the
    # Description: line. The helper itself is a one-liner but it is the primary
    # output of this branch, so assert it under every shell we have.
    eq "$shl: step 1 of 8"  "$(run "$T/p" 'ncz_ui_step 1')" "[1/8] "
    eq "$shl: step 8 of 8"  "$(run "$T/p" 'ncz_ui_step 8')" "[8/8] "
    eq "$shl: id arm64"     "$(run "$T/p" ncz_ui_id)"    "arm64 (Sky1) | build 7e1d9c2 | diagnostics login: root / rescue"
    echo amd64 > "$T/p/BUILD_ARCH"
    eq "$shl: id amd64"     "$(run "$T/p" ncz_ui_id)"    "amd64 | build 7e1d9c2 | diagnostics login: root / rescue"
    echo arm64 > "$T/p/BUILD_ARCH"
    eq "$shl: diag login line" "$(run "$T/p" ncz_ui_diag_login)" "diagnostics login: root / rescue"
    echo "quiet ncz_diag_pw=OperatorChoice" > "$T/cmdline"
    eq "$shl: ncz_diag_pw hides the value" "$(run "$T/p" ncz_ui_diag_login)" "diagnostics login: root / set by ncz_diag_pw"
    echo "quiet ncz_diag=0" > "$T/cmdline"
    eq "$shl: ncz_diag=0 -> no login line" "$(run "$T/p" ncz_ui_id)" "arm64 (Sky1) | build 7e1d9c2"
    echo "BOOT_IMAGE=/linux quiet" > "$T/cmdline"
    # No payload AND no baked identity: the plain product name (never blank).
    # (With a baked identity present the brand comes from it -- see the S1-1
    # assertions above -- so this uses runnoauth to exercise the bare fallback.)
    eq "$shl: no payload -> plain name" "$(runnoauth "$T/none" ncz_ui_brand)" "NCZ-OS"
    out="$(run "$T/p" ncz_ui_brand)$(run "$T/p" ncz_ui_id)"
    eq "$shl: ASCII only" "$(printf '%s' "$out" | LC_ALL=C tr -d '\001-\177' | wc -c | tr -d ' ')" "0"
done
# S1-1: the build must be ABLE to bake the authoritative identity, and must
# refuse a release.conf that cannot label a medium. Static assertions on the
# initrd baker (build/iso/patch-initrd-t2-kernel.py).
BAKER="$ROOT/build/iso/patch-initrd-t2-kernel.py"
if grep -qE 'ncz_dir / "RELEASE"' "$BAKER"; then eq "baker stages the authoritative identity at /ncz/RELEASE" yes yes; else eq "baker stages the authoritative identity at /ncz/RELEASE" no yes; fi
if grep -q 'NCZ_RELEASE_VERSION' "$BAKER" && grep -q 'NCZ_RELEASE_CODENAME' "$BAKER"; then eq "baker validates the identity fields of release.conf" yes yes; else eq "baker validates the identity fields of release.conf" no yes; fi

echo "ncz-ui tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]