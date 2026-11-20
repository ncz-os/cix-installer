#!/usr/bin/env bash
# A self-contained (server_payload=medium) server receipt has no online_fetch
# pins; the provenance gate must accept it and check the staged payload instead
# of failing "no ncz_payload.online_fetch payload pins".
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
F="$HERE/forky-provenance.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
nok(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

run_pins() { # RECEIPT_JSON -> prints "rc<space>repr"
  python3 -I - "$F" "$1" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rec = json.loads(sys.argv[2])
pins = m.server_pins("img", rec)
print("ok" if pins and pins.get("self_contained") else ("none" if pins is None else "online"), repr(pins))
print("fails=%d" % len(m.FAILS), file=sys.stderr)
PY
}

printf '%s' '{"variant":"server","ncz_payload":{"server_payload":"medium","staged_files":["base.squashfs"]}}' > "$T/medium.json"
out="$(run_pins "$(cat "$T/medium.json")" 2>"$T/err")"; rc=$?
[ "$rc" = 0 ] && grep -q '^ok ' <<<"$out" && ok "medium receipt accepted as self-contained" || nok "medium receipt: $out $(cat "$T/err")"
grep -q 'fails=0' "$T/err" && ok "medium receipt records no failure" || nok "medium receipt failures: $(cat "$T/err")"

printf '%s' '{"variant":"server","ncz_payload":{"server_payload":"medium","staged_files":[]}}' > "$T/bad.json"
out="$(run_pins "$(cat "$T/bad.json")" 2>"$T/err2")"
grep -q '^none ' <<<"$out" && ok "medium receipt without staged base.squashfs is refused" || nok "medium receipt without staged payload accepted: $out"

printf '%s' '{"variant":"server","ncz_payload":{"online_fetch":{"payload_name":"base.squashfs","payload_url":"https://e/base","payload_sha256":"'$(printf 'a%.0s' {1..64})'","assets_name":"ncz-assets-amd64.tar.gz","assets_url":"https://e/a","assets_sha256":"'$(printf 'b%.0s' {1..64})'","pool_name":"ncz-pool-amd64.tar.gz","pool_url":"https://e/p","pool_sha256":"'$(printf 'c%.0s' {1..64})'"}}}' > "$T/online.json"
out="$(run_pins "$(cat "$T/online.json")" 2>/dev/null)"
grep -q '^online ' <<<"$out" && ok "online receipt still returns the pin dict" || nok "online receipt: $out"

echo "test-provenance-medium-receipt: $pass passed, $fail failed"
[ "$fail" = 0 ]
