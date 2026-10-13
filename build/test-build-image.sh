#!/bin/bash
# test-build-image.sh -- unit tests for the single entrypoint's CLI, the layer
# plan/fingerprints, and the both-arch orchestration.  Companion to
# build/test-build-determinism.sh (which proves the deterministic primitives).
#
#   build/test-build-image.sh
#
# Covers the operator's flag requirements, both directions where a negative
# case exists:
#   1. argument parsing: every scope/option accepted; invalid/conflicting
#      combos rejected with exit 2 and an actionable message
#   2. dry-run plan per mode (full/respin/rebuild-*/components/only-image)
#      names the stages and the per-layer reuse decision
#   3. fingerprint invalidation: changing an input of layer L invalidates L and
#      its dependents ONLY (and switching the pin changes the derived UUIDs)
#   4. both-arch parallel orchestration with a fake stage command: one arch
#      failing does not kill the other and the combined rc is non-zero
#   5. preflight dry-run (tmpfs/privilege/substrate lines present)
#
# Exit 0 all pass, 1 any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/build-image.sh"
LP="$ROOT/build/lib/layerplan.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

SCRATCH="${NCZ_TEST_SCRATCH:-$ROOT/build/.imgtest.$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# --- 1. argument parsing ----------------------------------------------------
echo "== 1. argument parsing =="
expect_rc() { # rc expected, description, args...
    local want="$1" desc="$2"; shift 2
    bash "$BIN" "$@" >/dev/null 2>&1; local rc=$?
    if [ "$rc" = "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (want $want got $rc)"; fi
}
expect_ok()   { expect_rc 0 "$@"; }
expect_use()  { expect_rc 2 "$@"; }

expect_ok  "--help" --help
expect_use "no --arch rejected" --full --dry-run
expect_use "bad --arch rejected" --arch riscv --dry-run
expect_ok  "--full dry-run" --arch amd64 --full --dry-run
expect_ok  "--respin dry-run" --arch amd64 --respin --dry-run
expect_ok  "--quick-respin dry-run" --arch amd64 --quick-respin --dry-run
expect_ok  "--rebuild-base dry-run" --arch amd64 --rebuild-base --dry-run
expect_ok  "--rebuild-desktop dry-run" --arch amd64 --rebuild-desktop --dry-run
expect_ok  "--rebuild-hotfix dry-run" --arch amd64 --rebuild-hotfix --dry-run
expect_ok  "--only-image dry-run" --arch amd64 --only-image --dry-run
expect_ok  "--components valid" --arch amd64 --components kernel,singularity --dry-run
expect_ok  "--no-publish + gates" --arch amd64 --gates kvm --no-publish --dry-run
expect_ok  "--container override" --arch amd64 --container foo:trixie --dry-run
expect_ok  "--jobs" --arch amd64 --jobs 4 --dry-run
expect_ok  "--substrate pinned" --arch amd64 --substrate pinned --dry-run
expect_ok  "--offline" --arch amd64 --offline --dry-run
expect_use "duplicate scope rejected" --arch amd64 --full --respin --dry-run
expect_use "gates without --no-publish rejected" --arch amd64 --gates kvm --dry-run
expect_use "ui gate rejected" --arch amd64 --gates ui --no-publish --dry-run
expect_use "bad gate rejected" --arch amd64 --gates nope --no-publish --dry-run
expect_use "unknown component rejected" --arch amd64 --components frobnitz
expect_use "bad --substrate rejected" --arch amd64 --substrate sometimes
expect_use "bad --jobs rejected" --arch amd64 --jobs 0
expect_use "unknown flag rejected" --arch amd64 --frobnicate
expect_use "both + --host rejected" --arch both --host foo
expect_ok  "both dry-run" --arch both --full --dry-run

# --- 2. per-mode dry-run plan ----------------------------------------------
echo "== 2. per-mode plan =="
plan_layer() { # mode args... -> "mirror=.. base=.. desktop=.. hotfix=.."
    bash "$BIN" "$@" --dry-run 2>/dev/null \
        | awk '/layer plan/{f=1;next} f&&/fp=/{printf "%s=%s ",$1,$2} /fixed UUIDs/{f=0}'
}
for m in --full --respin --rebuild-base --rebuild-desktop --rebuild-hotfix --only-image; do
    out="$(plan_layer --arch amd64 $m)"
    [ -n "$out" ] && ok "plan '$m' produced layer decisions: $out" || bad "plan '$m' empty"
done
# only-image must be all-reuse
case "$(plan_layer --arch amd64 --only-image)" in
    *"base=reuse"*"desktop=reuse"*"hotfix=reuse"*) ok "only-image reuses every layer" ;;
    *) bad "only-image did not reuse every layer" ;;
esac
# full must be all-rebuild
case "$(plan_layer --arch amd64 --full)" in
    *"base=rebuild"*"desktop=rebuild"*"hotfix=rebuild"*) ok "full rebuilds every layer" ;;
    *) bad "full did not rebuild every layer" ;;
esac
# dry-run names the stages and the never-do list
p="$(bash "$BIN" --arch amd64 --full --dry-run 2>/dev/null)"
for s in preflight refresh-substrate stage-inputs refresh-sources offline-mirror provenance-inputs layers image provenance-gate kvm-gate receipt archive; do
    grep -q "$s" <<<"$p" && ok "plan names stage $s" || bad "plan missing stage $s"
done
grep -q 'NEVER (operator-only)' <<<"$p" && ok "plan states the never-do list" || bad "plan omits never-do list"
grep -q 'SOURCE_DATE_EPOCH' <<<"$p" && ok "plan shows SOURCE_DATE_EPOCH" || bad "plan omits SOURCE_DATE_EPOCH"
grep -q 'NCZ_REPRO_UUID_EXT4' <<<"$p" && ok "plan shows pin-derived UUIDs" || bad "plan omits UUIDs"

# --- 2b. stage ORDER (gate-order rule 2026-10-10) ----------------
echo "== 2b. stage order =="
plan_stages() { # -> "NN stage" per line, in plan order
    bash "$BIN" --arch amd64 --full --dry-run 2>/dev/null \
        | awk '/^  stages:/{f=1;next} f&&/^    \[/{print $3, $4}'
}
spos() { plan_stages | awk -v s="$1" '$2==s{print $1; exit}'; }
pi="$(spos provenance-inputs)"; lr="$(spos layers)"; om="$(spos offline-mirror)"
pg="$(spos provenance-gate)"; kg="$(spos kvm-gate)"; im="$(spos image)"
rs="$(spos refresh-sources)"
[ -n "$pi" ] && [ -n "$lr" ] && [ "$pi" -lt "$lr" ] && ok "provenance-inputs (#$pi) runs BEFORE layers (#$lr)" || bad "provenance-inputs must run before layers (pi=$pi lr=$lr)"
[ -n "$om" ] && [ -n "$pi" ] && [ "$om" -lt "$pi" ] && ok "provenance-inputs runs AFTER offline-mirror (#$om)" || bad "provenance-inputs must run after offline-mirror (om=$om pi=$pi)"
[ -n "$rs" ] && [ -n "$om" ] && [ "$rs" -lt "$om" ] && ok "refresh-sources runs before offline-mirror (it supplies the payload deb)" || bad "refresh-sources must run before offline-mirror (rs=$rs om=$om)"
[ -n "$pg" ] && [ -n "$kg" ] && [ "$pg" -lt "$kg" ] && ok "provenance-gate (#$pg) runs BEFORE kvm-gate (#$kg)" || bad "provenance-gate must run before kvm-gate (pg=$pg kg=$kg)"
[ -n "$im" ] && [ -n "$pg" ] && [ "$im" -lt "$pg" ] && ok "provenance-gate runs AFTER image (#$im)" || bad "provenance-gate must run after image (im=$im pg=$pg)"

# --- 2c. fail-fast: a failing provenance stage stops the long stage -------
# (uses the entrypoint's test-only NCZ_TEST_STAGE_CMD hook so no real stage runs)
echo "== 2c. fail-fast ordering =="
T1="$SCRATCH/ff-inputs"; T2="$SCRATCH/ff-gate"
NCZ_TEST_STAGE_CMD='case "{stage}" in provenance-inputs) echo "[fake] provenance-inputs failure"; exit 1;; *) exit 0;; esac' \
    bash "$BIN" --arch amd64 --full --no-publish --run-dir "$T1" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "a failing provenance-inputs fails the build (rc=$rc)" || bad "provenance-inputs failure was ignored"
awk -F'\t' '$2=="provenance-inputs" && $3 ~ /^FAIL/{f=1} END{exit !f}' "$T1/stages.tsv" \
    && ok "stages.tsv records provenance-inputs FAIL" || bad "stages.tsv missing provenance-inputs FAIL"
if awk -F'\t' '$2=="layers"{f=1} END{exit !f}' "$T1/stages.tsv"; then
    bad "layers ran after a failing provenance-inputs"
else
    ok "layers did NOT run after a failing provenance-inputs"
fi
NCZ_TEST_STAGE_CMD='case "{stage}" in provenance-gate) echo "[fake] provenance-gate failure"; exit 1;; *) exit 0;; esac' \
    bash "$BIN" --arch amd64 --full --no-publish --run-dir "$T2" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "a failing provenance-gate fails the build (rc=$rc)" || bad "provenance-gate failure was ignored"
if awk -F'\t' '$2=="kvm-gate"{f=1} END{exit !f}' "$T2/stages.tsv"; then
    bad "kvm-gate ran after a failing provenance-gate"
else
    ok "kvm-gate did NOT run after a failing provenance-gate"
fi

# --- 2d. refresh-sources must not delete the source-of-truth payload deb ----
# --sources pinned reuses the deb that already lives in assets/cix-debs/; the
# old stage ran `rm -f assets/cix-debs/ncz-singularity-desktop_*.deb` and then
# `install` from that removed path, so the medium silently lost its payload.
# Guard the safe shape (prune only superseded versions) and reject the old one.
if grep -qF "rm -f \"\$ROOT/assets/cix-debs/\"ncz-singularity-desktop_*.deb" "$BIN"; then
    bad "refresh-sources deletes the assets/cix-debs payload glob before install"
else
    ok "refresh-sources does not delete the source-of-truth payload deb"
fi
grep -qF "find \"\$ROOT/assets/cix-debs\" -maxdepth 1" "$BIN" \
    && grep -qF '! -name "$keep" -delete' "$BIN" \
    && ok "refresh-sources prunes only superseded payload debs" \
    || bad "refresh-sources does not prune superseded payload debs safely"
# The layer builder stages the same frozen deb; the same delete-then-copy
# anti-pattern there wiped the payload during the base layer and broke the
# hotfix layer.
SL="$ROOT/build/build-squashfs-layers.sh"
if grep -qF "rm -f \"\$ROOT/build/sinty-out/\"ncz-singularity-desktop_*.deb \"\$ROOT/assets/cix-debs/\"ncz-singularity-desktop_*.deb" "$SL"; then
    bad "build-squashfs-layers deletes the assets/cix-debs payload glob before install"
else
    ok "build-squashfs-layers does not delete the source-of-truth payload deb"
fi
grep -qF "find \"\$ROOT/assets/cix-debs\" -maxdepth 1" "$SL" \
    && grep -qF '! -name "$_keep" -delete' "$SL" \
    && ok "build-squashfs-layers prunes only superseded payload debs" \
    || bad "build-squashfs-layers does not prune payload debs safely"

# --- 2d. refresh-substrate runs under BOTH substrate policies ---------------
# With --substrate pinned the stage restores the pinned ISO into downloads/ and
# verifies the pin; if it were skipped, a fresh clone reaches the image stage
# with no substrate staged.
echo "== 2d. refresh-substrate runs for --substrate pinned and refresh =="
for pol in pinned refresh; do
    line="$(bash "$BIN" --arch amd64 --full --substrate "$pol" --dry-run 2>/dev/null | grep -E '^ +\[[a-z ]+\] +01 refresh-substrate')"
    case "$line" in
        *"[run ]"*) ok "plan runs refresh-substrate with --substrate $pol" ;;
        *) bad "plan does not run refresh-substrate with --substrate $pol: '$line'" ;;
    esac
done
T3="$SCRATCH/sub-pinned"
NCZ_TEST_STAGE_CMD='exit 0' \
    bash "$BIN" --arch amd64 --full --substrate pinned --no-publish --run-dir "$T3" >/dev/null 2>&1
awk -F'\t' '$2=="refresh-substrate" && $3 ~ /^PASS/{f=1} END{exit !f}' "$T3/stages.tsv" 2>/dev/null \
    && ok "stages.tsv records refresh-substrate PASS under --substrate pinned" \
    || bad "refresh-substrate did not run under --substrate pinned"

# --- 2e. the substrate pin check is never skipped by a file mode -----------
# build-image.sh and layers-preflight.sh run check-substrate-pin.sh with bash; a
# `[ -x ]` guard skipped it silently while the file was mode 0644.
echo "== 2e. substrate pin check is not mode-guarded =="
[ -x "$ROOT/build/check-substrate-pin.sh" ] \
    && ok "build/check-substrate-pin.sh is executable" \
    || bad "build/check-substrate-pin.sh is not executable"
for f in build/build-image.sh build/layers-preflight.sh; do
    if grep -q '\[ -x "$ROOT/build/check-substrate-pin.sh" \]' "$ROOT/$f"; then
        bad "$f skips check-substrate-pin.sh unless it is executable"
    else
        ok "$f does not gate check-substrate-pin.sh on the executable bit"
    fi
done
# every script the entrypoint guards with [ -x ] must actually be executable,
# otherwise the guarded step is skipped without a message
for f in build/build-image.sh build/layers-preflight.sh; do
    for g in $(grep -o '\[ -x "$ROOT/[^"]*" \]' "$ROOT/$f" | sed 's#.*"$ROOT/##; s#".*##' | sort -u); do
        [ -x "$ROOT/$g" ] && ok "$f: guarded $g is executable" || bad "$f: guarded $g is not executable (the step would be skipped)"
    done
done

# --- 3. fingerprint invalidation (both directions) -------------------------
echo "== 3. fingerprint invalidation =="
FIX="$SCRATCH/fix"; mkdir -p "$FIX"
mkfix() {
    mkdir -p "$FIX/post-install" "$FIX/assets/wallpaper" "$FIX/assets/singularity" \
             "$FIX/manifests" "$FIX/build/lib" "$FIX/build/iso"
    printf '#!/bin/sh\necho hi\n' > "$FIX/post-install/05-time-sync.sh"
    printf 'wall\n' > "$FIX/assets/wallpaper/w"
    printf 'samples=none\n' > "$FIX/assets/singularity/upstream-pins.tsv"
    printf 'pkg\n' > "$FIX/manifests/desktop.pkgs"
    printf 'pkg\n' > "$FIX/manifests/installer-base-amd64.pkgs"
    printf 'NCZ_BASE_CODENAME="forky"\nNCZ_BASE_MIRROR_SNAPSHOT="20261007T202437Z"\n' > "$FIX/release.conf"
    printf 'snapshot\t20261007T202437Z\nsnapshot_epoch\t1791404677\n' > "$FIX/manifests/base.pin"
}
mkfix
fp() { python3 -I "$LP" fingerprint --layer "$1" --arch amd64 --root "$FIX" --pin "$FIX/manifests/base.pin" 2>/dev/null; }
# baseline
b0=$(fp base); d0=$(fp desktop); m0=$(fp mirror); h0=$(fp hotfix)
# change a BASE input -> base + desktop + hotfix change; mirror unchanged
printf '# change\n' >> "$FIX/post-install/05-time-sync.sh"
[ "$(fp base)" != "$b0" ] && ok "base input change invalidates base" || bad "base input change did not invalidate base"
[ "$(fp desktop)" != "$d0" ] && ok "base change propagates to desktop" || bad "base change did not propagate to desktop"
[ "$(fp hotfix)" != "$h0" ] && ok "base change propagates to hotfix" || bad "base change did not propagate to hotfix"
[ "$(fp mirror)" = "$m0" ] && ok "base-only change leaves mirror unchanged" || bad "base change wrongly changed mirror"
git -C "$FIX" checkout -- . 2>/dev/null || true
# revert by regenerating fixture
mkfix
b0=$(fp base); d0=$(fp desktop); h0=$(fp hotfix); m0=$(fp mirror)
# change a DESKTOP-only input -> desktop + hotfix change; base + mirror unchanged
printf 'samples=changed\n' > "$FIX/assets/singularity/upstream-pins.tsv"
[ "$(fp desktop)" != "$d0" ] && ok "desktop input change invalidates desktop" || bad "desktop input change did not invalidate desktop"
[ "$(fp hotfix)" != "$h0" ] && ok "desktop change propagates to hotfix" || bad "desktop change did not propagate to hotfix"
[ "$(fp base)" = "$b0" ] && ok "desktop-only change leaves base unchanged" || bad "desktop change wrongly invalidated base"
[ "$(fp mirror)" = "$m0" ] && ok "desktop-only change leaves mirror unchanged" || bad "desktop change wrongly invalidated mirror"
mkfix
# change a MIRROR input -> everything changes
m0=$(fp mirror); b0=$(fp base)
printf 'extra\n' >> "$FIX/manifests/desktop.pkgs"
[ "$(fp mirror)" != "$m0" ] && ok "mirror input change invalidates mirror" || bad "mirror input change did not invalidate mirror"
[ "$(fp base)" != "$b0" ] && ok "mirror change propagates to base" || bad "mirror change did not propagate to base"
mkfix

# --- 3b. plan reuse with matching stamps on the fixture --------------------
LD="$SCRATCH/layers"; mkdir -p "$LD"
: > "$LD/base.squashfs"; : > "$LD/desktop.squashfs"; : > "$LD/desktop-hotfix.squashfs"
python3 -I "$LP" write-stamps --arch amd64 --layers-dir "$LD" --root "$FIX" --pin "$FIX/manifests/base.pin" >/dev/null
plan_decisions() { python3 -I "$LP" plan --arch amd64 --mode "$1" --layers-dir "$LD" --root "$FIX" --pin "$FIX/manifests/base.pin" "${@:2}" 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["layers"]["base"],d["layers"]["desktop"],d["layers"]["hotfix"])'; }
[ "$(plan_decisions respin)" = "reuse reuse reuse" ] && ok "respin reuses every layer when stamps match" || bad "respin did not reuse matching layers ($(plan_decisions respin))"
[ "$(plan_decisions full)" = "rebuild rebuild rebuild" ] && ok "full rebuilds despite matching stamps" || bad "full did not rebuild"
[ "$(plan_decisions rebuild-desktop)" = "reuse rebuild rebuild" ] && ok "rebuild-desktop reuses base, rebuilds desktop+hotfix" || bad "rebuild-desktop plan wrong ($(plan_decisions rebuild-desktop))"
[ "$(plan_decisions components --components screensavers)" = "reuse rebuild rebuild" ] && ok "components screensavers => desktop+hotfix" || bad "components screensavers plan wrong"
[ "$(plan_decisions components --components singularity)" = "reuse rebuild rebuild" ] && ok "components singularity => desktop+hotfix" || bad "components singularity plan wrong"
[ "$(plan_decisions components --components kernel)" = "rebuild rebuild rebuild" ] && ok "components kernel => base+dependents" || bad "components kernel plan wrong"
[ "$(plan_decisions only-image)" = "reuse reuse reuse" ] && ok "only-image reuses every layer" || bad "only-image plan wrong"
# a base input change makes respin rebuild everything, mirror included only if its inputs changed
printf '# x\n' >> "$FIX/post-install/05-time-sync.sh"
[ "$(plan_decisions respin)" = "rebuild rebuild rebuild" ] && ok "respin rebuilds after a base input change" || bad "respin did not notice base input change"

# --- 4. both-arch orchestration (fake stage command) -----------------------
echo "== 4. both-arch orchestration =="
FAKE="$SCRATCH/fake-orch.sh"
cat > "$FAKE" <<'FAKEEOF'
#!/bin/bash
arch="$1"; run_dir="$2"; log="$3"; shift 3
mkdir -p "$run_dir"
echo "fake build arch=$arch args=$*" > "$run_dir/out.txt"
echo "fake: arch=$arch OK" >> "$log"
sleep 0.2
if [ "$arch" = amd64 ] && [ -n "${NCZ_TEST_FAIL_AMD64:-}" ]; then exit 7; fi
exit 0
FAKEEOF
chmod +x "$FAKE"
BR="$SCRATCH/both-run"
NCZ_ORCH_CMD="bash \"$FAKE\" {arch} {run_dir} {log} {args}" \
NCZ_AMD64_HOST=fake64 NCZ_ARM64_HOST=fakeA \
    bash "$BIN" --arch both --full --no-publish --run-dir "$BR" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "both-arch build rc=0 when both pass" || bad "both-arch rc=$rc"
[ -f "$BR/amd64/out.txt" ] && [ -f "$BR/arm64/out.txt" ] && ok "both arches produced their run dirs" || bad "missing per-arch run dirs"
grep -q 'BOTH PASS' "$BR/SUMMARY.txt" 2>/dev/null && ok "combined summary says BOTH PASS" || bad "combined summary missing BOTH PASS"
# one arch fails: the other must still run, rc must be non-zero
rm -rf "$BR"
NCZ_TEST_FAIL_AMD64=1 \
NCZ_ORCH_CMD="bash \"$FAKE\" {arch} {run_dir} {log} {args}" \
NCZ_AMD64_HOST=fake64 NCZ_ARM64_HOST=fakeA \
    bash "$BIN" --arch both --full --no-publish --run-dir "$BR" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "both-arch rc!=0 when one arch fails (rc=$rc)" || bad "both-arch rc=0 despite a failed arch"
[ -f "$BR/arm64/out.txt" ] && ok "arm64 still completed while amd64 failed" || bad "arm64 was killed by the amd64 failure"
grep -q 'FAIL' "$BR/SUMMARY.txt" 2>/dev/null && ok "combined summary reports the failure" || bad "combined summary hid the failure"

# --- 5. preflight dry-run lines --------------------------------------------
echo "== 5. preflight dry-run =="
pf="$(bash "$BIN" --arch amd64 --full --dry-run 2>/dev/null)"
grep -q 'privilege' <<<"$pf" && ok "plan reports the privilege model" || bad "plan omits privilege model"
grep -q 'preflight' <<<"$pf" && ok "plan includes preflight" || bad "plan omits preflight"
grep -qi 'substrate' <<<"$pf" && ok "plan reports substrate policy" || bad "plan omits substrate policy"

printf '\n== build-image tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
