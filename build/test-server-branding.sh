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
_dd=""; trap 'rm -rf "$W"; [ -n "$_dd" ] && rm -rf "$_dd"' EXIT
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
eq "50-brand: server /etc/issue first line" "$(printf '%s\n' "$B" | sed -n 's/^ISSUE=//p')" "$SRVF - (detecting hardware) - kernel \\r"
nocyg "50-brand: server identity" "$B"
eq "50-brand: desktop medium, desktop PRETTY_NAME unchanged" "$(brand desktop desktop | sed -n 's/^PRETTY_NAME=//p')" "$DESK_LABEL Desktop, based on $NCZ_BASE_LABEL"
eq "50-brand: desktop medium, console-only install unchanged" "$(brand server desktop | sed -n 's/^PRETTY_NAME=//p')" "$DESK_LABEL Server, based on $NCZ_BASE_LABEL"
brand desktop desktop | grep -q '^VARIANT=' && bad "50-brand: desktop gained a VARIANT key" || ok "50-brand: desktop has no VARIANT key"
# the real writer (not only the print seam): 50-brand.sh run in a sandbox root, /etc and the installer meta dir
# rewritten into it, systemctl stubbed
realbrand() { # medium(server|desktop) build-variant -> sandbox root
    local R="$W/rb-$1-$2"; rm -rf "$R"; mkdir -p "$R/etc/update-motd.d" "$R/etc/systemd/system" "$R/lib/cix" "$R/usr/local/bin" "$R/usr/lib" "$R/bin" "$R/hook/lib"
    cp "$ROOT/release.conf" "$R/lib/cix/RELEASE"; echo 2026.10.26-abc1234 > "$R/lib/cix/BUILD_VERSION"; echo 2026-10-26 > "$R/lib/cix/BUILD_DATE"
    echo "$2" > "$R/lib/cix/BUILD_VARIANT"; [ "$1" = server ] && echo server > "$R/lib/cix/MEDIUM_VARIANT"
    printf '#!/bin/sh\nexit 0\n' > "$R/bin/systemctl"; chmod +x "$R/bin/systemctl"; cp "$H" "$R/hook/lib/"
    sed "s#/usr/local/lib/cix-installer#$R/lib/cix#g; s#/etc/#$R/etc/#g; s#/usr/local/bin/#$R/usr/local/bin/#g; s#/usr/lib/os-release#$R/usr/lib/os-release#g" \
        "$ROOT/post-install/50-brand.sh" > "$R/hook/50-brand.sh"
    PATH="$R/bin:$PATH" bash "$R/hook/50-brand.sh" > "$R/log" 2>&1
    echo "$R"
}
R=$(realbrand server server)
eq "50-brand (real write, server): PRETTY_NAME" "$(unset VARIANT PRETTY_NAME; . "$R/etc/os-release"; echo "$PRETTY_NAME")" "$SRVF, based on $NCZ_BASE_LABEL"
eq "50-brand (real write, server): VARIANT / VARIANT_ID / ID parse" "$(unset VARIANT VARIANT_ID ID; . "$R/etc/os-release"; echo "$VARIANT|$VARIANT_ID|$ID")" "Magnetar Server|magnetar-server|ncz"
eq "50-brand (real write, server): /etc/issue first line" "$(head -1 "$R/etc/issue")" "$SRVF - (detecting hardware) - kernel \\r"
eq "50-brand (real write, server): /etc/issue.net first line" "$(head -1 "$R/etc/issue.net")" "$SRVF (detecting hardware)"
eq "50-brand (real write, server): lsb DISTRIB_DESCRIPTION" "$(sed -n 's/^DISTRIB_DESCRIPTION=//p' "$R/etc/lsb-release")" "\"$SRVF, based on $NCZ_BASE_LABEL\""
nocyg "50-brand (real write, server): PRETTY_NAME/VERSION/VARIANT, issue, issue.net, log" \
    "$(grep -E '^(PRETTY_NAME|VERSION|VARIANT)=' "$R/etc/os-release"; cat "$R/etc/issue" "$R/etc/issue.net" "$R/log")"
R=$(realbrand desktop desktop)
eq "50-brand (real write, desktop): PRETTY_NAME unchanged" "$(unset PRETTY_NAME; . "$R/etc/os-release"; echo "$PRETTY_NAME")" "$DESK_LABEL Desktop, based on $NCZ_BASE_LABEL"
grep -q '^VARIANT' "$R/etc/os-release" && bad "50-brand (real write, desktop): gained a VARIANT key" || ok "50-brand (real write, desktop): no VARIANT key"
case "$(head -1 "$R/etc/issue")" in "$DESK_LABEL Desktop  ·  (detecting hardware)  (Kernel: \r)") ok "50-brand (real write, desktop): /etc/issue first-boot text (no token)" ;; *) bad "50-brand (real write, desktop): issue: $(head -1 "$R/etc/issue")" ;; esac
# --- the login banner never shows a raw token (2026-10-26, cyclops: agetty printed NCZ_ISSUE_*_PLACEHOLDER) --
for _m in server desktop; do
    R=$(realbrand $_m $_m)
    grep -q 'NCZ_ISSUE_' "$R/etc/issue" "$R/etc/issue.net" && bad "issue ($_m): first-boot text carries a raw NCZ_ISSUE_ token" || ok "issue ($_m): first-boot text has no raw token"
    grep -q '^IP:    (waiting for network)$' "$R/etc/issue" && ok "issue ($_m): first-boot IP line reads '(waiting for network)'" || bad "issue ($_m): IP line: $(grep '^IP:' "$R/etc/issue")"
    # the real refresh script the hook installed, run against the sandbox banner with stub hw-brand and ip
    mkdir -p "$R/stub"
    printf '#!/bin/sh\necho "SOC=Intel Core i5-2415M & co|x"\necho GPU=none\n' > "$R/stub/hw"; chmod +x "$R/stub/hw"
    printf '#!/bin/sh\ncase "$*" in *"route get"*) [ -s "%s/addr" ] && echo "1.1.1.1 via 10.0.0.1 dev eth0 src $(cat %s/addr) uid 0" ;; esac\nexit 0\n' "$R" "$R" > "$R/stub/ip"
    printf '#!/bin/sh\necho "$*" >> %s/agetty.calls\n' "$R" > "$R/stub/agetty"; chmod +x "$R/stub/ip" "$R/stub/agetty"
    RF() { PATH="$R/stub:$PATH" NCZ_ISSUE_FILE="$R/etc/issue" NCZ_ISSUE_NET_FILE="$R/etc/issue.net" NCZ_HW_BRAND="$R/stub/hw" sh "$R/usr/local/bin/ncz-issue-refresh" "$@"; }
    RF --soc
    case "$(head -1 "$R/etc/issue")" in *"Intel Core i5-2415M & co|x"*) ok "issue ($_m): --soc fills the SoC before the gettys (special characters kept)" ;; *) bad "issue ($_m): after --soc: $(head -1 "$R/etc/issue")" ;; esac
    grep -q '(Intel Core i5-2415M & co|x)$' "$R/etc/issue.net" && ok "issue.net ($_m): SoC filled, in brackets" || bad "issue.net ($_m): $(head -1 "$R/etc/issue.net")"
    grep -q -- '--reload' "$R/agetty.calls" 2>/dev/null && ok "issue ($_m): the gettys are told to re-print (agetty --reload)" || bad "issue ($_m): no agetty --reload"
    RF --ip-once; grep -q '^IP:    (waiting for network)$' "$R/etc/issue" && ok "issue ($_m): no address yet keeps the waiting text" || bad "issue ($_m): no-address IP line: $(grep '^IP:' "$R/etc/issue")"
    echo 192.168.207.89 > "$R/addr"; RF --ip-once
    grep -q '^IP:    192.168.207.89$' "$R/etc/issue" && ok "issue ($_m): the address is filled in" || bad "issue ($_m): IP line: $(grep '^IP:' "$R/etc/issue")"
    echo 192.168.207.90 > "$R/addr"; RF --ip-once
    grep -q '^IP:    192.168.207.90$' "$R/etc/issue" && ok "issue ($_m): a changed address replaces the old one (no stale banner)" || bad "issue ($_m): changed IP: $(grep '^IP:' "$R/etc/issue")"
    grep -qE 'NCZ_ISSUE_|\(detecting hardware\)' "$R/etc/issue" "$R/etc/issue.net" && bad "issue ($_m): a token or waiting text survived the refresh" || ok "issue ($_m): after the refresh no token or waiting text remains"
    [ "$_m" = server ] && { head -1 "$R/etc/issue" | grep -q 'Desktop' && bad "issue (server): first line says Desktop" || ok "issue (server): first line has no 'Desktop'"; }
done
# an older banner that still carries the tokens is healed too
printf 'X  ·  NCZ_ISSUE_SOC_PLACEHOLDER  (Kernel: \\r)\nIP:    NCZ_ISSUE_IP_PLACEHOLDER\n' > "$R/etc/issue"; echo 10.1.2.3 > "$R/addr"; RF --soc; RF --ip-once
grep -q 'NCZ_ISSUE_' "$R/etc/issue" && bad "issue: an old token banner is not healed: $(cat "$R/etc/issue")" || ok "issue: an old token banner is healed by the refresh"
# the unit: SoC before the first login prompt, the main process async
_u="$R/etc/systemd/system/ncz-issue-refresh.service"
grep -q '^Before=getty-pre.target$' "$_u" && grep -q '^Wants=getty-pre.target$' "$_u" && grep -qE '^ExecStartPre=-(.*)?/usr/local/bin/ncz-issue-refresh --soc$' "$_u" && grep -q '^Type=simple$' "$_u" \
    && ok "ncz-issue-refresh.service: SoC step ordered before getty-pre.target, main process Type=simple" || bad "ncz-issue-refresh.service: $(grep -E '^(Before|Wants|ExecStartPre|Type)=' "$_u" | tr '\n' ' ')"

# the motd title row reads the edition from os-release VARIANT, never from the caller's environment
# (the generated banner already reads the sandbox's etc/; only the live hardware probe is cut out)
_mt=$(VARIANT="Magnetar Server" bash -c "$(sed "s#$R/usr/local/bin/ncz-hw-brand#$W/none#g" "$R/etc/update-motd.d/00-ncz-banner")" 2>/dev/null | sed -n 3p)
case "$_mt" in *"$DESK_LABEL Desktop  ·  unknown edge agent"*) ok "motd: an exported VARIANT does not change the desktop title row" ;; *) bad "motd: exported VARIANT leaked into the desktop title: $_mt" ;; esac
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

# the whole 48 hook on a server medium (sandbox, systemctl/nmcli stubbed): no desktop advice in its log
R48="$W/r48"; mkdir -p "$R48/lib/cix" "$R48/etc" "$R48/bin" "$R48/hook/lib"
echo server > "$R48/lib/cix/BUILD_VARIANT"; echo server > "$R48/lib/cix/MEDIUM_VARIANT"; cp "$ROOT/release.conf" "$R48/lib/cix/RELEASE"
printf '#!/bin/sh\nexit 0\n' > "$R48/bin/systemctl"; printf '#!/bin/sh\nexit 1\n' > "$R48/bin/nmcli"; chmod +x "$R48/bin/systemctl" "$R48/bin/nmcli"; cp "$H" "$R48/hook/lib/"
sed "s#/usr/local/lib/cix-installer#$R48/lib/cix#g; s#/etc/#$R48/etc/#g" "$ROOT/post-install/48-server-variant.sh" > "$R48/hook/48.sh"
PATH="$R48/bin:$PATH" bash "$R48/hook/48.sh" > "$R48/log" 2>&1; _r48=$?
eq "48 (whole hook, server medium): exit status" "$_r48" 0
grep -q 'ncz desktop on' "$R48/log" "$R48/etc/issue.d/10-ncz-server.issue" 2>/dev/null && bad "48 (whole hook, server medium): still advises 'ncz desktop on'" || ok "48 (whole hook, server medium): no 'ncz desktop on' advice"
eq "48 (whole hook, server medium): issue.d title" "$(sed -n 2p "$R48/etc/issue.d/10-ncz-server.issue" 2>/dev/null)" "$SRVF"

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
    [ "$(printf '%s\n' "$T" | grep -c '^menuentry ')" -ge 3 ] && [ "$(printf '%s\n' "$T" | grep -c "^menuentry \"$DESK_LABEL  -  ")" = "$(printf '%s\n' "$T" | grep -c '^menuentry ')" ] \
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
printf '\necho "[62] Cygnus screensaver"; NCZ_LABEL="NCZ-OS 26.10 Cygnus"\n' >> "$W/cc/post-install/62-cygnus-screensaver-default.sh"
_o=$(NCZ_CODENAME_CHECK_ROOT="$W/cc" bash "$C" 2>&1); _r=$?
[ "$_r" != 0 ] && printf '%s' "$_o" | grep -q '62-cygnus-screensaver-default.sh' && ok "check-server-codename: a second, unlisted literal on an allow-listed line is still a hit" || bad "check-server-codename: per-line allow masked a literal: $_o"
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

# --- 12. dry run of the gate wiring: the matrix runs the UI check in the server set, and the gate --
#     hands it NCZ_UI_CHECK_VARIANT=server (real matrix + the gate's real dispatch block, stub gate/check)
mkdir -p "$W/dry/bin"; cp "$ROOT/build/kvm-install-gate-matrix.sh" "$W/dry/bin/"; mkdir -p "$W/dry/bin/lib"
cat > "$W/dry/bin/kvm-install-gate-gpt.sh" <<'STUB'
#!/bin/bash
echo "STUB set=$(basename "$2") ui=$NCZ_GATE_UI_CHECK server=$NCZ_GATE_SERVER offline=$NCZ_GATE_SERVER_OFFLINE comps=$NCZ_GATE_COMPONENTS"
[ "$NCZ_GATE_SERVER_OFFLINE" = 1 ] && echo "GATE PASS (server-offline-negative): stub" || echo "GATE PASS (phase 1+2): stub"
STUB
chmod +x "$W/dry/bin/kvm-install-gate-gpt.sh"; : > "$W/dry/img.img"
_m=$(bash "$W/dry/bin/kvm-install-gate-matrix.sh" "$W/dry/img.img" "$W/dry/work" full server server-offline-negative nodesktop 2>&1)
case "$_m" in *"use a directory on disk"*)   # the matrix refuses a tmpfs work root; run it on disk
    _dd=$(mktemp -d "$ROOT/../.ncz-srv-brand-dry.XXXXXX");   # beside the tree, never inside it
 _m=$(bash "$W/dry/bin/kvm-install-gate-matrix.sh" "$W/dry/img.img" "$_dd/work" full server server-offline-negative nodesktop 2>&1); rm -rf "$_dd" ;;
esac
printf '%s\n' "$_m" | grep -q '^STUB set=server ui=1 server=1 offline=0 comps=rescue-partition$' && ok "matrix dry run: the server set runs the UI check" || bad "matrix dry run: server set: $(printf '%s\n' "$_m" | grep STUB)"
printf '%s\n' "$_m" | grep -q '^STUB set=server-offline-negative ui=0 ' && ok "matrix dry run: the offline-negative set does not" || bad "matrix dry run: offline set"
printf '%s\n' "$_m" | grep -q '^STUB set=full ui=1 ' && printf '%s\n' "$_m" | grep -q '^STUB set=nodesktop ui=0 ' && ok "matrix dry run: desktop sets unchanged (full ui=1, nodesktop ui=0)" || bad "matrix dry run: desktop sets"
awk '/echo "  installer console UI check/{f=1} f{print} f && /^fi$/{exit}' "$ROOT/build/kvm-install-gate-gpt.sh" > "$W/dry/ui-block.sh"
cat > "$W/dry/bin/kvm-installer-ui-check.sh" <<'STUB'
#!/bin/bash
echo "UI-STUB variant=${NCZ_UI_CHECK_VARIANT:-unset} img=$1 arch=$2"
STUB
chmod +x "$W/dry/bin/kvm-installer-ui-check.sh"
uidry() { bash -c "fail() { echo \"GATEFAIL \$*\"; }; SCRIPT_DIR='$W/dry/bin'; IMG=x.img; ARCH=amd64; WORK='$W/dry'; NCZ_GATE_SERVER=$1; NCZ_GATE_UI_CHECK=1; . '$W/dry/ui-block.sh'" 2>&1; }
uidry 1 | grep -q 'UI-STUB variant=server' && ok "gate dry run: a server run calls the UI check with NCZ_UI_CHECK_VARIANT=server" || bad "gate dry run server: $(uidry 1)"
uidry 0 | grep -q 'UI-STUB variant=desktop' && ok "gate dry run: a desktop run calls it with the desktop contract" || bad "gate dry run desktop: $(uidry 0)"
# build-image.sh's server gate runner: sudo's env_reset drops everything not on its command line, so the pyte
# interpreter the UI check needs (the /root/ncz-pyte-venv the image build provisions) must be passed there, as the
# desktop runner does. Run the real stage_kvm_gate_server with a stub ncz_sudo_bash that prints its command.
awk '/^stage_kvm_gate_server\(\) \{$/{f=1} f{print} f && /^\}$/{exit}' "$ROOT/build/build-image.sh" > "$W/dry/srv-runner.sh"
mkdir -p "$W/dry/mag"; : > "$W/dry/mag/base.squashfs"; : > "$W/dry/mag/ncz-assets-amd64.tar.gz"; : > "$W/dry/mag/ncz-pool-amd64.tar.gz"
_sr=$(bash -c "ncz_sudo_bash() { echo \"SUDO: \$*\"; echo 'MATRIX PASS'; }
    ROOT='$ROOT'; RUN_DIR='$W/dry'; ARCH=amd64; MAGNETAR_DIR='$W/dry/mag'; unset NCZ_PYTE_PYTHON
    . '$W/dry/srv-runner.sh'; pyvenv=/root/ncz-pyte-venv; stage_kvm_gate_server '$W/dry/srv.log' '$W/dry/img.img' '$W/dry/kw' 0:0 /root/ncz-pyte-venv" 2>&1)
printf '%s\n' "$_sr" | grep '^SUDO: ' | grep -q "NCZ_PYTE_PYTHON='/root/ncz-pyte-venv/bin/python'" \
    && ok "build-image: the server gate runner passes NCZ_PYTE_PYTHON through sudo (the UI check finds pyte)" \
    || bad "build-image: the server gate runner's sudo line has no NCZ_PYTE_PYTHON: $(printf '%s\n' "$_sr" | grep '^SUDO: ' | cut -c1-300)"
grep -q '^ui=server$' "$W/dry/kvm-gate.result" 2>/dev/null && ok "build-image: the server gate result records ui=server" || bad "build-image: kvm-gate.result ui field: $(grep '^ui=' "$W/dry/kvm-gate.result" 2>/dev/null)"

if [ "$FAIL" != 0 ]; then echo "test-server-branding: FAIL" >&2; exit 1; fi
echo "test-server-branding: PASS"
