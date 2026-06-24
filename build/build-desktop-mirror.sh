#!/bin/bash
# build-desktop-mirror.sh — r130 fat/offline desktop closure mirror (arm64).
#
# Companion to build-server-mirror.sh. Where server-mirror carries the Ubuntu
# Server closure (Priority required/important/standard + server seed), THIS
# builds the closure of the curated Sky1 XFCE desktop set + r130 buckets
# (completeness / offline-apt tools / GIMP) listed in manifests/desktop.pkgs.
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
# indexes.
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

[ -f "$SEEDFILE" ] || { echo "ERROR: $SEEDFILE missing"; exit 1; }

echo "== build-desktop-mirror =="
echo "   seed=$SEEDFILE"
echo "   out=$OUT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/apt/preferences.d" "$T/etc/apt/apt.conf.d" \
         "$T/var/lib/apt/lists/partial" "$T/var/lib/dpkg" \
         "$T/var/cache/apt/archives/partial"
: > "$T/var/lib/dpkg/status"

echo "  source: Ubuntu ports ($PORTS_URL) — authoritative desktop closure"
cat > "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE main universe restricted multiverse
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE-updates main universe restricted multiverse
EOF

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

echo "  apt-get update (ports)..."
apt-get "${APTOPTS[@]}" update >/dev/null 2>&1

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

# download the exact closure versions into the new pool
rm -rf "$OUT"; mkdir -p "$OUT/pool/main"
echo "  downloading closure debs from ports..."
( cd "$OUT/pool/main" && apt-get "${APTOPTS[@]}" download $(tr '\n' ' ' < "$CLOSURE") >/dev/null 2>&1 ) \
    || echo "  WARN: some downloads failed (see gaps report)"

DEBS=$(find "$OUT/pool" -name '*.deb' | wc -l)
echo "  downloaded $DEBS debs"

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
