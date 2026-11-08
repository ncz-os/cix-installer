#!/bin/bash
# test-ui-socket-path.sh -- the UI capture harness must not put its qemu UNIX
# sockets under the (deep) run dir: AF_UNIX is capped at ~108 bytes and the
# arm64 2026-11-08 UI check died with "OSError: AF_UNIX path too long" because
# TMPDIR was the run dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
P="$ROOT/build/boot-screens.py"
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }
grep -q 'NCZ_UI_SOCKDIR' "$P" && ok "harness accepts a socket-dir override" || bad "no socket-dir override"
grep -q 'dir=os.environ.get("NCZ_UI_SOCKDIR") or "/tmp"' "$P" \
    && ok "socket dir defaults to /tmp, not TMPDIR" || bad "socket dir still follows TMPDIR"
# runtime proof: with a deep TMPDIR, the chosen base is still short
deep="$(mktemp -d /tmp/ncz-deep.XXXXXX)"; mkdir -p "$deep/$(printf 'x%.0s' $(seq 1 60))/$(printf 'y%.0s' $(seq 1 40))"
short=$(TMPDIR="$deep" python3 - "$P" <<'PY'
import os, re, sys, tempfile
src = open(sys.argv[1]).read()
m = re.search(r'SOCKD = tempfile\.mkdtemp\(prefix="ncz-bs-", dir=os\.environ\.get\("NCZ_UI_SOCKDIR"\) or "/tmp"\)', src)
assert m, "pattern not found"
d = tempfile.mkdtemp(prefix="ncz-bs-", dir=os.environ.get("NCZ_UI_SOCKDIR") or "/tmp")
print(d)
PY
)
rm -rf "$deep"
if [ -n "$short" ] && [ "${#short}" -lt 100 ]; then ok "socket dir path is short (${#short} bytes)"; else bad "socket dir path too long: ${short}"; fi
if [ "$FAIL" = 0 ]; then echo "test-ui-socket-path: PASS"; else echo "test-ui-socket-path: FAIL" >&2; exit 1; fi
