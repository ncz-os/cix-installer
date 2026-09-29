#!/bin/bash
# offline / blackholed network: `ncz-wallpaper-bing fetch --if-stale` must exit 75 quickly (the KVM gate smoke run allows 90 s)
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
H="$HERE/../assets/wallpaper/ncz-wallpaper-bing"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0; ok() { PASS=$((PASS+1)); echo "ok   $1"; }; no() { FAILS=$((FAILS+1)); echo "FAIL $1"; }
export NCZ_BING_DATA_ROOT="$T/data" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/cfg" HOME="$T"
t0=$SECONDS
NCZ_BING_PROBE_HOST=127.0.0.1 NCZ_BING_PROBE_PORT=1 bash "$H" fetch --if-stale >"$T/out" 2>&1; rc=$?
[ "$rc" = 75 ] && ok "closed port: exit 75 (temporary failure)" || { no "closed port gave rc=$rc"; cat "$T/out"; }
[ $((SECONDS - t0)) -le 15 ] && ok "and within 15 s" || no "took $((SECONDS - t0)) s"
grep -q "unreachable" "$T/out" && ok "it says why" || no "no reason logged"
grep -q 'def reachable' "$H" && ok "probe is in the helper" || no "probe missing"
echo "wallpaper probe tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]
