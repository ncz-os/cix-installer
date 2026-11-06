#!/bin/bash
# rehearse.sh -- M6: run every gate that needs no host and writes nothing.
#
# Purpose (docs/BUILD-STABILITY.md §M6): catch a stale or incoherent tree at commit time, not at
# stage 80 of a multi-hour build. This is deliberately NOT the whole build: it runs the static
# gates, the input-pin check (which carries M8's rootfs-snapshot rule) and the M8 unit test, then
# stops. No stage runs, no file is modified, no container is created.
#
# Exit codes: 0 all gates passed; 3 a gate failed (the failing gate is named).
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
fail=0
ran=0

run_gate() { # <label> <command...>
  local label=$1; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  ran=$((ran + 1))
  if [ $rc -eq 0 ]; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    printf '%s\n' "$out" | tail -6 | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

echo "== rehearse ($(date -u +%Y-%m-%dT%H:%MZ)) =="

# 1. the tree must be clean: a rehearsal over uncommitted edits proves nothing about the commit
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "FAIL tree is dirty -- commit or stash before rehearsing"
  git status --porcelain | head -8 | sed 's/^/       /'
  fail=$((fail + 1))
else
  ran=$((ran + 1)); echo "ok   tree is clean"
fi

# 1b. temp space: the gates here unpack debs into TMPDIR, and a full tmpfs turns them into
# false failures ("unreadable deb", "no .deb found in pool"). 11G of my own scratch once made
# this suite look unstable; it was the host, not the tests.
tmpdir_used_pct=$(df -P "${TMPDIR:-/tmp}" | awk "NR==2{gsub(/%/,"",$5); print $5}")
if [ -n "${tmpdir_used_pct:-}" ] && [ "$tmpdir_used_pct" -gt 90 ]; then
  echo "FAIL ${TMPDIR:-/tmp} is ${tmpdir_used_pct}% full -- clean scratch before rehearsing"
  fail=$((fail + 1))
else
  ran=$((ran + 1)); echo "ok   temp space (${TMPDIR:-/tmp} ${tmpdir_used_pct:-?}% used)"
fi

# 2. static gates that need no host
for g in build/test-no-ubuntu.sh build/test-pin-coherence.sh build/test-no-pin-literals.sh; do
  [ -x "$g" ] && run_gate "${g#build/}" bash "$g"
done

# 3. M8: the rootfs rows must carry the snapshot release.conf pins
if [ -x build/stage-build-inputs.sh ]; then
  out=$(bash build/stage-build-inputs.sh --arch "$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" --check 2>&1)
  rc=$?
  ran=$((ran + 1))
  if [ $rc -eq 0 ]; then
    echo "ok   build inputs staged and snapshot-bound (M8)"
  else
    echo "FAIL build inputs / M8"
    printf '%s\n' "$out" | grep -E "MISSING/BAD|M8|rebuild required" | head -6 | sed 's/^/       /'
    fail=$((fail + 1))
  fi
fi

# 4. the M8 unit test (cheap, fixtures only)
[ -f build/test-rootfs-snapshot-binding.sh ] && run_gate "test-rootfs-snapshot-binding.sh" bash build/test-rootfs-snapshot-binding.sh

echo
if [ $fail -eq 0 ]; then
  echo "rehearse: OK ($ran gates, nothing written)"
  exit 0
fi
echo "rehearse: FAIL ($fail of $ran gates)"
exit 3
