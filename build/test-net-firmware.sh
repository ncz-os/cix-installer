#!/bin/bash
# test-net-firmware.sh -- network firmware coverage for installer and target.
#   * every package in manifests/net-firmware.tsv is in manifests/firmware.pkgs
#     (seeded into the offline mirror, installed by post-install/13-firmware-bom.sh)
#   * 13-firmware-bom.sh runs on both architectures
#   * the d-i initrd builder bakes the initrd-scoped blobs (rtl_nic/*, MT79xx BT)
#     out of the pool .deb into /lib/firmware (build/iso/tests/test_initrd_net_firmware.py)
# Set NCZ_FIRMWARE_POOL=<offline mirror>/pool to also check the real packages.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
bad() { echo "FAIL  $*"; FAIL=1; }
ok()  { echo "PASS  $*"; }

for list in "$ROOT/post-install/hooks.list.amd64" "$ROOT/post-install/hooks.list.sky1-arm64"; do
    if grep -qx '13-firmware-bom.sh' "$list"; then ok "13-firmware-bom.sh in $(basename "$list")"
    else bad "13-firmware-bom.sh missing from $(basename "$list")"; fi
done

python3 -m unittest -v "$ROOT/build/iso/tests/test_initrd_net_firmware.py" 2>&1 | sed 's/^/      /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "initrd/table unit tests" || bad "initrd/table unit tests"

[ "$FAIL" = 0 ] && echo "net firmware tests: all passed"
exit "$FAIL"
