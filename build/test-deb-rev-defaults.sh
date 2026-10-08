#!/bin/bash
# test-deb-rev-defaults.sh -- a CLEAN CHECKOUT must build the NCZ libdrm and DKMS debs at the
# revision the version gate accepts, on both architectures, with NO environment overrides (r201:
# the runner needed LIBDRM_NCZ_REV=ncz2 and NCZ_DKMS_DEB_REV=2; arm64 even reused the r200 libdrm
# set). The defaults live in release.conf; this test proves the builders honour them, that the env
# override still works, and that editing the libdrm patch without bumping the revision fails early.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/revdef.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# shellcheck source=../release.conf
. "$ROOT/release.conf"
[ "$NCZ_LIBDRM_NCZ_REV" = ncz2 ] && ok "release.conf: libdrm default revision is ncz2" || bad "libdrm default revision is '$NCZ_LIBDRM_NCZ_REV'"
[ "$NCZ_DKMS_DEB_REV" = 2 ] && ok "release.conf: DKMS default revision is 2" || bad "DKMS default revision is '$NCZ_DKMS_DEB_REV'"
PATCH="$ROOT/docs/upstream-patches/libdrm-xf86drm-acpi-platform-identity.patch"
[ "$(sha256sum "$PATCH" | awk '{print $1}')" = "$NCZ_LIBDRM_PATCH_SHA256" ] \
    && ok "libdrm patch sha256 matches the pin in release.conf" || bad "libdrm patch changed without updating NCZ_LIBDRM_PATCH_SHA256 (and bumping NCZ_LIBDRM_NCZ_REV)"
if grep -nE 'ncz1|NCZ_DKMS_DEB_REV:-1' "$ROOT/build/build-libdrm-debs.sh" "$ROOT/build/build-dkms-debs.sh" >/dev/null; then
    bad "a builder still hardcodes the old ncz1 / :-1 default"; else ok "no hardcoded ncz1 default left in the builders"; fi

# --- libdrm: run the REAL builder with stub tools up to dpkg-buildpackage; capture the changelog ---
mkdir -p "$T/lroot/build" "$T/lroot/docs/upstream-patches" "$T/bin"
cp "$ROOT/build/build-libdrm-debs.sh" "$T/lroot/build/"; cp "$ROOT/release.conf" "$T/lroot/"
cp "$ROOT/build/lib" -r "$T/lroot/build/lib" 2>/dev/null
cp "$PATCH" "$T/lroot/docs/upstream-patches/"
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) f=$a ;; esac; done; : > "$(basename "$f")"
SH
cat > "$T/bin/dpkg-source" <<'SH'
#!/bin/sh
mkdir -p libdrm-2.4.134/debian; printf 'libdrm (2.4.134-3) unstable; urgency=medium\n\n  * x\n\n -- A <a@b>  Mon, 01 Jan 2026 00:00:00 +0000\n' > libdrm-2.4.134/debian/changelog
SH
printf '#!/bin/sh\nexit 0\n' > "$T/bin/patch"
cat > "$T/bin/dpkg-buildpackage" <<SH
#!/bin/sh
head -1 debian/changelog > "$T/changelog.top"; exit 7
SH
chmod +x "$T/bin/"*
run_libdrm() { ( cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T" "$@" bash "$T/lroot/build/build-libdrm-debs.sh" ) >"$T/lo" 2>&1; }
rm -f "$T/changelog.top"; run_libdrm
if grep -q '^libdrm (2.4.134-3+ncz2) forky' "$T/changelog.top" 2>/dev/null; then ok "libdrm builds 2.4.134-3+ncz2 from a clean environment"; else bad "libdrm default revision not applied: $(cat "$T/changelog.top" 2>/dev/null)"; cat "$T/lo"; fi
rm -f "$T/changelog.top"; run_libdrm LIBDRM_NCZ_REV=ncz9
grep -q '+ncz9)' "$T/changelog.top" 2>/dev/null && ok "LIBDRM_NCZ_REV still overrides" || bad "LIBDRM_NCZ_REV override ignored"
echo "# edited" >> "$T/lroot/docs/upstream-patches/libdrm-xf86drm-acpi-platform-identity.patch"
rm -f "$T/changelog.top"; run_libdrm
if [ ! -e "$T/changelog.top" ] && grep -q 'Bump NCZ_LIBDRM_NCZ_REV' "$T/lo"; then ok "editing the libdrm patch without a bump fails before building"; else bad "patch edit not caught"; cat "$T/lo"; fi

# --- libdrm: a published+pinned set for this version is REUSED, never rebuilt (toolchain drift trips the gate) ---
mkdir -p "$T/lroot/manifests" "$T/store/amd64/build/libdrm-debs"
cp "$ROOT/build/stage-build-inputs.sh" "$T/lroot/build/"
echo "# t" > "$T/lroot/manifests/build-inputs.tsv"
for n in libdrm2_2.4.134-3+ncz2_amd64.deb libdrm-common_2.4.134-3+ncz2_all.deb; do
    echo "deb $n" > "$T/store/amd64/build/libdrm-debs/$n"
    printf 'amd64\tbuild/libdrm-debs/%s\t%s\t8\tt\n' "$n" "$(sha256sum "$T/store/amd64/build/libdrm-debs/$n" | awk '{print $1}')" >> "$T/lroot/manifests/build-inputs.tsv"
done
cp "$PATCH" "$T/lroot/docs/upstream-patches/"   # undo the earlier edit
rm -f "$T/changelog.top"
( cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T" LIBDRM_ARCH=amd64 NCZ_BUILD_INPUTS_DIR="$T/store" bash "$T/lroot/build/build-libdrm-debs.sh" ) >"$T/lo2" 2>&1; rc=$?
if [ $rc = 0 ] && [ ! -e "$T/changelog.top" ] && grep -q 'reusing the published libdrm 2.4.134-3+ncz2' "$T/lo2" && [ -f "$T/lroot/build/libdrm-debs/libdrm2_2.4.134-3+ncz2_amd64.deb" ]; then
    ok "pinned published libdrm is staged and reused, no rebuild"; else bad "published libdrm not reused (rc=$rc)"; cat "$T/lo2"; fi
rm -f "$T/changelog.top"
( cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T" LIBDRM_ARCH=amd64 LIBDRM_REBUILD=1 NCZ_BUILD_INPUTS_DIR="$T/store" bash "$T/lroot/build/build-libdrm-debs.sh" ) >"$T/lo3" 2>&1
[ -e "$T/changelog.top" ] && ok "LIBDRM_REBUILD=1 forces a build" || { bad "LIBDRM_REBUILD=1 did not build"; cat "$T/lo3"; }
rm -f "$T/changelog.top"; rm -rf "$T/lroot/build/libdrm-debs"
( cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T" LIBDRM_ARCH=amd64 LIBDRM_NCZ_REV=ncz9 NCZ_BUILD_INPUTS_DIR="$T/store" bash "$T/lroot/build/build-libdrm-debs.sh" ) >"$T/lo4" 2>&1
[ -e "$T/changelog.top" ] && ok "a version with no pinned set (ncz9) falls back to building" || { bad "unpinned version did not build"; cat "$T/lo4"; }

# --- reuse path hardening (round-2 review) ---
run_pinned() { ( cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T" LIBDRM_ARCH=amd64 NCZ_BUILD_INPUTS_DIR="$T/store" "$@" bash "$T/lroot/build/build-libdrm-debs.sh" ); }
# (a) a pinned set that cannot be staged is FATAL and shown, never a silent rebuild
rm -rf "$T/lroot/build/libdrm-debs"; rm -f "$T/changelog.top"
cp "$T/store/amd64/build/libdrm-debs/libdrm2_2.4.134-3+ncz2_amd64.deb" "$T/good.deb"
echo corrupt >> "$T/store/amd64/build/libdrm-debs/libdrm2_2.4.134-3+ncz2_amd64.deb"
run_pinned >"$T/lo5" 2>&1; rc=$?
if [ $rc != 0 ] && [ ! -e "$T/changelog.top" ] && grep -q 'wrong sha256' "$T/lo5" && grep -q 'Not rebuilding on this host' "$T/lo5"; then
    ok "a pinned libdrm set that fails staging is fatal, shows why, and does not rebuild"
else bad "staging failure fell through (rc=$rc)"; cat "$T/lo5"; fi
cp "$T/good.deb" "$T/store/amd64/build/libdrm-debs/libdrm2_2.4.134-3+ncz2_amd64.deb"
# (b) the patch pin is checked on the reuse path too
rm -rf "$T/lroot/build/libdrm-debs"
cp "$PATCH" "$T/lroot/docs/upstream-patches/"; echo "# edited" >> "$T/lroot/docs/upstream-patches/libdrm-xf86drm-acpi-platform-identity.patch"
run_pinned >"$T/lo6" 2>&1; rc=$?
if [ $rc != 0 ] && grep -q 'Bump NCZ_LIBDRM_NCZ_REV' "$T/lo6" && [ ! -e "$T/lroot/build/libdrm-debs/libdrm2_2.4.134-3+ncz2_amd64.deb" ]; then
    ok "editing the patch is caught even when a pinned set exists"; else bad "patch edit not caught on the reuse path (rc=$rc)"; cat "$T/lo6"; fi
cp "$PATCH" "$T/lroot/docs/upstream-patches/"
# (c) older-revision debs in the output dir are cleared before the pinned set is staged
mkdir -p "$T/lroot/build/libdrm-debs"; echo old > "$T/lroot/build/libdrm-debs/libdrm2_2.4.134-3+ncz1_amd64.deb"; echo old > "$T/lroot/build/libdrm-debs/libdrm2-udeb_2.4.134-3+ncz1_amd64.udeb"
run_pinned >"$T/lo7" 2>&1; rc=$?
if [ $rc = 0 ] && ! ls "$T/lroot/build/libdrm-debs/" | grep -q 'ncz1' && [ -f "$T/lroot/build/libdrm-debs/libdrm2_2.4.134-3+ncz2_amd64.deb" ]; then
    ok "stale older-revision libdrm debs are removed before reuse"; else bad "stale ncz1 debs survived (rc=$rc)"; ls "$T/lroot/build/libdrm-debs"; cat "$T/lo7"; fi
# (d) reuse needs none of the source-build tools
mkdir -p "$T/emptybin"; rm -rf "$T/lroot/build/libdrm-debs"
( cd "$T" && env -i PATH="$T/emptybin:/usr/bin:/bin" HOME="$T" TMPDIR="$T" LIBDRM_ARCH=amd64 NCZ_BUILD_INPUTS_DIR="$T/store" bash "$T/lroot/build/build-libdrm-debs.sh" ) >"$T/lo8" 2>&1
grep -q 'reusing the published libdrm' "$T/lo8" && ok "reuse does not require curl/dpkg-source/dpkg-buildpackage" || { bad "reuse path needs source-build tools"; cat "$T/lo8"; }

# --- DKMS: run the REAL builder on a minimal asset tree, no env ---
if command -v dpkg-deb >/dev/null; then
    mkdir -p "$T/droot/build/lib" "$T/droot/assets/kernel/vpu/src"
    cp "$ROOT/build/build-dkms-debs.sh" "$T/droot/build/"; cp "$ROOT/release.conf" "$T/droot/"
    cp "$ROOT/build/lib/deb-version-gate.sh" "$T/droot/build/lib/"
    printf 'PACKAGE_NAME="cix-vpu-driver"\nPACKAGE_VERSION="1.0.2-ncz1"\nBUILT_MODULE_NAME[0]="amvx"\nDEST_MODULE_LOCATION[0]="/updates/dkms"\n' > "$T/droot/assets/kernel/vpu/dkms.conf"
    echo "int x;" > "$T/droot/assets/kernel/vpu/src/a.c"; : > "$T/index"
    ( cd "$T" && env -i PATH=/usr/bin:/bin HOME="$T" TMPDIR="$T" NCZ_PUBLISHED_INDEX="$T/index" bash "$T/droot/build/build-dkms-debs.sh" vpu ) >"$T/do" 2>&1
    if [ -f "$T/droot/build/dkms-debs/cix-vpu-driver-dkms_1.0.2-ncz1+ncz2_all.deb" ]; then ok "DKMS builder emits +ncz2 with no environment"; else bad "DKMS default revision not applied"; cat "$T/do"; ls "$T/droot/build/dkms-debs" 2>&1; fi
    ( cd "$T" && env -i PATH=/usr/bin:/bin HOME="$T" TMPDIR="$T" NCZ_DKMS_DEB_REV=7 NCZ_PUBLISHED_INDEX="$T/index" bash "$T/droot/build/build-dkms-debs.sh" vpu ) >"$T/do2" 2>&1
    [ -f "$T/droot/build/dkms-debs/cix-vpu-driver-dkms_1.0.2-ncz1+ncz7_all.deb" ] && ok "NCZ_DKMS_DEB_REV still overrides" || { bad "NCZ_DKMS_DEB_REV override ignored"; cat "$T/do2"; }
else
    echo "SKIP DKMS builder run: dpkg-deb not available"
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
