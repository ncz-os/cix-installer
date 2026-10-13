#!/bin/bash
# test-pipefail-grep.sh -- `WRITER | grep -q PATTERN` is unsafe under `set -o pipefail`.
#
# grep -q exits at the first match. A writer that still has output to send then
# takes SIGPIPE (exit 141), and with pipefail the whole pipeline reports failure
# although the pattern matched. bash writes printf/echo output line by line into
# a pipe, so even a few kilobytes are enough: build/lint-platform.sh reported
# "hook must be on the list" for listed hooks about one run in three.
# `grep >/dev/null PATTERN` reads all of its input, so the writer always finishes.
#
#   1. a large input matched on its first line: the grep -q form fails under
#      pipefail (proves the hazard) and the grep >/dev/null form passes every run
#   2. no build/*.sh, build/lib/*.sh or tools/*.sh that sets pipefail pipes into
#      grep -q (except the files listed in KEEP, whose bytes feed pinned
#      artifacts and change only together with a re-pin)
#
# Usage: build/test-pipefail-grep.sh
# Exit 0 = all PASS, 1 = one or more FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

echo "=== 1. large input, match on the first line ==="
big=$(seq 1 200000 | sed 's/^/hook-/')
old_fail=0; new_fail=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s\n' "$big" | grep -qx 'hook-1' || old_fail=$((old_fail + 1))
    printf '%s\n' "$big" | grep >/dev/null -x 'hook-1' || new_fail=$((new_fail + 1))
done
[ "$old_fail" -gt 0 ] && ok "control: grep -q under pipefail fails on a large input ($old_fail/10 runs)" \
    || bad "control: grep -q never failed on a large input (the hazard was not reproduced)"
[ "$new_fail" = 0 ] && ok "grep >/dev/null matches the first line in 10/10 runs" \
    || bad "grep >/dev/null failed $new_fail/10 runs"
printf '%s\n' "$big" | grep >/dev/null -x 'hook-0' && bad "grep >/dev/null matched a missing line" \
    || ok "grep >/dev/null still fails when the line is missing"
listed=$(printf '%s\n' "$big" | tail -n 1)
[ "$listed" = hook-200000 ] && ok "fixture is complete" || bad "fixture: got '$listed'"

echo "=== 2. no pipe into grep -q in pipefail scripts ==="
KEEP=" build/build-kernel-debs.sh build/build-mgmt-rootfs.sh build/build-rescue-rootfs.sh \
build/build-accel-overlays.sh build/build-singularity.sh build/build-singularity-deb.sh \
build/patch-singularity-scenefx.sh build/build-ncz-apt-policy-deb.sh "
RE='\|[[:space:]]*grep([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*q'
hits=""
cd "$REPO" || exit 1
for f in build/*.sh build/lib/*.sh tools/*.sh; do
    [ -f "$f" ] || continue
    case "$KEEP" in *" $f "*) continue ;; esac
    [ "$f" = build/test-pipefail-grep.sh ] && continue   # section 1 uses the unsafe form on purpose
    grep >/dev/null -E 'set -[a-z]*o pipefail|set -o pipefail|set -euo pipefail|set -uo pipefail' "$f" || continue
    h=$(grep -nE "$RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [ -n "$h" ] && hits="$hits$(printf '%s\n' "$h" | sed "s|^|$f:|")"$'\n'
done
[ -z "$hits" ] && ok "no WRITER | grep -q in pipefail scripts" || bad "WRITER | grep -q under pipefail (use grep >/dev/null):" "$hits"

echo "test-pipefail-grep: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
