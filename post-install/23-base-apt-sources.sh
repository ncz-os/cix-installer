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
        : "${NCZ_RUNTIME_MIRROR:?Debian profile requires NCZ_RUNTIME_MIRROR}"
        : "${NCZ_BASE_CODENAME:?Debian profile requires NCZ_BASE_CODENAME}"
        : "${NCZ_BASE_COMPONENTS:?Debian profile requires NCZ_BASE_COMPONENTS}"
        # Rule since 2026-10-08: only Debian forky. No other suite, ever.
        if [ "$NCZ_BASE_CODENAME" != "forky" ]; then
            echo "[23] FATAL: base suite is '${NCZ_BASE_CODENAME}', only Debian forky is allowed" >&2
            exit 1
        fi
        case "$NCZ_RUNTIME_MIRROR" in
            *ubuntu*|*launchpad*) echo "[23] FATAL: runtime mirror ${NCZ_RUNTIME_MIRROR} is not a Debian archive" >&2; exit 1 ;;
        esac
        KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
        [ -s "$KEYRING" ] || { echo "[23] FATAL: missing $KEYRING" >&2; exit 1; }
        install -d -m 0755 /etc/apt/sources.list.d
        # Never leave any foreign archive as a live fallback on the image.
        rm -f /etc/apt/sources.list
        find /etc/apt/sources.list.d -maxdepth 1 -type f \
            -iname '*ubuntu*' -delete
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
        for _opt in ${NCZ_RUNTIME_MIRROR_APT_OPTS:-}; do
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
URIs: ${NCZ_RUNTIME_MIRROR}
Suites: ${NCZ_BASE_CODENAME}
Components: ${NCZ_BASE_COMPONENTS}
Signed-By: ${KEYRING}
EOF
            printf '%s' "$NCZ_APT_EXTRA_FIELDS"
        } > /etc/apt/sources.list.d/ncz-base.sources
        echo "[23] configured Debian ${NCZ_BASE_CODENAME} base: ${NCZ_RUNTIME_MIRROR}"
        if [ -n "$NCZ_APT_EXTRA_FIELDS" ]; then
            echo "[23] applied mirror options: $(printf '%s' "$NCZ_APT_EXTRA_FIELDS" | tr '\n' ' ')"
        fi
        # Prove the file apt will really read, not the script that wrote it.
        # Guard on the URI we actually wrote, not on the build-time pin:
        # the installed system now tracks NCZ_RUNTIME_MIRROR, which is
        # normally unpinned and must NOT carry Check-Valid-Until: no.
        case "${NCZ_RUNTIME_MIRROR}" in
            *snapshot.debian.org*)
                if ! grep -qi '^Check-Valid-Until:[[:space:]]*no' \
                        /etc/apt/sources.list.d/ncz-base.sources; then
                    echo "[23] FATAL: runtime mirror is a snapshot (${NCZ_RUNTIME_MIRROR}) but ncz-base.sources has no Check-Valid-Until: no -- apt would start refusing updates the moment that snapshot's Release expires" >&2
                    exit 1
                fi
                echo "[23] WARNING: installed system is pinned to a snapshot and will not receive updates"
                ;;
            *)
                if grep -qi '^Check-Valid-Until:[[:space:]]*no' \
                        /etc/apt/sources.list.d/ncz-base.sources; then
                    echo "[23] FATAL: runtime mirror ${NCZ_RUNTIME_MIRROR} is not a snapshot, so Check-Valid-Until: no must not be set -- that would suppress genuine Release expiry" >&2
                    exit 1
                fi
                ;;
        esac
        ;;
    Ubuntu)
        echo "[23] FATAL: Ubuntu base profiles are not supported (rule since 2026-10-08: no Ubuntu debs, ever)" >&2
        exit 1
        ;;
    *)
        echo "[23] FATAL: unsupported NCZ_BASE_NAME=${NCZ_BASE_NAME:-unset}" >&2
        exit 1
        ;;
esac
