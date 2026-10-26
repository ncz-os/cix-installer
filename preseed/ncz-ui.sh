#!/bin/sh
# ncz-ui.sh -- shared look of every NCZ d-i dialog (arm64 and amd64). Sourced by the helpers; POSIX sh (busybox ash).
#
#   ncz_ui_brand   "NCZ-OS 26.10 Cygnus"           (dialog frame titles; "NCZ-OS 26.10 Magnetar Server" on a server medium)
#   ncz_ui_title   "[n/8] NCZ-OS 26.10 Cygnus - ..." | "Magnetar Server - Step n of 7: ..." (dialog titles)
#   ncz_ui_variant "desktop" | "server"            (which medium this is; post-install/lib/ncz-brand.sh)
#   ncz_ui_id      "arm64 (Sky1) | build 7e1d9c2 | diagnostics login: root / rescue"  (last line of every dialog body)
#   ncz_ui_diag_login  "diagnostics login: root / rescue" (empty when ncz_diag=0), also in the boot banner
#
# The identity comes from the payload on the install medium (RELEASE, BUILD_VERSION, BUILD_ARCH); when a file is
# missing the plain product name and `uname -m` are used, so a dialog is never blank. Output is ASCII on purpose:
# the newt frontend runs in the C locale in early d-i and an em dash rendered "<ERR>" and cut the title.
# NCZ_UI_PAYLOAD overrides the payload directory (tests).

_ncz_ui_dir() {
    for _d in "${NCZ_UI_PAYLOAD:-}" /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
        [ -n "$_d" ] && [ -r "$_d/BUILD_VERSION" ] && { echo "$_d"; return 0; }
    done
    return 1
}

_ncz_ui_field() {   # file key -> value of KEY="value" (quotes stripped)
    [ -r "$1" ] || return 0
    # `read` returns non-zero on a final line with no trailing newline, so a
    # truncated/tampered file would silently lose that field. Consume the
    # partial line too (|| [ -n "$_l" ]) rather than dropping it.
    while IFS= read -r _l || [ -n "$_l" ]; do
        case "$_l" in "$2="*) _v=${_l#*=}; _v=${_v#\"}; _v=${_v%\"}; echo "$_v"; return 0 ;; esac
    done < "$1"
}

# ncz_ui_brand -- the product identity in every dialog frame title.
#
# AUTHORITATIVE FIRST (S1-1). The release identity must come from the build's
# own release.conf, which build/iso/patch-initrd-t2-kernel.py bakes into the
# initrd as /ncz/RELEASE at the same moment it bakes /preseed.cfg -- gated so a
# build whose release.conf is unreadable FAILS rather than shipping a stale
# identity. The medium's /ncz-payload/RELEASE (release.conf verbatim, staged by
# build/iso/write-usb-image.py) is the FALLBACK only: on a medium written from
# an older tree while the initrd was baked fresh (or a tampered/stale medium
# copy) the baked identity still wins, so the retired name can never reach the
# installer dialogs. The payload directory remains the source for build metadata
# (BUILD_VERSION / BUILD_ARCH, see ncz_ui_id below).
#
# Search order:
#   /ncz/RELEASE                       baked from release.conf (authoritative)
#   <payload dir>/RELEASE              install medium (fallback)
# NCZ_UI_RELEASE overrides the authoritative file (tests).
_ncz_ui_release_files() {
    [ -n "${NCZ_UI_RELEASE:-}" ] && printf '%s\n' "${NCZ_UI_RELEASE}"
    printf '%s\n' /ncz/RELEASE
    _dir=$(_ncz_ui_dir) && printf '%s\n' "$_dir/RELEASE"
}

ncz_ui_brand() {
    _rv=""; _rc=""
    for _f in $(_ncz_ui_release_files); do
        [ -r "$_f" ] || continue
        _rv=$(_ncz_ui_field "$_f" NCZ_RELEASE_VERSION)
        _rc=$(_ncz_ui_field "$_f" NCZ_RELEASE_CODENAME)
        [ -n "$_rv$_rc" ] && break
    done
    _ncz_lbl="NCZ-OS${_rv:+ $_rv}${_rc:+ $_rc}"
    # A Magnetar Server medium names its edition instead of the desktop
    # codename (post-install/lib/ncz-brand.sh); a desktop medium prints the
    # line above unchanged.
    if [ "$(ncz_ui_variant)" = server ] && _ncz_ui_brand_lib; then
        _ncz_lbl=$(ncz_brand_label server "$_ncz_lbl" NCZ-OS "$_rv")
    fi
    echo "$_ncz_lbl"
}

# _ncz_ui_brand_lib -- source the medium's post-install/lib/ncz-brand.sh, the one
# place that names the server edition. NCZ_BRAND_SH overrides (tests). Returns 1
# when it cannot be found.
_ncz_ui_brand_lib() {
    command -v ncz_brand_label >/dev/null 2>&1 && return 0
    _ncz_bdir=$(_ncz_ui_dir) || _ncz_bdir=""
    for _ncz_bl in "${NCZ_BRAND_SH:-}" \
                   "${NCZ_MEDIA_DIR:+$NCZ_MEDIA_DIR/post-install/lib/ncz-brand.sh}" \
                   "${_ncz_bdir:+$_ncz_bdir/post-install/lib/ncz-brand.sh}"; do
        [ -n "$_ncz_bl" ] && [ -r "$_ncz_bl" ] && . "$_ncz_bl" && return 0
    done
    return 1
}

# ncz_ui_variant -- "server" when the install medium is a Magnetar Server medium
# (its ncz-payload/ carries ncz-fetch-payload.manifest), else "desktop". Read from
# the medium, which partman/early_command has mounted (NCZ_MEDIA_DIR) before the
# first operator-facing dialog. NCZ_UI_VARIANT=server|desktop overrides (tests).
ncz_ui_variant() {
    case "${NCZ_UI_VARIANT:-}" in server|desktop) echo "$NCZ_UI_VARIANT"; return 0 ;; esac
    _ncz_vdir=$(_ncz_ui_dir) || _ncz_vdir=""
    if _ncz_ui_brand_lib; then
        ncz_brand_medium_variant "${NCZ_MEDIA_DIR:-}" "$_ncz_vdir"
        return 0
    fi
    # No helper on the medium: the same marker test, so a server medium never
    # falls back to the desktop flow just because a file is missing.
    for _ncz_vd in "${NCZ_MEDIA_DIR:-}" "$_ncz_vdir"; do
        [ -n "$_ncz_vd" ] && [ -f "$_ncz_vd/ncz-fetch-payload.manifest" ] && { echo server; return 0; }
    done
    echo desktop
}

# The installer diagnostics login (preseed/diag-console.sh, network-console) is the documented
# rescue-partition login, root / rescue (docs/RECOVERY-LOGINS.md). It exists only in the installer
# environment and is shown on every console while the installer runs. ncz_diag_pw=<pw> on the boot
# line replaces it (the value is then not shown); ncz_diag=0 turns diagnostics off.
NCZ_DIAG_LOGIN_DEFAULT=rescue
ncz_ui_diag_login() {
    _ncz_cl=$(cat "${NCZ_UI_CMDLINE:-/proc/cmdline}" 2>/dev/null)
    _ncz_dg=""; _ncz_pw=""
    for _t in $_ncz_cl; do
        case "$_t" in ncz_diag=*) _ncz_dg=${_t#ncz_diag=} ;; ncz_diag_pw=*) _ncz_pw=set ;; esac
    done
    case "$_ncz_dg" in 0|off|no|false|disable|disabled) return 0 ;; esac
    if [ -n "$_ncz_pw" ]; then echo "diagnostics login: root / set by ncz_diag_pw"
    else echo "diagnostics login: root / $NCZ_DIAG_LOGIN_DEFAULT"; fi
}

# ncz_ui_step <n> -- "[n/TOTAL] " prefix for a dialog Description line, the
# persistent per-stage mark docs/INSTALLER-BOOT-UX.md names as not built
# ("a persistent stage list with per-stage marks"). This is debconf's own
# Description field, not a bespoke overlay -- every dialog already carries
# one line of brand text via ncz_ui_brand; this just numbers it. TOTAL is the
# count of real operator-facing screens in the actual partman/early_command
# sequence (preseed/preseed.cfg): region(1), username/password/confirm(3),
# components(1), disk/root-fs/erase-confirm(3) = 8. hostname-suggest.sh and
# locale-keyboard-chooser.sh are NOT in that sequence (hostname is automatic;
# locale-keyboard-chooser.sh is not invoked by early_command) so they are not
# numbered and do not count toward TOTAL.
NCZ_UI_TOTAL_STEPS=8
ncz_ui_step() {
    echo "[${1}/${NCZ_UI_TOTAL_STEPS}] "
}

# ncz_ui_title N DESKTOP_TEXT SERVER_ACTION -- one dialog title (debconf Description).
#   desktop medium: "[N/8] NCZ-OS 26.10 Cygnus - DESKTOP_TEXT", exactly the title the
#                   dialogs carried before (no step mark when N is empty)
#   server medium:  "Magnetar Server - Step n of 7: SERVER_ACTION". The full edition
#                   name ("NCZ-OS 26.10 Magnetar Server") is on the id line (ncz_ui_id),
#                   so the title fits d-i's ~61 columns. A server medium has no
#                   component dialog (step 5): disk / root fs / erase confirm are
#                   steps 5, 6 and 7 of 7. N empty: "Magnetar Server - SERVER_ACTION".
ncz_ui_title() {
    if [ "$(ncz_ui_variant)" = server ] && _ncz_ui_brand_lib; then
        if [ -n "$1" ]; then
            _ncz_sn=$1
            [ "$_ncz_sn" -gt 5 ] 2>/dev/null && _ncz_sn=$((_ncz_sn - 1))
            echo "${NCZ_SERVER_EDITION} - Step ${_ncz_sn} of $((NCZ_UI_TOTAL_STEPS - 1)): $3"
        else
            echo "${NCZ_SERVER_EDITION} - $3"
        fi
        return 0
    fi
    if [ -n "$1" ]; then
        echo "$(ncz_ui_step "$1")$(ncz_ui_brand) - $2"
    else
        echo "$(ncz_ui_brand) - $2"
    fi
}

ncz_ui_id() {
    _arch=""; _bv=""
    if _dir=$(_ncz_ui_dir); then
        [ -r "$_dir/BUILD_ARCH" ] && read -r _arch < "$_dir/BUILD_ARCH"
        [ -r "$_dir/BUILD_VERSION" ] && read -r _bv < "$_dir/BUILD_VERSION"
    fi
    [ -n "$_arch" ] || case "$(uname -m 2>/dev/null)" in aarch64) _arch=arm64 ;; x86_64) _arch=amd64 ;; *) _arch=$(uname -m 2>/dev/null) ;; esac
    # Only label arm64 as Sky1 when the hardware actually matches: the Cix
    # Sky1 (CP8180) SoC reports itself in /proc/cpuinfo and its device-tree
    # compatible strings, the same probe 50-brand.sh's ncz-hw-brand uses.
    # Any other arm64 board keeps the plain arch name.
    case "$_arch" in
        arm64)
            # NCZ_UI_SKY1 is a test seam (build/test-ncz-ui.sh): it decides the
            # probe outcome instead of reading host hardware.
            case "${NCZ_UI_SKY1:-}" in
                1) _is_sky1=1 ;;
                0) _is_sky1=0 ;;
                *) if grep -qi 'sky1\|cp8180\|cix' /proc/cpuinfo \
                         /sys/firmware/devicetree/base/compatible 2>/dev/null; then
                        _is_sky1=1
                    else
                        _is_sky1=0
                    fi
                    ;;
            esac
            [ "$_is_sky1" = 1 ] && _arch="arm64 (Sky1)"
            ;;
    esac
    _dl=$(ncz_ui_diag_login)
    # A server medium's dialog titles carry only "Magnetar Server"; the full
    # edition name leads the id line instead.
    _ncz_idb=""
    [ "$(ncz_ui_variant)" = server ] && _ncz_idb="$(ncz_ui_brand) | "
    echo "${_ncz_idb}${_arch}${_bv:+ | build ${_bv##*-}}${_dl:+ | $_dl}"
}
