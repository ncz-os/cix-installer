#!/bin/bash
# test-ncz-repo-policy.sh -- behavioural tests for the NCZ/Debian separation
# GATES (the apt resolution itself is build/test-apt-separation.sh):
#   1. check-ncz-repo-policy.sh   Debian-named package in the NCZ suite without an allowlist row FAILS
#   2. check-installed-apt-config two enabled NCZ repos / missing pin FAILS (r200 shape), new shape passes
#   3. deb-version-gate           same version + different bytes FAILS ("1.0 -> 1.0")
#   4. publisher policy           ncz-reprepro-publish.sh refuses a leaked Debian-named deb
#   5. ncz-update-check           classifies MEDUSA's real r200 `apt list --upgradable` into
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
{ stanza libdrm2 2.4.134-3+ncz1 amd64; } > "$T/wrongarch.Packages"
{ stanza linux-image-amd64 7.1.9-1 amd64; } > "$T/debkernel.Packages"
expect_rc "good index passes" 0 "$ROOT/build/check-ncz-repo-policy.sh" "$T/good.Packages"
expect_rc "leaked fonts-liberation fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/leak.Packages"
case "$LAST" in *"fonts-liberation 1:2.1.5-3build1"*"not in the allowlist"*) ok "  message names the package" ;; *) bad "message lacks the package" "$LAST" ;; esac
expect_rc "allowlisted libdrm2 on the wrong arch fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/wrongarch.Packages"
expect_rc "Debian kernel name in the NCZ suite fails" 1 "$ROOT/build/check-ncz-repo-policy.sh" "$T/debkernel.Packages"
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
    kill "$LPID" 2>/dev/null
    [ "$lrc" = 1 ] && ok "--live fails on the leaked amd64 index (rc=1)" || bad "--live rc=$lrc" "$(cat "$T/live.out")"
    n=$(grep -c '^FAIL: .*fonts-liberation' "$T/live.out"); [ "$n" = 2 ] && ok "--live saw the leak in both repos (amd64 only)" || bad "--live leak count $n, wanted 2" "$(cat "$T/live.out")"
    grep -q 'examined' "$T/live.out" && grep -q 'binary-/' "$T/live.out" && bad "--live clobbered the architecture variable" || ok "--live requests binary-amd64 and binary-arm64, never binary-"
    grep -q 'OK: R2 Release Origin is NCZ-OS' "$T/live.out" && ok "--live checks the R2 Release Origin" || bad "--live skipped the Origin check" "$(cat "$T/live.out")"
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
    printf '%s\n' "$LAST" | grep -q "$want" && ok "  reports: $want" || bad "  did not report: $want" "$LAST"
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
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb missing (sections 3-4)"; echo "test-ncz-repo-policy: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
# shellcheck source=lib/deb-version-gate.sh
. "$HERE/lib/deb-version-gate.sh"
mkdeb() {  # out name ver arch marker
    local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: t\n' "$2" "$3" "$4" > "$w/DEBIAN/control"
    echo "$5" > "$w/usr/share/x/f"
    dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}
mkdeb "$T/pub.deb" ncz-wallpapers-ncz 1.0 all published-bytes
PUBSHA="$(sha256sum "$T/pub.deb" | awk '{print $1}')"
printf 'Package: ncz-wallpapers-ncz\nVersion: 1.0\nArchitecture: all\nSHA256: %s\n\n' "$PUBSHA" > "$T/index"
export NCZ_PUBLISHED_INDEX="$T/index"
mkdeb "$T/rebuilt.deb" ncz-wallpapers-ncz 1.0 all different-bytes
expect_rc "rebuilt with the SAME version and different bytes FAILS" 1 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
case "$LAST" in *"must bump their version"*) ok "  message says to bump" ;; *) bad "  no bump message" "$LAST" ;; esac
expect_rc "identical bytes republished are idempotent" 0 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/pub.deb'"
mkdeb "$T/bumped.deb" ncz-wallpapers-ncz 1.1 all different-bytes
expect_rc "bumped version passes" 0 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/bumped.deb'"
expect_rc "unreachable index is a warning offline" 0 env NCZ_PUBLISHED_INDEX="$T/does-not-exist" bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
expect_rc "an unreachable first index falls through to the next source (same-version leak still caught)" 1 env NCZ_PUBLISHED_INDEX="$T/does-not-exist $T/index" bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
expect_rc "unreachable index is an error when strict" 1 env NCZ_PUBLISHED_INDEX="$T/does-not-exist" NCZ_VERSION_GATE_STRICT=1 bash -c ". '$HERE/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/rebuilt.deb'"
# the builders actually call the gate
for b in build-wallpaper-contrib-deb.sh build-usb-recovery-deb.sh build-dkms-debs.sh build-singularity-deb.sh build-libdrm-debs.sh build-ncz-apt-policy-deb.sh; do
    grep -q 'ncz_deb_version_gate' "$HERE/$b" && ok "$b calls the version gate" || bad "$b does not call the version gate"
done
# wallpaper builder default is no longer the republished 1.0
grep -q 'NCZ_WALLPAPER_PACK_VERSION:-1.0}' "$HERE/build-wallpaper-contrib-deb.sh" \
    && bad "wallpaper builder still defaults to the already-published 1.0" || ok "wallpaper builder default moved past 1.0"

echo "=== 4. publisher policy: build/ops/argos/ncz-reprepro-publish.sh ==="
PUB="$HERE/ops/argos/ncz-reprepro-publish.sh"
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
mkdeb "$T/bad2.deb" libdrm2 2.4.134-3+ncz2 amd64 x
mkdeb "$T/dk.deb" linux-image-arm64 7.1.9-1 arm64 x
expect_rc "publisher refuses fonts-liberation (the r200 leak)" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/fl.deb'"
expect_rc "publisher accepts an ncz-* package" 0 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
expect_rc "publisher accepts the allowlisted libdrm2 on arm64" 0 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok2.deb'"
expect_rc "publisher refuses libdrm2 on amd64" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/bad2.deb'"
expect_rc "publisher refuses a Debian kernel name" 1 bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/dk.deb'"
printf 'Package: ncz-newthing\nVersion: 1.0\nArchitecture: all\nSHA256: %064d\n\n' 1 > "$T/idx2"
expect_rc "publisher refuses a same-version different-bytes republish" 1 env NCZ_PUBLISHED_INDEX="$T/idx2" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
rm -rf "$T/poldir2"; mkdir "$T/poldir2"
expect_rc "publisher fails closed when the policy library is missing" 1 env NCZ_POLICY_DIR="$T/poldir2" bash -c ". '$T/policy.sh'; ncz_publish_policy '$T/ok1.deb'"
unset NCZ_PUBLISHED_INDEX NCZ_POLICY_DIR

echo "=== 5. update classification: assets/update-manager/ncz-update-check ==="
if command -v python3 >/dev/null 2>&1; then
    OUTJ="$(python3 -I - "$ROOT/assets/update-manager/ncz-update-check" "$FX" <<'PY'
import importlib.machinery, importlib.util, json, sys
path, fx = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("nuc", path)
spec = importlib.util.spec_from_loader("nuc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
listing = open(fx + "/medusa-apt-list-upgradable.txt").read()
glob = open(fx + "/medusa-policy-global.txt").read()
perpkg = open(fx + "/medusa-policy-upgradable.txt").read()
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
grep -q 'check-ncz-repo-policy.sh" --components' "$HERE/preflight-sbom-check.sh" && grep -q 'check-ncz-repo-policy.sh" --live' "$HERE/preflight-sbom-check.sh" \
    && ok "preflight-sbom-check.sh runs the seed and live repo-content gates" || bad "preflight-sbom-check.sh does not run the repo-content gates"
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

echo "test-ncz-repo-policy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
