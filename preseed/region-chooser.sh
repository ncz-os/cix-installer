#!/bin/sh
# region-chooser.sh -- NCZ installer interactive REGION selection.
# Invoked from partman/early_command (see preseed.cfg) as the FIRST NCZ dialog
# the operator sees (operator 2026-10-06: "the region should be chosen along
# with the first question asked"): region, then username + password, then
# components, then disk + fs. The hostname is generated, never asked.
#
# ONCE PER BOOT: a completed run leaves $NCZ_TMP/.ncz-region-done; any later
# --prompt run (partman restarted, early_command replayed) re-applies the saved
# answer from $NCZ_TMP/ncz-region and never shows the dialog again.
#
# ONE PROMPT - FOUR d-i answers. The user picks a country; the script derives
# locale (lang_COUNTRY.UTF-8), country code (TZ country code), timezone (the
# IANA tz for the country's capital), and keyboard layout (top-level xkb code).
# Pinning all four into the matching d-i questions lets us drop d-i's native
# localechooser / keyboard-configuration / clock-setup question chain (4-7
# separate dialogs) and replace it with one branded prompt.
#
# WHY A CUSTOM CHOOSER (same reasoning as the disk + hostname + components
# choosers): the ISO boots d-i at priority=critical so finish-install auto-
# reboots cleanly. At critical priority d-i AUTO-ANSWERS its own locale/
# country/keymap questions from whatever is preseeded rather than showing them
# to the operator, so without this script the install lands on en_US.UTF-8 / us
# / UTC regardless of where the operator actually is. Same technique as
# disk-fs-chooser.sh and component-selector.sh: register our own cdebconf
# templates and db_input them at CRITICAL priority, which IS shown even under
# the critical threshold.
#
# UNLIKE the disk chooser this is NOT destructive: a locale/keymap mistake is
# fixable after install (dpkg-reconfigure locales / keyboard-configuration);
# an aborted install over a debconf hiccup here would be a worse trade. So the
# failure mode is "fall back to the en_US.UTF-8 / us / UTC default and continue
# the install", never abort.
#
# d-i can also raise THIS question chain on its own when its localechooser sees
# no preseed answer. By providing our own and marking all four d-i questions
# seen, we suppress d-i's chain entirely.
#
# TEST/UNATTENDED override: kernel cmdline `ncz_region=<code>` skips the prompt
# entirely. The override MUST be one of the offered REGIONS; misspelled or
# unknown values fall back to the prompt so a typo does not silently land the
# user on en_US.
#
# Persistence: writes the four chosen values into /tmp/ncz-region for late.sh
# (post-install/24-apt-sources.sh reads timezone); the install-time d-i answers
# are pushed via db_set + db_fset seen=true so d-i's localechooser /
# keyboard-configuration / clock-setup chains are not raised.

set +e

. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
NCZ_TMP="${NCZ_TMP:-/tmp}"
DONE="$NCZ_TMP/.ncz-region-done"

# shared NCZ dialog look (brand in the frame title, arch + build on the last body line); optional, never fatal
for _ncz_u in "${NCZ_UI_SH:-}" /ncz/ncz-ui.sh /cdrom/ncz-payload/ncz-ui.sh "$(dirname "$0")/ncz-ui.sh"; do
    [ -n "$_ncz_u" ] && [ -r "$_ncz_u" ] && . "$_ncz_u" && break
done
command -v ncz_ui_brand >/dev/null 2>&1 || { ncz_ui_brand() { echo "NCZ-OS"; }; ncz_ui_id() { echo ""; }; }

log() {
    echo "[ncz region] $*"
    # Progress chatter goes to VT3 (and the serial diag console); VT1/console is the
    # newt UI and raw lines written over it corrupt the screen. Failures stay visible.
    case "$*" in
        ABORT*|FATAL*|ERROR*) _vs="/dev/console /dev/tty1 /dev/tty3" ;;
        *) _vs="/dev/tty3" ;;
    esac
    for _v in $_vs; do
        echo "[ncz region] $*" > "$_v" 2>/dev/null || true
    done
}

# --- curated REGIONS table ---------------------------------------------------
# Format: <code>:<locale>:<country>:<timezone>:<keymap>:<label shown in the list>
# ONE ENTRY PER LINE (real newlines). r199 joined the entries with
# backslash-newline inside the double quotes, which the shell removes, so the
# table was ONE line: the dialog listed only "us", ncz_region=<anything but us>
# was rejected, and the "us" row's keymap field read "us ca" (the GU502LV laptop
# 2026-10-06: "REGION = en_US.UTF-8 ... keymap=us ca" pushed into
# keyboard-configuration/xkb-keymap). Labels must not contain a comma (cdebconf
# splits Choices on ", ").
#
# Operator feedback 2026-09-30: the operator requires ONE choice to set
# locale, country, timezone AND derive keyboard. Every entry below is
# hand-curated to match what d-i's native localechooser + keyboard-
# configuration + clock-setup chains would have arrived at for that
# country, with the keyboard layout being the conventional xkb top-level
# code (no variants; the override ncz_keymap=<code> still works for
# variants).
#
# Country codes are the ISO 3166-1 alpha-2 codes d-i's debian-installer/
# country expects; timezones are IANA tz database names.
#
# Add an entry here and the dialog offers it automatically (the multi-select
# code rebuilds the Choices: line from this list at runtime).
REGIONS="us:en_US.UTF-8:US:America/New_York:us:United States
ca:en_US.UTF-8:CA:America/Toronto:us:Canada
mx:es_MX.UTF-8:MX:America/Mexico_City:us:Mexico
br:pt_BR.UTF-8:BR:America/Sao_Paulo:br:Brazil
uk:en_GB.UTF-8:GB:Europe/London:gb:United Kingdom
ie:en_IE.UTF-8:IE:Europe/Dublin:gb:Ireland
de:de_DE.UTF-8:DE:Europe/Berlin:de:Germany
fr:fr_FR.UTF-8:FR:Europe/Paris:fr:France
es:es_ES.UTF-8:ES:Europe/Madrid:es:Spain
it:it_IT.UTF-8:IT:Europe/Rome:it:Italy
nl:nl_NL.UTF-8:NL:Europe/Amsterdam:nl:Netherlands
se:sv_SE.UTF-8:SE:Europe/Stockholm:se:Sweden
pl:pl_PL.UTF-8:PL:Europe/Warsaw:pl:Poland
ru:ru_RU.UTF-8:RU:Europe/Moscow:ru:Russia
jp:ja_JP.UTF-8:JP:Asia/Tokyo:jp:Japan
cn:zh_CN.UTF-8:CN:Asia/Shanghai:cn:China
kr:ko_KR.UTF-8:KR:Asia/Seoul:kr:South Korea
in:hi_IN.UTF-8:IN:Asia/Kolkata:us:India
au:en_US.UTF-8:AU:Australia/Sydney:us:Australia"

region_in_table() {
    _want="$1"
    printf '%s\n' "$REGIONS" | awk -F: -v w="$_want" '$1==w {found=1; exit} END{exit !found}'
}
region_field() {   # code field -> value
    printf '%s\n' "$REGIONS" | awk -F: -v c="$1" -v f="$2" '$1==c {print $f; exit}'
}

# --- read cmdline overrides --------------------------------------------------
CMD=$(cat "${NCZ_CMDLINE:-/proc/cmdline}" 2>/dev/null)
OVR_REGION=""; OVR_KEYMAP=""
_unattended=0
for tok in $CMD; do
    case "$tok" in
        ncz_region=*) OVR_REGION="${tok#ncz_region=}" ;;
        ncz_keymap=*) OVR_KEYMAP="${tok#ncz_keymap=}" ;;
        ncz_components=*|ncz_unattended=1) _unattended=1 ;;
    esac
done

# --- choose the region ----------------------------------------------------------
CHOSEN_LOCALE=""
CHOSEN_COUNTRY=""
CHOSEN_TZ=""
CHOSEN_KEYMAP=""

# Defer the dialog until partman/early_command (see component-selector.sh for
# the same pattern). When called WITHOUT --prompt (i.e. from the first
# early_command), we still register defaults so a prompt failure later does
# not leave the debconf database empty. The --prompt run is the one that
# shows the dialog to the operator.
NCZ_PROMPT="${1:-}"

if [ -n "$OVR_REGION" ]; then
    if region_in_table "$OVR_REGION"; then
        CHOSEN_LOCALE=$(region_field "$OVR_REGION" 2)
        CHOSEN_COUNTRY=$(region_field "$OVR_REGION" 3)
        CHOSEN_TZ=$(region_field "$OVR_REGION" 4)
        CHOSEN_KEYMAP=$(region_field "$OVR_REGION" 5)
        log "cmdline override: region=$OVR_REGION locale=$CHOSEN_LOCALE country=$CHOSEN_COUNTRY tz=$CHOSEN_TZ keymap=$CHOSEN_KEYMAP"
    else
        log "WARNING: ncz_region=$OVR_REGION is not an offered region -- falling back to prompt"
    fi
fi

# Without --prompt: register defaults and exit. The partman/early_command
# run is the one that prompts the operator. This split (the same one
# component-selector.sh + hostname-suggest.sh use) keeps the boot-time silent
# stretch free of any operator-blocking dialog.
if [ "$NCZ_PROMPT" != "--prompt" ]; then
    CHOSEN_LOCALE="${CHOSEN_LOCALE:-en_US.UTF-8}"
    CHOSEN_COUNTRY="${CHOSEN_COUNTRY:-US}"
    CHOSEN_TZ="${CHOSEN_TZ:-America/New_York}"
    CHOSEN_KEYMAP="${CHOSEN_KEYMAP:-us}"
    db_set  debian-installer/locale "$CHOSEN_LOCALE" 2>/dev/null || true
    db_fset debian-installer/locale seen true        2>/dev/null || true
    db_set  debian-installer/language "en"           2>/dev/null || true
    db_fset debian-installer/language seen true      2>/dev/null || true
    db_set  debian-installer/country "$CHOSEN_COUNTRY" 2>/dev/null || true
    db_fset debian-installer/country seen true        2>/dev/null || true
    db_set  keyboard-configuration/xkb-keymap "$CHOSEN_KEYMAP" 2>/dev/null || true
    db_fset keyboard-configuration/xkb-keymap seen true        2>/dev/null || true
    db_set  keyboard-configuration/layoutcode "$CHOSEN_KEYMAP" 2>/dev/null || true
    db_fset keyboard-configuration/layoutcode seen true        2>/dev/null || true
    db_set  time/zone "$CHOSEN_TZ"                   2>/dev/null || true
    db_fset time/zone seen true                      2>/dev/null || true
    log "interactive install: the region dialog is the first NCZ dialog, shown in partman/early_command (en_US until then)"
    exit 0
fi

# Already answered this boot: re-apply the saved answer, never ask again.
if [ -z "$CHOSEN_LOCALE" ] && [ -e "$DONE" ] && [ -s "$NCZ_TMP/ncz-region" ]; then
    { read -r CHOSEN_LOCALE; read -r CHOSEN_COUNTRY; read -r CHOSEN_TZ; read -r CHOSEN_KEYMAP; } < "$NCZ_TMP/ncz-region"
    log "already answered this boot: re-applying region locale=$CHOSEN_LOCALE (no dialog)"
fi

if [ -z "$CHOSEN_LOCALE" ] && [ "$NCZ_PROMPT" = "--prompt" ] && [ "$_unattended" = 0 ]; then
    # Choices-C carries the region codes (what db_get returns and Default names);
    # Choices carries the country names the operator reads. Default us = Enter
    # accepts United States / en_US / us keyboard.
    CHOICES_C=$(printf '%s\n' "$REGIONS" | awk -F: 'NF>=6 {printf "%s%s", (n++ ? ", " : ""), $1}')
    CHOICES=$(printf '%s\n' "$REGIONS" | awk -F: 'NF>=6 {printf "%s%s", (n++ ? ", " : ""), $6}')
    cat > "$NCZ_TMP/ncz-region.templates" <<TPL
Template: ncz/region
Type: select
Choices-C: ${CHOICES_C}
Choices: ${CHOICES}
Default: us
Description: $(ncz_ui_brand) - select your REGION
 Pick your country. NCZ-OS uses it to set the language, timezone and
 keyboard layout in one step. Press Enter to accept United States.
 .
 $(ncz_ui_id)
TPL
    if debconf-loadtemplate ncz "$NCZ_TMP/ncz-region.templates" 2>/dev/null; then
        db_set     ncz/region us 2>/dev/null || true
        db_fset    ncz/region seen false     || true
        db_settitle ncz/region 2>/dev/null
        if db_input critical ncz/region && db_go; then
            db_get ncz/region && CHOSEN_REGION="$RET"
        else
            log "WARNING: region prompt could not be shown/completed -- using default"
        fi
    else
        log "WARNING: could not load region template -- using default"
    fi
    if [ -n "$CHOSEN_REGION" ] && region_in_table "$CHOSEN_REGION"; then
        CHOSEN_LOCALE=$(region_field "$CHOSEN_REGION" 2)
        CHOSEN_COUNTRY=$(region_field "$CHOSEN_REGION" 3)
        CHOSEN_TZ=$(region_field "$CHOSEN_REGION" 4)
        CHOSEN_KEYMAP=$(region_field "$CHOSEN_REGION" 5)
    fi
fi

# ncz_keymap= override (separate from ncz_region) lets a power-user pin a
# variant keymap. Otherwise we use what the REGIONS table gave us.
if [ -n "$OVR_KEYMAP" ]; then
    CHOSEN_KEYMAP="$OVR_KEYMAP"
    log "cmdline override: keymap=$CHOSEN_KEYMAP"
fi

# --- final safety net (no prompt path or a prompt that failed) --------------
[ -n "$CHOSEN_LOCALE" ] || CHOSEN_LOCALE="en_US.UTF-8"
[ -n "$CHOSEN_COUNTRY" ] || CHOSEN_COUNTRY="US"
[ -n "$CHOSEN_TZ" ]      || CHOSEN_TZ="America/New_York"
[ -n "$CHOSEN_KEYMAP" ]  || CHOSEN_KEYMAP="us"

LANG_CODE=$(printf '%s' "$CHOSEN_LOCALE" | cut -d_ -f1)
log "REGION = $CHOSEN_LOCALE (lang=$LANG_CODE country=$CHOSEN_COUNTRY tz=$CHOSEN_TZ keymap=$CHOSEN_KEYMAP)"

# --- push the choice into the real d-i debconf questions ---------------------
# d-i would normally raise 4 separate questions (locale, country, keymap layout,
# timezone). Mark them ALL seen with our derived answers so none of them are
# shown -- the ONE region prompt above is the only dialog this stage raises.
db_set  debian-installer/locale "$CHOSEN_LOCALE" 2>/dev/null || true
db_fset debian-installer/locale seen true        2>/dev/null || true
db_set  debian-installer/language "$LANG_CODE"   2>/dev/null || true
db_fset debian-installer/language seen true      2>/dev/null || true
db_set  debian-installer/country "$CHOSEN_COUNTRY" 2>/dev/null || true
db_fset debian-installer/country seen true       2>/dev/null || true
db_set  keyboard-configuration/xkb-keymap "$CHOSEN_KEYMAP" 2>/dev/null || true
db_fset keyboard-configuration/xkb-keymap seen true        2>/dev/null || true
db_set  keyboard-configuration/layoutcode "$CHOSEN_KEYMAP" 2>/dev/null || true
db_fset keyboard-configuration/layoutcode seen true        2>/dev/null || true
db_set  keyboard-configuration/variant ""        2>/dev/null || true
db_fset keyboard-configuration/variant seen true 2>/dev/null || true
db_set  clock-setup/utc true                     2>/dev/null || true
db_fset clock-setup/utc seen true                2>/dev/null || true
db_set  time/zone "$CHOSEN_TZ"                   2>/dev/null || true
db_fset time/zone seen true                      2>/dev/null || true

# stash for post-install hooks / diagnostics (same convention as
# /tmp/ncz-target-disk, /tmp/ncz-root-fs in disk-fs-chooser.sh and
# /tmp/ncz-locale in the retired locale-keyboard-chooser.sh)
cat > "$NCZ_TMP/ncz-region" <<REGION
${CHOSEN_LOCALE}
${CHOSEN_COUNTRY}
${CHOSEN_TZ}
${CHOSEN_KEYMAP}
REGION
# A --prompt run (dialog answered, override applied, or unattended default)
# completes the region step for this boot.
[ "$NCZ_PROMPT" = "--prompt" ] && : > "$DONE"
log "chooser complete: locale=$CHOSEN_LOCALE country=$CHOSEN_COUNTRY tz=$CHOSEN_TZ keymap=$CHOSEN_KEYMAP"
exit 0