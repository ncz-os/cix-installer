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
check_nolive() { if strip_comments "$1" | grep >/dev/null -F -- "$2"; then bad "$3" "'$2' is still a live hardcode in $1"; else ok "$3"; fi; }

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
# build/iso/write-usb-image.py is NOT in this list: the MINOR-001 gate
# (run_release_identity_gate) names the retired codenames it rejects, so the
# no-hardcode scan below must not flag the gate itself. The generated-strings
# guarantee for that writer is asserted in the MINOR-001 section at the end.
WRITERS=(
    build/build-installer-image.sh
    build/iso/build-refind-esp.py
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

# ---- MINOR-001: the build-time gate over GENERATED identity strings --------
# The operator saw "NCZ Maximilian Server" on an arm64 Preview2 medium. The
# gate (build/check-release-identity-gate.sh) checks what the producers
# ACTUALLY generated -- the RELEASE/os-release/issue strings in a staged
# medium tree and a baked rootfs tree -- for BOTH variants:
#   * no retired codename (Maximilian, Reinhardt) in any generated string;
#   * no empty product label;
#   * the os-release PRETTY_NAME variant label matches BUILD_VARIANT
#     (desktop -> Desktop, server -> Server).
GATE="$ROOT/build/check-release-identity-gate.sh"
if [ -f "$GATE" ] && [ -x "$GATE" ]; then ok "gate script exists and is executable"; else bad "gate script exists and is executable"; fi

# conf subcommand: the current release.conf is a sound identity.
if bash "$GATE" conf "$ROOT_RC" >/dev/null 2>&1; then
    ok "gate conf: current release.conf passes"
else
    bad "gate conf: current release.conf passes"
fi

# Build a realistic generated tree for each variant from release.conf via the
# real 50-brand.sh print-identity path, plus the medium RELEASE copy.
make_tree() {  # $1 dir, $2 variant
    local d="$1" v="$2"
    mkdir -p "$d/ncz-payload" "$d/etc" "$d/usr/local/lib/cix-installer"
    cp "$ROOT_RC" "$d/ncz-payload/RELEASE"
    cp "$ROOT_RC" "$d/usr/local/lib/cix-installer/RELEASE"
    printf '%s' "$v" > "$d/usr/local/lib/cix-installer/BUILD_VARIANT"
    brand_id "$ROOT_RC" "$v" PRETTY_NAME | sed 's/^PRETTY_NAME=//' > "$d/.pn"
    brand_id "$ROOT_RC" "$v" VERSION    | sed 's/^VERSION=//'    > "$d/.ver"
    {
        printf 'PRETTY_NAME="%s"\n' "$(cat "$d/.pn")"
        printf 'NAME="%s"\n' "$NCZ_PRODUCT_NAME"
        printf 'VERSION_ID="%s"\n' "$NCZ_RELEASE_VERSION"
        printf 'BUILD_ID="2026.10.17-test"\n'
        printf 'VERSION="%s"\n' "$(cat "$d/.ver")"
        printf 'VERSION_CODENAME=%s\n' "$(printf '%s' "$NCZ_RELEASE_CODENAME" | tr '[:upper:]' '[:lower:]')"
        printf 'NCZ_VARIANT=%s\n' "$v"
        printf 'ID=ncz\n'
    } > "$d/etc/os-release"
    {
        printf 'DISTRIB_ID=NCZ\nDISTRIB_RELEASE=%s\nDISTRIB_CODENAME=%s\n' \
            "$NCZ_RELEASE_VERSION" "$(printf '%s' "$NCZ_RELEASE_CODENAME" | tr '[:upper:]' '[:lower:]')"
        printf 'DISTRIB_DESCRIPTION="%s"\n' "$(cat "$d/.pn")"
    } > "$d/etc/lsb-release"
    {
        printf '%s %s  ·  unknown  (Kernel: \\r)\n' "$EXPECT_LABEL" "$([ "$v" = server ] && echo Server || echo Desktop)"
        printf 'Build: 2026.10.17-test  (unknown)\nIP:    NCZ_ISSUE_IP_PLACEHOLDER\n'
    } > "$d/etc/issue"
    {
        printf '%s %s  (NCZ_ISSUE_SOC_PLACEHOLDER)\n' "$EXPECT_LABEL" "$([ "$v" = server ] && echo Server || echo Desktop)"
        printf 'Build: 2026.10.17-test  (unknown)\n'
    } > "$d/etc/issue.net"
    rm -f "$d/.pn" "$d/.ver"
}
GT="$T/gate-tree"
make_tree "$GT/desktop" desktop
make_tree "$GT/server"  server

if bash "$GATE" staged "$GT/desktop/ncz-payload" >/dev/null 2>&1; then
    ok "gate staged: clean medium RELEASE passes (desktop)"
else
    bad "gate staged: clean medium RELEASE passes (desktop)"
fi
if bash "$GATE" baked "$GT/desktop" >/dev/null 2>&1; then
    ok "gate baked: desktop rootfs passes (Desktop label)"
else
    bad "gate baked: desktop rootfs passes (Desktop label)"
fi
if bash "$GATE" baked "$GT/server" >/dev/null 2>&1; then
    ok "gate baked: server rootfs passes (Server label)"
else
    bad "gate baked: server rootfs passes (Server label)"
fi

# Negative controls: the gate must FAIL the build on every MINOR-001 failure
# mode. (Assemble the retired name at runtime, as test-ncz-ui.sh does, so this
# file's own sources stay clean under the check_nolive guard above.)
STALE_C="Maxi""milian"
# stale codename in the medium RELEASE -> must fail the staged gate
make_tree "$GT/stale-med" desktop
printf 'NCZ_PRODUCT_NAME="NCZ-OS"\nNCZ_RELEASE_VERSION="26.7"\nNCZ_RELEASE_CODENAME="%s"\n' "$STALE_C" > "$GT/stale-med/ncz-payload/RELEASE"
if bash "$GATE" staged "$GT/stale-med" >/dev/null 2>&1; then
    bad "gate staged: retired codename in medium RELEASE must FAIL"
else
    ok "gate staged: retired codename in medium RELEASE fails the gate"
fi
# stale codename in the baked rootfs os-release + issue -> must fail
make_tree "$GT/stale-baked" server
sed -i "s/${NCZ_RELEASE_CODENAME}/${STALE_C}/g" "$GT/stale-baked/etc/os-release" "$GT/stale-baked/etc/lsb-release" "$GT/stale-baked/etc/issue" "$GT/stale-baked/etc/issue.net"
if bash "$GATE" baked "$GT/stale-baked" >/dev/null 2>&1; then
    bad "gate baked: retired codename in rootfs identity files must FAIL"
else
    ok "gate baked: retired codename in rootfs identity files fails the gate"
fi
# variant mismatch: server BUILD_VARIANT but a Desktop-labelled PRETTY_NAME
make_tree "$GT/mismatch" server
sed -i 's/ Server/ Desktop/' "$GT/mismatch/etc/os-release"
if bash "$GATE" baked "$GT/mismatch" >/dev/null 2>&1; then
    bad "gate baked: variant label mismatch must FAIL"
else
    ok "gate baked: variant label mismatch fails the gate"
fi
# empty product label: RELEASE with no product name -> must fail
make_tree "$GT/empty" desktop
sed -i 's/^NCZ_PRODUCT_NAME=.*/NCZ_PRODUCT_NAME=""/' "$GT/empty/ncz-payload/RELEASE" "$GT/empty/usr/local/lib/cix-installer/RELEASE"
sed -i "s/${NCZ_PRODUCT_NAME} //" "$GT/empty/etc/os-release"
if bash "$GATE" baked "$GT/empty" >/dev/null 2>&1; then
    bad "gate baked: empty product label must FAIL"
else
    ok "gate baked: empty product label fails the gate"
fi
# An older, NON-retired codename in the medium RELEASE must fail: the copy
# must equal release.conf, not merely avoid the retired list.
make_tree "$GT/old-cod" desktop
sed -i 's/^NCZ_RELEASE_CODENAME=.*/NCZ_RELEASE_CODENAME="Orion"/' "$GT/old-cod/ncz-payload/RELEASE"
if bash "$GATE" staged "$GT/old-cod" >/dev/null 2>&1; then
    bad "gate staged: a non-current (non-retired) codename must FAIL"
else
    ok "gate staged: a non-current (non-retired) codename fails the gate"
fi
# A baked rootfs without the BUILD_VARIANT stamp must fail, not default.
make_tree "$GT/novariant" desktop
rm -f "$GT/novariant/usr/local/lib/cix-installer/BUILD_VARIANT"
if bash "$GATE" baked "$GT/novariant" >/dev/null 2>&1; then
    bad "gate baked: a missing BUILD_VARIANT stamp must FAIL"
else
    ok "gate baked: a missing BUILD_VARIANT stamp fails the gate"
fi
# A staged medium with no RELEASE at all must fail (nothing was checked).
mkdir -p "$GT/nomedium/ncz-payload"
if bash "$GATE" staged "$GT/nomedium" >/dev/null 2>&1; then
    bad "gate staged: a medium without RELEASE must FAIL"
else
    ok "gate staged: a medium without RELEASE fails the gate"
fi
# A baked rootfs missing issue.net (50-brand did not run fully) must fail.
make_tree "$GT/noissue" desktop
rm -f "$GT/noissue/etc/issue.net"
if bash "$GATE" baked "$GT/noissue" >/dev/null 2>&1; then
    bad "gate baked: a rootfs without issue.net must FAIL"
else
    ok "gate baked: a rootfs without issue.net fails the gate"
fi
# An issue banner with an older (non-retired) identity must fail.
make_tree "$GT/oldbanner" desktop
sed -i "s/${NCZ_RELEASE_CODENAME}/Orion/" "$GT/oldbanner/etc/issue"
if bash "$GATE" baked "$GT/oldbanner" >/dev/null 2>&1; then
    bad "gate baked: an issue banner with an older identity must FAIL"
else
    ok "gate baked: an issue banner with an older identity fails the gate"
fi
# The stock Debian factory copy of /etc/issue is not a generated banner.
make_tree "$GT/factory" desktop
mkdir -p "$GT/factory/usr/share/factory/etc"
printf '\\S\nKernel \\r on an \\m (\\l)\n' > "$GT/factory/usr/share/factory/etc/issue"
if bash "$GATE" baked "$GT/factory" >/dev/null 2>&1; then
    ok "gate baked: systemd factory issue copy is ignored"
else
    bad "gate baked: systemd factory issue copy is ignored"
fi
# A stale (non-retired) codename in os-release or lsb-release must fail.
for _f in os-release:VERSION_CODENAME lsb-release:DISTRIB_CODENAME; do
    make_tree "$GT/cod-${_f%%:*}" desktop
    sed -i "s/^${_f#*:}=.*/${_f#*:}=orion/" "$GT/cod-${_f%%:*}/etc/${_f%%:*}"
    if bash "$GATE" baked "$GT/cod-${_f%%:*}" >/dev/null 2>&1; then
        bad "gate baked: a stale ${_f#*:} must FAIL"
    else
        ok "gate baked: a stale ${_f#*:} fails the gate"
    fi
done
# A lower-cased retired codename in release.conf itself must be refused.
printf 'NCZ_PRODUCT_NAME="NCZ-OS"\nNCZ_RELEASE_VERSION="26.10"\nNCZ_RELEASE_CODENAME="%s"\n' \
    "$(printf '%s' "$STALE_C" | tr '[:upper:]' '[:lower:]')" > "$GT/lc-retired.conf"
if bash "$GATE" conf "$GT/lc-retired.conf" >/dev/null 2>&1; then
    bad "gate conf: a lower-cased retired codename must FAIL"
else
    ok "gate conf: a lower-cased retired codename fails the gate"
fi
# The image build must invoke the gate on every medium and every bake.
check_grep "$ROOT/build/iso/write-usb-image.py" "check-release-identity-gate.sh" \
    "write-usb-image.py: runs the identity gate on the staged medium"
check_grep "$ROOT/build/build-baked-rootfs.sh" "check-release-identity-gate.sh\" baked" \
    "build-baked-rootfs.sh: runs the identity gate on the baked rootfs"
# The gate runs for BOTH variants: write-usb-image.py gates every
# build_ncz_payload_tree() call (desktop and server are only _variant()
# branches of it) and build-baked-rootfs.sh gates every bake (VARIANT env).
check_grep "$ROOT/build/build-baked-rootfs.sh" 'VARIANT="${VARIANT:-desktop}"' \
    "build-baked-rootfs.sh: VARIANT env knob still drives the bake (both variants gated)"

echo "release-identity tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
