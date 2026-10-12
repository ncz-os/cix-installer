#!/usr/bin/env bash
# tools/lockrig/agent/headless.sh -- runs ON a host (build host or a host with no
# DRM/compositor). Drives the committed headless labwc lock suite
# (tests/lockscreen-framesrc/test-framesrc.sh) inside a container against a set
# of harness binaries. This is the fallback used for headless hosts (PROTEUS) and
# the dry-run on the build hosts (ACHILLES/ULTRA), and it "says so": the result
# is tagged mode=headless and the ledger records which binaries were used.
#
# Env in:  BINDIR   abs path on the host with singularity-lockscreen-on,
#                   singularity-lockscreen-off, singularity-lock-framesrc-testsrc
#          TESTFILE abs path to test-framesrc.sh
#          IMAGE    container image (default localhost/ncz-locktest:forky)
#          D        scratch dir   TAG host name
# Out:     $D/cases.tsv  $D/result.json  $D/headless.log
set -u
BINDIR="${BINDIR:?BINDIR required}"
TESTFILE="${TESTFILE:?TESTFILE required}"
IMAGE="${IMAGE:-localhost/ncz-locktest:forky}"
TAG="${TAG:-host}"; D="${D:-$HOME/Projects/lockrig/run-$$}"
mkdir -p "$D"; R="$D/cases.tsv"; : > "$R"; LOG="$D/headless.log"; : > "$LOG"
trap 'touch "$D/DONE" 2>/dev/null' EXIT
say(){ echo "[$(date +%T)] $*" | tee -a "$LOG"; }
rec(){ printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$R"; say "CASE $1 $2: ${3:-}"; }

say "=== lockrig headless host=$TAG image=$IMAGE bindir=$BINDIR ==="
missing=""
for b in singularity-lockscreen-on singularity-lockscreen-off singularity-lock-framesrc-testsrc; do
  [ -x "$BINDIR/$b" ] || missing="$missing $b"
done
if [ -n "$missing" ]; then
  rec TH SKIP "harness binaries not staged at $BINDIR (missing:$missing); stage a matching-arch build or set LOCKRIG_BINDIR_*"
  cat > "$D/result.json" <<JSON
{"host":"$TAG","mode":"headless","binaries":"$BINDIR","summary":{"pass":0,"fail":0,"skip":1},"reason":"harness binaries not staged"}
JSON
  exit 0
fi
[ -r "$TESTFILE" ] || { rec TH SKIP "test-framesrc.sh not found at $TESTFILE"; cat > "$D/result.json" <<JSON
{"host":"$TAG","mode":"headless","summary":{"pass":0,"fail":0,"skip":1},"reason":"test-framesrc.sh missing"}
JSON
exit 0; }

CTR="podman"
command -v "$CTR" >/dev/null 2>&1 || { rec TH SKIP "no podman on host: cannot run headless harness"; cat > "$D/result.json" <<JSON
{"host":"$TAG","mode":"headless","summary":{"pass":0,"fail":0,"skip":1},"reason":"no podman"}
JSON
exit 0; }
"$CTR" image exists "$IMAGE" 2>/dev/null || { rec TH SKIP "container image $IMAGE not present on host; stage it (podman load) or set IMAGE"; cat > "$D/result.json" <<JSON
{"host":"$TAG","mode":"headless","summary":{"pass":0,"fail":0,"skip":1},"reason":"image $IMAGE missing"}
JSON
exit 0; }

WORK="$D/work"; mkdir -p "$WORK/tmp"; cp "$BINDIR"/singularity-lockscreen-on "$BINDIR"/singularity-lockscreen-off "$BINDIR"/singularity-lock-framesrc-testsrc "$WORK/" 2>>"$LOG"
chmod 755 "$WORK"/singularity-* 2>/dev/null
cp "$TESTFILE" "$WORK/test-framesrc.sh"; chmod 755 "$WORK/test-framesrc.sh"

say "running container harness..."
"$CTR" run --rm --network=none -v "$WORK":/work:Z -w /work -e WORK=/work -e TMPDIR=/work/tmp \
  "$IMAGE" bash /work/test-framesrc.sh >"$D/headless.out" 2>&1
RC=$?
pass=$(grep -c 'PASS:' "$D/headless.out" 2>/dev/null); [ -n "$pass" ] || pass=0
fail=$(grep -c 'FAIL:' "$D/headless.out" 2>/dev/null); [ -n "$fail" ] || fail=0
say "container rc=$RC pass=$pass fail=$fail"
tail -5 "$D/headless.out" | sed 's/^/    /' | tee -a "$LOG"
if [ "$RC" = 0 ] && [ "$fail" = 0 ] && [ "$pass" -ge 1 ]; then
  rec TH PASS "headless labwc suite ($IMAGE): $pass passed / $fail failed"
  sp=1; sf=0
else
  rec TH FAIL "headless labwc suite rc=$RC: $pass passed / $fail failed (see headless.out)"
  sp=0; sf=1
fi
cat > "$D/result.json" <<JSON
{"host":"$TAG","mode":"headless","image":"$IMAGE","binaries":"$BINDIR",
 "ended_iso":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","summary":{"pass":$sp,"fail":$sf,"skip":0}}
JSON
exit 0
