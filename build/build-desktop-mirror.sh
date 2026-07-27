#!/bin/bash
# build-desktop-mirror.sh — r130 fat/offline desktop closure mirror (arm64).
#
# Companion to build-server-mirror.sh. Where server-mirror carries the Ubuntu
# Server closure (Priority required/important/standard + server seed), THIS
# builds the closure of the Sky1 SINGULARITY desktop runtime set listed in
# manifests/desktop.pkgs (Singularity replaced XFCE in 26.7 — NO xubuntu-core,
# NO xfce4-*; Wayland-native GTK4 runtime libs + Chromium + mpv + Xwayland).
#
# build-iso-di.sh merges build/desktop-mirror/pool into the ISO pool alongside
# server-mirror and regenerates the single 'main' deb index from the combined
# pool, so post-install/20-desktop.sh installs the desktop fully OFFLINE from
# file:///cdrom (no ports.ubuntu.com dependency → no r129-style 20-desktop stall).
#
# Outputs:
#   build/desktop-mirror/        apt repo (dists/resolute + pool) — POOL is what
#                                the ISO consumes; dists/ is for standalone use.
#   build/desktop-mirror.gaps    closure pkgs not in the local resolute-mirror
#
# Method (identical to build-server-mirror.sh): a self-contained apt root over
# Ubuntu ports, arm64, simulate-install the desktop seed to compute the closure,
# apt-get download the exact closure versions into the new pool, regenerate
# indexes. Chromium is the one exception: Ubuntu 26.04 ships Chromium as snap
# only, so the browser seed uses Google's own signed real Chrome build
# (google-chrome-stable), pinned to one exact version + SHA256-verified, and
# folded into this offline mirror. No live Google apt source is installed on
# the appliance. (An earlier stop-gap used XtraDeb's ungoogled-chromium
# before real Chrome existed for arm64 — dropped 2026-07-27, superseded.)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/build/resolute-mirror"
OUT="$REPO/build/desktop-mirror"
SEEDFILE="$REPO/manifests/desktop.pkgs"
GAPS="$REPO/build/desktop-mirror.gaps"
SUITE=resolute
ARCH=arm64
IDX="$SRC/dists/$SUITE/main/binary-$ARCH/Packages"

# Source: Ubuntu ports (current, complete, authoritative). The desktop long
# tail (gimp, catfish, synaptic, xfce goodies, ...) lives largely in universe.
PORTS_URL="${PORTS_URL:-http://ports.ubuntu.com/ubuntu-ports}"

# Real, official Google Chrome for arm64 Linux (launched publicly Q2 2026,
# available since via Google's own signed apt repo). Folded into the offline
# mirror pool, same reasoning as everything else here: no live apt source on
# the shipped appliance (r180 doctrine), pin to one exact checksummed
# version. Adds Google account sync/Widevine DRM/Google Pay and (per
# post-install/84-vpu-vaapi.sh) confirmed working VA-API hardware video
# decode once that hook's fixes are applied; verified 2026-07-27 against
# Google's own published Packages index.
GOOGLE_CHROME_URL="${GOOGLE_CHROME_URL:-https://dl.google.com/linux/chrome/deb}"
GOOGLE_CHROME_KEY_URL="${GOOGLE_CHROME_KEY_URL:-https://dl.google.com/linux/linux_signing_key.pub}"
GOOGLE_CHROME_KEY="$REPO/build/google-chrome-apt-keyring.asc"
GOOGLE_CHROME_VERSION="150.0.7871.186-1"
GOOGLE_CHROME_PKGS="google-chrome-stable"
GOOGLE_CHROME_SHA256="02596a2d07db16eec42422b95dea374ee22d18c9ceaae9e9301298e0e2678fb3"

[ -f "$SEEDFILE" ] || { echo "ERROR: $SEEDFILE missing"; exit 1; }

echo "== build-desktop-mirror =="
echo "   seed=$SEEDFILE"
echo "   out=$OUT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/apt/preferences.d" "$T/etc/apt/apt.conf.d" "$T/etc/apt/keyrings" \
         "$T/var/lib/apt/lists/partial" "$T/var/lib/dpkg" \
         "$T/var/cache/apt/archives/partial"
: > "$T/var/lib/dpkg/status"

echo "  source: Ubuntu ports ($PORTS_URL) — authoritative desktop closure"
cat > "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE main universe restricted multiverse
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE-updates main universe restricted multiverse
EOF

if grep -Eq '^[[:space:]]*google-chrome-stable([[:space:]]|$)' "$SEEDFILE"; then
    [ -f "$GOOGLE_CHROME_KEY" ] || { echo "ERROR: $GOOGLE_CHROME_KEY missing"; exit 1; }
    cp "$GOOGLE_CHROME_KEY" "$T/etc/apt/keyrings/google-chrome-apt-keyring.asc"
    chmod 0644 "$T/etc/apt/keyrings/google-chrome-apt-keyring.asc"
    cat >> "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH signed-by=$T/etc/apt/keyrings/google-chrome-apt-keyring.asc] $GOOGLE_CHROME_URL stable main
EOF
    cat > "$T/etc/apt/preferences.d/google-chrome.pref" <<EOF
Package: $GOOGLE_CHROME_PKGS
Pin: version $GOOGLE_CHROME_VERSION
Pin-Priority: 700

Package: google-chrome-beta google-chrome-unstable google-chrome-canary
Pin: origin dl.google.com
Pin-Priority: -1
EOF
    echo "  source: Google Chrome (${GOOGLE_CHROME_URL}) — pinned to $GOOGLE_CHROME_VERSION, checksum-verified below"
fi

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
    _policy="$(apt-cache "${APTOPTS[@]}" policy google-chrome-stable)"
    if ! printf '%s\n' "$_policy" | grep -q " $GOOGLE_CHROME_VERSION"; then
        echo "ERROR: google-chrome-stable version $GOOGLE_CHROME_VERSION not visible from signed Google apt repo" >&2
        echo "       update GOOGLE_CHROME_VERSION + GOOGLE_CHROME_SHA256 only after verifying the new Packages entry" >&2
        exit 1
    fi
    # SHA256-verify the actual .deb, not just the version string — Google's
    # own Packages index publishes it, so pin against that exact value.
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
        _deb_sha="$(curl -fsSL -m 60 "$_deb_rel" -o "$T/google-chrome-stable.deb" && sha256sum "$T/google-chrome-stable.deb" | awk '{print $1}')"
        if [ "$_deb_sha" != "$GOOGLE_CHROME_SHA256" ]; then
            echo "ERROR: google-chrome-stable .deb SHA256 mismatch — expected $GOOGLE_CHROME_SHA256, got $_deb_sha" >&2
            exit 1
        fi
        echo "  verified google-chrome-stable $GOOGLE_CHROME_VERSION SHA256 matches pinned value"
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

# download the exact closure versions into the pool -- INCREMENTAL: keep
# whatever's already there (`apt-get download` itself skips re-fetching a
# .deb that's already present at the exact candidate version, verified
# empirically), so a re-run only pulls what's actually new/changed instead
# of re-downloading the entire ~1500-package closure every time.
mkdir -p "$OUT/pool/main"
echo "  downloading closure debs from ports (incremental)..."
if ! ( cd "$OUT/pool/main" && xargs -r apt-get "${APTOPTS[@]}" download < "$CLOSURE" >/dev/null 2>&1 ); then
    echo "  WARN: some downloads failed (see gaps report)"
fi

# NCZ-OS proprietary package: it is not published on Ubuntu ports, so add a
# locally-built copy directly in reprepro-style pool layout. This is optional
# to keep the mirror useful as a standalone Ubuntu closure builder.
SINGDEB=""
# Sort candidates so a stale/older .deb left in sinty-out from a previous
# build can never shadow the newest one (version-sort, newest last, per
# Codex review 2026-07-26 — the original first-match glob loop picked
# whichever candidate the shell happened to list first, which is undefined
# ordering, not necessarily the newest version).
SING_CANDIDATES="$(ls -1 "$REPO"/build/sinty-out/ncz-singularity-desktop_*_arm64.deb 2>/dev/null | sort -V || true)"
if [ -n "$SING_CANDIDATES" ]; then
    SINGDEB="$(printf '%s\n' "$SING_CANDIDATES" | tail -1)"
    N="$(printf '%s\n' "$SING_CANDIDATES" | wc -l)"
    [ "$N" -gt 1 ] && echo "  NOTE: $N candidate ncz-singularity-desktop .debs found in sinty-out; using newest by version: $(basename "$SINGDEB")"
fi
if [ -n "$SINGDEB" ]; then
    SINGPOOL="$OUT/pool/main/n/ncz-singularity-desktop"
    mkdir -p "$SINGPOOL"
    cp -f "$SINGDEB" "$SINGPOOL/"
    echo "  added local NCZ package: $SINGDEB -> $SINGPOOL/"
else
    echo "  WARN: no local ncz-singularity-desktop_*_arm64.deb at $REPO/build/sinty-out — continuing without it"
fi

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
( cd "$OUT" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=NCZ" \
    -o "APT::FTPArchive::Release::Label=NCZ-Desktop" \
    -o "APT::FTPArchive::Release::Suite=$SUITE" \
    -o "APT::FTPArchive::Release::Codename=$SUITE" \
    -o "APT::FTPArchive::Release::Components=main" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    release "dists/$SUITE" > "dists/$SUITE/Release" )

# closure packages that the local resolute-mirror did NOT have (informational)
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
    echo "# Seed packages apt could not locate at all (bad name / not in resolute):"
    if [ -s "$MISSING" ]; then sed 's/^/  MISSING-SEED: /' "$MISSING"; else echo "  (none)"; fi
    echo ""
    echo "# Closure packages NOT in the local resolute-mirror (pulled from ports): $(wc -l < "$FILLED")"
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
