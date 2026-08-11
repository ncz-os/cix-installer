#!/bin/bash
# Build the one complete, profile-matched offline closure used by a Forky ISO.
set -euo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../release.conf
. "$REPO/release.conf"

SUITE="${SUITE:-$NCZ_BASE_CODENAME}"
ARCH="${ARCH:-arm64}"
MIRROR_URL="${MIRROR_URL:-$NCZ_BASE_MIRROR}"
COMPONENTS="${COMPONENTS:-$NCZ_BASE_COMPONENTS}"
OUT="${OUT:-$REPO/build/$SUITE-mirror}"
VENDOR_MIRROR="${VENDOR_MIRROR:-$REPO/build/$SUITE-vendor-mirror}"
DEBIAN_KEYRING="${DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
BASE_SEED="$REPO/manifests/installer-base.pkgs"
DESKTOP_SEED="$REPO/manifests/desktop.pkgs"

[ "$SUITE" = "$NCZ_BASE_CODENAME" ] || {
    echo "ERROR: suite '$SUITE' does not match release profile '$NCZ_BASE_CODENAME'" >&2
    exit 1
}
[ -r "$DEBIAN_KEYRING" ] || { echo "ERROR: Debian archive keyring missing: $DEBIAN_KEYRING" >&2; exit 1; }
[ -d "$VENDOR_MIRROR/dists/$SUITE" ] || { echo "ERROR: vendor mirror missing: $VENDOR_MIRROR" >&2; exit 1; }
[ -s "$BASE_SEED" ] && [ -s "$DESKTOP_SEED" ] || { echo "ERROR: required seed manifest missing" >&2; exit 1; }
if [ -e "$OUT" ] && [ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "ERROR: refusing to merge into existing mirror: $OUT" >&2
    echo "       choose a new OUT directory or audit and remove that exact prior mirror first." >&2
    exit 1
fi

echo "== build-$SUITE-mirror =="
echo "   suite=$SUITE arch=$ARCH source=$MIRROR_URL"
echo "   seeds=$(basename "$BASE_SEED"),$(basename "$DESKTOP_SEED") vendor=$VENDOR_MIRROR"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/etc/apt/apt.conf.d" "$TMP/etc/apt/preferences.d" \
         "$TMP/var/lib/apt/lists/partial" "$TMP/var/lib/dpkg" \
         "$TMP/var/cache/apt/archives/partial"
: > "$TMP/var/lib/dpkg/status"

cat > "$TMP/etc/apt/sources.list" <<EOF
deb [arch=$ARCH signed-by=$DEBIAN_KEYRING] $MIRROR_URL $SUITE $COMPONENTS
deb [arch=$ARCH trusted=yes] file://$VENDOR_MIRROR $SUITE main
EOF

APTOPTS=(
    -o "Dir=$TMP"
    -o "Dir::State=$TMP/var/lib/apt"
    -o "Dir::State::status=$TMP/var/lib/dpkg/status"
    -o "Dir::Cache=$TMP/var/cache/apt"
    -o "Dir::Etc=$TMP/etc/apt"
    -o "APT::Architecture=$ARCH"
    -o "APT::Architectures=$ARCH"
    -o "Acquire::Languages=none"
    -o "APT::Install-Recommends=0"
)

echo "  refreshing signed Debian and pinned vendor indexes"
apt-get "${APTOPTS[@]}" update >/dev/null

SEED="$TMP/seed"
{
    grep -hvE '^[[:space:]]*(#|$)' "$BASE_SEED" "$DESKTOP_SEED" | awk '{print $1}'
} | sort -u > "$SEED"
echo "  explicit seed: $(wc -l < "$SEED") packages"

SIMLOG="$TMP/sim.log"
if ! apt-get "${APTOPTS[@]}" install -s -y $(tr '\n' ' ' < "$SEED") > "$SIMLOG" 2>&1; then
    echo "ERROR: profile package set is not installable as one closure" >&2
    grep -E 'Depends:|Conflicts:|not installable|Unable to correct' "$SIMLOG" >&2 || tail -80 "$SIMLOG" >&2
    exit 1
fi

CLOSURE="$TMP/closure"
awk '/^Inst / {print $2}' "$SIMLOG" | sort -u > "$CLOSURE"
[ -s "$CLOSURE" ] || { echo "ERROR: resolver returned an empty closure" >&2; exit 1; }
echo "  resolved closure: $(wc -l < "$CLOSURE") packages"

mkdir -p "$OUT/pool/main" "$OUT/dists/$SUITE/main/binary-$ARCH"
echo "  downloading exact closure"
if ! (cd "$OUT/pool/main" && xargs -r apt-get "${APTOPTS[@]}" download < "$CLOSURE"); then
    echo "ERROR: failed to download complete closure; output is intentionally not indexed" >&2
    exit 1
fi

ACTUAL="$TMP/actual"
# dpkg-deb -f takes the ARCHIVE first and the field name after it, so the
# package list has to be built one archive at a time; passing a batch of
# filenames after "-f Package" makes dpkg-deb try to open an archive called
# "Package" and fail the whole verification step.
find "$OUT/pool/main" -type f -name '*.deb' -print0 | \
    xargs -0 -r -n1 -I{} dpkg-deb -f {} Package | sort -u > "$ACTUAL"
MISSING="$TMP/missing"
comm -23 "$CLOSURE" "$ACTUAL" > "$MISSING"
if [ -s "$MISSING" ]; then
    echo "ERROR: downloaded mirror is incomplete:" >&2
    sed 's/^/  /' "$MISSING" >&2
    exit 1
fi

(cd "$OUT" && dpkg-scanpackages --multiversion pool/main /dev/null \
    > "dists/$SUITE/main/binary-$ARCH/Packages")
gzip -9n -c "$OUT/dists/$SUITE/main/binary-$ARCH/Packages" \
    > "$OUT/dists/$SUITE/main/binary-$ARCH/Packages.gz"
# Remove any previous Release BEFORE regenerating it. The shell truncates the
# redirect target before apt-ftparchive scans the tree, and with a stale file
# present the emitted checksums could describe a Packages that no longer
# exists -- apt then rejects the mirror with "Hash Sum mismatch". Measured
# 2026-08-11 on build/forky-mirror: Release claimed sha256 b79c1dd8 for a
# Packages whose real hash was 733df18b, and deleting the old Release first
# fixed it. Same fix build-vendor-mirror.sh already carries.
(cd "$OUT" && rm -f "dists/$SUITE/Release" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=NCZ-OS" \
    -o "APT::FTPArchive::Release::Label=NCZ-OS-$SUITE" \
    -o "APT::FTPArchive::Release::Suite=$SUITE" \
    -o "APT::FTPArchive::Release::Codename=$SUITE" \
    -o "APT::FTPArchive::Release::Components=main" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    release "dists/$SUITE" > "dists/$SUITE/Release")

COUNT="$(grep -c '^Package: ' "$OUT/dists/$SUITE/main/binary-$ARCH/Packages")"
echo "  verified offline mirror: $COUNT package records, $(du -sh "$OUT/pool" | cut -f1) pool"
