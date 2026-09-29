#!/bin/bash
# 24-apt-sources.sh — wire the NCZ apt source(s) EARLY (before any hook that
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
# 2026-07-06: migrated off Buildkite Packages to Cloudflare R2, after making
# the Buildkite registry public tripped a "Resource limit reached" wall on
# the (then) plan tier -- blocked BOTH apt and web-UI downloads regardless of
# visibility, with no fallback, and caused a real community-user install
# failure (10-our-kernel.sh has no recovery if its one apt source is
# unreachable). A second, independent bug (auth.conf.d machine line written
# as a full URL instead of a bare hostname) meant authenticated/private
# access never worked either.
#
# 2026-07-26: REVERSED -- Buildkite Packages is primary again (operator
# directive: the org now has full open-source Buildkite privileges). Verified
# empirically same day: anonymous, unauthenticated access to
# packages.buildkite.com/ncz-os/ncz/any/ -- InRelease, Release, Packages, AND
# an actual pool .deb blob -- all return real data with no resource-limit
# wall. The registry backfilled from ~/ncz-apt-repo (was stale since 07-06,
# see ARGOS:~/bin/backfill-buildkite-packages.sh) and ARGOS:~/bin/
# ncz-reprepro-publish.sh now dual-publishes every future package to BOTH
# targets, so this is not just swapping which single point of failure we
# have: Cloudflare R2 stays configured as a SECOND, independent apt source
# (not merely a mirror URL) -- if Buildkite is unreachable at `apt-get
# update` time, apt still resolves packages from R2's index, and vice versa.
# That's the actual fix for the no-fallback failure mode that started this
# whole saga -- neither source is a single point of failure anymore.
#
# Buildkite Packages is a managed registry with ITS OWN auto-generated GPG
# signing key (fetched once from https://packages.buildkite.com/ncz-os/ncz/
# gpgkey, staged here as buildkite-ncz-apt-keyring.asc) -- NOT the NCZ-OS
# reprepro key (ncz-os-apt-keyring.asc) that signs the R2 copy. Both keyrings
# must be present.
#
# Codex review 2026-07-26: a source whose keyring failed to stage must NOT be
# written -- an earlier draft wrote the sources.list.d entry unconditionally,
# which meant a missing/corrupt .asc file produced a source apt could never
# actually update (silent failure deferred to whenever a later hook needed a
# package). Now each source is written ONLY on a successful dearmor, and it's
# fatal if BOTH end up unconfigured (no apt source at all is unrecoverable);
# one-of-two missing is a warning, since that's still a functional, if
# no-longer-redundant, apt setup.
set -euo pipefail
echo "[24] wiring NCZ apt sources (Buildkite Packages PRIMARY + Cloudflare R2 backup) + refreshing package index"

HERE="$(dirname "$0")"
if [ -x "$HERE/23-base-apt-sources.sh" ]; then
    "$HERE/23-base-apt-sources.sh"
fi

# debootstrap's minimal root intentionally omits GnuPG, but this hook is
# called by the kernel phase before any package manifest is installed. Fetch
# the verifier from the already-authenticated base archive before dearmoring
# either NCZ repository key.
if ! command -v gpg >/dev/null 2>&1; then
    echo "[24] installing gnupg needed to verify NCZ repository keyrings"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gnupg
fi

install -d /etc/apt/keyrings /etc/apt/sources.list.d
CONFIGURED=0

# --- Buildkite Packages (PRIMARY) -------------------------------------------
BK_KEYRING=/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg
BK_SRC=/etc/apt/sources.list.d/ncz-os-apt-buildkite.list
if [ -f "$HERE/buildkite-ncz-apt-keyring.asc" ] && \
   gpg --dearmor < "$HERE/buildkite-ncz-apt-keyring.asc" > "$BK_KEYRING" 2>/dev/null; then
    chmod 0644 "$BK_KEYRING"
    cat > "$BK_SRC" <<SRCEOF
# NCZ kernel updates + CIX proprietary userspace + Singularity Desktop —
# Buildkite Packages (public, no auth) — PRIMARY as of 2026-07-26.
deb [signed-by=$BK_KEYRING] https://packages.buildkite.com/ncz-os/ncz/any/ any main
SRCEOF
    echo "[24] Buildkite Packages source installed (primary): $BK_SRC"
    CONFIGURED=$((CONFIGURED + 1))
else
    echo "[24] WARN: $HERE/buildkite-ncz-apt-keyring.asc missing or invalid — Buildkite Packages source NOT wired (no source written for a keyring we don't have)"
fi

# --- Cloudflare R2 (SECONDARY / backup) -------------------------------------
R2_KEYRING=/etc/apt/keyrings/ncz-os-apt-keyring.gpg
R2_SRC=/etc/apt/sources.list.d/ncz-os-apt-r2.list
if [ -f "$HERE/ncz-os-apt-keyring.asc" ] && \
   gpg --dearmor < "$HERE/ncz-os-apt-keyring.asc" > "$R2_KEYRING" 2>/dev/null; then
    chmod 0644 "$R2_KEYRING"
    cat > "$R2_SRC" <<SRCEOF
# NCZ kernel updates + CIX proprietary userspace + Singularity Desktop —
# Cloudflare R2 (public, no auth) — SECONDARY/backup as of 2026-07-26. A real
# second apt source, not just a mirror URL: if Buildkite is unreachable at
# update time apt still resolves + installs from this index.
deb [signed-by=$R2_KEYRING] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main
SRCEOF
    echo "[24] Cloudflare R2 source installed (backup): $R2_SRC"
    CONFIGURED=$((CONFIGURED + 1))
else
    echo "[24] WARN: $HERE/ncz-os-apt-keyring.asc missing or invalid — Cloudflare R2 source NOT wired (no source written for a keyring we don't have)"
fi

if [ "$CONFIGURED" -eq 0 ]; then
    echo "[24] FATAL: neither the Buildkite Packages nor the Cloudflare R2 apt source could be wired (both keyrings missing/invalid) — no NCZ-OS apt source is configured, later hooks that need it (20-desktop.sh, 25-cix-proprietary.sh) will fail" >&2
    exit 1
elif [ "$CONFIGURED" -eq 1 ]; then
    echo "[24] WARN: only 1 of 2 NCZ-OS apt sources configured — redundancy is degraded but install can continue"
fi

APT_REFRESH_STAMP=/var/lib/apt/lists/.ncz-installer-refreshed
echo "[24] refreshing package index after apt source wiring"
if apt-get update -o Acquire::Check-Date=false 2>&1 | tail -10; then
    touch "$APT_REFRESH_STAMP"
else
    echo "[24] WARN: apt-get update had errors (network unavailable during chroot install, or one source down -- the other source's index may still be usable) -- later hooks may still be able to use cached/offline sources"
fi
