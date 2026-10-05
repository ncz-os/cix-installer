#!/bin/bash
# Extract the classifier functions from the real script and exercise them
# against synthetic /boot trees matching the live fleet hosts.
#
# Operator directive 2026-09-30 (amd64 part): amd64 ships NO 7.3-rc5 line
# at all -- no default, no edge. The classifier therefore NEVER classifies
# a 7.3-rc kernel as EDGE on amd64. Even if one is installed (operator
# apt-installed), the rEFInd menu cannot offer it as a bootable entry.
# This test asserts that policy contract.
#
# History: prior to the directive this script asserted the OPPOSITE --
# that 7.3-rc4/5 became EDGE on amd64 (the original classifier rewrite
# rationale, captured in the test name "xhcifix no longer orphaned").
# Those behaviours are now out of policy and the test has been rewritten
# to assert the directive.
#
# Source path resolution: the test MUST read the classifier from the tree it
# lives in. The old default hardcoded $HOME/Projects/cix-installer, the
# operator's unrelated working clone. On a build host that clone is a
# different, often stale branch, so the test validated a classifier this repo
# does not ship and reported 5 spurious failures (b43e3e5 "Known, not caused
# here", 2026-10-03) even though the shipped classifier passes every case.
# Resolve to this repo by default; REPO_ROOT stays an explicit override for
# CI runs against a different checkout.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$REPO_ROOT/assets/refind/zz1-ncz-refind-refresh-amd64"
if [ ! -f "$SRC" ]; then
    # Fallback to the directory this test script lives in.
    SRC="$(cd "$(dirname "$0")/.." && pwd)/assets/refind/zz1-ncz-refind-refresh-amd64"
fi
[ -f "$SRC" ] || { echo "EXTRACT FAILED: $SRC not found"; exit 2; }
SHIM=/tmp/classifier-shim.sh
awk '/^BOOTDIR=/,/^KVER_EDGE=\$\(find_newest edge\)$/' "$SRC" \
  | sed '/^KVER_STABLE=\$(find_newest stable)$/d; /^KVER_EDGE=\$(find_newest edge)$/d' > "$SHIM"
grep -q 'is_prerelease' "$SHIM" || { echo "EXTRACT FAILED"; exit 2; }
. "$SHIM"

mkboot() { # mkboot <dir> <kver>...  (mtime increases in argument order)
  local d="$1"; shift; rm -rf "$d"; mkdir -p "$d"; local t=1000000000
  for k in "$@"; do
    : > "$d/vmlinuz-$k"; echo x > "$d/initrd.img-$k"
    touch -d "@$t" "$d/vmlinuz-$k"; t=$((t+100))
  done
}
PASS=0; FAIL=0
check() { # check <label> <expect_stable> <expect_edge>
  local got_s got_e
  got_s=$(find_newest stable 2>/dev/null); got_e=$(find_newest edge 2>/dev/null)
  if [ "$got_s" = "$2" ] && [ "$got_e" = "$3" ]; then
    echo "  PASS  $1"; echo "          stable=$got_s edge=$got_e"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1"; echo "          expected stable=$2 edge=$3"
    echo "          got      stable=$got_s edge=$got_e"; FAIL=$((FAIL+1))
  fi
}

echo "=== PEGASUS, current (pre-rc5)"
# Operator directive: even though 7.3.0-rc4-2-t2-trixie is in /boot, it
# is NEVER classified as edge on amd64. Stable is still the newest
# release; edge is empty.
export BOOTDIR=/tmp/b1
mkboot $BOOTDIR 7.2.6-2-t2-trixie 7.2.7-2-t2-trixie 7.3.0-rc4-ncz-amd64-edge 7.3.0-rc4-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-2-t2-trixie-rescue
check "amd64: rc4 kernels stay out of edge (directive 2026-09-30)" 7.2.8-1-t2-trixie ""

echo "=== PEGASUS + rc5"
# Even with a fresh 7.3-rc5 installed, amd64 refuses to surface it as
# edge. Stable is 7.2.8 (the default), edge is empty.
export BOOTDIR=/tmp/b2
mkboot $BOOTDIR 7.2.6-2-t2-trixie 7.2.7-2-t2-trixie 7.3.0-rc4-ncz-amd64-edge 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie
check "amd64: rc5 stays out of edge (directive 2026-09-30)" 7.2.8-1-t2-trixie ""

echo "=== MEDUSA + rc5 (the -xhcifix orphan)"
# The -xhcifix orphan that prompted the original classifier rewrite is
# also out of policy on amd64 now: it is installed, but the rEFInd menu
# does not surface it. (The bug it was fixing was that the kernel was
# dropped from the ESP entirely; the fix to that was the classifier;
# the policy is now to refuse to enumerate edge entirely on amd64.)
export BOOTDIR=/tmp/b3
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix 7.3.0-rc5-1-t2-trixie
check "amd64: xhcifix + rc5 both stay out of edge" 7.2.8-1-t2-trixie ""

echo "=== MEDUSA without rc5: xhcifix must NOT be promoted to edge"
# Per the directive, even an isolated 7.3-rc4-xhcifix is not promoted
# to edge on amd64. (This is the case that previously asserted the
# "recovered" behaviour; that policy is now inverted.)
export BOOTDIR=/tmp/b4
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix
check "amd64: isolated rc4-xhcifix stays out of edge" 7.2.8-1-t2-trixie ""

echo "=== negative: no initrd means not eligible (stable still picks up)"
# Stable is still discovered; edge stays empty even though rc5 is
# present (the policy, not the missing initrd, is what suppresses edge).
export BOOTDIR=/tmp/b5
mkboot $BOOTDIR 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie
rm -f $BOOTDIR/initrd.img-7.3.0-rc5-1-t2-trixie
check "amd64: rc5 stays out of edge even with initrd missing" 7.2.8-1-t2-trixie ""

echo "=== positive: pure-stable /boot -- only stable, no edge"
# The fleet host that has only 7.2.x releases installed. No surprise:
# stable is the newest, edge is empty.
export BOOTDIR=/tmp/b6
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie
check "amd64: pure-stable /boot" 7.2.8-1-t2-trixie ""

echo "=== Cygnus 26.10 base: the shipping stable line is 7.2.9-2-t2-trixie"
# The classifier must treat the 7.2.9 release naming exactly like every other
# release: stable, not prerelease, and any 7.3-rc5 sitting beside it is still
# refused as an amd64 edge entry. The fixtures above stop at 7.2.8, so the
# shipping Cygnus naming (b43e3e5: amd64 stable = 7.2.9-2-t2-trixie) had no
# coverage; this is the regression case for the 7.2.9 "-t2-trixie" naming.
export BOOTDIR=/tmp/b7
mkboot $BOOTDIR 7.2.8-1-t2-trixie 7.2.9-2-t2-trixie 7.3.0-rc5-1-t2-trixie
check "amd64: 7.2.9-2-t2-trixie is stable; rc5 stays out of edge" 7.2.9-2-t2-trixie ""

echo "=== REGRESSION PROOF: what the OLD globs did -- and why it's now banned"
# The OLD globs (pre-rewrite AND pre-directive) would promote rc5 to
# Stable on amd64. That is the exact failure mode the operator directive
# 2026-09-30 is designed to ban. Confirm the OLD logic still exhibits
# that failure (so we know what we are guarding against), then confirm
# the NEW directive classifier refuses to enumerate edge at all.
export BOOTDIR=/tmp/b2
old_stable=""; old_edge=""; nm=-1
for f in $BOOTDIR/vmlinuz-*; do k="${f##*/vmlinuz-}"
  case "$k" in *-rescue) continue;; *-t2-trixie) m=$(stat -c %Y "$f"); [ "$m" -gt "$nm" ] && { nm=$m; old_stable="$k"; };; esac; done
for f in $BOOTDIR/vmlinuz-*; do k="${f##*/vmlinuz-}"; case "$k" in *-ncz-amd64-edge) old_edge="$k";; esac; done
echo "  OLD: stable=$old_stable edge=$old_edge"
[ "$old_stable" = "7.3.0-rc5-1-t2-trixie" ] \
  && { echo "  CONFIRMED: old logic promotes rc5 to Stable (Default) on amd64 -- exactly the failure mode banned by directive 2026-09-30"; PASS=$((PASS+1)); } \
  || { echo "  regression proof did not reproduce"; FAIL=$((FAIL+1)); }
# And the new directive's contract: edge is empty, full stop.
got_e=$(find_newest edge 2>/dev/null)
[ -z "$got_e" ] \
  && { echo "  CONFIRMED: new classifier enumerates NO edge on amd64 (directive 2026-09-30)"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: new classifier unexpectedly promoted '$got_e' to edge"; FAIL=$((FAIL+1)); }

echo; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]