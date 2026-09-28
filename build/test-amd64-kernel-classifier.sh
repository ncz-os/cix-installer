#!/bin/bash
# Extract the classifier functions from the real script and exercise them
# against synthetic /boot trees matching the live fleet hosts.
SRC="$HOME/Projects/cix-installer/assets/refind/zz1-ncz-refind-refresh-amd64"
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
export BOOTDIR=/tmp/b1
mkboot $BOOTDIR 7.2.6-2-t2-trixie 7.2.7-2-t2-trixie 7.3.0-rc4-ncz-amd64-edge 7.3.0-rc4-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-2-t2-trixie-rescue
check "stable ignores rc; newest release wins" 7.2.8-1-t2-trixie 7.3.0-rc4-2-t2-trixie

echo "=== PEGASUS + rc5"
export BOOTDIR=/tmp/b2
mkboot $BOOTDIR 7.2.6-2-t2-trixie 7.2.7-2-t2-trixie 7.3.0-rc4-ncz-amd64-edge 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie
check "rc5 becomes EDGE, 7.2.8 stays STABLE" 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie

echo "=== MEDUSA + rc5 (the -xhcifix orphan)"
export BOOTDIR=/tmp/b3
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix 7.3.0-rc5-1-t2-trixie
check "xhcifix no longer orphaned; rc5 newest edge" 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie

echo "=== MEDUSA without rc5: xhcifix must be recovered as edge"
export BOOTDIR=/tmp/b4
mkboot $BOOTDIR 7.2.7-2-t2-trixie 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix
check "xhcifix recovered (was dropped entirely before)" 7.2.8-1-t2-trixie 7.3.0-rc4-3-t2-trixie-xhcifix

echo "=== negative: no initrd means not eligible"
export BOOTDIR=/tmp/b5
mkboot $BOOTDIR 7.2.8-1-t2-trixie 7.3.0-rc5-1-t2-trixie
rm -f $BOOTDIR/initrd.img-7.3.0-rc5-1-t2-trixie
check "rc5 skipped mid-transaction" 7.2.8-1-t2-trixie ""

echo "=== REGRESSION PROOF: what the OLD globs did with rc5"
export BOOTDIR=/tmp/b2
old_stable=""; old_edge=""; nm=-1
for f in $BOOTDIR/vmlinuz-*; do k="${f##*/vmlinuz-}"
  case "$k" in *-rescue) continue;; *-t2-trixie) m=$(stat -c %Y "$f"); [ "$m" -gt "$nm" ] && { nm=$m; old_stable="$k"; };; esac; done
for f in $BOOTDIR/vmlinuz-*; do k="${f##*/vmlinuz-}"; case "$k" in *-ncz-amd64-edge) old_edge="$k";; esac; done
echo "  OLD: stable=$old_stable edge=$old_edge"
[ "$old_stable" = "7.3.0-rc5-1-t2-trixie" ] \
  && { echo "  CONFIRMED: old logic promotes rc5 to Stable (Default)"; PASS=$((PASS+1)); } \
  || { echo "  regression proof did not reproduce"; FAIL=$((FAIL+1)); }

echo; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
