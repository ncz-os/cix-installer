#!/bin/bash
# lint-hook-arch-gates.sh -- every post-install hook that carries platform-specific content must say what it does
# on the other architecture. run-all.sh executes EVERY hook on EVERY architecture, so an ungated Sky1 hook runs on
# x86 (this caused the serial-getty@ttyAMA0, ncz-performance-mode and cix-detect-display leaks on T2).
#
# A hook is flagged when it has >= LINT_MIN_HITS non-comment lines naming a platform (Sky1/cix/mali/panthor/aarch64
# vs T2/apple/nvidia/intel/amd64) and NO arch check (uname -m, dpkg --print-architecture, BUILD_ARCH, NCZ_ARCH, ARCH=,
# aarch64/x86_64/amd64 case arms). Flagged hooks must be listed in build/hook-arch-allowlist.tsv (hook<TAB>reason).
# New hooks cannot be added to the allowlist without a written reason; the goal is for the list to shrink.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${LINT_ROOT:-$(cd "$HERE/.." && pwd)}"
DIR="${LINT_HOOK_DIR:-$ROOT/post-install}"
ALLOW="${LINT_ALLOWLIST:-$ROOT/build/hook-arch-allowlist.tsv}"
MIN="${LINT_MIN_HITS:-3}"
SKY='sky1|cixmini|cix-|mali|panthor|aarch64|arm64|ttyAMA|npu|vpu|noe'
X86='t2linux|apple|nvidia|cuda|intel|amd64|x86_64|thunderbolt'
CHK='sys_vendor|product_name|uname -m|--print-architecture|BUILD_ARCH|NCZ_ARCH|NCZ_TARGET_ARCH|\$ARCH|\$\{ARCH|aarch64\)|x86_64\)|amd64\)|arm64\)'
FAIL=0; n=0
for f in "$DIR"/*.sh; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; n=$((n+1))
    # 'cix-installer' is the project's own directory name, not a platform reference
    body="$(grep -v '^[[:space:]]*#' "$f" | sed 's/cix-installer//g; s/cix-detect-display//g')"
    sky="$(printf '%s\n' "$body" | grep -Eic "$SKY" || true)"
    x86="$(printf '%s\n' "$body" | grep -Eic "$X86" || true)"
    chk="$(printf '%s\n' "$body" | grep -Ec -- "$CHK" || true)"
    [ "$chk" -gt 0 ] && continue
    if [ "$sky" -ge "$MIN" ] || [ "$x86" -ge "$MIN" ]; then
        if [ -f "$ALLOW" ] && awk -F'\t' -v h="$b" '$1==h && $2!="" {f=1} END{exit(f?0:1)}' "$ALLOW"; then continue; fi
        echo "LINT FAIL: $b names a platform (sky1=$sky x86=$x86 lines) but has no architecture check." >&2
        echo "  gate it: [ \"\$(uname -m)\" = aarch64 ] || { echo \"$b: not Sky1, skipping\"; exit 0; }   (log and no-op on the other arch)" >&2
        echo "  or list it in build/hook-arch-allowlist.tsv with a reason." >&2
        FAIL=1
    fi
done
# stale allowlist rows (hook renamed/removed, or gate added) must be dropped so the list only shrinks
if [ -f "$ALLOW" ]; then
    while IFS=$'\t' read -r h why; do
        case "$h" in ''|'#'*) continue ;; esac
        [ -f "$DIR/$h" ] || { echo "LINT FAIL: allowlist row '$h' has no such hook" >&2; FAIL=1; }
    done < "$ALLOW"
fi
[ "$FAIL" = 0 ] && echo "lint-hook-arch-gates: OK ($n hooks)"
exit "$FAIL"
