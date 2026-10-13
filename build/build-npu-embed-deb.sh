#!/bin/bash
# build-npu-embed-deb.sh -- package the NPU embedding server (ncz-npu-embed) from this tree.
#
# The published 1.0.0 was built outside the repo: its server copy, its unit and
# its wrapper pointed at /opt/ncz/embed-venv, while the image provisions the NPU
# interpreter at /opt/ncz/noe-venv (post-install/88-noe-umd-venv.sh, re-synced by
# ncz-noe-venv-sync.service whenever cix-noe-umd changes) and installs the server
# from assets/npu with that venv (post-install/89-npu-embed-server.sh). Its
# Depends was a bare "cix-noe-umd", which let an install keep a UMD the NOE
# wheels no longer match. This builds the package from the same files the image
# uses: assets/npu/ncz-npu-embed-server.py, the unit hook 89 writes, a wrapper for
# the same venv, and a versioned dependency on the cix-noe-umd the images ship.
#
# The unit stays DISABLED by the package (enabling belongs to the MNEMOS install
# path, which verifies the served vector width first).
# Output: build/npu-embed-deb/ncz-npu-embed_<ver>_arm64.deb (byte-reproducible).
set -euo pipefail
umask 022
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG=ncz-npu-embed
OUT="${NCZ_NPU_EMBED_OUT:-$ROOT/build/npu-embed-deb}"
# 1.1.0: built from the tree; noe-venv; Depends cix-noe-umd (>= 3.1.4-cixdeb13-260714).
VERSION="${NCZ_NPU_EMBED_VERSION:-1.1.0}"
NOE_UMD_MIN="3.1.4-cixdeb13-260714"
case "$VERSION" in
    1.1.0) SOURCE_DATE_EPOCH=1791921600 ;;   # 2026-10-13T20:00:00Z
    *) SOURCE_DATE_EPOCH="${NCZ_NPU_EMBED_EPOCH:-}"
       case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) echo "ERROR: no mtime epoch for $PKG $VERSION: add one in $0" >&2; exit 1 ;; esac ;;
esac
export SOURCE_DATE_EPOCH
SERVER="$ROOT/assets/npu/ncz-npu-embed-server.py"
HOOK="$ROOT/post-install/89-npu-embed-server.sh"
[ -f "$SERVER" ] && [ -f "$HOOK" ] || { echo "ERROR: missing $SERVER or $HOOK" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
install -d "$WORK/DEBIAN" "$WORK/usr/local/bin" "$WORK/lib/systemd/system" "$WORK/usr/share/doc/$PKG"
install -m 0755 "$SERVER" "$WORK/usr/local/bin/ncz-npu-embed-server.py"
# The unit is the one hook 89 writes, extracted from the hook so the two cannot drift.
sed -n "/^cat > \/etc\/systemd\/system\/ncz-npu-embed.service <<'UNIT'\$/,/^UNIT\$/p" "$HOOK" | sed '1d;$d' \
    > "$WORK/lib/systemd/system/ncz-npu-embed.service"
grep -q '^ExecStart=/opt/ncz/noe-venv/bin/python ' "$WORK/lib/systemd/system/ncz-npu-embed.service" \
    || { echo "ERROR: could not extract the ncz-npu-embed unit from $HOOK" >&2; exit 1; }
chmod 0644 "$WORK/lib/systemd/system/ncz-npu-embed.service"
cat > "$WORK/usr/local/bin/ncz-npu-python" <<'WRAP'
#!/bin/sh
# The interpreter that can drive the NPU: the venv post-install/88-noe-umd-venv.sh
# provisions (and ncz-noe-venv-sync.service keeps matched to cix-noe-umd). The
# system python is outside the >=3.11,<3.13 range the NOE wheels support.
exec /opt/ncz/noe-venv/bin/python "$@"
WRAP
chmod 0755 "$WORK/usr/local/bin/ncz-npu-python"
printf 'NCZ-OS NPU embedding server: OpenAI /v1/embeddings on the Sky1 Zhouyi NPU.\nSee docs/NPU-USAGE-GUIDE.md in cix-installer.\n' > "$WORK/usr/share/doc/$PKG/README"
chmod 0644 "$WORK/usr/share/doc/$PKG/README"
cat > "$WORK/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
# Deliberately NOT enabled here: ncz install mnemos probes the live endpoint and
# only wires MNEMOS up when it returns 768 floats.
if [ "$1" = configure ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
fi
exit 0
POSTINST
chmod 0755 "$WORK/DEBIAN/postinst"
find "$WORK" -type d -exec chmod 0755 {} +
SIZE_KB=$(find "$WORK/usr" "$WORK/lib" -type f -printf '%s\n' | awk '{s+=$1} END{printf "%d", (s+1023)/1024}')
cat > "$WORK/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Installed-Size: $SIZE_KB
Depends: cix-noe-umd (>= $NOE_UMD_MIN), python3
Recommends: ncz-model-nomic-embed
Section: utils
Priority: optional
Description: OpenAI-compatible embeddings on the CIX Sky1 Zhouyi NPU
 Serves /v1/embeddings from a precompiled NOE graph so MNEMOS can offload
 embedding to the NPU (nomic-embed-text-v1.5, 768 dimensions; bge-m3 and
 bge-small-zh graphs are recognised by file name).
 .
 Runs on /opt/ncz/noe-venv, the NPU interpreter the image provisions and keeps
 matched to cix-noe-umd. The unit is gated on /dev/aipu and is NOT enabled by
 this package.
CONTROL
chmod 0644 "$WORK/DEBIAN/control"
find "$WORK" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
install -d "$OUT"
DEB="$OUT/${PKG}_${VERSION}_arm64.deb"
dpkg-deb -Zxz --build --root-owner-group "$WORK" "$DEB" >/dev/null
# shellcheck source=lib/deb-version-gate.sh
. "$ROOT/build/lib/deb-version-gate.sh"
ncz_deb_version_gate "$DEB" || exit 1
echo "built: $DEB"
