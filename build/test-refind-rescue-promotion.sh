#!/bin/bash
# shellcheck disable=SC2016,SC1090,SC1091,SC2329  # literal $ in generated code/sed; non-constant source; cp() is called by the extracted impl
# test-refind-rescue-promotion.sh -- regression tests for the rEFInd rescue
# auto-promotion guard (item RRH, 2026-10-04).
#
# The refresh scripts promote the outgoing ESP kernel to the single -rescue slot
# before wiping the ESP. The pre-fix loop took the first non-rescue ESP kernel
# whose kver was neither the primary nor the edge line, with NO prerelease
# classification, and deleted the existing rescue pair BEFORE copying. Live on
# MEDUSA (T2 Mac) after purging linux-image-7.2.8-3, a staged stock-Edge kernel
# 7.3.0-rc5-10-t2-ncz-revhid (not equal to KVER_EDGE=7.3.0-rc5-9) was
# promoted to RESCUE and the known-good 7.2.8 rescue was deleted.
#
# These tests run the REAL promotion code (extracted verbatim from the shipped
# script) against a fixture ESP tree:
#   1. stale rc kernel on the ESP + old stable rescue -> the existing rescue
#      survives byte-identical (no rc promotion);
#   2. normal upgrade stable A -> stable B still promotes A to rescue;
#   3. rc-only outgoing -> no promotion;
#   4. a failed copy leaves the old rescue intact.
#
# Usage:
#   bash build/test-refind-rescue-promotion.sh                 # both shipped scripts
#   bash build/test-refind-rescue-promotion.sh <script> [...]  # explicit scripts
# The explicit form also runs against the PRE-FIX script (e.g.
# `git show HEAD:assets/refind/ncz-refind-refresh-amd64.sh > /tmp/old.sh`):
# tests 1, 3 and 4 must FAIL there, proving the regression tests are meaningful.
#
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file is
# missing / the promotion code could not be extracted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -gt 0 ]; then
    SOURCES=("$@")
else
    SOURCES=("$REPO/assets/refind/ncz-refind-refresh-amd64.sh" \
             "$REPO/assets/refind/ncz-refind-refresh.sh")
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# Extract the promotion implementation from a refresh script into a callable
# `ncz_promote_outgoing_rescue <esp> <primary> [edge]`.
#  - fixed (new) scripts expose the function directly;
#  - pre-fix scripts have an inline `for _esp_k in /boot/efi/vmlinuz-*` block,
#    which is wrapped and its hardcoded paths/vars rewritten.
extract_impl() {
    local src="$1"
    if grep -q '^ncz_promote_outgoing_rescue()' "$src"; then
        awk '/^is_prerelease\(\)/,/^}$/' "$src"
        awk '/^is_stable_class\(\)/,/^}$/' "$src"
        awk '/^ncz_promote_outgoing_rescue\(\)/,/^}$/' "$src"
        return 0
    fi
    # Pre-fix inline form.
    local block
    block="$(awk '
        index($0, "for _esp_k in /boot/efi/vmlinuz-*") { g=1 }
        g { print }
        g && /^[[:space:]]*done[[:space:]]*$/ { exit }
    ' "$src")"
    [ -n "$block" ] || return 1
    echo 'is_prerelease() { case "$1" in *-rc[0-9]*) return 0 ;; *) return 1 ;; esac; }'
    echo 'is_stable_class() { return 0; }'
    echo 'ncz_promote_outgoing_rescue() {'
    echo '  local ESP="$1" PRIMARY="$2" EDGE_KVER="${3:-}"'
    printf '%s\n' "$block" \
        | sed -e 's#/boot/efi#$ESP#g' \
              -e 's/\$KVER_NEXT/\$PRIMARY/g' \
              -e 's/\$KVER_STABLE/\$PRIMARY/g' \
              -e 's/\$KVER_EDGE/\$EDGE_KVER/g'
    echo '}'
}

mkfile() { printf 'payload-%s\n' "$2" > "$1"; }
mkesp()  # mkesp <dir> <vmlinuz-kver>... (each gets an initrd)
{
    local d="$1"; shift; local k
    rm -rf "$d"; mkdir -p "$d"
    for k in "$@"; do
        mkfile "$d/vmlinuz-$k" "$k"
        mkfile "$d/initrd.img-$k" "$k"
    done
}
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

PRIMARY_AMD64="7.2.9-2-t2-ncz"   # incoming stable
STABLE_A="7.2.8-3-t2-ncz"        # outgoing stable
RC_KVER="7.3.0-rc5-10-t2-ncz-revhid"

run_for_source() {
    local src="$1" impl_dir impl
    echo "=== $(basename "$src") ==="
    if [ ! -r "$src" ]; then
        bad "$(basename "$src") is readable" "cannot read $src"
        return
    fi
    impl_dir="$(mktemp -d)"
    impl="$impl_dir/impl.sh"
    if ! extract_impl "$src" > "$impl" 2>"$impl.err" || [ ! -s "$impl" ]; then
        bad "$(basename "$src") promotion code extracted" "$(cat "$impl.err")"
        rm -rf "$impl_dir"
        return
    fi
    bash -n "$impl" 2>"$impl.err" || {
        bad "$(basename "$src") extracted code parses" "$(cat "$impl.err")"
        rm -rf "$impl_dir"
        return
    }

    # ---- scenario 1: rc staged + existing stable rescue must survive --------
    local esp="$impl_dir/s1" before after
    mkesp "$esp" "$RC_KVER" "$STABLE_A-rescue"
    before="$(sha "$esp/vmlinuz-$STABLE_A-rescue")"
    ( set +e; . "$impl"; ncz_promote_outgoing_rescue "$esp" "$PRIMARY_AMD64" "" ) \
        >"$impl_dir/s1.log" 2>&1
    after="$(sha "$esp/vmlinuz-$STABLE_A-rescue")"
    if [ -n "$before" ] && [ "$before" = "$after" ] \
       && [ ! -e "$esp/vmlinuz-$RC_KVER-rescue" ]; then
        ok "1) existing stable rescue survives byte-identical; rc not promoted"
    else
        bad "1) existing stable rescue survives byte-identical; rc not promoted" \
            "$(printf 'before=%s after=%s\n' "$before" "$after"; ls -1 "$esp"; cat "$impl_dir/s1.log")"
    fi

    # ---- scenario 2: stable A -> stable B still promotes A ------------------
    local esp2="$impl_dir/s2"
    mkesp "$esp2" "$STABLE_A" "7.2.7-1-t2-ncz-rescue"
    ( set +e; . "$impl"; ncz_promote_outgoing_rescue "$esp2" "$PRIMARY_AMD64" "" ) \
        >"$impl_dir/s2.log" 2>&1
    if [ -e "$esp2/vmlinuz-$STABLE_A-rescue" ] \
       && [ "$(sha "$esp2/vmlinuz-$STABLE_A-rescue")" = "$(sha "$esp2/vmlinuz-$STABLE_A")" ] \
       && [ ! -e "$esp2/vmlinuz-7.2.7-1-t2-ncz-rescue" ]; then
        ok "2) normal upgrade promotes outgoing stable A to rescue"
    else
        bad "2) normal upgrade promotes outgoing stable A to rescue" \
            "$(ls -1 "$esp2"; cat "$impl_dir/s2.log")"
    fi

    # ---- scenario 3: rc-only outgoing -> no promotion -----------------------
    local esp3="$impl_dir/s3"
    mkesp "$esp3" "$RC_KVER"
    ( set +e; . "$impl"; ncz_promote_outgoing_rescue "$esp3" "$PRIMARY_AMD64" "" ) \
        >"$impl_dir/s3.log" 2>&1
    if ! compgen -G "$esp3/vmlinuz-*-rescue" >/dev/null 2>&1; then
        ok "3) rc-only outgoing promotes nothing"
    else
        bad "3) rc-only outgoing promotes nothing" \
            "$(ls -1 "$esp3"; cat "$impl_dir/s3.log")"
    fi

    # ---- scenario 4: failed copy leaves the old rescue intact ---------------
    local esp4="$impl_dir/s4" r4_before r4_after
    mkesp "$esp4" "$STABLE_A" "7.2.7-1-t2-ncz-rescue"
    r4_before="$(sha "$esp4/vmlinuz-7.2.7-1-t2-ncz-rescue")"
    ( set +e; . "$impl"; cp() { return 1; }; \
      ncz_promote_outgoing_rescue "$esp4" "$PRIMARY_AMD64" "" ) \
        >"$impl_dir/s4.log" 2>&1
    r4_after="$(sha "$esp4/vmlinuz-7.2.7-1-t2-ncz-rescue")"
    if [ -n "$r4_before" ] && [ "$r4_before" = "$r4_after" ] \
       && [ ! -e "$esp4/vmlinuz-$STABLE_A-rescue" ]; then
        ok "4) failed copy leaves the old rescue intact"
    else
        bad "4) failed copy leaves the old rescue intact" \
            "$(printf 'before=%s after=%s\n' "$r4_before" "$r4_after"; ls -1 "$esp4"; cat "$impl_dir/s4.log")"
    fi

    rm -rf "$impl_dir"
}

for s in "${SOURCES[@]}"; do
    run_for_source "$s"
done

echo
echo "refind rescue-promotion tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
