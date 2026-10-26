#!/bin/bash
# test-server-branding.sh -- the Magnetar Server medium names its edition and skips the
# desktop component selector; a desktop medium is unchanged.
#
# 2026-10-26, the first real amd64 Magnetar Server install (cyclops): every installer screen
# said "NCZ-OS 26.10 Cygnus" (the desktop release codename) and the desktop component
# selector was shown. The server KVM gate sets never looked at the installer screens.
#
# Runs the REAL helpers against fixture media, no VM, no root:
#   1. post-install/lib/ncz-brand.sh: the edition string, the label, the medium decision
#   2. preseed/ncz-ui.sh: ncz_ui_brand / ncz_ui_variant / ncz_ui_step on both media
#   3. preseed/component-selector.sh --prompt: no dialog and the server record on a server
#      medium; the dialog and the desktop record on a desktop medium
#   4. preseed/late.sh: the installer label and progress / remove-media templates
#   5. post-install/50-brand.sh: os-release / issue identity, the motd title row
#   6. post-install/48-server-variant.sh: the server console banner (/etc/issue.d)
#   7. assets/refind/ncz-refind-refresh{,-amd64}.sh: the installed menu titles
#   8. build/iso/build-refind-esp.py: the installer boot menu's identity line
#   9. assets/ncz-cli.sh: `ncz version`
#  10. build/kvm-install-gate-gpt.sh: ncz_gate_server_brand (the installed-system assertion)
# On the pre-fix tree (4971507b) sections 2-9 fail: every server string carries "Cygnus" and
# the selector shows its dialog.
# shellcheck disable=SC1090,SC2209  # fixture paths are sourced by variable; DISH holds a command name
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/ncz-srv-brand.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
nocyg() { case "$2" in *[Cc]ygnus*) bad "$1 names Cygnus: [$2]" ;; *) ok "$1 has no Cygnus" ;; esac; }
# d-i runs these under busybox ash; use it when the host has one.
DISH=sh; command -v busybox >/dev/null 2>&1 && DISH="busybox sh"

. "$ROOT/release.conf"
DESK_LABEL="NCZ-OS $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"
SRV="Magnetar Server"                                   # short form: dialog titles
SRVF="NCZ-OS $NCZ_RELEASE_VERSION Magnetar Server"     # full form: where the desktop says "NCZ-OS 26.10 Cygnus"

# fixture media: a desktop and a server ncz-payload/ (the server one carries the fetch manifest)
mkmedium() { # dir server(0|1)
    mkdir -p "$1/post-install/lib"
    echo "2026.10.26-abc1234" > "$1/BUILD_VERSION"; echo amd64 > "$1/BUILD_ARCH"
    cp "$ROOT/release.conf" "$1/RELEASE"
    cp "$ROOT/post-install/lib/ncz-brand.sh" "$1/post-install/lib/ncz-brand.sh"
    [ "$2" = 1 ] && printf 'base.squashfs http://x/base.squashfs 0\n' > "$1/ncz-fetch-payload.manifest"
    return 0
}
mkmedium "$W/desk" 0; mkmedium "$W/srv" 1
mkdir -p "$W/srv-nolib"; cp -a "$W/srv/." "$W/srv-nolib/"; rm -f "$W/srv-nolib/post-install/lib/ncz-brand.sh"

# --- 1. the helper ---------------------------------------------------------------------------
H="$ROOT/post-install/lib/ncz-brand.sh"
eq "helper: NCZ_SERVER_EDITION" "$(. "$H"; echo "$NCZ_SERVER_EDITION")" "Magnetar Server"
eq "helper: desktop label passes through unchanged" "$(. "$H"; ncz_brand_label desktop "$DESK_LABEL" NCZ-OS 26.10)" "$DESK_LABEL"
eq "helper: desktop label keeps odd spacing/quotes" "$(. "$H"; ncz_brand_label desktop 'NCZ-OS 26.10 "Cygnus"  x' NCZ-OS)" 'NCZ-OS 26.10 "Cygnus"  x'
eq "helper: server label without a version" "$(. "$H"; ncz_brand_label server "$DESK_LABEL" NCZ-OS)" "NCZ-OS Magnetar Server"
eq "helper: server label" "$(. "$H"; ncz_brand_label server "" NCZ-OS "$NCZ_RELEASE_VERSION")" "$SRVF"
eq "helper: medium with fetch manifest is server" "$(. "$H"; ncz_brand_medium_variant "$W/srv")" server
eq "helper: medium without it is desktop" "$(. "$H"; ncz_brand_medium_variant "$W/desk")" desktop
mkdir -p "$W/inst"; echo server > "$W/inst/MEDIUM_VARIANT"
eq "helper: installed MEDIUM_VARIANT=server" "$(. "$H"; ncz_brand_medium_variant "$W/desk" "$W/inst")" server
echo desktop > "$W/inst/MEDIUM_VARIANT"
eq "helper: installed MEDIUM_VARIANT=desktop" "$(. "$H"; ncz_brand_medium_variant "$W/inst")" desktop
eq "helper: no directory is desktop" "$(. "$H"; ncz_brand_medium_variant "" "$W/none")" desktop
eq "helper: runs under busybox ash" "$($DISH -c ". '$H'; ncz_brand_medium_variant '$W/srv'; ncz_brand_label server x NCZ-OS 26.10")" "server
NCZ-OS 26.10 Magnetar Server"

# --- 2. the d-i dialog look --------------------------------------------------------------------
ui() { # payload-dir function [args]
    NCZ_UI_PAYLOAD="$1" NCZ_UI_RELEASE="$ROOT/release.conf" NCZ_UI_CMDLINE=/dev/null $DISH -c \
        ". '$ROOT/preseed/ncz-ui.sh'; shift; \"\$@\"" _ "$@"
}
eq "ncz_ui_brand: desktop medium" "$(ui "$W/desk" ncz_ui_brand)" "$DESK_LABEL"
eq "ncz_ui_brand: server medium" "$(ui "$W/srv" ncz_ui_brand)" "$SRVF"
eq "ncz_ui_variant: desktop medium" "$(ui "$W/desk" ncz_ui_variant)" desktop
eq "ncz_ui_variant: server medium" "$(ui "$W/srv" ncz_ui_variant)" server
eq "ncz_ui_variant: server medium without the helper (marker fallback)" "$(ui "$W/srv-nolib" ncz_ui_variant)" server
eq "ncz_ui_variant: NCZ_MEDIA_DIR (partman/early_command) decides" \
    "$(NCZ_MEDIA_DIR="$W/srv" ui "$W/desk" ncz_ui_variant)" server
eq "ncz_ui_step: desktop 5 of 8" "$(ui "$W/desk" ncz_ui_step 5)" "[5/8] "
eq "ncz_ui_step: desktop 8 of 8" "$(ui "$W/desk" ncz_ui_step 8)" "[8/8] "
eq "ncz_ui_title: desktop step title unchanged" "$(ui "$W/desk" ncz_ui_title 1 "select your REGION" "Choose your country")" "[1/8] $DESK_LABEL - select your REGION"
eq "ncz_ui_title: desktop, no step" "$(ui "$W/desk" ncz_ui_title "" "HARDWARE SUMMARY" "What we found")" "$DESK_LABEL - HARDWARE SUMMARY"
eq "ncz_ui_title: server step 1" "$(ui "$W/srv" ncz_ui_title 1 "select your REGION" "Choose your country")" "$SRV - Step 1 of 7: Choose your country"
eq "ncz_ui_title: server step 4" "$(ui "$W/srv" ncz_ui_title 4 x "Type the password again")" "$SRV - Step 4 of 7: Type the password again"
eq "ncz_ui_title: server disk is step 5 of 7" "$(ui "$W/srv" ncz_ui_title 6 x "Choose the disk to ERASE")" "$SRV - Step 5 of 7: Choose the disk to ERASE"
eq "ncz_ui_title: server erase confirm is step 7 of 7" "$(ui "$W/srv" ncz_ui_title 8 x "Erase disk and install?")" "$SRV - Step 7 of 7: Erase disk and install?"
eq "ncz_ui_title: server, no step" "$(ui "$W/srv" ncz_ui_title "" "HARDWARE SUMMARY" "What we found")" "$SRV - What we found"
case "$(ui "$W/desk" ncz_ui_id)" in "amd64 | build abc1234"*) ok "ncz_ui_id: desktop unchanged" ;; *) bad "ncz_ui_id desktop: $(ui "$W/desk" ncz_ui_id)" ;; esac
case "$(ui "$W/srv" ncz_ui_id)" in "$SRVF | amd64 | build abc1234"*) ok "ncz_ui_id: server leads with the full edition" ;; *) bad "ncz_ui_id server: $(ui "$W/srv" ncz_ui_id)" ;; esac

# every chooser title, rendered from the real Description lines (both media)
grep -h '^Description: \$(ncz_ui_title ' "$ROOT/preseed/"*.sh | sed 's/^Description: //' > "$W/titles.src"
printf '%s\n' "\$(ncz_ui_title \"\" \"HARDWARE SUMMARY\" \"What we found\")" >> "$W/titles.src"
[ "$(grep -c . "$W/titles.src")" -ge 9 ] && ok "chooser titles: $(grep -c . "$W/titles.src") ncz_ui_title calls found" || bad "chooser titles: only $(grep -c . "$W/titles.src")"
titles_for() { # medium -> rendered titles
    while IFS= read -r t; do
        NCZ_UI_PAYLOAD="$1" NCZ_UI_RELEASE="$ROOT/release.conf" NCZ_UI_CMDLINE=/dev/null $DISH -c \
            ". '$ROOT/preseed/ncz-ui.sh'; CHOSEN_USER=ncz; CHOSEN_DISK=/dev/sda; echo \"$t\""
    done < "$W/titles.src"
}
ST=$(titles_for "$W/srv"); DT=$(titles_for "$W/desk")
nocyg "server dialog titles" "$ST"
_long=$(printf '%s\n' "$ST" | awk 'length($0) > 61')
[ -z "$_long" ] && ok "server dialog titles fit d-i's 61 columns (66 with '[!!] ')" || bad "server titles too long: $_long"
[ "$(printf '%s\n' "$ST" | grep -c "^$SRV - ")" = "$(printf '%s\n' "$ST" | grep -c .)" ] && ok "every server title starts '$SRV - '" || bad "server titles: $ST"
printf '%s\n' "$DT" | grep -q "^\[6/8\] $DESK_LABEL - select the TARGET DISK (it will be ERASED)$" && ok "desktop disk title unchanged" || bad "desktop titles: $DT"

# --- 3. the component selector ------------------------------------------------------------------
cat > "$W/confmodule" <<'CM'
db_set() { echo "SET $*" >> "$NCZ_TEST_DBLOG"; }
db_fset() { :; }
db_settitle() { echo "TITLE $*" >> "$NCZ_TEST_DBLOG"; }
db_input() { echo "INPUT $*" >> "$NCZ_TEST_DBLOG"; }
db_go() { return 0; }
db_get() { RET="desktop, mgmt-container, rescue-partition"; return 0; }
CM
mkdir -p "$W/bin" "$W/nopci"
printf '#!/bin/sh\ncp "$2" "$NCZ_TEST_DBLOG.tpl"\n' > "$W/bin/debconf-loadtemplate"; chmod +x "$W/bin/debconf-loadtemplate"
sel() { # name payload cmdline-text -> rc; leaves $W/sel-<name>/
    local d="$W/sel-$1"; rm -rf "$d"; mkdir -p "$d/tmp" "$d/state" "$d/target"
    printf '%s\n' "$3" > "$d/cmdline"; : > "$d/db.log"
    PATH="$W/bin:$PATH" NCZ_TEST_DBLOG="$d/db.log" NCZ_CONFMODULE="$W/confmodule" \
    NCZ_UI_SH="$ROOT/preseed/ncz-ui.sh" NCZ_UI_PAYLOAD="$2" NCZ_UI_RELEASE="$ROOT/release.conf" NCZ_UI_CMDLINE=/dev/null \
    NCZ_TMP="$d/tmp" NCZ_COMP_STATE="$d/state" NCZ_TARGET="$d/target" NCZ_CMDLINE="$d/cmdline" \
    NCZ_LOGGER=true NCZ_PCI_DEVICES="$W/nopci" NCZ_UNAME_M=x86_64 NCZ_MEDIA_DIR="${SEL_MEDIA_DIR:-}" \
        $DISH "$ROOT/preseed/component-selector.sh" --prompt > "$d/out" 2>&1
    echo $? > "$d/rc"
}
sel srv "$W/srv" "quiet"
eq "selector, server medium: exit 0" "$(cat "$W/sel-srv/rc")" 0
if grep -q '^INPUT' "$W/sel-srv/db.log" || [ -e "$W/sel-srv/db.log.tpl" ]; then
    bad "selector, server medium: the component dialog was shown ($(tr '\n' ' ' < "$W/sel-srv/db.log"))"
else ok "selector, server medium: no component dialog"; fi
eq "selector, server medium: record" "$(cat "$W/sel-srv/state/COMPONENTS" 2>/dev/null)" "rescue-partition"
eq "selector, server medium: /tmp mirror" "$(cat "$W/sel-srv/tmp/ncz-components" 2>/dev/null)" "rescue-partition"
eq "selector, server medium: COMPONENTS_desktop" "$(cat "$W/sel-srv/target/etc/cix-installer/COMPONENTS_desktop" 2>/dev/null)" 0
eq "selector, server medium: COMPONENTS_rescue-partition" "$(cat "$W/sel-srv/target/etc/cix-installer/COMPONENTS_rescue-partition" 2>/dev/null)" 1
[ -e "$W/sel-srv/tmp/.ncz-components-done" ] && ok "selector, server medium: answered once per boot" || bad "selector, server medium: no done marker"
SEL_MEDIA_DIR="$W/srv" sel srvmd "$W/desk" "quiet"
eq "selector, NCZ_MEDIA_DIR is a server medium: record" "$(cat "$W/sel-srvmd/state/COMPONENTS" 2>/dev/null)" "rescue-partition"
sel srvovr "$W/srv" "quiet ncz_components=desktop,mgmt-container"
eq "selector, server medium: desktop dropped from an override" "$(cat "$W/sel-srvovr/state/COMPONENTS" 2>/dev/null)" "mgmt-container"
grep -q 'a Magnetar Server medium has no desktop -- dropping' "$W/sel-srvovr/out" && ok "selector, server medium: the drop is logged" || bad "selector: drop not logged"
sel srvdesk "$W/srv" "quiet ncz_components=desktop"
eq "selector, server medium: desktop-only override = the server record" "$(cat "$W/sel-srvdesk/state/COMPONENTS" 2>/dev/null)" "rescue-partition"
sel srvgate "$W/srv" "quiet ncz_components=rescue-partition"
eq "selector, server medium: the server gate's override" "$(cat "$W/sel-srvgate/state/COMPONENTS" 2>/dev/null)" "rescue-partition"
sel desk "$W/desk" "quiet"
grep -q '^INPUT critical ncz/components' "$W/sel-desk/db.log" && ok "selector, desktop medium: dialog shown" || bad "selector, desktop medium: no dialog ($(cat "$W/sel-desk/out"))"
eq "selector, desktop medium: record" "$(cat "$W/sel-desk/state/COMPONENTS" 2>/dev/null)" "desktop,browsers,wallpaper-rotator,mgmt-container,rescue-partition"
eq "selector, desktop medium: dialog title" "$(sed -n 's/^Description: //p' "$W/sel-desk/db.log.tpl" 2>/dev/null)" "[5/8] $DESK_LABEL - optional components"

# the erase confirmation on a server medium: no components, the download stated before the erase
awk '/cat > \/tmp\/ncz-confirm.templates <<TPL/{n++} n==1{print} n==1 && /^TPL$/{exit}' "$ROOT/preseed/disk-fs-chooser.sh" \
    | sed "s#/tmp/ncz-confirm.templates#$W/confirm.tpl#" > "$W/confirm.sh"
NCZ_UI_PAYLOAD="$W/srv" NCZ_UI_RELEASE="$ROOT/release.conf" NCZ_UI_CMDLINE=/dev/null $DISH -c \
    ". '$ROOT/preseed/ncz-ui.sh'; CHOSEN_DISK=/dev/sda; CHOSEN_FS=btrfs; _ncz_resc=yes; . '$W/confirm.sh'"
if [ -s "$W/confirm.tpl" ]; then
    eq "erase confirm (server): title" "$(sed -n 's/^Description: //p' "$W/confirm.tpl")" "$SRV - Step 7 of 7: Erase disk and install?"
    grep -q 'downloads about 3 GB after the disk is erased' "$W/confirm.tpl" && ok "erase confirm (server): states the 3 GB download before the erase" || bad "erase confirm (server): no download warning"
    grep -q 'the disk is left erased with nothing installed' "$W/confirm.tpl" && ok "erase confirm (server): says what a failed download leaves" || bad "erase confirm (server): no failure consequence"
    grep -qE 'Components:|desktop|Cygnus' "$W/confirm.tpl" && bad "erase confirm (server): lists components/desktop/codename" || ok "erase confirm (server): no components, no desktop, no codename"
    grep -q "^ $SRVF | " "$W/confirm.tpl" && ok "erase confirm (server): id line carries the full edition" || bad "erase confirm (server): id line: $(tail -1 "$W/confirm.tpl")"
else bad "erase confirm (server): the server template block was not found/rendered"; fi

# --- 4. late.sh: the installer label and its templates ---------------------------------------------
# The identity block (release file -> label/variant) and the progress/remove-media templates, with
# /cdrom/ncz-payload pointed at a fixture medium and /tmp at a scratch dir.
awk '/^NCZ_PRODUCT_NAME="NCZ-OS"$/{f=1} f{print} /^export NCZ_PRODUCT_NAME /{exit}' "$ROOT/preseed/late.sh" > "$W/late-id.sh"
awk '!f && /^    if \[ "\$NCZ_LATE_VARIANT" = server \]; then$/{f=1}
     f{print} f && /^NCZTPL$/{n++} f && n==2 && /^    fi$/{exit}' "$ROOT/preseed/late.sh" > "$W/late-tpl.sh"
[ -s "$W/late-id.sh" ] && [ -s "$W/late-tpl.sh" ] && ok "late.sh: identity and template blocks found" || bad "late.sh: blocks not found"
late() { # medium -> prints label, variant, then the templates
    local m="$W/late-$1"; rm -rf "$m"; mkdir -p "$m/cdrom" "$m/tmp"; cp -a "$2" "$m/cdrom/ncz-payload"
    sed "s#/cdrom/ncz-payload#$m/cdrom/ncz-payload#g; s#/hd-media/ncz-payload#$m/none#g; s#/media/cdrom/ncz-payload#$m/none#g; s#/run/live/medium/ncz-payload#$m/none#g" \
        "$W/late-id.sh" > "$m/id.sh"
    sed "s#/tmp/ncz-progress.templates#$m/tmp/t#" "$W/late-tpl.sh" > "$m/tpl.sh"
    $DISH -c "ttymsg() { :; }; . '$m/id.sh'; NCZ_DIAG_LOGIN_LINE=''; . '$m/tpl.sh'; echo \"LABEL=\$NCZ_RELEASE_LABEL\"; echo \"VARIANT=\$NCZ_LATE_VARIANT\"; cat '$m/tmp/t'"
}
LS=$(late srv "$W/srv"); LD=$(late desk "$W/desk")
eq "late.sh: server label" "$(printf '%s\n' "$LS" | sed -n 's/^LABEL=//p')" "$SRVF"
eq "late.sh: desktop label" "$(printf '%s\n' "$LD" | sed -n 's/^LABEL=//p')" "$DESK_LABEL"
nocyg "late.sh: server progress/remove-media templates" "$LS"
printf '%s\n' "$LS" | grep -q "^Description: $SRV is installed - remove the USB stick now$" && ok "late.sh: server final screen names $SRV" || bad "late.sh: server final screen"
printf '%s\n' "$LS" | grep -q "^Description: Installing $SRV - this takes several minutes$" && ok "late.sh: server progress title" || bad "late.sh: server progress title"
printf '%s\n' "$LS" | grep -qi 'desktop' && bad "late.sh: server templates mention a desktop: $(printf '%s\n' "$LS" | grep -i desktop | head -2)" || ok "late.sh: server templates promise no desktop"
printf '%s\n' "$LD" | grep -q "^ The full desktop, GPU/NPU drivers, kernels and agents are being installed.$" && ok "late.sh: desktop progress text unchanged" || bad "late.sh: desktop progress text"
printf '%s\n' "$LD" | grep -q "^ desktop. If the USB stick is left inserted" && ok "late.sh: desktop remove-media text unchanged" || bad "late.sh: desktop remove-media text"
# the progress line never shows the codename in a hook name on a server medium
_hb=$(awk '/hb_label=\$\(printf .%s. "\$hb_label" \| sed/{f=1} f{print} /^    fi$/{if(f) exit}' "$ROOT/preseed/late.sh")
hbl() { NCZ_LATE_VARIANT=$1 NCZ_RELEASE_CODENAME=Cygnus hb_label=$2 bash -c "$_hb"'
echo "$hb_label"'; }
eq "late.sh: server progress label for 62-cygnus-screensaver-default" "$(hbl server 62-cygnus-screensaver-default)" "screensaver default"
eq "late.sh: desktop progress label unchanged" "$(hbl desktop 62-cygnus-screensaver-default)" "cygnus screensaver default"

# --- 5. 50-brand.sh ------------------------------------------------------------------------------
brand() { NCZ_BRAND_PRINT_IDENTITY="$ROOT/release.conf" NCZ_BRAND_VARIANT="$1" NCZ_BRAND_MEDIUM="$2" bash "$ROOT/post-install/50-brand.sh" 2>/dev/null; }
B=$(brand server server)
eq "50-brand: server PRETTY_NAME" "$(printf '%s\n' "$B" | sed -n 's/^PRETTY_NAME=//p')" "$SRVF, based on $NCZ_BASE_LABEL"
eq "50-brand: server VERSION" "$(printf '%s\n' "$B" | sed -n 's/^VERSION=//p')" "$NCZ_RELEASE_VERSION (Magnetar Server, based on $NCZ_BASE_LABEL)"
eq "50-brand: server VARIANT" "$(printf '%s\n' "$B" | sed -n 's/^VARIANT=//p')" '"Magnetar Server"'
eq "50-brand: server VARIANT_ID" "$(printf '%s\n' "$B" | sed -n 's/^VARIANT_ID=//p')" magnetar-server
eq "50-brand: server /etc/issue first line" "$(printf '%s\n' "$B" | sed -n 's/^ISSUE=//p')" "$SRVF - NCZ_ISSUE_SOC_PLACEHOLDER - kernel \\r"
nocyg "50-brand: server identity" "$B"
eq "50-brand: desktop medium, desktop PRETTY_NAME unchanged" "$(brand desktop desktop | sed -n 's/^PRETTY_NAME=//p')" "$DESK_LABEL Desktop, based on $NCZ_BASE_LABEL"
eq "50-brand: desktop medium, console-only install unchanged" "$(brand server desktop | sed -n 's/^PRETTY_NAME=//p')" "$DESK_LABEL Server, based on $NCZ_BASE_LABEL"
brand desktop desktop | grep -q '^VARIANT=' && bad "50-brand: desktop gained a VARIANT key" || ok "50-brand: desktop has no VARIANT key"
# the motd title row reads the edition from os-release VARIANT
awk "/^cat > \/etc\/update-motd.d\/00-ncz-banner <<'BANNER'/{f=1;next} /^BANNER\$/{f=0} f" "$ROOT/post-install/50-brand.sh" > "$W/banner.sh"
motd() { # os-release-file -> first title row
    sed "s#/etc/os-release#$1#g; s#/etc/cix-installer/RELEASE#$ROOT/release.conf#g; s#/usr/local/bin/ncz-hw-brand#$W/none#g" "$W/banner.sh" > "$W/banner-run.sh"
    bash "$W/banner-run.sh" 2>/dev/null | sed -n '3p'
}
printf 'NAME="NCZ-OS"\nVERSION_ID="26.10"\nVERSION_CODENAME=cygnus\nNCZ_VARIANT=server\nVARIANT="Magnetar Server"\nBUILD_ID=x\n' > "$W/osr-srv"
printf 'NAME="NCZ-OS"\nVERSION_ID="26.10"\nVERSION_CODENAME=cygnus\nNCZ_VARIANT=desktop\nBUILD_ID=x\n' > "$W/osr-desk"
case "$(motd "$W/osr-srv")" in *"  $SRVF - unknown "*) ok "motd: server title row" ;; *) bad "motd: server title row: $(motd "$W/osr-srv")" ;; esac
case "$(motd "$W/osr-desk")" in *"NCZ-OS $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME Desktop  ·  unknown edge agent"*) ok "motd: desktop title row unchanged" ;; *) bad "motd: desktop title row: $(motd "$W/osr-desk")" ;; esac

# --- 6. 48-server-variant.sh: the server console banner ---------------------------------------------
awk '/^if \[ "\$_ncz_medium" = server \]; then$/{f=1} f{print} /^    } > \/etc\/issue.d\/10-ncz-server.issue$/{exit}' "$ROOT/post-install/48-server-variant.sh" \
    | sed "s#/etc/issue.d#$W#; s#/usr/local/lib/cix-installer/RELEASE#$ROOT/release.conf#" > "$W/issued.sh"; echo fi >> "$W/issued.sh"
( set -euo pipefail; . "$H"; _ncz_medium=server; . "$W/issued.sh" )
if [ -s "$W/10-ncz-server.issue" ]; then
    eq "48: server banner title" "$(sed -n 2p "$W/10-ncz-server.issue")" "$SRVF"
    grep -qF 'ssh <user>@\4' "$W/10-ncz-server.issue" && ok "48: server banner shows the ssh login with agetty's address" || bad "48: no ssh line"
    grep -qiE 'maximilian|cygnus|ncz desktop on' "$W/10-ncz-server.issue" && bad "48: server banner names a retired/desktop name or the desktop toggle" || ok "48: server banner has no retired name, no codename, no desktop toggle"
    LC_ALL=C grep -q '[^ -~]' "$W/10-ncz-server.issue" && bad "48: server banner is not plain ASCII" || ok "48: server banner is plain ASCII"
else bad "48: no server banner block"; fi

# --- 7. installed rEFInd menus ----------------------------------------------------------------------
for s in "$ROOT/assets/refind/ncz-refind-refresh.sh" "$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"; do
    n=$(basename "$s" .sh)
    awk '/NCZ-MENU-VARIANT-BEGIN/{f=1} f{print} /NCZ-MENU-VARIANT-END/{exit}' "$s" \
        | sed "s#/usr/local/lib/cix-installer#$W/mv/lib#g" > "$W/mv-$n.sh"
    awk '/^\{$/ {b=NR} /^\} > "\$REFIND_CONF"$/ {e=NR} {l[NR]=$0} END {for (i=b; i<=e; i++) print l[i]}' "$s" > "$W/menu-$n.sh"
    titles() { # medium(server|-) -> menu titles
        rm -rf "$W/mv"; mkdir -p "$W/mv/lib/post-install/lib"; cp "$H" "$W/mv/lib/post-install/lib/"
        [ "$1" = - ] || echo "$1" > "$W/mv/lib/MEDIUM_VARIANT"
        echo server > "$W/mv/lib/BUILD_VARIANT"; echo rescue-partition > "$W/mv/lib/COMPONENTS"
        ( set +u; unset NCZ_VARIANT
          STABLE_AVAILABLE=1 NEXT_AVAILABLE=1 PANTHOR_ENTRY=1 KVER_STABLE=7.3.0-t2-ncz KVER_NEXT=7.3.0-sky1-ncz
          NCZ_PRODUCT_NAME=NCZ-OS NCZ_RELEASE_SHORT="$DESK_LABEL" RESCUEPART_OPTIONS="root=PARTUUID=p" REFIND_CONF="$W/mv/refind.conf"
          NCZ_RELEASE_VERSION="$NCZ_RELEASE_VERSION"
          REFIND_TIMEOUT=5 REFIND_BANNER="ncz-banner.png" REFIND_THEME="" REFIND_ICON="" BUILD_VERSION=t ROOT_FSTYPE=ext4 DEFAULT_TOKEN=Console
          . "$W/mv-$n.sh" >/dev/null; . "$W/menu-$n.sh"; grep -E '^(menuentry |banner )' "$W/mv/refind.conf" )
    }
    T=$(titles server)
    [ -n "$T" ] && [ "$(printf '%s\n' "$T" | grep -c "^menuentry \"$SRVF  -  ")" = "$(printf '%s\n' "$T" | grep -c '^menuentry ')" ] \
        && ok "$n: every server menu title starts '$SRVF  -  '" || bad "$n: server titles: $T"
    nocyg "$n: server menu titles" "$T"
    printf '%s\n' "$T" | grep -q '^banner ' && bad "$n: the server menu still references the legacy banner image" || ok "$n: no legacy banner image on the server menu"
    T=$(titles -)
    [ "$(printf '%s\n' "$T" | grep -c "^menuentry \"$DESK_LABEL  -  ")" = "$(printf '%s\n' "$T" | grep -c '^menuentry ')" ] \
        && ok "$n: desktop-medium titles unchanged ('$DESK_LABEL  -  ')" || bad "$n: desktop titles: $T"
    printf '%s\n' "$T" | grep -q '^banner ncz-banner.png' && ok "$n: desktop menu keeps its banner line" || bad "$n: desktop banner line lost"
done

# --- 8. the installer boot menu's identity line --------------------------------------------------------
esp_line() { NCZ_VARIANT="$1" python3 -c "import importlib.util,sys
s=importlib.util.spec_from_file_location('e','$ROOT/build/iso/build-refind-esp.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.build_info_line('amd64'))"; }
case "$(esp_line server)" in "$SRVF -- built "*) ok "build-refind-esp: server info line" ;; *) bad "build-refind-esp: server info line: $(esp_line server)" ;; esac
case "$(esp_line desktop)" in "$DESK_LABEL -- built "*) ok "build-refind-esp: desktop info line unchanged" ;; *) bad "build-refind-esp: desktop info line: $(esp_line desktop)" ;; esac
mkdir -p "$W/espcopy/build/iso"; cp "$ROOT/build/iso/build-refind-esp.py" "$W/espcopy/build/iso/"; cp "$ROOT/release.conf" "$W/espcopy/"
_o=$(NCZ_VARIANT=server python3 -c "import importlib.util
s=importlib.util.spec_from_file_location('e','$W/espcopy/build/iso/build-refind-esp.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.build_info_line('amd64'))" 2>&1); _r=$?
[ "$_r" != 0 ] && printf '%s' "$_o" | grep -q 'ncz-brand.sh is missing' && ok "build-refind-esp: a server build without the brand helper fails with a clear message" || bad "build-refind-esp: missing helper: rc=$_r $_o"
case "$(NCZ_VARIANT= esp_line '')" in "$DESK_LABEL -- built "*) ok "build-refind-esp: unset NCZ_VARIANT is desktop" ;; *) bad "build-refind-esp: unset variant" ;; esac

# --- 9. ncz version ---------------------------------------------------------------------------------------
cli() { # installer-meta dir
    sed "s#/usr/local/lib/cix-installer#$1#g; s#/etc/cix-installer/RELEASE#$ROOT/release.conf#g" "$ROOT/assets/ncz-cli.sh" > "$W/ncz-cli.sh"
    bash "$W/ncz-cli.sh" version 2>/dev/null
}
rm -rf "$W/cm"; mkdir -p "$W/cm/post-install/lib"; cp "$H" "$W/cm/post-install/lib/"
eq "ncz version: desktop unchanged" "$(cli "$W/cm")" "NCZ-OS $NCZ_RELEASE_VERSION \"$NCZ_RELEASE_CODENAME\""
echo server > "$W/cm/MEDIUM_VARIANT"
eq "ncz version: Magnetar Server install" "$(cli "$W/cm")" "$SRVF"

# --- 10. the KVM gate's installed-system assertion -----------------------------------------------------
awk '/# NCZ-GATE-SERVER-BRAND-BEGIN/{f=1} f{print} /# NCZ-GATE-SERVER-BRAND-END/{exit}' "$ROOT/build/kvm-install-gate-gpt.sh" > "$W/gb.sh"
gate() { bash -c ". '$W/gb.sh'; ncz_gate_server_brand '$1' '$2' '$3'" >/dev/null 2>&1; echo $?; }
printf 'PRETTY_NAME="NCZ-OS 26.10 Magnetar Server, based on X"\nVERSION="26.10 (Magnetar Server, based on X)"\nVERSION_CODENAME=cygnus\nVARIANT="Magnetar Server"\n' > "$W/g-osr"
printf 'NCZ-OS 26.10 Magnetar Server - SOC - kernel \\r\n' > "$W/g-iss"
printf 'menuentry "NCZ-OS 26.10 Magnetar Server  -  7.3 Console" {\n}\nmenuentry "NCZ-OS 26.10 Magnetar Server  -  Rescue Partition (Console)" {\n}\n' > "$W/g-rc"
eq "gate: a correct server install passes" "$(gate "$W/g-osr" "$W/g-iss" "$W/g-rc")" 0
printf 'PRETTY_NAME="NCZ-OS 26.10 Cygnus Server, based on X"\nVERSION="26.10 (Cygnus Server, based on X)"\n' > "$W/g-osr-old"
printf 'NCZ-OS 26.10 Cygnus Server  ·  SOC\n' > "$W/g-iss-old"
printf 'menuentry "NCZ-OS 26.10 Cygnus  -  7.3 Console" {\n}\n' > "$W/g-rc-old"
eq "gate: the pre-fix os-release fails" "$(gate "$W/g-osr-old" "$W/g-iss" "$W/g-rc")" 1
eq "gate: the pre-fix /etc/issue fails" "$(gate "$W/g-osr" "$W/g-iss-old" "$W/g-rc")" 1
eq "gate: the pre-fix menu titles fail" "$(gate "$W/g-osr" "$W/g-iss" "$W/g-rc-old")" 1
printf 'PRETTY_NAME="NCZ-OS Magnetar 26.10"\nVARIANT="Magnetar"\n' > "$W/g-osr-bare"
eq "gate: bare 'Magnetar' is not 'Magnetar Server'" "$(gate "$W/g-osr-bare" "$W/g-iss" "$W/g-rc")" 1
eq "gate: a missing os-release fails" "$(gate "$W/none" "$W/g-iss" "$W/g-rc")" 1

# --- 11. the static codename check (build/check-server-codename.sh) --------------------------------
C="$ROOT/build/check-server-codename.sh"
bash "$C" >/dev/null 2>&1 && ok "check-server-codename: the tree passes" || bad "check-server-codename: the tree fails: $(bash "$C" 2>&1 | head -3)"
mkdir -p "$W/cc/assets/refind" "$W/cc/build/iso" "$W/cc/manifests"
cp -a "$ROOT/preseed" "$ROOT/post-install" "$W/cc/"; cp -a "$ROOT/assets/refind/." "$W/cc/assets/refind/"
cp "$ROOT/assets/ncz-cli.sh" "$W/cc/assets/"; cp "$ROOT/build/iso/build-refind-esp.py" "$W/cc/build/iso/"
cp "$ROOT/manifests/server-codename-allowlist.tsv" "$W/cc/manifests/"
NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" >/dev/null 2>&1 && ok "check-server-codename: the copy passes" || bad "check-server-codename: the copy fails"
printf '\necho "NCZ-OS 26.10 Cygnus"\n' >> "$W/cc/preseed/region-chooser.sh"
_o=$(NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" 2>&1); _r=$?
[ "$_r" != 0 ] && printf '%s' "$_o" | grep -q 'preseed/region-chooser.sh' && ok "check-server-codename: a hard-coded Cygnus in a d-i helper fails" || bad "check-server-codename: injected literal not caught: $_o"
cp "$ROOT/preseed/region-chooser.sh" "$W/cc/preseed/region-chooser.sh"
printf '\nNCZ_LABEL="NCZ-OS 26.10 Cygnus"\n' >> "$W/cc/post-install/62-cygnus-screensaver-default.sh"
_o=$(NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" 2>&1); _r=$?
[ "$_r" != 0 ] && printf '%s' "$_o" | grep -q '62-cygnus-screensaver-default.sh' && ok "check-server-codename: a new label literal in an allow-listed hook is still a hit" || bad "check-server-codename: allow-list row too broad: $_o"
cp "$ROOT/post-install/62-cygnus-screensaver-default.sh" "$W/cc/post-install/62-cygnus-screensaver-default.sh"
printf '\n# the Cygnus prose in a comment is fine\n    # indented Cygnus prose too\n' >> "$W/cc/preseed/region-chooser.sh"
NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" >/dev/null 2>&1 && ok "check-server-codename: comment prose is not a hit" || bad "check-server-codename: a comment was flagged"
printf '    echo "NCZ-OS 26.10 Cygnus" # a trailing comment does not exempt the code\n' >> "$W/cc/preseed/region-chooser.sh"
_o=$(NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" 2>&1); _r=$?
[ "$_r" != 0 ] && printf '%s' "$_o" | grep -q 'region-chooser.sh' && ok "check-server-codename: code with a trailing comment is still a hit" || bad "check-server-codename: trailing-comment code passed: $_o"
cp "$ROOT/preseed/region-chooser.sh" "$W/cc/preseed/region-chooser.sh"
printf 'preseed/late.sh\tnothing-matches-this\tstale\n' >> "$W/cc/manifests/server-codename-allowlist.tsv"
_o=$(NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" 2>&1); _r=$?
[ "$_r" != 0 ] && printf '%s' "$_o" | grep -q 'matches nothing' && ok "check-server-codename: a stale allow-list row fails" || bad "check-server-codename: stale row not caught: $_o"

if [ "$FAIL" != 0 ]; then echo "test-server-branding: FAIL" >&2; exit 1; fi
echo "test-server-branding: PASS"
