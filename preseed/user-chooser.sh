#!/bin/sh
# user-chooser.sh -- NCZ installer interactive USERNAME + PASSWORD (with confirm)
# selection. Invoked from partman/early_command (see preseed.cfg), in the
# exact position the operator requires (after region / before hostname / before
# disk+fs).
#
# The operator requires EXACTLY ONE USERNAME PROMPT, followed by EXACTLY ONE
# PASSWORD PROMPT WITH CONFIRM (so two prompt appearances for password:
# "default password with confirm (2x)").
#
# WHY A CUSTOM CHOOSER (same reasoning as disk-fs-chooser.sh /
# hostname-suggest.sh / region-chooser.sh): the ISO boots d-i at
# priority=critical so finish-install auto-reboots cleanly. At critical
# priority d-i AUTO-ANSWERS its own passwd/username + passwd/user-password +
# passwd/user-password-again chain with whatever is preseeded rather than
# showing them -- so without this script the install silently lands on a
# username/password it inherits from preseed.cfg (or prompts d-i native).
# We register our own cdebconf templates and db_input them at CRITICAL
# priority, which IS shown even under the critical threshold.
#
# This is NOT destructive (a username/password mistake is recoverable, unlike
# the disk wipe), so the failure mode is "fall back to the default username
# / no password set (unattended-equivalent) and continue the install",
# never abort. An aborted install over a debconf hiccup here would be a
# worse trade.
#
# TEST/UNATTENDED override: kernel cmdline `ncz_username=<name>` and
# `ncz_password=<plain>` skip the prompts entirely. The KVM install gate
# uses these for its unattended runs. Empty + absent overrides -> prompt
# is shown. Password overrides do NOT have a confirm step (the override is
# authoritative; an unattended install has no operator to compare against).
#
# Persistence: writes /tmp/ncz-user (consumed by late.sh and any
# diagnostics); pushes the answers into the d-i passwd/* questions with
# seen=true so d-i's user-setup does not re-prompt. passwd/root-login is
# forced false (no root password prompt, ever -- the magnetar diag account
# is the lockout backstop, see post-install/09-diag-account.sh).

set +e

. /usr/share/debconf/confmodule 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true

# shared NCZ dialog look (brand in the frame title, arch + build on the last body line); optional, never fatal
for _ncz_u in "${NCZ_UI_SH:-}" /ncz/ncz-ui.sh /cdrom/ncz-payload/ncz-ui.sh "$(dirname "$0")/ncz-ui.sh"; do
    [ -n "$_ncz_u" ] && [ -r "$_ncz_u" ] && . "$_ncz_u" && break
done
command -v ncz_ui_brand >/dev/null 2>&1 || { ncz_ui_brand() { echo "NCZ-OS"; }; ncz_ui_id() { echo ""; }; }

log() {
    echo "[ncz user] $*"
    # Progress chatter goes to VT3 (and the serial diag console); VT1/console is the
    # newt UI and raw lines written over it corrupt the screen. Failures stay visible.
    case "$*" in
        ABORT*|FATAL*|ERROR*) _vs="/dev/console /dev/tty1 /dev/tty3" ;;
        *) _vs="/dev/tty3" ;;
    esac
    for _v in $_vs; do
        echo "[ncz user] $*" > "$_v" 2>/dev/null || true
    done
}

# --- read cmdline overrides --------------------------------------------------
CMD=$(cat /proc/cmdline 2>/dev/null)
OVR_USER=""; OVR_PASS=""
_unattended=0
for tok in $CMD; do
    case "$tok" in
        ncz_username=*) OVR_USER="${tok#ncz_username=}" ;;
        ncz_password=*) OVR_PASS="${tok#ncz_password=}" ;;
        ncz_components=*|ncz_unattended=1) _unattended=1 ;;
    esac
done

# Defer the dialog until partman/early_command (see component-selector.sh for
# the same pattern). When called WITHOUT --prompt (i.e. from the first
# early_command), we still register the default username but never prompt
# the operator. This keeps the boot-time silent stretch free of any
# operator-blocking dialog.
NCZ_PROMPT="${1:-}"

# validation (POSIX sh, no grep -P, no extended regex for portability with the
# installer's busybox ash)
is_valid_username() {
    _u="$1"
    [ -n "$_u" ] || return 1
    [ "${#_u}" -le 32 ] || return 1
    # first char must be a lowercase letter; rest lowercase letters / digits / hyphens / underscores.
    case "$_u" in
        [a-z]*) : ;;
        *) return 1 ;;
    esac
    case "$_u" in
        *[!a-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# --- username --------------------------------------------------------------
# Skip the interactive prompt when this run is unattended (KVM gates pass
# ncz_components= or ncz_unattended=1 on the kernel cmdline; mirroring
# hostname-suggest.sh's pattern so the gate does not stall on the prompt).
CHOSEN_USER=""
if [ -n "$OVR_USER" ]; then
    if is_valid_username "$OVR_USER"; then
        CHOSEN_USER="$OVR_USER"
        log "cmdline override: username=$CHOSEN_USER"
    else
        log "WARNING: ncz_username=$OVR_USER is not a valid POSIX username -- falling back to prompt"
    fi
fi
# Unattended without ncz_username=: keep a username preseeded through the
# standard d-i key (passwd/username= on the cmdline or in a preseed file)
# instead of replacing it with the default. Replacing it also dropped the
# preseeded password (below), d-i user-setup then failed on "No password has
# been supplied" before adding the default groups, and the only account had
# no sudo (2026-10-06 KVM gate: sudo_ok=0).
if [ -z "$CHOSEN_USER" ] && [ "$_unattended" = 1 ] && db_get passwd/username 2>/dev/null \
        && is_valid_username "$RET"; then
    CHOSEN_USER="$RET"
    log "unattended: keeping preseeded username=$CHOSEN_USER"
fi
if [ -z "$CHOSEN_USER" ] && [ "$NCZ_PROMPT" = "--prompt" ] && [ "$_unattended" = 0 ]; then
    cat > /tmp/ncz-username.templates <<TPL
Template: ncz/username
Type: string
Default: ncz
Description: $(ncz_ui_brand) - choose a USERNAME
 This is the only account on the installed system. It is in the sudo group
 and is the one you will log in with. Use lowercase letters, digits,
 hyphens and underscores only, starting with a letter (at most 32
 characters).
 .
 Press Enter to accept the default "ncz".
 .
 $(ncz_ui_id)
TPL
    if debconf-loadtemplate ncz /tmp/ncz-username.templates 2>/dev/null; then
        db_set     ncz/username ncz 2>/dev/null || true
        db_fset    ncz/username seen false 2>/dev/null || true
        db_settitle ncz/username 2>/dev/null
        if db_input critical ncz/username && db_go; then
            db_get ncz/username && CHOSEN_USER="$RET"
        else
            log "WARNING: username prompt could not be shown/completed -- using default"
        fi
    else
        log "WARNING: could not load username template -- using default"
    fi
fi
[ -n "$CHOSEN_USER" ] || CHOSEN_USER="ncz"
is_valid_username "$CHOSEN_USER" || CHOSEN_USER="ncz"

# --- password (and confirm) -------------------------------------------------
# We deliberately do NOT validate password strength -- the operator picked
# it; passwd/user-setup's default strength policy is acceptable on NCZ-OS
# and refusing a weak password here just makes the operator set up the
# account in the live system, which is worse UX. user-setup/allow-password-weak
# is already preseeded true in preseed.cfg.
#
# Confirm behaviour: ONLY ask the confirm prompt when the password came from
# an OPERATOR (no ncz_password= override). Unattended runs are authoritative
# and not required to type the same thing twice; the KVM install gate's
# ncz_password= takes this path. Same for the password prompt itself when
# the run is unattended (KVM gates), per hostname-suggest.sh's pattern.
CHOSEN_PASS=""
if [ -n "$OVR_PASS" ]; then
    CHOSEN_PASS="$OVR_PASS"
    log "cmdline override: password set (not echoed); confirm prompt skipped for unattended"
elif [ "$_unattended" = 1 ] && db_get passwd/user-password 2>/dev/null && [ -n "$RET" ]; then
    # Same as the username: keep a password preseeded through passwd/user-password.
    CHOSEN_PASS="$RET"
    log "unattended: keeping preseeded password (not echoed)"
elif [ "$NCZ_PROMPT" = "--prompt" ] && [ "$_unattended" = 0 ]; then
    # Newline-in-description is NOT supported for Type: password, so this
    # template only carries a single-line prompt title.
    cat > /tmp/ncz-password.templates <<TPL
Template: ncz/password
Type: password
Description: $(ncz_ui_brand) - choose a PASSWORD for ${CHOSEN_USER} (will be asked again to confirm)

Template: ncz/password-confirm
Type: password
Description: $(ncz_ui_brand) - type the same PASSWORD again for ${CHOSEN_USER} (confirm)
TPL
    if debconf-loadtemplate ncz /tmp/ncz-password.templates 2>/dev/null; then
        db_fset    ncz/password seen false 2>/dev/null || true
        db_settitle ncz/password 2>/dev/null
        if db_input critical ncz/password && db_go; then
            db_get ncz/password && CHOSEN_PASS="$RET"
        else
            log "WARNING: password prompt could not be shown/completed -- leaving unset (no password; the diag account is the lockout backstop)"
        fi
        if [ -n "$CHOSEN_PASS" ]; then
            db_fset    ncz/password-confirm seen false 2>/dev/null || true
            db_settitle ncz/password-confirm 2>/dev/null
            if db_input critical ncz/password-confirm && db_go; then
                db_get ncz/password-confirm && _confirm="$RET"
                if [ "$_confirm" != "$CHOSEN_PASS" ]; then
                    log "WARNING: password and confirm do not match -- leaving password unset (operator can set one from the live system)"
                    CHOSEN_PASS=""
                fi
            else
                log "WARNING: password-confirm prompt could not be shown/completed -- leaving unset"
                CHOSEN_PASS=""
            fi
        fi
    else
        log "WARNING: could not load password template -- leaving unset"
    fi
fi

log "USER = $CHOSEN_USER  PASSWORD = $([ -n "$CHOSEN_PASS" ] && echo set || echo UNSET)"

# --- push the choice into the real d-i debconf questions --------------------
# Mark d-i's passwd/* questions seen so user-setup does not re-prompt.
db_set  passwd/root-login false                    2>/dev/null || true
db_fset passwd/root-login seen true                2>/dev/null || true
db_set  passwd/make-user true                      2>/dev/null || true
db_fset passwd/make-user seen true                 2>/dev/null || true
db_set  passwd/username "$CHOSEN_USER"             2>/dev/null || true
db_fset passwd/username seen true                  2>/dev/null || true
db_set  passwd/user-fullname "$CHOSEN_USER"        2>/dev/null || true
db_fset passwd/user-fullname seen true             2>/dev/null || true
db_set  passwd/user-password "$CHOSEN_PASS"        2>/dev/null || true
db_fset passwd/user-password seen true             2>/dev/null || true
db_set  passwd/user-password-again "$CHOSEN_PASS"  2>/dev/null || true
db_fset passwd/user-password-again seen true       2>/dev/null || true
db_set  passwd/user-default-groups "audio cdrom video plugdev netdev sudo dialout" 2>/dev/null || true
db_fset passwd/user-default-groups seen true       2>/dev/null || true
db_set  user-setup/allow-password-weak true        2>/dev/null || true
db_fset user-setup/allow-password-weak seen true   2>/dev/null || true
db_set  user-setup/encrypt-home false              2>/dev/null || true
db_fset user-setup/encrypt-home seen true         2>/dev/null || true

# stash for post-install hooks / diagnostics
cat > /tmp/ncz-user <<USER
${CHOSEN_USER}
${CHOSEN_PASS}
USER
chmod 0600 /tmp/ncz-user
log "chooser complete: username=$CHOSEN_USER password=$([ -n "$CHOSEN_PASS" ] && echo set || echo UNSET)"
exit 0