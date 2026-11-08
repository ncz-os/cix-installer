#!/bin/bash
# build-server-online.sh -- build the ONLINE (Magnetar option B) server medium.
#
# The release server medium pins three PUBLISHED payload files (base.squashfs,
# ncz-assets-<arch>.tar.gz, ncz-pool-<arch>.tar.gz) and fetches them at install
# time; it must not be self-contained (that is the offline fallback and blows
# past 4 GiB). This wrapper exists so the release step is one command and the
# published-base rule is enforced, not remembered:
#   * --base-url must be https:// (a LAN/local URL is refused by design);
#   * the three files must exist under that base (checked by the KVM gate, not
#     here -- nothing is uploaded by this script);
#   * the build never publishes.
#
# Usage:
#   build/build-server-online.sh --arch amd64 --base-url https://host/prefix [--run-dir DIR]
#   build/build-server-online.sh --arch arm64 --base-url ... --run-dir ...
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ARCH=""; BASE=""; RUN=""; PLAN=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?--arch needs amd64|arm64}"; shift 2 ;;
        --base-url) BASE="${2:?--base-url needs a URL}"; shift 2 ;;
        --run-dir) RUN="${2:?--run-dir needs a directory}"; shift 2 ;;
        --plan) PLAN=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-server-online: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$ARCH" ] && [ -n "$BASE" ] || { echo "build-server-online: --arch and --base-url are required" >&2; exit 2; }
case "$ARCH" in amd64|arm64) ;; *) echo "build-server-online: --arch must be amd64 or arm64" >&2; exit 2 ;; esac
base="${BASE%/}"
case "$base" in
    https://*) ;;
    *) echo "build-server-online: --base-url must be https:// (published media never pin http/LAN URLs): $BASE" >&2; exit 2 ;;
esac
case "$base" in
    *://localhost*|*://127.*|*://10.*|*://192.168.*|*://172.1[6-9].*|*://172.2[0-9].*|*://172.3[01].*)
        echo "build-server-online: --base-url is a LAN/local address; a release medium must use the published host: $BASE" >&2
        exit 2 ;;
esac
if [ -z "$RUN" ]; then
    RUN="$ROOT/../server-online-$ARCH-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RUN" || exit 2

echo "build-server-online: arch=$ARCH base=$base"
echo "build-server-online: run dir $RUN"
echo "build-server-online: this build does NOT publish; the KVM gate verifies the fetch from $base"
echo "build-server-online: payload files the medium will pin: base.squashfs, ncz-assets-$ARCH.tar.gz, ncz-pool-$ARCH.tar.gz"
if [ "$PLAN" = 1 ]; then
    echo "build-server-online: plan only; no build"
    exit 0
fi
exec env NCZ_VARIANT=server NCZ_SERVER_PAYLOAD=online NCZ_PAYLOAD_BASE_URL="$base" \
    bash "$ROOT/build/build-image.sh" --arch "$ARCH" --full --sources pinned --substrate pinned --no-publish \
    --run-dir "$RUN"
