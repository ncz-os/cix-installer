#!/bin/sh
# ncz-ui.sh -- shared look of every NCZ d-i dialog (arm64 and amd64). Sourced by the helpers; POSIX sh (busybox ash).
#
#   ncz_ui_brand   "NCZ-OS 26.7 Maximilian"        (dialog frame titles)
#   ncz_ui_id      "arm64 (Sky1) | build 7e1d9c2"  (last line of every dialog body)
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

ncz_ui_id() {
    _arch=""; _bv=""
    if _dir=$(_ncz_ui_dir); then
        [ -r "$_dir/BUILD_ARCH" ] && read -r _arch < "$_dir/BUILD_ARCH"
        [ -r "$_dir/BUILD_VERSION" ] && read -r _bv < "$_dir/BUILD_VERSION"
    fi
    [ -n "$_arch" ] || case "$(uname -m 2>/dev/null)" in aarch64) _arch=arm64 ;; x86_64) _arch=amd64 ;; *) _arch=$(uname -m 2>/dev/null) ;; esac
    case "$_arch" in arm64) _arch="arm64 (Sky1)" ;; esac
    echo "${_arch}${_bv:+ | build ${_bv##*-}}"
}
