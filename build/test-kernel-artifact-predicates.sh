#!/usr/bin/env bash
# test-kernel-artifact-predicates.sh -- the one-kernel name predicate must be the
# same in all three places that implement it.
#
# WHY. The "is this a Debian kernel/module artifact" question is answered by three
# separate regexes:
#
#   build/iso/write-usb-image.py      KERNEL_ARTIFACT_NAME_RE  -- DELETES the file
#                                       from the copied /cdrom pool when
#                                       NCZ_ONE_KERNEL=1
#   build/forky-provenance.py         KERNEL_ARTIFACT_RE       -- EXEMPTS it from
#                                       provenance (docs/ONE-KERNEL.md)
#   build/classify-sid-exceptions.py  KERNEL_ARTIFACT_RE       -- reports class K
#
# The dangerous direction is a file the GATE exempts while the WRITER keeps: it
# stays on the medium with no provenance check.  That was real -- the writer used
# ".+-modules-.+-di$" and the other two "(^.+-(modules|binary)-.*-di$)", which
# disagree on a version-less name ("foo-modules--di"): exempted, but not deleted.
# Measured, cycle 487.
#
# This suite fails if the three source texts differ, or if they classify any name in
# the corpus below differently -- so a future edit to one of them cannot drift.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }
for f in build/iso/write-usb-image.py build/forky-provenance.py build/classify-sid-exceptions.py; do
    [ -s "$ROOT/$f" ] || { echo "missing $ROOT/$f"; exit 1; }
done

python3 - "$ROOT" <<'PY' > /tmp/kap.$$ 2>&1
import re, sys
root = sys.argv[1]
files = {
    "write-usb-image.py": "build/iso/write-usb-image.py",
    "forky-provenance.py": "build/forky-provenance.py",
    "classify-sid-exceptions.py": "build/classify-sid-exceptions.py",
}
pats = {}
for label, rel in files.items():
    src = open(f"{root}/{rel}", encoding="utf-8").read()
    m = re.search(r"KERNEL_ARTIFACT[A-Z_]*\s*=\s*re\.compile\(\s*(.*?)\)\s*\n", src, re.S)
    if not m:
        print(f"FAIL {label} has no KERNEL_ARTIFACT* re.compile()")
        continue
    pats[label] = "".join(re.findall(r'r?"([^"]*)"', m.group(1)))

if len(pats) < 3:
    sys.exit(0)

vals = set(pats.values())
if len(vals) == 1:
    print("PASS all three kernel-artifact regexes are byte-identical")
else:
    print("FAIL the three kernel-artifact regexes differ:")
    for k, v in pats.items():
        print(f"        {k:28} {v}")

comp = {k: re.compile(v) for k, v in pats.items()}
# Real Debian shapes, the degenerate shape that caused the drift, NCZ names that
# must NOT match, and packages that must never be treated as kernel artifacts.
corpus = [
    "base-modules-7.2.15+deb14-amd64-di",
    "core-modules-2.6-di",
    "foo-binary-1-amd64-di",
    "foo-modules-1.2-amd64-di",
    "foo-modules--di",
    "linux-base-something",
    "linux-headers-6.1.0-1-amd64",
    "linux-image-7.1.13+deb14-amd64",
    "kernel-image-6.1",
    "ncz-cixmini-kernel-modules-1.0",
    "ncz-linux-image-arm64",
    "libpcre2-8-0-udeb",
    "wpasupplicant-udeb",
    "bash",
]
disagreements = []
for n in corpus:
    verdicts = {k: bool(c.search(n)) for k, c in comp.items()}
    if len(set(verdicts.values())) > 1:
        disagreements.append((n, verdicts))
if disagreements:
    print("FAIL the three predicates disagree on:", len(disagreements), "name(s)")
    for n, v in disagreements:
        detail = ", ".join(f"{k}={'match' if b else 'no'}" for k, b in v.items())
        print(f"        {n}: {detail}")
else:
    print(f"PASS all three agree on every one of the {len(corpus)} corpus names")

# and the property that matters: nothing the gate exempts may be kept by the writer
gate = comp["forky-provenance.py"]; writer = comp["write-usb-image.py"]
leaks = [n for n in corpus if gate.search(n) and not writer.search(n)]
if leaks:
    print("FAIL the gate exempts a name the writer does not delete:", ", ".join(leaks))
else:
    print("PASS nothing the gate exempts survives the writer's filter")
PY
rc=$?
while IFS= read -r line; do
    case "$line" in
        PASS*) ok "${line#PASS }" ;;
        FAIL*) bad "${line#FAIL }" ;;
        "        "*) echo "$line" ;;
    esac
done < /tmp/kap.$$
rm -f /tmp/kap.$$
[ "$rc" = 0 ] || bad "the predicate comparison itself failed (rc=$rc)"

echo "test-kernel-artifact-predicates: $pass passed, $fail failed"
[ "$fail" = 0 ]
