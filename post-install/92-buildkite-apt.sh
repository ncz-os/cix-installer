#!/bin/bash
# 92-buildkite-apt.sh — Buildkite Packages registry (ncz-os/ncz) = KERNEL UPDATE
# apt source: linux-image-cixmini-{lts,edge} + cixmini-boot. Private registry =>
# a READ token is required; it is staged from the gitignored build secret
# post-install/buildkite-read-token (baked into the ISO, NOT committed to git).
# CIX userspace bits come from Codeberg (91). r142.
set -euo pipefail
echo "[92] wiring Buildkite Packages apt repo (kernel updates)"
KEYRING=/etc/apt/keyrings/ncz-os_ncz-archive-keyring.gpg
SRC=/etc/apt/sources.list.d/buildkite-ncz-os-ncz.list
AUTH=/etc/apt/auth.conf.d/ncz-os_ncz.conf
HERE="$(dirname "$0")"
install -d /etc/apt/keyrings /etc/apt/sources.list.d /etc/apt/auth.conf.d
[ -f "$HERE/ncz-buildkite-keyring.asc" ] && gpg --dearmor < "$HERE/ncz-buildkite-keyring.asc" > "$KEYRING" && chmod 0644 "$KEYRING"
if [ -s "$HERE/buildkite-read-token" ]; then
  TOK="$(cat "$HERE/buildkite-read-token")"
  printf 'machine https://packages.buildkite.com/ncz-os/ncz/ login buildkite password %s\n' "$TOK" > "$AUTH"
  chmod 600 "$AUTH"
  echo "[92] buildkite read token installed -> $AUTH"
else
  echo "[92] WARN: no buildkite-read-token staged; kernel-update source will need manual auth"
fi
cat > "$SRC" <<SRCEOF
# NCZ kernel updates — Buildkite Packages (ncz-os/ncz, private read)
deb [signed-by=$KEYRING] https://packages.buildkite.com/ncz-os/ncz/any/ any main
SRCEOF
echo "[92] Buildkite kernel-update source installed: $SRC"
