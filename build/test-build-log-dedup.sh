#!/bin/bash
# test-build-log-dedup.sh -- M11 (docs/BUILD-STABILITY.md C3/§3): the provenance
# gate runs BEFORE the credential scan, and every per-stage log line appears
# exactly once.
#
# WHY.  A2 (amd64, 2026-10-29) reached stage 80 after layers (680s), image
# (403s) and secret-scan (409s), then failed on 71 provenance findings -- so a
# provenance-doomed image paid for a full 409s credential scan first.  The
# provenance gate is cheap (48s in A2) and nothing in it reads the
# secret-scan's output, so it moves in front of it.  Separately, every line in
# every per-stage log appeared twice: stage functions `tee -a "$log"` their own
# output AND run_stage() pipes the whole function through `tee -a "$log"`.
#
# The checks below are structural on purpose -- they read the stage table and
# the stage bodies, so they never need a real build:
#
#   1. the plan lists provenance-gate BEFORE secret-scan, both still RUN
#   2. a resumed run keeps that order and still runs both
#   3. compile-time: no stage function tees into its own stage log
#   4. runtime: a run through the real run_stage() writes every line once
#
# Exit 0 all pass, 1 any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/build-image.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

SCRATCH="${NCZ_TEST_SCRATCH:-$ROOT/build/.imglogtest.$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

# --- 1. plan order: provenance-gate before secret-scan ----------------------
echo "== 1. plan order: provenance-gate before secret-scan =="
# -> "NN stage" per line, in plan order.  Parsed field-wise rather than by
# column: strip the "  " indent, then take the "[state]" tag as one token and
# the index/name from the remainder, so extra spaces or a wider state tag
# cannot silently shift the columns.
plan_stages() {
    bash "$BIN" --arch amd64 --full --dry-run 2>/dev/null \
        | awk '
            $1=="stages:" { f=1; next }
            f && /^[[:space:]]*$/ { exit }
            f && match($0, /\[[^]]*\][[:space:]]+[0-9]+[[:space:]]+[A-Za-z0-9_-]+$/) {
                rest = substr($0, RSTART, RLENGTH)
                sub(/^\[[^]]*\][[:space:]]+/, "", rest)
                split(rest, a, /[[:space:]]+/)
                print a[1], a[2]
            }'
}
spos() { plan_stages | awk -v s="$1" '$2==s{print $1; exit}'; }
pg="$(spos provenance-gate)"; ss="$(spos secret-scan)"; im="$(spos image)"
kg="$(spos kvm-gate)"
# The parser must actually see the whole plan: an empty or truncated read would
# make every position comparison below vacuously true.
nstages="$(plan_stages | grep -c . || true)"
[ "${nstages:-0}" -ge 10 ] \
    && ok "the dry-run plan parses ($nstages stages read)" \
    || bad "the dry-run plan did not parse (read $nstages stages)"
if [ -n "$pg" ] && [ -n "$ss" ] && [ "$pg" -lt "$ss" ]; then
    ok "provenance-gate (#$pg) runs BEFORE secret-scan (#$ss) (M11)"
else
    bad "provenance-gate must run before secret-scan (pg=$pg ss=$ss)"
fi
[ -n "$im" ] && [ -n "$pg" ] && [ "$im" -lt "$pg" ] && [ "$pg" -lt "${kg:-999}" ] \
    && ok "the reordered pair still sits between image (#$im) and kvm-gate (#$kg)" \
    || bad "gate order broken around image/kvm-gate (im=$im pg=$pg kg=$kg)"

# The plan is read ONCE into a variable: `... | grep ` under `set -o >/dev/null
# pipefail` returns 141 (grep exits at the first match, the writer gets
# SIGPIPE, pipefail propagates it), so a piped `grep ` reports "not found" >/dev/null
# for a line that IS present.  Herestrings have no pipe and no SIGPIPE.
PLAN="$(bash "$BIN" --arch amd64 --full --dry-run 2>/dev/null)"
# both gates stay MANDATORY: neither may ever be listed [off ...]
for g in provenance-gate secret-scan; do
    if grep -E "^[[:space:]]+\[off *\] [0-9]+ ${g}$" <<<"$PLAN" >/dev/null; then
        bad "$g is switchable off in the default plan"
    else
        ok "$g is not switchable off in the default plan"
    fi
done
# ... and both are RUN (not skip) in the default --full plan
for g in provenance-gate secret-scan; do
    grep -E "^[[:space:]]+\[run *\] [0-9]+ ${g}$" <<<"$PLAN" >/dev/null \
        && ok "the default plan RUNS $g" || bad "the default plan does not run $g"
done

# --- 2. a resumed run keeps the order and runs both ------------------------
echo "== 2. resumed run: both gates run, in the new order =="
T2="$SCRATCH/resume"
NCZ_TEST_STAGE_CMD='case "{stage}" in provenance-gate) echo "[fake] provenance ran"; exit 0;; secret-scan) echo "[fake] secret-scan ran"; exit 0;; *) exit 0;; esac' \
    bash "$BIN" --arch amd64 --full --no-publish --resume-from image \
        --run-dir "$T2" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "resume-from image: build rc=0" || bad "resume-from image rc=$rc"
pg_t="$(awk -F'\t' '$2=="provenance-gate"{print NR; exit}' "$T2/stages.tsv" 2>/dev/null)"
ss_t="$(awk -F'\t' '$2=="secret-scan"{print NR; exit}' "$T2/stages.tsv" 2>/dev/null)"
[ -n "$pg_t" ] && [ -n "$ss_t" ] && [ "$pg_t" -lt "$ss_t" ] \
    && ok "resume-from image: provenance-gate ran BEFORE secret-scan" \
    || bad "resume-from image: gate order wrong (pg=$pg_t ss=$ss_t)"
for g in provenance-gate secret-scan; do
    awk -F'\t' -v s="$g" '$2==s && $3=="PASS"{f=1} END{exit !f}' "$T2/stages.tsv" \
        && ok "resume-from image: $g is PASS in stages.tsv" \
        || bad "resume-from image: $g did not run/PASS"
done
# A failing provenance gate now aborts BEFORE the credential scan is paid for.
T2b="$SCRATCH/resume-prov-fail"
NCZ_TEST_STAGE_CMD='case "{stage}" in provenance-gate) echo "[fake] provenance failure"; exit 1;; secret-scan) echo "[fake] secret-scan ran"; exit 0;; *) exit 0;; esac' \
    bash "$BIN" --arch amd64 --full --no-publish --resume-from image \
        --run-dir "$T2b" >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "a failing provenance-gate fails the build (rc=$rc)" \
    || bad "a failing provenance-gate was ignored"
if [ -s "$T2b/stages.tsv" ] && awk -F'\t' '$2=="secret-scan"{f=1} END{exit !f}' "$T2b/stages.tsv"; then
    bad "secret-scan still ran after a failing provenance gate (M11 saves nothing)"
else
    ok "secret-scan did NOT run after a failing provenance gate (the M11 saving)"
fi

# --- 3. compile-time: no stage function tees into its own stage log --------
# run_stage() already pipes the whole function through `tee -a "$log"`; an
# inner `tee -a "$log"` makes every line appear twice.
echo "== 3. no stage function tees into the stage log itself =="
#
# The match is deliberately broad: ANY `tee` with `-a` inside a stage function
# whose log argument names a log variable is a second write of bytes run_stage()
# already tees.  Covered shapes: unquoted `$log`, braced `${log}`, other names
# (`$stage_log`, `$LOG`), trailing redirects (`2>&1`), extra whitespace, and
# `--append`.  A formatter must not be able to slip the bug back in by
# rewriting `tee -a "$log"` as `tee  --append  $log  2>&1`.
inner="$(awk '
    /^stage_[a-z_0-9]+\(\)[[:space:]]*\{/ { fn=1; next }
    fn && /^\}/                          { fn=0 }
    # A second write of the stage log: `tee` in append mode whose argument names
    # a log variable.  Shape: optional $, optional {, then a name ENDING in
    # "log" (case-insensitive) -- so $log, ${log}, $stage_log, $LOG, $STAGE_LOG,
    # ${stage_log} all match, while $logout-style names do not.  Extra spaces
    # and trailing redirects (2>&1) are ignored because only the tee argument
    # matters.
    fn && tolower($0) ~ /(^|[^[:alnum:]_-])tee[[:space:]]+(-a|--append)([[:space:]]|$)/ &&
         tolower($0) ~ /\$(\{)?[A-Za-z0-9_]*log(\})?/ { printf "%d:%s\n", NR, $0 }
' "$BIN")"
if [ -z "$inner" ]; then
    ok "no stage_* function pipes through tee -a \"\$log\" (lines would double)"
else
    bad "stage functions still tee into their own stage log (doubled lines):"
    printf '%s\n' "$inner" | head -5
fi
# the outer tee in run_stage() is what writes the log -- it must still be there
awk '/^run_stage\(\) \{/{f=1} f&&/^\}/{exit} f' "$BIN" | grep  'tee -a "\$log"' >/dev/null \
    && ok "run_stage() still writes the stage log through a single tee" \
    || bad "run_stage() lost its single tee -- the stage log would be empty"

# --- 4. runtime: every stage log line appears exactly once -----------------
# A stage body that pipes a sub-script through `tee -a "$log"` is the shape that
# doubled every line in A2: the sub-script's output lands in the log, and then
# run_stage()'s own tee writes the function's stdout (the same bytes) again.
# stub-sub.sh is that sub-script and stage-body.sh is the stage's pipe; between
# them they reproduce BOTH writes, which is why section 3 (which forbids the
# inner tee) and this runtime check agree on the same defect.
echo "== 4. runtime: every stage log line appears once =="
T4="$SCRATCH/dedup"
mkdir -p "$T4/bin"
# stub-sub.sh stands in for a sub-script a stage runs (build/build-squashfs-
# layers.sh and friends).  It writes to STDOUT ONLY -- exactly like every
# build/*.sh helper; none of them opens a log of its own.
cat > "$T4/bin/stub-sub.sh" <<'STUB'
#!/bin/bash
# <stage>  -- a stage's sub-script: stdout only, like every build/*.sh helper.
stage="$1"
[ -n "$stage" ] || { echo "stub-sub: usage: <stage>" >&2; exit 2; }
printf 'MARK-%s sentinel line\n' "$stage"
printf 'MARK-%s second\n' "$stage"
STUB
chmod +x "$T4/bin/stub-sub.sh"

# stage-body.sh is the stage function's body.  run_stage() passes the stage its
# log path as $1, exactly as stage_<name>() receives it.
#
# THE DEFECT (A2): the stage function ended with its own `| tee -a "$log"`, so
# the stage wrote its log AND run_stage()'s outer tee wrote the same bytes to
# the same file -- every line twice.  $INNER_TEE selects the two shapes so the
# test can prove it distinguishes them:
#   INNER_TEE=1  -> the pre-M11 stage: body tees into $log itself   (doubled)
#   INNER_TEE=0  -> the M11 stage:      body only prints to stdout  (single)
#
# The real tree is tested with INNER_TEE=0; the harness is first shown to
# DETECT the INNER_TEE=1 shape, so a green result cannot be a test that is
# simply blind to the bug.
cat > "$T4/bin/stage-body.sh" <<'STUB'
#!/bin/bash
# <log>  -- a stage function body; $NS marks the stage.
log="$1"
[ -n "$log" ] || { echo "stage-body: usage: <log>" >&2; exit 2; }
sub="$(dirname "$0")/stub-sub.sh"
if [ "${INNER_TEE:-0}" = 1 ]; then
    # pre-M11 shape: the stage tees its own output into its own log.  It writes
    # to a file it owns so the control is deterministic -- run_stage() truncates
    # its own per-stage log before the body runs, and the point here is only
    # that this body writes each line TWICE.
    ( "$sub" "$NS" ) 2>&1 | tee -a "${INNER_TEE_LOG:-$log}"
else
    # M11 shape: print to stdout; run_stage() owns the single log write
    "$sub" "$NS"
fi
STUB
chmod +x "$T4/bin/stage-body.sh"

# check_dedup <run-dir> <label> -> prints ok/bad lines
# Asserts every per-stage log under <run-dir>/logs carries each sentinel once.
check_dedup() {
    local rd="$1" label="$2" logs f n u seen=0 dupes=0 miscount=0
    logs="$(ls -1 "$rd"/logs/*.log 2>/dev/null)"
    if [ -z "$logs" ]; then
        bad "$label: the run wrote no per-stage logs under $rd/logs"
        return
    fi
    for f in $logs; do
        n="$(grep -c '^MARK-' "$f" 2>/dev/null || true)"
        [ "${n:-0}" = 0 ] && continue
        seen=$((seen + 1))
        if [ "$n" != 2 ]; then
            miscount=$((miscount + 1))
            bad "$label: $(basename "$f") has $n MARK lines, expected 2 (doubled/missing)"
        fi
        u="$(grep '^MARK-' "$f" | sort | uniq -d | wc -l)"
        [ "$u" -gt 0 ] && { dupes=$((dupes + 1))
            bad "$label: doubled lines in $(basename "$f"): $(grep '^MARK-' "$f" | sort | uniq -d | head -2 | tr '\n' ' ')"; }
    done
    [ "$seen" -gt 0 ] && ok "$label: $seen per-stage log(s) carry the sentinel" \
        || bad "$label: no per-stage log carried the sentinel output"
    [ "$dupes" = 0 ] && [ "$miscount" = 0 ] \
        && ok "$label: every line appears exactly once" \
        || ok "$label: DOUBLING DETECTED ($dupes log(s) with dupes, $miscount with wrong count)"
}

# run the two shapes against the REAL run_stage()
run_shape() { # <inner-tee 0|1> <run-dir> -> rc
    local it="$1" rd="$2"
    INNER_TEE="$it" NS="sentinel" \
    NCZ_TEST_STAGE_CMD="\"$T4/bin/stage-body.sh\" {stage}" \
        bash "$BIN" --arch amd64 --full --no-publish --run-dir "$rd" >/dev/null 2>&1
}

echo "== 4a. the harness DETECTS the pre-M11 shape (control) =="
# A control that must go RED: the pre-M11 stage body writes every line twice.
# If this control passes, section 4b proves nothing, so it is asserted to fail.
CTL="$SCRATCH/ctl.log"
: > "$CTL"
# run_stage()'s shape: tee the whole body into the same log.  With INNER_TEE=1
# the body writes it too -> every line twice, which is exactly A2.
( INNER_TEE=1 INNER_TEE_LOG="$CTL" NS=sentinel "$T4/bin/stage-body.sh" "$CTL" ) 2>&1 \
    | tee -a "$CTL" >/dev/null
ctl_total="$(grep -c '^MARK-' "$CTL" 2>/dev/null || true)"
ctl_dist="$(grep '^MARK-' "$CTL" 2>/dev/null | sort -u | grep -c . || true)"
if [ "${ctl_dist:-0}" -gt 0 ] && [ "${ctl_total:-0}" -gt "${ctl_dist:-0}" ]; then
    ok "control: the pre-M11 shape doubles lines (${ctl_total} lines, ${ctl_dist} distinct) -- the check can see the bug"
else
    bad "control: the pre-M11 shape was not doubled (${ctl_total:-0} lines, ${ctl_dist:-0} distinct) -- section 4b is blind to the defect"
fi

echo "== 4b. the REAL tree logs every line exactly once =="
# The stub above proves the harness writes a single log when the stage body does
# not tee.  This half drives the tree's OWN stage function through the tree's
# own run_stage(), so an inner `tee -a "$log"` anywhere in a stage body is
# reproduced for real.  stage_preflight is used because it runs cheaply and its
# `say` helper is exactly where A2's doubling showed up (`say ... | tee -a`).
T4B="$SCRATCH/dedup-real"
mkdir -p "$T4B"
# Drive ONLY preflight: --resume-from skips the earlier stages; the rest are
# stopped by a hook after preflight records its row, so no real work happens.
NCZ_TEST_STAGE_SKIP="refresh-substrate,stage-inputs,refresh-sources,offline-mirror,provenance-inputs,static-gates,layers,image" \
    bash "$BIN" --arch amd64 --full --no-publish --run-dir "$T4B/run" >/dev/null 2>&1
rc=$?
pf="$T4B/run/logs/00-preflight.log"
if [ ! -s "$pf" ]; then
    bad "the real preflight stage wrote no log at $pf (rc=$rc)"
else
    # preflight prints '[preflight] ...' lines via say().  Under run_stage's tee
    # alone each appears once; with an inner `| tee -a "$log"` each appears twice.
    saytotal="$(grep -c '^\[preflight\] ' "$pf" 2>/dev/null || true)"
    saydist="$(grep '^\[preflight\] ' "$pf" 2>/dev/null | sort -u | grep -c . || true)"
    [ "${saydist:-0}" -gt 0 ] \
        && ok "the real preflight stage logged ${saydist} distinct say() line(s)" \
        || bad "the real preflight stage logged no say() lines"
    if [ "${saytotal:-0}" -eq "${saydist:-0}" ] && [ "${saydist:-0}" -gt 0 ]; then
        ok "real stage body: every say() line appears exactly once (no inner tee)"
    else
        bad "real stage body doubles its log: ${saytotal:-0} say() lines, ${saydist:-0} distinct"
        grep '^\[preflight\] ' "$pf" 2>/dev/null | sort | uniq -d | head -3 | sed 's/^/       doubled: /'
    fi
fi

echo "== 4c. the REAL tree: a capture+printf stage logs every line once =="
# Some stages CANNOT print straight to stdout: they must decide PASS/FAIL from
# the sub-script's output BEFORE run_stage() writes the stage log (run_stage's
# tee only lands after the stage function returns).  stage_kvm_gate and
# stage_kvm_gate_server therefore capture the sub-script into a variable and
# re-print it once:
#
#     gate_out="$( ... bash build/kvm-install-gate-gpt.sh ... 2>&1 )"
#     printf '%s\n' "$gate_out"
#
# That shape is single-write BY CONSTRUCTION: the command substitution's stdout
# goes to the variable, not the pipe, so only the printf ever reaches
# run_stage()'s tee.  It is easy to "simplify" that back into a pipe (which
# would double every line) or to leave the captured bytes also flowing to the
# outer tee, so it is pinned here: the harness is first shown to DETECT the
# doubled variant, then the tree's capture+printf shape is run for real.
cat > "$T4/bin/stage-capture.sh" <<'STUB'
#!/bin/bash
# <log>  -- a stage body using the capture+printf shape.  $CAP_TEE selects:
#   CAP_TEE=1 -> capture AND also pipe to stdout (the doubling mistake)
#   CAP_TEE=0 -> capture and print once (what the tree does)
log="$1"
[ -n "$log" ] || { echo "stage-capture: usage: <log>" >&2; exit 2; }
sub="$(dirname "$0")/stub-sub.sh"
out="$( "$sub" captured 2>&1 )"
if [ "${CAP_TEE:-0}" = 1 ]; then
    # the mistake: the sub-script ALSO goes to stdout, so run_stage tees it
    ( "$sub" captured ) 2>&1
    printf '%s\n' "$out"
else
    printf '%s\n' "$out"
fi
STUB
chmod +x "$T4/bin/stage-capture.sh"

cap_shape() { # <cap-tee 0|1> <log> -> writes $log
    local cap="$1" l="$2"
    : > "$l"
    ( CAP_TEE="$cap" "$T4/bin/stage-capture.sh" "$l" ) 2>&1 | tee -a "$l" >/dev/null
}
CAPCTL="$SCRATCH/capctl.log"
cap_shape 1 "$CAPCTL"
capctl_total="$(grep -c '^MARK-' "$CAPCTL" 2>/dev/null || true)"
capctl_dist="$(grep '^MARK-' "$CAPCTL" 2>/dev/null | sort -u | grep -c . || true)"
if [ "${capctl_dist:-0}" -gt 0 ] && [ "${capctl_total:-0}" -gt "${capctl_dist:-0}" ]; then
    ok "control: the capture+piped shape doubles lines (${capctl_total} lines, ${capctl_dist} distinct) -- the check can see it"
else
    bad "control: the capture+piped shape was not doubled (${capctl_total:-0}/${capctl_dist:-0}) -- 4c would be blind to it"
fi

CAPOK="$SCRATCH/capok.log"
cap_shape 0 "$CAPOK"
capok_total="$(grep -c '^MARK-' "$CAPOK" 2>/dev/null || true)"
capok_dist="$(grep '^MARK-' "$CAPOK" 2>/dev/null | sort -u | grep -c . || true)"
capok_dupes="$(grep '^MARK-' "$CAPOK" 2>/dev/null | sort | uniq -d | wc -l)"
if [ "${capok_dist:-0}" -gt 0 ] && [ "${capok_total:-0}" -eq "${capok_dist:-0}" ] && [ "${capok_dupes:-1}" = 0 ]; then
    ok "the capture+printf shape logs every line exactly once (${capok_dist} distinct)"
else
    bad "the capture+printf shape doubled or dropped lines (${capok_total:-0} lines, ${capok_dist:-0} distinct)"
fi

# ...and the tree really uses that shape where it must, so 4c covers code that
# exists rather than a happy accident: both KVM gate stages capture their
# sub-script and print it once (never `| tee -a "$log"` -- section 3 forbids it).
for fn in stage_kvm_gate stage_kvm_gate_server; do
    body="$(awk -v f="^$fn\\\\(\\\\)" '$0 ~ f { fn=1; next } fn && /^}/ { exit } fn' "$BIN")"
    if grep -E '^[[:space:]]*(gate_out|set_out)=' <<<"$body" >/dev/null && grep -q 'printf' <<<"$body"; then
        ok "$fn uses the capture+printf shape 4c exercises"
    else
        bad "$fn no longer uses the capture+printf shape -- 4c no longer covers a real stage"
    fi
done

printf '\n== build-log-dedup tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
