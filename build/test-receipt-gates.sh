#!/bin/bash
# test-receipt-gates.sh -- gates.json must evidence one_kernel and ui.
# Lane B 2026-11-08 02:55Z: an image's gate summary must include one_kernel and
# ui, not only the kvm/provenance/secret-scan trio.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/build/receipt-gates.py"
if [ ! -f "$G" ]; then
    echo "FAIL: no build/receipt-gates.py (gate summary helper missing)"
    exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- desktop full build: every required gate PASS, ui=PASS ------------------
mkdir -p "$tmp/desktop"
printf 'gate=kvm\nresult=PASS\nui=PASS\noptions=norescue\n' > "$tmp/desktop/kvm-gate.result"
printf 'gate=provenance\nresult=PASS\none_kernel=PASS\n' > "$tmp/desktop/provenance.result"
printf 'gate=secret-scan\nresult=PASS\n' > "$tmp/desktop/secret-scan.result"
printf 'gate=provenance-inputs\nresult=PASS\n' > "$tmp/desktop/provenance-inputs.result"
printf 'gate=layers-preflight\nresult=PASS\n' > "$tmp/desktop/layers-preflight.result"
printf 'stage=layers-postcheck\nresult=PASS\n' > "$tmp/desktop/layers-postcheck.result"

python3 "$G" "$tmp/desktop" --variant desktop > "$tmp/desktop.json" || {
    echo "FAIL: helper exited non-zero on the desktop fixture"; exit 1; }
python3 - "$tmp/desktop.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
g = d["gates"]
for k in ("kvm", "provenance", "one_kernel", "secret_scan", "ui"):
    if g.get(k) != "PASS":
        print(f"FAIL: desktop {k} = {g.get(k)!r}, want PASS"); raise SystemExit(1)
if not d.get("all_required_passed"):
    print("FAIL: desktop all_required_passed false"); raise SystemExit(1)
print("PASS: desktop gates include one_kernel and ui, all required passed")
PY

# --- server medium: ui is not a desktop check; N/A is allowed ---------------
mkdir -p "$tmp/server"
printf 'gate=kvm\nresult=PASS\nvariant=server\nui=server\noptions=server-medium\n' > "$tmp/server/kvm-gate.result"
printf 'gate=provenance\nresult=PASS\none_kernel=PASS\nvariant=server\n' > "$tmp/server/provenance.result"
printf 'gate=secret-scan\nresult=PASS\n' > "$tmp/server/secret-scan.result"
printf 'gate=provenance-inputs\nresult=PASS\n' > "$tmp/server/provenance-inputs.result"
printf 'gate=layers-preflight\nresult=PASS\n' > "$tmp/server/layers-preflight.result"
printf 'stage=layers-postcheck\nresult=PASS\n' > "$tmp/server/layers-postcheck.result"

python3 "$G" "$tmp/server" --variant server > "$tmp/server.json" || {
    echo "FAIL: helper exited non-zero on the server fixture"; exit 1; }
python3 - "$tmp/server.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
g = d["gates"]
if g.get("ui") != "N/A":
    print(f"FAIL: server ui = {g.get('ui')!r}, want N/A"); raise SystemExit(1)
if g.get("one_kernel") != "PASS":
    print(f"FAIL: server one_kernel = {g.get('one_kernel')!r}"); raise SystemExit(1)
if not d.get("all_required_passed"):
    print("FAIL: server all_required_passed false"); raise SystemExit(1)
print("PASS: server gates show one_kernel PASS and ui N/A")
PY

# --- a failing kvm gate must not pass --------------------------------------
mkdir -p "$tmp/bad"
printf 'gate=kvm\nresult=FAIL\nui=PASS\n' > "$tmp/bad/kvm-gate.result"
printf 'gate=provenance\nresult=PASS\none_kernel=PASS\n' > "$tmp/bad/provenance.result"
python3 "$G" "$tmp/bad" --variant desktop > "$tmp/bad.json" || true
python3 - "$tmp/bad.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("all_required_passed"):
    print("FAIL: a FAIL kvm gate reported all_required_passed"); raise SystemExit(1)
print("PASS: a FAIL kvm gate is not summarized as passed")
PY

echo "ALL PASS"
