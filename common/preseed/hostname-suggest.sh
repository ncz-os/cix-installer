#!/bin/sh
# hostname-suggest.sh -- installer-side hostname handling, run from preseed/early_command via
# _ncz_helper (baked at /ncz/hostname-suggest.sh). The NAME comes from ncz-hostname-gen.sh (the one
# algorithm shared with first boot); this file only talks to debconf.
#
# WHY A HELPER: the logic used to be inlined in early_command, which pushed the joined command to
# 15,634 bytes and broke d-i media detection (build/check-early-command-size.sh guards the budget).
#
# WHY IT RUNS TWICE: preseed/early_command runs once from the initrd preseed and again after d-i
# reloads the media preseed. The reload RESETS netcfg/get_hostname to the preseeded placeholder
# (ncz-setup, seen=true), which silently discarded the earlier suggestion: an installed O6N
# (18e8a14) ended up ncz-20e7bc from the first-boot fallback instead of an IAU name. So:
#   run 1 (no /tmp/.ncz-hostname): decide the name -- prompt when interactive, otherwise the
#         generated (or ncz_hostname=) name -- and save it in /tmp/.ncz-hostname;
#   every run: db_set netcfg/get_hostname + netcfg/hostname from the saved name and mark them seen.
#
# INTERACTIVE = no ncz_components= and no ncz_unattended=1 on the kernel command line. A critical
# question is used because priority=critical suppresses d-i's own hostname question; the operator
# sees the suggestion as the default and can type another name. Unattended installs never block.
# ncz_hostname=<name> on the command line overrides the generated name.
#
# Test seams: NCZ_CONFMODULE, NCZ_HOSTNAME_GEN, NCZ_HOSTNAME_STATE, NCZ_HOSTNAME_ASKED, NCZ_CMDLINE, NCZ_EARLY_LOG.
. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
command -v db_set >/dev/null 2>&1 || exit 0
# shared NCZ dialog look (brand in the frame title, arch + build on the last body line); optional, never fatal
for _ncz_u in "${NCZ_UI_SH:-}" /ncz/ncz-ui.sh /cdrom/ncz-payload/ncz-ui.sh "$(dirname "$0")/ncz-ui.sh"; do
    [ -n "$_ncz_u" ] && [ -r "$_ncz_u" ] && . "$_ncz_u" && break
done
command -v ncz_ui_brand >/dev/null 2>&1 || { ncz_ui_brand() { echo "NCZ-OS"; }; ncz_ui_id() { echo ""; }; }

STATE="${NCZ_HOSTNAME_STATE:-/tmp/.ncz-hostname}"
ASKED="${NCZ_HOSTNAME_ASKED:-/tmp/.ncz-hostname-asked}"
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

# Interactive installs: the name dialog is shown by the --prompt run, right before partitioning (see the note in
# component-selector.sh). The first run only generates and applies the suggestion.
if [ "${1:-}" = "--prompt" ] && [ "$_unattended" = 0 ] && [ ! -e "$ASKED" ] && ! { [ -n "$_override" ] && _ncz_valid "$_override"; } ; then
    : > "$ASKED"
        cat > /tmp/ncz-hostname.templates <<TPL
Template: ncz/hostname
Type: string
Default: $NAME
Description: $(ncz_ui_brand) - name this computer
 A name was generated for this machine: $NAME
 .
 Press Enter to accept it, or type your own name (letters, digits and hyphens, at most 63
 characters). It stays the same if you swap network adapters.
 .
 $(ncz_ui_id)
TPL
        if debconf-loadtemplate ncz /tmp/ncz-hostname.templates 2>/dev/null ; then
            db_set ncz/hostname "$NAME" 2>/dev/null || true
            db_fset ncz/hostname seen false 2>/dev/null || true
            db_settitle ncz/hostname 2>/dev/null || true
            if db_input critical ncz/hostname && db_go ; then
                if db_get ncz/hostname ; then
                    _ans=$(printf '%s' "$RET" | tr 'A-Z' 'a-z')
                    if _ncz_valid "$_ans" ; then NAME=$_ans; _how="chosen by the operator"; fi
                fi
            fi
        fi
    printf '%s\n' "$NAME" > "$STATE"
fi

db_set netcfg/get_hostname "$NAME"
db_set netcfg/hostname "$NAME"
db_fset netcfg/get_hostname seen true
db_fset netcfg/hostname seen true
echo "early_command: hostname $NAME ($_how; unattended=$_unattended)" >> "$LOG" 2>/dev/null
exit 0
