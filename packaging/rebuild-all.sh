#!/bin/bash
# Rebuild every NCZ media-stack .deb from current sources and publish them.
#
# Run this after ANY change to the driver, ffmpeg or Chromium. The three
# packages are versioned by date and rebuilt together, because they are tested
# together: shipping a new driver against a stale browser deb is how a
# combination reaches users that nobody ever ran.
#
# Artifacts are collected here, then published with publish-apt.sh.
#
#   ./rebuild-all.sh [--publish <suite>]
#
# Sources are pulled from the hosts that build them:
#   driver + ffmpeg   board  (arm64, where the driver is built and tested)
#   chromium          HYDRA  (x86 cross-build host)
set -u

BOARD="${NCZ_BOARD:-root@192.168.207.3}"
CROSSBUILD="${NCZ_CROSSBUILD:-jasonperlow@192.168.207.78}"
CHROMIUM_VER="${NCZ_CHROMIUM_VER:-151.0.7922.75}"
STAMP="$(date -u +%Y%m%d)"
OUT="${NCZ_DEB_OUT:-$PWD/debs}"
PUBLISH_SUITE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --publish) PUBLISH_SUITE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

echo "=== driver + ffmpeg (on $BOARD) ==="
scp -q "$HERE/cix-vaapi/make-deb.sh" "$BOARD:/root/mk-driver.sh"
scp -q "$HERE/ffmpeg/make-deb.sh"    "$BOARD:/root/mk-ffmpeg.sh"
# shellcheck disable=SC2029
ssh "$BOARD" "mkdir -p /root/ncz-debs && cd /root/ncz-debs && rm -f *.deb && \
    bash /root/mk-driver.sh /usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so $STAMP && \
    bash /root/mk-ffmpeg.sh /opt/cix-ffmpeg $STAMP" || FAIL=1
scp -q "$BOARD:/root/ncz-debs/*.deb" "$OUT/" 2>/dev/null || FAIL=1

echo "=== chromium (on $CROSSBUILD) ==="
scp -q "$HERE/chromium/make-deb.sh" "$CROSSBUILD:/tmp/mk-chromium.sh"
# shellcheck disable=SC2029
ssh "$CROSSBUILD" "mkdir -p ~/ncz-debs && cd ~/ncz-debs && rm -f *.deb && \
    bash /tmp/mk-chromium.sh ~/chromium-build/src/out/sky1 $CHROMIUM_VER $STAMP stable" || FAIL=1
scp -q "$CROSSBUILD:~/ncz-debs/*.deb" "$OUT/" 2>/dev/null || FAIL=1

echo "=== collected ==="
ok=0
for d in "$OUT"/*.deb; do
    [ -e "$d" ] || continue
    # A .deb that dpkg cannot read, or one implausibly small, has shipped from
    # a build that exited 0 before now. Check both.
    if ! dpkg-deb --info "$d" >/dev/null 2>&1; then
        echo "  INVALID  $(basename "$d")"; FAIL=1; continue
    fi
    sz=$(stat -f %z "$d" 2>/dev/null || stat -c %s "$d")
    if [ "$sz" -lt 100000 ]; then
        echo "  TOO SMALL ($sz B)  $(basename "$d")"; FAIL=1; continue
    fi
    printf '  %-52s %s MiB\n' "$(basename "$d")" "$((sz / 1048576))"
    ok=$((ok + 1))
done
[ "$ok" -eq 3 ] || { echo "  expected 3 packages, got $ok"; FAIL=1; }

if [ -n "$PUBLISH_SUITE" ]; then
    [ "$FAIL" = 0 ] || { echo "not publishing: rebuild had failures" >&2; exit 1; }
    echo "=== publishing to $PUBLISH_SUITE ==="
    "$HERE/publish-apt.sh" "$PUBLISH_SUITE" "$OUT"/*.deb || exit 1
fi

exit "$FAIL"
