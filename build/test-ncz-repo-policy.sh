#!/bin/bash
# test-ncz-repo-policy.sh -- behavioural tests for the NCZ/Debian separation
# GATES (the apt resolution itself is build/test-apt-separation.sh):
#   1. check-ncz-repo-policy.sh   Debian-named package in the NCZ suite without an allowlist row FAILS
#   2. check-installed-apt-config two enabled NCZ repos / missing pin FAILS (r200 shape), new shape passes
#   3. deb-version-gate           same version + different bytes FAILS ("1.0 -> 1.0")
#   4. publisher policy           ncz-reprepro-publish.sh refuses a leaked Debian-named deb
#   5. ncz-update-check           classifies a T2 Mac's real r200 `apt list --upgradable` into
#                                 NCZ-OS / Debian groups (recorded fixtures)
# Each gate is exercised in BOTH directions (bad input fails, good input passes).
# Usage: build/test-ncz-repo-policy.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
FX="$HERE/testdata/apt-separation"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0 out; shift 2
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$out"; fi
    LAST="$out"
}

# shellcheck source=../post-install/lib/apt-separation.sh
. "$ROOT/post-install/lib/apt-separation.sh"

stanza() {  # name ver arch
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nSHA256: %064d\nFilename: pool/x.deb\n\n' "$1" "$2" "$3" 0
}

echo "=== 1. repo-content gate: check-ncz-repo-policy.sh ==="
{ stanza ncz-screensavers 0.8.10 amd64; stanza libdrm-common 2.4.134-3+ncz1 all
  stanza linux-image-cixmini 7.3.0 arm64; stanza zoder 0.2.1 arm64; stanza libdrm2 2.4.134-3+ncz1 arm64; } > "$T/good.Packages"
{ cat "$T/good.Packages"; stanza fonts-liberation 1:2.1.5-3build1 all; } > "$T/leak.Packages"
{ stanza libdrm-etnaviv1 2.4.134-3+ncz1 amd64; } > "$T/wrongarch.Packages"
{ stanza linux-image-amd64 7.1.9-1 amd64; } > "$T/debkernel.Packages"
expect_rc "good index passes" 0 "$ROOT/build/check-ncz-repo-policy.sh" "$T/good.Packages"
expect_rc "leaked fonts-liberation fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/leak.Packages"
case "$LAST" in *"fonts-liberation 1:2.1.5-3build1"*"not in the allowlist"*) ok "  message names the package" ;; *) bad "message lacks the package" "$LAST" ;; esac
expect_rc "allowlisted arm64-only libdrm-etnaviv1 on amd64 fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/wrongarch.Packages"
expect_rc "Debian kernel name in the NCZ suite fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/debkernel.Packages"
{ stanza libgtk4-layer-shell0 1.3.0-1+ncz20261013 arm64; } > "$T/g4ls-arm64.Packages"
{ stanza libgtk4-layer-shell0 1.3.0-1+ncz20261013 amd64; } > "$T/g4ls-amd64.Packages"
expect_rc "allowlisted arm64 libgtk4-layer-shell0 (patched layer-shell) passes" 0 "$ROOT/build/check-ncz-repo-policy.sh" "$T/g4ls-arm64.Packages"
expect_rc "libgtk4-layer-shell0 on amd64 fails (override is arm64 only)" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/g4ls-amd64.Packages"
ncz_apt_separation_pin_text | awk '/^Package: /{p=$0} /^Pin-Priority: 990/{print p}' | grep >/dev/null -w libgtk4-layer-shell0 \
    && ok "pin text gives libgtk4-layer-shell0 from the NCZ hosts priority 990" || bad "libgtk4-layer-shell0 missing from the 990 stanza"
gzip -kf "$T/leak.Packages"
expect_rc "gz index is read" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/leak.Packages.gz"
expect_rc "seed gate: manifests/components.tsv is clean" 0 "$ROOT/build/check-ncz-repo-policy.sh" --components
printf 'fonts-liberation\tstaged-deb\tstaged:x\tall\n' > "$T/comp.tsv"
expect_rc "seed gate: a Debian-named staged-deb fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" --components "$T/comp.tsv"
# the r200 live Buildkite amd64 index, recorded: contains fonts-liberation
expect_rc "recorded r200 Buildkite amd64 index fails (fonts-liberation)" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$FX/buildkite-r200-amd64.Packages.names"

echo "=== 1b. --live walks both architectures of both repos (local http fixture) ==="
if command -v python3 >/dev/null 2>&1; then
    LV="$T/live/dists/any"; mkdir -p "$LV/main/binary-amd64" "$LV/main/binary-arm64"
    : > "$LV/InRelease"; printf 'Origin: NCZ-OS\nCodename: any\n' > "$LV/Release"
    cp "$T/good.Packages" "$LV/main/binary-arm64/Packages"; cp "$T/leak.Packages" "$LV/main/binary-amd64/Packages"
    LPORT=$((20000 + RANDOM % 20000))
    ( cd "$T/live" && exec python3 -m http.server "$LPORT" --bind 127.0.0.1 >/dev/null 2>&1 ) & LPID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do python3 -c "import socket;socket.create_connection(('127.0.0.1',$LPORT),1)" 2>/dev/null && break; sleep 0.3; done
    NCZ_BK_BASE="http://127.0.0.1:$LPORT/dists/any" NCZ_R2_BASE="http://127.0.0.1:$LPORT/dists/any" \
        "$ROOT/build/check-ncz-repo-policy.sh" --live > "$T/live.out" 2>&1; lrc=$?
    [ "$lrc" = 1 ] && ok "--live fails on the leaked amd64 index (rc=1)" || bad "--live rc=$lrc" "$(cat "$T/live.out")"
    n=$(grep -c '^FAIL: .*fonts-liberation' "$T/live.out"); [ "$n" = 2 ] && ok "--live saw the leak in both repos (amd64 only)" || bad "--live leak count $n, wanted 2" "$(cat "$T/live.out")"
    grep -q 'examined' "$T/live.out" && grep -q 'binary-/' "$T/live.out" && bad "--live clobbered the architecture variable" || ok "--live requests binary-amd64 and binary-arm64, never binary-"
    grep -q 'OK: R2 Release Origin is NCZ-OS' "$T/live.out" && ok "--live checks the R2 Release Origin" || bad "--live skipped the Origin check" "$(cat "$T/live.out")"
    # apt-live-gate.sh modes against the same leaky fixture (preflight = warn, ship = fail)
    ( export NCZ_BK_BASE="http://127.0.0.1:$LPORT/dists/any" NCZ_R2_BASE="http://127.0.0.1:$LPORT/dists/any"
      env -u NCZ_APT_LIVE_GATE bash "$ROOT/build/apt-live-gate.sh" fail >/dev/null 2>&1; echo "fail=$?" >  "$T/gate.rc"
      env -u NCZ_APT_LIVE_GATE bash "$ROOT/build/apt-live-gate.sh" warn >/dev/null 2>&1; echo "warn=$?" >> "$T/gate.rc"
      env -u NCZ_APT_LIVE_GATE bash "$ROOT/build/apt-live-gate.sh" >/dev/null 2>&1;      echo "default=$?" >> "$T/gate.rc"
      NCZ_APT_LIVE_GATE=skip bash "$ROOT/build/apt-live-gate.sh" fail >/dev/null 2>&1;    echo "skip=$?" >> "$T/gate.rc"
      NCZ_APT_LIVE_GATE=fail bash "$ROOT/build/apt-live-gate.sh" warn >/dev/null 2>&1;    echo "envfail=$?" >> "$T/gate.rc" )
    grep -qx 'fail=1' "$T/gate.rc" && ok "apt-live-gate fail mode: a live leak exits 1 (ship gate)" || bad "apt-live-gate fail mode" "$(cat "$T/gate.rc")"
    grep -qx 'warn=0' "$T/gate.rc" && ok "apt-live-gate warn mode: the same leak exits 0 (preflight)" || bad "apt-live-gate warn mode" "$(cat "$T/gate.rc")"
    grep -qx 'default=1' "$T/gate.rc" && ok "apt-live-gate with no mode defaults to fail" || bad "apt-live-gate default" "$(cat "$T/gate.rc")"
    grep -qx 'skip=0' "$T/gate.rc" && grep -qx 'envfail=1' "$T/gate.rc" && ok "NCZ_APT_LIVE_GATE overrides the caller's default (skip, fail)" || bad "apt-live-gate env override" "$(cat "$T/gate.rc")"
    # ship-apt-gate.sh (build/ship-image.sh): always fail mode; env cannot weaken it; unreachable/empty index fails
    mkdir -p "$T/live/clean/dists/any/main/binary-amd64" "$T/live/clean/dists/any/main/binary-arm64" "$T/live/empty/dists/any/main/binary-amd64" "$T/live/empty/dists/any/main/binary-arm64"
    for d in clean empty; do : > "$T/live/$d/dists/any/InRelease"; printf 'Origin: NCZ-OS\n' > "$T/live/$d/dists/any/Release"; done
    cp "$T/good.Packages" "$T/live/clean/dists/any/main/binary-amd64/Packages"; cp "$T/good.Packages" "$T/live/clean/dists/any/main/binary-arm64/Packages"
    : > "$T/live/empty/dists/any/main/binary-amd64/Packages"; : > "$T/live/empty/dists/any/main/binary-arm64/Packages"
    shipgate() {  # name base [VAR=val ...] -> rc; output in $T/ship.out
        local b="$1"; shift
        env -u NCZ_APT_LIVE_GATE -u NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE NCZ_BK_BASE="$b" NCZ_R2_BASE="$b" "$@" bash "$ROOT/build/ship-apt-gate.sh" > "$T/ship.out" 2>&1
    }
    LEAK="http://127.0.0.1:$LPORT/dists/any"; CLEAN="http://127.0.0.1:$LPORT/clean/dists/any"; EMPTY="http://127.0.0.1:$LPORT/empty/dists/any"; DOWN="http://127.0.0.1:1/dists/any"
    shipgate "$LEAK";                                                            [ $? = 1 ] && ok "ship gate: leak, env unset -> FAIL" || bad "ship: leak/unset" "$(cat "$T/ship.out")"
    shipgate "$LEAK" NCZ_APT_LIVE_GATE=warn;                                     [ $? = 1 ] && ok "ship gate: leak, NCZ_APT_LIVE_GATE=warn exported (no override flag) -> still FAIL" || bad "ship: leak/warn" "$(cat "$T/ship.out")"
    grep -q 'ignoring NCZ_APT_LIVE_GATE=warn' "$T/ship.out" && ok "  ...and it says it ignored the variable" || bad "  no ignore notice" "$(cat "$T/ship.out")"
    shipgate "$LEAK" NCZ_APT_LIVE_GATE=skip;                                     [ $? = 1 ] && ok "ship gate: leak, NCZ_APT_LIVE_GATE=skip (no override flag) -> still FAIL" || bad "ship: leak/skip" "$(cat "$T/ship.out")"
    shipgate "$LEAK" NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE=1;                         [ $? = 1 ] && ok "ship gate: override flag alone (no NCZ_APT_LIVE_GATE) weakens nothing -> FAIL" || bad "ship: leak/allow-only" "$(cat "$T/ship.out")"
    shipgate "$LEAK" NCZ_APT_LIVE_GATE=warn NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE=1;  [ $? = 0 ] && ok "ship gate: leak, warn + explicit override flag -> allowed" || bad "ship: leak/warn+allow" "$(cat "$T/ship.out")"
    grep -q 'OVERRIDDEN' "$T/ship.out" && ok "  ...and logs the override loudly" || bad "  override not logged" "$(cat "$T/ship.out")"
    shipgate "$CLEAN";                                                           [ $? = 0 ] && ok "ship gate: clean live repos -> pass" || bad "ship: clean" "$(cat "$T/ship.out")"
    shipgate "$DOWN";                                                            [ $? != 0 ] && ok "ship gate: unreachable index -> FAIL (no verdict, no shipment)" || bad "ship: unreachable passed" "$(cat "$T/ship.out")"
    shipgate "$EMPTY";                                                           [ $? != 0 ] && ok "ship gate: empty/unparseable index -> FAIL" || bad "ship: empty passed" "$(cat "$T/ship.out")"
    # preflight (warn) stays tolerant of both
    ( export NCZ_BK_BASE="$DOWN" NCZ_R2_BASE="$DOWN"; env -u NCZ_APT_LIVE_GATE bash "$ROOT/build/apt-live-gate.sh" warn >/dev/null 2>&1; echo "pre-down=$?" > "$T/pre.rc"
      export NCZ_BK_BASE="$EMPTY" NCZ_R2_BASE="$EMPTY"; env -u NCZ_APT_LIVE_GATE bash "$ROOT/build/apt-live-gate.sh" warn >/dev/null 2>&1; echo "pre-empty=$?" >> "$T/pre.rc" )
    grep -qx 'pre-down=0' "$T/pre.rc" && grep -qx 'pre-empty=0' "$T/pre.rc" && ok "preflight (warn): unreachable and empty indexes only warn" || bad "preflight tolerance" "$(cat "$T/pre.rc")"
    grep -q 'ship-apt-gate.sh' "$HERE/ship-image.sh" && ok "ship-image.sh calls ship-apt-gate.sh" || bad "ship-image.sh does not call ship-apt-gate.sh"
    kill "$LPID" 2>/dev/null
fi

echo "=== 2. installed-config audit: check-installed-apt-config.sh ==="
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN" "$T/keys"
printf '#!/bin/sh\ncat\n' > "$FAKEBIN/gpg"; chmod +x "$FAKEBIN/gpg"
echo k > "$T/keys/buildkite-ncz-apt-keyring.asc"; echo k > "$T/keys/ncz-os-apt-keyring.asc"
# r200 shape: both repos enabled, only the kernel-purity pin, a t2.list
OLD="$T/old"; mkdir -p "$OLD/etc/apt/sources.list.d" "$OLD/etc/apt/preferences.d"
echo 'deb [signed-by=/x] https://packages.buildkite.com/ncz-os/ncz/any/ any main' > "$OLD/etc/apt/sources.list.d/ncz-os-apt-buildkite.list"
echo 'deb [signed-by=/x] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main' > "$OLD/etc/apt/sources.list.d/ncz-os-apt-r2.list"
echo 'deb [signed-by=/x] https://adityagarg8.github.io/t2-ubuntu-repo ./' > "$OLD/etc/apt/sources.list.d/t2.list"
( . "$ROOT/post-install/lib/kernel-purity.sh"; ncz_kernel_purity_pin_text > "$OLD/etc/apt/preferences.d/00-ncz-kernel-purity.pref" )
expect_rc "r200-shaped config fails" 1 "$ROOT/build/check-installed-apt-config.sh" "$OLD"
for want in "separation.*missing" "2 NCZ repos enabled" "t2.list present"; do
    printf '%s\n' "$LAST" | grep >/dev/null "$want" && ok "  reports: $want" || bad "  did not report: $want" "$LAST"
done
NEW="$T/new"; mkdir -p "$NEW/etc/apt/preferences.d"
( . "$ROOT/post-install/lib/kernel-purity.sh"; ncz_kernel_purity_pin_text > "$NEW/etc/apt/preferences.d/00-ncz-kernel-purity.pref" )
PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$NEW" >/dev/null
ncz_apt_write_separation_pin "$NEW" >/dev/null
echo 'deb [signed-by=/x] https://adityagarg8.github.io/t2-ubuntu-repo ./' > "$NEW/etc/apt/sources.list.d/t2.list"
expect_rc "new-shaped config passes" 0 "$ROOT/build/check-installed-apt-config.sh" "$NEW"
rm "$NEW/etc/apt/preferences.d/$NCZ_APT_PIN_NAME"
expect_rc "new config minus the pin file fails" 1 "$ROOT/build/check-installed-apt-config.sh" "$NEW"
ncz_apt_write_separation_pin "$NEW" >/dev/null
mv "$NEW/etc/apt/sources.list.d/ncz-os-apt-r2.list.disabled" "$NEW/etc/apt/sources.list.d/ncz-os-apt-r2.list"
expect_rc "new config with R2 re-enabled (two repos) fails" 1 "$ROOT/build/check-installed-apt-config.sh" "$NEW"
echo '# hand edit' >> "$NEW/etc/apt/preferences.d/$NCZ_APT_PIN_NAME"
expect_rc "hand-edited pin file fails" 1 "$ROOT/build/check-installed-apt-config.sh" "$NEW"
ncz_apt_write_separation_pin "$NEW" >/dev/null
echo '# hand edit' >> "$NEW/etc/apt/preferences.d/00-ncz-kernel-purity.pref"
expect_rc "hand-edited kernel-purity pin fails" 1 "$ROOT/build/check-installed-apt-config.sh" "$NEW"

echo "=== 3. version discipline: deb-version-gate.sh ==="
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb missing (sections 3-4)"; echo "=== 7. builders of published/staged debs normalise modes (umask 022) ==="
for b in $(grep -lE 'dpkg-deb (-[A-Za-z-]+ )*(--build|-b)\b|dpkg-deb -b|dpkg-buildpackage|fakeroot dpkg-deb' "$HERE"/*.sh "$ROOT"/staging/*/*.sh 2>/dev/null | grep -v '/test-'); do
    um="$(grep -nE '^umask 0?22' "$b" | head -1 | cut -d: -f1)"
    first="$(grep -nE 'dpkg-deb (-[A-Za-z-]+ )*(--build|-b)\b|dpkg-deb -b|dpkg-buildpackage|fakeroot dpkg-deb' "$b" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
    if [ -n "$um" ] && [ -n "$first" ] && [ "$um" -lt "$first" ]; then ok "${b#"$ROOT/"}: umask 022 (line $um) precedes the first build (line $first)"
    else bad "${b#"$ROOT/"}: no umask 022 before the first deb build (umask line '${um:-none}', build line '${first:-?}')"; fi
done
# dynamic: the same tree built under umask 002 and 022 has one content identity
ident_under() {  # umask builder-env... -> identity file
    local um="$1" out="$2"; shift 2
    ( umask "$um"; env NCZ_PUBLISHED_INDEX=/dev/null "$@" ) >/dev/null 2>&1
}
for um in 002 022; do
    ident_under "$um" x NCZ_USB_RECOVERY_OUT="$T/um$um/usb" bash "$HERE/build-usb-recovery-deb.sh"
    ident_under "$um" x NCZ_APT_POLICY_OUT="$T/um$um/pol" bash "$HERE/build-ncz-apt-policy-deb.sh"
done
for k in usb pol; do
    if ls "$T"/um002/$k/*.deb >/dev/null 2>&1 && ls "$T"/um022/$k/*.deb >/dev/null 2>&1; then
        ( . "$HERE/lib/deb-version-gate.sh"; ncz_deb_identity "$T"/um002/$k/*.deb > "$T/umi1"; ncz_deb_identity "$T"/um022/$k/*.deb > "$T/umi2" )
        cmp -s "$T/umi1" "$T/umi2" && ok "$k: built under umask 002 and 022 -> identical content identity" || bad "$k: identity depends on the umask" "$(diff "$T/umi1" "$T/umi2" | head -4)"
    else bad "$k: did not build under both umasks"; fi
done

echo "test-ncz-repo-policy: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
# shellcheck source=lib/deb-version-gate.sh
. "$HERE/lib/deb-version-gate.sh"
mkdeb() {  # out name ver arch marker [mtime-epoch] [mode] [description]
    local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: %s\n' "$2" "$3" "$4" "${8:-t}" > "$w/DEBIAN/control"
    echo "$5" > "$w/usr/share/x/f"
    [ -n "${7:-}" ] && chmod "$7" "$w/usr/share/x/f"
    [ -n "${6:-}" ] && touch -d "@$6" "$w/usr/share/x/f" "$w/usr/share/x" "$w/usr/share" "$w/usr"
    dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}
gate() { bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$1'"; }
mkdir -p "$T/pool"
mkdeb "$T/pub.deb" ncz-wallpapers-ncz 1.0 all published-bytes 1000000000
cp "$T/pub.deb" "$T/pool/ncz-wallpapers-ncz_1.0_all.deb"
PUBSHA="$(sha256sum "$T/pub.deb" | awk '{print $1}')"
printf 'Package: ncz-wallpapers-ncz\nVersion: 1.0\nArchitecture: all\nSHA256: %s\nFilename: ncz-wallpapers-ncz_1.0_all.deb\n\n' "$PUBSHA" > "$T/index"
export NCZ_PUBLISHED_INDEX="$T/index" NCZ_PUBLISHED_POOL="$T/pool"
mkdeb "$T/rebuilt.deb" ncz-wallpapers-ncz 1.0 all different-bytes 1000000000
expect_rc "same version, CHANGED FILE CONTENT is refused" 1 gate "$T/rebuilt.deb"
case "$LAST" in *"must bump their version"*) ok "  message says to bump" ;; *) bad "  no bump message" "$LAST" ;; esac
case "$LAST" in *"file: "*) ok "  message shows what differs" ;; *) bad "  no diff shown" "$LAST" ;; esac
mkdeb "$T/again.deb" ncz-wallpapers-ncz 1.0 all published-bytes 1700000000
cmp -s "$T/again.deb" "$T/pub.deb" && bad "fixture error: the rebuild is byte-identical" || ok "fixture: the unchanged rebuild differs in bytes (mtimes)"
expect_rc "same version, SAME content, different bytes (mtimes) is allowed" 0 gate "$T/again.deb"
case "$LAST" in *"same content as the published build"*) ok "  message says content is identical" ;; *) bad "  no identical-content message" "$LAST" ;; esac
mkdeb "$T/mode.deb" ncz-wallpapers-ncz 1.0 all published-bytes 1000000000 0755
expect_rc "same version, changed file MODE is refused" 1 gate "$T/mode.deb"
mkdeb "$T/desc.deb" ncz-wallpapers-ncz 1.0 all published-bytes 1000000000 "" "different description"
expect_rc "same version, changed CONTROL field is refused" 1 gate "$T/desc.deb"
expect_rc "identical bytes republished are idempotent" 0 gate "$T/pub.deb"
mkdeb "$T/bumped.deb" ncz-wallpapers-ncz 1.1 all different-bytes
expect_rc "bumped version passes" 0 gate "$T/bumped.deb"
expect_rc "unreachable index is a warning only with the explicit NCZ_VERSION_GATE_STRICT=0 override" 0 env NCZ_VERSION_GATE_STRICT=0 NCZ_PUBLISHED_INDEX="$T/does-not-exist" bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
expect_rc "an unreachable first index falls through to the next source (changed content still caught)" 1 env NCZ_PUBLISHED_INDEX="$T/does-not-exist $T/index" bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
expect_rc "unreachable index is an error by default (fail closed)" 1 env -u NCZ_VERSION_GATE_STRICT NCZ_PUBLISHED_INDEX="$T/does-not-exist" NCZ_VERSION_GATE_STRICT=1 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
expect_rc "published .deb unfetchable: warning only with NCZ_VERSION_GATE_STRICT=0" 0 env NCZ_VERSION_GATE_STRICT=0 NCZ_PUBLISHED_POOL="$T/nopool" bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/again.deb'"
expect_rc "published .deb unfetchable: error by default (fail closed)" 1 env -u NCZ_VERSION_GATE_STRICT NCZ_PUBLISHED_POOL="$T/nopool" NCZ_VERSION_GATE_STRICT=1 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/again.deb'"
# a real builder is reproducible in identity: ncz-usb-recovery built twice differs in bytes but not in content
if [ "$(dpkg --print-architecture 2>/dev/null)" != "" ]; then
    for i in 1 2; do NCZ_PUBLISHED_INDEX=/dev/null NCZ_USB_RECOVERY_OUT="$T/usb$i" bash "$HERE/build-usb-recovery-deb.sh" >/dev/null 2>&1; sleep 2; done
    if ls "$T"/usb1/*.deb >/dev/null 2>&1 && ls "$T"/usb2/*.deb >/dev/null 2>&1; then
        # Since 4a6506c5 the usb-recovery deb is byte-reproducible, so two
        # builds may be identical; either way the identity must match and the
        # gate must allow the rebuild.
        cmp -s "$T"/usb1/*.deb "$T"/usb2/*.deb && ok "two ncz-usb-recovery builds are byte-identical (reproducible)" || ok "two ncz-usb-recovery builds differ in bytes"
        ( . "$HERE/lib/deb-version-gate.sh"; ncz_deb_identity "$T"/usb1/*.deb > "$T/id1"; ncz_deb_identity "$T"/usb2/*.deb > "$T/id2" )
        cmp -s "$T/id1" "$T/id2" && ok "  ...and have the same content identity" || bad "  usb-recovery identity differs between runs" "$(diff "$T/id1" "$T/id2")"
        U1="$(ls "$T"/usb1/*.deb)"; U2="$(ls "$T"/usb2/*.deb)"; mkdir -p "$T/upool"; cp "$U1" "$T/upool/u.deb"
        printf 'Package: ncz-usb-recovery\nVersion: %s\nArchitecture: arm64\nSHA256: %s\nFilename: u.deb\n\n' "$(dpkg-deb -f "$U1" Version)" "$(sha256sum "$U1" | awk '{print $1}')" > "$T/uindex"
        expect_rc "gate: an unchanged real usb-recovery rebuild of a published version is allowed" 0 env NCZ_PUBLISHED_INDEX="$T/uindex" NCZ_PUBLISHED_POOL="$T/upool" NCZ_VERSION_GATE_STRICT=1 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$U2'"
    else
        bad "build-usb-recovery-deb.sh did not produce a deb"
    fi
fi
# the builders actually call the gate
for b in build-wallpaper-contrib-deb.sh build-usb-recovery-deb.sh build-dkms-debs.sh build-singularity-deb.sh build-libdrm-debs.sh build-ncz-apt-policy-deb.sh; do
    grep -q 'ncz_deb_version_gate' "$HERE/$b" && ok "$b calls the version gate" || bad "$b does not call the version gate"
done
# wallpaper builder default is no longer the republished 1.0
grep -q 'NCZ_WALLPAPER_PACK_VERSION:-1.0}' "$HERE/build-wallpaper-contrib-deb.sh" \
    && bad "wallpaper builder still defaults to the already-published 1.0" || ok "wallpaper builder default moved past 1.0"

echo "=== 4. publisher policy: build/ops/publish/ncz-reprepro-publish.sh ==="
PUB="$HERE/ops/publish/ncz-reprepro-publish.sh"
sed -n '/^# --- policy-begin/,/^# --- policy-end/p' "$PUB" > "$T/policy.sh"
[ -s "$T/policy.sh" ] && ok "policy block present in the publisher" || bad "policy block missing from the publisher"
grep -q '^ncz_publish_policy "\$TMPDEB" || exit' "$PUB" && ok "publisher calls the policy before includedeb" || bad "publisher does not call the policy"
pol_before="$(grep -n 'ncz_publish_policy "\$TMPDEB"' "$PUB" | cut -d: -f1)"; inc="$(grep -n '^reprepro -b "\$REPO" includedeb' "$PUB" | cut -d: -f1)"
[ -n "$pol_before" ] && [ -n "$inc" ] && [ "$pol_before" -lt "$inc" ] && ok "policy runs before includedeb" || bad "policy does not run before includedeb"
mkdir -p "$T/poldir"; cp "$ROOT/post-install/lib/apt-separation.sh" "$HERE/lib/deb-version-gate.sh" "$T/poldir/"
pub() { bash -c ". '$T/policy.sh'; NCZ_POLICY_DIR='$T/poldir' ncz_publish_policy '$1'"; }
: > "$T/empty-index"; export NCZ_PUBLISHED_INDEX="$T/empty-index"
export NCZ_POLICY_DIR="$T/poldir"
mkdeb "$T/fl.deb" fonts-liberation 1:2.1.5-3build1 all ubuntu
mkdeb "$T/ok1.deb" ncz-newthing 1.0 all x
mkdeb "$T/ok2.deb" libdrm2 2.4.134-3+ncz2 arm64 x
mkdeb "$T/ok3.deb" libdrm2 2.4.134-3+ncz2 amd64 x
mkdeb "$T/bad2.deb" libdrm-etnaviv1 2.4.134-3+ncz2 amd64 x
mkdeb "$T/dk.deb" linux-image-arm64 7.1.9-1 arm64 x
expect_rc "publisher refuses fonts-liberation (the r200 leak)" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/fl.deb'"
expect_rc "publisher accepts an ncz-* package" 0 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
expect_rc "publisher accepts the allowlisted libdrm2 on arm64" 0 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok2.deb'"
expect_rc "publisher accepts the allowlisted libdrm2 on amd64" 0 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok3.deb'"
expect_rc "publisher refuses the arm64-only libdrm-etnaviv1 on amd64 (libdrm2 is allowlisted for both arches since r201)" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/bad2.deb'"
expect_rc "publisher refuses a Debian kernel name" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/dk.deb'"
mkdeb "$T/np-pub.deb" ncz-newthing 1.0 all published-version 1000000000; cp "$T/np-pub.deb" "$T/pool/ncz-newthing_1.0_all.deb"
printf 'Package: ncz-newthing\nVersion: 1.0\nArchitecture: all\nSHA256: %s\nFilename: ncz-newthing_1.0_all.deb\n\n' "$(sha256sum "$T/np-pub.deb" | awk '{print $1}')" > "$T/idx2"
expect_rc "publisher refuses a same-version CHANGED-content republish" 1 env NCZ_PUBLISHED_INDEX="$T/idx2" NCZ_PUBLISHED_POOL="$T/pool" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
mkdeb "$T/np-again.deb" ncz-newthing 1.0 all published-version 1700000000
expect_rc "publisher accepts a byte-different rebuild of identical content" 0 env NCZ_PUBLISHED_INDEX="$T/idx2" NCZ_PUBLISHED_POOL="$T/pool" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/np-again.deb'"
# ncz-apt-policy must carry exactly the library deployed next to the publisher (the pin it publishes)
mkpol() {  # out libfile
    local w="$T/pw.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/ncz-apt-policy"
    printf 'Package: ncz-apt-policy\nVersion: 1.0.1\nArchitecture: all\nMaintainer: T <t@example.invalid>\nDescription: t\n' > "$w/DEBIAN/control"
    cp "$2" "$w/usr/share/ncz-apt-policy/apt-separation.sh"
    dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}
mkpol "$T/pol-ok.deb" "$T/poldir/apt-separation.sh"
{ cat "$T/poldir/apt-separation.sh"; echo '# an older pin'; } > "$T/old-lib.sh"; mkpol "$T/pol-old.deb" "$T/old-lib.sh"
expect_rc "publisher accepts ncz-apt-policy built from the deployed library" 0 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/pol-ok.deb'"
expect_rc "publisher REFUSES ncz-apt-policy whose packaged pin differs from the deployed library" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/pol-old.deb'"
case "$LAST" in *"different pin"*) ok "  message names the stale pin" ;; *) bad "  no pin message" "$LAST" ;; esac
mkdir -p "$T/poldir-old"; cp "$T/poldir/apt-separation.sh" "$T/poldir-old/"
sed '/^ncz_policy_deb_lib_check() {/,$d' "$T/poldir/deb-version-gate.sh" > "$T/poldir-old/deb-version-gate.sh"
grep -q '^ncz_policy_deb_lib_check()' "$T/poldir-old/deb-version-gate.sh" && bad "fixture: the old gate library still has the function"
expect_rc "publisher fails CLOSED for ncz-apt-policy when the deployed gate library predates the lib check" 1 env NCZ_POLICY_DIR="$T/poldir-old" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/pol-ok.deb'"
expect_rc "  ...while an ordinary package is unaffected by the old library" 0 env NCZ_POLICY_DIR="$T/poldir-old" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
# the policy directory default is $HOME-relative, never a fixed user's home
grep -Eq '/home/[a-z][a-z0-9_-]*/' "$T/policy.sh" && bad "the policy block still hard-codes a home directory" || ok "no hard-coded home directory in the policy block"
mkdir -p "$T/fakehome/ncz-policy"; cp "$T/poldir/"*.sh "$T/fakehome/ncz-policy/"
expect_rc "default policy dir is \$HOME/ncz-policy" 0 env -u NCZ_POLICY_DIR HOME="$T/fakehome" NCZ_PUBLISHED_INDEX="$T/empty-index" bash -c ". '$T/policy.sh'; [ \"\$NCZ_POLICY_DIR\" = '$T/fakehome/ncz-policy' ] && ncz_publish_policy '$T/ok1.deb'"
env -i PATH="$PATH" bash -c ". '$T/policy.sh'" >/dev/null 2>&1 && bad "no HOME and no NCZ_POLICY_DIR must fail closed" || ok "no HOME and no NCZ_POLICY_DIR fails closed"
rm -rf "$T/poldir2"; mkdir "$T/poldir2"
expect_rc "publisher fails closed when the policy library is missing" 1 env NCZ_POLICY_DIR="$T/poldir2" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
unset NCZ_PUBLISHED_INDEX NCZ_POLICY_DIR NCZ_PUBLISHED_POOL

echo "=== 5. update classification: assets/update-manager/ncz-update-check ==="
if command -v python3 >/dev/null 2>&1; then
    OUTJ="$(python3 -I - "$ROOT/assets/update-manager/ncz-update-check" "$FX" <<'PY'
import importlib.machinery, importlib.util, json, sys
path, fx = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("nuc", path)
spec = importlib.util.spec_from_loader("nuc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
listing = open(fx + "/t2mac-apt-list-upgradable.txt").read()
glob = open(fx + "/t2mac-policy-global.txt").read()
perpkg = open(fx + "/t2mac-policy-upgradable.txt").read()
parsed = [mm.groupdict() for mm in (m.LINE_RE.match(l.strip()) for l in listing.splitlines()) if mm]
origins = m.parse_source_origins(glob)
cands = m.parse_candidate_hosts(perpkg)
out = {}
for it in parsed:
    out[it["package"]] = m.group_for(cands.get(it["package"], []), origins, m.NCZ_HOSTS)
print(json.dumps(out))
PY
)"
    # shellcheck disable=SC2016
    chk() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get(sys.argv[2])==sys.argv[3] else 1)' "$OUTJ" "$1" "$2"; }
    chk fonts-liberation ncz-os && ok "fonts-liberation (Buildkite) -> ncz-os (the flagged r200 update, now labelled)" || bad "fonts-liberation group" "$OUTJ"
    for p in ncz-wallpapers-ncz ncz-wallpapers-singularity ncz-wallpapers-alex-jay-brady ncz-wallpapers-brandon-perlow; do
        chk "$p" ncz-os && ok "$p -> ncz-os" || bad "$p group" "$OUTJ"
    done
    for p in terser node-terser spirv-tools spirv-tools-dev spirv-tools-headers; do
        chk "$p" debian && ok "$p -> debian" || bad "$p group" "$OUTJ"
    done
    python3 -I - "$ROOT/assets/update-manager/ncz-update-check" <<'PY' && ok "file: sources are per path; foreign-arch Debian packages stay Debian; Debian Backports is Debian" || bad "file:/foreign-arch/backports classification"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("nuc", sys.argv[1])
spec = importlib.util.spec_from_loader("nuc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
glob = (" 500 file:/srv/offline forky/main amd64 Packages\n     release o=NCZ-OS,n=forky\n"
        " 500 file:/srv/debian-copy ./ Packages\n     release o=Debian,n=forky\n"
        " 500 https://deb.debian.org/debian forky-backports/main amd64 Packages\n     release o=Debian Backports,n=forky-backports\n     origin deb.debian.org\n"
        " 500 https://deb.debian.org/debian forky/main amd64 Packages\n     release o=Debian,n=forky\n     origin deb.debian.org\n")
o = m.parse_source_origins(glob)
ok = True
ok &= m.source_key("file:/srv/offline") != m.source_key("file:/srv/debian-copy")
ok &= m.group_for([m.source_key("file:/srv/debian-copy")], o, m.NCZ_HOSTS) == "debian"
ok &= m.group_for([m.source_key("file:///srv/offline")], o, m.NCZ_HOSTS) == "ncz-os"
ok &= m.classify_host("deb.debian.org", o, m.NCZ_HOSTS) == "debian"
pol = "libfoo:armhf:\n  Installed: 1\n  Candidate: 2\n  Version table:\n     2 500\n        500 https://deb.debian.org/debian forky/main armhf Packages\n"
c = m.parse_candidate_hosts(pol)
ok &= c.get("libfoo") == ["deb.debian.org"] and c.get("libfoo:armhf") == ["deb.debian.org"]
ok &= m.group_for(c["libfoo"], o, m.NCZ_HOSTS) == "debian"
pol2 = ("libfoo:\n  Installed: 1\n  Candidate: 2\n  Version table:\n     2 500\n        500 https://packages.buildkite.com/ncz-os/ncz/any any/main amd64 Packages\n"
        "libfoo:armhf:\n  Installed: 1\n  Candidate: 2\n  Version table:\n     2 500\n        500 https://deb.debian.org/debian forky/main armhf Packages\n")
c2 = m.parse_candidate_hosts(pol2)
ok &= c2["libfoo"] == ["packages.buildkite.com", "deb.debian.org"] and c2["libfoo:armhf"] == ["deb.debian.org"]  # native entry kept
sys.exit(0 if ok else 1)
PY
    python3 -I - "$ROOT/assets/update-manager/ncz-update-check" <<'PY' && ok "third-party host (Google, no NCZ/Debian origin) -> third-party" || bad "third-party classification"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("nuc", sys.argv[1])
spec = importlib.util.spec_from_loader("nuc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
o = m.parse_source_origins(" 500 https://dl.google.com/linux/chrome-stable/deb stable/main amd64 Packages\n     release v=1.0,o=Google LLC,a=stable\n     origin dl.google.com\n")
sys.exit(0 if m.group_for(["dl.google.com"], o, m.NCZ_HOSTS) == "third-party" else 1)
PY
else
    echo "SKIP: python3 missing"
fi

echo "=== 6. the gates are wired into the real gate scripts, not only their own tests ==="
grep -q 'check-ncz-repo-policy.sh" --components' "$HERE/preflight-sbom-check.sh" && grep -q 'apt-live-gate.sh" warn' "$HERE/preflight-sbom-check.sh" \
    && ok "preflight-sbom-check.sh runs the seed gate (fails) and the live gate in WARN mode" || bad "preflight-sbom-check.sh gate wiring"
grep -q 'check-installed-apt-config.sh' "$HERE/verify-installed-target.sh" \
    && ok "verify-installed-target.sh runs the installed-config audit" || bad "verify-installed-target.sh does not run the installed-config audit"
grep -q 'ncz-apt-policy' "$ROOT/manifests/install-extra.pkgs" && grep -q 'install-extra.pkgs:ncz-apt-policy' "$ROOT/sbom/expected-packages.txt" \
    && grep -q 'install-extra.pkgs:ncz-apt-policy' "$ROOT/sbom/expected-packages-amd64.txt" && grep -q '^ncz-apt-policy\b' "$ROOT/manifests/components.tsv" \
    && ok "ncz-apt-policy is in install-extra, both SBOMs and components.tsv" || bad "ncz-apt-policy is missing from a manifest/SBOM/registry"
# The payload debs are built, installed and ABI-gated against their exact versions; a new Depends would force a rewrap
# (new version, plugin rebuild) and make the Singularity deb uninstallable until ncz-apt-policy is published.
grep -q 'ncz-apt-policy' "$ROOT/build/build-singularity-deb.sh" && bad "ncz-singularity-desktop must NOT depend on ncz-apt-policy" \
    || ok "ncz-singularity-desktop control Depends is unchanged (no ncz-apt-policy)"
grep -q '^Depends: \$DEPENDS$' "$ROOT/build/build-singularity-deb.sh" && ok "Depends line is exactly the derived closure" || bad "Depends line changed"
grep -q 'ensure_policy' "$ROOT/assets/update-manager/ncz-update-apply" && ok "ncz-update-apply installs ncz-apt-policy" || bad "ncz-update-apply does not install ncz-apt-policy"

echo "=== 7. builders of published/staged debs normalise modes (umask 022) ==="
for b in $(grep -lE 'dpkg-deb (-[A-Za-z-]+ )*(--build|-b)\b|dpkg-deb -b|dpkg-buildpackage|fakeroot dpkg-deb' "$HERE"/*.sh "$ROOT"/staging/*/*.sh 2>/dev/null | grep -v '/test-'); do
    um="$(grep -nE '^umask 0?22' "$b" | head -1 | cut -d: -f1)"
    first="$(grep -nE 'dpkg-deb (-[A-Za-z-]+ )*(--build|-b)\b|dpkg-deb -b|dpkg-buildpackage|fakeroot dpkg-deb' "$b" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
    if [ -n "$um" ] && [ -n "$first" ] && [ "$um" -lt "$first" ]; then ok "${b#"$ROOT/"}: umask 022 (line $um) precedes the first build (line $first)"
    else bad "${b#"$ROOT/"}: no umask 022 before the first deb build (umask line '${um:-none}', build line '${first:-?}')"; fi
done
# dynamic: the same tree built under umask 002 and 022 has one content identity
ident_under() {  # umask builder-env... -> identity file
    local um="$1" out="$2"; shift 2
    ( umask "$um"; env NCZ_PUBLISHED_INDEX=/dev/null "$@" ) >/dev/null 2>&1
}
for um in 002 022; do
    ident_under "$um" x NCZ_USB_RECOVERY_OUT="$T/um$um/usb" bash "$HERE/build-usb-recovery-deb.sh"
    ident_under "$um" x NCZ_APT_POLICY_OUT="$T/um$um/pol" bash "$HERE/build-ncz-apt-policy-deb.sh"
done
for k in usb pol; do
    if ls "$T"/um002/$k/*.deb >/dev/null 2>&1 && ls "$T"/um022/$k/*.deb >/dev/null 2>&1; then
        ( . "$HERE/lib/deb-version-gate.sh"; ncz_deb_identity "$T"/um002/$k/*.deb > "$T/umi1"; ncz_deb_identity "$T"/um022/$k/*.deb > "$T/umi2" )
        cmp -s "$T/umi1" "$T/umi2" && ok "$k: built under umask 002 and 022 -> identical content identity" || bad "$k: identity depends on the umask" "$(diff "$T/umi1" "$T/umi2" | head -4)"
    else bad "$k: did not build under both umasks"; fi
done

echo "test-ncz-repo-policy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
