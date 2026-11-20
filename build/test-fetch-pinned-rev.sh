#!/bin/bash
# test-fetch-pinned-rev.sh -- behavioural tests for build/lib/fetch-pinned-rev.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# shellcheck source=../build/lib/fetch-pinned-rev.sh
. "$HERE/lib/fetch-pinned-rev.sh"

# a fixture repo with two commits
git init -q "$T/up" && cd "$T/up"
for n in 1 2; do echo "line $n" > f.txt; git add f.txt
  git -c user.name=t -c user.email=t@t commit -qm "c$n"; done
REV2="$(git rev-parse HEAD)"; REV1="$(git rev-parse HEAD~1)"
cd "$HERE"

TREE_OK=1
ncz_fetch_pinned_rev "$T/up" "$REV1" "$T/out1" || TREE_OK=0
[ "$TREE_OK" = 1 ] && [ "$(git -C "$T/out1" rev-parse HEAD)" = "$REV1" ] && ok "fetch by full sha lands on that commit" || bad "fetch by sha did not land on it"

out="$(ncz_fetch_pinned_rev "$T/up" "" "$T/out2" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "an empty revision is refused" || bad "empty revision rc=$rc, wanted 1"
case "$out" in *"not a pin"*|*"no pinned revision"*) ok "  the refusal says why" ;; *) bad "refusal message unclear" "$out" ;; esac

out="$(ncz_fetch_pinned_rev "$T/up" "main" "$T/out3" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a branch name is refused" || bad "branch name rc=$rc, wanted 1"
case "$out" in *"is not a full lowercase 40-hex sha"*) ok "  the refusal names the rule" ;; *) bad "rule not named" "$out" ;; esac

out="$(ncz_fetch_pinned_rev "$T/up" "${REV2:0:12}" "$T/out4" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a SHORT sha is refused (ambiguity is the thing being removed)" || bad "short sha rc=$rc, wanted 1"

out="$(ncz_fetch_pinned_rev "$T/does-not-exist" "$REV2" "$T/out5" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "an unreachable repo is refused" || bad "unreachable repo rc=$rc, wanted 1"

TREE_OK=1
ncz_fetch_pinned_rev "$T/up" "$REV2" "$T/out6" || TREE_OK=0
[ "$TREE_OK" = 1 ] && [ "$(cat "$T/out6/f.txt")" = "line 2" ] && ok "the checkout carries that commit's content" || bad "checkout content wrong"

echo "=== wired into the fetcher? ==="
G="$HERE/build-gst-cix.sh"
grep -q 'lib/fetch-pinned-rev.sh' "$G" && ok "build-gst-cix.sh sources the pinning helper" || bad "gst fetcher does not source the helper"
grep -q 'ncz_fetch_pinned_rev' "$G" && ok "build-gst-cix.sh fetches by pinned revision" || bad "gst fetcher still clones a branch"
grep -q 'NCZ_GST_CIX_REV' "$HERE/../release.conf" && ok "release.conf carries the pin" || bad "no NCZ_GST_CIX_REV in release.conf"

echo "test-fetch-pinned-rev: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
