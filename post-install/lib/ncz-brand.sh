#!/bin/sh
# ncz-brand.sh -- the one place that names the NCZ-OS server edition and decides
# whether a medium (or an installed system) is a Magnetar Server one.
#
# POSIX sh: sourced by busybox ash in d-i (preseed/ncz-ui.sh, preseed/late.sh,
# preseed/component-selector.sh, from the medium's ncz-payload/post-install/lib/),
# by bash on the installed system (post-install/50-brand.sh, 48-server-variant.sh,
# the rEFInd generators, the ncz CLI, from /usr/local/lib/cix-installer/
# post-install/lib/), and read by build/iso/build-refind-esp.py for the
# installer boot menu (it parses NCZ_SERVER_EDITION below).
#
# Desktop text is never built here. Every caller keeps its own desktop label
# ("NCZ-OS 26.10 Cygnus" and its variants) and passes it in; for a desktop
# medium ncz_brand_label prints that label back unchanged, so desktop output
# stays byte-identical by construction.
#
# The server signal is the MEDIUM, not the component choice:
#   * a Magnetar Server medium carries ncz-payload/ncz-fetch-payload.manifest
#     (build/iso/write-usb-image.py writes it only for NCZ_VARIANT=server);
#   * preseed/late.sh records that as /usr/local/lib/cix-installer/MEDIUM_VARIANT
#     on the installed system.
# BUILD_VARIANT is deliberately not used: a desktop medium installed with the
# desktop component off records BUILD_VARIANT=server too, and that install is
# a desktop-medium install (it keeps the desktop branding).

NCZ_SERVER_EDITION="Magnetar Server"

# ncz_brand_medium_variant DIR... -> "server" when any DIR is a Magnetar Server
# medium's payload directory or an installed copy of it, else "desktop".
# NCZ_BRAND_MEDIUM=server|desktop overrides (tests).
ncz_brand_medium_variant() {
    case "${NCZ_BRAND_MEDIUM:-}" in
        server|desktop) echo "$NCZ_BRAND_MEDIUM"; return 0 ;;
    esac
    for _ncz_bd in "$@"; do
        [ -n "$_ncz_bd" ] || continue
        if [ -f "$_ncz_bd/ncz-fetch-payload.manifest" ]; then
            echo server; return 0
        fi
        if [ -r "$_ncz_bd/MEDIUM_VARIANT" ]; then
            case "$(tr -d ' \t\r\n' < "$_ncz_bd/MEDIUM_VARIANT" 2>/dev/null)" in
                server) echo server; return 0 ;;
            esac
        fi
    done
    echo desktop
}

# ncz_brand_label VARIANT DESKTOP_LABEL [PRODUCT [VERSION]]
#   desktop (or anything but server): DESKTOP_LABEL, unchanged
#   server: "<PRODUCT>[ <VERSION>] Magnetar Server", e.g. "NCZ-OS 26.10 Magnetar Server"
#           (where the desktop says "NCZ-OS 26.10 Cygnus"; PRODUCT defaults to NCZ-OS)
# Short dialog titles use the edition alone: "$NCZ_SERVER_EDITION - Step n of N: ...".
ncz_brand_label() {
    case "$1" in
        server) echo "${3:-NCZ-OS}${4:+ $4} ${NCZ_SERVER_EDITION}" ;;
        *) printf '%s\n' "$2" ;;
    esac
}
