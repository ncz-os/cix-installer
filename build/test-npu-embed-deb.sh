#!/bin/bash
# test-npu-embed-deb.sh -- ncz-npu-embed is built from this tree, matches the image's NPU venv and
# the unit hook 89 writes, pins the cix-noe-umd the images ship, and is byte-reproducible.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/var/tmp}/npuembed.XXXXXX")"; trap 'rm -rf "$T"' EXIT
: > "$T/index"
for i in 1 2; do
  ( umask $([ $i = 1 ] && echo 022 || echo 002); NCZ_PUBLISHED_INDEX="$T/index" NCZ_NPU_EMBED_OUT="$T/o$i" bash "$ROOT/build/build-npu-embed-deb.sh" ) > "$T/b$i.log" 2>&1 \
    || bad "build $i failed" "$(tail -5 "$T/b$i.log")"
  sleep 1
done
D1="$(ls "$T"/o1/*.deb 2>/dev/null)"; D2="$(ls "$T"/o2/*.deb 2>/dev/null)"
[ -n "$D1" ] && cmp -s "$D1" "$D2" && ok "byte-identical across rebuilds" || bad "not reproducible"
dep="$(dpkg-deb -f "$D1" Depends 2>/dev/null)"
case "$dep" in *"cix-noe-umd (>= 3.1.4-cixdeb13-260714)"*) ok "Depends pins the shipped cix-noe-umd ($dep)" ;; *) bad "Depends: $dep" ;; esac
dpkg-deb -x "$D1" "$T/x"
grep -q '^ExecStart=/opt/ncz/noe-venv/bin/python /usr/local/bin/ncz-npu-embed-server.py' "$T/x/lib/systemd/system/ncz-npu-embed.service" \
    && ok "unit runs on the image's noe-venv" || bad "unit ExecStart" "$(grep ExecStart "$T/x/lib/systemd/system/ncz-npu-embed.service")"
grep -q 'embed-venv' -r "$T/x" && bad "package still references embed-venv" || ok "no embed-venv reference"
cmp -s "$T/x/usr/local/bin/ncz-npu-embed-server.py" "$ROOT/assets/npu/ncz-npu-embed-server.py" && ok "server is the tree's assets/npu copy" || bad "server differs from assets/npu"
grep -q 'LOCAL_NOMIC_TOKENIZER' "$ROOT/assets/npu/ncz-npu-embed-server.py" && ok "server prefers the packaged local tokenizer" || bad "no local tokenizer fallback"
echo "test-npu-embed-deb: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
