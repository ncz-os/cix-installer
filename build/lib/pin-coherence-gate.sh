# shellcheck shell=bash
# build/lib/pin-coherence-gate.sh -- the build-image.sh preflight decision on
# build/check-pin-coherence.sh output (docs/BUILD-STABILITY.md M3 + M7).
#
# Sourced.  ncz_pin_coherence_gate CHECKER ROOT ARCH KNOWN_FILE
#   Runs CHECKER --root ROOT --arch ARCH and prints one decision per line:
#     OK: ...     the pins agree
#     WARN: ...   a rule listed in KNOWN_FILE failed (owner + exact fix shown)
#     FAIL: ...   anything else: an unlisted rule failed, the checker could not
#                 judge the tree (rc 2), it failed without naming a rule, or
#                 KNOWN_FILE is malformed
#   Returns 0 when there is no FAIL line, 1 otherwise.  The full checker output
#   goes to stderr (preflight writes it to the stage log).
# CHECKER is an argument so build/test-build-image.sh can drive the decision
# with fixture checker output; build-image.sh always passes the real script.

ncz_pin_coherence_gate() {
    local checker="$1" root="$2" arch="$3" known="$4"
    local out rc=0 rules r line fail=0
    local -A owner=() fix=()

    if [ -f "$known" ]; then
        local n=0 k o f _rest
        while IFS=$'\t' read -r k o f _rest; do
            n=$((n+1))
            case "$k" in ''|'#'*) continue ;; esac
            if [ -z "$o" ] || [ -z "$f" ] || [[ ! "$k" =~ ^[a-z][a-z-]*$ ]]; then
                echo "FAIL: $known line $n is malformed (need rule<TAB>owner<TAB>fix<TAB>reason); refusing to guess which failures are known"
                fail=1; continue
            fi
            owner[$k]="$o"; fix[$k]="$f"
        done < "$known"
    fi

    out="$(bash "$checker" --root "$root" --arch "$arch" 2>&1)" || rc=$?
    printf '%s\n' "$out" >&2

    if [ "$rc" = 0 ]; then
        echo "OK: pin coherence OK (check-pin-coherence.sh --arch $arch)"
        return "$fail"
    fi
    if [ "$rc" != 1 ]; then
        echo "FAIL: check-pin-coherence.sh could not judge the tree (rc=$rc); fix the error above"
        return 1
    fi
    rules="$(sed -n 's/^\[pin-coherence\] FAIL \([a-z-]*\):.*/\1/p' <<<"$out" | sort -u)"
    if [ -z "$rules" ]; then
        echo "FAIL: check-pin-coherence.sh failed (rc=1) without naming a rule"
        return 1
    fi
    for r in $rules; do
        if [ -n "${owner[$r]:-}" ]; then
            echo "WARN: ================ KNOWN pin-coherence failure: $r ================"
            while IFS= read -r line; do
                case "$line" in "[pin-coherence] FAIL $r:"*) echo "WARN:   $line" ;; esac
            done <<<"$out"
            echo "WARN:   owner: ${owner[$r]}"
            echo "WARN:   fix:   ${fix[$r]}"
            echo "WARN:   listed in $(basename "$known"); the build continues, but this image does not meet the pin for '$r'"
        else
            while IFS= read -r line; do
                case "$line" in "[pin-coherence] FAIL $r:"*) echo "FAIL: $line" ;; esac
            done <<<"$out"
            echo "FAIL: pin-coherence rule '$r' failed and is not a known failure; fix and commit the pin files (never add it to $(basename "$known") to get a build through)"
            fail=1
        fi
    done
    return "$fail"
}
