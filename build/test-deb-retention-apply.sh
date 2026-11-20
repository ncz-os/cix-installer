#!/usr/bin/env bash
# test-deb-retention-apply.sh -- the deleting path of the n-2 retention tool.
#
# dry run is the default and was tested; --apply is the part that can destroy the
# last known good. Those properties are asserted here against a fixture pool:
#   * --apply without --yes-really refuses and deletes nothing;
#   * --apply --yes-really deletes EXACTLY the planned set, keeps the newest of
#     every series, and never touches a name outside the kernel/singularity scope;
#   * --apply against an apt index URL refuses (only a local pool can be pruned);
#   * a dry run deletes nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TOOL="$REPO/build/deb-retention.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

[ -s "$TOOL" ] || { echo "missing $TOOL"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-retention.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

mkpool() {  # mkpool <dir>: four kernel releases, 2 builds each, plus out-of-scope and singularity
    local d="$1"; rm -rf "$d"; mkdir -p "$d"
    local v b
    for v in 7.2.0 7.3.0 7.3.1 7.4.0; do
        for b in 1 2; do : > "$d/linux-image-${v}-t2-ncz_${v}-${b}_amd64.deb"; done
    done
    : > "$d/ncz-singularity-desktop_20261025175504+bk0+tgza_amd64.deb"
    : > "$d/ncz-singularity-desktop_20261105105000+bk0+tgzb_amd64.deb"
    : > "$d/bash_5.2-1_amd64.deb"          # out of scope: must never be considered
}

count() { find "$1" -name '*.deb' | wc -l | tr -d ' '; }

# 1. dry run deletes nothing
mkpool "$T/p1"; before=$(count "$T/p1")
python3 "$TOOL" --dir "$T/p1" >/dev/null 2>&1
[ "$(count "$T/p1")" = "$before" ] && ok "a dry run deletes nothing" || bad "a dry run deleted files"

# 2. --apply without --yes-really refuses (exit 2) and deletes nothing
out="$(python3 "$TOOL" --dir "$T/p1" --apply 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "--apply without --yes-really exits 2" || bad "--apply without --yes-really exited $rc"
[ "$(count "$T/p1")" = "$before" ] && ok "the refused --apply deleted nothing" || bad "the refused --apply deleted files"
printf '%s' "$(echo "$out")" | grep -q 'nothing deleted' && ok "the refusal says nothing was deleted" || bad "the refusal is unclear" "$out"

# 3. --apply --yes-really deletes exactly the plan
mkpool "$T/p2"
plan="$(python3 "$TOOL" --dir "$T/p2" --json 2>/dev/null)"
want="$(printf '%s' "$plan" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(r["filename"].split("/")[-1] for r in d["would_remove"])))')"
python3 "$TOOL" --dir "$T/p2" --apply --yes-really >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "--apply --yes-really exits 0" || bad "--apply --yes-really exited $rc"
gone="$(cd "$T/p2" && ls -1 *.deb 2>/dev/null | sort | tr '\n' ' ')"
kept="$gone"
missing=""
for f in $want; do case " $kept " in *" $f "*) missing="$missing $f";; esac; done
[ -z "$missing" ] && ok "every planned removal is gone" || bad "planned removals survived" "$missing"
for f in linux-image-7.4.0-t2-ncz_7.4.0-2_amd64.deb linux-image-7.3.1-t2-ncz_7.3.1-2_amd64.deb linux-image-7.3.0-t2-ncz_7.3.0-2_amd64.deb; do
    [ -e "$T/p2/$f" ] && ok "the newest build of a kept release survives ($f)" || bad "a kept build was deleted ($f)"
done
[ -e "$T/p2/bash_5.2-1_amd64.deb" ] && ok "an out-of-scope package is untouched" || bad "an out-of-scope package was deleted"
[ "$(count "$T/p2")" = "6" ] && ok "exactly the surviving set remains (3 kernel builds + 2 singularity + 1 out-of-scope)" \
    || bad "unexpected survivor count: $(count "$T/p2")"

# 4. --apply against an index URL refuses: only a local pool can be pruned
mkpool "$T/p3"; before3=$(count "$T/p3")
out="$(python3 "$TOOL" --packages "$T/p3/linux-image-7.2.0-t2-ncz_7.2.0-1_amd64.deb" --apply --yes-really 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "pruning is refused for a non-directory source (exit 2)" || bad "pruning a file-as-index exited $rc"
[ "$(count "$T/p3")" = "$before3" ] && ok "the refused URL/file prune deleted nothing" || bad "the refused prune deleted files"

echo "test-deb-retention-apply: $pass passed, $fail failed"
[ "$fail" = 0 ]
