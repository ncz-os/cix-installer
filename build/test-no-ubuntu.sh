#!/bin/bash
# test-no-ubuntu.sh -- positive AND negative fixtures for the no-Ubuntu / forky-provenance gates:
#   build/check-no-ubuntu.sh (offline) and build/check-forky-provenance.sh (snapshot index).
# The leaked Ubuntu build fonts-liberation 1:2.1.5-3build1 MUST fail; Debian's 1:2.1.5-3 MUST pass.
# Usage: build/test-no-ubuntu.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
T="$(mktemp -d "${TMPDIR:-$HOME}/.no-ubuntu-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0 out; shift 2
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$out"; fi
    LAST="$out"
}
NOUB="$ROOT/build/check-no-ubuntu.sh"
PROV="$ROOT/build/check-forky-provenance.sh"

mkdeb() {  # out name ver arch maintainer [payload]
    local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: %s\nDescription: t\n' "$2" "$3" "$4" "$5" > "$w/DEBIAN/control"
    echo "${6:-p}" > "$w/usr/share/x/f"
    dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}
DEB_MAINT='Debian Fonts Task Force <debian-fonts@lists.debian.org>'
UBU_MAINT='Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>'

# --- fixtures: debs --------------------------------------------------------------------------
mkdir -p "$T/ubuntu-pool" "$T/debian-pool" "$T/ncz-pool" "$T/ubuntu-ver-pool" "$T/tpm-pool" "$T/vendor-pool" "$T/vendor-bad-pool"
mkdeb "$T/ubuntu-pool/fonts-liberation_1%3a2.1.5-3build1_all.deb" fonts-liberation 1:2.1.5-3build1 all "$UBU_MAINT"
mkdeb "$T/ubuntu-ver-pool/fonts-liberation_x.deb" fonts-liberation 1:2.1.5-3build1 all "$DEB_MAINT"   # Debian-looking maintainer, Ubuntu-style build suffix
mkdeb "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" fonts-liberation 1:2.1.5-3 all "$DEB_MAINT"
mkdeb "$T/ncz-pool/ncz-widget_1.0_all.deb" ncz-widget 1.0 all 'Jason Perlow <jperlow@gmail.com>'
mkdeb "$T/ncz-pool/libdrm2_2.4.134-3+ncz2_amd64.deb" libdrm2 2.4.134-3+ncz2 amd64 'Debian X Strike Force <debian-x@lists.debian.org>'
mkdeb "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb" libtss2-rc0t64 4.1.3-7 amd64 'Mathieu Trudel-Lapierre <cyphermox@ubuntu.com>'
mkdeb "$T/vendor-pool/acme-browser_1.0-1_amd64.deb" acme-browser 1.0-1 amd64 'Acme Corp <pkg@acme.example>'
mkdeb "$T/vendor-bad-pool/acme-browser_1.0-1_amd64.deb" acme-browser 1.0-1 amd64 'Acme Corp <pkg@acme.example>' tampered
sha() { sha256sum "$1" | awk '{print $1}'; }

# the pinned-snapshot index fixture: what Debian forky really carries
DEBSHA="$(sha "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb")"
TPMSHA="$(sha "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb")"
mkdir -p "$T/idx"
{
  printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3\nArchitecture: all\nSHA256: %s\n\n' "$DEBSHA"
  printf 'Package: libtss2-rc0t64\nVersion: 4.1.3-7\nArchitecture: amd64\nSHA256: %s\n\n' "$TPMSHA"
} > "$T/idx/Packages"
printf 'acme-browser\t1.0-1\tamd64\tAcme Corp\thttps://acme.example/acme-browser_1.0-1_amd64.deb\t%s\ttest vendor\n' "$(sha "$T/vendor-pool/acme-browser_1.0-1_amd64.deb")" > "$T/vendor-debs.tsv"
printf 'dl.acme.example\tstable\tAcme Corp\ttest vendor repo\n' > "$T/vendor-repos.tsv"
PV=(--index-dir "$T/idx" --vendor-debs "$T/vendor-debs.tsv" --vendor-repos "$T/vendor-repos.tsv")

echo "=== 1. check-no-ubuntu.sh (offline, Ubuntu evidence only) ==="
expect_rc "Ubuntu-maintained fonts-liberation 1:2.1.5-3build1 FAILS" 1 bash "$NOUB" --debs "$T/ubuntu-pool"
echo "$LAST" | grep -q 'Ubuntu-maintained' && ok "  reason names the Ubuntu maintainer" || bad "reason missing" "$LAST"
expect_rc "Debian fonts-liberation 1:2.1.5-3 passes" 0 bash "$NOUB" --debs "$T/debian-pool"
expect_rc "NCZ debs pass" 0 bash "$NOUB" --debs "$T/ncz-pool"
expect_rc "@ubuntu.com Debian maintainer is only a WARN offline" 0 bash "$NOUB" --debs "$T/tpm-pool"

echo "=== 2. check-forky-provenance.sh (snapshot index, fail closed) ==="
expect_rc "fonts-liberation 1:2.1.5-3build1 (Ubuntu maintainer) FAILS" 1 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/ubuntu-pool"
expect_rc "fonts-liberation 1:2.1.5-3build1 with a Debian-looking maintainer FAILS (not in forky snapshot)" 1 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/ubuntu-ver-pool"
echo "$LAST" | grep -q 'ubuntu' && ok "  failure names Ubuntu" || bad "no Ubuntu mention" "$LAST"
expect_rc "fonts-liberation 1:2.1.5-3 byte-identical to the snapshot passes" 0 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/debian-pool"
expect_rc "NCZ namespace + +ncz Debian-named rebuild pass" 0 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/ncz-pool"
expect_rc "Debian pkg with an @ubuntu.com maintainer passes when byte-identical to the snapshot" 0 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/tpm-pool"
mkdir -p "$T/tpm-other"; mkdeb "$T/tpm-other/libtss2-rc0t64_4.1.3-7_amd64.deb" libtss2-rc0t64 4.1.3-7 amd64 'Mathieu Trudel-Lapierre <cyphermox@ubuntu.com>' DIFFERENT-BYTES
expect_rc "same name/version, DIFFERENT bytes (an Ubuntu rebuild) FAILS" 1 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/tpm-other"
expect_rc "vendor deb with the pinned sha passes" 0 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/vendor-pool"
expect_rc "vendor deb with a different sha FAILS" 1 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/vendor-bad-pool"
mkdir -p "$T/unknown"; mkdeb "$T/unknown/mystery_1.0_all.deb" mystery 1.0 all 'Someone <s@example.invalid>'
expect_rc "unknown-origin package FAILS (no escape hatch)" 1 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --debs "$T/unknown"
expect_rc "no index => fails closed (rc 2)" 2 env NCZ_FORKY_INDEX_DIR= python3 -I "$ROOT/build/forky-provenance.py" --debs "$T/debian-pool"

echo "=== 3. dpkg status / Packages inputs ==="
printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' "$UBU_MAINT" > "$T/status.bad"
printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\n\n' "$DEB_MAINT" > "$T/status.good"
expect_rc "installed Ubuntu fonts-liberation FAILS" 1 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --status "$T/status.bad"
expect_rc "installed Debian fonts-liberation passes" 0 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --status "$T/status.good"
printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\nSHA256: %064d\n\n' "$UBU_MAINT" 0 > "$T/Packages.leak"
expect_rc "a Packages index carrying the leaked Ubuntu build FAILS" 1 bash "$NOUB" --packages "$T/Packages.leak"

echo "=== 4. rootfs: os-release + apt sources + pins ==="
mkroot() {  # dir
    mkdir -p "$1/etc/apt/sources.list.d" "$1/etc/apt/preferences.d" "$1/var/lib/dpkg"
    printf 'PRETTY_NAME="Debian GNU/Linux forky/sid"\nID=debian\nVERSION_CODENAME=forky\n' > "$1/etc/os-release"
    : > "$1/var/lib/dpkg/status"
}
PIN="$(sed -n 's/^NCZ_BASE_MIRROR_SNAPSHOT="\{0,1\}\([0-9TZ]*\)"\{0,1\}.*/\1/p' "$ROOT/release.conf" | head -1)"
mkroot "$T/r-good"
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s forky main contrib non-free non-free-firmware\n' "$PIN" > "$T/r-good/etc/apt/sources.list"
printf 'Types: deb\nURIs: https://packages.buildkite.com/ncz-os/ncz/any/\nSuites: any\nComponents: main\n\nTypes: deb\nURIs: https://dl.acme.example/\nSuites: stable\nComponents: main\n' > "$T/r-good/etc/apt/sources.list.d/x.sources"
printf 'Package: linux-image-*\nPin: release o=Debian\nPin-Priority: -1\n\nPackage: *\nPin: release n=forky\nPin-Priority: 500\n' > "$T/r-good/etc/apt/preferences.d/00.pref"
expect_rc "Debian forky rootfs (pinned snapshot + NCZ repo + vendor repo + negative pin) passes" 0 python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --rootfs "$T/r-good"
rootcase() {  # name want mutate-cmd...
    local n="$1" want="$2"; shift 2
    cp -a "$T/r-good" "$T/r-$n"; ( cd "$T/r-$n" && eval "$@" )
    expect_rc "rootfs $n" "$want" python3 -I "$ROOT/build/forky-provenance.py" "${PV[@]}" --rootfs "$T/r-$n"
}
rootcase osrel-ubuntu 1 "printf 'ID=ubuntu\nVERSION_CODENAME=resolute\n' > etc/os-release"
rootcase osrel-idlike 1 "printf 'ID=ncz\nID_LIKE=ubuntu\n' > etc/os-release"
rootcase osrel-ubucodename 1 "printf 'ID=ncz\nID_LIKE=debian\nUBUNTU_CODENAME=forky\n' > etc/os-release"
rootcase ncz-os-release-debian-like 0 "printf 'ID=ncz\nID_LIKE=debian\n' > etc/os-release"
rootcase ubuntu-ports 1 "echo 'deb http://ports.ubuntu.com/ubuntu-ports resolute main universe' > etc/apt/sources.list"
rootcase ubuntu-deb822 1 "printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble\nComponents: main\n' > etc/apt/sources.list.d/u.sources"
rootcase trixie 1 "echo 'deb https://deb.debian.org/debian trixie main' > etc/apt/sources.list"
rootcase forky-updates 1 "echo 'deb https://deb.debian.org/debian forky-updates main' > etc/apt/sources.list"
rootcase forky-security 1 "echo 'deb https://security.debian.org/debian-security forky-security main' > etc/apt/sources.list"
rootcase stable-backports 1 "echo 'deb https://deb.debian.org/debian stable-backports main' > etc/apt/sources.list"
rootcase other-snapshot 1 "echo 'deb https://snapshot.debian.org/archive/debian/20200101T000000Z forky main' > etc/apt/sources.list"
rootcase live-forky 0 "echo 'deb https://deb.debian.org/debian forky main' > etc/apt/sources.list"
rootcase unknown-vendor 1 "echo 'deb https://evil.example/repo stable main' > etc/apt/sources.list"
rootcase pin-trixie 1 "printf 'Package: *\nPin: release n=trixie\nPin-Priority: 900\n' > etc/apt/preferences.d/01.pref"
rootcase pin-ubuntu 1 "printf 'Package: *\nPin: release o=Ubuntu\nPin-Priority: 500\n' > etc/apt/preferences.d/01.pref"
rootcase disabled-source-ignored 0 "echo 'deb http://ports.ubuntu.com/ubuntu-ports resolute main' > etc/apt/sources.list.d/old.list.disabled"
rootcase installed-ubuntu-pkg 1 "printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' '$UBU_MAINT' > var/lib/dpkg/status"

echo "=== 5. SRC scan: Ubuntu archives / defaults in the build sources ==="
mkdir -p "$T/repo/build" "$T/repo/post-install/lib" "$T/repo/manifests"
cp "$ROOT/build/forky-provenance.py" "$T/repo/build/"; cp "$ROOT/build/check-no-ubuntu.sh" "$T/repo/build/"
cp "$ROOT/post-install/lib/apt-separation.sh" "$T/repo/post-install/lib/"; cp "$ROOT/release.conf" "$T/repo/"
echo '# ports.ubuntu.com is mentioned only in this comment' > "$T/repo/build/ok.sh"
export NCZ_NO_UBUNTU_ROOT="$T/repo"
expect_rc "comment-only mention passes" 0 bash "$T/repo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
echo 'MIRROR="${5:-http://ports.ubuntu.com/ubuntu-ports}"' > "$T/repo/build/bad.sh"
expect_rc "Ubuntu ports mirror default FAILS" 1 bash "$T/repo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
echo "$LAST" | grep -q 'bad.sh' && ok "  finding names the file" || bad "file not named" "$LAST"
echo 'SUITE="${3:-resolute}"' > "$T/repo/build/bad.sh"
expect_rc "'resolute' default suite FAILS" 1 bash "$T/repo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
printf 'FROM ubuntu:26.04\n' > "$T/repo/build/bad.sh"
expect_rc "ubuntu base container FAILS" 1 bash "$T/repo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
rm -f "$T/repo/build/bad.sh"; unset NCZ_NO_UBUNTU_ROOT

echo "=== 6. the real tree ==="
expect_rc "check-no-ubuntu.sh on this repo passes" 0 bash "$NOUB"
expect_rc "builders refuse Ubuntu/other suites (ncz_require_debian_forky)" 0 bash -c '
  . "'"$ROOT"'/build/lib/mirror-apt-opts.sh"
  ncz_require_debian_forky forky https://deb.debian.org/debian Debian &&
  ncz_require_debian_forky forky https://snapshot.debian.org/archive/debian/20261007T202437Z Debian &&
  ! ncz_require_debian_forky resolute http://ports.ubuntu.com/ubuntu-ports Ubuntu 2>/dev/null &&
  ! ncz_require_debian_forky forky http://ports.ubuntu.com/ubuntu-ports Debian 2>/dev/null &&
  ! ncz_require_debian_forky trixie https://deb.debian.org/debian Debian 2>/dev/null &&
  ! ncz_require_debian_forky forky https://deb.debian.org/debian Ubuntu 2>/dev/null &&
  ! ncz_require_debian_forky forky https://mirror.example.org/debian Debian 2>/dev/null'
for s in build-mgmt-rootfs.sh build-rescue-rootfs.sh build-baked-rootfs.sh; do
    grep -q 'ncz_require_debian_forky' "$ROOT/build/$s" && ok "$s calls ncz_require_debian_forky" || bad "$s lacks the Debian-forky guard"
done
grep -q 'ID_LIKE=debian' "$ROOT/post-install/50-brand.sh" && ! grep -q 'ID_LIKE=ubuntu\|UBUNTU_CODENAME' "$ROOT/post-install/50-brand.sh" \
    && ok "50-brand.sh no longer writes ID_LIKE=ubuntu / UBUNTU_CODENAME" || bad "50-brand.sh still claims Ubuntu lineage"

echo "---"
echo "no-ubuntu tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
