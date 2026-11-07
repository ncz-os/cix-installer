#!/usr/bin/env bash
# Tests for image-ci-matrix.sh: the image CI build matrix
# (desktop + server/Magnetar) x (amd64 + arm64), each cell built twice from
# clean clones and compared with compare-images.sh.
#
# Nothing here builds an image. The driver clones a FIXTURE repo whose
# build/build-image.sh is a stub that records what it was given and writes a
# medium (and, for server, a payload) the real compare-images.sh then compares.
# The properties under test are the ones that could hurt: the plan names all
# four cells and starts nothing; every build is --no-publish, on a real disk,
# under one host lock, with the variant's own KVM sets; a server build is a
# gate medium (no payload URL leaks in); the Hive busy marker is held for the
# whole chain and given back; a nondeterministic or failed cell fails the run;
# clones are removed and the artifacts kept.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
M="$HERE/image-ci-matrix.sh"
pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$M" ] || { echo "missing $M"; echo "test-image-ci-matrix: 0 passed, 1 failed"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }
command -v git >/dev/null || { echo "SKIP: no git"; exit 0; }

# Scratch on the repo's disk: /tmp is a tmpfs on the build hosts, and the
# driver (correctly) refuses to put a run there.
T="$REPO/build/.matrix-test.$$"
rm -rf "$T"; mkdir -p "$T"
LIVE=""
cleanup() {
    [ -n "$LIVE" ] && kill "$LIVE" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

HARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$HARCH" in x86_64) HARCH=amd64 ;; aarch64) HARCH=arm64 ;; esac
HUP="$(echo "$HARCH" | tr 'a-z' 'A-Z')"

# --- the fixture repo ---------------------------------------------------------
F="$T/fixture"
mkdir -p "$F/build/lib"
cp "$REPO/build/compare-images.sh" "$F/build/compare-images.sh"
cp "$REPO/build/lib/compare-lib.sh" "$F/build/lib/compare-lib.sh"
cat > "$F/build/build-image.sh" <<'STUB'
#!/bin/bash
# stub build-image.sh: record, then write a medium (+ payload for server)
set -u
all="$*"; ARCH="" RUN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in --arch) ARCH="$2"; shift 2 ;; --run-dir) RUN_DIR="$2"; shift 2 ;; *) shift ;; esac
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
side="${RUN_DIR##*-}"
mkdir -p "$RUN_DIR" "$ROOT/assets/squashfs"
mpid=""; [ -f "$NCZ_IMAGE_CI_MARKER_DIR/ncz-image-ci-matrix" ] && mpid="$(head -1 "$NCZ_IMAGE_CI_MARKER_DIR/ncz-image-ci-matrix")"
malive=no; [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null && malive=yes
{ echo "args=$all"; echo "variant=${NCZ_VARIANT:-}"; echo "lock=${NCZ_BUILD_LOCK:-}"
  echo "kvm_sets=${NCZ_KVM_GATE_VARIANTS:-}"; echo "server_sets=${NCZ_KVM_GATE_SERVER_SETS:-}"
  echo "payload_base=${NCZ_PAYLOAD_BASE_URL:-<unset>}"; echo "payload_url=${NCZ_PAYLOAD_URL:-<unset>}"
  echo "pwd=$PWD"; echo "marker_alive=$malive"; echo "tmpdir=${TMPDIR:-}"; } > "$RUN_DIR/stub.env"
echo "${NCZ_VARIANT:-}-$ARCH-$side" >> "$STUB_ORDER"
case ",${STUB_FAIL:-}," in *",${NCZ_VARIANT}-$side,"*) echo "stub: failing on purpose"; exit 1 ;; esac
noise=""; [ "${STUB_NONDET:-0}" = 1 ] && [ "$side" = b ] && noise="-$$-$RANDOM"
sha="$(git -C "$ROOT" rev-parse --short HEAD)"
printf 'base-%s%s\n' "$ARCH" "$noise" > "$ROOT/assets/squashfs/base.squashfs"
img="$ROOT/build/ncz-os-$ARCH-20261107-$sha-${NCZ_VARIANT}.img"
printf 'medium-%s-%s%s\n' "$ARCH" "$NCZ_VARIANT" "$noise" > "$img"
printf '{"variant": "%s"}\n' "$NCZ_VARIANT" > "$img.receipt.json"
printf '%s\n' "$img" > "$RUN_DIR/image.path"
if [ "$NCZ_VARIANT" = server ]; then
    mkdir -p "$RUN_DIR/payload"
    cp "$ROOT/assets/squashfs/base.squashfs" "$RUN_DIR/payload/base.squashfs"
    for n in assets pool; do
        printf '%s-%s\n' "$n" "$ARCH" > "$RUN_DIR/payload/ncz-$n-$ARCH.tar.gz"
        printf '%s  ncz-%s-%s.tar.gz\n' "$(sha256sum "$RUN_DIR/payload/ncz-$n-$ARCH.tar.gz" | cut -c1-64)" "$n" "$ARCH" \
            > "$RUN_DIR/payload/ncz-$n-$ARCH.tar.gz.sha256"
    done
fi
for g in kvm-gate provenance secret-scan; do printf 'result=PASS\n' > "$RUN_DIR/$g.result"; done
exit 0
STUB
chmod +x "$F/build/build-image.sh"
git -C "$F" init -q
git -C "$F" -c user.name=t -c user.email=t@t add -A
git -C "$F" -c user.name=t -c user.email=t@t commit -q -m fixture
FSHA="$(git -C "$F" rev-parse HEAD)"

export NCZ_IMAGE_CI_ROOT="$T/ci"
export NCZ_IMAGE_CI_MARKER_DIR="$T/markers"
export NCZ_BUILD_LOCK="$T/locks/.ncz-build.lock"
export STUB_ORDER="$T/order.log"
mkdir -p "$T/markers"

# --- 1. dry run: the whole matrix, nothing started ------------------------------
out="$(bash "$M" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry run exits 0" || nok "dry run exited $rc: $(head -3 <<<"$out")"
for cell in desktop/amd64 server/amd64 desktop/arm64 server/arm64; do
    grep -q "^cell $cell " <<<"$out" && ok "dry run plans $cell" || nok "dry run does not plan $cell"
done
[ "$(grep -c '^  build [ab]:' <<<"$out")" = 8 ] && ok "dry run: two builds (A + determinism B) per cell" \
    || nok "dry run build lines: $(grep -c '^  build [ab]:' <<<"$out"), wanted 8"
[ "$(grep -c '^  compare:' <<<"$out")" = 4 ] && ok "dry run: one compare per cell" || nok "dry run compare lines"
! grep '^  build' <<<"$out" | grep -v -- '--no-publish' | grep -q . \
    && ok "every planned build carries --no-publish" || nok "a planned build lacks --no-publish"
grep '^  build' <<<"$out" | grep -q -- '--full --sources pinned --substrate pinned' \
    && ok "planned builds use the pinned full build" || nok "planned builds are not the pinned full build"
grep -A6 '^cell server/amd64 ' <<<"$out" | grep '^  build a:' | grep -q 'NCZ_VARIANT=server' \
    && ok "server cell builds with NCZ_VARIANT=server" || nok "server cell does not set NCZ_VARIANT=server"
grep -A6 '^cell desktop/arm64 ' <<<"$out" | grep '^  build a:' | grep -q 'NCZ_VARIANT=desktop' \
    && ok "desktop cell builds with NCZ_VARIANT=desktop" || nok "desktop cell does not set NCZ_VARIANT=desktop"
grep -A6 '^cell server/arm64 ' <<<"$out" | grep '^  compare:' | grep -q -- '--payload ' \
    && ok "server compare includes the Magnetar payload" || nok "server compare omits --payload"
grep -A6 '^cell desktop/amd64 ' <<<"$out" | grep '^  compare:' | grep -q -- '--payload ' \
    && nok "desktop compare passes --payload" || ok "desktop compare has no payload"
grep -A6 '^cell server/amd64 ' <<<"$out" | grep '^  gates:' | grep -q 'server server-offline-negative' \
    && ok "server cell gates with the Magnetar KVM sets" || nok "server cell KVM sets missing"
grep -A6 '^cell desktop/amd64 ' <<<"$out" | grep '^  gates:' | grep -q 'norescue norescue-mgmt nodesktop minimal stalefs' \
    && ok "desktop cell gates with the desktop KVM sets" || nok "desktop cell KVM sets missing"
grep '^cell desktop/amd64 ' <<<"$out" | grep -q 'hosts=hydra,typhon' \
    && ok "amd64 cells run on HYDRA or TYPHON" || nok "amd64 host list: $(grep '^cell desktop/amd64 ' <<<"$out")"
grep '^cell server/arm64 ' <<<"$out" | grep -q 'hosts=ultra' \
    && ok "arm64 cells run on ULTRA" || nok "arm64 host list: $(grep '^cell server/arm64 ' <<<"$out")"
grep -q "^lock: $NCZ_BUILD_LOCK" <<<"$out" && ok "the plan names the host build lock" || nok "the plan omits the lock"
grep -q "^marker: $NCZ_IMAGE_CI_MARKER_DIR/ncz-image-ci-matrix" <<<"$out" && ok "the plan names the Hive busy marker" || nok "the plan omits the marker"
[ ! -e "$NCZ_IMAGE_CI_ROOT" ] && ok "dry run created no run root" || nok "dry run created $NCZ_IMAGE_CI_ROOT"
[ -z "$(ls -A "$T/markers")" ] && ok "dry run wrote no marker" || nok "dry run wrote a marker"

# --- 2. JSON plan and filters ---------------------------------------------------
js="$(bash "$M" --json 2>/dev/null)"
python3 -I - "$js" <<'PY' && ok "--json: 4 cells, 2 builds + a compare each, server-only payload compare" || nok "--json plan is wrong"
import json, sys
d = json.loads(sys.argv[1])
cells = {(c["variant"], c["arch"]): c for c in d["cells"]}
assert set(cells) == {(v, a) for v in ("desktop", "server") for a in ("amd64", "arm64")}, cells.keys()
for (v, a), c in cells.items():
    assert [b["side"] for b in c["builds"]] == ["a", "b"], c["builds"]
    assert c["compare"], c
    assert c["payload_compare"] == (v == "server"), c
    assert all("--no-publish" in b["command"] for b in c["builds"])
assert cells[("server", "arm64")]["hosts"] == ["ultra", "fedora"], cells[("server", "arm64")]["hosts"]
PY
n="$(bash "$M" --json --no-determinism 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(c["builds"]) for c in d["cells"]), sum(1 for c in d["cells"] if c["compare"]))')"
[ "$n" = "4 0" ] && ok "--no-determinism: one build per cell, no compare" || nok "--no-determinism plan: $n"
n="$(bash "$M" --arch arm64 2>/dev/null | grep -c '^cell ')"
[ "$n" = 2 ] && ok "--arch arm64 plans the two arm64 cells" || nok "--arch arm64 planned $n cells"
n="$(bash "$M" --variants server 2>/dev/null | grep -c '^cell server/')"
[ "$n" = 2 ] && ok "--variants server plans the two Magnetar cells" || nok "--variants server planned $n"
bash "$M" --variants desktop,bogus >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown variant is refused (exit 2)" || nok "an unknown variant was accepted"
bash "$M" --arch riscv64 >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown arch is refused (exit 2)" || nok "an unknown arch was accepted"

# --- 3. refusals: publishing, tmpfs, the wrong host ------------------------------
out="$(NCZ_IMAGE_CI_BUILD_ARGS='--full --sources pinned' bash "$M" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'refusing' <<<"$out" && ok "build args without --no-publish are refused" || nok "missing --no-publish accepted (rc=$rc)"
out="$(NCZ_IMAGE_CI_BUILD_ARGS='--full --no-publish --publish' bash "$M" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'refusing' <<<"$out" && ok "a publish hook beside --no-publish is refused" || nok "a publish hook was accepted (rc=$rc)"
if [ "$(findmnt -no FSTYPE -T /dev/shm 2>/dev/null)" = tmpfs ]; then
    out="$(NCZ_IMAGE_CI_ROOT=/dev/shm/ncz-image-ci-test-$$ bash "$M" 2>&1)"; rc=$?
    [ "$rc" = 2 ] && grep -q 'tmpfs' <<<"$out" && ok "a run root on tmpfs is refused" || nok "tmpfs root accepted (rc=$rc)"
    [ ! -e "/dev/shm/ncz-image-ci-test-$$" ] && ok "and nothing was created there" || { nok "it created /dev/shm/ncz-image-ci-test-$$"; rm -rf "/dev/shm/ncz-image-ci-test-$$"; }
else
    echo "  SKIP  no tmpfs at /dev/shm on this host"
fi
out="$(NCZ_IMAGE_CI_HOSTNAME=studio bash "$M" --foreground --repo "$F" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'not a build host' <<<"$out" && ok "a host outside the arch's list is refused" || nok "wrong host accepted (rc=$rc): $(tail -2 <<<"$out")"
out="$(NCZ_IMAGE_CI_UNAME=Darwin bash "$M" --foreground --repo "$F" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'never builds on macOS' <<<"$out" && ok "macOS (STUDIO) is refused" || nok "macOS accepted (rc=$rc)"
other=arm64; [ "$HARCH" = arm64 ] && other=amd64
out="$(env NCZ_IMAGE_CI_HOSTNAME=t1 "NCZ_IMAGE_CI_HOSTS_$(echo $other | tr a-z A-Z)=t1" bash "$M" --foreground --arch "$other" --repo "$F" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'cannot build' <<<"$out" && ok "a cross-arch cell is refused on this host" || nok "cross-arch accepted (rc=$rc)"
[ ! -s "$STUB_ORDER" ] && ok "no refusal started a build" || nok "a refusal started a build: $(cat "$STUB_ORDER")"

# --- 4. a real (stubbed) run of this host's cells ------------------------------
export NCZ_IMAGE_CI_HOSTNAME=t1
export "NCZ_IMAGE_CI_HOSTS_$HUP=t1"
# a payload URL in the caller's environment must not reach a CI server build
export NCZ_PAYLOAD_BASE_URL=https://example.invalid/release
( bash "$M" --foreground --arch "$HARCH" --repo "$F" > "$T/run1.log" 2>&1 ); rc=$?
unset NCZ_PAYLOAD_BASE_URL
[ "$rc" = 0 ] && ok "foreground run of both $HARCH cells exits 0" || nok "foreground run exited $rc: $(tail -5 "$T/run1.log")"
L1="$(ls -1d "$NCZ_IMAGE_CI_ROOT"/*/ 2>/dev/null | head -1)"; L1="${L1%/}"
[ -n "$L1" ] && [ -f "$L1/matrix.tsv" ] && ok "the run writes matrix.tsv" || nok "no matrix.tsv under $NCZ_IMAGE_CI_ROOT"
[ "$(cat "$STUB_ORDER" 2>/dev/null | tr '\n' ' ')" = "desktop-$HARCH-a desktop-$HARCH-b server-$HARCH-a server-$HARCH-b " ] \
    && ok "builds run in order: desktop A, B, then server A, B" || nok "build order: $(tr '\n' ' ' < "$STUB_ORDER")"
for v in desktop server; do
    row="$(awk -F'\t' -v v="$v" '$1==v' "$L1/matrix.tsv" 2>/dev/null)"
    grep -q "	PASS	" <<<"$row" && grep -q "	deterministic	" <<<"$row" \
        && ok "$v/$HARCH: PASS and deterministic" || nok "$v/$HARCH row: $row"
    c="$L1/$v-$HARCH"
    python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["verdict"]=="deterministic" else 1)' "$c/compare.json" 2>/dev/null \
        && ok "$v/$HARCH: compare.json says deterministic" || nok "$v/$HARCH: compare.json missing or not deterministic"
    e="$c/run-a/stub.env"
    grep -q -- "--no-publish" "$e" && grep -q -- "--run-dir $c/run-a" "$e" \
        && ok "$v/$HARCH: build A got --no-publish and its own run dir" || nok "$v/$HARCH: build A args: $(grep args= "$e")"
    grep -q "^variant=$v$" "$e" && ok "$v/$HARCH: build A ran with NCZ_VARIANT=$v" || nok "$v/$HARCH: variant $(grep variant= "$e")"
    grep -q "^lock=$NCZ_BUILD_LOCK$" "$e" && ok "$v/$HARCH: build A took the host build lock" || nok "$v/$HARCH: $(grep lock= "$e")"
    grep -q "^pwd=$c/src-a$" "$e" && ok "$v/$HARCH: build A ran in its own clean clone" || nok "$v/$HARCH: $(grep pwd= "$e")"
    grep -q "^marker_alive=yes$" "$e" && ok "$v/$HARCH: the Hive busy marker was live during the build" || nok "$v/$HARCH: no live marker during the build"
    grep -q "^tmpdir=$c/" "$e" && ok "$v/$HARCH: TMPDIR is inside the cell (not /tmp)" || nok "$v/$HARCH: $(grep tmpdir= "$e")"
    [ ! -e "$c/src-a" ] && [ ! -e "$c/src-b" ] && ok "$v/$HARCH: both clones removed after the compare" || nok "$v/$HARCH: a clone was left behind"
    ls "$c"/artifacts/ncz-os-"$HARCH"-*-"$v".img >/dev/null 2>&1 && [ -s "$c/artifacts/SHA256SUMS" ] \
        && ok "$v/$HARCH: image A kept in artifacts/ with SHA256SUMS" || nok "$v/$HARCH: artifacts missing: $(ls "$c/artifacts" 2>&1)"
done
e="$L1/server-$HARCH/run-a/stub.env"
grep -q '^server_sets=server server-offline-negative$' "$e" && ok "server build got the Magnetar KVM sets" || nok "server sets: $(grep server_sets= "$e")"
grep -q '^payload_base=<unset>$' "$e" && grep -q '^payload_url=<unset>$' "$e" \
    && ok "server build is a gate medium: the caller's payload URL was dropped" || nok "a payload URL leaked into the CI build: $(grep payload "$e")"
grep -q '^kvm_sets=norescue norescue-mgmt nodesktop minimal stalefs$' "$L1/desktop-$HARCH/run-a/stub.env" \
    && ok "desktop build got the desktop KVM sets" || nok "desktop sets: $(grep kvm_sets= "$L1/desktop-$HARCH/run-a/stub.env")"
python3 -I -c 'import json,sys; a=[x["asset"] for x in json.load(open(sys.argv[1]))["assets"]]; sys.exit(0 if "payload/ncz-pool-'"$HARCH"'.tar.gz" in a else 1)' "$L1/server-$HARCH/compare.json" 2>/dev/null \
    && ok "server compare covered the payload" || nok "server compare.json has no payload rows"
[ -d "$L1/server-$HARCH/run-a/payload" ] && [ ! -e "$L1/server-$HARCH/run-b/payload" ] \
    && ok "payload A kept, payload B removed after the compare" || nok "payload retention wrong"
[ ! -e "$T/markers/ncz-image-ci-matrix" ] && ok "the marker is released when the run ends" || nok "the marker was left behind"

# --- 5. a nondeterministic build fails the run and says where -----------------
: > "$STUB_ORDER"
( STUB_NONDET=1 bash "$M" --foreground --arch "$HARCH" --variants server --repo "$F" > "$T/run2.log" 2>&1 ); rc=$?
[ "$rc" = 1 ] && ok "a nondeterministic cell fails the run (exit 1)" || nok "nondeterministic run exited $rc"
grep -q "server/$HARCH.*NONDETERMINISTIC" "$T/run2.log" && ok "the summary names the nondeterministic cell" || nok "summary: $(tail -3 "$T/run2.log")"

# --- 6. a failed build stops its cell, not the others ---------------------------
: > "$STUB_ORDER"
( STUB_FAIL=server-a bash "$M" --foreground --arch "$HARCH" --repo "$F" > "$T/run3.log" 2>&1 ); rc=$?
[ "$rc" = 1 ] && ok "a failed build fails the run (exit 1)" || nok "failed-build run exited $rc"
grep -q "server-$HARCH-b" "$STUB_ORDER" && nok "build B ran after build A failed" || ok "build B is not started after build A fails"
grep -q "desktop-$HARCH-b" "$STUB_ORDER" && ok "the desktop cell still ran in full" || nok "the desktop cell was skipped"
grep -q "server/$HARCH.*FAIL.*build-a" "$T/run3.log" && ok "the summary names the failed build" || nok "summary: $(tail -3 "$T/run3.log")"

# --- 7. one matrix per host: a live marker blocks, a stale one is cleared ------
: > "$STUB_ORDER"
sleep 60 & LIVE=$!
printf '%s\n' "$LIVE" > "$T/markers/ncz-image-ci-matrix"
out="$(bash "$M" --foreground --arch "$HARCH" --repo "$F" 2>&1)"; rc=$?
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; LIVE=""
[ "$rc" = 3 ] && grep -q 'already running' <<<"$out" && ok "a live matrix marker blocks a second run (exit 3)" || nok "second run with a live marker: rc=$rc"
[ ! -s "$STUB_ORDER" ] && ok "and nothing was built" || nok "a build started despite the live marker"
printf '999999\n' > "$T/markers/ncz-image-ci-matrix"
out="$(bash "$M" --foreground --arch "$HARCH" --variants desktop --no-determinism --repo "$F" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'clearing a stale marker' <<<"$out" && ok "a stale marker is cleared and named" || nok "stale marker: rc=$rc $(head -3 <<<"$out")"
[ "$(cat "$STUB_ORDER")" = "desktop-$HARCH-a" ] && ok "--no-determinism builds A only" || nok "--no-determinism built: $(tr '\n' ' ' < "$STUB_ORDER")"

# --- 8. --execute detaches, holds the marker, and gives it back ----------------
: > "$STUB_ORDER"
( bash "$M" --execute --arch "$HARCH" --variants desktop --no-determinism --repo "$F" > "$T/exec.log" 2>&1 ); rc=$?
[ "$rc" = 0 ] && grep -q 'started pid=' "$T/exec.log" && ok "--execute launches and returns" || nok "--execute: rc=$rc $(cat "$T/exec.log")"
for _ in $(seq 1 60); do [ -e "$T/markers/ncz-image-ci-matrix" ] || break; sleep 0.5; done
[ ! -e "$T/markers/ncz-image-ci-matrix" ] && ok "the detached run finished and released the marker" || nok "the detached run still holds the marker"
[ "$(cat "$STUB_ORDER")" = "desktop-$HARCH-a" ] && ok "the detached run built its cell" || nok "detached run built: $(cat "$STUB_ORDER")"
grep -q 'set -C; printf' "$M" && ok "the marker is reserved with O_EXCL semantics and a pid" || nok "marker reservation is racy"
grep -q 'BASHPID" > "$MARKER"' "$M" && ok "the detached child records its own pid" || nok "the parent records the pid (crash window)"

# --- 9. candidate status: the 2x2 grid ------------------------------------------
# A release candidate is complete only when all four media (desktop + server on
# amd64 + arm64) are built, gated, deterministic and provenance-recorded. The
# arch halves run on different hosts, so --status reads every launch dir given.
st="$(bash "$M" --status --repo "$F" --from "$L1" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "status: two of four cells => candidate incomplete (exit 1)" || nok "status rc=$rc: $st"
grep -q "^desktop .*deterministic" <<<"$st" && grep -q "^server .*deterministic" <<<"$st" \
    && ok "status: the $HARCH cells read deterministic" || nok "status grid: $st"
grep -q "not built" <<<"$st" && ok "status: the other arch reads 'not built'" || nok "status grid lacks 'not built': $st"
grep -q "^candidate ${FSHA:0:12}: INCOMPLETE" <<<"$st" && ok "status: the verdict names the candidate and says INCOMPLETE" || nok "verdict: $(grep candidate <<<"$st")"
# the other arch's half, as a launch dir copied back from its build host
L2="$T/other-host/$(basename "$L1")"; mkdir -p "$L2"
for v in desktop server; do cp -a "$L1/$v-$HARCH" "$L2/$v-$other"; done
sed "s/	$HARCH	/	$other	/" "$L1/matrix.tsv" | sed "s#$L1/\([a-z]*\)-$HARCH#$L2/\1-$other#" > "$L2/matrix.tsv"
st="$(bash "$M" --status --repo "$F" --from "$L1" --from "$L2" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q "^candidate ${FSHA:0:12}: COMPLETE" <<<"$st" \
    && ok "status: all four deterministic and provenance-recorded => COMPLETE (exit 0)" || nok "status rc=$rc: $st"
rm -f "$L2/server-$other/run-a/provenance.result"
st="$(bash "$M" --status --repo "$F" --from "$L1" --from "$L2" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "^server .*built" <<<"$st" && ! grep -q "^server .*deterministic.*deterministic" <<<"$st" \
    && ok "status: a cell without a provenance PASS is only 'built', candidate incomplete" || nok "status rc=$rc: $st"
printf 'dest=STUDIO:~/Projects/ncz-images\n' > "$L1/desktop-$HARCH/shipped"
st="$(bash "$M" --status --repo "$F" --from "$L1" --from "$L2" --json 2>&1)"
python3 -I - "$st" "$HARCH" "$other" <<'PYX' && ok "status --json: per-cell state incl. shipped, complete=false" || nok "status --json: $st"
import json, sys
d = json.loads(sys.argv[1]); h, o = sys.argv[2], sys.argv[3]
g = {(c["variant"], c["arch"]): c["state"] for c in d["cells"]}
assert g[("desktop", h)] == "shipped", g
assert g[("server", h)] == "deterministic", g
assert g[("server", o)] == "built", g
assert d["complete"] is False and len(d["cells"]) == 4
PYX

echo "test-image-ci-matrix: $pass passed, $fail failed"
[ "$fail" = 0 ]
