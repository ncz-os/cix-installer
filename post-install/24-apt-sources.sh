#!/bin/bash
# 24-apt-sources.sh — wire the NCZ apt source(s) EARLY (before any hook that
# installs packages: 25-cix-proprietary, 52-vivaldi, etc), and refresh the
# package index so their own dependency-resolution steps have real, current
# data to resolve against.
#
# r189 regression this fixes: vivaldi-stable stuck in dpkg `iU`
# (half-configured) on every fresh install because fonts-liberation couldn't
# be resolved. The root cause was NOT a missing apt source --
# /etc/apt/sources.list shipped full Ubuntu ports on the then Ubuntu-based
# legacy base (r189, the MS-R1 test board); Ubuntu is gone (operator 2026-10-08) and the only
# base source is Debian forky (23-base-apt-sources.sh). The real problem was
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
# see build/ops/argos/backfill-buildkite-packages.sh) and build/ops/argos/
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
# review 2026-07-26: a source whose keyring failed to stage must NOT be
# written -- an earlier draft wrote the sources.list.d entry unconditionally,
# which meant a missing/corrupt .asc file produced a source apt could never
# actually update (silent failure deferred to whenever a later hook needed a
# package). Now each source is written ONLY on a successful dearmor, and it's
# fatal if BOTH end up unconfigured (no apt source at all is unrecoverable);
# one-of-two missing is a warning, since that's still a functional, if
# no-longer-redundant, apt setup.
#
# 2026-10-07 (r201, operator: "make sure our ncz-specific updates are separated
# from the debian ones"): the dual-source arrangement above is REPLACED. Two
# enabled NCZ repos that overlap made same-version rebuilds show up as
# "1.0 -> 1.0" and let either one shadow Debian. Now exactly ONE NCZ repo is
# enabled (Buildkite Packages: the superset, 19 packages vs R2's 13), R2 stays
# staged as a DISABLED fallback (`ncz-apt-source r2` switches), and a pin file
# (/etc/apt/preferences.d/10-ncz-origin-separation.pref) keeps NCZ packages for
# NCZ names and Debian packages for Debian names. All of it lives in
# post-install/lib/apt-separation.sh; see docs/APT-SEPARATION.md.
set -euo pipefail
echo "[24] wiring the NCZ apt source (Buildkite Packages; R2 kept as a disabled fallback) + origin-separation pin + refreshing package index"

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

# The two NCZ repo URLs (literal, so build/test-screensavers-mandatory-install-
# builders.sh and docs can grep them; the writer is lib/apt-separation.sh):
#   enabled : https://packages.buildkite.com/ncz-os/ncz/any/ any main
#   fallback: https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main (disabled)
# shellcheck source=lib/apt-separation.sh
. "$HERE/lib/apt-separation.sh"

install -d /etc/apt/keyrings /etc/apt/sources.list.d
# The pin goes in BEFORE any apt-get update/install below, and before the T2
# hook (55) wires t2.list, so no NCZ/T2 package can ever win a Debian name.
ncz_apt_write_separation_pin
ncz_apt_install_source_helper

if ENABLED_NCZ_REPO="$(ncz_apt_write_ncz_sources "$HERE")"; then
    echo "[24] NCZ apt source enabled: $ENABLED_NCZ_REPO (exactly one NCZ repo; the other is a disabled fallback: ncz-apt-source status)"
    if [ "$ENABLED_NCZ_REPO" = r2 ]; then
        echo "[24] WARN: the Buildkite keyring was missing/invalid, so the degraded R2 fallback is the enabled source" >&2
    fi
else
    echo "[24] FATAL: neither the Buildkite Packages nor the Cloudflare R2 keyring could be staged (both keyrings missing/invalid) — no NCZ-OS apt source is configured, later hooks that need it (20-desktop.sh, 25-cix-proprietary.sh) will fail" >&2
    exit 1
fi

APT_REFRESH_STAMP=/var/lib/apt/lists/.ncz-installer-refreshed
echo "[24] refreshing package index after apt source wiring"
if apt-get update -o Acquire::Check-Date=false 2>&1 | tail -10; then
    touch "$APT_REFRESH_STAMP"
else
    echo "[24] WARN: apt-get update had errors (network unavailable during chroot install, or one source down -- the other source's index may still be usable) -- later hooks may still be able to use cached/offline sources"
fi

# The pin is already written above; the package keeps it current (and is what
# `apt upgrade` updates later). Best effort: a missing candidate (not yet
# published, or no network and not on the offline pool) is a warning, not a failure.
if command -v apt-cache >/dev/null 2>&1 && \
   [ -n "$(apt-cache policy ncz-apt-policy 2>/dev/null | sed -n 's/^  Candidate: //p' | grep -v '^(none)$')" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y ncz-apt-policy 2>&1 | tail -3 \
        || echo "[24] WARN: could not install ncz-apt-policy (pin file is in place)"
else
    echo "[24] WARN: no candidate for ncz-apt-policy yet (publish it); the pin file written above stays in force"
fi

# --- live-update canary (operator 2026-10-05) ----------------------------------
# Offline install gets ncz-screensavers from the flat offline apt source
# (file:///cdrom/ncz-payload/apt-repo, registered by late.sh; seeded by
# build-forky-mirror.sh from this very manifest). Live `apt upgrade` on the
# running image does NOT have the offline mirror -- it pulls new screensaver
# debs from one of the NCZ-OS apt sources wired above. If neither source
# resolves ncz-screensavers, an installed image will never receive a newer
# screensaver package and the hook-driven install will look fine but the
# runtime update path will silently never advance. Verify now, while we still
# know which source was wired -- and verify the candidate came from an NCZ-OS
# *network* host, not from the offline /cdrom pool: 20-desktop.sh registers
# file:///cdrom before this hook, so a naive "candidate exists" check would
# pass even when both live sources are dead, hiding exactly the drift this
# canary exists to catch.
echo "[24] verifying NCZ-OS apt sources carry ncz-screensavers for live 'apt upgrade'"
if command -v apt-cache >/dev/null 2>&1; then
    _ncz_ss_pol="$(apt-cache policy ncz-screensavers 2>/dev/null)"
    _ncz_ss_cand="$(printf '%s\n' "$_ncz_ss_pol" | sed -n 's/^  Candidate: //p')"
    if [ -z "$_ncz_ss_cand" ] || [ "$_ncz_ss_cand" = "(none)" ]; then
        echo "[24] FATAL: no apt source (NCZ-OS network or the offline /cdrom pool) offers ncz-screensavers -- the live image can install it offline but will NEVER receive updates via 'apt upgrade'" >&2
        echo "[24]        (operator 2026-10-05: 'If we are distributing screensavers as Deb they need to be apt installed during installation.' Same logic applies to keeping them current.)" >&2
        echo "[24]        Check both repos serve the package; if the package was unpublished, run oc-apt-publish first." >&2
        exit 1
    fi
    # The candidate must be offered by an NCZ-OS network source. /cdrom is gone
    # on the installed system, so a candidate that exists only there proves
    # nothing about `apt upgrade`.
    if printf '%s\n' "$_ncz_ss_pol" | grep -qE 'packages\.buildkite\.com/ncz-os/ncz|pub-d7b784e01679403d9c70fcd23fff5b96\.r2\.dev'; then
        echo "[24] OK: NCZ-OS apt sources carry ncz-screensavers (Candidate: $_ncz_ss_cand)"
    elif printf '%s\n' "$_ncz_ss_pol" | grep -qE 'file:/+cdrom'; then
        echo "[24] WARN: ncz-screensavers resolves only from the offline /cdrom pool; no NCZ-OS network source offered it during this install (index not refreshed, or both sources unreachable). The live-update path is unproven, but the sources above are wired and will serve the package once reachable." >&2
    else
        echo "[24] FATAL: ncz-screensavers candidate $_ncz_ss_cand is not offered by an NCZ-OS apt source -- the live image will NEVER receive updates via 'apt upgrade'" >&2
        echo "[24]        candidate origins seen:" >&2
        printf '%s\n' "$_ncz_ss_pol" | sed -n '/^  Version table:/,$p' | sed 's/^/        /' >&2
        exit 1
    fi
else
    echo "[24] WARN: apt-cache not on PATH; cannot prove live-update path. Continuing (offline install path is unaffected)."
fi
