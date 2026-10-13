#!/bin/bash
# test-platform-lint.sh -- exercise build/lint-platform.sh, build/gen-hooks-lists.sh
# and the hooks.list handling in post-install/run-all.sh against synthetic
# trees, in the posture of build/test-arm64-gates.sh: drive the real scripts from
# script-controlled fixtures, prove BOTH directions (a clean tree passes, each
# class of violation fails with its LINT-<id> line).
#
# Run: bash build/test-platform-lint.sh
# Exit 0 = every case passed; 1 = at least one failed; 2 = a script under test is missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT="$REPO/build/lint-platform.sh"
GEN="$REPO/build/gen-hooks-lists.sh"
RUNALL="$REPO/post-install/run-all.sh"
for f in "$LINT" "$GEN" "$RUNALL"; do [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }; done

TMPROOT="$(mktemp -d -t platform-lint-test.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

tab() { sed 's/ ;; /\t/g'; }

# Build a minimal passing fixture repo in $1.
mkfixture() {
    local r="$1"
    rm -rf "$r"; mkdir -p "$r/build" "$r/docs" "$r/post-install"
    cp "$LINT" "$GEN" "$r/build/"
    tab > "$r/build/platform-deny-patterns.txt" <<'X'
# id ;; platform ;; ERE
sky1-soc ;; sky1 ;; \bsky1\b|cixmini
amd64-t2 ;; amd64 ;; \bt2\b|nvidia
X
    printf '#!/bin/bash\necho common\n' > "$r/post-install/10-common.sh"
    printf '#!/bin/bash\n# NCZ-PLATFORM-GUARD: sky1-arm64 only\ncase "$_ncz_pg_arch" in arm64) ;; esac\necho sky1 hook for cixmini\n' > "$r/post-install/20-sky.sh"
    printf '#!/bin/bash\n# NCZ-PLATFORM-GUARD: amd64 only\ncase "$_ncz_pg_arch" in amd64) ;; esac\necho t2 hook\n' > "$r/post-install/30-x86.sh"
    printf '#!/bin/bash\n# NCZ-MIXED-HOOK: both\necho mixed\n' > "$r/post-install/40-mix.sh"
    : > "$r/docs/platform-deny-exceptions.tsv"
    tab > "$r/docs/platform-inventory.tsv" <<'X'
# path ;; class ;; feature ;; reason
post-install/10-common.sh ;; common ;; - ;; generic
post-install/20-sky.sh ;; sky1 ;; - ;; sky only
post-install/30-x86.sh ;; amd64 ;; t2 ;; x86 only
post-install/40-mix.sh ;; mixed ;; - ;; both
post-install/hooks.list.sky1-arm64 ;; common ;; - ;; list
post-install/hooks.list.amd64 ;; common ;; - ;; list
build/ ;; common ;; - ;; build
docs/ ;; common ;; - ;; docs
X
    NCZ_LINT_ROOT="$r" bash "$r/build/gen-hooks-lists.sh" >/dev/null
}

run_lint() { NCZ_LINT_ROOT="$1" bash "$1/build/lint-platform.sh" 2>&1; }

expect_pass() {  # name [root]
    local out rc; out=$(run_lint "${2:-$F}"); rc=$?
    [ "$rc" = 0 ] && ok "$1" || bad "$1 (expected pass, rc=$rc)" "$out"
}
expect_fail() {  # name root needle
    local out rc; out=$(run_lint "$2"); rc=$?
    if [ "$rc" != 0 ] && printf '%s\n' "$out" | grep >/dev/null -F -- "$3"; then ok "$1"
    else bad "$1 (expected rc!=0 and '$3', rc=$rc)" "$out"; fi
}

F="$TMPROOT/fx"

# ---- lint: clean fixture ----------------------------------------------------
mkfixture "$F"
expect_pass "clean fixture passes"

# ---- generator direction ----------------------------------------------------
sky=$(grep -vc '^#' "$F/post-install/hooks.list.sky1-arm64")
amd=$(grep -vc '^#' "$F/post-install/hooks.list.amd64")
[ "$sky" = 3 ] && grep -qx 20-sky.sh "$F/post-install/hooks.list.sky1-arm64" \
  && ! grep -qx 30-x86.sh "$F/post-install/hooks.list.sky1-arm64" \
  && ok "sky1 list = common + mixed + sky1, no amd64 hook" || bad "sky1 list content" "$(cat "$F/post-install/hooks.list.sky1-arm64")"
[ "$amd" = 3 ] && grep -qx 30-x86.sh "$F/post-install/hooks.list.amd64" \
  && ! grep -qx 20-sky.sh "$F/post-install/hooks.list.amd64" \
  && ok "amd64 list = common + mixed + amd64, no sky1 hook" || bad "amd64 list content" "$(cat "$F/post-install/hooks.list.amd64")"
grep -qx 40-mix.sh "$F/post-install/hooks.list.amd64" && grep -qx 40-mix.sh "$F/post-install/hooks.list.sky1-arm64" \
  && ok "mixed hook is on both lists" || bad "mixed hook on both lists"

# ---- HOOKS / COVER ----------------------------------------------------------
mkfixture "$F"; printf '#!/bin/bash\necho new\n' > "$F/post-install/50-new.sh"
expect_fail "unclassified hook is rejected (HOOKS)" "$F" "LINT-HOOKS: hook 50-new.sh has no exact inventory row"
expect_fail "unclassified hook is rejected (COVER)" "$F" "no inventory row for tracked file: post-install/50-new.sh"

mkfixture "$F"; echo 30-x86.sh >> "$F/post-install/hooks.list.sky1-arm64"
expect_fail "amd64 hook on the sky1 list is rejected" "$F" "30-x86.sh (amd64) must NOT be on the sky1-arm64 list"

mkfixture "$F"; grep -vx 10-common.sh "$F/post-install/hooks.list.amd64" > "$F/l" && mv "$F/l" "$F/post-install/hooks.list.amd64"
expect_fail "common hook missing from a list is rejected" "$F" "10-common.sh (common) must be on the amd64 list"

mkfixture "$F"; echo 99-ghost.sh >> "$F/post-install/hooks.list.amd64"
expect_fail "list naming a nonexistent hook is rejected" "$F" "names 99-ghost.sh which does not exist"

mkfixture "$F"; echo '# hand edit' >> "$F/post-install/hooks.list.amd64"
expect_fail "hand-edited (stale) list is rejected" "$F" "out of date"

mkfixture "$F"; sed -i '/hooks.list.amd64/d' "$F/docs/platform-inventory.tsv"
expect_fail "list file without inventory row is rejected" "$F" "no inventory row for tracked file: post-install/hooks.list.amd64"

# ---- FORMAT -----------------------------------------------------------------
mkfixture "$F"; printf 'post-install/10-common.sh\tbogus\t-\twhy\n' >> "$F/docs/platform-inventory.tsv"
expect_fail "bad class is rejected" "$F" "LINT-FORMAT: bad class 'bogus'"

mkfixture "$F"; printf 'docs/x\tsky1\tt2\twhy\n' >> "$F/docs/platform-inventory.tsv"
expect_fail "feature on a sky1 row is rejected" "$F" "feature on a sky1 row"

mkfixture "$F"; printf 'docs/zzz-gone.md\tcommon\t-\tstale\n' >> "$F/docs/platform-inventory.tsv"
expect_fail "stale exact row is rejected" "$F" "stale row (file is not tracked): docs/zzz-gone.md"

# ---- DENY -------------------------------------------------------------------
mkfixture "$F"; printf '#!/bin/bash\necho cixmini here\n' > "$F/post-install/10-common.sh"
expect_fail "sky1 token in a COMMON hook is rejected" "$F" "LINT-DENY: COMMON hook 10-common.sh contains a sky1 token [sky1-soc]"
printf '10-common.sh ;; sky1-soc ;; reviewed: message text\n' | tab > "$F/docs/platform-deny-exceptions.tsv"
expect_pass "reviewed exception admits the token"
out=$(run_lint "$F"); rc=$?; [ "$rc" = 0 ] || bad "exception run" "$out"
printf '#!/bin/bash\necho fine\n' > "$F/post-install/10-common.sh"
expect_fail "stale exception is rejected" "$F" "stale exception (no longer matches): 10-common.sh sky1-soc"

mkfixture "$F"; printf '#!/bin/bash\n# cixmini and nvidia in a comment only\necho ok\n' > "$F/post-install/10-common.sh"
expect_pass "platform tokens in comments are ignored"

mkfixture "$F"; printf '#!/bin/bash\necho nvidia-smi\n' > "$F/post-install/10-common.sh"
expect_fail "amd64 token in a COMMON hook is rejected" "$F" "contains a amd64 token [amd64-t2]"

mkfixture "$F"; printf '#!/bin/bash\necho cixmini\n' > "$F/post-install/40-mix.sh"; printf '# NCZ-MIXED-HOOK: x\n' >> "$F/post-install/40-mix.sh"
expect_pass "platform tokens in a MIXED hook are allowed"

# ---- GUARD ------------------------------------------------------------------
mkfixture "$F"; printf '#!/bin/bash\necho sky1 only\n' > "$F/post-install/20-sky.sh"
expect_fail "sky1 hook without guard is rejected" "$F" "sky1 hook 20-sky.sh has no NCZ-PLATFORM-GUARD"
mkfixture "$F"; printf '#!/bin/bash\necho x\n' > "$F/post-install/30-x86.sh"
expect_fail "amd64 hook without guard is rejected" "$F" "amd64 hook 30-x86.sh has no NCZ-PLATFORM-GUARD"
mkfixture "$F"; printf '#!/bin/bash\necho x\n' > "$F/post-install/40-mix.sh"
expect_fail "mixed hook without marker is rejected" "$F" "mixed hook 40-mix.sh has no NCZ-MIXED-HOOK"

# ---- run-all.sh: hooks.list handling ---------------------------------------
# Real run-all.sh against fake hooks. It only ever removes hooks from the plan.
mkra() {
    local d="$1"; rm -rf "$d"; mkdir -p "$d"
    local h
    for h in 10-common 20-sky 30-x86 40-mix; do printf '#!/bin/bash\necho "RAN-%s"\n' "$h" > "$d/$h.sh"; done
    printf '#!/bin/bash\necho RAN-70-bootloader\n' > "$d/70-bootloader.sh"
    printf '#!/bin/bash\necho RAN-99-diagnostics\n' > "$d/99-diagnostics.sh"
    printf '10-common.sh\n20-sky.sh\n40-mix.sh\n' > "$d/hooks.list.sky1-arm64"
    printf '10-common.sh\n30-x86.sh\n40-mix.sh\n' > "$d/hooks.list.amd64"
}
runra() {  # dir arch [extra env...]
    local d="$1" a="$2"; shift 2
    env NCZ_HOOK_DIR="$d" NCZ_LOGDIR="$d/log" NCZ_TTY=/dev/null NCZ_DISABLE_APT_SHIM=1 NCZ_TARGET_ARCH="$a" "$@" \
        bash "$RUNALL" 2>&1
}
ran() { printf '%s\n' "$1" | grep -o 'RAN-[0-9a-z-]*' | sort -u | tr '\n' ' '; }

R="$TMPROOT/ra"
mkra "$R"; out=$(runra "$R" arm64)
[ "$(ran "$out")" = "RAN-10-common RAN-20-sky RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && printf '%s\n' "$out" | grep >/dev/null -F "PLATFORM-SKIP: 30-x86.sh" \
  && ok "run-all arm64: sky1 list runs common+sky+mixed, skips and logs the amd64 hook" \
  || bad "run-all arm64" "$(ran "$out")"$'\n'"$(printf '%s\n' "$out" | grep -E 'PLATFORM|hooks.list')"
printf '%s\n' "$out" | grep >/dev/null ORPHAN && bad "run-all arm64 must not call a platform skip an ORPHAN" "$(printf '%s\n' "$out" | grep ORPHAN)" \
  || ok "run-all arm64: platform skip is not reported as ORPHAN"

mkra "$R"; out=$(runra "$R" amd64)
[ "$(ran "$out")" = "RAN-10-common RAN-30-x86 RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && printf '%s\n' "$out" | grep >/dev/null -F "PLATFORM-SKIP: 20-sky.sh" \
  && ok "run-all amd64: amd64 list skips and logs the sky1 hook" \
  || bad "run-all amd64" "$(ran "$out")"

mkra "$R"; out=$(runra "$R" x86_64)
printf '%s\n' "$out" | grep >/dev/null "platform=amd64" && ok "run-all maps x86_64 to platform amd64" || bad "run-all x86_64 mapping"

mkra "$R"; rm "$R"/hooks.list.*; out=$(runra "$R" arm64)
[ "$(ran "$out")" = "RAN-10-common RAN-20-sky RAN-30-x86 RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && printf '%s\n' "$out" | grep >/dev/null "legacy behavior" \
  && ok "run-all without any list runs every hook (legacy fallback)" || bad "run-all no-list fallback" "$(ran "$out")"

mkra "$R"; out=$(runra "$R" riscv64)
[ "$(ran "$out")" = "RAN-10-common RAN-20-sky RAN-30-x86 RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && ok "run-all with an unknown arch runs every hook (never guesses a platform)" || bad "run-all unknown arch" "$(ran "$out")"

mkra "$R"; out=$(runra "$R" arm64 NCZ_HOOKS_LIST=none)
[ "$(ran "$out")" = "RAN-10-common RAN-20-sky RAN-30-x86 RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && ok "run-all NCZ_HOOKS_LIST=none disables the list" || bad "run-all NCZ_HOOKS_LIST=none" "$(ran "$out")"

mkra "$R"; out=$(runra "$R" arm64 NCZ_PLATFORM=amd64)
printf '%s\n' "$out" | grep >/dev/null -F "RAN-30-x86" && ! printf '%s\n' "$out" | grep >/dev/null -F "RAN-20-sky" \
  && ok "run-all NCZ_PLATFORM overrides detection" || bad "run-all NCZ_PLATFORM override" "$(ran "$out")"

mkra "$R"; echo 99-ghost.sh >> "$R/hooks.list.amd64"; out=$(runra "$R" amd64)
printf '%s\n' "$out" | grep >/dev/null -F "WARNING: 99-ghost.sh is on" && ok "run-all warns about a listed hook missing from disk" || bad "run-all ghost warning"

mkra "$R"; rm "$R/20-sky.sh"; out=$(runra "$R" arm64)
[ "$(ran "$out")" = "RAN-10-common RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && ok "run-all never adds a hook the list names but disk lacks" || bad "run-all missing-on-disk" "$(ran "$out")"

mkra "$R"; : > "$R/hooks.list.amd64"; out=$(runra "$R" amd64)
[ "$(ran "$out")" = "RAN-10-common RAN-20-sky RAN-30-x86 RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && ok "run-all: empty list falls back to legacy (never runs zero hooks)" || bad "run-all empty list" "$(ran "$out")"
mkra "$R"; rm "$R/hooks.list.amd64"; mkdir "$R/hooks.list.amd64"; out=$(runra "$R" amd64)
[ "$(ran "$out")" = "RAN-10-common RAN-20-sky RAN-30-x86 RAN-40-mix RAN-70-bootloader RAN-99-diagnostics " ] \
  && ok "run-all: a directory named as the list falls back to legacy" || bad "run-all directory list" "$(ran "$out")"
mkfixture "$F"; printf '#!/bin/bash\n# NCZ-PLATFORM-GUARD: sky1 (comment only)\necho x\n' > "$F/post-install/20-sky.sh"
expect_fail "guard marker without the case block is rejected" "$F" "sky1 hook 20-sky.sh has no NCZ-PLATFORM-GUARD"

# ---- real tree --------------------------------------------------------------
out=$(NCZ_LINT_ROOT="$REPO" bash "$LINT" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "lint passes on this repository" || bad "lint on this repository" "$out"

echo
echo "platform-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
