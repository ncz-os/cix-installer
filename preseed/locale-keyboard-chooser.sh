#!/bin/sh
# locale-keyboard-chooser.sh — NCZ installer interactive LOCALE + KEYBOARD
# LAYOUT selection. Invoked from preseed/early_command (see preseed-ubuntu.cfg),
# BEFORE d-i's own localization step consumes debian-installer/locale and
# keyboard-configuration/xkb-keymap.
#
# WHY a custom chooser (same reasoning as disk-fs-chooser.sh): the ISO boots
# d-i at priority=critical so finish-install auto-reboots cleanly. At critical
# priority d-i's own native language/country/locale and keyboard-detection
# steps are auto-answered from whatever is preseeded rather than shown, so a
# hardcoded `debian-installer/locale ... seen true` (the prior default) meant
# every install was silently forced to en_US.UTF-8 / us regardless of the
# operator. Same technique as the disk/filesystem chooser: register our own
# cdebconf templates and db_input them at CRITICAL priority, which IS shown
# even under a critical threshold.
#
# UNLIKE the disk chooser this is NOT a destructive operation, so failure mode
# is "fall back to the en_US.UTF-8 / us default and continue the install",
# never abort. A locale/keyboard mistake is fixable after install
# (raspi-config-style `dpkg-reconfigure locales` / `keyboard-configuration`);
# an aborted install over a debconf hiccup here would be a worse trade.
#
# TEST/UNATTENDED override: if the kernel cmdline carries `ncz_locale=<loc>`
# and/or `ncz_keymap=<layout>`, the matching prompt is skipped — but the
# override MUST be one of the offered candidates (CANDIDATES_LOCALE /
# CANDIDATES_KEYMAP below). This is how the KVM install gate and any other
# unattended pipeline runs without a human present.
set +e

. /usr/share/debconf/confmodule 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true

log() { echo "[ncz locale] $*"; echo "[ncz locale] $*" > /dev/tty3 2>/dev/null || true; }

# --- read cmdline overrides -------------------------------------------------
CMD=$(cat /proc/cmdline 2>/dev/null)
OVR_LOCALE=""; OVR_KEYMAP=""
for tok in $CMD; do
    case "$tok" in
        ncz_locale=*) OVR_LOCALE="${tok#ncz_locale=}" ;;
        ncz_keymap=*) OVR_KEYMAP="${tok#ncz_keymap=}" ;;
    esac
done

# --- curated candidate lists -------------------------------------------------
# Deliberately curated, not the full ~700-entry Debian locale/xkb universe —
# same "enumerate real candidates" spirit as disk-fs-chooser.sh's whole-disk
# list, sized for a select menu a human can actually read. Each locale entry
# is "locale:Description"; xkb entries are "layout:Description".
LOCALES="\
en_US.UTF-8:English (United States)
en_GB.UTF-8:English (United Kingdom)
de_DE.UTF-8:Deutsch (Germany)
fr_FR.UTF-8:Français (France)
es_ES.UTF-8:Español (Spain)
it_IT.UTF-8:Italiano (Italy)
pt_BR.UTF-8:Português (Brazil)
pt_PT.UTF-8:Português (Portugal)
nl_NL.UTF-8:Nederlands (Netherlands)
sv_SE.UTF-8:Svenska (Sweden)
pl_PL.UTF-8:Polski (Poland)
ru_RU.UTF-8:Русский (Russia)
ja_JP.UTF-8:日本語 (Japan)
zh_CN.UTF-8:简体中文 (China)
zh_TW.UTF-8:繁體中文 (Taiwan)
ko_KR.UTF-8:한국어 (Korea)"

KEYMAPS="\
us:English (US)
gb:English (UK)
de:German
fr:French
es:Spanish
it:Italian
br:Portuguese (Brazil)
pt:Portuguese
nl:Dutch
se:Swedish
pl:Polish
ru:Russian
jp:Japanese
cn:Chinese
kr:Korean"

# language/country derived from the chosen locale's own name — every entry
# above is <lang>_<COUNTRY>.UTF-8, so split on '_' and '.' rather than
# maintaining a second parallel table that could drift out of sync.
derive_lang()    { echo "$1" | cut -d_ -f1 ; }
derive_country() { echo "$1" | cut -d_ -f2 | cut -d. -f1 ; }

locale_in_candidates() {
    _want="$1"
    printf '%s\n' "$LOCALES" | cut -d: -f1 | grep -qx "$_want"
}
keymap_in_candidates() {
    _want="$1"
    printf '%s\n' "$KEYMAPS" | cut -d: -f1 | grep -qx "$_want"
}

# --- choose the locale -------------------------------------------------------
CHOSEN_LOCALE=""
if [ -n "$OVR_LOCALE" ]; then
    if locale_in_candidates "$OVR_LOCALE"; then
        CHOSEN_LOCALE="$OVR_LOCALE"
        log "cmdline override: locale = $CHOSEN_LOCALE"
    else
        log "WARNING: ncz_locale=$OVR_LOCALE is not an offered candidate — falling back to prompt"
    fi
fi
if [ -z "$CHOSEN_LOCALE" ]; then
    CHOICES=""
    LONG=""
    printf '%s\n' "$LOCALES" | while IFS=: read -r code desc; do :; done # posix sh has no here-loop var leak guard; use for instead
    _oldifs=$IFS; IFS='
'
    for line in $LOCALES; do
        code=${line%%:*}; desc=${line#*:}
        [ -z "$CHOICES" ] && CHOICES="$code" || CHOICES="$CHOICES, $code"
        LONG="$LONG  $code  —  $desc\\n"
    done
    IFS=$_oldifs
    cat > /tmp/ncz-locale.templates <<TPL
Template: ncz/locale
Type: select
Choices: ${CHOICES}
Default: en_US.UTF-8
Description: NCZ-OS install — select your LOCALE
 Choose the language + region for the installed system.
 .
 ${LONG}
TPL
    if debconf-loadtemplate ncz /tmp/ncz-locale.templates 2>/dev/null; then
        db_set     ncz/locale en_US.UTF-8 2>/dev/null || true
        db_fset    ncz/locale seen false             || true
        db_settitle ncz/locale 2>/dev/null
        if db_input critical ncz/locale && db_go; then
            db_get ncz/locale && CHOSEN_LOCALE="$RET"
        else
            log "WARNING: locale prompt could not be shown/completed — using default"
        fi
    else
        log "WARNING: could not load locale template — using default"
    fi
fi
[ -n "$CHOSEN_LOCALE" ] && locale_in_candidates "$CHOSEN_LOCALE" || CHOSEN_LOCALE="en_US.UTF-8"

# --- choose the keyboard layout ----------------------------------------------
CHOSEN_KEYMAP=""
if [ -n "$OVR_KEYMAP" ]; then
    if keymap_in_candidates "$OVR_KEYMAP"; then
        CHOSEN_KEYMAP="$OVR_KEYMAP"
        log "cmdline override: keymap = $CHOSEN_KEYMAP"
    else
        log "WARNING: ncz_keymap=$OVR_KEYMAP is not an offered candidate — falling back to prompt"
    fi
fi
if [ -z "$CHOSEN_KEYMAP" ]; then
    CHOICES=""
    LONG=""
    _oldifs=$IFS; IFS='
'
    for line in $KEYMAPS; do
        code=${line%%:*}; desc=${line#*:}
        [ -z "$CHOICES" ] && CHOICES="$code" || CHOICES="$CHOICES, $code"
        LONG="$LONG  $code  —  $desc\\n"
    done
    IFS=$_oldifs
    cat > /tmp/ncz-keymap.templates <<TPL
Template: ncz/keymap
Type: select
Choices: ${CHOICES}
Default: us
Description: NCZ-OS install — select your KEYBOARD LAYOUT
 Choose the keyboard layout for the installed system.
 .
 ${LONG}
TPL
    if debconf-loadtemplate ncz /tmp/ncz-keymap.templates 2>/dev/null; then
        db_set     ncz/keymap us 2>/dev/null || true
        db_fset    ncz/keymap seen false     || true
        db_settitle ncz/keymap 2>/dev/null
        if db_input critical ncz/keymap && db_go; then
            db_get ncz/keymap && CHOSEN_KEYMAP="$RET"
        else
            log "WARNING: keymap prompt could not be shown/completed — using default"
        fi
    else
        log "WARNING: could not load keymap template — using default"
    fi
fi
[ -n "$CHOSEN_KEYMAP" ] && keymap_in_candidates "$CHOSEN_KEYMAP" || CHOSEN_KEYMAP="us"

LANG_CODE=$(derive_lang "$CHOSEN_LOCALE")
COUNTRY_CODE=$(derive_country "$CHOSEN_LOCALE")
log "LOCALE = $CHOSEN_LOCALE (lang=$LANG_CODE country=$COUNTRY_CODE)   KEYMAP = $CHOSEN_KEYMAP"

# --- push the choice into the real d-i debconf questions ---------------------
db_set  debian-installer/locale "$CHOSEN_LOCALE" || true
db_fset debian-installer/locale seen true        || true
db_set  debian-installer/language "$LANG_CODE"   || true
db_fset debian-installer/language seen true      || true
db_set  debian-installer/country "$COUNTRY_CODE" || true
db_fset debian-installer/country seen true       || true
db_set  keyboard-configuration/xkb-keymap "$CHOSEN_KEYMAP" || true
db_fset keyboard-configuration/xkb-keymap seen true        || true
db_set  keyboard-configuration/layoutcode "$CHOSEN_KEYMAP" || true
db_fset keyboard-configuration/layoutcode seen true        || true

# stash for post-install hooks / diagnostics (same convention as
# /tmp/ncz-target-disk, /tmp/ncz-root-fs in disk-fs-chooser.sh)
echo "$CHOSEN_LOCALE" > /tmp/ncz-locale 2>/dev/null || true
echo "$CHOSEN_KEYMAP" > /tmp/ncz-keymap 2>/dev/null || true
log "chooser complete: locale=$CHOSEN_LOCALE keymap=$CHOSEN_KEYMAP"
exit 0
