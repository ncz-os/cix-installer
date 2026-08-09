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
        cat > /etc/apt/sources.list.d/ncz-base.sources <<EOF
Types: deb
URIs: ${NCZ_BASE_MIRROR}
Suites: ${NCZ_BASE_CODENAME}
Components: ${NCZ_BASE_COMPONENTS}
Signed-By: ${KEYRING}
EOF
        echo "[23] configured Debian ${NCZ_BASE_CODENAME} base: ${NCZ_BASE_MIRROR}"
        ;;
    Ubuntu)
        echo "[23] retaining Ubuntu base sources for this profile"
        ;;
    *)
        echo "[23] FATAL: unsupported NCZ_BASE_NAME=${NCZ_BASE_NAME:-unset}" >&2
        exit 1
        ;;
esac
