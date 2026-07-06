#!/bin/bash
# 24-apt-sources.sh — wire the NCZ apt source EARLY (before any hook that
# installs packages: 25-cix-proprietary, 52-vivaldi, etc), and refresh the
# package index so their own dependency-resolution steps have real, current
# data to resolve against.
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
# (2) directly in 52-vivaldi.sh. This hook fixes (1).
#
# 2026-07-06: migrated off Buildkite Packages to Cloudflare R2. Buildkite's
# registry is private-by-default, and flipping it public tripped a
# "Resource limit reached" wall on the plan tier -- blocking package
# downloads (both apt and the web UI) regardless of visibility. R2's public
# bucket access (pub-*.r2.dev) has no such issue and needs no client-side
# auth at all, so the whole read-token/auth.conf.d machinery from the
# Buildkite era is gone -- one less class of bug (a prior version of this
# hook had a malformed auth.conf.d `machine` line using a full URL instead
# of a bare hostname, silently making every request unauthenticated).
set -euo pipefail
echo "[24] wiring NCZ apt source (Cloudflare R2) + refreshing package index"

KEYRING=/etc/apt/keyrings/ncz-os-apt-keyring.gpg
SRC=/etc/apt/sources.list.d/ncz-os-apt.list
HERE="$(dirname "$0")"
install -d /etc/apt/keyrings /etc/apt/sources.list.d
[ -f "$HERE/ncz-os-apt-keyring.asc" ] && gpg --dearmor < "$HERE/ncz-os-apt-keyring.asc" > "$KEYRING" && chmod 0644 "$KEYRING"

cat > "$SRC" <<SRCEOF
# NCZ kernel updates + CIX proprietary userspace — Cloudflare R2 (public, no auth)
deb [signed-by=$KEYRING] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main
SRCEOF
echo "[24] NCZ apt source installed: $SRC"

echo "[24] refreshing package index"
apt-get update 2>&1 | tail -10 || echo "[24] WARN: apt-get update had errors (network unavailable during chroot install?) -- later hooks may still be able to use cached/offline sources"
