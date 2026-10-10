#!/bin/bash
# test-preseed-consistency.sh — guard the "one authoritative preseed" contract.
#
# Operator 2026-10-10: "We had redundant preseeds before also." This test makes
# the redundancy explicit and fails closed on the shapes that used to bite:
#
#   * the SAME debconf question set TWICE with DIFFERENT values (a real
#     conflict — which line wins depends on d-i's load order and is not
#     intentional).  -> FAIL
#   * the SAME question set twice with the SAME value (harmless but stale).
#     -> WARN (reported, not fatal; keep the tree honest)
#   * a question NOT in build/preseed-known-keys.txt (forces a conscious
#     allow-list entry, so a legacy/Ubuntu-era key cannot creep back in).
#     -> FAIL
#   * a question set BOTH in the static preseed and at runtime by a
#     preseed/*.sh db_set, unless listed in build/preseed-runtime-overrides.txt
#     as an intentional override (the helper runs later and wins).
#     -> FAIL
#   * more than one static preseed .cfg, or per-arch preseed fixtures that
#     differ (the preseed must be arch-agnostic; arch is resolved at runtime).
#     -> FAIL
#
# Usage: build/test-preseed-consistency.sh
#        build/test-preseed-consistency.sh --self-test   (proves the guard by
#        mutation: a synthetic clean tree passes, a conflicting/unknown tree fails)
set -euo pipefail

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ "$SELF_TEST" = 1 ]; then
    src="$(cd "$(dirname "$0")" && pwd)"
    rc=0
    mk() { # mk <dir>; seeds a minimal tree from the real ones
        d="$1"; mkdir -p "$d/preseed" "$d/build"
        cp "$src/../preseed/preseed.cfg" "$d/preseed/preseed.cfg"
        cp "$src/preseed-known-keys.txt" "$d/build/preseed-known-keys.txt"
        cp "$src/preseed-runtime-overrides.txt" "$d/build/preseed-runtime-overrides.txt"
    }
    t="$(mktemp -d -t preseed-selftest.XXXXXX)"
    trap 'rm -rf "$t"' EXIT
    # clean copy must PASS
    mk "$t/clean"
    if REPO_ROOT="$t/clean" bash "$src/test-preseed-consistency.sh" >/dev/null 2>&1; then
        echo "  PASS  self-test: clean tree passes"
    else
        echo "  FAIL  self-test: clean tree should pass" >&2; rc=1
    fi
    # conflicting duplicate must FAIL
    mk "$t/conflict"
    printf 'd-i mirror/suite string bookworm\n' >> "$t/conflict/preseed/preseed.cfg"
    if REPO_ROOT="$t/conflict" bash "$src/test-preseed-consistency.sh" >/dev/null 2>&1; then
        echo "  FAIL  self-test: conflicting duplicate should fail" >&2; rc=1
    else
        echo "  PASS  self-test: conflicting duplicate fails"
    fi
    # unknown key must FAIL
    mk "$t/unknown"
    printf 'd-i ncz/dead-key string yes\n' >> "$t/unknown/preseed/preseed.cfg"
    if REPO_ROOT="$t/unknown" bash "$src/test-preseed-consistency.sh" >/dev/null 2>&1; then
        echo "  FAIL  self-test: unknown key should fail" >&2; rc=1
    else
        echo "  PASS  self-test: unknown key fails"
    fi
    [ "$rc" -eq 0 ] && echo "SELF-TEST OK" || echo "SELF-TEST FAILED"
    exit "$rc"
fi

cd "$REPO_ROOT"

# ONE exit trap for the whole run: in bash a later `trap ... EXIT` REPLACES the
# earlier one, so registering one per temp file leaves the earlier files behind.
CLEANUP_PATHS=()
cleanup() { [ "${#CLEANUP_PATHS[@]}" -gt 0 ] && rm -rf "${CLEANUP_PATHS[@]}" 2>/dev/null; return 0; }
trap cleanup EXIT

PRESEED=preseed/preseed.cfg
KNOWN=build/preseed-known-keys.txt
OVER=build/preseed-runtime-overrides.txt

PASS=0
FAIL=0
WARN=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=$((FAIL + 1)); }
warn() { echo "  WARN  $1"; WARN=$((WARN + 1)); }

echo "=== preseed consistency (${PRESEED}) ==="
[ -f "$PRESEED" ] || { fail "missing $PRESEED"; echo "FAILED ($FAIL)"; exit 1; }
[ -f "$KNOWN" ] || { fail "missing allow-list $KNOWN"; echo "FAILED ($FAIL)"; exit 1; }
[ -f "$OVER" ] || { fail "missing overrides list $OVER"; echo "FAILED ($FAIL)"; exit 1; }

# ---------------------------------------------------------------- 1. one source
mapfile -t static_pres < <(find preseed -maxdepth 1 -type f -name '*preseed*.cfg' | sort)
if [ "${#static_pres[@]}" -eq 1 ] && [ "${static_pres[0]}" = "$PRESEED" ]; then
    pass "exactly one static preseed: $PRESEED"
else
    fail "expected exactly one static preseed ($PRESEED); found: ${static_pres[*]:-none}"
fi

# per-arch fixtures must be byte-identical (preseed is arch-agnostic)
if [ -d build/iso/tests/fixtures/d-i-startup ]; then
    if diff -rq build/iso/tests/fixtures/d-i-startup/amd64 \
               build/iso/tests/fixtures/d-i-startup/arm64 >/dev/null 2>&1; then
        pass "per-arch d-i-startup fixtures are identical (arch-agnostic preseed)"
    else
        fail "per-arch d-i-startup fixtures differ — a preseed variant slipped in"
        diff -rq build/iso/tests/fixtures/d-i-startup/amd64 \
                 build/iso/tests/fixtures/d-i-startup/arm64 2>&1 | sed 's/^/        /' >&2
    fi
fi

# ------------------------------------------ 2. duplicate/conflicting static keys
# Emit: <key>\t<value> for every `d-i <key> <type> <value>` line except `seen`.
tmp_vals="$(mktemp -t preseed-vals.XXXXXX)"; CLEANUP_PATHS+=("$tmp_vals")
awk '
    /^d-i[ \t]+[^ \t]+[ \t]+seen[ \t]*/ { next }   # seen-markers carry no value
    /^d-i[ \t]+[^ \t]+[ \t]+[^ \t]+/ {
        key=$2; type=$3
        value=$0
        sub(/^d-i[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", value)  # strip to value
        printf "%s\t%s\n", key, value
    }
' "$PRESEED" > "$tmp_vals"

conflict=0
while IFS=$'\t' read -r key ndistinct first; do
    conflict=1
    fail "CONFLICT: $key set to $ndistinct different values in $PRESEED (first: '$first')"
    grep -n "^d-i[ \t]\+$key[ \t]" "$PRESEED" | sed 's/^/        /' >&2
done < <(awk -F'\t' '
    {
        if (!(($1 SUBSEP $2) in vseen)) {
            vseen[$1 SUBSEP $2]=1
            cnt[$1]++
            if (!($1 in first)) first[$1]=$2
        }
    }
    END { for (k in cnt) if (cnt[k]>1) printf "%s\t%d\t%s\n", k, cnt[k], first[k] }
' "$tmp_vals")
if [ "$conflict" -eq 0 ]; then
    pass "no conflicting duplicate keys in $PRESEED"
fi

# redundant (same value twice) — informational
awk -F'\t' '
    { c[$1 SUBSEP $2]++ }
    END { for (x in c) if (c[x]>1) { split(x,a,SUBSEP); printf "%s\t%d\n", a[1], c[x] } }
' "$tmp_vals" | while IFS=$'\t' read -r key cnt; do
    warn "REDUNDANT: $key declared $cnt times with the same value in $PRESEED"
done

# ------------------------------------------ 3. allow-list (known consumer) check
unknown=0
# allow-list lines: strip #-comments and surrounding blanks before matching
KNOWN_KEYS="$(mktemp -t preseed-known.XXXXXX)"; CLEANUP_PATHS+=("$KNOWN_KEYS")
awk '{ sub(/#.*/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); if ($0!="") print }' "$KNOWN" > "$KNOWN_KEYS"
while IFS=$'\t' read -r key _; do
    [ -n "$key" ] || continue
    if ! grep -qxF "$key" "$KNOWN_KEYS"; then
        unknown=1
        fail "UNKNOWN KEY: $key is set in $PRESEED but not in $KNOWN (add it with a reason, or remove the line)"
    fi
done < "$tmp_vals"
if [ "$unknown" -eq 0 ]; then
    pass "every key in $PRESEED is allow-listed in $KNOWN"
fi

# ------------------------------------------ 4. runtime-override double-set check
# keys set by db_set in preseed/*.sh
rtset="$(mktemp -t preseed-rt.XXXXXX)"; CLEANUP_PATHS+=("$rtset")
shopt -s nullglob
_pres_sh=(preseed/*.sh)
shopt -u nullglob
if [ "${#_pres_sh[@]}" -gt 0 ]; then
    grep -rhoE '^[[:space:]]*db_set[[:space:]]+[A-Za-z0-9_./-]+' "${_pres_sh[@]}" 2>/dev/null \
        | awk '{print $2}' | sort -u > "$rtset"
else
    : > "$rtset"
fi

double=0
while read -r rk; do
    [ -n "$rk" ] || continue
    # is it also a static key?
    grep -qE "^d-i[ \t]+$rk[ \t]" "$PRESEED" || continue
    # intentional override?
    grep -qE "^$rk([[:space:]]|$)" "$OVER" && continue
    double=1
    fail "DOUBLE-SET: $rk is set in $PRESEED AND by a preseed/*.sh db_set; add it to $OVER if intentional"
done < "$rtset"
if [ "$double" -eq 0 ]; then
    pass "no unlisted runtime/static double-set keys"
fi

echo "=== result: ${PASS} passed, ${FAIL} failed, ${WARN} warned ==="
[ "$FAIL" -eq 0 ] || { echo "FAILED ($FAIL)"; exit 1; }
echo "OK"
