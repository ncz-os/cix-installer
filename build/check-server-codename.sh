#!/bin/bash
# check-server-codename.sh -- static guard: no file on the Magnetar Server install path may
# hard-code the desktop release codename ("Cygnus") outside manifests/server-codename-allowlist.tsv.
#
# 2026-10-26 (cyclops, first real amd64 server install): the installer said "NCZ-OS 26.10 Cygnus"
# on every screen. That text came from release.conf at run time, which
# build/test-server-branding.sh covers by rendering the server strings; this check stops the
# other way back in, a literal "Cygnus" in a server-path script.
#
# Server-path files: the d-i helpers (preseed/), every post-install hook a server runs (the
# desktop-only hooks run-all.sh skips without the desktop component are excluded, read from its
# _SKIP_DESKTOP_RE), post-install/lib/, the installed rEFInd generators and kernel hook, the ncz
# CLI and the installer ESP builder. Comment lines (# ...) are prose and not checked.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ROOT="${NCZ_CODENAME_CHECK_ROOT:-$ROOT}"
ALLOW="${NCZ_CODENAME_ALLOWLIST:-$ROOT/manifests/server-codename-allowlist.tsv}"
cd "$ROOT" || exit 2
[ -r "$ALLOW" ] || { echo "check-server-codename: allow-list missing: $ALLOW" >&2; exit 2; }
SKIP=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}_SKIP_DESKTOP_RE=[\"']\([^\"']*\)[\"'].*/\2/p" post-install/run-all.sh | head -1)
[ -n "$SKIP" ] || { echo "check-server-codename: cannot read _SKIP_DESKTOP_RE from post-install/run-all.sh" >&2; exit 2; }

files=()
for f in preseed/*.sh preseed/preseed.cfg post-install/*.sh post-install/lib/*.sh \
         assets/refind/*.sh assets/refind/zz1-ncz-refind-refresh-amd64 assets/ncz-cli.sh \
         build/iso/build-refind-esp.py; do
    [ -f "$f" ] || continue
    case "$f" in post-install/[0-9]*) printf '%s\n' "${f##*/}" | grep -qE "$SKIP" && continue ;; esac
    files+=("$f")
done

fail=0; used=""
while IFS= read -r hit; do
    f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}; line=${rest#*:}
    # a whole-line comment (first non-blank character '#') is prose; a trailing comment is not exempt
    l2=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$l2" in '#'*) continue ;; esac
    # Per occurrence, not per line: every allow-listed text this file's rows match is cut out
    # of the line, and the line is a hit when a "cygnus" is still left. A second, unlisted
    # literal on an allow-listed line therefore still fails.
    rest="$line"; idx=0
    while IFS=$'\t' read -r ap are _reason; do
        case "$ap" in ''|'#'*) continue ;; esac
        idx=$((idx + 1))
        [ "$ap" = "$f" ] || continue
        cut=$(printf '%s\n' "$rest" | NCZ_RE="$are" awk '{ n = gsub(ENVIRON["NCZ_RE"], ""); print n "\t" $0 }')
        if [ "${cut%%$'\t'*}" != 0 ]; then used="$used $idx"; rest="${cut#*$'\t'}"; fi
    done < "$ALLOW"
    allowed=1
    printf '%s\n' "$rest" | grep -qi cygnus && allowed=0
    if [ "$allowed" = 0 ]; then
        echo "FAIL $f:$n: names the desktop codename on the server install path: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-160)"
        fail=1
    fi
done < <(grep -n -i -H cygnus "${files[@]}" 2>/dev/null)

# a row that matches nothing is stale: remove it rather than let it silently widen later
idx=0
while IFS=$'\t' read -r ap are _reason; do
    case "$ap" in ''|'#'*) continue ;; esac
    idx=$((idx + 1))
    case " $used " in *" $idx "*) ;; *) echo "FAIL allow-list row $idx ($ap: $are) matches nothing; remove it"; fail=1 ;; esac
done < "$ALLOW"

if [ "$fail" != 0 ]; then
    echo "check-server-codename: FAIL (${#files[@]} server-path files scanned)" >&2
    exit 1
fi
echo "check-server-codename: OK (${#files[@]} server-path files, no unlisted 'Cygnus')"
