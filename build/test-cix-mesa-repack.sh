#!/bin/bash
# test-cix-mesa-repack.sh -- build/verify-cix-mesa-repack.py accepts exactly the -ncz1 change
# (01-cixgpu-compat.conf commented out, Version bumped) and refuses anything more.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/var/tmp}/mesarepack.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mk() {  # mk <deb> <version> <conf text> <lib text>
    local r="$T/r$$.$RANDOM"; mkdir -p "$r/DEBIAN" "$r/etc/ld.so.conf.d" "$r/opt/cixgpu-compat/lib"
    printf 'Package: cix-mesa\nVersion: %s\nArchitecture: arm64\nMaintainer: Cix OS team\nDescription: t\n' "$2" > "$r/DEBIAN/control"
    printf '%s\n' "$3" > "$r/etc/ld.so.conf.d/01-cixgpu-compat.conf"; printf '%s\n' "$4" > "$r/opt/cixgpu-compat/lib/libx.so"
    dpkg-deb --root-owner-group -b "$r" "$1" >/dev/null 2>&1
}
mk "$T/v.deb" 24.0.4 /opt/cixgpu-compat/lib/aarch64-linux-gnu lib
mk "$T/good.deb" 24.0.4-ncz1 "# disabled" lib
mk "$T/live.deb" 24.0.4-ncz1 /opt/cixgpu-compat/lib/aarch64-linux-gnu lib
mk "$T/extra.deb" 24.0.4-ncz1 "# disabled" changed
python3 -I "$HERE/verify-cix-mesa-repack.py" "$T/v.deb" "$T/good.deb" >/dev/null && ok "the -ncz1 change is accepted" || bad "the -ncz1 change was refused"
python3 -I "$HERE/verify-cix-mesa-repack.py" "$T/v.deb" "$T/live.deb" >/dev/null && bad "a live loader path was accepted" || ok "a conf that still adds a loader path is refused"
python3 -I "$HERE/verify-cix-mesa-repack.py" "$T/v.deb" "$T/extra.deb" >/dev/null && bad "an extra payload change was accepted" || ok "any other payload change is refused"
echo "test-cix-mesa-repack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
