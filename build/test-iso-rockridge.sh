#!/bin/bash
# test-iso-rockridge.sh -- build/forky-provenance.py reads a Rock Ridge ISO by
# its real names, and its --iso-evidence listing is the shape iso_verify()
# accepts.
#
# WHY: on the real Debian netinst the ECMA-119 directory records carry only
# truncated 8.3 identifiers (DEBIAN_I, BINARY_A, PACKAGES.GZ), so the pure-
# Python reader never matched dists/.../debian-installer/.../Packages and
# provenance-predict failed closed on a good ISO; the amd64 build had to pass
# --no-substrate, which hid three sid udebs until stage 10. --iso-evidence
# wrote a short `xorriso -ls` listing while the parser expected a long one, so
# that path could never verify either.
#
# CASES
#   R1  fixture ISO (xorriso -as mkisofs -R -J): Rock Ridge names, mixed case,
#       names past 8.3 and past 64 chars (CE continuation), a symlink
#   R2  deep tree with an rr_moved relocation (CL/RE): the relocated directory
#       shows up at its real path and rr_moved is hidden
#   R3  --iso-evidence writes the lsdl listing; iso_verify() accepts it for its
#       own ISO and refuses a tampered size, a dropped line, a dropped dir
#   R4  a plain ECMA-119 image (no Rock Ridge) still reads by its records
#   R5  the real netinst, when present (NCZ_REAL_NETINST or the ARGONAS
#       substrate dir): the d-i Packages index is found by its real path and
#       the xorriso listing verifies against the records
# Needs xorriso (R1-R3, R5). Python runs isolated (-I).
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PY="$ROOT/build/forky-provenance.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/iso-rr-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0; skip=0
ok() { printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
no() { printf '  [FAIL] %s\n' "$*" >&2; fail=$((fail+1)); }
sk() { printf '  [SKIP] %s\n' "$*"; skip=$((skip+1)); }

# py <snippet> [args...]: run against the module (fp) with FAILS visible.
py() {
    local code="$1"; shift
    FP_PATH="$PY" python3 -I - "$@" <<PYEOF
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fp", os.environ["FP_PATH"])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)
$code
PYEOF
}

if ! command -v xorriso >/dev/null 2>&1; then
    echo "test-iso-rockridge: xorriso not installed -- SKIP all"
    exit 0
fi

LONG="kernel-image-7.3.0-amd64-di_7.3.0-1+ncz1_amd64-with-a-name-well-past-sixty-four-characters.udeb"
S="$W/root"
mkdir -p "$S/dists/forky/main/debian-installer/binary-amd64" "$S/pool/main/l/linux-signed-amd64" \
         "$S/Mixed/CaseDir"
printf 'Package: x\n' > "$S/dists/forky/main/debian-installer/binary-amd64/Packages"
printf 'Package: x\n' | gzip -n > "$S/dists/forky/main/debian-installer/binary-amd64/Packages.gz"
printf 'udeb\n' > "$S/pool/main/l/linux-signed-amd64/$LONG"
printf 'm\n' > "$S/Mixed/CaseDir/ReadMe.TXT"
ln -s forky "$S/dists/testing"
xorriso -as mkisofs -quiet -o "$W/rr.iso" -R -J -joliet-long -iso-level 3 -V NCZRR "$S" >/dev/null 2>&1 \
    || { echo "FATAL: could not build the fixture ISO" >&2; exit 1; }

echo "R1 Rock Ridge names from the directory records"
out=$(py '
recs = fp.read_iso_records(open(sys.argv[1], "rb").read())
for (p, n), r in sorted(recs.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
    if n is not None:
        print("REC", (p + "/" + n) if p else n, "dir" if r["is_dir"] else ("link" if r["is_link"] else "file"), r["size"], "rr" if r["rr"] else "ecma")
' "$W/rr.iso" 2>&1)
has() { grep -qxF "$1" <<<"$out"; }
has "REC dists/forky/main/debian-installer/binary-amd64/Packages.gz file $(stat -c%s "$S/dists/forky/main/debian-installer/binary-amd64/Packages.gz") rr" \
    && ok "debian-installer/binary-amd64/Packages.gz by its real path" \
    || no "d-i Packages.gz not found by its real path: $(grep -i packages <<<"$out" | head -3)"
has "REC dists/forky/main/debian-installer/binary-amd64/Packages file 11 rr" \
    && ok "Packages (no extension) keeps its case" || no "Packages case lost"
has "REC pool/main/l/linux-signed-amd64/$LONG file 5 rr" \
    && ok "a ${#LONG}-char name (NM across a CE continuation) is whole" \
    || no "long name truncated: $(grep -i kernel-image <<<"$out")"
has "REC Mixed/CaseDir/ReadMe.TXT file 2 rr" && ok "mixed-case names are preserved" || no "mixed case lost"
has "REC dists/testing link 0 rr" && ok "dists/testing is a symlink, not a file" || no "symlink not recognised: $(grep testing <<<"$out")"
grep -q 'DEBIAN_I\|BINARY_A\|PACKAGES' <<<"$out" && no "a truncated ECMA-119 name leaked through" \
                                              || ok "no truncated 8.3 identifier is reported"

echo "R2 deep tree relocated into rr_moved (CL/RE)"
D="$W/deep"; mkdir -p "$D/a/b/c/d/e/f/g/h/i/j"; echo deep > "$D/a/b/c/d/e/f/g/h/i/j/deepfile.txt"
if xorriso -as mkisofs -quiet -o "$W/deep.iso" -R -rr_reloc_dir rr_moved "$D" >/dev/null 2>&1; then
    out=$(py '
recs = fp.read_iso_records(open(sys.argv[1], "rb").read())
paths = {(p + "/" + n) if p else n for (p, n) in recs if n is not None}
print("DEEP", "a/b/c/d/e/f/g/h/i/j/deepfile.txt" in paths)
print("MOVED", any(x.split("/")[0] in ("rr_moved", ".rr_moved") for x in paths))
' "$W/deep.iso" 2>&1)
    grep -q '^DEEP True$' <<<"$out" && ok "relocated directory found at its real path" || no "relocated dir lost: $out"
    grep -q '^MOVED False$' <<<"$out" && ok "rr_moved is hidden" || no "rr_moved shown: $out"
    xorriso -indev "$W/deep.iso" -find / -exec lsdl -- 2>/dev/null > "$W/deep.lsdl"
    out=$(py '
data = open(sys.argv[1], "rb").read()
print("VERIFY", fp.iso_verify(open(sys.argv[2]).read(), data, "t") is not None, len(fp.FAILS))
' "$W/deep.iso" "$W/deep.lsdl" 2>&1)
    grep -q '^VERIFY True 0$' <<<"$out" && ok "the relocated tree verifies against xorriso's listing" || no "deep verify: $out"
else
    sk "this xorriso cannot write -rr_reloc_dir"
fi

echo "R3 --iso-evidence listing <-> iso_verify()"
rc=0; out=$(python3 -I "$PY" --ubuntu-only --work "$W/work" --iso-evidence "$W/ev" \
    --substrate-iso "$W/rr.iso" 2>&1) || rc=$?
L="$W/ev/iso-listing.txt"
[ "$rc" = 0 ] && [ -s "$L" ] && ok "--iso-evidence wrote $(wc -l < "$L") lines (rc=0)" || no "--iso-evidence rc=$rc: $out"
head -1 "$L" | grep  '^# ncz iso-listing v2' >/dev/null && ok "listing carries the v2 header" || no "no v2 header"
grep -qF "'/dists/forky/main/debian-installer/binary-amd64/Packages.gz'" "$L" \
    && ok "listing names the full Rock Ridge path" || no "listing lacks the full path"
verify() {  # listing -> "VERIFY <bool> <fails>"
    py '
data = open(sys.argv[1], "rb").read()
print("VERIFY", fp.iso_verify(open(sys.argv[2]).read(), data, "t") is not None, len(fp.FAILS))
' "$W/rr.iso" "$1" 2>&1
}
grep -q '^VERIFY True 0$' <<<"$(verify "$L")" && ok "iso_verify accepts the ISO's own listing" || no "own listing refused: $(verify "$L")"
sed "s#^\(-[^']* \)11 \(.*Packages'\)\$#\112 \2#" "$L" > "$W/bad-size.txt"
cmp -s "$L" "$W/bad-size.txt" && no "fixture edit did not change the size" || true
grep -q '^VERIFY False' <<<"$(verify "$W/bad-size.txt")" && ok "a tampered file size is refused" || no "tampered size accepted"
grep -v "ReadMe.TXT'" "$L" > "$W/bad-drop.txt"
grep -q '^VERIFY False' <<<"$(verify "$W/bad-drop.txt")" && ok "a dropped member is refused" || no "dropped member accepted"
grep -v "/Mixed" "$L" > "$W/bad-dir.txt"
grep -q '^VERIFY False' <<<"$(verify "$W/bad-dir.txt")" && ok "a dropped directory subtree is refused" || no "dropped subtree accepted"
sed "s#'/dists/testing' -> 'forky'#'/dists/testing'#; s#^l\(r.*'/dists/testing'\)#-\1#" "$L" > "$W/bad-link.txt"
grep -q '^VERIFY False' <<<"$(verify "$W/bad-link.txt")" && ok "a symlink listed as a file is refused" || no "symlink-as-file accepted"
xorriso -indev "$W/rr.iso" -ls / > "$W/old-ls.txt" 2>/dev/null
grep -q '^VERIFY False' <<<"$(verify "$W/old-ls.txt")" && ok "the old short '-ls' listing is refused (empty)" || no "old -ls listing accepted"
cp "$L" "$W/bad-line.txt"
printf "%s\n" "-r--r--r--    1 0 0 x Oct 26 03:13 '/broken'" >> "$W/bad-line.txt"
grep -q '^VERIFY False' <<<"$(verify "$W/bad-line.txt")" && ok "an unparseable entry line fails" || no "unparseable line accepted"
out=$(py '
w, i = fp._xorriso_word(sys.argv[1], 0)
print("WORD", repr(w), i)
' "'/it'\"'\"'s q.txt' -> 'x'" 2>&1)
grep -qF "WORD \"/it's q.txt\" 17" <<<"$out" && ok "xorriso quoting of an embedded ' is undone" || no "quote parse: $out"

echo "R4 a plain ECMA-119 image (no Rock Ridge) still reads by its records"
P="$W/plain"; mkdir -p "$P/pool/main"; echo u > "$P/pool/main/a.udeb"
# xorriso -as mkisofs writes Rock Ridge even without -R; switch it off natively.
xorriso -outdev "$W/plain.iso" -rockridge off -joliet off -map "$P" / >/dev/null 2>&1
out=$(py '
recs = fp.read_iso_records(open(sys.argv[1], "rb").read())
print(sorted(((p + "/" + n) if p else n, r["rr"]) for (p, n), r in recs.items() if n))
' "$W/plain.iso" 2>&1)
grep -q "('POOL/MAIN/A.UDEB', False)" <<<"$out" && ok "ECMA-119 identifiers, rr=False: $out" || no "plain ISO: $out"

echo "R5 the real Debian netinst"
REAL="${NCZ_REAL_NETINST:-}"
if [ -z "$REAL" ]; then
    for c in /mnt/argonas/datapool/projects/ncz-os-assets/substrate/debian-testing-amd64-netinst-*.iso \
             "$HOME"/ncz-assets/debian-testing-*-netinst*.iso "$ROOT"/downloads/debian-testing-*-netinst.iso; do
        [ -f "$c" ] && REAL="$c"      # last match wins: newest, the build's own copy last
    done
fi
if [ -n "$REAL" ] && [ -f "$REAL" ]; then
    xorriso -indev "$REAL" -find / -exec lsdl -- 2>/dev/null > "$W/real.lsdl"
    out=$(py '
data = open(sys.argv[1], "rb").read()
recs = fp.read_iso_records(data)
names = {(p + "/" + n) if p else n: r for (p, n), r in recs.items() if n}
di = sorted(x for x in names if "/debian-installer/" in x and x.rsplit("/", 1)[-1].startswith("Packages"))
print("DI", len(di), di[:2])
print("TRUNC", sum(1 for x in names if "DEBIAN_I" in x))
print("UDEBS", sum(1 for x in names if x.endswith(".udeb")))
print("VERIFY", fp.iso_verify(open(sys.argv[2]).read(), data, "t") is not None, len(fp.FAILS))
' "$REAL" "$W/real.lsdl" 2>&1)
    echo "    $(basename "$REAL"): $(tr '\n' ' ' <<<"$out")"
    grep -qE '^DI [1-9]' <<<"$out" && ok "d-i Packages index found by its real path" || no "real netinst: no d-i Packages: $out"
    grep -q '^TRUNC 0$' <<<"$out" && ok "no truncated DEBIAN_I path" || no "truncated names on the real netinst"
    grep -qE '^UDEBS [1-9]' <<<"$out" && ok "pool udebs found" || no "no udebs found"
    grep -q '^VERIFY True 0$' <<<"$out" && ok "xorriso's listing of the real netinst verifies" || no "real listing refused: $out"
else
    sk "no real netinst ISO here (set NCZ_REAL_NETINST)"
fi

echo
echo "test-iso-rockridge: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
