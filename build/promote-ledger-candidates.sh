#!/bin/bash
# promote-ledger-candidates.sh -- move reviewed candidate rows from a nightly
# run's ledger-candidates.tsv into the REVIEWED manifests/ncz-packages.tsv.
#
# This is OPERATOR / zoder-review gated and NEVER runs automatically: the
# nightly canary writes candidates only.  Running this by hand (with an explicit
# reviewer and NCZ_PROMOTE_OPERATOR=1) is what promotes a HEAD build's bytes into
# the reviewed ledger so release mode accepts them.
#
# Usage:
#   build/promote-ledger-candidates.sh <run-id> [--candidates FILE] \
#       [--ledger manifests/ncz-packages.tsv] [--apply --reviewer NAME]
#
#   (no --apply)  print the unified diff + a summary; change nothing.  Exit 0 if
#                 there is something to promote, 1 if nothing new / conflicts.
#   --apply       REQUIRES --reviewer NAME and NCZ_PROMOTE_OPERATOR=1.  Appends
#                 the new rows to the reviewed ledger (comments preserved) and
#                 prints the diff that was applied.  Refuses on any conflict.
#
# Candidate file resolution: --candidates, else $NCZ_NIGHTLY_ROOT/<run-id>/ledger-candidates.tsv,
# else ./nightly/<run-id>/ledger-candidates.tsv.
#
# Exit 2 usage/tooling error, 3 conflict (a reviewed row with the same identity
# but different bytes -- needs a human decision, never auto-overwritten).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

RUN_ID=""; CAND=""; LEDGER="$ROOT/manifests/ncz-packages.tsv"; APPLY=0; REVIEWER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --candidates) CAND="${2:?}"; shift 2 ;;
        --ledger) LEDGER="${2:?}"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --reviewer) REVIEWER="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        -*) echo "promote-ledger-candidates: unknown arg: $1" >&2; exit 2 ;;
        *) RUN_ID="$1"; shift ;;
    esac
done
[ -n "$RUN_ID" ] || { echo "promote-ledger-candidates: <run-id> required" >&2; exit 2; }
if [ -z "$CAND" ]; then
    for base in "${NCZ_NIGHTLY_ROOT:-}" "$ROOT/nightly"; do
        [ -n "$base" ] || continue
        if [ -f "$base/$RUN_ID/ledger-candidates.tsv" ]; then CAND="$base/$RUN_ID/ledger-candidates.tsv"; break; fi
    done
fi
[ -n "$CAND" ] && [ -f "$CAND" ] || { echo "promote-ledger-candidates: no candidates file for run '$RUN_ID' (use --candidates)" >&2; exit 2; }
[ -f "$LEDGER" ] || { echo "promote-ledger-candidates: no reviewed ledger at $LEDGER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-promote.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Build the would-be ledger (reviewed rows + new candidates) and a conflict list.
python3 -I - "$CAND" "$LEDGER" "$WORK/proposed.tsv" "$WORK/new.tsv" "$WORK/conflict.txt" <<'PYEOF'
import sys
cand, ledger, proposed, newf, conflict = sys.argv[1:6]

def rows(path):
    out = []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        out.append(line.rstrip("\n").split("\t"))
    return out

reviewed = {}
for r in rows(ledger):
    reviewed[(r[0], r[1], r[2])] = r[3]   # (name,version,arch) -> sha256

new = []
confl = []
for r in rows(cand):
    if len(r) < 10:
        confl.append(f"MALFORMED (needs 10 cols): {r}")
        continue
    name, ver, arch, sha, recipe, rev, note, shas, run_id, status = r[:10]
    if status != "candidate":
        confl.append(f"status != candidate: {name} {ver} {arch} ({status})")
        continue
    key = (name, ver, arch)
    if key in reviewed:
        if reviewed[key] == sha:
            continue                      # already reviewed byte-identically
        confl.append(f"CONFLICT {name} {ver} {arch}: reviewed {reviewed[key][:16]}.. "
                     f"vs candidate {sha[:16]}..")
        continue
    new.append((name, ver, arch, sha, recipe, rev, note))

with open(proposed, "w", encoding="utf-8") as out:
    out.write(open(ledger, encoding="utf-8").read())
    if new:
        if not open(ledger, encoding="utf-8").read().endswith("\n"):
            out.write("\n")
        for (name, ver, arch, sha, recipe, rev, note) in new:
            out.write("\t".join([name, ver, arch, sha, recipe, rev,
                                  note or f"promoted from nightly run {run_id}"]) + "\n")
with open(newf, "w", encoding="utf-8") as fh:
    fh.write(str(len(new)))
with open(conflict, "w", encoding="utf-8") as fh:
    if confl:
        fh.write("\n".join(confl) + "\n")
PYEOF
rc=$?
[ "$rc" = 0 ] || { echo "promote-ledger-candidates: analysis failed" >&2; exit 2; }

N_NEW="$(cat "$WORK/new.tsv")"
N_CONF="$(wc -l < "$WORK/conflict.txt" | tr -d ' ')"
echo "== promote-ledger-candidates: run $RUN_ID"
echo "   candidates: $CAND"
echo "   reviewed:   $LEDGER"
echo "   new rows:   $N_NEW   conflicts: $N_CONF"
if [ "$N_CONF" != 0 ]; then
    echo "   -- conflicts (resolve by hand; never auto-overwritten):" >&2
    sed 's/^/      /' "$WORK/conflict.txt" >&2
fi
echo "== proposed diff =="
diff -u "$LEDGER" "$WORK/proposed.tsv" | sed 's/^/  /' || true

if [ "$APPLY" != 1 ]; then
    echo
    echo "DRY RUN (nothing changed).  To apply after review:"
    echo "  NCZ_PROMOTE_OPERATOR=1 $0 $RUN_ID --candidates $CAND --apply --reviewer <you>"
    [ "$N_NEW" != 0 ] && [ "$N_CONF" = 0 ] && exit 0 || exit 1
fi

[ "$N_CONF" = 0 ] || { echo "promote-ledger-candidates: refusing --apply with conflicts present" >&2; exit 3; }
[ -n "$REVIEWER" ] || { echo "promote-ledger-candidates: --apply requires --reviewer NAME (zoder/operator review gate)" >&2; exit 2; }
[ "${NCZ_PROMOTE_OPERATOR:-0}" = 1 ] || { echo "promote-ledger-candidates: --apply requires NCZ_PROMOTE_OPERATOR=1 (operator-only)" >&2; exit 2; }

python3 -I - "$WORK/proposed.tsv" "$LEDGER" <<'PYEOF'
import shutil, sys
shutil.copyfile(sys.argv[1], sys.argv[2])
PYEOF
echo "== applied: $LEDGER updated (reviewer=$REVIEWER). Review + commit it by hand. =="
exit 0
