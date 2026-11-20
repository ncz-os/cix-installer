#!/usr/bin/env bash
# A self-contained (NCZ_SERVER_PAYLOAD=medium) server build has no
# online_fetch pins in its receipt. The magnetar receipt check must accept
# that shape and still prove base.squashfs went onto the medium -- the
# success line must not assume an online payload_name.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
B="$HERE/build-image.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
nok(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# extract the magnetar receipt heredoc verbatim
awk '/python3 -I - "\$receipt" "\$MAGNETAR_DIR"/{f=1;next} f&&/^PY$/{exit} f' "$B" > "$T/check.py"
[ -s "$T/check.py" ] && ok "extracted the magnetar receipt check" || { nok "no receipt check in build-image.sh"; echo "test-magnetar-medium-receipt: $pass passed, $fail failed"; exit 1; }

mkdir -p "$T/payload"; printf 'base\n' > "$T/payload/base.squashfs"
cat > "$T/receipt.json" <<'JSON'
{"schema":"ncz-medium-receipt/v1","variant":"server",
 "ncz_payload":{"server_payload":"medium","staged_files":["base.squashfs"]}}
JSON

python3 -I "$T/check.py" "$T/receipt.json" "$T/payload" u u u > "$T/out" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "medium receipt accepted (exit 0)" || nok "medium receipt rejected rc=$rc: $(tail -2 "$T/out")"
grep -qi "self-contained" "$T/out" && ok "medium receipt reports the self-contained payload" || nok "medium receipt output: $(tail -1 "$T/out")"

echo "test-magnetar-medium-receipt: $pass passed, $fail failed"
[ "$fail" = 0 ]
