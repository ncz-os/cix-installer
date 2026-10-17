#!/bin/sh
# hostname-suggest.sh -- installer-side hostname handling, run from preseed/early_command via
# _ncz_helper (baked at /ncz/hostname-suggest.sh). The NAME comes from ncz-hostname-gen.sh (the one
# algorithm shared with first boot); this file only talks to debconf.
#
# WHY A HELPER: the logic used to be inlined in early_command, which pushed the joined command to
# 15,634 bytes and broke d-i media detection (build/check-early-command-size.sh guards the budget).
#
# WHY IT HANDLES A RE-RUN: until 2026-10-08 preseed/early_command ran twice (the initrd preseed, then
# the media preseed that file-preseed reloaded). That reload RESET netcfg/get_hostname to the preseeded
# placeholder (ncz-setup, seen=true), which silently discarded the earlier suggestion: an installed O6N
# (18e8a14) ended up ncz-20e7bc from the first-boot fallback instead of an IAU name. Since 2026-10-08 the
# Install entry loads preseed.cfg once, so no reload happens; this state-driven behaviour is retained
# defensively in case the command is ever evaluated twice. So:
#   first run (no /tmp/.ncz-hostname): decide the name -- the generated (or ncz_hostname=) name -- and
#         save it in /tmp/.ncz-hostname;
#   every run: db_set netcfg/get_hostname + netcfg/hostname from the saved name and mark them seen.
#
# NO PROMPT, EVER (S2-3): the hostname is automatic. The retired --prompt branch (build a critical
# template, show a dialog, write an $ASKED marker) was removed outright -- preseed.cfg never passed
# --prompt, and leaving it in place was an automation hazard: a future caller re-adding the flag would
# silently reintroduce an interactive prompt into an unattended pipeline. Nothing in this script reads
# stdin, so it cannot block.
# ncz_hostname=<name> on the command line overrides the generated name.
#
# Test seams: NCZ_CONFMODULE, NCZ_HOSTNAME_GEN, NCZ_HOSTNAME_STATE, NCZ_CMDLINE, NCZ_EARLY_LOG.
. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
command -v db_set >/dev/null 2>&1 || exit 0

STATE="${NCZ_HOSTNAME_STATE:-/tmp/.ncz-hostname}"
LOG="${NCZ_EARLY_LOG:-/var/log/early_command.log}"
CMDLINE="${NCZ_CMDLINE:-/proc/cmdline}"
GEN="${NCZ_HOSTNAME_GEN:-}"
if [ -z "$GEN" ] ; then
    for _g in /ncz/ncz-hostname-gen.sh /tmp/ncz-hostname-gen.sh "$(dirname "$0")/ncz-hostname-gen.sh" /cdrom/ncz-payload/ncz-hostname-gen.sh ; do
        [ -f "$_g" ] && { GEN="$_g"; break; }
    done
fi

_ncz_valid() {   # RFC 1123 label, at most 63 characters, lower case
    case "$1" in ''|-*|*-|*[!a-z0-9-]*) return 1 ;; esac
    [ "${#1}" -le 63 ]
}

_unattended=0; _override=""
for _t in $(cat "$CMDLINE" 2>/dev/null) ; do
    case $_t in
        ncz_components=*|ncz_unattended=1) _unattended=1 ;;
        ncz_hostname=*) _override=${_t#ncz_hostname=} ;;
    esac
done

if [ -s "$STATE" ] ; then
    NAME=$(cat "$STATE")
    _how="re-applied after the preseed reload"
else
    if [ -n "$GEN" ] ; then
        _out=$(sh "$GEN" --source 2>/dev/null)
        NAME=${_out%% *}; _src=${_out#* }
    else
        NAME=""; _src="no-generator"
    fi
    _ncz_valid "$NAME" || { NAME="ncz-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"; _src="fallback"; }
    _how="generated from $_src"
    if [ -n "$_override" ] && _ncz_valid "$_override" ; then
        NAME=$_override; _how="ncz_hostname= on the command line"
    fi
    printf '%s\n' "$NAME" > "$STATE"
fi

# NO INTERACTIVE PROMPT (S2-3). The hostname is automatic: preseed.cfg never
# calls this script with --prompt, so the retired --prompt block (which built a
# template, showed a critical dialog and wrote an $ASKED marker) was dead code
# that could re-enable an interactive prompt in an unattended pipeline if anyone
# re-added the flag. It is deleted outright: this helper's ONLY job is to
# db_set the generated/overridden name. Nothing here can block on input.

db_set netcfg/get_hostname "$NAME"
db_set netcfg/hostname "$NAME"
db_fset netcfg/get_hostname seen true
db_fset netcfg/hostname seen true
echo "early_command: hostname $NAME ($_how; unattended=$_unattended)" >> "$LOG" 2>/dev/null
exit 0
