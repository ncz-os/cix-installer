#!/bin/bash
# `ncz-wallpaper-bing market` is the contract the Singularity wallpapers-bing preferred-region row calls:
# no argument prints the effective preference, one argument stores it through the helper.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
H="$HERE/../assets/wallpaper/ncz-wallpaper-bing"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0; ok() { PASS=$((PASS+1)); echo "ok   $1"; }; no() { FAILS=$((FAILS+1)); echo "FAIL $1"; }
export NCZ_BING_DATA_ROOT="$T/data" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/cfg" HOME="$T" NCZ_BING_QUIET=1
unset NCZ_BING_MARKETS NCZ_BING_MARKET LANGUAGE LC_ALL LC_MESSAGES
export LANG=de_DE.UTF-8
F="$T/cfg/singularity/wallpapers-bing/market"
[ "$(bash "$H" market)" = "de-DE" ] && ok "unset: effective preference follows the session locale" || no "unset gave $(bash "$H" market)"
bash "$H" market en-GB; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$F")" = "en-GB" ] && ok "set en-GB writes the preference file" || no "set en-GB rc=$rc file=$(cat "$F" 2>&1)"
[ "$(bash "$H" market)" = "en-GB" ] && ok "get returns the stored market" || no "get gave $(bash "$H" market)"
bash "$H" market fr-fr && [ "$(bash "$H" market)" = "fr-FR" ] && ok "case is normalised" || no "case not normalised"
bash "$H" market all && [ "$(bash "$H" market)" = "all" ] && ok "all means no preference" || no "all not stored"
bash "$H" market consolidated && [ "$(bash "$H" market)" = "all" ] && ok "the combined row maps to all" || no "consolidated not mapped"
bash "$H" market auto && [ "$(bash "$H" market)" = "de-DE" ] && ok "auto resolves through the locale again" || no "auto gave $(bash "$H" market)"
bash "$H" market en-ZZ 2>/dev/null; rc=$?; v=$(cat "$F")
[ "$rc" = 2 ] && [ "$v" = "auto" ] && ok "unknown market rejected, file untouched" || no "en-ZZ rc=$rc file=$v"
bash "$H" market banana 2>/dev/null; [ $? = 2 ] && ok "garbage rejected" || no "garbage accepted"
[ ! -e "$F.tmp" ] && ok "no temp file left behind" || no "temp file left"
bash "$H" markets | grep -q "^en-GB" && ok "markets still lists the codes the picker offers" || no "markets lost en-GB"
for code in $(bash "$H" markets | cut -f1 | grep -v "^consolidated$"); do bash "$H" market "$code" || { no "advertised market $code rejected"; break; }; done; ok "every advertised market is accepted"
echo "wallpaper market tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]
