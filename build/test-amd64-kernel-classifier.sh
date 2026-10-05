#!/bin/bash
# Extract the classifier functions from the real script and exercise them
# against synthetic /boot trees matching the live fleet hosts.
#
# Operator directive 2026-10-05 (amd64 part): amd64 ships the 7.2.9 stable
# line as the default plus exactly one pinned edge kernel -- the 7.3.0-rc6
# T2 build with the AER ANFE revert (7.3.0-rc6-1-t2-edge-aerfix). The
# classifier surfaces ONLY that pinned line as EDGE; every other -rc kernel
# (rc5, an unpinned rc6 variant, the old -ncz-amd64-edge builds) is dropped
# and never becomes a bootable edge entry. This test asserts both
# directions: pinned accepted, unpinned refused.
#
# History: the 2026-09-30 directive banned amd64 edge entirely and this test
# asserted that no -rc kernel became EDGE. The 2026-10-05 directive replaced
# that ban with the pinned-edge rule.
#
# Source path resolution: by default the test reads the script from
# $HOME/Projects/cix-installer/assets/refind/zz1-ncz-refind-refresh-amd64
# (operator's working clone on this build host). Set REPO_ROOT to override
# (e.g. when running in CI against a different checkout) -- the test
# then reads assets/refind/zz1-ncz-refind-refresh-amd64 from there.
REPO_ROOT="${REPO_ROOT:-$HOME/Projects/cix-installer}"
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
# Even though 7.3.0-rc4-2-t2-trixie and the old -ncz-amd64-edge build are
# in /boot, they are NOT the pinned edge kernel and are never classified
# as edge on amd64. Stable is still the newest release; edge is empty.
export BOOTDIR=/tmp/b1
mkboot $BOOTDIR 7.2.6-2-t2-trixie 7.2.7-2-t2-trixie 7.3.0-rc4-ncz-amd64-edge 7.3.0-rc4-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-2-t2-trixie-rescue
check "amd64: unpinned rc4 builds stay out of edge" 7.2.8-1-t2-trixie ""

echo "=== PEGASUS + rc5"
# Even with a fresh 7.3-rc5 installed, amd64 refuses to surface it as
# edge (rc5 is retired; only the pinned 7.3.0-rc6 revert is edge).
# Stable is 7.2.8 (the default), edge is empty.
export BOOTDIR=/tmp/b2
mkboot $BOOTDIR 7.2.6-2-t2-trixie 7.2.7-2-t2-trixie 7.3.0-rc4-ncz-amd64-edge 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie
check "amd64: rc5 stays out of edge" 7.2.8-1-t2-trixie ""

echo "=== MEDUSA + rc5 (the -xhcifix orphan)"
# The -xhcifix orphan that prompted the original classifier rewrite is
# also out of policy on amd64 now: it is installed, but the rEFInd menu
# does not surface it (only the pinned rc6 revert is edge).
export BOOTDIR=/tmp/b3
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix 7.3.0-rc5-1-t2-trixie
check "amd64: xhcifix + rc5 both stay out of edge" 7.2.8-1-t2-trixie ""

echo "=== MEDUSA without rc5: xhcifix must NOT be promoted to edge"
# Under the pinned-edge rule, even an isolated 7.3-rc4-xhcifix is not
# promoted to edge on amd64.
export BOOTDIR=/tmp/b4
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix
check "amd64: isolated rc4-xhcifix stays out of edge" 7.2.8-1-t2-trixie ""

echo "=== negative: no initrd means not eligible (stable still picks up)"
# Stable is still discovered; edge stays empty even though rc5 is
# present (the pinned-edge rule, not the missing initrd, suppresses edge).
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

echo "=== positive: pinned rc6 AER-revert edge is surfaced (operator 2026-10-05)"
# The validated amd64 edge kernel. Stable stays the default 7.2.9; the
# revert build is the edge entry.
export BOOTDIR=/tmp/b7
mkboot $BOOTDIR 7.2.9-2-t2-trixie 7.3.0-rc6-1-t2-edge-aerfix
check "amd64: pinned rc6 revert edge surfaced, stable default preserved" 7.2.9-2-t2-trixie 7.3.0-rc6-1-t2-edge-aerfix

echo "=== negative: unpinned rc6 variants + rc5 stay OUT of edge"
# Same 7.3.0-rc6 generation but not the pinned build, plus the retired rc5.
# Neither becomes edge; stable is untouched.
export BOOTDIR=/tmp/b8
mkboot $BOOTDIR 7.2.9-2-t2-trixie 7.3.0-rc6-1-t2-edge-plain 7.3.0-rc6-1-t2-edge-rev7920 7.3.0-rc5-1-t2-trixie
check "amd64: unpinned rc6 variants and rc5 stay out of edge" 7.2.9-2-t2-trixie ""

echo "=== REGRESSION PROOF: what the OLD globs did -- and why it's now banned"
# The OLD globs (pre-rewrite AND pre-directive) would promote rc5 to
# Stable on amd64. That is the exact failure mode the operator directive
# 2026-09-30 banned, and the 2026-10-05 pinned-edge rule keeps it banned.
# Confirm the OLD logic still exhibits that failure (so we know what we
# are guarding against), then confirm the NEW classifier refuses to
# enumerate any unpinned edge.
export BOOTDIR=/tmp/b2
old_stable=""; old_edge=""; nm=-1
for f in $BOOTDIR/vmlinuz-*; do k="${f##*/vmlinuz-}"
  case "$k" in *-rescue) continue;; *-t2-trixie) m=$(stat -c %Y "$f"); [ "$m" -gt "$nm" ] && { nm=$m; old_stable="$k"; };; esac; done
for f in $BOOTDIR/vmlinuz-*; do k="${f##*/vmlinuz-}"; case "$k" in *-ncz-amd64-edge) old_edge="$k";; esac; done
echo "  OLD: stable=$old_stable edge=$old_edge"
[ "$old_stable" = "7.3.0-rc5-1-t2-trixie" ] \
  && { echo "  CONFIRMED: old logic promotes rc5 to Stable (Default) on amd64 -- exactly the failure mode banned by directive 2026-09-30 and still out of policy under the 2026-10-05 pinned-edge rule"; PASS=$((PASS+1)); } \
  || { echo "  regression proof did not reproduce"; FAIL=$((FAIL+1)); }
# And the new pinned-edge contract: no unpinned edge on amd64.
got_e=$(find_newest edge 2>/dev/null)
[ -z "$got_e" ] \
  && { echo "  CONFIRMED: new classifier enumerates NO unpinned edge on amd64 (directive 2026-10-05)"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: new classifier unexpectedly promoted '$got_e' to edge"; FAIL=$((FAIL+1)); }

echo; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]