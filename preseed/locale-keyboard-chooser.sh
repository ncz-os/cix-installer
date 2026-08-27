#!/bin/sh
# locale-keyboard-chooser.sh — retired NCZ installer interactive LOCALE +
# KEYBOARD LAYOUT selection.
#
# This script is intentionally no longer invoked by preseed.cfg or staged into
# the ISO. Human installs now leave debian-installer/locale and
# keyboard-configuration/* unanswered so Debian's native localechooser and
# keyboard-configuration dialogs run. build/kvm-install-gate.sh applies
# standard d-i locale/keymap answers only to its throwaway qemutest ISO.
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

# --- candidate lists ---------------------------------------------------------
# LOCALES is every UTF-8 charmap entry from this build host's own
# /usr/share/i18n/SUPPORTED (`awk '$2=="UTF-8"{print $1}' | sort`) — the exact
# list stock Debian's own locales package offers, not a hand-picked subset.
# Operator feedback 2026-08-20: an earlier curated 16-entry version of this
# list was rejected ("we want what debian uses"). Regenerate this block if
# the build host's Debian version changes what SUPPORTED contains; it is
# static data, not queried at install time (the d-i busybox environment this
# script actually runs in has no /usr/share/i18n/SUPPORTED of its own).
#
# KEYMAPS stays a curated top-level-country shortlist — console-setup's own
# full xkb layout+variant space is a two-level (layout, variant) structure
# that doesn't fit this flat-select technique as directly as a locale code
# does; a curated set of common layouts plus the ncz_keymap= override for
# anything else is the pragmatic middle ground here.
LOCALES="\
aa_DJ.UTF-8
aa_ER
aa_ET
af_ZA.UTF-8
agr_PE
ak_GH
am_ET
an_ES.UTF-8
anp_IN
ar_AE.UTF-8
ar_BH.UTF-8
ar_DZ.UTF-8
ar_EG.UTF-8
ar_IN
ar_IQ.UTF-8
ar_JO.UTF-8
ar_KW.UTF-8
ar_LB.UTF-8
ar_LY.UTF-8
ar_MA.UTF-8
ar_OM.UTF-8
ar_QA.UTF-8
ar_SA.UTF-8
ar_SD.UTF-8
ar_SS
ar_SY.UTF-8
ar_TN.UTF-8
ar_YE.UTF-8
as_IN
ast_ES.UTF-8
ayc_PE
az_AZ
az_IR
be_BY@latin
be_BY.UTF-8
bem_ZM
ber_DZ
ber_MA
bg_BG.UTF-8
bhb_IN.UTF-8
bho_IN
bho_NP
bi_VU
bn_BD
bn_IN
bo_CN
bo_IN
br_FR.UTF-8
brx_IN
bs_BA.UTF-8
byn_ER
ca_AD.UTF-8
ca_ES.UTF-8
ca_ES@valencia
ca_FR.UTF-8
ca_IT.UTF-8
ce_RU
chr_US
ckb_IQ
cmn_TW
crh_RU
crh_UA
csb_PL
cs_CZ.UTF-8
C.UTF-8
cv_RU
cy_GB.UTF-8
da_DK.UTF-8
de_AT.UTF-8
de_BE.UTF-8
de_CH.UTF-8
de_DE.UTF-8
de_IT.UTF-8
de_LI.UTF-8
de_LU.UTF-8
doi_IN
dsb_DE
dv_MV
dz_BT
el_CY.UTF-8
el_GR.UTF-8
en_AG
en_AU.UTF-8
en_BW.UTF-8
en_CA.UTF-8
en_DK.UTF-8
en_GB.UTF-8
en_HK.UTF-8
en_IE.UTF-8
en_IL
en_IN
en_NG
en_NZ.UTF-8
en_PH.UTF-8
en_SC.UTF-8
en_SG.UTF-8
en_US.UTF-8
en_ZA.UTF-8
en_ZM
en_ZW.UTF-8
eo
es_AR.UTF-8
es_BO.UTF-8
es_CL.UTF-8
es_CO.UTF-8
es_CR.UTF-8
es_CU
es_DO.UTF-8
es_EC.UTF-8
es_ES.UTF-8
es_GT.UTF-8
es_HN.UTF-8
es_MX.UTF-8
es_NI.UTF-8
es_PA.UTF-8
es_PE.UTF-8
es_PR.UTF-8
es_PY.UTF-8
es_SV.UTF-8
es_US.UTF-8
es_UY.UTF-8
es_VE.UTF-8
et_EE.UTF-8
eu_ES.UTF-8
eu_FR.UTF-8
fa_IR
ff_SN
fi_FI.UTF-8
fil_PH
fo_FO.UTF-8
fr_BE.UTF-8
fr_CA.UTF-8
fr_CH.UTF-8
fr_FR.UTF-8
fr_LU.UTF-8
fur_IT
fy_DE
fy_NL
ga_IE.UTF-8
gbm_IN
gd_GB.UTF-8
gez_ER
gez_ER@abegede
gez_ET
gez_ET@abegede
gl_ES.UTF-8
gu_IN
gv_GB.UTF-8
hak_TW
ha_NG
he_IL.UTF-8
hif_FJ
hi_IN
hne_IN
hr_HR.UTF-8
hsb_DE.UTF-8
ht_HT
hu_HU.UTF-8
hy_AM
ia_FR
id_ID.UTF-8
ig_NG
ik_CA
is_IS.UTF-8
it_CH.UTF-8
it_IT.UTF-8
iu_CA
ja_JP.UTF-8
kab_DZ
ka_GE.UTF-8
kk_KZ.UTF-8
kl_GL.UTF-8
km_KH
kn_IN
kok_IN
ko_KR.UTF-8
ks_IN
ks_IN@devanagari
ku_TR.UTF-8
kv_RU
kw_GB.UTF-8
ky_KG
lb_LU
lg_UG.UTF-8
li_BE
lij_IT
li_NL
ln_CD
lo_LA
ltg_LV.UTF-8
lt_LT.UTF-8
lv_LV.UTF-8
lzh_TW
mag_IN
mai_IN
mai_NP
mdf_RU
mfe_MU
mg_MG.UTF-8
mhr_RU
mi_NZ.UTF-8
miq_NI
mjw_IN
mk_MK.UTF-8
ml_IN
mni_IN
mn_MN
mnw_MM
mr_IN
ms_MY.UTF-8
mt_MT.UTF-8
my_MM
nan_TW
nan_TW@latin
nb_NO.UTF-8
nds_DE
nds_NL
ne_NP
nhn_MX
niu_NU
niu_NZ
nl_AW
nl_BE.UTF-8
nl_NL.UTF-8
nn_NO.UTF-8
nr_ZA
nso_ZA
oc_FR.UTF-8
om_ET
om_KE.UTF-8
or_IN
os_RU
pa_IN
pap_AW
pap_CW
pa_PK
pl_PL.UTF-8
ps_AF
pt_BR.UTF-8
pt_PT.UTF-8
quz_PE
raj_IN
rif_MA
ro_RO.UTF-8
ru_RU.UTF-8
ru_UA.UTF-8
rw_RW
sah_RU
sa_IN
sat_IN
sc_IT
scn_IT
sd_IN
sd_IN@devanagari
se_NO
sgs_LT
shn_MM
shs_CA
sid_ET
si_LK
sk_SK.UTF-8
sl_SI.UTF-8
sm_WS
so_DJ.UTF-8
so_ET
so_KE.UTF-8
so_SO.UTF-8
sq_AL.UTF-8
sq_MK
sr_ME
sr_RS
sr_RS@latin
ssy_ER
ss_ZA
st_ZA.UTF-8
su_ID
sv_FI.UTF-8
sv_SE.UTF-8
sw_KE
sw_TZ
syr
szl_PL
ta_IN
ta_LK
tcy_IN.UTF-8
te_IN
tg_TJ.UTF-8
the_NP
th_TH.UTF-8
ti_ER
ti_ET
tig_ER
tk_TM
tl_PH.UTF-8
tn_ZA
tok
to_TO
tpi_PG
tr_CY.UTF-8
tr_TR.UTF-8
ts_ZA
tt_RU
tt_RU@iqtelif
ug_CN
uk_UA.UTF-8
unm_US
ur_IN
ur_PK
uz_UZ@cyrillic
uz_UZ.UTF-8
ve_ZA
vi_VN
wa_BE.UTF-8
wae_CH
wal_ET
wo_SN
xh_ZA.UTF-8
yi_US.UTF-8
yo_NG
yue_HK
yuw_PG
zgh_MA
zh_CN.UTF-8
zh_HK.UTF-8
zh_SG.UTF-8
zh_TW.UTF-8
zu_ZA.UTF-8"

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
derive_country() { echo "$1" | cut -d_ -f2 | cut -d. -f1 | cut -d@ -f1 ; }

locale_in_candidates() {
    _want="$1"
    printf '%s\n' "$LOCALES" | grep -qx "$_want"
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
    _oldifs=$IFS; IFS='
'
    for code in $LOCALES; do
        desc="$(derive_lang "$code") ($(derive_country "$code"))"
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
