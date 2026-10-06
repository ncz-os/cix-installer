#!/bin/bash
# build-desktop-mirror.sh — r130 fat/offline desktop closure mirror (arm64).
#
# Builds the closure of the Sky1 SINGULARITY desktop runtime set listed in
# manifests/desktop.pkgs (Singularity replaced XFCE in 26.7 — NO xubuntu-core,
# NO xfce4-*; Wayland-native GTK4 runtime libs + Chromium + mpv + Xwayland).
# (build-server-mirror.sh, formerly this file's Ubuntu-Server-closure
# companion, was deleted 2026-08-21 as dead code — see
# docs/UBUNTU-ERA-AUDIT-2026-08-21.md.)
#
# build-iso-di.sh merges build/desktop-mirror/pool into the ISO pool and
# regenerates the single 'main' deb index from the combined pool, so
# post-install/20-desktop.sh installs the desktop fully OFFLINE from
# file:///cdrom (no live apt source dependency → no r129-style 20-desktop stall).
#
# Outputs:
#   build/desktop-mirror/        apt repo (dists/<suite> + pool) — POOL is what
#                                the ISO consumes; dists/ is for standalone use.
#   build/desktop-mirror.gaps    closure pkgs not in the local mirror
#
# Method: a self-contained apt root over Debian's own archive (release.conf
# NCZ_BASE_MIRROR/NCZ_BASE_COMPONENTS), arm64, simulate-install the desktop
# seed to compute the closure, apt-get download the exact closure versions
# into the new pool, regenerate indexes. Chromium is the one exception: no
# Debian/Ubuntu Chromium package is used at all, the browser seed uses
# Google's own signed real Chrome build
# (google-chrome-stable), pinned to one exact version + SHA256-verified, and
# folded into this offline mirror. No live Google apt source is installed on
# the appliance. (An earlier stop-gap used XtraDeb's ungoogled-chromium
# before real Chrome existed for arm64 — dropped 2026-07-27, superseded.)
set -euo pipefail

# Never hardcode the base suite. release.conf is the single source of truth --
# a hardcoded "resolute" here is how a Forky tree ends up building a Ubuntu
# mirror and silently combining the two.
_RC="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/release.conf"
if [ -r "$_RC" ]; then . "$_RC"; else
  echo "ERROR: $_RC not readable -- refusing to guess the base distro" >&2; exit 1
fi
: "${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"


# LC_ALL=C: several steps below sort package-name lists with `sort -u` in
# separate invocations and then diff them with `comm`, which requires BOTH
# inputs sorted under the SAME collation order -- under the build host's
# default locale, two independent `sort -u` calls can disagree on ordering
# (case/locale-sensitive collation) even though each individually looks
# "sorted", and `comm` then fails with "not in sorted order" (found live
# 2026-07-27 running this end-to-end on cixmini for the first time). Force
# the plain byte-order C locale everywhere in this script so every sort/comm
# pair is guaranteed consistent.
export LC_ALL=C

# Single source of truth for the ncz-screensavers version floor (operator
# 2026-10-05 mandatory-install item). Sourced once here; the `required`
# ncz-screensavers row in NCZ_LOCAL_DEBS below reads NCZ_SCREENSAVERS_MIN_VERSION
# and the standard error messages from it.
SCREENSAVERS_VERSION_ENV="$REPO/build/screensavers-version.env"
if [ ! -r "$SCREENSAVERS_VERSION_ENV" ]; then
    echo "ERROR: $SCREENSAVERS_VERSION_ENV not readable -- refusing to build a desktop mirror without a screensaver version floor" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$SCREENSAVERS_VERSION_ENV"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/build/$NCZ_BASE_CODENAME-mirror"
OUT="$REPO/build/desktop-mirror"
GAPS="$REPO/build/desktop-mirror.gaps"
SUITE="$NCZ_BASE_CODENAME"
ARCH="${ARCH:-${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}}"
if [ -f "$REPO/manifests/desktop-$ARCH.pkgs" ]; then
    SEEDFILE="$REPO/manifests/desktop-$ARCH.pkgs"
else
    SEEDFILE="$REPO/manifests/desktop.pkgs"
fi
IDX="$SRC/dists/$SUITE/main/binary-$ARCH/Packages"

# Source: Debian's own archive (release.conf NCZ_BASE_MIRROR/NCZ_BASE_COMPONENTS
# -- the single source of truth for the base distro, same as SUITE above).
# Historically pointed at Ubuntu ports on the claim that the desktop long tail
# (gimp, catfish, synaptic, xfce goodies) "lives largely in universe" -- stale:
# catfish and every xfce4-* package are already gone from manifests/desktop.pkgs
# (removed when Singularity replaced XFCE in 26.7), and gimp/synaptic are
# ordinary Debian main packages, never Ubuntu-universe-exclusive. Nothing in
# the current seed needs Ubuntu. arm64 needs no separate "ports" archive on
# Debian -- it is a normal release architecture on the main archive.
: "${NCZ_BASE_MIRROR:?release.conf did not define NCZ_BASE_MIRROR}"
: "${NCZ_BASE_COMPONENTS:?release.conf did not define NCZ_BASE_COMPONENTS}"
PORTS_URL="${PORTS_URL:-$NCZ_BASE_MIRROR}"

# Real, official Google Chrome for arm64 Linux (launched publicly Q2 2026,
# available since via Google's own signed apt repo). Folded into the offline
# mirror pool, same reasoning as everything else here: no live apt source on
# the shipped appliance (r180 doctrine). Adds Google account sync/Widevine
# DRM/Google Pay and (per post-install/84-vpu-vaapi.sh) confirmed working
# VA-API hardware video decode once that hook's fixes are applied.
#
# NOT VERSION-PINNED (operator, 2026-08-12): always mirror whatever Google
# currently ships as stable. A hardcoded version is a build-time time bomb --
# Google rotates the stable point release every couple of weeks and drops the
# previous one from the index, so the pin fails the build rather than
# protecting it (151.0.7922.71-1 vanished exactly this way). Integrity still
# holds: the repo is added with signed-by=, so apt verifies Google's Release
# signature, and the expected SHA256 is read from that signed Packages index
# and checked against the downloaded .deb below.
GOOGLE_CHROME_URL="${GOOGLE_CHROME_URL:-https://dl.google.com/linux/chrome/deb}"
GOOGLE_CHROME_KEY_URL="${GOOGLE_CHROME_KEY_URL:-https://dl.google.com/linux/linux_signing_key.pub}"
GOOGLE_CHROME_KEY="$REPO/build/google-chrome-apt-keyring.asc"
GOOGLE_CHROME_PKGS="google-chrome-stable"

# ncz-singularity-desktop (build/build-singularity-deb.sh) is CIX/NCZ-specific
# -- it doesn't exist on Ubuntu ports at all, only on the Buildkite Packages
# registry (the same one post-install/24-apt-sources.sh wires as the shipped
# image's own runtime source). Without this, ncz-singularity-desktop can be
# in the seed file all day and this script will never find it -- found
# 2026-07-27 running this end-to-end for the first time: 20-desktop.sh
# hard-failed with "ncz-singularity-desktop not installable" on any build
# that doesn't happen to have live network access to Buildkite, because the
# offline mirror pool never had a source that could see this package at all.
BUILDKITE_NCZ_URL="${BUILDKITE_NCZ_URL:-https://packages.buildkite.com/ncz-os/ncz/any}"
BUILDKITE_NCZ_KEY="$REPO/post-install/buildkite-ncz-apt-keyring.asc"

[ -f "$SEEDFILE" ] || { echo "ERROR: $SEEDFILE missing"; exit 1; }

echo "== build-desktop-mirror =="
echo "   seed=$SEEDFILE"
echo "   out=$OUT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/apt/preferences.d" "$T/etc/apt/apt.conf.d" "$T/etc/apt/keyrings" \
         "$T/var/lib/apt/lists/partial" "$T/var/lib/dpkg" \
         "$T/var/cache/apt/archives/partial"
: > "$T/var/lib/dpkg/status"

echo "  source: Debian ($PORTS_URL, $SUITE) — authoritative desktop closure"
cat > "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE $NCZ_BASE_COMPONENTS
EOF

if grep -Eq '^[[:space:]]*google-chrome-stable([[:space:]]|$)' "$SEEDFILE"; then
    [ -f "$GOOGLE_CHROME_KEY" ] || { echo "ERROR: $GOOGLE_CHROME_KEY missing"; exit 1; }
    cp "$GOOGLE_CHROME_KEY" "$T/etc/apt/keyrings/google-chrome-apt-keyring.asc"
    chmod 0644 "$T/etc/apt/keyrings/google-chrome-apt-keyring.asc"
    cat >> "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH signed-by=$T/etc/apt/keyrings/google-chrome-apt-keyring.asc] $GOOGLE_CHROME_URL stable main
EOF
    cat > "$T/etc/apt/preferences.d/google-chrome.pref" <<EOF
Package: *
Pin: release o=Google LLC
Pin-Priority: -1

Package: google-chrome-stable
Pin: release o=Google LLC
Pin-Priority: 990

Package: google-chrome-beta google-chrome-unstable google-chrome-canary
Pin: release o=Google LLC
Pin-Priority: -1
EOF
    echo "  source: Google Chrome (${GOOGLE_CHROME_URL}) — tracking current stable, checksum-verified below"
fi

[ -f "$BUILDKITE_NCZ_KEY" ] || { echo "ERROR: $BUILDKITE_NCZ_KEY missing"; exit 1; }
cp "$BUILDKITE_NCZ_KEY" "$T/etc/apt/keyrings/buildkite-ncz-apt-keyring.asc"
chmod 0644 "$T/etc/apt/keyrings/buildkite-ncz-apt-keyring.asc"
cat >> "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH signed-by=$T/etc/apt/keyrings/buildkite-ncz-apt-keyring.asc] $BUILDKITE_NCZ_URL any main
EOF
# Buildkite also carries a historical Ubuntu build of fonts-liberation for
# Chrome consumers.  NCZ-OS is Debian-only; force Debian's exact Forky build
# even though the Ubuntu version string sorts higher.
cat > "$T/etc/apt/preferences.d/debian-only-overrides.pref" <<'EOF'
Package: fonts-liberation
Pin: version 1:2.1.5-3
Pin-Priority: 1001
EOF
echo "  source: Buildkite Packages (${BUILDKITE_NCZ_URL}) — ncz-singularity-desktop + other CIX/NCZ-only packages"

APTOPTS=(
  -o Dir="$T"
  -o Dir::State="$T/var/lib/apt"
  -o Dir::State::status="$T/var/lib/dpkg/status"
  -o Dir::Cache="$T/var/cache/apt"
  -o Dir::Etc="$T/etc/apt"
  -o APT::Architecture="$ARCH"
  -o APT::Architectures="$ARCH"
  -o Acquire::Languages=none
  -o APT::Install-Recommends=0
)

echo "  apt-get update (desktop package sources)..."
apt-get "${APTOPTS[@]}" update >/dev/null 2>&1

if grep -Eq '^[[:space:]]*google-chrome-stable([[:space:]]|$)' "$SEEDFILE"; then
    # Whatever Google currently ships as stable — no pin (operator 2026-08-12).
    _chrome_ver="$(apt-cache "${APTOPTS[@]}" policy google-chrome-stable \
                   | awk '/Candidate:/ {print $2}')"
    if [ -z "$_chrome_ver" ] || [ "$_chrome_ver" = "(none)" ]; then
        echo "ERROR: google-chrome-stable has no candidate from the signed Google apt repo" >&2
        echo "       (repo reachable? key valid? arch $ARCH published?)" >&2
        exit 1
    fi
    echo "  google-chrome-stable candidate: $_chrome_ver"

    # Integrity anchor: the SHA256 published in Google's OWN Packages index.
    # That index arrived under a signature apt already verified (signed-by= on
    # the source line), so it is a trustworthy expectation for the .deb we are
    # about to fold into an offline mirror — and unlike a hardcoded constant it
    # tracks whatever version we just resolved.
    _want_sha="$(apt-cache "${APTOPTS[@]}" show "google-chrome-stable=$_chrome_ver" 2>/dev/null \
                 | awk '/^SHA256: / {print $2; exit}')"
    if [ -z "$_want_sha" ]; then
        echo "ERROR: no SHA256 in the signed Packages entry for google-chrome-stable=$_chrome_ver" >&2
        exit 1
    fi

    # NB: --print-uris lists the whole dependency closure, not just this one
    # package -- `head -1` on the piped output triggers a SIGPIPE in the
    # upstream apt-get/awk once head closes the pipe, and pipefail turns
    # that into a non-zero exit that kills this script under set -e even
    # though $_deb_rel captures the right value. Grep for the exact package
    # name instead of blindly taking the first line, and disable pipefail
    # for just this one pipeline as a second layer of protection.
    set +o pipefail
    _deb_rel="$(apt-get "${APTOPTS[@]}" --print-uris -qq install --reinstall google-chrome-stable 2>/dev/null | awk -F"'" '{print $2}' | grep -m1 'google-chrome-stable_')"
    set -o pipefail
    if [ -n "$_deb_rel" ]; then
        _deb_sha="$(curl -fsSL -m 120 "$_deb_rel" -o "$T/google-chrome-stable.deb" && sha256sum "$T/google-chrome-stable.deb" | awk '{print $1}')"
        if [ "$_deb_sha" != "$_want_sha" ]; then
            echo "ERROR: google-chrome-stable .deb SHA256 mismatch — signed index says $_want_sha, download is $_deb_sha" >&2
            exit 1
        fi
        echo "  verified google-chrome-stable $_chrome_ver against the signed index SHA256"
    fi
fi

# all package names apt can see
ALL_NAMES="$T/all-names"
apt-cache "${APTOPTS[@]}" pkgnames 2>/dev/null | sort -u > "$ALL_NAMES"

# seed = the EXPLICIT desktop seed only (no req/imp/std injection — those base
# priorities are server-mirror's job; the desktop closure pulls its own deps).
SEED="$T/seed"
grep -vE '^\s*(#|$)' "$SEEDFILE" | awk '{print $1}' | sort -u > "$SEED"
echo "  seed packages (explicit desktop): $(wc -l < "$SEED")"

# split seed into present vs missing-from-ports
PRESENT="$T/present"; MISSING="$T/missing"
comm -12 "$SEED" "$ALL_NAMES" > "$PRESENT"
comm -23 "$SEED" "$ALL_NAMES" > "$MISSING"

echo "  seed present in ports: $(wc -l < "$PRESENT")   missing: $(wc -l < "$MISSING")"

# Resolve the closure. Atomic simulate first; tolerant per-seed union fallback.
echo "  resolving dependency closure (total names visible: $(wc -l < "$ALL_NAMES"))..."
SIMLOG="$T/sim.log"
CLOSURE="$T/closure"
UNMET="$T/unmet"; : > "$UNMET"

if apt-get "${APTOPTS[@]}" install -s -y $(tr '\n' ' ' < "$PRESENT") > "$SIMLOG" 2>&1 \
   && grep -q '^Inst ' "$SIMLOG"; then
    awk '/^Inst /{print $2}' "$SIMLOG" | sort -u > "$CLOSURE"
    echo "  closure resolved atomically: $(wc -l < "$CLOSURE") packages"
else
    echo "  atomic resolve failed; falling back to tolerant per-seed union..."
    : > "$CLOSURE.acc"
    bad=0
    while read -r p; do
        [ -n "$p" ] || continue
        if apt-get "${APTOPTS[@]}" install -s -y "$p" > "$T/one.log" 2>&1 \
           && grep -q '^Inst ' "$T/one.log"; then
            awk '/^Inst /{print $2}' "$T/one.log" >> "$CLOSURE.acc"
        else
            echo "UNINSTALLABLE-SEED: $p" >> "$UNMET"
            grep -E "Depends:|Conflicts:|but it is not" "$T/one.log" | sed "s/^/  ($p) /" >> "$UNMET"
            bad=$((bad+1))
        fi
    done < "$PRESENT"
    sort -u "$CLOSURE.acc" > "$CLOSURE"
    echo "  closure (union): $(wc -l < "$CLOSURE") packages; $bad seed(s) dropped as uninstallable"
fi

# Build a clean snapshot.  Keeping an incremental pool is unsafe across a
# distribution pivot: packages downloaded from the former Ubuntu source had
# higher versions than Debian's candidates and remained indexable after the
# source was corrected, producing a mixed, unsatisfiable closure.  The mirror
# is derived output, so discard only its package files and repopulate it from
# the exact candidates resolved above.
mkdir -p "$OUT/pool/main"
find "$OUT/pool/main" -maxdepth 1 -type f -name '*.deb' -delete
echo "  downloading clean Debian closure snapshot..."
if ! ( cd "$OUT/pool/main" && xargs -r apt-get "${APTOPTS[@]}" download < "$CLOSURE" >/dev/null 2>&1 ); then
    echo "  WARN: some downloads failed (see gaps report)"
fi

# The incremental pool keeps older versions of packages that remain in the
# closure. Chrome is large (~125 MiB) and Google rotates stable every couple of
# weeks, so without this every rebuild leaves the previous point release behind
# and silently bloats the ISO. Keep only the version resolved and verified above.
if grep -Eq '^[[:space:]]*google-chrome-stable([[:space:]]|$)' "$SEEDFILE"; then
    chrome_keep="google-chrome-stable_${_chrome_ver}_${ARCH}.deb"
    for chrome_deb in "$OUT"/pool/main/google-chrome-stable_*_"${ARCH}.deb"; do
        [ -e "$chrome_deb" ] || continue
        [ "$(basename "$chrome_deb")" = "$chrome_keep" ] || rm -f "$chrome_deb"
    done
fi

# NCZ-OS-local packages: not published in Debian, so add locally-built copies
# directly in reprepro-style pool layout. Optional ones keep the mirror usable
# as a standalone Debian closure builder; required ones do not, because
# their absence produces an ISO that fails partway through an install.
#
# The common rows here are optional EXCEPT ncz-screensavers: operator
# 2026-10-05 ("If we are distributing screensavers as Deb they need to be apt
# installed during installation.") makes ncz-screensavers a hard build-time
# requirement on desktop variants. The hook (post-install/59-ncz-screensavers
# -pkg.sh) hard-fails when it has no candidate; a mirror that lacks the
# package would build cleanly, install cleanly, and silently ship no
# screensavers -- the failure class the operator flagged. Marking it required
# here causes this script to exit with a precise "missing package" error
# instead.
#
# ncz-screensavers-plugin is intentionally NOT a row: there is no such published
# package (Buildkite + R2 serve ncz-screensavers, ncz-singularity-desktop,
# ncz-screensavers-gtk4-reference only). The Singularity screensaver plugin is
# shipped INSIDE ncz-screensavers; seeding a separate, non-existent package
# would silently fail the build.
#
# cixmini-boot Depends on ncz-usb-recovery, but the pool that has to satisfy
# it offline is build/forky-vendor-mirror, not this one -- see the note above
# the gate at the bottom of this block.
#
# ncz-usb-recovery is deliberately in the arm64-only block below (item RS,
# 2026-10-04): it is a Sky1-only workaround, and seeding the all-arch desktop
# closure put it on amd64/T2 images where its unit then rebound the T2 root hub
# every boot. The package is now Architecture: arm64 and its glob matches
# _arm64.deb.
#
# Each row: <package name>|<glob of candidate .debs>|<required?>
NCZ_LOCAL_DEBS="
ncz-singularity-desktop|$REPO/build/sinty-out/ncz-singularity-desktop_*_${ARCH}.deb|optional
ncz-singularity-desktop|$REPO/assets/cix-debs/ncz-singularity-desktop_*_${ARCH}.deb|optional
ncz-screensavers|$REPO/build/ncz-screensavers-out/ncz-screensavers_*_${ARCH}.deb|required
"
if [ "$ARCH" = arm64 ]; then
NCZ_LOCAL_DEBS+="
ncz-usb-recovery|$REPO/build/usb-recovery-deb/ncz-usb-recovery_*_arm64.deb|optional
libdrm-common|$REPO/build/libdrm-debs/libdrm-common_2.4.134-3+ncz*_all.deb|required
libdrm2|$REPO/build/libdrm-debs/libdrm2_2.4.134-3+ncz*_arm64.deb|required
libdrm-amdgpu1|$REPO/build/libdrm-debs/libdrm-amdgpu1_2.4.134-3+ncz*_arm64.deb|required
libdrm-etnaviv1|$REPO/build/libdrm-debs/libdrm-etnaviv1_2.4.134-3+ncz*_arm64.deb|required
libdrm-freedreno1|$REPO/build/libdrm-debs/libdrm-freedreno1_2.4.134-3+ncz*_arm64.deb|required
libdrm-nouveau2|$REPO/build/libdrm-debs/libdrm-nouveau2_2.4.134-3+ncz*_arm64.deb|required
libdrm-radeon1|$REPO/build/libdrm-debs/libdrm-radeon1_2.4.134-3+ncz*_arm64.deb|required
libdrm-tegra0|$REPO/build/libdrm-debs/libdrm-tegra0_2.4.134-3+ncz*_arm64.deb|required
libdrm-dev|$REPO/build/libdrm-debs/libdrm-dev_2.4.134-3+ncz*_arm64.deb|required
"
fi

printf '%s\n' "$NCZ_LOCAL_DEBS" | while IFS='|' read -r pkg glob req; do
    [ -n "$pkg" ] || continue

    # Version-sort and take the last: a stale .deb left by an earlier build must
    # never shadow the newest. A plain glob loop picks whichever the shell lists
    # first, which is undefined ordering, not newest.
    candidates="$(ls -1 $glob 2>/dev/null | sort -V || true)"
    if [ -z "$candidates" ]; then
        if [ "$req" = required ]; then
            echo "  ERROR: no $pkg .deb at $glob" >&2
            if [ "$pkg" = ncz-screensavers ]; then
                echo "  ERROR: $pkg is mandatory on desktop variants; the offline mirror MUST carry it." >&2
                echo "  ERROR:   ($NCZ_SCREENSAVERS_MISSING_MSG)" >&2
                echo "  ERROR:   rebuild with build/build-screensavers-deb.sh and re-run." >&2
            else
                echo "  ERROR: required local package missing; build the artifact first." >&2
                echo "  ERROR: for patched libdrm, run: build/build-libdrm-debs.sh" >&2
            fi
            exit 1
        fi
        echo "  WARN: no $pkg .deb at $glob — continuing without it"
        continue
    fi

    # ncz-screensavers has a minimum-version floor in build/screensavers-version.env.
    # Enforce it here so a stale .deb (left behind from a previous publish) cannot
    # shadow the newer one in $candidates: the version-sort above picks the
    # newest deb in the glob, but if THAT newest deb is itself older than the
    # floor (publish bot broken, mirror not refreshed) the build must fail loudly,
    # not silently ship a too-old catalogue.
    if [ "$pkg" = ncz-screensavers ]; then
        ss_deb="$(printf '%s\n' "$candidates" | tail -1)"
        ss_ver="$(dpkg-deb -f "$ss_deb" Version 2>/dev/null || echo unknown)"
        if [ "$ss_ver" = unknown ] || ! dpkg --compare-versions "$ss_ver" ge "$NCZ_SCREENSAVERS_MIN_VERSION"; then
            echo "  ERROR: newest ncz-screensavers .deb at $ss_deb is version '$ss_ver', BELOW the required floor $NCZ_SCREENSAVERS_MIN_VERSION" >&2
            echo "  ERROR:   ($NCZ_SCREENSAVERS_TOO_OLD_MSG)" >&2
            exit 1
        fi
        echo "  ncz-screensavers floor OK: $ss_ver >= $NCZ_SCREENSAVERS_MIN_VERSION"
    fi

    deb="$(printf '%s\n' "$candidates" | tail -1)"
    n="$(printf '%s\n' "$candidates" | wc -l)"
    [ "$n" -gt 1 ] && echo "  NOTE: $n candidate $pkg .debs found; using newest by version: $(basename "$deb")"

    # reprepro pool layout: pool/main/<first letter>/<source name>/
    pooldir="$OUT/pool/main/$(printf '%s' "$pkg" | cut -c1)/$pkg"
    mkdir -p "$pooldir"
    cp -f "$deb" "$pooldir/"
    echo "  added local NCZ package: $deb -> $pooldir/"
    # A local package is not a Debian seed, so it is absent from the resolved
    # closure and the "prune debs no longer in the closure" pass below would
    # delete it again. Record it as intentionally present.
    grep -qxF "$pkg" "$CLOSURE" || echo "$pkg" >> "$CLOSURE"
done
# comm(1) below needs the closure sorted in the C locale; the loop above appended.
LC_ALL=C sort -u -o "$CLOSURE" "$CLOSURE"
# The desktop delta consumes this pool directly. The complete ISO closure also
# consumes it alongside the vendor pool, where cixmini-boot and its mandatory
# ncz-usb-recovery dependency are published.

# prune debs for packages no longer in the resolved closure (e.g. dropped
# from the seed, or no longer pulled in as a dependency) so the pool doesn't
# grow unbounded now that it's no longer wiped on every run.
PRUNED=0
for f in "$OUT"/pool/main/*.deb; do
    [ -e "$f" ] || continue
    pkgname="${f##*/}"; pkgname="${pkgname%%_*}"
    grep -qxF "$pkgname" "$CLOSURE" || { rm -f "$f"; PRUNED=$((PRUNED+1)); }
done
[ "$PRUNED" -gt 0 ] && echo "  pruned $PRUNED stale deb(s) no longer in the closure"

DEBS=$(find "$OUT/pool" -name '*.deb' | wc -l)
echo "  downloaded/kept $DEBS debs"

# regenerate indexes (for standalone use; the ISO build regenerates from the
# combined server+desktop pool, so the ISO does not consume these dists/).
echo "  generating Packages/Release..."
mkdir -p "$OUT/dists/$SUITE/main/binary-$ARCH"
( cd "$OUT" && apt-ftparchive packages pool/main > "dists/$SUITE/main/binary-$ARCH/Packages" )
gzip -9c "$OUT/dists/$SUITE/main/binary-$ARCH/Packages" > "$OUT/dists/$SUITE/main/binary-$ARCH/Packages.gz"
# Remove any previous Release BEFORE regenerating it. The shell truncates the
# redirect target before apt-ftparchive scans the tree, and with a stale file
# present the emitted checksums could describe a Packages that no longer
# exists -- apt then rejects the mirror with "Hash Sum mismatch". Measured
# 2026-08-11 on build/forky-mirror: Release claimed sha256 b79c1dd8 for a
# Packages whose real hash was 733df18b, and deleting the old Release first
# fixed it. Same fix build-vendor-mirror.sh already carries.
( cd "$OUT" && rm -f "dists/$SUITE/Release" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=NCZ" \
    -o "APT::FTPArchive::Release::Label=NCZ-Desktop" \
    -o "APT::FTPArchive::Release::Suite=$SUITE" \
    -o "APT::FTPArchive::Release::Codename=$SUITE" \
    -o "APT::FTPArchive::Release::Components=main" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    release "dists/$SUITE" > "dists/$SUITE/Release" )

# closure packages that the local mirror did NOT have (informational)
FILLED="$T/filled"
if [ -f "$IDX" ]; then
    LOCAL_NAMES="$T/local-names"
    awk '/^Package: /{print $2}' "$IDX" | sort -u > "$LOCAL_NAMES"
    comm -23 "$CLOSURE" "$LOCAL_NAMES" > "$FILLED"
else
    cp "$CLOSURE" "$FILLED"
fi

# gap report
{
    echo "# NCZ desktop-mirror gap report — $(date -u +%FT%TZ)"
    echo "# Seed packages apt could not locate at all (bad name / not in the Debian archive):"
    if [ -s "$MISSING" ]; then sed 's/^/  MISSING-SEED: /' "$MISSING"; else echo "  (none)"; fi
    echo ""
    echo "# Closure packages NOT in the local mirror (pulled from Debian directly): $(wc -l < "$FILLED")"
    if [ -s "$FILLED" ]; then sed 's/^/  FROM-PORTS: /' "$FILLED"; else echo "  (none)"; fi
    echo ""
    echo "# Unmet/uninstallable complaints from dependency resolution:"
    if [ -s "$UNMET" ]; then sed 's/^/  /' "$UNMET"; else echo "  (none)"; fi
} > "$GAPS"

echo ""
echo "== summary =="
echo "  desktop mirror : $(du -sh "$OUT" | cut -f1) / $DEBS debs"
echo "  gaps report    : $GAPS"
echo "  --- gaps head ---"
sed -n '1,25p' "$GAPS"
