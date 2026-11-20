#!/bin/bash
# The image installs flight-plans.json where hook 58 puts it; the rotate script must
# search that path. a test machine 2026-11-14: hook 58 installed /usr/local/share/ncz/flight-plans.json
# but the script only looked beside itself, in ~/.local/share/ncz and /usr/share/ncz-screensavers,
# so ncz-bh-flightplan.service failed every 5 min ("flight-plans.json not found").
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }
S="$ROOT/assets/screensaver/ncz-bh-flightplan-rotate"
H="$ROOT/post-install/58-screensaver-shader.sh"
DEST=$(sed -n "s#.*install -m 0644 \"\$SRC/flight-plans.json\" \(/[^ ]*flight-plans.json\).*#\1#p" "$H" | head -1)
[ -n "$DEST" ] && ok "hook 58 installs the plans at $DEST" || bad "cannot read the plans destination from hook 58"
grep -qF "pathlib.Path(\"$DEST\")" "$S" && ok "rotate script searches $DEST" || bad "rotate script does not search $DEST (the service fails on an installed image)"
# behaviour, not just text: with the plans only at the installed path the lookup must succeed
if [ -n "$DEST" ] && command -v python3 >/dev/null; then
    T=$(mktemp -d "${TMPDIR:-$HOME}/bhfp.XXXXXX") || exit 2
    trap "rm -rf \"$T\"" EXIT
    mkdir "$T/bin"
    sed "s#pathlib.Path(\"$DEST\")#pathlib.Path(\"$T/flight-plans.json\")#" "$S" > "$T/bin/rotate.py"
    echo "{}" > "$T/flight-plans.json"
    cd "$T" && env -u NCZ_BH_PLANS HOME="$T/none" python3 - <<PY && ok "lookup resolves the installed-path plans" || bad "lookup did not resolve the installed-path plans"
import runpy, sys
ns = runpy.run_path("$T/bin/rotate.py", run_name="not_main")
assert str(ns["_plans_path"]()) == "$T/flight-plans.json"
PY
fi
if [ "$FAIL" = 0 ]; then echo "test-bh-flightplan-path: PASS"; else echo "test-bh-flightplan-path: FAIL" >&2; exit 1; fi
