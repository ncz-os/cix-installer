#!/bin/bash
# test-release-identity.sh -- regression tests for the 26.10 Cygnus identity
# sweep. Every check here failed before the sweep:
#   * the (since retired) ISO-repack gates stamped NCZ_MAXIMILIAN regardless
#     of release.conf; the raw GPT image writers now carry that guard;
#   * the recovery-container banner said "MAXIMILIAN";
#   * the logo slot shipped LOGO=ncz / ncz.png, not the approved Cygnus mark;
#   * the installed rEFInd titles omitted the codename;
#   * the fixtures pinned 26.7/Maximilian.
#
# Run: bash build/test-release-identity.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1${2:+: $2}"; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }
check_grep()   { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "missing '$2' in $1"; fi; }
check_nogrep() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3" "'$2' still present in $1"; else ok "$3"; fi; }
# Comment-aware variant: history prose may still name 26.7/Maximilian, only a
# LIVE (non-comment) hardcode is the regression.
strip_comments() { sed -E 's/^[[:space:]]*#.*$//' "$1"; }
check_nolive() { if strip_comments "$1" | grep -qF -- "$2"; then bad "$3" "'$2' is still a live hardcode in $1"; else ok "$3"; fi; }

ROOT_RC="$ROOT/release.conf"
[ -r "$ROOT_RC" ] || { echo "FATAL: missing $ROOT_RC" >&2; exit 2; }
# shellcheck source=../release.conf
. "$ROOT_RC"

# ---- helper derives the live identity ---------------------------------------
EXPECT_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"
EXPECT_VOL="NCZ_$(printf %s "$NCZ_RELEASE_CODENAME" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_' | cut -c1-28)"
check_eq "helper derives NCZ_RELEASE_LABEL from release.conf" \
    "$(bash -c ". '$ROOT/build/lib/release-identity.sh'; printf '%s' \"\$NCZ_RELEASE_LABEL\"")" "$EXPECT_LABEL"
check_eq "helper derives NCZ_ISO_VOLUME_ID from release.conf" \
    "$(bash -c ". '$ROOT/build/lib/release-identity.sh'; printf '%s' \"\$NCZ_ISO_VOLUME_ID\"")" "$EXPECT_VOL"

# ---- helper tracks a CHANGED release.conf (not a hardcoded value) -----------
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/build/lib"
cp "$ROOT/build/lib/release-identity.sh" "$T/build/lib/"
printf 'NCZ_PRODUCT_NAME="NCZ-OS"\nNCZ_RELEASE_VERSION="99.1"\nNCZ_RELEASE_CODENAME="Testbird"\n' > "$T/release.conf"
check_eq "helper tracks a synthetic release.conf (label)" \
    "$(bash -c ". '$T/build/lib/release-identity.sh'; printf '%s' \"\$NCZ_RELEASE_LABEL\"")" "NCZ-OS 99.1 Testbird"
check_eq "helper tracks a synthetic release.conf (volid)" \
    "$(bash -c ". '$T/build/lib/release-identity.sh'; printf '%s' \"\$NCZ_ISO_VOLUME_ID\"")" "NCZ_TESTBIRD"

# ---- no raw GPT image writer or gate hardcodes a codename -------------------
# The installer media is the raw GPT .img written by build-installer-image.sh;
# its visible identity (the rEFInd boot menu) is derived from release.conf by
# build-refind-esp.py. None of these may carry a stale literal codename.
WRITERS=(
    build/build-installer-image.sh
    build/iso/build-refind-esp.py
    build/iso/write-usb-image.py
    build/kvm-install-gate-gpt.sh
)
for g in "${WRITERS[@]}"; do
    check_nolive "$ROOT/$g" "NCZ_MAXIMILIAN" "$g: no hardcoded NCZ_MAXIMILIAN label"
    check_nolive "$ROOT/$g" "Maximilian" "$g: no hardcoded Maximilian codename"
done
check_grep "$ROOT/build/iso/build-refind-esp.py" 'REPO_ROOT / "release.conf"' "build-refind-esp.py: reads release.conf"
check_grep "$ROOT/build/iso/build-refind-esp.py" 'rel.get("NCZ_RELEASE_CODENAME"' "build-refind-esp.py: boot menu derives the codename from release.conf"

# ---- recovery-container banner derives from release.conf --------------------
check_nolive "$ROOT/build/build-mgmt-rootfs.sh" "MAXIMILIAN" "build-mgmt-rootfs.sh: banner no longer hardcodes MAXIMILIAN"
check_grep  "$ROOT/build/build-mgmt-rootfs.sh" 'NCZ_MGMT_BANNER_LABEL SERVER RECOVERY CONTAINER' "build-mgmt-rootfs.sh: banner uses the derived label"

# ---- Cygnus logo wired into the greeter slot --------------------------------
LOGO="$ROOT/assets/branding/greeter/cygnus/ncz-os-cygnus-logo.png"
if [ -f "$LOGO" ]; then ok "Cygnus logo tracked at assets/branding/greeter/cygnus/"; else bad "Cygnus logo tracked at assets/branding/greeter/cygnus/"; fi
check_eq "Cygnus logo sha256 matches the approved pack" \
    "$(sha256sum "$LOGO" 2>/dev/null | awk '{print $1}')" \
    "dc949a357778993a6a509cb2f09e39902aa160bdd7ab2e542871aa31ffbc8890"
check_grep "$ROOT/post-install/55-greeter.sh" 'ncz-os-cygnus-logo.png' "55-greeter.sh: references the Cygnus logo asset"
check_grep "$ROOT/post-install/55-greeter.sh" '"/usr/share/pixmaps/$LOGO_NAME.png"' "55-greeter.sh: installs to the pixmaps path"
check_grep "$ROOT/post-install/55-greeter.sh" '"/usr/share/icons/hicolor/256x256/apps/$LOGO_NAME.png"' "55-greeter.sh: installs to the hicolor apps path"
check_grep "$ROOT/post-install/55-greeter.sh" "$(printf '%s' 'elif [ -f "$ASSETS/logo/ncz.png" ]; then')" "55-greeter.sh: keeps a missing-asset fallback"
check_grep "$ROOT/post-install/50-brand.sh" 'LOGO=ncz-os-${SKU_LOWER}' "50-brand.sh: LOGO derives from the release codename"

# ---- installed rEFInd titles carry the full label ---------------------------
for r in assets/refind/ncz-refind-refresh.sh assets/refind/ncz-refind-refresh-amd64.sh; do
    check_grep "$ROOT/$r" 'NCZ_RELEASE_SHORT="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"' \
        "$r: rEFInd titles use product+version+codename"
done

# ---- fixtures derive the identity, no pinned old codename -------------------
for f in build/test-ncz-ui.sh build/test-installed-target-verifier.sh build/test-dual-arch-parity.sh; do
    check_nolive "$ROOT/$f" "Maximilian" "$f: fixture no longer pins Maximilian"
    check_grep  "$ROOT/$f" "release.conf" "$f: fixture sources release.conf"
done

# ---- os-release names the base system once --------------------------------
# PRETTY_NAME used to read "... (based on Debian testing Debian Testing (Forky))":
# the hook printed NCZ_BASE_NAME and NCZ_BASE_VERSION in front of
# NCZ_BASE_LABEL, which already carries both.
brand_id() { # $1 release file, $2 variant, $3 key
    NCZ_BRAND_PRINT_IDENTITY="$1" NCZ_BRAND_VARIANT="$2" \
        bash "$ROOT/post-install/50-brand.sh" 2>/dev/null | sed -n "s/^$3=//p"
}
check_eq "50-brand.sh: desktop PRETTY_NAME" "$(brand_id "$ROOT_RC" desktop PRETTY_NAME)" \
    "$EXPECT_LABEL Desktop, based on $NCZ_BASE_LABEL"
check_eq "50-brand.sh: server PRETTY_NAME" "$(brand_id "$ROOT_RC" server PRETTY_NAME)" \
    "$EXPECT_LABEL Server, based on $NCZ_BASE_LABEL"
check_eq "50-brand.sh: VERSION" "$(brand_id "$ROOT_RC" desktop VERSION)" \
    "$NCZ_RELEASE_VERSION ($NCZ_RELEASE_CODENAME Desktop, based on $NCZ_BASE_LABEL)"
check_eq "50-brand.sh: lsb DISTRIB_DESCRIPTION matches PRETTY_NAME" \
    "$(brand_id "$ROOT_RC" desktop DISTRIB_DESCRIPTION)" "$(brand_id "$ROOT_RC" desktop PRETTY_NAME)"
_pn="$(brand_id "$ROOT_RC" desktop PRETTY_NAME)"
_lc="$(printf '%s' "$_pn" | tr '[:upper:]' '[:lower:]')"
_n="$(printf '%s' "$_lc" | grep -o "$(printf '%s' "$NCZ_BASE_NAME" | tr '[:upper:]' '[:lower:]')" | wc -l)"
check_eq "50-brand.sh: PRETTY_NAME names the base distribution once" "$_n" "1"
_n="$(printf '%s' "$_lc" | grep -o "$(printf '%s' "$NCZ_BASE_VERSION" | tr '[:upper:]' '[:lower:]')" | wc -l)"
check_eq "50-brand.sh: PRETTY_NAME names the base suite once" "$_n" "1"
printf 'NCZ_PRODUCT_NAME="NCZ-OS"\nNCZ_RELEASE_VERSION="99.1"\nNCZ_RELEASE_CODENAME="Testbird"\nNCZ_BASE_NAME="Debian"\nNCZ_BASE_VERSION="testing"\n' > "$T/nolabel.conf"
check_eq "50-brand.sh: release file without NCZ_BASE_LABEL" "$(brand_id "$T/nolabel.conf" desktop PRETTY_NAME)" \
    "NCZ-OS 99.1 Testbird Desktop, based on Debian testing"
check_nogrep "$ROOT/post-install/50-brand.sh" '${NCZ_BASE_NAME} ${NCZ_BASE_VERSION} ${NCZ_BASE_LABEL}' \
    "50-brand.sh: no identity string repeats the base name and suite before the label"

echo "release-identity tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
