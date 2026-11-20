#!/bin/bash
# The arm64 rEFInd menu titles and default tokens name the kernel series of the
# kernel they boot (KVER_NEXT), never a hardcoded "7.3".  Drives the real
# emission block of assets/refind/ncz-refind-refresh.sh with stub variables and
# checks the titles for 7.4 and 7.3 kernels; also checks the default tokens are
# series-derived and that no literal "7.3 Mali"-style title text is left.
#
# Run:  bash build/test-refind-kernel-series-label.sh [path/to/ncz-refind-refresh.sh]

set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REFIND="${1:-$REPO/assets/refind/ncz-refind-refresh.sh}"
W=$(mktemp -d "${TMPDIR:-/var/tmp}/refind-series.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  PASS  $1"
    else fail=$((fail + 1)); echo "  FAIL  $1: expected '$2', got '$3'"; fi
}

MENU_START=$(grep -n '^    echo "timeout \$REFIND_TIMEOUT"$' "$REFIND" | cut -d: -f1)
MENU_END=$(awk -v s="${MENU_START:-0}" 'NR>s && /^} > "\$REFIND_CONF"$/{print NR; exit}' "$REFIND")
MENU_OPEN=$(awk -v m="${MENU_START:-0}" 'NR<m && /^\{$/{o=NR} END{print o}' "$REFIND")
[ -n "$MENU_OPEN" ] && [ -n "$MENU_END" ] || { echo "FAIL: cannot locate the emission block"; exit 1; }
extract_menu() { sed -n "${MENU_OPEN},${MENU_END}p" "$REFIND"; }

emit_titles() { # <kver> -> menuentry titles (the real block, NCZ_KS NOT preset)
    local out="$W/refind.conf"
    : > "$out"
    NCZ_VARIANT=desktop NCZ_MENU_VARIANT=desktop REFIND_CONF="$out" NEXT_AVAILABLE=1 KVER_NEXT="$1" \
      NEXT_INITRD_AVAILABLE=1 NCZ_RELEASE_SHORT=NCZ PANTHOR_ENTRY=1 REFIND_ICON= REFIND_BANNER= \
      REFIND_THEME= REFIND_TIMEOUT=5 DEFAULT_TOKEN=x MALI_OPTIONS=x PANTHOR_OPTIONS=y \
      NEXT_CONSOLE_OPTIONS=c NEXT_RESCUE_OPTIONS=r RESCUEPART_OPTIONS=p \
      bash -c "$(extract_menu)" >/dev/null 2>&1
    grep -o 'menuentry "[^"]*"' "$out" 2>/dev/null | sed 's/^menuentry "//;s/"$//'
}

echo "=== titles follow the booted kernel ==="
t74=$(emit_titles 7.4.0-rc3-sky1-ncz)
check "7.4 kernel: Mali entry says 7.4"        1 "$(grep -c -- '-  7\.4 Mali (Default)$' <<<"$t74")"
check "7.4 kernel: Console entry says 7.4"     1 "$(grep -c -- '-  7\.4 Console (All Accelerators, Mali)$' <<<"$t74")"
check "7.4 kernel: Rescue entry says 7.4"      1 "$(grep -c -- '-  7\.4 Rescue / No Accelerators (Console)$' <<<"$t74")"
check "7.4 kernel: Rescue Partition says 7.4"  1 "$(grep -c -- '-  7\.4 Rescue Partition (Console)$' <<<"$t74")"
check "7.4 kernel: no title says 7.3"          0 "$(grep -c '7\.3' <<<"$t74")"
t73=$(emit_titles 7.3.4-sky1-ncz)
check "7.3 kernel: Mali entry says 7.3"        1 "$(grep -c -- '-  7\.3 Mali (Default)$' <<<"$t73")"
tnone=$(emit_titles sky1-ncz)
check "no version in KVER: titles drop the series, still unique" 1 "$(grep -c -- '-  Mali (Default)$' <<<"$tnone")"

echo "=== default tokens are series-derived and match exactly one title ==="
for kv in 7.4.0-rc3-sky1-ncz 7.3.4-sky1-ncz; do
    ks=$(printf '%s' "$kv" | sed -n -E 's/^([0-9]+\.[0-9]+).*/\1 /p')
    titles=$(emit_titles "$kv")
    check "$kv: '${ks}Mali (Default)' matches exactly one title" 1 "$(grep -c -F -- "${ks}Mali (Default)" <<<"$titles")"
    check "$kv: '${ks}Console (All Accelerators, Mali)' matches exactly one title" 1 "$(grep -c -F -- "${ks}Console (All Accelerators, Mali)" <<<"$titles")"
done
check "script derives the default tokens from NCZ_KS" 4 "$(grep -c 'DEFAULT_TOKEN=.*NCZ_KS' "$REFIND")"

echo "=== no hardcoded 7.3 title text is left ==="
check "no literal '7.3 Mali|Console|Rescue' title/token in the script" 0 \
    "$(grep -v '^[[:space:]]*#' "$REFIND" | grep -c -E '7\.3 (Mali|Console|Rescue)')"

echo "=== server menus follow the booted kernel too (arm64) ==="
emit_titles_variant() { # <script> <variant> <kver-var> <kver> -> titles
    local script="$1" variant="$2" kvar="$3" kver="$4" out="$W/refind.v.conf" ms me mo
    ms=$(grep -n '^    echo "timeout \$REFIND_TIMEOUT"$' "$script" | cut -d: -f1)
    me=$(awk -v s="${ms:-0}" 'NR>s && /^} > "\$REFIND_CONF"$/{print NR; exit}' "$script")
    mo=$(awk -v m="${ms:-0}" 'NR<m && /^\{$/{o=NR} END{print o}' "$script")
    : > "$out"
    env NCZ_VARIANT="$variant" NCZ_MENU_VARIANT="$variant" REFIND_CONF="$out" NEXT_AVAILABLE=1 STABLE_AVAILABLE=1 \
      "$kvar=$kver" NEXT_INITRD_AVAILABLE=1 STABLE_INITRD_AVAILABLE=1 NCZ_RELEASE_SHORT=NCZ PANTHOR_ENTRY=1 \
      REFIND_ICON= REFIND_BANNER= REFIND_THEME= REFIND_TIMEOUT=5 DEFAULT_TOKEN=x MALI_OPTIONS=x PANTHOR_OPTIONS=y \
      NEXT_CONSOLE_OPTIONS=c NEXT_RESCUE_OPTIONS=r RESCUEPART_OPTIONS=p STABLE_OPTIONS=o STABLE_CONSOLE_OPTIONS=c \
      STABLE_RESCUE_OPTIONS=r \
      bash -c "$(sed -n "${mo},${me}p" "$script")" >/dev/null 2>&1
    grep -o 'menuentry "[^"]*"' "$out" 2>/dev/null | sed 's/^menuentry "//;s/"$//'
}
srv=$(emit_titles_variant "$REFIND" server KVER_NEXT 7.4.0-rc3-sky1-ncz)
check "arm64 server: Console entry says 7.4"          1 "$(grep -c -- '-  7\.4 Console (All Accelerators, Mali)$' <<<"$srv")"
check "arm64 server: Rescue Partition entry says 7.4" 1 "$(grep -c -- '-  7\.4 Rescue Partition (Console)$' <<<"$srv")"
check "arm64 server: no title says 7.3"               0 "$(grep -c '7\.3' <<<"$srv")"

echo "=== amd64 script: same rule ==="
AMD="${2:-$REPO/assets/refind/ncz-refind-refresh-amd64.sh}"
if [ -f "$AMD" ]; then
    d74=$(emit_titles_variant "$AMD" desktop KVER_STABLE 7.4.0-rc3-t2-ncz)
    check "amd64 7.4: Default entry says 7.4"  1 "$(grep -c -- '-  7\.4 (Default)$' <<<"$d74")"
    check "amd64 7.4: Console entry says 7.4"  1 "$(grep -c -- '-  7\.4 Console$' <<<"$d74")"
    d75=$(emit_titles_variant "$AMD" desktop KVER_STABLE 7.5.0-t2-ncz)
    check "amd64 7.5 kernel: Default entry says 7.5 (no hardcoded 7.4)" 1 "$(grep -c -- '-  7\.5 (Default)$' <<<"$d75")"
    check "amd64 7.5 kernel: no title says 7.4"                        0 "$(grep -c '7\.4' <<<"$d75")"
    s74=$(emit_titles_variant "$AMD" server KVER_STABLE 7.4.0-rc3-t2-ncz)
    check "amd64 server: Console entry says 7.4"   1 "$(grep -c -- '-  7\.4 Console$' <<<"$s74")"
    check "amd64 server: no desktop (Default) entry" 0 "$(grep -c '(Default)' <<<"$s74")"
    ttl=$(bash -c "$(awk '/^ncz_menu_title_for\(\) \{/,/^\}/' "$AMD"); ncz_menu_title_for 7.5.0-t2-ncz")
    check "add-only title derives the series from the kernel" "7.5 Kernel 7.5.0-t2-ncz" "$ttl"
    check "no literal '7.4 (Default)|7.4 Console|7.4 Kernel' title text in the amd64 script" 0 \
        "$(grep -v '^[[:space:]]*#' "$AMD" | grep -c -E '7\.4 (\(Default\)|Console|Kernel)')"
else
    echo "  SKIP  amd64 script not found: $AMD"
fi

echo "=== amd64 server entries carry panic=30; desktop does not ==="
if [ -f "$AMD" ]; then
    fn=$(awk '/^ncz_apply_menu_variant\(\) \{/,/^\}/' "$AMD")
    opts() { # <variant> <STABLE_OPTIONS preset> -> "<STABLE_OPTIONS>|<CONSOLE>|<RESCUEPART>"
        bash -c "$fn"'
STABLE_AVAILABLE=1; NCZ_RELEASE_SHORT=NCZ; REFIND_BANNER=x
STABLE_OPTIONS="root=r console=tty0 '"$2"'"; STABLE_CONSOLE_OPTIONS="root=r console=tty0 systemd.unit=multi-user.target"
RESCUEPART_OPTIONS="root=PARTUUID=p rootwait"; NCZ_VARIANT='"$1"'
DEFAULT_TOKEN=x; NCZ_KS="7.4 "
ncz_apply_menu_variant >/dev/null 2>&1
printf "%s|%s|%s\n" "$STABLE_OPTIONS" "$STABLE_CONSOLE_OPTIONS" "$RESCUEPART_OPTIONS"' 2>/dev/null
    }
    sv=$(opts server "")
    check "server: default entry options carry panic=30"       1 "$(awk -F'|' '{print $1}' <<<"$sv" | grep -c -w 'panic=30')"
    check "server: console entry options carry panic=30"       1 "$(awk -F'|' '{print $2}' <<<"$sv" | grep -c -w 'panic=30')"
    check "server: rescue partition options carry panic=30"    1 "$(awk -F'|' '{print $3}' <<<"$sv" | grep -c -w 'panic=30')"
    check "server: panic=30 appears once per entry"            3 "$(grep -o 'panic=30' <<<"$sv" | wc -l | tr -d ' ')"
    dv=$(opts desktop "")
    check "desktop: no panic= on any entry"                    0 "$(grep -c 'panic=' <<<"$dv")"
    pv=$(opts server "panic=6")
    check "server: an existing panic= is not overridden"       0 "$(awk -F'|' '{print $1}' <<<"$pv" | grep -c 'panic=30')"
fi

echo
echo "refind kernel-series label: $pass passed, $fail failed"
[ "$fail" = 0 ]
