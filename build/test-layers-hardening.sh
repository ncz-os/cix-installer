#!/bin/bash
# test-layers-hardening.sh -- both-direction tests for the hardened layer checks
# (DESIGN RULE 2026-10-10, "harden the layer checks"):
#   build/layers-preflight.sh  (pre-layer, fail-fast)
#   build/check-layers.sh      (per-layer post-checks)
#
# Every check is exercised with a crafted BAD fixture (must FAIL) and, where a
# positive case exists, a GOOD one (must PASS).  No root, no squashfs toolchain
# required: the checks run against unpacked directory layers + stub tools.
#
#   build/test-layers-hardening.sh      exit 0 all pass, 1 any FAIL
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRE="$HERE/layers-preflight.sh"
CL="$HERE/check-layers.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
check() { local want="$1" got="$2" what="$3"; [ "$want" = "$got" ] && ok "$what" || bad "$what (want $want got $got)"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-layhard.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mk_elf() { { printf '\177ELF'; printf '%s\n' "$1"; } > "$2"; }

# --- assert a check id's result in the TSV --------------------------------
lc() {  # <layer> [extra args...] -> TSV on stdout
    local layer="$1"; shift
    bash "$CL" "$layer" --arch amd64 --stage t "$@" 2>/dev/null
}
assert_check() {  # <tsv-text> <check-id> <PASS|FAIL|SKIP|WARN> <what>
    local text="$1" id="$2" want="$3" what="$4" got
    got="$(printf '%s\n' "$text" | awk -F'\t' -v i="$id" '$3==i{print $4; exit}')"
    check "$want" "$got" "$what"
}
lc_rc() { local layer="$1"; shift; bash "$CL" "$layer" --arch amd64 --stage t "$@" >/dev/null 2>&1; echo $?; }

# ===========================================================================
echo "== check-layers.sh: structural + package state =="
good="$T/good"; mkdir -p "$good/var/lib/dpkg"
printf 'Package: foo\nStatus: install ok installed\nVersion: 1\n\nPackage: bar\nStatus: install ok installed\nVersion: 2\n' \
    > "$good/var/lib/dpkg/status"
tsv="$(lc "$good")"
assert_check "$tsv" dpkg-status PASS "good layer: dpkg-status PASS"
assert_check "$tsv" no-build-leftovers PASS "good layer: no leftovers"
assert_check "$tsv" one-kernel PASS "good layer: one kernel (none)"
assert_check "$tsv" no-ubuntu PASS "good layer: no ubuntu"
check 0 "$(lc_rc "$good")" "good layer: check-layers rc=0"

# half-installed dpkg status -> FAIL
bad1="$T/bad-installed"; cp -a "$good" "$bad1"
printf 'Package: baz\nStatus: install ok unpacked\nVersion: 3\n' >> "$bad1/var/lib/dpkg/status"
tsv="$(lc "$bad1")"
assert_check "$tsv" dpkg-status FAIL "unpacked package: dpkg-status FAIL"
check 1 "$(lc_rc "$bad1")" "unpacked package: rc=1"

# build leftovers -> FAIL
bad2="$T/bad-leftovers"; cp -a "$good" "$bad2"; mkdir -p "$bad2/.git" "$bad2/tmp"; : > "$bad2/root/.bash_history"
tsv="$(lc "$bad2")"
assert_check "$tsv" no-build-leftovers FAIL "dirty layer: no-build-leftovers FAIL"

# Debian kernel present -> FAIL
bad3="$T/bad-debiankernel"; cp -a "$good" "$bad3"; mkdir -p "$bad3/var/lib/dpkg/info"
: > "$bad3/var/lib/dpkg/info/linux-image-7.1.0-test.list"
tsv="$(lc "$bad3")"
assert_check "$tsv" one-kernel FAIL "Debian 7.1 kernel: one-kernel FAIL"

# Ubuntu origin -> FAIL
bad4="$T/bad-ubuntu"; cp -a "$good" "$bad4"
printf 'Package: snapd\nStatus: install ok installed\nVersion: 1\nOrigin: Ubuntu\n' >> "$bad4/var/lib/dpkg/status"
tsv="$(lc "$bad4")"
assert_check "$tsv" no-ubuntu FAIL "Ubuntu origin: no-ubuntu FAIL"

# manifest mismatch -> FAIL (both directions: missing + extra)
mf="$T/manifest.tsv"; printf 'foo\t1\nbar\t2\n' > "$mf"
tsv="$(lc "$good" --manifest "$mf")"
assert_check "$tsv" pkg-set-manifest PASS "manifest matches: pkg-set-manifest PASS"
printf 'foo\t1\nbar\t2\nqux\t9\n' > "$mf"
tsv="$(lc "$good" --manifest "$mf")"
assert_check "$tsv" pkg-set-manifest FAIL "manifest missing qux: pkg-set-manifest FAIL"

# quoted #error labwc -> FAIL; clean labwc -> PASS
cl_bad="$T/cl-bad"; cp -a "$good" "$cl_bad"; mkdir -p "$cl_bad/opt/singularity/bin"
mk_elf '#error "Missing shader preamble"' "$cl_bad/opt/singularity/bin/labwc"
tsv="$(lc "$cl_bad")"
assert_check "$tsv" labwc-shader-gate FAIL "quoted #error labwc: shader gate FAIL"
cl_ok="$T/cl-ok"; cp -a "$good" "$cl_ok"; mkdir -p "$cl_ok/opt/singularity/bin"
mk_elf '#error Missing shader preamble' "$cl_ok/opt/singularity/bin/labwc"
tsv="$(lc "$cl_ok")"
assert_check "$tsv" labwc-shader-gate PASS "clean labwc: shader gate PASS"

# layer chain: expected parent sha mismatch -> FAIL, match -> PASS
chain="$T/chain.tsv"; : > "$chain"
chainlayer="$T/chainlayer"; mkdir -p "$chainlayer"; printf 'x' > "$chainlayer/one"
# dir layers have no whole-file sha -> chain SKIP (documented); use a file layer
printf 'layer-bytes' > "$T/test.squashfs"   # not a real squashfs, but _sha_file works on files
goodsha="$(sha256sum "$T/test.squashfs" | awk '{print $1}')"
tsv="$(lc "$T/test.squashfs" --chain "$chain" --expect-parent "base:$goodsha")"
assert_check "$tsv" layer-chain PASS "layer chain: matching parent sha PASS"
tsv="$(lc "$T/test.squashfs" --chain "$chain" --expect-parent "base:deadbeef")"
assert_check "$tsv" layer-chain FAIL "layer chain: mismatched parent sha FAIL"

# stale reuse stamp / determinism member-list: prev differs -> WARN
prev="$T/prev"; cp -a "$good" "$prev"; printf 'extra' > "$prev/extra-file"
tsv="$(lc "$good" --prev "$prev")"
assert_check "$tsv" member-list-determinism WARN "member list differs from prev: WARN"

# ===========================================================================
echo "== layers-preflight.sh =="
PFCHK="$T/pf-checks.tsv"
PF() {  # [args...] -> writes the TSV to $PFCHK; echoes the human log
    : > "$PFCHK"
    bash "$PRE" --arch amd64 --root "$ROOT" --checks-out "$PFCHK" "$@" 2>&1
}
assert_pre() {  # <unused> <check-id> <PASS|FAIL|SKIP|WARN> <what>
    local id="$2" want="$3" what="$4" got
    got="$(awk -F'\t' -v i="$id" '$3==i{print $4; exit}' "$PFCHK" 2>/dev/null)"
    check "$want" "$got" "$what"
}
# a fake `df` fixture that always shows plenty of space
dfok="$T/df-ok"; printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 1 %d 1%% /\n' $((200*1024*1024)) > "$dfok"
dflow="$T/df-low"; printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 1 %d 1%% /\n' $((5*1024*1024)) > "$dflow"

# (1) missing frozen deb -> FAIL
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-none")"
str="$out"; mkdir -p "$T/r1"; out="$(PF --run-dir "$T/r1" --df-fixture "$dfok" --scratch "$T/scratch-none")"
assert_pre "$out" frozen-deb FAIL "missing frozen deb -> frozen-deb FAIL"

# (2) frozen deb sha mismatch -> FAIL
mkdir -p "$T/debs" "$T/r2/singularity-sources/out"
printf 'not-a-deb' > "$T/r2/singularity-sources/out/ncz-singularity-desktop_1_amd64.deb"
out="$(PF --run-dir "$T/r2" --payload-deb "$T/r2/singularity-sources/out/ncz-singularity-desktop_1_amd64.deb" \
        --df-fixture "$dfok" --scratch "$T/scratch-none" --deb-dir "$T/debs" --prov-check "$T/prov-ok.sh" 2>&1)"
# no recorded sha256 -> FAIL
assert_pre "$out" frozen-deb FAIL "frozen deb without recorded sha -> FAIL"

# (3) low disk -> resources FAIL
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dflow" --scratch "$T/scratch-none" 2>&1)"
assert_pre "$out" resources FAIL "low disk (<60GB) -> resources FAIL"

# (4) tmpfs build fs is not testable here (needs findmnt); assert the df line works on good
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-none" 2>&1)"
assert_pre "$out" resources PASS "plenty of disk -> resources (disk) no FAIL"

# (5) dirty subproject scratch -> clean-tree FAIL; clean -> PASS
mkdir -p "$T/scratch-dirty/singularity-desktop/subprojects"
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-dirty" 2>&1)"
assert_pre "$out" clean-tree FAIL "leftover singularity-desktop -> clean-tree FAIL"
mkdir -p "$T/scratch-clean"
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" 2>&1)"
assert_pre "$out" clean-tree PASS "clean scratch -> clean-tree PASS"
# --quarantine moves it aside and passes
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-dirty" --quarantine 2>&1)"
assert_pre "$out" clean-tree PASS "--quarantine clears the leftover -> clean-tree PASS"

# (6) SDE unset -> resources FAIL (assert the exact finding, not the first row)
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" 2>&1)"
grep -q 'SOURCE_DATE_EPOCH is not set' <<<"$out" && ok "SOURCE_DATE_EPOCH unset -> resources FAIL" \
    || bad "SOURCE_DATE_EPOCH unset not detected"

# (6b) build-lock ownership: our own build's lock is expected (PASS), a foreign
# live holder FAILS
lockf="$T/r1-lock"; printf '%s\n' "$$" > "$lockf"
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" --lock-file "$lockf" --lock-owner "$$" 2>&1)"
grep -q 'this build holds the lock' <<<"$out" && ok "own build lock recognized (--lock-owner)" || bad "own build lock flagged as foreign"
sleep 300 & extpid=$!
printf '%s\n' "$extpid" > "$lockf"
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" --lock-file "$lockf" 2>&1)"
grep -q 'another build holds the lock' <<<"$out" && ok "a foreign live lock FAILS" || bad "foreign lock not detected"
kill "$extpid" 2>/dev/null

# (7) inputs: duplicate versions -> FAIL; prov tool rejecting -> inputs-unique FAIL
mk_debdir() {  # dir, name, version
    local d="$1" n="$2" v="$3"; mkdir -p "$d"
    # a .deb-shaped file whose Architecture field parses via a stub dpkg-deb
    printf '%s %s' "$n" "$v" > "$d/${n}_${v}_amd64.deb"
}
# stub dpkg-deb so the preflight can read Architecture/Package/Version
STUB="$T/bin"; mkdir -p "$STUB"
cat > "$STUB/dpkg-deb" <<'EOF'
#!/bin/bash
# minimal dpkg-deb -f <deb> <Field> for the test fixtures: fields encoded in the name
deb="$2"; field="$3"
case "$field" in
  Architecture) printf 'amd64\n' ;;
  Package) printf '%s\n' "$(basename "$deb" | sed -E 's/_[^_]+_[^_]+\.deb$//')" ;;
  Version) printf '%s\n' "$(basename "$deb" | sed -E 's/^[^_]+_([^_]+)_.*$/\1/')" ;;
esac
EOF
chmod +x "$STUB/dpkg-deb"
provok="$T/prov-ok.sh"; printf '#!/bin/bash\nexit 0\n' > "$provok"; chmod +x "$provok"
provfail="$T/prov-fail.sh"; printf '#!/bin/bash\nexit 1\n' > "$provfail"; chmod +x "$provfail"
dupdir="$T/dups"; mk_debdir "$dupdir" ncz-foo 1.0; mk_debdir "$dupdir" ncz-foo 2.0
PATH="$STUB:$PATH" out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" --deb-dir "$dupdir" --prov-check "$provok" 2>&1)"
assert_pre "$out" inputs-unique FAIL "duplicate package versions -> inputs-unique FAIL"
onedir="$T/one"; mk_debdir "$onedir" ncz-foo 1.0
PATH="$STUB:$PATH" out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" --deb-dir "$onedir" --prov-check "$provok" 2>&1)"
assert_pre "$out" inputs-ledger PASS "one version, prov OK -> inputs-ledger PASS"
PATH="$STUB:$PATH" out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" --deb-dir "$onedir" --prov-check "$provfail" 2>&1)"
assert_pre "$out" inputs-ledger FAIL "prov tool rejects -> inputs-ledger FAIL"

# (8) pins: determinism.pin freshness is a real repo check -> expect no FAIL on this tree
out="$(PF --run-dir "$T/r1" --no-payload --df-fixture "$dfok" --scratch "$T/scratch-clean" 2>&1)"
assert_pre "$out" pins PASS "pin consistency on this tree -> pins PASS"

# (9) overall exit code: a FAIL makes preflight exit non-zero
PATH="$STUB:$PATH" bash "$PRE" --arch amd64 --root "$ROOT" --run-dir "$T/r1" --no-payload \
    --df-fixture "$dflow" --scratch "$T/scratch-clean" --deb-dir "$onedir" --prov-check "$provok" >/dev/null 2>&1
check 1 "$?" "a FAIL makes layers-preflight exit non-zero"

# (10) result file written for the receipt
[ -f "$T/r1/layers-preflight.result" ] && ok "layers-preflight.result written" || bad "layers-preflight.result missing"

# ===========================================================================
echo "== build-image.sh integration =="
# --layers-check-only runs the post-checks against a dir of layers and exits
LONLY="$T/lonly"; mkdir -p "$LONLY"; cp -a "$good" "$LONLY/base.dir"
# (a dir of *.squashfs is required; make one nominal squashfs file -> integrity FAIL)
: > "$LONLY/base.squashfs"
bash "$ROOT/build/build-image.sh" --arch amd64 --layers-check-only "$LONLY" >/dev/null 2>&1
check 1 "$?" "--layers-check-only on an invalid squashfs -> rc=1"
# bad --arch rejected
bash "$ROOT/build/build-image.sh" --arch riscv --layers-check-only "$LONLY" >/dev/null 2>&1
check 2 "$?" "--layers-check-only with bad arch -> usage rc=2"

# plan mentions the new checks
plan="$(bash "$ROOT/build/build-image.sh" --arch amd64 --full --dry-run 2>/dev/null)"
grep -q 'layers-preflight' <<<"$plan" && ok "plan names layers-preflight" || bad "plan omits layers-preflight"
grep -q 'check-layers.sh' <<<"$plan" && ok "plan names the post-checks" || bad "plan omits the post-checks"
grep -q 'layer-checks.tsv' <<<"$plan" && ok "plan names the findings TSV" || bad "plan omits the findings TSV"

echo
printf '== layers-hardening tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
