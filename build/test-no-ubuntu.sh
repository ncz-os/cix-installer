#!/bin/bash
# test-no-ubuntu.sh -- positive AND negative fixtures for the no-Ubuntu /
# forky-provenance gates:
#   build/check-no-ubuntu.sh       (offline; Ubuntu evidence only)
#   build/forky-provenance.py      (verified signed snapshot index + ledger)
#
# The full gate is exercised against an ISOLATED trust root ($T/repo): a copy of
# the verifier with its own release.conf, manifests/ and a throwaway keyring, plus
# a snapshot index signed by that key.  This is the sanctioned "isolated copy of
# trusted metadata/keyring" the shipped verifier has no bypass for.  No test path
# can weaken the trust root of the real checkout.
#
# The leaked Ubuntu build fonts-liberation 1:2.1.5-3build1 MUST fail; Debian's
# 1:2.1.5-3 MUST pass; a package that is only NAMED ncz-*/cix-* MUST fail.
#
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

# Required fixture tools: absent tools are a loud failure, never a silent
# green (a skipped fixture suite proves nothing).
for t in dpkg-deb gpg gpgv python3 xz cpio; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done

mkdeb() {  # out name ver arch maintainer [payload]
    local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: %s\nDescription: t\n' "$2" "$3" "$4" "$5" > "$w/DEBIAN/control"
    echo "${6:-p}" > "$w/usr/share/x/f"
    dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}
sha() { sha256sum "$1" | awk '{print $1}'; }

DEB_MAINT='Debian Fonts Task Force <debian-fonts@lists.debian.org>'
UBU_MAINT='Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>'

# --- fixtures: debs --------------------------------------------------------------------------
mkdir -p "$T/ubuntu-pool" "$T/debian-pool" "$T/ncz-pool" "$T/ubuntu-ver-pool" "$T/tpm-pool" \
         "$T/vendor-pool" "$T/vendor-bad-pool" "$T/nameonly-pool" "$T/plusncz-pool" "$T/unknown"
mkdeb "$T/ubuntu-pool/fonts-liberation_1%3a2.1.5-3build1_all.deb" fonts-liberation 1:2.1.5-3build1 all "$UBU_MAINT"
mkdeb "$T/ubuntu-ver-pool/fonts-liberation_x.deb" fonts-liberation 1:2.1.5-3build1 all "$DEB_MAINT"
mkdeb "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" fonts-liberation 1:2.1.5-3 all "$DEB_MAINT"
mkdeb "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb" libtss2-rc0t64 4.1.3-7 amd64 'Mathieu Trudel-Lapierre <cyphermox@ubuntu.com>'
mkdir -p "$T/tpm-other"; mkdeb "$T/tpm-other/libtss2-rc0t64_4.1.3-7_amd64.deb" libtss2-rc0t64 4.1.3-7 amd64 'Mathieu Trudel-Lapierre <cyphermox@ubuntu.com>' DIFFERENT-BYTES
mkdeb "$T/ncz-pool/ncz-widget_1.0_all.deb" ncz-widget 1.0 all 'Jason Perlow <jperlow@gmail.com>'
mkdeb "$T/ncz-pool/libdrm2_2.4.134-3+ncz2_amd64.deb" libdrm2 2.4.134-3+ncz2 amd64 'Debian X Strike Force <debian-x@lists.debian.org>'
mkdeb "$T/vendor-pool/acme-browser_1.0-1_amd64.deb" acme-browser 1.0-1 amd64 'Acme Corp <pkg@acme.example>'
mkdeb "$T/vendor-bad-pool/acme-browser_1.0-1_amd64.deb" acme-browser 1.0-1 amd64 'Acme Corp <pkg@acme.example>' tampered
# name-only/prefix-only NCZ claims that MUST fail (no ledger entry):
mkdeb "$T/nameonly-pool/cix-gpu-umd_2.0.0_arm64.deb" cix-gpu-umd 2.0.0 arm64 'CIX Technology <support@cixtech.com>'
mkdeb "$T/nameonly-pool/ncz-apt-policy_1.0_all.deb" ncz-apt-policy 1.0 all 'Jason Perlow <jperlow@gmail.com>'
mkdeb "$T/plusncz-pool/mystery_1.0+ncz1_amd64.deb" mystery 1.0+ncz1 amd64 'Nobody <n@example.invalid>'
mkdeb "$T/unknown/mystery_1.0_all.deb" mystery 1.0 all 'Someone <s@example.invalid>'

DEBSHA="$(sha "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb")"
TPMSHA="$(sha "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb")"
VSHA="$(sha "$T/vendor-pool/acme-browser_1.0-1_amd64.deb")"
DEBSIZE="$(wc -c < "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb")"
TPMSIZE="$(wc -c < "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb")"

# --- isolated trust root ---------------------------------------------------------------------
mkdir -p "$T/repo/build" "$T/repo/manifests/keys"
cp "$ROOT/build/forky-provenance.py" "$T/repo/build/"
printf 'NCZ_BASE_NAME="Debian"\nNCZ_BASE_CODENAME="forky"\nNCZ_BASE_MIRROR_SNAPSHOT="20260101T000000Z"\n' > "$T/repo/release.conf"
cat > "$T/repo/manifests/vendor-debs.tsv" <<EOF
# name	version	arch	vendor	source	sha256	note
acme-browser	1.0-1	amd64	Acme Corp	https://acme.example/x.deb	$VSHA	test vendor
EOF
NW_SHA="$(sha "$T/ncz-pool/ncz-widget_1.0_all.deb")"
LD_SHA="$(sha "$T/ncz-pool/libdrm2_2.4.134-3+ncz2_amd64.deb")"
cat > "$T/repo/manifests/ncz-packages.tsv" <<EOF
# name	version	arch	sha256	recipe	source_revision	note
ncz-widget	1.0	all	$NW_SHA	build/build-widget.sh	test revision 1	test NCZ build
libdrm2	2.4.134-3+ncz2	amd64	$LD_SHA	build/build-libdrm-debs.sh	test revision 1	test NCZ repack
EOF
cat > "$T/repo/manifests/vendor-repos.tsv" <<'EOF'
# kind	scheme	host	path	suite	approved	vendor	note
debian-pin	https	snapshot.debian.org	/archive/debian/<pin>	forky	yes	Debian	test pin
debian-live	https	deb.debian.org	/debian	forky	yes	Debian	test runtime
ncz	https	packages.buildkite.com	/ncz-os/ncz/any/	any	yes	NCZ	test ncz
vendor	https	acme.example	/repo	stable	yes	Acme	test vendor
vendor	https	apt.repos.intel.com	/openvino	ubuntu24	pending	Intel	test pending
offline	file	-	/cdrom/ncz-payload/apt-repo	/	yes	NCZ-OS	test flat media pool
offline	file	-	/cdrom	forky	yes	NCZ-OS	test installer data root
EOF

# keyring + signed Release + Packages indexes -----------------------------------------------
export GNUPGHOME="$T/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
cat > "$T/keyparams" <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: NCZ Test Signing Key
Name-Email: test@ncz.invalid
Expire-Date: 0
%commit
EOF
gpg --batch --gen-key "$T/keyparams" >/dev/null 2>&1 || { echo "SKIP: gpg key generation failed"; exit 0; }
gpg --batch --export > "$T/repo/manifests/keys/test-keyring.gpg"
KFPR="$(gpg --with-colons --fingerprint test@ncz.invalid | awk -F: '/^fpr:/{print $10; exit}')"

IDX="$T/idx"
COMPS="main/binary-amd64 main/binary-arm64 main/binary-all contrib/binary-amd64 contrib/binary-arm64 contrib/binary-all non-free/binary-amd64 non-free/binary-arm64 non-free/binary-all non-free-firmware/binary-amd64 non-free-firmware/binary-arm64 non-free-firmware/binary-all main/debian-installer/binary-amd64 main/debian-installer/binary-arm64"
mkdir -p "$IDX/dists/forky"
REL="$T/Release.body"
{
  printf 'Origin: Debian\nLabel: Debian\nSuite: testing\nCodename: forky\n'
  printf 'Architectures: all amd64 arm64\nComponents: main contrib non-free non-free-firmware\n'
  printf 'SHA256:\n'
} > "$REL"
for rel in $COMPS; do
    mkdir -p "$IDX/dists/forky/$rel"
    pf="$IDX/dists/forky/$rel/Packages"
    {
      printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\nFilename: pool/main/f/fonts-liberation/fonts-liberation_1%%3a2.1.5-3_all.deb\nSize: %s\nSHA256: %s\n\n' "$DEB_MAINT" "$DEBSIZE" "$DEBSHA"
      printf 'Package: libtss2-rc0t64\nVersion: 4.1.3-7\nArchitecture: amd64\nMaintainer: %s\nFilename: pool/main/libt/libtss2-rc0t64/libtss2-rc0t64_4.1.3-7_amd64.deb\nSize: %s\nSHA256: %s\n\n' 'Mathieu Trudel-Lapierre <cyphermox@ubuntu.com>' "$TPMSIZE" "$TPMSHA"
    } > "$pf"
    xz -f -k "$pf"
    printf ' %s %s %s\n' "$(sha "$pf.xz")" "$(wc -c < "$pf.xz")" "$rel/Packages.xz" >> "$REL"
done
mkdir -p "$IDX/pool/main/f/fonts-liberation" "$IDX/pool/main/libt/libtss2-rc0t64"
cp "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" "$IDX/pool/main/f/fonts-liberation/"
cp "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb" "$IDX/pool/main/libt/libtss2-rc0t64/"
gpg --batch --yes --clearsign -o "$IDX/dists/forky/InRelease" "$REL" >/dev/null 2>&1
IRSHA="$(sha "$IDX/dists/forky/InRelease")"; IRSIZE="$(wc -c < "$IDX/dists/forky/InRelease")"
cat > "$T/repo/manifests/forky-snapshot.tsv" <<EOF
snapshot	20260101T000000Z
codename	forky
components	main contrib non-free non-free-firmware
architectures	amd64 arm64 all
inrelease_path	dists/forky/InRelease
inrelease_sha256	$IRSHA
inrelease_size	$IRSIZE
keyring	manifests/keys/test-keyring.gpg
keyring_sha256	$(sha "$T/repo/manifests/keys/test-keyring.gpg")
signer_keys	$KFPR
EOF

PROV=("python3" "-I" "$T/repo/build/forky-provenance.py" "--index-dir" "$IDX")
prov() { "${PROV[@]}" "$@"; }

# =============================================================================================
echo "=== 1. check-no-ubuntu.sh (offline, Ubuntu evidence only) ==="
expect_rc "Ubuntu-maintained fonts-liberation 1:2.1.5-3build1 FAILS" 1 bash "$NOUB" --debs "$T/ubuntu-pool"
echo "$LAST" | grep -q 'Ubuntu-built' && ok "  reason names the Ubuntu build" || bad "reason missing" "$LAST"
expect_rc "Debian fonts-liberation 1:2.1.5-3 passes" 0 bash "$NOUB" --debs "$T/debian-pool"
expect_rc "NCZ debs pass" 0 bash "$NOUB" --debs "$T/ncz-pool"
expect_rc "@ubuntu.com Debian maintainer is only a WARN offline" 0 bash "$NOUB" --debs "$T/tpm-pool"

echo "=== 2. full gate: verified index (happy paths) ==="
expect_rc "fonts-liberation 1:2.1.5-3build1 (Ubuntu maintainer) FAILS" 1 prov --debs "$T/ubuntu-pool"
expect_rc "fonts-liberation 1:2.1.5-3build1 Debian-looking maintainer FAILS (not in snapshot)" 1 prov --debs "$T/ubuntu-ver-pool"
echo "$LAST" | grep -q 'ubuntu' && ok "  failure names Ubuntu" || bad "no Ubuntu mention" "$LAST"
expect_rc "fonts-liberation 1:2.1.5-3 byte-identical to the snapshot passes" 0 prov --debs "$T/debian-pool"
expect_rc "reviewed NCZ ledger entries pass" 0 prov --debs "$T/ncz-pool"
expect_rc "@ubuntu.com maintainer passes when byte-identical to the snapshot" 0 prov --debs "$T/tpm-pool"
expect_rc "same name/version, DIFFERENT bytes (Ubuntu rebuild) FAILS" 1 prov --debs "$T/tpm-other"
expect_rc "reviewed vendor deb with pinned sha passes" 0 prov --debs "$T/vendor-pool"
expect_rc "vendor deb with a different sha FAILS" 1 prov --debs "$T/vendor-bad-pool"
expect_rc "unknown-origin package FAILS (no escape hatch)" 1 prov --debs "$T/unknown"
expect_rc "no --index-dir => fails closed (rc 2)" 2 python3 -I "$T/repo/build/forky-provenance.py" --debs "$T/debian-pool"

echo "=== 2b. name/prefix is NOT proof of NCZ (regression) ==="
expect_rc "cix-* / ncz-* named debs with no ledger entry FAIL" 1 prov --debs "$T/nameonly-pool"
echo "$LAST" | grep -q 'unknown origin' && ok "  failure says unknown origin (not NCZ)" || bad "wrong reason" "$LAST"
expect_rc "a '+ncz' version with no ledger entry FAILS" 1 prov --debs "$T/plusncz-pool"
# schema: the reviewed NCZ ledger must carry a non-empty source revision (col 6),
# regardless of a non-empty free-text note (col 7).
cp -a "$T/repo" "$T/repo-badledger"
python3 - "$T/repo-badledger/manifests/ncz-packages.tsv" <<'PY'
import sys
p = sys.argv[1]; out = []
for line in open(p):
    if line.startswith("#") or not line.strip():
        out.append(line); continue
    f = line.rstrip("\n").split("\t")
    if len(f) >= 7:
        f[5] = ""          # blank source_revision; note (col 7) stays non-empty
    out.append("\t".join(f) + "\n")
open(p, "w").writelines(out)
PY
expect_rc "NCZ ledger with EMPTY source_revision FAILS (strict schema)" 2 \
  python3 -I "$T/repo-badledger/build/forky-provenance.py" --index-dir "$IDX" --debs "$T/debian-pool"
expect_rc "unchanged reviewed NCZ ledger still passes" 0 prov --debs "$T/ncz-pool"

echo "=== 2c. index integrity / env steering ==="
BADIDX="$T/badidx"; cp -a "$IDX" "$BADIDX"; printf 'tampered\n' >> "$BADIDX/dists/forky/InRelease"
expect_rc "tampered InRelease (signature/digest) FAILS closed" 1 python3 -I "$T/repo/build/forky-provenance.py" --index-dir "$BADIDX" --debs "$T/debian-pool"
BADIDX2="$T/badidx2"; cp -a "$IDX" "$BADIDX2"; truncate -s 20 "$BADIDX2/dists/forky/main/binary-amd64/Packages.xz" 2>/dev/null || head -c 20 "$IDX/dists/forky/main/binary-amd64/Packages.xz" > "$BADIDX2/dists/forky/main/binary-amd64/Packages.xz"
expect_rc "truncated Packages.xz FAILS closed" 1 python3 -I "$T/repo/build/forky-provenance.py" --index-dir "$BADIDX2" --debs "$T/debian-pool"
CFGIDX="$T/cfgidx"; cp -a "$IDX" "$CFGIDX"; rm -f "$CFGIDX/dists/forky/InRelease"
expect_rc "missing InRelease with fetch disabled FAILS closed" 1 python3 -I "$T/repo/build/forky-provenance.py" --index-dir "$CFGIDX" --debs "$T/debian-pool"
expect_rc "NCZ_APT_NCZ_HOSTS env override does NOT change the verdict" 0 env NCZ_APT_NCZ_HOSTS=evil.example.invalid "${PROV[@]}" --debs "$T/debian-pool"
expect_rc "NCZ_PROVENANCE_ROOT env override does NOT redirect the trust root" 0 env NCZ_PROVENANCE_ROOT=/nonexistent "${PROV[@]}" --debs "$T/debian-pool"
expect_rc "HOME pointing at a poisoned cache is irrelevant (explicit verified index)" 0 env HOME="$T/bad-home" "${PROV[@]}" --debs "$T/debian-pool"
expect_rc "--verify-mirror on the full upstream copy passes (rc 0)" 0 python3 -I "$T/repo/build/forky-provenance.py" --verify-mirror "$IDX" --index-dir "$IDX"
BADPOOL="$T/badpoolmir"; cp -a "$IDX" "$BADPOOL"; printf 'x' >> "$BADPOOL/pool/main/f/fonts-liberation/fonts-liberation_1%3a2.1.5-3_all.deb"
expect_rc "--verify-mirror rejects a tampered pool deb (real bytes)" 1 python3 -I "$T/repo/build/forky-provenance.py" --verify-mirror "$BADPOOL" --index-dir "$IDX"

echo "=== 3. dpkg status / Packages inputs (fail closed) ==="
printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' "$UBU_MAINT" > "$T/status.bad"
printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\n\n' "$DEB_MAINT" > "$T/status.good"
expect_rc "installed Ubuntu fonts-liberation FAILS" 1 prov --status "$T/status.bad"
expect_rc "installed Debian fonts-liberation passes" 0 prov --status "$T/status.good"
printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' "$UBU_MAINT" > "$T/status.nostatus"
expect_rc "status record with NO Status field FAILS (not silently skipped)" 1 prov --status "$T/status.nostatus"
printf 'Package: fonts-liberation\nStatus: install ok unpacked\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' "$UBU_MAINT" > "$T/status.unpacked"
expect_rc "unpacked Ubuntu record FAILS (no longer skipped)" 1 prov --status "$T/status.unpacked"
printf 'Package: x\nStatus: install ok installed\nArchitecture: all\n\n' > "$T/status.malformed"
expect_rc "malformed status record (missing Version) FAILS" 1 prov --status "$T/status.malformed"
expect_rc "missing --status file FAILS" 1 prov --status "$T/nope.status"
printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\nSHA256: %064d\n\n' "$UBU_MAINT" 0 > "$T/Packages.leak"
expect_rc "a Packages index carrying the leaked Ubuntu build FAILS" 1 bash "$NOUB" --packages "$T/Packages.leak"
expect_rc "missing --packages file FAILS" 1 prov --packages "$T/nope.Packages"
mkdir -p "$T/empty-pool"
expect_rc "empty --debs pool FAILS (no silent zero)" 1 prov --debs "$T/empty-pool"
expect_rc "missing --debs dir FAILS" 1 prov --debs "$T/nope-dir"

echo "=== 4. rootfs: os-release, apt sources, pins ==="
mkroot() {
    mkdir -p "$1/etc/apt/sources.list.d" "$1/etc/apt/preferences.d" "$1/var/lib/dpkg"
    printf 'PRETTY_NAME="Debian GNU/Linux forky/sid"\nID=debian\nVERSION_CODENAME=forky\n' > "$1/etc/os-release"
    printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\n\n' "$DEB_MAINT" > "$1/var/lib/dpkg/status"
}
mkroot "$T/r-good"
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20260101T000000Z forky main contrib non-free non-free-firmware\n' > "$T/r-good/etc/apt/sources.list"
printf 'Types: deb\nURIs: https://packages.buildkite.com/ncz-os/ncz/any/\nSuites: any\nComponents: main\n' > "$T/r-good/etc/apt/sources.list.d/ncz.sources"
printf 'Package: *\nPin: release n=forky\nPin-Priority: 500\n' > "$T/r-good/etc/apt/preferences.d/00.pref"
expect_rc "forky rootfs (pinned snapshot + NCZ repo + forky pin) passes" 0 prov --rootfs "$T/r-good"
rootcase() { local n="$1" want="$2"; shift 2; cp -a "$T/r-good" "$T/r-$n"; ( cd "$T/r-$n" && eval "$@" ); expect_rc "rootfs $n" "$want" prov --rootfs "$T/r-$n"; }
rootcase osrel-ubuntu 1 "printf 'ID=ubuntu\nVERSION_CODENAME=resolute\n' > etc/os-release"
rootcase osrel-idlike 1 "printf 'ID=ncz\nID_LIKE=ubuntu\n' > etc/os-release"
rootcase osrel-ubucodename 1 "printf 'ID=ncz\nID_LIKE=debian\nUBUNTU_CODENAME=forky\n' > etc/os-release"
rootcase ubuntu-ports 1 "echo 'deb http://ports.ubuntu.com/ubuntu-ports resolute main universe' > etc/apt/sources.list"
rootcase ubuntu-deb822 1 "printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble\nComponents: main\n' > etc/apt/sources.list.d/u.sources"
rootcase other-snapshot 1 "echo 'deb https://snapshot.debian.org/archive/debian/20200101T000000Z forky main' > etc/apt/sources.list"
rootcase live-forky 0 "echo 'deb https://deb.debian.org/debian forky main' > etc/apt/sources.list"
rootcase live-trixie 1 "echo 'deb https://deb.debian.org/debian trixie main' > etc/apt/sources.list"
rootcase ncz-wrong-suite 1 "echo 'deb https://packages.buildkite.com/ncz-os/ncz/any/ resolute main' > etc/apt/sources.list.d/x.list"
rootcase ncz-any-ok 0 "echo 'deb https://packages.buildkite.com/ncz-os/ncz/any/ any main' > etc/apt/sources.list.d/x.list"
rootcase vendor-exact-ok 0 "echo 'deb https://acme.example/repo stable main' > etc/apt/sources.list.d/v.list"
rootcase vendor-wrong-suite 1 "echo 'deb https://acme.example/repo noble main' > etc/apt/sources.list.d/v.list"
rootcase intel-pending 1 "echo 'deb https://apt.repos.intel.com/openvino ubuntu24 main' > etc/apt/sources.list.d/i.list"
rootcase offline-focal 1 "echo 'deb file:/mnt/pool focal main' > etc/apt/sources.list"
rootcase offline-not-bound 1 "echo 'deb file:/cdrom forky main' > etc/apt/sources.list"
rootcase offline-unknown-root 1 "echo 'deb file:/mnt/pool forky main' > etc/apt/sources.list"
rootcase offline-unscanned-child 1 "echo 'deb file:///cdrom/unscanned-repo forky main' > etc/apt/sources.list"
rootcase pin-forky 0 "printf 'Package: *\nPin: release n=forky\nPin-Priority: 900\n' > etc/apt/preferences.d/01.pref"
rootcase pin-focal 1 "printf 'Package: *\nPin: release n=focal\nPin-Priority: 900\n' > etc/apt/preferences.d/01.pref"
rootcase pin-trixie 1 "printf 'Package: *\nPin: release n=trixie\nPin-Priority: 900\n' > etc/apt/preferences.d/01.pref"
rootcase pin-ubuntu-origin 1 "printf 'Package: *\nPin: release o=Ubuntu\nPin-Priority: 500\n' > etc/apt/preferences.d/01.pref"
rootcase pin-noblank-noble 1 "printf 'Package: *\nPin: release n=forky\nPin-Priority: -1\nPackage: *\nPin: release n=noble\nPin-Priority: 900\n' > etc/apt/preferences.d/01.pref"
rootcase pin-ncz-origin 0 "printf 'Package: *\nPin: origin packages.buildkite.com\nPin-Priority: 990\n' > etc/apt/preferences.d/01.pref"
rootcase installed-ubuntu-pkg 1 "printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' '$UBU_MAINT' > var/lib/dpkg/status"
rootcase disabled-source-ignored 0 "echo 'deb http://ports.ubuntu.com/ubuntu-ports resolute main' > etc/apt/sources.list.d/old.list.disabled"
rootcase no-status 1 "rm -f var/lib/dpkg/status"
rootcase status-missing-field 1 "printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\n\n' '$DEB_MAINT' > var/lib/dpkg/status"
rootcase empty-status 1 ": > var/lib/dpkg/status"
rootcase status-no-package 1 "printf 'Version: 1\nArchitecture: all\nStatus: install ok installed\n\n' > var/lib/dpkg/status"
rootcase uri-query 1 "echo 'deb https://acme.example/repo?x=1 stable main' > etc/apt/sources.list.d/v.list"
rootcase uri-cred 1 "echo 'deb https://user@acme.example/repo stable main' > etc/apt/sources.list.d/v.list"
rootcase uri-port 1 "echo 'deb https://acme.example:8443/repo stable main' > etc/apt/sources.list.d/v.list"
rootcase uri-traversal 1 "echo 'deb https://acme.example/repo/../evil stable main' > etc/apt/sources.list.d/v.list"
rootcase dup-pin 1 "printf 'Package: *\nPin: release n=noble\nPin: release n=trixie\nPin-Priority: 900\n' > etc/apt/preferences.d/01.pref"
rootcase deb822-dup-field 1 "printf 'Types: deb\nURIs: https://acme.example/repo\nURIs: https://evil.example/x\nSuites: stable\nComponents: main\n' > etc/apt/sources.list.d/d.sources"
rootcase deb822-no-types 1 "printf 'URIs: https://acme.example/repo\nSuites: stable\nComponents: main\n' > etc/apt/sources.list.d/d.sources"
rootcase deb822-empty-uris 1 "printf 'Types: deb\nURIs:\nSuites: stable\nComponents: main\n' > etc/apt/sources.list.d/d.sources"

echo "=== 4b. real squashfs layer (unsquashfs) ==="
SQ="$T/sq"; rm -rf "$SQ"; mkdir -p "$SQ/var/lib/dpkg" "$SQ/etc/apt/preferences.d"
printf 'ID=debian\nID_LIKE=debian\nVERSION_CODENAME=forky\n' > "$SQ/etc/os-release"
printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\n\n' "$DEB_MAINT" > "$SQ/var/lib/dpkg/status"
printf 'Package: *\nPin: release n=forky\nPin-Priority: 500\n' > "$SQ/etc/apt/preferences.d/00.pref"
mksquashfs "$SQ" "$T/good.squashfs" -noappend -quiet -processors 1 >/dev/null 2>&1
expect_rc "real squashfs with a Debian package passes" 0 "${PROV[@]}" --squashfs "$T/good.squashfs"
printf 'this is not a squashfs image' > "$T/trunc.squashfs"
expect_rc "truncated squashfs FAILS closed" 1 "${PROV[@]}" --squashfs "$T/trunc.squashfs"
printf 'Package: fonts-liberation\nStatus: install ok unpacked\nVersion: 1:2.1.5-3build1\nArchitecture: all\nMaintainer: %s\n\n' "$UBU_MAINT" > "$SQ/var/lib/dpkg/status"
mksquashfs "$SQ" "$T/ubuntu.squashfs" -noappend -quiet -processors 1 >/dev/null 2>&1
expect_rc "squashfs carrying an unpacked Ubuntu package FAILS" 1 "${PROV[@]}" --squashfs "$T/ubuntu.squashfs"

echo "=== 4c. real initrd (magic sniff + concatenated newc + escapes) ==="
IRD="$T/ird"; rm -rf "$IRD"; mkdir -p "$IRD"
# POSITIVE fixtures are produced by GNU cpio (never a hand serializer): bare
# "initrd", gzip/xz/zstd, two concatenated archives, a raw-newc +
# compressed-tail mix, and a valid 070702 crc archive.  NEGATIVES mutate the
# GNU output (names/targets) or flip a data byte.
cat > "$T/mkinitrd.py" <<'PY'
import gzip, lzma, os, shutil, subprocess, sys
outdir, deb, ubu = sys.argv[1], sys.argv[2], sys.argv[3]
deb_b = open(deb, "rb").read(); ubu_b = open(ubu, "rb").read()
status = (b"Package: fonts-liberation\nStatus: install ok installed\n"
          b"Version: 1:2.1.5-3\nArchitecture: all\n"
          b"Maintainer: Debian Fonts Task Force <debian-fonts@lists.debian.org>\n\n")

def mkroot(name):
    d = os.path.join(outdir, "tree_" + name)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d); return d

def add(root, rel, data):
    p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)

def names(root):
    out = []
    for dp, dns, fns in os.walk(root):
        for n in dns + fns:
            out.append(os.path.relpath(os.path.join(dp, n), root))
    return sorted(out)

def cpio(root, fmt):
    r = subprocess.run(["cpio", "-o", "-H", fmt], cwd=root,
                       input=("\n".join(names(root)) + "\n").encode(),
                       capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr.decode()); raise SystemExit(1)
    return r.stdout

r = mkroot("main"); add(r, "boot/fonts-liberation_1%3a2.1.5-3_all.deb", deb_b)
add(r, "var/lib/dpkg/status", status)
nc = cpio(r, "newc")
open(os.path.join(outdir, "initrd"), "wb").write(nc)          # bare, no suffix
open(os.path.join(outdir, "nc.gz"), "wb").write(gzip.compress(nc))
open(os.path.join(outdir, "nc.xz"), "wb").write(lzma.compress(nc))
open(os.path.join(outdir, "nc.raw"), "wb").write(nc)

r2 = mkroot("main2"); add(r2, "boot/x.deb", deb_b)
nc2 = cpio(r2, "newc")
open(os.path.join(outdir, "concat"), "wb").write(nc + nc2)     # two archives
open(os.path.join(outdir, "mixed"), "wb").write(nc + gzip.compress(nc2))

r3 = mkroot("crc"); add(r3, "boot/y.deb", deb_b)
crc = bytearray(cpio(r3, "crc"))
open(os.path.join(outdir, "crc"), "wb").write(bytes(crc))
at = bytes(crc).find(deb_b[:24])
if at < 0:
    at = max(i for i, b in enumerate(crc) if b) - 1
bad = bytearray(crc); bad[at] ^= 0xFF
open(os.path.join(outdir, "crc_bad"), "wb").write(bytes(bad))

r4 = mkroot("esc"); add(r4, "aaaaaa", b"x")
esc = cpio(r4, "newc")
open(os.path.join(outdir, "escape"), "wb").write(esc.replace(b"aaaaaa\x00", b"../xxx\x00", 1))
open(os.path.join(outdir, "abs"), "wb").write(esc.replace(b"aaaaaa\x00", b"/etc/x\x00", 1))

r5 = mkroot("sym"); os.symlink("aaaaaa", os.path.join(r5, "link"))
sy = cpio(r5, "newc")
# r5 + absolute symlink target: etc/mtab -> /proc/mounts class.  SAFE: it binds
# to the virtual archive root and is never materialised onto the host.
open(os.path.join(outdir, "symlink"), "wb").write(sy.replace(b"aaaaaa\x00", b"/etc/p\x00", 1))

r7 = mkroot("symesc"); os.symlink("../../etc/passwd", os.path.join(r7, "link"))
open(os.path.join(outdir, "symlink_escape"), "wb").write(cpio(r7, "newc"))

r6 = mkroot("ubu"); add(r6, "boot/ubuntu.deb", ubu_b)
open(os.path.join(outdir, "ubuntu"), "wb").write(cpio(r6, "newc"))
open(os.path.join(outdir, "unknown.bin"), "wb").write(b"\x00\x01\x02\x03NOTACPIO_MAGIC")
PY
python3 -I "$T/mkinitrd.py" "$IRD" "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" "$T/ubuntu-pool/fonts-liberation_1%3a2.1.5-3build1_all.deb"
zstd -q -f "$IRD/nc.raw" -o "$IRD/nc.zst"
cat > "$T/initrd_probe.py" <<'PY'
import importlib.util, os, sys
ver, idx, owned = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fp", ver)
fp = importlib.util.module_from_spec(spec); spec.loader.exec_module(fp)
class A:
    ubuntu_only = False; index_dir = idx; fetch_index = False; verify_mirror = None
ref = fp.Ref(A())
bad = 0
for c in sys.argv[4:]:
    name, want = c.split("="); want = int(want)
    fp.FAILS.clear()
    fp._scan_initrd(ref, os.path.join(owned, name), owned)
    got = 1 if fp.FAILS else 0
    print(("PASS " if got == want else "MISMATCH ") + f"{name} want={want} got={got}")
    if got != want:
        bad += 1
sys.exit(1 if bad else 0)
PY
expect_rc "initrd: concatenated newc/gz/xz/zst scanned; escapes/unknown/CRC/Ubuntu FAIL" 0 \
  python3 -I "$T/initrd_probe.py" "$T/repo/build/forky-provenance.py" "$IDX" "$IRD" \
  initrd=0 nc.gz=0 nc.xz=0 nc.zst=0 concat=0 mixed=0 crc=0 \
  escape=1 abs=1 symlink=0 symlink_escape=1 unknown.bin=1 crc_bad=1 ubuntu=1
echo "$LAST" | grep -q MISMATCH && bad "initrd fixture mismatch" "$LAST" || ok "  initrd fixtures all matched expectation"


echo "=== 4c2. cpio trailer completeness + hard links (GNU-produced) ==="
cat > "$T/mkcpio_fixtures.py" <<'PY'
import json, os, shutil, subprocess, sys
outdir = sys.argv[1]
def mkroot(n):
    d = os.path.join(outdir, "t_" + n); shutil.rmtree(d, ignore_errors=True); os.makedirs(d); return d
def add(r, rel, data):
    p = os.path.join(r, rel); d = os.path.dirname(p)
    if d: os.makedirs(d, exist_ok=True)
    with open(p, "wb") as f: f.write(data)
def cpio(root, names):
    r = subprocess.run(["cpio", "-o", "--format=newc"], cwd=root,
                       input=("\n".join(names) + "\n").encode(), capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr.decode()); raise SystemExit(1)
    return r.stdout
def w(name, data):
    p = os.path.join(outdir, name)
    with open(p, "wb") as f: f.write(data)
    return p
cases = []
def case(name, data, fail, files=None, allow_tail=False):
    p = w(name, data)
    c = {"archive": p, "out": os.path.join(outdir, "o_" + name),
         "expect_fail": fail, "allow_tail": allow_tail}
    if files: c["files"] = files
    cases.append(c)
r = mkroot("hl"); add(r, "a", b"HL-CONTENT\n"); os.link(os.path.join(r, "a"), os.path.join(r, "b"))
hl = cpio(r, ["a", "b"])
case("hl", hl, False, {"a": "HL-CONTENT\n", "b": "HL-CONTENT\n"})
case("trunc_notrailer", hl[:hl.rfind(b"070701")], True)
case("trunc_mid", hl[:len(hl) // 2], True)
bad = bytearray(hl); bad[6:12] = b"ZZZZZZ"
case("bad_header", bytes(bad), True)
r2 = mkroot("main"); add(r2, "f.deb", b"X" * 64)
real = cpio(r2, ["f.deb"])
empty = real[real.rfind(b"070701"):]
case("concat_empty", empty + real, False, {"f.deb": "X" * 64})
r3 = mkroot("c1"); add(r3, "x", b"AAA"); os.link(os.path.join(r3, "x"), os.path.join(r3, "x2"))
c1 = cpio(r3, ["x", "x2"])
r4 = mkroot("c2"); add(r4, "y", b"BBB"); os.link(os.path.join(r4, "y"), os.path.join(r4, "y2"))
c2 = cpio(r4, ["y", "y2"])
ino = c1[6:14]
c2m = c2.replace(b"070701" + c2[6:14], b"070701" + ino).replace(b"070702" + c2[6:14], b"070702" + ino)
case("concat_inode_reuse", c1 + c2m, False, {"x": "AAA", "x2": "AAA", "y": "BBB", "y2": "BBB"})
json.dump(cases, open(os.path.join(outdir, "cases.json"), "w"))
PY
python3 -I "$T/mkcpio_fixtures.py" "$T/cpio"
cat > "$T/cpio_check.py" <<'PY'
import importlib.util, json, os, sys
ver, jsonpath = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fp", ver)
fp = importlib.util.module_from_spec(spec); spec.loader.exec_module(fp)
bad = 0
for c in json.load(open(jsonpath)):
    fp.FAILS.clear()
    out = c["out"]; os.makedirs(out, exist_ok=True)
    fp._extract_newc(open(c["archive"], "rb").read(), out, c["archive"],
                     allow_tail=c.get("allow_tail", False))
    got = 1 if fp.FAILS else 0
    ok = got == int(c["expect_fail"])
    if not got and "files" in c:
        for rel, want in c["files"].items():
            p = os.path.join(out, rel)
            if not os.path.isfile(p) or open(p, "rb").read() != want.encode():
                ok = False
                print("content mismatch " + rel + " in " + os.path.basename(c["archive"]))
    print(("PASS " if ok else "FAIL ") + os.path.basename(c["archive"]) +
          " expect_fail=" + str(c["expect_fail"]) + " got=" + str(got))
    if not ok: bad += 1
sys.exit(1 if bad else 0)
PY
expect_rc "cpio trailer/hardlink/inode-reuse fixtures" 0 \
  python3 -I "$T/cpio_check.py" "$T/repo/build/forky-provenance.py" "$T/cpio/cases.json"
expect_rc "compressed-tail staging ignores unusable TMPDIR (owned scratch)" 0 \
  env TMPDIR=/nonexistent-ncz-tmp python3 -I "$T/initrd_probe.py" "$T/repo/build/forky-provenance.py" "$IDX" "$IRD" mixed=0

echo "=== 4d. real subset offline mirror (build-forky-mirror style) ==="
MDIR="$T/candmir"; rm -rf "$MDIR"; mkdir -p "$MDIR/dists/forky/main/binary-amd64" "$MDIR/pool/main/f/fonts-liberation"
DEBREL="pool/main/f/fonts-liberation/fonts-liberation_1%3a2.1.5-3_all.deb"
cp "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" "$MDIR/$DEBREL"
printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\nFilename: %s\nSize: %s\nSHA256: %s\n\n' \
  "$DEB_MAINT" "$DEBREL" "$DEBSIZE" "$DEBSHA" > "$MDIR/dists/forky/main/binary-amd64/Packages"
printf 'Origin: NCZ-OS\nLabel: NCZ-OS-forky\nSuite: forky\nCodename: forky\nArchitectures: amd64\nComponents: main\n' > "$MDIR/dists/forky/Release"
expect_rc "self-signed subset mirror authorized by the verified upstream index passes" 0 "${PROV[@]}" --verify-mirror "$MDIR"
BADM="$T/badmir"; cp -a "$MDIR" "$BADM"; printf 'x' >> "$BADM/$DEBREL"
expect_rc "subset mirror with a tampered pool deb FAILS" 1 "${PROV[@]}" --verify-mirror "$BADM"
ORPH="$T/orphmir"; cp -a "$MDIR" "$ORPH"; cp "$T/unknown/mystery_1.0_all.deb" "$ORPH/pool/orphan.deb"
expect_rc "subset mirror with an orphan pool deb FAILS" 1 "${PROV[@]}" --verify-mirror "$ORPH"
UNA="$T/unamir"; cp -a "$MDIR" "$UNA"; cp "$T/unknown/mystery_1.0_all.deb" "$UNA/$DEBREL.mystery"
printf 'Package: mystery\nVersion: 1.0\nArchitecture: all\nMaintainer: %s\nFilename: %s.mystery\nSize: %s\nSHA256: %s\n\n' \
  "Someone <s@example.invalid>" "$DEBREL" "$(wc -c < "$UNA/$DEBREL.mystery")" "$(sha "$UNA/$DEBREL.mystery")" >> "$UNA/dists/forky/main/binary-amd64/Packages"
expect_rc "subset mirror with an unauthorized package FAILS" 1 "${PROV[@]}" --verify-mirror "$UNA"

echo "=== 4e. real GPT image: offline /cdrom + flat media binding, debugfs/FAT/initrd ==="
missing_img_tool=0
for t in sfdisk mkfs.ext4 debugfs mkfs.vfat mdir mcopy mmd mksquashfs tar zstd dd truncate; do
    command -v "$t" >/dev/null 2>&1 || { echo "  FAIL  required image-fixture tool missing: $t"; missing_img_tool=1; }
done
if [ "$missing_img_tool" != 0 ]; then
    FAIL=$((FAIL+1))
else
    mkimg() {  # DIR OUTIMG
        dd if=/dev/zero of="$T/data.ext4" bs=1M count=150 status=none
        mkfs.ext4 -q -F -d "$1" "$T/data.ext4" >/dev/null 2>&1
        dd if=/dev/zero of="$T/esp.vfat" bs=1M count=8 status=none
        mkfs.vfat "$T/esp.vfat" >/dev/null 2>&1
        mmd -i "$T/esp.vfat" ::/ncz ::/ncz/ssh-udebs ::/boot >/dev/null 2>&1
        mcopy -i "$T/esp.vfat" "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" "::/ncz/ssh-udebs/" >/dev/null 2>&1
        mcopy -i "$T/esp.vfat" "$IRD/nc.gz" "::/boot/initrd.gz" >/dev/null 2>&1
        dd if=/dev/zero of="$2" bs=1M count=190 status=none
        sfdisk "$2" >/dev/null 2>&1 <<'SFD'
label: gpt
start=4096, size=16384, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
start=20480, size=300000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
SFD
        dd if="$T/esp.vfat" of="$2" bs=512 seek=4096 conv=notrunc status=none
        dd if="$T/data.ext4" of="$2" bs=512 seek=20480 conv=notrunc status=none
    }
    # one squashfs layer + rescue/mgmt rootfs tarballs, all with real apt config
    mk_layer() {  # DIR
        mkdir -p "$1/var/lib/dpkg" "$1/etc/apt/preferences.d"
        printf 'ID=debian\nID_LIKE=debian\nVERSION_CODENAME=forky\n' > "$1/etc/os-release"
        printf 'Package: fonts-liberation\nStatus: install ok installed\nVersion: 1:2.1.5-3\nArchitecture: all\nMaintainer: %s\n\n' "$DEB_MAINT" > "$1/var/lib/dpkg/status"
        printf 'deb file:///cdrom forky main\ndeb [trusted=yes] file:///cdrom/ncz-payload/apt-repo /\n' > "$1/etc/apt/sources.list"
        [ -n "${NCZ_TEST_EXTRA_SOURCES:-}" ] && printf '%s\n' "$NCZ_TEST_EXTRA_SOURCES" >> "$1/etc/apt/sources.list"
    }
    build_root() {  # DIR
        rm -rf "$1"
        mkdir -p "$1/dists/forky/main/binary-amd64" "$1/pool/main/f/fonts-liberation" \
                 "$1/pool/main/libt/libtss2-rc0t64" "$1/ncz-payload/assets/cix-debs" \
                 "$1/ncz-payload/apt-repo"
        cp "$IDX/dists/forky/main/binary-amd64/Packages.xz" "$1/dists/forky/main/binary-amd64/Packages.xz"
        cp "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" "$1/pool/main/f/fonts-liberation/"
        cp "$T/tpm-pool/libtss2-rc0t64_4.1.3-7_amd64.deb" "$1/pool/main/libt/libtss2-rc0t64/"
        cp "$T/debian-pool/fonts-liberation_1%3a2.1.5-3_all.deb" "$1/ncz-payload/apt-repo/fonts-liberation_1%3a2.1.5-3_all.deb"
        printf 'Package: fonts-liberation\nVersion: 1:2.1.5-3\nArchitecture: all\nFilename: fonts-liberation_1%%3a2.1.5-3_all.deb\nSize: %s\nSHA256: %s\n\n' \
          "$DEBSIZE" "$DEBSHA" > "$1/ncz-payload/apt-repo/Packages"
        rm -rf "$T/ilayer"; mk_layer "$T/ilayer"
        mksquashfs "$T/ilayer" "$1/ncz-payload/base.squashfs" -noappend -quiet -processors 1 >/dev/null 2>&1
        for r in rescue mgmt; do
            rm -rf "$T/irf-$r"; mk_layer "$T/irf-$r"
            tar -C "$T/irf-$r" -cf - . | zstd -q -o "$1/ncz-payload/$r-rootfs.tar.zst"
        done
    }
    mkdir -p "$T/imgwork"

    cat > "$T/source_ok_probe.py" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
fp = importlib.util.module_from_spec(spec); spec.loader.exec_module(fp)
def row(path, suite):
    return {"kind": "offline", "scheme": "file", "host": "-", "path": path,
            "suite": suite, "approved": "yes", "vendor": "NCZ-OS", "note": "t", "line": 1}
r = types.SimpleNamespace(sources=[row("/cdrom", "forky"),
                                   row("/cdrom/ncz-payload/apt-repo", "/")],
                          bound_offline={"/cdrom", "/cdrom/ncz-payload/apt-repo"})
cases = [("file:///cdrom", "forky", None), ("file:///cdrom/", "forky", None),
         ("file:///cdrom/ncz-payload/apt-repo", "/", None),
         ("file:///cdrom/unscanned-repo", "forky", "fail"),
         ("file:///cdrom/../etc", "forky", "fail"),
         ("file://otherhost/cdrom", "forky", "fail"),
         ("file:///data/pool", "forky", "fail")]
bad = 0
for uri, suite, want in cases:
    got = fp.source_ok(r, uri, suite)
    ok = (got is None) if want is None else (got is not None)
    print(("PASS " if ok else "FAIL ") + uri + " => " + str(got))
    if not ok: bad += 1
sys.exit(1 if bad else 0)
PY
    expect_rc "source_ok exact-path binding (parent never authorizes a child)" 0 \
      python3 -I "$T/source_ok_probe.py" "$T/repo/build/forky-provenance.py"

    build_root "$T/imgroot"; mkimg "$T/imgroot" "$T/tiny.img"
    expect_rc "real GPT image with authorized file:///cdrom + flat media passes --image" 0 \
      "${PROV[@]}" --image "$T/tiny.img" --work "$T/imgwork"
    echo "$LAST" | grep -q "packages checked" && ok "  image scan reported counts" || bad "no image scan summary" "$LAST"

    # negative: tampered pool deb -> /cdrom not authorized -> file:///cdrom fails
    cp -a "$T/imgroot" "$T/imgbad"; printf 'x' >> "$T/imgbad/pool/main/f/fonts-liberation/fonts-liberation_1%3a2.1.5-3_all.deb"
    mkimg "$T/imgbad" "$T/badpool.img"
    expect_rc "tampered pool deb => file:///cdrom fails closed" 1 "${PROV[@]}" --image "$T/badpool.img" --work "$T/imgwork"

    # negative: partial pool (record references a missing deb)
    cp -a "$T/imgroot" "$T/imgpart"; rm -f "$T/imgpart/pool/main/libt/libtss2-rc0t64/libtss2-rc0t64_4.1.3-7_amd64.deb"
    mkimg "$T/imgpart" "$T/partpool.img"
    expect_rc "partial pool => file:///cdrom fails closed" 1 "${PROV[@]}" --image "$T/partpool.img" --work "$T/imgwork"

    # negative: foreign package in the pool (not in the verified index/ledgers)
    cp -a "$T/imgroot" "$T/imgfor"; cp "$T/unknown/mystery_1.0_all.deb" "$T/imgfor/pool/mystery_1.0_all.deb"
    printf 'Package: mystery\nVersion: 1.0\nArchitecture: all\nFilename: mystery_1.0_all.deb\nSize: %s\nSHA256: %s\n\n' \
      "$(wc -c < "$T/imgfor/pool/mystery_1.0_all.deb")" "$(sha "$T/imgfor/pool/mystery_1.0_all.deb")" \
      >> "$T/imgfor/dists/forky/main/binary-amd64/Packages"
    mkimg "$T/imgfor" "$T/forpool.img"
    expect_rc "foreign/orphan pool package => file:///cdrom fails closed" 1 "${PROV[@]}" --image "$T/forpool.img" --work "$T/imgwork"

    # negative: flat media source referenced but the apt-repo is absent
    cp -a "$T/imgroot" "$T/imgflat"; rm -rf "$T/imgflat/ncz-payload/apt-repo"
    mkimg "$T/imgflat" "$T/noflat.img"
    expect_rc "missing flat apt-repo => its file: source fails closed" 1 "${PROV[@]}" --image "$T/noflat.img" --work "$T/imgwork"

    # negative: a bound parent (/cdrom) must not authorize an unscanned child
    # root (/cdrom/unscanned-repo) even if such a directory exists.
    NCZ_TEST_EXTRA_SOURCES='deb file:///cdrom/unscanned-repo forky main' build_root "$T/imgunscanned"
    mkdir -p "$T/imgunscanned/unscanned-repo"
    cp "$T/unknown/mystery_1.0_all.deb" "$T/imgunscanned/unscanned-repo/"
    mkimg "$T/imgunscanned" "$T/unscanned.img"
    expect_rc "unscanned /cdrom child source FAILS closed (exact-path binding)" 1 \
      "${PROV[@]}" --image "$T/unscanned.img" --work "$T/imgwork"
    echo "$LAST" | grep -q 'unknown offline source root' && ok "  reason: unknown offline root" || bad "wrong reason" "$LAST"

    # leak test: binding must be restored per image, so the SAME ref scanning a
    # standalone rootfs with file:///cdrom afterwards must still fail.
    mk_layer "$T/leakrootfs"
    cat > "$T/leak_probe.py" <<'PY'
import importlib.util, os, sys
ver, idx, img, work, rootfs = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("fp", ver)
fp = importlib.util.module_from_spec(spec); spec.loader.exec_module(fp)
class A:
    ubuntu_only = False; index_dir = idx; fetch_index = False; verify_mirror = None
ref = fp.Ref(A())
fp.scan_image(ref, img, work)          # binds /cdrom, then restores in finally
if fp.FAILS:
    print("image unexpectedly failed"); sys.exit(3)
fp.FAILS.clear()
fp.scan_rootfs(ref, rootfs, "leak-rootfs")   # must NOT inherit the binding
sys.exit(1 if fp.FAILS else 2)
PY
    expect_rc "offline binding does not leak from one image to a later rootfs scan" 1 \
      python3 -I "$T/leak_probe.py" "$T/repo/build/forky-provenance.py" "$IDX" "$T/tiny.img" "$T/imgwork" "$T/leakrootfs"

    # negative: truncated image
    head -c 14000000 "$T/tiny.img" > "$T/trunc.img"
    expect_rc "truncated image FAILS closed" 1 "${PROV[@]}" --image "$T/trunc.img" --work "$T/imgwork"
fi

echo "=== 5. SRC scan: Ubuntu archives / defaults in the build sources ==="
mkdir -p "$T/srcrepo/build" "$T/srcrepo/post-install/lib" "$T/srcrepo/manifests"
cp "$ROOT/build/forky-provenance.py" "$ROOT/build/check-no-ubuntu.sh" "$T/srcrepo/build/"
cp "$ROOT/post-install/lib/apt-separation.sh" "$T/srcrepo/post-install/lib/"; cp "$ROOT/release.conf" "$T/srcrepo/"
cp -a "$ROOT/manifests" "$T/srcrepo/"
echo '# ports.ubuntu.com is mentioned only in this comment' > "$T/srcrepo/build/ok.sh"
export NCZ_NO_UBUNTU_ROOT="$T/srcrepo"
expect_rc "comment-only mention passes" 0 bash "$T/srcrepo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
echo 'MIRROR="${5:-http://ports.ubuntu.com/ubuntu-ports}"' > "$T/srcrepo/build/bad.sh"
expect_rc "Ubuntu ports mirror default FAILS" 1 bash "$T/srcrepo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
echo "$LAST" | grep -q 'bad.sh' && ok "  finding names the file" || bad "file not named" "$LAST"
echo 'SUITE="${3:-resolute}"' > "$T/srcrepo/build/bad.sh"
expect_rc "'resolute' default suite FAILS" 1 bash "$T/srcrepo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
printf 'FROM ubuntu:26.04\n' > "$T/srcrepo/build/bad.sh"
expect_rc "ubuntu base container FAILS" 1 bash "$T/srcrepo/build/check-no-ubuntu.sh" --debs "$T/debian-pool"
rm -f "$T/srcrepo/build/bad.sh"; unset NCZ_NO_UBUNTU_ROOT

echo "=== 6. the real tree ==="
expect_rc "check-no-ubuntu.sh on this repo passes" 0 bash "$NOUB"
expect_rc "builders refuse non-Debian/unpinned mirrors" 0 bash -c '
  . "'"$ROOT"'/build/lib/mirror-apt-opts.sh"
  ! ncz_require_debian_forky forky https://deb.debian.org/debian Debian 2>/dev/null &&
  ! ncz_require_debian_forky forky /nonexistent-local-mirror Debian 2>/dev/null &&
  ncz_require_debian_forky forky https://snapshot.debian.org/archive/debian/20261007T202437Z Debian &&
  ! ncz_require_debian_forky resolute http://ports.ubuntu.com/ubuntu-ports Ubuntu 2>/dev/null &&
  ! ncz_require_debian_forky forky http://ports.ubuntu.com/ubuntu-ports Debian 2>/dev/null &&
  ! ncz_require_debian_forky forky https://snapshot.debian.org/archive/debian/20200101T000000Z Debian 2>/dev/null'
expect_rc "ncz_pin_snapshot parses the released pin exactly" 0 bash -c '
  . "'"$ROOT"'/build/lib/mirror-apt-opts.sh"
  [ "$(ncz_pin_snapshot "'"$ROOT"'")" = "20261007T202437Z" ]'
mkdir -p "$T/badconf"
printf 'NCZ_BASE_MIRROR_SNAPSHOT="20260101T000000Zjunk"\n' > "$T/badconf/release.conf"
expect_rc "ncz_pin_snapshot rejects a malformed/oversized pin" 0 bash -c '
  . "'"$ROOT"'/build/lib/mirror-apt-opts.sh"; ! ncz_pin_snapshot "'"$T"'/badconf"'
printf 'NCZ_BASE_MIRROR_SNAPSHOT="20260101T000000Z"\nNCZ_BASE_MIRROR_SNAPSHOT="20200101T000000Z"\n' > "$T/badconf/release.conf"
expect_rc "ncz_pin_snapshot rejects a duplicate assignment" 0 bash -c '
  . "'"$ROOT"'/build/lib/mirror-apt-opts.sh"; ! ncz_pin_snapshot "'"$T"'/badconf"'
expect_rc "build-mgmt-rootfs.sh calls ncz_require_debian_forky" 0 grep -q ncz_require_debian_forky "$ROOT/build/build-mgmt-rootfs.sh"
expect_rc "build-rescue-rootfs.sh calls ncz_require_debian_forky" 0 grep -q ncz_require_debian_forky "$ROOT/build/build-rescue-rootfs.sh"
expect_rc "build-baked-rootfs.sh calls ncz_require_debian_forky" 0 grep -q ncz_require_debian_forky "$ROOT/build/build-baked-rootfs.sh"
expect_rc "trust metadata pin matches release.conf" 0 bash -c '
  [ "$(sed -n "s/^snapshot\t//p" "'"$ROOT"'/manifests/forky-snapshot.tsv")" = "$(sed -n "s/^NCZ_BASE_MIRROR_SNAPSHOT=\"\{0,1\}\([0-9TZ]*\)\"\{0,1\}.*/\1/p" "'"$ROOT"'/release.conf")" ]'
expect_rc "production keyring verifies the real pinned InRelease" 0 \
  gpgv --status-fd 1 --keyring "$ROOT/manifests/keys/debian-archive-keyring.gpg" "$ROOT/build/testdata/forky-snapshot/InRelease"
echo "$LAST" | grep -q 'VALIDSIG' && ok "  gpgv emitted machine-readable VALIDSIG" || bad "no VALIDSIG" "$LAST"
expect_rc "pinned InRelease sha256+size match trust metadata" 0 bash -c '
  f="'"$ROOT"'/build/testdata/forky-snapshot/InRelease"
  [ "$(sha256sum "$f" | cut -d" " -f1)" = "$(sed -n "s/^inrelease_sha256\t//p" "'"$ROOT"'/manifests/forky-snapshot.tsv")" ] &&
  [ "$(wc -c < "$f")" = "$(sed -n "s/^inrelease_size\t//p" "'"$ROOT"'/manifests/forky-snapshot.tsv")" ]'
expect_rc "--ubuntu-only refuses --image (shipping scan cannot downgrade)" 2 "${PROV[@]}" --ubuntu-only --image "$T/x.img" --work "$T"
expect_rc "--ubuntu-only refuses --verify-mirror" 2 "${PROV[@]}" --ubuntu-only --verify-mirror "$T/m"

echo
echo "no-ubuntu tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
