#!/bin/bash
# 23-base-apt-sources.sh — install the configured upstream APT base before
# NCZ's own package repositories are refreshed by 24-apt-sources.sh.
set -euo pipefail

HERE="$(dirname "$0")"
RELEASE=/usr/local/lib/cix-installer/RELEASE
[ -r "$RELEASE" ] || RELEASE="$HERE/../RELEASE"
[ -r "$RELEASE" ] || { echo "[23] FATAL: release profile missing" >&2; exit 1; }
# shellcheck disable=SC1090
. "$RELEASE"

case "${NCZ_BASE_NAME:-}" in
    Debian)
        : "${NCZ_BASE_MIRROR:?Debian profile requires NCZ_BASE_MIRROR}"
        : "${NCZ_BASE_CODENAME:?Debian profile requires NCZ_BASE_CODENAME}"
        : "${NCZ_BASE_COMPONENTS:?Debian profile requires NCZ_BASE_COMPONENTS}"
        KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
        [ -s "$KEYRING" ] || { echo "[23] FATAL: missing $KEYRING" >&2; exit 1; }
        install -d -m 0755 /etc/apt/sources.list.d
        # Never leave Ubuntu Ports as a live fallback on a Debian-profiled image.
        rm -f /etc/apt/sources.list
        find /etc/apt/sources.list.d -maxdepth 1 -type f \
            \( -iname '*ubuntu*' -o -iname '*resolute*' \) -delete
        # release.conf sets NCZ_BASE_MIRROR_APT_OPTS (currently
        # "check-valid-until=no") precisely BECAUSE a pinned
        # snapshot.debian.org Release file carries a short Valid-Until and DOES
        # expire -- its own comment says every consumer must pass it through or
        # "every fetch against a pinned snapshot fails closed". This file, the
        # only thing that writes the INSTALLED system's base repo, was not
        # passing it through. Measured 2026-09-24: the pinned 20260920T203924Z
        # snapshot's forky Release says
        #     Valid-Until: Sun, 27 Sep 2026 20:12:51 UTC
        # so every machine installed from this build would have started
        # refusing "apt update" three days later, on a system that worked when
        # it was handed over. These are one-line-format options in release.conf
        # and deb822 fields here, so translate rather than paste.
        NCZ_APT_EXTRA_FIELDS=""
        for _opt in ${NCZ_BASE_MIRROR_APT_OPTS:-}; do
            case "$_opt" in
                check-valid-until=*)
                    NCZ_APT_EXTRA_FIELDS="${NCZ_APT_EXTRA_FIELDS}Check-Valid-Until: ${_opt#*=}
" ;;
                trusted=*)
                    NCZ_APT_EXTRA_FIELDS="${NCZ_APT_EXTRA_FIELDS}Trusted: ${_opt#*=}
" ;;
                *)
                    echo "[23] FATAL: unhandled NCZ_BASE_MIRROR_APT_OPTS token '$_opt' -- refusing to silently drop an option release.conf says is required" >&2
                    exit 1 ;;
            esac
        done
        {
            cat <<EOF
Types: deb
URIs: ${NCZ_BASE_MIRROR}
Suites: ${NCZ_BASE_CODENAME}
Components: ${NCZ_BASE_COMPONENTS}
Signed-By: ${KEYRING}
EOF
            printf '%s' "$NCZ_APT_EXTRA_FIELDS"
        } > /etc/apt/sources.list.d/ncz-base.sources
        echo "[23] configured Debian ${NCZ_BASE_CODENAME} base: ${NCZ_BASE_MIRROR}"
        if [ -n "$NCZ_APT_EXTRA_FIELDS" ]; then
            echo "[23] applied mirror options: $(printf '%s' "$NCZ_APT_EXTRA_FIELDS" | tr '\n' ' ')"
        fi
        # Prove the file apt will really read, not the script that wrote it.
        if [ -n "${NCZ_BASE_MIRROR_SNAPSHOT:-}" ] && \
           ! grep -qi '^Check-Valid-Until:[[:space:]]*no' \
                /etc/apt/sources.list.d/ncz-base.sources; then
            echo "[23] FATAL: pinned to snapshot ${NCZ_BASE_MIRROR_SNAPSHOT} but ncz-base.sources has no Check-Valid-Until: no -- apt would start refusing updates the moment that snapshot's Release expires" >&2
            exit 1
        fi
        ;;
    Ubuntu)
        echo "[23] retaining Ubuntu base sources for this profile"
        ;;
    *)
        echo "[23] FATAL: unsupported NCZ_BASE_NAME=${NCZ_BASE_NAME:-unset}" >&2
        exit 1
        ;;
esac
