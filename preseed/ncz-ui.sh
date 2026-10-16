#!/bin/sh
# ncz-ui.sh -- shared look of every NCZ d-i dialog (arm64 and amd64). Sourced by the helpers; POSIX sh (busybox ash).
#
#   ncz_ui_brand   "NCZ-OS 26.7 Maximilian"        (dialog frame titles)
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
    while IFS= read -r _l; do
        case "$_l" in "$2="*) _v=${_l#*=}; _v=${_v#\"}; _v=${_v%\"}; echo "$_v"; return 0 ;; esac
    done < "$1"
}

ncz_ui_brand() {
    _dir=$(_ncz_ui_dir) || { echo "NCZ-OS"; return 0; }
    _rv=$(_ncz_ui_field "$_dir/RELEASE" NCZ_RELEASE_VERSION)
    _rc=$(_ncz_ui_field "$_dir/RELEASE" NCZ_RELEASE_CODENAME)
    echo "NCZ-OS${_rv:+ $_rv}${_rc:+ $_rc}"
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
    echo "${_arch}${_bv:+ | build ${_bv##*-}}${_dl:+ | $_dl}"
}
