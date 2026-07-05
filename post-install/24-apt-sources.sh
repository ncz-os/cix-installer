#!/bin/bash
# 24-apt-sources.sh — wire the Buildkite apt source EARLY (before any hook
# that installs packages: 25-cix-proprietary, 52-vivaldi, etc), and refresh
# the package index so their own dependency-resolution steps have real,
# current data to resolve against.
#
# r189 regression this fixes: vivaldi-stable stuck in dpkg `iU`
# (half-configured) on every fresh install because fonts-liberation couldn't
# be resolved. The root cause was NOT a missing apt source --
# /etc/apt/sources.list already ships full Ubuntu ports
# main+universe+restricted+multiverse (+updates/security/backports) by
# default, always has (confirmed live on .66, r189). The real problem was
# two-fold: (1) nothing ever ran `apt-get update` before 52-vivaldi.sh needed
# a resolved index, so apt had no package data to work with regardless of
# which sources existed; (2) 52-vivaldi.sh's own dependency-fix step used
# `--no-download`, which can't fetch anything even with a fresh index. Fixed
# (2) directly in 52-vivaldi.sh. This hook fixes (1), and also moves the
# Buildkite source (kernel updates + CIX proprietary userspace, mirrored
# 2026-07-05 from archive.cixtech.com -- see
# project_cix_buildkite_mirror_2026_07_05) here from the old
# 92-buildkite-apt.sh, which ran too late (hook 92 sorts after 25/52) to be
# any use to their dependency-resolution steps either.
set -euo pipefail
echo "[24] wiring Buildkite apt source + refreshing package index"

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
    echo "[24] buildkite read token installed -> $AUTH"
else
    echo "[24] WARN: no buildkite-read-token staged; buildkite source will need manual auth"
fi
cat > "$SRC" <<SRCEOF
# NCZ kernel updates + CIX proprietary userspace — Buildkite Packages (ncz-os/ncz, private read)
deb [signed-by=$KEYRING] https://packages.buildkite.com/ncz-os/ncz/any/ any main
SRCEOF
echo "[24] Buildkite source installed: $SRC"

echo "[24] refreshing package index"
apt-get update 2>&1 | tail -10 || echo "[24] WARN: apt-get update had errors (network unavailable during chroot install?) -- later hooks may still be able to use cached/offline sources"
