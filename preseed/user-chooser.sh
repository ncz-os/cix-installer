#!/bin/sh
# user-chooser.sh -- NCZ installer interactive USERNAME + PASSWORD (with confirm)
# selection. Invoked from partman/early_command (see preseed.cfg) with
# --prompt, right after the region dialog (operator flow 2026-10-06: region,
# username, password + confirm, components, disk + fs; hostname automatic).
#
# WITHOUT --prompt (preseed/early_command, both runs) it only SEEDS d-i's own
# passwd/* questions so user-setup-udeb -- a main-menu step that runs BEFORE
# partitioning -- does not ask them: PEGASUS 2026-10-06 spent 14:20:05-14:20:31
# in user-setup-udeb (full name, username, password, verify: user-setup-ask
# asks all four at critical priority when they are unseen) and then this
# script asked username and password again. The seed never replaces a value
# that is already there (kernel-cmdline passwd/username=... from the KVM gates
# wins), and parks a locked placeholder in passwd/user-password-crypted only
# when no password is known yet, which is what makes user-setup-ask skip its
# password + verify questions; the --prompt run clears it once it has a real
# password.
#
# ONCE PER BOOT: a completed --prompt run leaves $NCZ_TMP/.ncz-user-done; a
# later --prompt run re-applies $NCZ_TMP/ncz-user and never asks again.
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

. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
NCZ_TMP="${NCZ_TMP:-/tmp}"
DONE="$NCZ_TMP/.ncz-user-done"
# user-setup-apply uses passwd/user-password-crypted whenever it is non-empty; "!" is a locked password.
PW_PLACEHOLDER='!'


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
CMD=$(cat "${NCZ_CMDLINE:-/proc/cmdline}" 2>/dev/null)
OVR_USER=""; OVR_PASS=""
_unattended=0
for tok in $CMD; do
    case "$tok" in
        ncz_username=*) OVR_USER="${tok#ncz_username=}" ;;
        ncz_password=*) OVR_PASS="${tok#ncz_password=}" ;;
        ncz_components=*|ncz_unattended=1) _unattended=1 ;;
    esac
done

# The dialogs are shown only by the --prompt run in partman/early_command.
# Without --prompt (preseed/early_command) the script only seeds d-i's passwd/*
# questions (below) and never prompts.
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

# --- seed mode (no --prompt): stop user-setup-udeb from asking ---------------
# The first early_command runs before anna has loaded user-setup-udeb, so its passwd/* templates may not exist
# yet and db_set would fail. A missing question is seeded with debconf-set-selections, the same call d-i's own
# file-preseed (and the kernel-cmdline passwd/username=...) uses: it creates the question on a placeholder
# template, marks it seen, and the value survives when user-setup-udeb loads the real template.
_seed_keep_or_add() {   # question type value -> keep a non-empty value (mark seen), else queue the seed line
    if db_get "$1" 2>/dev/null && [ -n "$RET" ]; then
        db_fset "$1" seen true 2>/dev/null || true
        return 1
    fi
    printf 'd-i %s %s %s\n' "$1" "$2" "$3" >> "$_seedf"
}
if [ "$NCZ_PROMPT" != "--prompt" ]; then
    command -v db_get >/dev/null 2>&1 || exit 0
    if [ -e "$DONE" ]; then
        log "seed: already answered this boot, leaving passwd/* as set"
        exit 0
    fi
    _seedf="$NCZ_TMP/ncz-user.seed"; ( umask 077; : > "$_seedf" )   # may carry ncz_password=: never world-readable
    _su=ncz; [ -n "$OVR_USER" ] && is_valid_username "$OVR_USER" && _su="$OVR_USER"
    _seed_keep_or_add passwd/username string "$_su"
    _seed_keep_or_add passwd/user-fullname string "$_su"
    if [ -n "$OVR_PASS" ]; then
        _seed_keep_or_add passwd/user-password password "$OVR_PASS"
        _seed_keep_or_add passwd/user-password-again password "$OVR_PASS"
    elif ! { db_get passwd/user-password 2>/dev/null && [ -n "$RET" ]; }; then
        # no password known yet: a locked placeholder makes user-setup-ask skip password + verify
        _seed_keep_or_add passwd/user-password-crypted password "$PW_PLACEHOLDER"
    fi
    if [ -s "$_seedf" ]; then
        if "${NCZ_SET_SELECTIONS:-debconf-set-selections}" "$_seedf" 2>/dev/null; then
            log "seed: passwd/* preseeded + seen so user-setup-udeb does not ask (the NCZ dialogs ask right before partitioning)"
        else
            log "WARNING: seed: debconf-set-selections failed -- d-i user-setup may ask for the account itself"
        fi
    else
        log "seed: passwd/* already preseeded, marked seen"
    fi
    rm -f "$_seedf"
    exit 0
fi

# --- already answered this boot: re-apply, never ask again ------------------
CHOSEN_USER=""
CHOSEN_PASS=""
_reapplied=0
if [ -e "$DONE" ] && [ -s "$NCZ_TMP/ncz-user" ]; then
    { read -r CHOSEN_USER; read -r CHOSEN_PASS; } < "$NCZ_TMP/ncz-user"
    is_valid_username "$CHOSEN_USER" && _reapplied=1
    log "already answered this boot: re-applying username=$CHOSEN_USER (no dialog)"
fi

# --- username --------------------------------------------------------------
# Skip the interactive prompt when this run is unattended (KVM gates pass
# ncz_components= or ncz_unattended=1 on the kernel cmdline; mirroring
# hostname-suggest.sh's pattern so the gate does not stall on the prompt).
if [ "$_reapplied" = 0 ] && [ -n "$OVR_USER" ]; then
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
    cat > "$NCZ_TMP/ncz-username.templates" <<TPL
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
    if debconf-loadtemplate ncz "$NCZ_TMP/ncz-username.templates" 2>/dev/null; then
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
if [ "$_reapplied" = 1 ]; then
    :
elif [ -n "$OVR_PASS" ]; then
    CHOSEN_PASS="$OVR_PASS"
    log "cmdline override: password set (not echoed); confirm prompt skipped for unattended"
elif [ "$_unattended" = 1 ] && db_get passwd/user-password 2>/dev/null && [ -n "$RET" ]; then
    # Same as the username: keep a password preseeded through passwd/user-password.
    CHOSEN_PASS="$RET"
    log "unattended: keeping preseeded password (not echoed)"
elif [ "$NCZ_PROMPT" = "--prompt" ] && [ "$_unattended" = 0 ]; then
    # Newline-in-description is NOT supported for Type: password, so this
    # template only carries a single-line prompt title.
    cat > "$NCZ_TMP/ncz-password.templates" <<TPL
Template: ncz/password
Type: password
Description: $(ncz_ui_brand) - choose a PASSWORD for ${CHOSEN_USER} (will be asked again to confirm)

Template: ncz/password-confirm
Type: password
Description: $(ncz_ui_brand) - type the same PASSWORD again for ${CHOSEN_USER} (confirm)
TPL
    if debconf-loadtemplate ncz "$NCZ_TMP/ncz-password.templates" 2>/dev/null; then
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
# The seed's locked placeholder must not outrank the real password (user-setup-apply prefers -crypted). With no
# password at all it stays: the account is created locked instead of user-setup failing on an empty password.
if [ -n "$CHOSEN_PASS" ] && db_get passwd/user-password-crypted 2>/dev/null && [ "$RET" = "$PW_PLACEHOLDER" ]; then
    db_set passwd/user-password-crypted "" 2>/dev/null || true
fi
db_set  passwd/user-default-groups "audio cdrom video plugdev netdev sudo dialout" 2>/dev/null || true
db_fset passwd/user-default-groups seen true       2>/dev/null || true
db_set  user-setup/allow-password-weak true        2>/dev/null || true
db_fset user-setup/allow-password-weak seen true   2>/dev/null || true
db_set  user-setup/encrypt-home false              2>/dev/null || true
db_fset user-setup/encrypt-home seen true         2>/dev/null || true

# stash for post-install hooks / diagnostics
( umask 077; cat > "$NCZ_TMP/ncz-user" <<USER
${CHOSEN_USER}
${CHOSEN_PASS}
USER
)
chmod 0600 "$NCZ_TMP/ncz-user"
: > "$DONE"
log "chooser complete: username=$CHOSEN_USER password=$([ -n "$CHOSEN_PASS" ] && echo set || echo UNSET)"
exit 0