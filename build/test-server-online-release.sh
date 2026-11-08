#!/bin/bash
# test-server-online-release.sh -- the release server medium must be the ONLINE
# Magnetar medium (option B): a published https base, never a LAN URL, never the
# self-contained fallback, and never a publish from the build.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
S="$ROOT/build/build-server-online.sh"
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }
[ -x "$S" ] && ok "wrapper present" || bad "wrapper missing"
"$S" --arch amd64 --base-url http://host/x >/dev/null 2>&1 && bad "http base accepted" || ok "http base refused"
"$S" --arch amd64 --base-url https://192.168.1.10/x >/dev/null 2>&1 && bad "LAN base accepted" || ok "LAN base refused"
"$S" --arch arm64 --base-url https://pub.example.invalid/p --plan >/dev/null 2>&1 && ok "public https plan accepted" || bad "public https plan refused"
grep -q 'NCZ_SERVER_PAYLOAD=online' "$S" && ok "wrapper uses the online payload mode" || bad "wrapper does not set online mode"
grep -q -- '--no-publish' "$S" && ok "wrapper never publishes" || bad "wrapper could publish"
grep -q 'NCZ_PAYLOAD_BASE_URL' "$S" && ok "wrapper pins the published base" || bad "wrapper does not pin the base"
if [ "$FAIL" = 0 ]; then echo "test-server-online-release: PASS"; else echo "test-server-online-release: FAIL" >&2; exit 1; fi
