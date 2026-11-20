#!/bin/bash
# test-no-panthor-boot.sh -- Mali-only boot menu (operator order 2026-11-16,
# "No panthor Mali only").
#
# The arm64 generator (assets/refind/ncz-refind-refresh.sh) must:
#   1. never emit a Panthor menuentry and never emit sky1.gpu=mesa, even when
#      a panthor.ko exists for the booted kernel (the case the old code
#      turned into an entry via the ncz_panthor_module_present gate);
#   2. never learn, honour, or keep a stored/learned default naming Panthor:
#      a prefs default or a live refind.conf default_selection naming Panthor
#      falls back to the Mali default entry;
#   3. keep the Mali default entry name, its sky1.gpu=vendor option, and the
#      module_blacklist=panthor,panfrost console/rescue blacklists.
#
# Usage:
#   bash build/test-no-panthor-boot.sh                 # the shipped hook
#   bash build/test-no-panthor-boot.sh <script> [...]  # explicit script(s)
# The explicit form accepts the PRE-FIX script (e.g.
# `git show <base>:assets/refind/ncz-refind-refresh.sh > old.sh`):
# the Panthor cases must FAIL there, proving the tests are meaningful.
#
# Fixtures and fakes only: static source assertions plus the shipped
# default-selection logic extracted verbatim and run against fixture
# defaults. No root, no ESP, nothing booted.
#
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file is
# missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -gt 0 ]; then
    SOURCES=("$@")
else
    SOURCES=("$REPO/assets/refind/ncz-refind-refresh.sh")
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

MALI_DEFAULT="7.3 Mali (Default)"

# --- run the shipped default-selection logic against fixture defaults ------
# Extracts the learn/discard/honour block verbatim (learn -> discard ->
# honour -> persist) and runs it with stub vars: DEFAULT_TOKEN is the
# policy-computed Mali default, the prefs default names Panthor, and the live
# default is supplied per case. Prints the resulting DEFAULT_TOKEN.
run_default_logic() {  # <src> <workdir> -> prints DEFAULT_TOKEN
    local src="$1" work="$2"
    {
        echo 'DESKTOP_COMPONENT_DISABLED=0'
        echo 'DEFAULT_TOKEN="'"$MALI_DEFAULT"'"'
        echo 'SAFE_DEFAULT_TOKEN="$DEFAULT_TOKEN"'
        echo 'NCZ_REFIND_DEFAULT="7.3 Panthor (Experimental)"'
        echo 'NCZ_REFIND_TIMEOUT=""'
        echo '_live_default="'"${3:-7.3 Panthor (Experimental)}"'"'
        echo '_live_timeout=""'
        echo "NCZ_PREFS=\"$work/prefs.conf\""
        awk '/^# Learn from the live file/,/^\} > "\$NCZ_PREFS"/' "$src"
        echo 'printf "%s\n" "$DEFAULT_TOKEN"'
    } > "$work/run.sh"
    sed -i -e "s#\$NCZ_PREFS#$work/prefs.conf#g" "$work/run.sh"
    bash "$work/run.sh" 2>/dev/null | tail -1
}

check_source() {  # <src> <tag>
    local src="$1" tag="$2" rc=0
    if grep -Eq '^[[:space:]]*echo "menuentry.*[Pp]anthor' "$src"; then
        bad "$tag: source still generates a Panthor menuentry"; rc=1
    else
        ok "$tag: no Panthor menuentry generation"
    fi
    if grep -Eq '^[[:space:]]*(export )?PANTHOR_OPTIONS=' "$src"; then
        bad "$tag: source still builds a PANTHOR_OPTIONS (sky1.gpu=mesa) path"; rc=1
    else
        ok "$tag: no PANTHOR_OPTIONS (sky1.gpu=mesa) path"
    fi
    if grep -Eq 'ncz_panthor_module_present\(\)' "$src" \
        || grep -Eq 'ncz_panthor_module_present "\$KVER_NEXT"' "$src"; then
        bad "$tag: source still gates a Panthor entry on a module probe"; rc=1
    else
        ok "$tag: no module-gated Panthor entry"
    fi
    # sky1.gpu=mesa must not appear as an emitted option string (comments
    # describing the removal are fine; an options assignment is not).
    if grep -Eq '^[[:space:]]*[^#]*sky1\.gpu=mesa' "$src"; then
        bad "$tag: source still emits sky1.gpu=mesa outside a comment"; rc=1
    else
        ok "$tag: no sky1.gpu=mesa option emitted"
    fi
    if grep -q 'DEFAULT_TOKEN="${NCZ_KS}Mali (Default)"' "$src"; then
        ok "$tag: default entry name unchanged"
    else
        bad "$tag: default entry name changed"; rc=1
    fi
    if grep -Eq '^[[:space:]]*[^#]*sky1\.gpu=vendor' "$src"; then
        ok "$tag: Mali entry keeps sky1.gpu=vendor"
    else
        bad "$tag: Mali entry lost sky1.gpu=vendor"; rc=1
    fi
    if grep -q 'CONSOLE_GPU_BLACKLIST="panthor,panfrost"' "$src"; then
        ok "$tag: module_blacklist=panthor,panfrost stays (console)"
    else
        bad "$tag: console module_blacklist=panthor,panfrost is gone (must stay)"; rc=1
    fi
    if grep -q 'RESCUE_ACCEL_BLACKLIST="panthor,panfrost,mali_kbase' "$src"; then
        ok "$tag: rescue accelerator blacklist keeps panthor"
    else
        bad "$tag: rescue blacklist lost panthor (must stay)"; rc=1
    fi
    return $rc
}

check_default() {  # <src> <tag>
    local src="$1" tag="$2" rc=0
    local work; work="$(mktemp -d)"
    local got
    got="$(run_default_logic "$src" "$work")"
    rm -rf "$work"
    case "$got" in
        "$MALI_DEFAULT") ok "$tag: Panthor default discarded (got '$got')" ;;
        *[Pp][Aa][Nn][Tt][Hh][Oo][Rr]*) bad "$tag: default still names Panthor ('$got')"; rc=1 ;;
        *) bad "$tag: default is not the Mali default ('$got')"; rc=1 ;;
    esac
    return $rc
}

for src in "${SOURCES[@]}"; do
    echo "=== $(basename "$src") ==="
    [ -r "$src" ] || { bad "$src is readable" "cannot read $src"; continue; }
    bash -n "$src" 2>/dev/null || { bad "$src parses" "$(bash -n "$src" 2>&1 | head -5)"; continue; }
    short="$(basename "$src")"
    c1=0; c2=0
    check_source "$src" "$short" || c1=1
    check_default "$src" "$short" || c2=1
    upper_work="$(mktemp -d)"
    upper_got="$(run_default_logic "$src" "$upper_work" '7.3 PANTHOR (Experimental)')"
    rm -rf "$upper_work"
    if [ "$upper_got" = "$MALI_DEFAULT" ]; then
        ok "$short: uppercase PANTHOR live default discarded"
    else
        bad "$short: uppercase PANTHOR live default was retained ('$upper_got')"; c2=1
    fi
    [ "$c1" = 0 ] && [ "$c2" = 0 ] && ok "$short: all no-panthor-boot cases pass"
done

echo
echo "no-panthor-boot: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
