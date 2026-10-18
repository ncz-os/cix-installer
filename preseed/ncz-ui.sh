#!/bin/sh
# ncz-ui.sh -- shared look of every NCZ d-i dialog (arm64 and amd64). Sourced by the helpers; POSIX sh (busybox ash).
#
#   ncz_ui_brand   "NCZ-OS 26.10 Cygnus"           (dialog frame titles)
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
