#!/bin/bash
# shellcheck disable=SC1090
# Hermetic check that an empty package manifest or an empty Packages index
# exits non-zero with an explicit error, and that apt-get update failure
# prints its E: lines. No debootstrap, no apt, no image build.
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/build/lib/mirror-apt-opts.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAILS=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }

if [ -f "$LIB" ]; then ok "mirror-apt-opts.sh present"; else no "mirror-apt-opts.sh missing"; fi
. "$LIB"

printf '%s\n' '# comment' '' 'openssh-server  # note' 'systemd' 'openssh-server' > "$T/pkgs.txt"
got="$(ncz_pkgs_from_manifest "$T/pkgs.txt")" || no "non-empty manifest returned non-zero"
old="$(grep -vE '^\s*(#|$)' "$T/pkgs.txt" | sed 's/#.*//' | awk '{print $1}' | grep . | sort -u | tr '\n' ' ')"
if [ "$got" = "$old" ] && [ "$got" = "openssh-server systemd " ]; then
    ok "non-empty manifest matches the old pipeline"
else
    no "non-empty manifest diverged: got=[$got] old=[$old]"
fi

printf '%s\n' '# only a comment' '' > "$T/empty.pkgs"
err="$(ncz_pkgs_from_manifest "$T/empty.pkgs" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q 'package manifest has no packages'; then
    ok "empty manifest exits non-zero with an explicit error"
else
    no "empty manifest rc=$rc err=[$err]"
fi

printf '%s\n' 'Package: bash' 'Package: coreutils' > "$T/Packages"
count="$(ncz_package_record_count "$T/Packages")" || no "record count failed on a non-empty index"
oldc="$(grep -c '^Package: ' "$T/Packages")"
if [ "$count" = "$oldc" ] && [ "$count" = 2 ]; then
    ok "package record count matches grep -c on a non-empty index"
else
    no "package record count diverged: got=$count old=$oldc"
fi
: > "$T/Packages.empty"
err="$(ncz_package_record_count "$T/Packages.empty" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q 'no Package records'; then
    ok "empty package index exits non-zero with an explicit error"
else
    no "empty package index rc=$rc err=[$err]"
fi

for script in build-mgmt-rootfs.sh build-rescue-rootfs.sh build-baked-rootfs.sh; do
    if grep -q 'ncz_mirror_sources_list' "$ROOT/build/$script"; then
        ok "$script calls ncz_mirror_sources_list"
    else
        no "$script does not call ncz_mirror_sources_list"
    fi
    if grep -q 'ncz_apt_update_or_die' "$ROOT/build/$script"; then
        ok "$script surfaces apt-get update failure"
    else
        no "$script does not surface apt-get update failure"
    fi
done
if grep -q 'ncz_package_record_count' "$ROOT/build/build-forky-mirror.sh" \
    && ! grep -q 'grep -c '"'"'^Package:'"'"'' "$ROOT/build/build-forky-mirror.sh"; then
    ok "forky-mirror no longer ends the index count on grep -c"
else
    no "forky-mirror still uses grep -c for the package record count"
fi
if ! grep -q '| grep \. |' "$ROOT/build/build-mgmt-rootfs.sh" \
    && ! grep -q '| grep \. |' "$ROOT/build/build-rescue-rootfs.sh"; then
    ok "mgmt and rescue no longer pipe the package list through grep ."
else
    no "mgmt or rescue still pipes the package list through grep ."
fi

apt_fail_check() {
    local label="$1" log err rc
    log="$T/apt-$label.log"
    printf '%s\n' "Hit:1 http://example invalid" "E: Release file for example is expired" > "$T/apt-body"
    err="$(ncz_apt_update_or_die "$log" "$label" bash -c "cat \"\$1\" >&2; exit 100" bash "$T/apt-body" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$err" | grep -q "apt-get update failed ($label)" \
        && printf '%s\n' "$err" | grep -q 'E: Release file for example is expired'; then
        ok "apt-get update failure surfaces for $label"
    else
        no "apt-get update failure not surfaced for $label rc=$rc err=[$err]"
    fi
}
apt_fail_check "management chroot"
apt_fail_check "rescue chroot"
apt_fail_check "bake chroot"

echo "sibling empty index: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
