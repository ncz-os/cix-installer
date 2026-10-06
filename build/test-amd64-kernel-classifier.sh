#!/bin/bash
# Extract the classifier functions from the real script and exercise them
# against synthetic /boot trees matching the live fleet hosts.
#
# Operator directive 2026-10-05 (unified 7.3): amd64 ships ONE kernel, 7.3.
# The classifier surfaces the newest 7.3 kernel in /boot as the DEFAULT; the
# retired 7.2.x line and Debian-archive kernels are never surfaced. The exact
# 7.3 pin is enforced at build time (build/verify-kernel-default-policy.sh),
# not re-derived here.
#
# Source path resolution: the test MUST read the classifier from the tree it
# lives in. REPO_ROOT stays an explicit override for CI runs against a
# different checkout.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$REPO_ROOT/assets/refind/zz1-ncz-refind-refresh-amd64"
[ -f "$SRC" ] || { echo "EXTRACT FAILED: $SRC not found"; exit 2; }
SHIM="$(mktemp -t classifier-shim.XXXXXX.sh)"
trap 'rm -f "$SHIM"' EXIT
awk '/^BOOTDIR=/,/^KVER_STABLE=\$\(find_newest\)$/' "$SRC" \
  | sed '/^KVER_STABLE=\$(find_newest)$/d' > "$SHIM"
grep -q 'is_prerelease' "$SHIM" || { echo "EXTRACT FAILED: classifier functions missing"; exit 2; }
grep -q '^classify()' "$SHIM" || { echo "EXTRACT FAILED: classify() missing"; exit 2; }
# shellcheck source=/dev/null
. "$SHIM"

mkboot() { # mkboot <dir> <kver>...  (mtime increases in argument order)
  local d="$1"; shift; rm -rf "$d"; mkdir -p "$d"; local t=1000000000
  for k in "$@"; do
    : > "$d/vmlinuz-$k"; echo x > "$d/initrd.img-$k"
    touch -d "@$t" "$d/vmlinuz-$k"; t=$((t+100))
  done
}
PASS=0; FAIL=0
check() { # check <label> <expect_default>
  local got
  got=$(find_newest 2>/dev/null)
  if [ "$got" = "$2" ]; then
    echo "  PASS  $1"; echo "          default=$got"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1"; echo "          expected default='$2' got='$got'"; FAIL=$((FAIL+1))
  fi
}

echo "=== unified 7.3: newest 7.3 kernel is the default; 7.2.x is not ==="
export BOOTDIR=/tmp/b1
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.9-2-t2-trixie 7.3.0-rc5-1-t2-trixie 7.3.0-rc6-1-t2-edge-aerfix 7.2.4-2-t2-trixie-rescue
check "amd64: newest 7.3 wins over the retired 7.2.9" 7.3.0-rc6-1-t2-edge-aerfix

echo "=== a 7.2.x-only /boot is not surfaced (retired) ==="
export BOOTDIR=/tmp/b2
mkboot $BOOTDIR 7.2.8-1-t2-trixie 7.2.9-2-t2-trixie
check "amd64: pure-7.2.x /boot has no default" ""

echo "=== unpinned 7.3 rc variants are still 7.3 (build gate pins the exact one) ==="
export BOOTDIR=/tmp/b3
mkboot $BOOTDIR 7.2.9-2-t2-trixie 7.3.0-rc6-1-t2-edge-plain
check "amd64: a 7.3 rc6 variant classifies as default" 7.3.0-rc6-1-t2-edge-plain

echo "=== Debian-archive kernels are never surfaced ==="
export BOOTDIR=/tmp/b4
mkboot $BOOTDIR 7.1.4-amd64 6.1.0-13-amd64
check "amd64: Debian kernels are not the default" ""

echo "=== rescue images are skipped ==="
export BOOTDIR=/tmp/b5
mkboot $BOOTDIR 7.3.0-rc6-1-t2-edge-aerfix-rescue 7.3.0-rc6-1-t2-edge-aerfix
check "amd64: the rescue image is skipped, the live 7.3 kernel is default" 7.3.0-rc6-1-t2-edge-aerfix

echo "=== missing initrd: newest 7.3 without an initrd is skipped ==="
export BOOTDIR=/tmp/b6
mkboot $BOOTDIR 7.3.0-rc5-1-t2-trixie 7.3.0-rc6-1-t2-edge-aerfix
rm -f $BOOTDIR/initrd.img-7.3.0-rc6-1-t2-edge-aerfix
check "amd64: the incomplete newer 7.3 kernel is skipped" 7.3.0-rc5-1-t2-trixie

echo "=== negative: no 7.3 at all -> empty ==="
export BOOTDIR=/tmp/b7
mkboot $BOOTDIR 6.1.0-13-amd64
check "amd64: no 7.3 -> no default" ""

echo; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
