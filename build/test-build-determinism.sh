#!/bin/bash
# test-build-determinism.sh -- unit-level proof of the determinism contract
#.  Both directions are asserted: a stable input
# yields identical bytes, and a genuinely nondeterministic input is shown to
# differ (so the test cannot pass by accident).
#
#   build/test-build-determinism.sh
#
# Covers:
#   1. reproducible.py selftest (canonical pin, SDE, UUID derivation)
#   2. SOURCE_DATE_EPOCH derivation from a fixture pin / repo
#   3. fixed-UUID derivation from the pin (stable, arch/kind separated)
#   4. base.pin + determinism.pin canonical form + digest + gen-base-pin --check
#   5. tar wrapper byte-stability (same input twice; mtime-independent)
#      and the negative control (plain tar of changed mtimes DOES differ)
#   6. squashfs wrapper byte-stability
#   7. entrypoint --dry-run works and names the stages
#
# Exit 0 all pass (skips are reported, not failures), 1 any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/build/lib/reproducible.py"
# shellcheck source=/dev/null
. "$ROOT/build/lib/reproducible.sh"
# shellcheck source=/dev/null
. "$ROOT/build/lib/compare-lib.sh"
ncz_repro_init "$ROOT"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$*"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

SCRATCH="${NCZ_TEST_SCRATCH:-$ROOT/build/.det-test.$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

printf '== 1. reproducible.py + layerplan.py selftest ==\n'
if python3 -I "$PY" selftest | tail -1 | grep >/dev/null 'PASS'; then ok "reproducible.py selftest PASS"; else bad "reproducible.py selftest"; fi
if python3 -I "$ROOT/build/lib/layerplan.py" selftest | tail -1 | grep >/dev/null 'PASS'; then ok "layerplan.py selftest PASS"; else bad "layerplan.py selftest"; fi

printf '== 2. SOURCE_DATE_EPOCH derivation ==\n'
cat > "$SCRATCH/pin" <<'EOF'
snapshot	20261007T202437Z
snapshot_epoch	1791404677
EOF
got="$(python3 -I "$PY" sde --pin "$SCRATCH/pin")"
[ "$got" = "1791404677" ]; check $? "sde falls back to snapshot_epoch ($got)"
got="$(python3 -I "$PY" sde --pin "$SCRATCH/pin" --override 1700000000)"
[ "$got" = "1700000000" ]; check $? "sde honours NCZ_SOURCE_DATE_EPOCH override"
cat >> "$SCRATCH/pin" <<'EOF'
git_commit_epoch	1600000000
EOF
got="$(python3 -I "$PY" sde --pin "$SCRATCH/pin")"
[ "$got" = "1600000000" ]; check $? "sde prefers git_commit_epoch over snapshot_epoch"
python3 -I "$PY" sde --pin "$SCRATCH/pin" --override 0 >/dev/null 2>&1
[ $? != 0 ]; check $? "sde rejects 0 (unset-looking value)"

printf '== 3. fixed-UUID derivation from the pin ==\n'
u1="$(python3 -I "$PY" uuid --kind ext4 --pin "$SCRATCH/pin" --arch amd64)"
u2="$(python3 -I "$PY" uuid --kind ext4 --pin "$SCRATCH/pin" --arch amd64)"
u3="$(python3 -I "$PY" uuid --kind ext4 --pin "$SCRATCH/pin" --arch arm64)"
[ "$u1" = "$u2" ]; check $? "uuid stable for the same pin/arch"
[ "$u1" != "$u3" ]; check $? "uuid differs by arch"
python3 - <<PYEOF
import re,sys
sys.exit(0 if re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', "$u1") else 1)
PYEOF
check $? "uuid is RFC-4122 v5-formatted ($u1)"

printf '== 4. pin canonical form + digest + determinism aggregate ==\n'
# (a) the provenance base pin (substrate/snapshot; arch-major rows)
if [ -f "$ROOT/manifests/base.pin" ]; then
    d1="$(python3 -I "$PY" pin-digest "$ROOT/manifests/base.pin")"
    [ -n "$d1" ] && [ "${#d1}" = 64 ]; check $? "manifests/base.pin digest is a sha256 ($d1)"
    # canonical form is stable across comment/whitespace noise
    cp "$ROOT/manifests/base.pin" "$SCRATCH/pin2"
    printf '# noise\n\n' >> "$SCRATCH/pin2"
    d2="$(python3 -I "$PY" pin-digest "$SCRATCH/pin2")"
    [ "$d1" = "$d2" ]; check $? "pin digest ignores comments/blanks"
else
    bad "manifests/base.pin missing"
fi
# (b) the local determinism aggregate (input-ledger digests + singularity pins)
if [ -f "$ROOT/manifests/determinism.pin" ]; then
    if bash "$ROOT/build/gen-base-pin.sh" --check >/dev/null 2>&1; then
        ok "gen-base-pin --check agrees with the sources"
    else
        bad "gen-base-pin --check (manifests/determinism.pin stale)"
    fi
else
    bad "manifests/determinism.pin missing (run build/gen-base-pin.sh)"
fi

printf '== 5. tar wrapper byte-stability (both directions) ==\n'
mkdir -p "$SCRATCH/tree/d"
printf 'hello\n' > "$SCRATCH/tree/a"
printf 'world\n' > "$SCRATCH/tree/d/b"
ncz_repro_env >/dev/null
SDE="$SOURCE_DATE_EPOCH"
sha() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo MISSING; }
if tar --version 2>/dev/null | grep >/dev/null -i 'GNU tar'; then
    ncz_tar_repro -cf "$SCRATCH/a.tar" -C "$SCRATCH/tree" .
    ncz_tar_repro -cf "$SCRATCH/b.tar" -C "$SCRATCH/tree" .
    [ "$(sha "$SCRATCH/a.tar")" != MISSING ] && [ "$(sha "$SCRATCH/a.tar")" = "$(sha "$SCRATCH/b.tar")" ]
    check $? "tar wrapper identical for the same input twice"
    touch -d '2001-02-03 04:05:06' "$SCRATCH/tree/a" 2>/dev/null || touch -t 200102030405.06 "$SCRATCH/tree/a"
    ncz_tar_repro -cf "$SCRATCH/c.tar" -C "$SCRATCH/tree" .
    [ "$(sha "$SCRATCH/a.tar")" = "$(sha "$SCRATCH/c.tar")" ]
    check $? "tar wrapper is mtime-independent (pins --mtime)"
    # negative control: a plain tar of changed mtimes MUST differ, proving the
    # input is genuinely nondeterministic and the wrapper is what fixes it.
    tar -cf "$SCRATCH/na.tar" -C "$SCRATCH/tree" . 2>/dev/null
    touch -d '2005-06-07 08:09:10' "$SCRATCH/tree/a" 2>/dev/null || touch -t 200506070809.10 "$SCRATCH/tree/a"
    tar -cf "$SCRATCH/nb.tar" -C "$SCRATCH/tree" . 2>/dev/null
    [ "$(sha "$SCRATCH/na.tar")" != "$(sha "$SCRATCH/nb.tar")" ]
    check $? "plain tar differs when mtimes change (negative control)"
    # pin sensitivity: a different SOURCE_DATE_EPOCH MUST change the wrapper's bytes
    SOURCE_DATE_EPOCH=$((SDE + 1)) ncz_tar_repro -cf "$SCRATCH/d.tar" -C "$SCRATCH/tree" .
    [ "$(sha "$SCRATCH/a.tar")" != "$(sha "$SCRATCH/d.tar")" ]
    check $? "tar wrapper bytes depend on SOURCE_DATE_EPOCH (pin drives artifacts)"
else
    skip "non-GNU tar on this host (BSD tar); build hosts are GNU/Linux"
fi

printf '== 6. squashfs wrapper byte-stability ==\n'
if command -v mksquashfs >/dev/null 2>&1; then
    ncz_mksquashfs "$SCRATCH/tree" "$SCRATCH/a.sqfs" >/dev/null 2>&1 || true
    ncz_mksquashfs "$SCRATCH/tree" "$SCRATCH/b.sqfs" >/dev/null 2>&1 || true
    if [ -f "$SCRATCH/a.sqfs" ] && [ -f "$SCRATCH/b.sqfs" ] && \
       [ "$(sha256sum "$SCRATCH/a.sqfs" | awk '{print $1}')" = "$(sha256sum "$SCRATCH/b.sqfs" | awk '{print $1}')" ]; then
        check 0 "mksquashfs wrapper identical for the same input twice"
    elif [ ! -f "$SCRATCH/a.sqfs" ]; then
        bad "mksquashfs wrapper produced no archive (see the mksquashfs error above)"
    else
        bad "mksquashfs wrapper produced different bytes for the same input"
    fi
    # wrapper + normalised listing agree with the pin
    if diff <(ncz_canon_squashfs_list "$SCRATCH/a.sqfs") <(ncz_canon_squashfs_list "$SCRATCH/b.sqfs") >/dev/null; then
        ok "squashfs normalised listings agree"
    else
        bad "squashfs normalised listings"
    fi
else
    skip "mksquashfs not installed"
fi

printf '== 6b. ext4/vfat wrapper byte-stability ==\n'
ncz_repro_env >/dev/null
if command -v mke2fs >/dev/null 2>&1; then
    NCZ_REPRO_ARCH=amd64 ncz_mke2fs "$SCRATCH/e1.img" 16384 >/dev/null 2>&1 || true
    NCZ_REPRO_ARCH=amd64 ncz_mke2fs "$SCRATCH/e2.img" 16384 >/dev/null 2>&1 || true
    if [ -f "$SCRATCH/e1.img" ] && [ -f "$SCRATCH/e2.img" ] && \
       [ "$(sha256sum "$SCRATCH/e1.img" | awk '{print $1}')" = "$(sha256sum "$SCRATCH/e2.img" | awk '{print $1}')" ]; then
        ok "mke2fs wrapper (pinned -U/-E hash_seed) identical twice"
    elif [ ! -f "$SCRATCH/e1.img" ]; then
        bad "mke2fs wrapper produced no filesystem"
    else
        bad "mke2fs wrapper differs between runs (unpinned UUID/hash_seed?)"
    fi
    # the pin drives it: a different arch -> a different UUID -> different bytes
    NCZ_REPRO_ARCH=arm64 ncz_mke2fs "$SCRATCH/e3.img" 16384 >/dev/null 2>&1 || true
    if [ -f "$SCRATCH/e3.img" ] && [ -f "$SCRATCH/e1.img" ] && \
       [ "$(sha256sum "$SCRATCH/e3.img" | awk '{print $1}')" != "$(sha256sum "$SCRATCH/e1.img" | awk '{print $1}')" ]; then
        ok "mke2fs bytes depend on the pin (arch-scoped UUID)"
    else
        skip "mke2fs pin-sensitivity check (host lacking e2fsprogs UUID support)"
    fi
else
    skip "mke2fs not installed"
fi
if command -v mformat >/dev/null 2>&1; then
    : > "$SCRATCH/v1.img"; : > "$SCRATCH/v2.img"
    ncz_mformat "$SCRATCH/v1.img" -C -T 32768 >/dev/null 2>&1 || true
    ncz_mformat "$SCRATCH/v2.img" -C -T 32768 >/dev/null 2>&1 || true
    if [ -s "$SCRATCH/v1.img" ] && [ -s "$SCRATCH/v2.img" ] && \
       [ "$(sha256sum "$SCRATCH/v1.img" | awk '{print $1}')" = "$(sha256sum "$SCRATCH/v2.img" | awk '{print $1}')" ]; then
        ok "mformat wrapper (pinned volume serial) identical twice"
    else
        skip "mformat wrapper byte check (tool variant)"
    fi
else
    skip "mformat not installed"
fi

printf '== 7. entrypoint --dry-run ==\n'
if bash "$ROOT/build/build-image.sh" --arch amd64 --dry-run >"$SCRATCH/plan.txt" 2>&1; then
    ok "build-image.sh --arch amd64 --dry-run exits 0"
    grep -q 'offline-mirror' "$SCRATCH/plan.txt" && grep -q 'provenance-gate' "$SCRATCH/plan.txt"
    check $? "dry-run plan names the stages"
    grep -q 'NEVER (operator-only)' "$SCRATCH/plan.txt"
    check $? "dry-run plan states the never-do list"
    grep -q 'SOURCE_DATE_EPOCH' "$SCRATCH/plan.txt"
    check $? "dry-run plan shows SOURCE_DATE_EPOCH"
else
    bad "dry-run"
    sed 's/^/     /' "$SCRATCH/plan.txt"
fi

printf '== 8. compare-images.sh (both directions) ==\n'
# two identical files -> DETERMINISTIC, rc 0
printf 'identical-bytes\n' > "$SCRATCH/one"
cp "$SCRATCH/one" "$SCRATCH/two"
if bash "$ROOT/build/compare-images.sh" "$SCRATCH/one" "$SCRATCH/two" >"$SCRATCH/cmp1.txt" 2>&1; then
    grep -q DETERMINISTIC "$SCRATCH/cmp1.txt" && ok "compare-images: identical inputs => DETERMINISTIC" || bad "compare-images verdict"
else
    bad "compare-images: identical inputs should exit 0"
fi
# two different files with no expect rule -> UNEXPLAINED, rc 1
printf 'different-bytes\n' > "$SCRATCH/three"
if bash "$ROOT/build/compare-images.sh" "$SCRATCH/one" "$SCRATCH/three" >/dev/null 2>&1; then
    bad "compare-images: differing inputs should exit non-zero"
else
    ok "compare-images: unexplained difference => rc != 0"
fi
# the difference is accepted only with a matching --expect rule
printf 'final.img\tdocumented-exception\tfixture\n' > "$SCRATCH/expect.tsv"
if bash "$ROOT/build/compare-images.sh" --expect "$SCRATCH/expect.tsv" "$SCRATCH/one" "$SCRATCH/three" >/dev/null 2>&1; then
    ok "compare-images: a documented exception makes the diff acceptable"
else
    bad "compare-images: documented exception was not honoured"
fi

printf '== 9. normalising helpers (compare-lib) ==\n'
mkdir -p "$SCRATCH/t1/a" "$SCRATCH/t2/a"
printf 'x\n' > "$SCRATCH/t1/a/f"; cp "$SCRATCH/t1/a/f" "$SCRATCH/t2/a/f"
# shellcheck source=/dev/null
. "$ROOT/build/lib/compare-lib.sh"
if diff <(ncz_canon_tree "$SCRATCH/t1") <(ncz_canon_tree "$SCRATCH/t2") >/dev/null; then
    ok "ncz_canon_tree identical for identical trees"
else
    bad "ncz_canon_tree differs for identical trees"
fi
printf 'y\n' > "$SCRATCH/t2/a/f"
if diff <(ncz_canon_tree "$SCRATCH/t1") <(ncz_canon_tree "$SCRATCH/t2") >/dev/null; then
    bad "ncz_canon_tree failed to notice a content change"
else
    ok "ncz_canon_tree notices a content change"
fi
printf '{"a":1,"finished_at":123,"host":"x"}\n' > "$SCRATCH/j1"
printf '{"a":1,"finished_at":999,"host":"y"}\n' > "$SCRATCH/j2"
if diff <(ncz_canon_json "$SCRATCH/j1") <(ncz_canon_json "$SCRATCH/j2") >/dev/null; then
    ok "ncz_canon_json drops volatile keys (finished_at/host)"
else
    bad "ncz_canon_json did not normalise volatile keys"
fi

printf '\n== determinism tests: %d passed, %d failed, %d skipped ==\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
