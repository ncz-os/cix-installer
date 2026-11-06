#!/bin/bash
# test-audit-dpkg-state.sh -- behavioural tests for build/audit-dpkg-state.sh
#
# The audit exists because a fleet probe that returned nothing looked like a clean
# result. So the tests here are mostly about NOT reporting the wrong thing: a hold
# and a leftover conffile are not residue, an empty audit is not a pass, and the
# DKMS/prebuilt overlap is named rather than left to be rediscovered on a host.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
AUDIT="$HERE/audit-dpkg-state.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect_rc() {  # label want-rc snapshot
    local label="$1" want="$2" snap="$3" rc=0 out
    out="$("$AUDIT" --snapshot "$snap" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$out"; fi
    LAST="$out"
}

[ -x "$AUDIT" ] || { echo "SKIP: $AUDIT is not executable" >&2; exit 0; }

echo "=== 1. a clean host ==="
cat > "$T/clean" <<'EOF'
pkg ii ncz-singularity-desktop 20261105105000
pkg ii linux-image-7.3.1-t2-ncz 7.3.1-1
pkg ii t2gmux-modules-7.4.0-rc1-t2-ncz 0.8+t2ncz-7.4.0-rc1-1
owns t2gmux-modules-7.4.0-rc1-t2-ncz /lib/modules/7.4.0-rc1-t2-ncz/updates/dkms/t2gmux.ko
dkms t2gmux/0.8 7.3.1-t2-ncz installed
EOF
expect_rc "clean host passes" 0 "$T/clean"
case "$LAST" in *"0 residue"*"0 dkms/prebuilt collision(s)"*) ok "  summary counts are zero" ;; *) bad "summary wrong" "$LAST" ;; esac

echo "=== 2. holds and leftover conffiles are NOT residue ==="
cat > "$T/held" <<'EOF'
pkg ii ncz-singularity-desktop 20261105105000
pkg hi cix-noe-umd 3.1.4-cixdeb13-260714
pkg rc mesa-opencl-icd 26.1.6-1
pkg rc initramfs-tools 0.151
EOF
expect_rc "held + removed-with-conffiles passes" 0 "$T/held"
case "$LAST" in *"1 held"*"2 removed-with-conffiles"*) ok "  holds and conffile leftovers are counted, not flagged" ;; *) bad "counts wrong" "$LAST" ;; esac

echo "=== 3. real residue is named with its package and state ==="
cat > "$T/residue" <<'EOF'
pkg ii ncz-singularity-desktop 20261105105000
pkg iF linux-image-7.4.0-rc1-t2-ncz 7.4.0-rc1-1
pkg iU t2smc-modules-7.4.0-rc1-t2-ncz 0.1+t2ncz-7.4.0-rc1-1
EOF
expect_rc "half-configured + unpacked fail" 1 "$T/residue"
case "$LAST" in *"RESIDUE"*linux-image-7.4.0-rc1-t2-ncz*iF*) ok "  names the half-configured image" ;; *) bad "image not named" "$LAST" ;; esac
case "$LAST" in *"RESIDUE"*t2smc-modules*iU*) ok "  names the unpacked module package" ;; *) bad "module package not named" "$LAST" ;; esac

echo "=== 4. the DKMS/prebuilt overlap is a collision, not a mystery ==="
cat > "$T/collision" <<'EOF'
pkg ii linux-image-7.4.0-rc1-t2-ncz 7.4.0-rc1-1
pkg ii t2gmux-modules-7.4.0-rc1-t2-ncz 0.8+t2ncz-7.4.0-rc1-1
owns t2gmux-modules-7.4.0-rc1-t2-ncz /lib/modules/7.4.0-rc1-t2-ncz/updates/dkms/t2gmux.ko
dkms t2gmux/0.8 7.4.0-rc1-t2-ncz built
EOF
expect_rc "same .ko path owned by a package, DKMS built -> fails" 1 "$T/collision"
case "$LAST" in *"COLLISION"*t2gmux*7.4.0-rc1-t2-ncz*) ok "  names the module and the kernel" ;; *) bad "collision not named" "$LAST" ;; esac
case "$LAST" in *t2gmux-modules-7.4.0-rc1-t2-ncz*) ok "  names the package that owns the path" ;; *) bad "package not named" "$LAST" ;; esac

echo "=== 4b. DKMS 'installed' for the same kernel is NOT a collision ==="
cat > "$T/installed" <<'EOF'
pkg ii t2gmux-modules-7.4.0-rc1-t2-ncz 0.8+t2ncz-7.4.0-rc1-1
owns t2gmux-modules-7.4.0-rc1-t2-ncz /lib/modules/7.4.0-rc1-t2-ncz/updates/dkms/t2gmux.ko
dkms t2gmux/0.8 7.4.0-rc1-t2-ncz installed (Original modules exist)
EOF
expect_rc "dkms already installed skips, so the postinst cannot fail on it" 0 "$T/installed"

echo "=== 5. DKMS for a DIFFERENT kernel is not a collision ==="
cat > "$T/otherkernel" <<'EOF'
pkg ii t2gmux-modules-7.4.0-rc1-t2-ncz 0.8+t2ncz-7.4.0-rc1-1
owns t2gmux-modules-7.4.0-rc1-t2-ncz /lib/modules/7.4.0-rc1-t2-ncz/updates/dkms/t2gmux.ko
dkms t2gmux/0.8 7.3.1-t2-ncz installed
EOF
expect_rc "dkms on another kernel does not collide" 0 "$T/otherkernel"

echo "=== 6. a module package with no DKMS registration is fine ==="
cat > "$T/prebuiltonly" <<'EOF'
pkg ii t2gmux-modules-7.4.0-rc1-t2-ncz 0.8+t2ncz-7.4.0-rc1-1
owns t2gmux-modules-7.4.0-rc1-t2-ncz /lib/modules/7.4.0-rc1-t2-ncz/updates/dkms/t2gmux.ko
EOF
expect_rc "prebuilt module, no DKMS claim -> clean" 0 "$T/prebuiltonly"

echo "=== 7. an empty audit is not a pass ==="
: > "$T/empty"
expect_rc "empty snapshot exits 3" 3 "$T/empty"

echo "=== 8. usage errors ==="
rc=0; "$AUDIT" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "unknown option exits 2" || bad "unknown option rc=$rc, wanted 2"
rc=0; "$AUDIT" --snapshot "$T/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "missing snapshot exits 2" || bad "missing snapshot rc=$rc, wanted 2"

echo "test-audit-dpkg-state: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
