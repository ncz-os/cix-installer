#!/bin/bash
# build-server-mirror.sh — trim the full resolute mirror down to the NCZ
# "Ubuntu Server library" closure (server seed + everything Priority
# required/important/standard + their full dependency closure). Desktop /
# end-user packages (Priority optional that nothing in the seed needs) are
# dropped; those come from Ubuntu online per policy.
#
# Outputs:
#   build/server-mirror/        trimmed apt repo (dists/resolute + pool)
#   build/server-mirror.gaps    seeds/deps requested but NOT in the source mirror
#
# Method: a self-contained apt root over the existing file:// mirror, arm64,
# simulate-install the seed to compute the closure, then apt-get download the
# exact closure versions into the new pool and regenerate indexes.
set -euo pipefail

# LC_ALL=C: see build-desktop-mirror.sh for the full rationale — independent
# `sort -u` calls can disagree on collation order under the build host's
# default locale, breaking the `comm` diffs below ("not in sorted order").
export LC_ALL=C

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/build/resolute-mirror"
OUT="$REPO/build/server-mirror"
SEEDFILE="$REPO/build/server-seed.txt"
GAPS="$REPO/build/server-mirror.gaps"
SUITE=resolute
ARCH=arm64
IDX="$SRC/dists/$SUITE/main/binary-$ARCH/Packages"

# Online fill: pull anything the local desktop mirror is missing (e.g. server
# essentials like efibootmgr/initramfs-tools/systemd-boot) from Ubuntu ports.
# Set NO_NETWORK=1 for a pure offline trim of only what the local mirror has.
PORTS_URL="${PORTS_URL:-http://ports.ubuntu.com/ubuntu-ports}"
NO_NETWORK="${NO_NETWORK:-0}"

[ -d "$SRC" ]      || { echo "ERROR: $SRC missing"; exit 1; }
[ -f "$IDX" ]      || { echo "ERROR: $IDX missing"; exit 1; }
[ -f "$SEEDFILE" ] || { echo "ERROR: $SEEDFILE missing"; exit 1; }

echo "== build-server-mirror =="
echo "   src=$SRC"
echo "   out=$OUT"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/apt/preferences.d" "$T/etc/apt/apt.conf.d" \
         "$T/var/lib/apt/lists/partial" "$T/var/lib/dpkg" \
         "$T/var/cache/apt/archives/partial"
: > "$T/var/lib/dpkg/status"

# Source selection. We do NOT mix the (stale) local snapshot with (current)
# ports — that causes version-skew dep conflicts (e.g. systemd-boot 259.5 from
# ports vs older systemd locally). Pick ONE self-consistent source:
#   default      -> Ubuntu ports only (current, complete, authoritative)
#   NO_NETWORK=1 -> local file mirror only (offline trim; may miss essentials)
if [ "$NO_NETWORK" = "1" ]; then
    echo "  source: local mirror only (offline trim)"
    cat > "$T/etc/apt/sources.list" <<EOF
deb [trusted=yes] file://$SRC $SUITE main universe restricted multiverse
EOF
else
    echo "  source: Ubuntu ports ($PORTS_URL) — authoritative server closure"
    cat > "$T/etc/apt/sources.list" <<EOF
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE main universe restricted multiverse
deb [arch=$ARCH trusted=yes] $PORTS_URL $SUITE-updates main universe restricted multiverse
EOF
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

echo "  apt-get update ($([ "$NO_NETWORK" = 1 ] && echo 'local only' || echo 'local + ports'))..."
apt-get "${APTOPTS[@]}" update >/dev/null 2>&1

# all package names apt can see (local mirror + ports, if enabled)
ALL_NAMES="$T/all-names"
apt-cache "${APTOPTS[@]}" pkgnames 2>/dev/null | sort -u > "$ALL_NAMES"

# seed = explicit seed file + every required/important/standard package
SEED="$T/seed"
{
    grep -vE '^\s*(#|$)' "$SEEDFILE" | awk '{print $1}'
    awk -v RS='' '/\nPriority: (required|important|standard)\n/{ for(i=1;i<=NF;i++) if($i=="Package:"){print $(i+1)} }' "$IDX"
} | sort -u > "$SEED"
echo "  seed packages (explicit + req/imp/std): $(wc -l < "$SEED")"

# split seed into present vs missing-from-mirror
PRESENT="$T/present"; MISSING="$T/missing"
comm -12 "$SEED" "$ALL_NAMES" > "$PRESENT"
comm -23 "$SEED" "$ALL_NAMES" > "$MISSING"

echo "  seed present in mirror: $(wc -l < "$PRESENT")   missing: $(wc -l < "$MISSING")"

# Resolve the closure. First try one atomic simulate (fast, exact). If that
# fails (one awkward seed can abort the whole set), fall back to a tolerant
# per-seed union so a single uninstallable seed doesn't zero everything.
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
# whatever's already there (`apt-get download` skips re-fetching a .deb
# that's already present at the exact candidate version, same fix as
# build-desktop-mirror.sh 2026-07-05), so a re-run only pulls what's
# actually new/changed.
mkdir -p "$OUT/pool/main"
echo "  downloading closure debs from source mirror (incremental)..."
( cd "$OUT/pool/main" && apt-get "${APTOPTS[@]}" download $(tr '\n' ' ' < "$CLOSURE") >/dev/null 2>&1 ) \
    || echo "  WARN: some downloads failed (see gaps report)"

# prune debs for packages no longer in the resolved closure so the pool
# doesn't grow unbounded now that it's no longer wiped on every run.
PRUNED=0
for f in "$OUT"/pool/main/*.deb; do
    [ -e "$f" ] || continue
    pkgname="${f##*/}"; pkgname="${pkgname%%_*}"
    grep -qxF "$pkgname" "$CLOSURE" || { rm -f "$f"; PRUNED=$((PRUNED+1)); }
done
[ "$PRUNED" -gt 0 ] && echo "  pruned $PRUNED stale deb(s) no longer in the closure"

DEBS=$(find "$OUT/pool" -name '*.deb' | wc -l)
echo "  downloaded/kept $DEBS debs"

# regenerate indexes
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
    -o "APT::FTPArchive::Release::Label=NCZ-Server" \
    -o "APT::FTPArchive::Release::Suite=$SUITE" \
    -o "APT::FTPArchive::Release::Codename=$SUITE" \
    -o "APT::FTPArchive::Release::Components=main" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    release "dists/$SUITE" > "dists/$SUITE/Release" )

# closure packages that the local desktop mirror did NOT have (filled from ports)
LOCAL_NAMES="$T/local-names"
awk '/^Package: /{print $2}' "$IDX" | sort -u > "$LOCAL_NAMES"
FILLED="$T/filled"
comm -23 "$CLOSURE" "$LOCAL_NAMES" > "$FILLED"

# gap report
{
    echo "# NCZ server-mirror gap report — $(date -u +%FT%TZ)"
    echo "# Seed packages apt could not locate at all (bad name / not in resolute):"
    if [ -s "$MISSING" ]; then sed 's/^/  MISSING-SEED: /' "$MISSING"; else echo "  (none)"; fi
    echo ""
    echo "# Closure packages NOT in the local mirror (filled from Ubuntu ports): $(wc -l < "$FILLED")"
    if [ -s "$FILLED" ]; then sed 's/^/  FROM-PORTS: /' "$FILLED"; else echo "  (none)"; fi
    echo ""
    echo "# Unmet/uninstallable complaints from dependency resolution:"
    if [ -s "$UNMET" ]; then sed 's/^/  /' "$UNMET"; else echo "  (none)"; fi
} > "$GAPS"

echo ""
echo "== summary =="
echo "  source mirror : $(du -sh "$SRC" | cut -f1) / $(find "$SRC" -name '*.deb' | wc -l) debs"
echo "  server mirror : $(du -sh "$OUT" | cut -f1) / $DEBS debs"
echo "  gaps report   : $GAPS"
echo "  --- gaps head ---"
sed -n '1,25p' "$GAPS"
