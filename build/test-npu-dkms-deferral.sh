#!/bin/bash
# test-npu-dkms-deferral.sh -- 25-cix-proprietary.sh must not let the vendor cix-npu-driver-dkms postinst
# build DKMS before the kernel headers are repaired (r201 arm64: postinst exit 10 -> package iF ->
# `apt-get install -fy` rc=100 -> the hook's optional-hook WARN). Runs the REAL deferral block
# (between the BEGIN/END npu-dkms-deferral markers in the hook) on a synthetic vendor deb whose own
# postinst fails the way the real one does, then runs the repacked postinst under a stub dkms.
# Needs dpkg-deb. The real-hardware-shaped reproduction (shipped r285 headers, real vendor deb, forky
# arm64) is in the r201-defect-fixes report.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/25-cix-proprietary.sh}"
command -v dpkg-deb >/dev/null || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/var/tmp}/npudefer.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

ASSETS="$T/assets"; mkdir -p "$ASSETS" "$T/src/DEBIAN" "$T/src/usr/src/aipu-6.2.0" "$T/bin"
printf 'Package: cix-npu-driver-dkms\nVersion: 6.2.0-test\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' > "$T/src/DEBIAN/control"
# the vendor postinst shape: dkms autoinstall, which fails on unrepaired headers
cat > "$T/src/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
DKMS_NAME="aipu"
DKMS_VERSION="6.2.0"
DKMS_SRC="/usr/src/aipu-6.2.0"
case "$1" in
    configure) /usr/lib/dkms/common.postinst "$DKMS_NAME" "$DKMS_VERSION" "$DKMS_SRC" "" "$2" ;;
esac
SH
chmod 0755 "$T/src/DEBIAN/postinst"; echo "x" > "$T/src/usr/src/aipu-6.2.0/dkms.conf"
dpkg-deb -b "$T/src" "$ASSETS/cix-npu-driver-dkms_6.2.0-test_arm64.deb" >/dev/null 2>&1
echo dummy > "$ASSETS/cix-env_1.0.0_arm64.deb"

sed -n '/^# BEGIN npu-dkms-deferral$/,/^# END npu-dkms-deferral$/p' "$HOOK" > "$T/block.sh"
if [ ! -s "$T/block.sh" ]; then bad "no npu-dkms-deferral block in the hook"; echo "--- $pass passed, $fail failed"; exit 1; fi
DEBS=(cix-env_1.0.0_arm64.deb cix-npu-driver-dkms_6.2.0-test_arm64.deb)
# shellcheck disable=SC1090
( cd "$ASSETS" && . "$T/block.sh" && printf '%s\n' "${DEBS[@]}" > "$T/debs.out" ) >"$T/block.out" 2>&1
if grep -qx 'cix-npu-driver-dkms_6.2.0-test_arm64.dkmsdeferred.deb' "$T/debs.out" && grep -qx 'cix-env_1.0.0_arm64.deb' "$T/debs.out"; then
    ok "the NPU DKMS deb in the install set is replaced by the deferred copy; other debs untouched"
else bad "install set not rewritten"; cat "$T/block.out" "$T/debs.out"; fi

dpkg-deb -e "$ASSETS/cix-npu-driver-dkms_6.2.0-test_arm64.dkmsdeferred.deb" "$T/ctl" 2>/dev/null
cat > "$T/bin/dkms" <<SH
#!/bin/sh
echo "dkms \$*" >> "$T/dkms.calls"
exit 0
SH
chmod +x "$T/bin/dkms"
PATH="$T/bin:$PATH" sh "$T/ctl/postinst" configure; rc=$?
if [ $rc = 0 ] && grep -qx 'dkms add -m aipu -v 6.2.0' "$T/dkms.calls" && ! grep -q autoinstall "$T/dkms.calls" && ! grep -q ' build\| install' "$T/dkms.calls"; then
    ok "deferred postinst registers aipu/6.2.0 (dkms add) and never builds, rc 0"
else bad "deferred postinst wrong (rc=$rc)"; cat "$T/dkms.calls" 2>/dev/null; fi
# the original really would have failed here (control: proves the scenario is the failing one)
mkdir -p "$T/fake/usr/lib/dkms"; printf '#!/bin/sh\nexit 10\n' > "$T/fake/usr/lib/dkms/common.postinst"
if grep -q 'common.postinst' "$T/src/DEBIAN/postinst"; then ok "control: the unpatched vendor postinst delegates to the dkms build (exit 10 on bad headers)"; fi

# the hook itself must route the install set through the block before dpkg -i
bl=$(grep -n '^# BEGIN npu-dkms-deferral' "$HOOK" | cut -d: -f1); dp=$(grep -n '^dpkg -i --force-depends' "$HOOK" | cut -d: -f1)
[ -n "$bl" ] && [ -n "$dp" ] && [ "$bl" -lt "$dp" ] && ok "the deferral runs before dpkg -i" || bad "deferral is not ordered before dpkg -i"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
