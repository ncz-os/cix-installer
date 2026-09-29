#!/bin/bash
# Build the one complete, profile-matched offline closure used by a Forky ISO.
set -euo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../release.conf
. "$REPO/release.conf"

SUITE="${SUITE:-$NCZ_BASE_CODENAME}"
# 2026-09-15: was hardcoded "arm64" regardless of caller -- an AMD64 build
# silently pulled arm64 packages into its offline closure. Derive from the
# same NCZ_TARGET_ARCH every other arch-aware script in this repo reads.
ARCH="${ARCH:-${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}}"
MIRROR_URL="${MIRROR_URL:-$NCZ_BASE_MIRROR}"
COMPONENTS="${COMPONENTS:-$NCZ_BASE_COMPONENTS}"
OUT="${OUT:-$REPO/build/$SUITE-mirror}"
VENDOR_MIRROR="${VENDOR_MIRROR:-$REPO/build/$SUITE-vendor-mirror}"
DESKTOP_MIRROR="${DESKTOP_MIRROR:-$REPO/build/desktop-mirror}"
DEBIAN_KEYRING="${DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
# Same arch-manifest-selection pattern as preflight-sbom-check.sh's
# manifest_for(): prefer manifests/<name>-$ARCH.pkgs when it exists
# (installer-base-amd64.pkgs, desktop-amd64.pkgs already do), falling back
# to the original arm64/default filename -- arm64 behavior unchanged.
_seed_for() {
    local arch_file="$REPO/manifests/$1-$ARCH.pkgs"
    if [ -f "$arch_file" ]; then echo "$arch_file"; else echo "$REPO/manifests/$1.pkgs"; fi
}
BASE_SEED="${BASE_SEED:-$(_seed_for installer-base)}"
DESKTOP_SEED="${DESKTOP_SEED:-$(_seed_for desktop)}"
FIRMWARE_SEED="${FIRMWARE_SEED:-$REPO/manifests/firmware.pkgs}"

[ "$SUITE" = "$NCZ_BASE_CODENAME" ] || {
    echo "ERROR: suite '$SUITE' does not match release profile '$NCZ_BASE_CODENAME'" >&2
    exit 1
}
[ -r "$DEBIAN_KEYRING" ] || { echo "ERROR: Debian archive keyring missing: $DEBIAN_KEYRING" >&2; exit 1; }
[ -d "$VENDOR_MIRROR/dists/$SUITE" ] || { echo "ERROR: vendor mirror missing: $VENDOR_MIRROR" >&2; exit 1; }
[ -d "$DESKTOP_MIRROR/dists/$SUITE" ] || { echo "ERROR: desktop mirror missing: $DESKTOP_MIRROR" >&2; exit 1; }
[ -s "$BASE_SEED" ] && [ -s "$DESKTOP_SEED" ] && [ -s "$FIRMWARE_SEED" ] || { echo "ERROR: required seed manifest missing" >&2; exit 1; }
if [ -e "$OUT" ] && [ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "ERROR: refusing to merge into existing mirror: $OUT" >&2
    echo "       choose a new OUT directory or audit and remove that exact prior mirror first." >&2
    exit 1
fi

echo "== build-$SUITE-mirror =="
echo "   suite=$SUITE arch=$ARCH source=$MIRROR_URL"
echo "   seeds=$(basename "$BASE_SEED"),$(basename "$DESKTOP_SEED"),$(basename "$FIRMWARE_SEED") vendor=$VENDOR_MIRROR desktop=$DESKTOP_MIRROR"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/etc/apt/apt.conf.d" "$TMP/etc/apt/preferences.d" \
         "$TMP/var/lib/apt/lists/partial" "$TMP/var/lib/dpkg" \
         "$TMP/var/cache/apt/archives/partial"
: > "$TMP/var/lib/dpkg/status"

# A pinned snapshot.debian.org mirror carries a short-lived Valid-Until --
# NCZ_BASE_MIRROR_APT_OPTS (release.conf) adds check-valid-until=no only when
# actually pinned, so an unpinned live-mirror build keeps normal expiry checks.
MIRROR_DEB_OPTS="arch=$ARCH signed-by=$DEBIAN_KEYRING"
[ -n "${NCZ_BASE_MIRROR_APT_OPTS:-}" ] && MIRROR_DEB_OPTS="$MIRROR_DEB_OPTS $NCZ_BASE_MIRROR_APT_OPTS"
cat > "$TMP/etc/apt/sources.list" <<EOF
deb [$MIRROR_DEB_OPTS] $MIRROR_URL $SUITE $COMPONENTS
deb [arch=$ARCH trusted=yes] file://$VENDOR_MIRROR $SUITE main
deb [arch=$ARCH trusted=yes] file://$DESKTOP_MIRROR $SUITE main
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
# manifests/install-extra.pkgs: packages that must be on the install media's
# offline mirror and are installed at install time by a post-install hook, NOT
# baked into desktop.squashfs (so adding one needs no layer rebuild). Optional.
EXTRA_SEED="${EXTRA_SEED:-$REPO/manifests/install-extra.pkgs}"
{
    grep -hvE '^[[:space:]]*(#|$)' "$BASE_SEED" "$DESKTOP_SEED" "$FIRMWARE_SEED" | awk '{print $1}'
    { [ -s "$EXTRA_SEED" ] && sed 's/#.*//' "$EXTRA_SEED" | awk 'NF {print $1}'; } || true
} | sort -u > "$SEED"
echo "  explicit seed: $(wc -l < "$SEED") packages"

SIMLOG="$TMP/sim.log"
if ! apt-get "${APTOPTS[@]}" install -s -y $(tr '\n' ' ' < "$SEED") > "$SIMLOG" 2>&1; then
    echo "ERROR: profile package set is not installable as one closure" >&2
    grep -E 'Depends:|Conflicts:|Breaks:|not installable|Unable to correct|held broken' "$SIMLOG" >&2 || tail -80 "$SIMLOG" >&2
    echo "  independently uninstallable seeds:" >&2
    while read -r pkg; do
        apt-get "${APTOPTS[@]}" install -s -y "$pkg" >/dev/null 2>&1 || echo "    $pkg" >&2
    done < "$SEED"
    exit 1
fi

CLOSURE="$TMP/closure"
awk '/^Inst / {print $2}' "$SIMLOG" | sort -u > "$CLOSURE"
[ -s "$CLOSURE" ] || { echo "ERROR: resolver returned an empty closure" >&2; exit 1; }
echo "  resolved closure: $(wc -l < "$CLOSURE") packages"

mkdir -p "$OUT/pool/main" "$OUT/dists/$SUITE/main/binary-$ARCH"
# Preserve the package universe apt resolved against.  The generated mirror
# index below describes only the closure and therefore cannot prove that a
# newly-published firmware package was omitted.  This local metadata snapshot
# makes verify-firmware-bom.sh an offline-capable, independently-triggerable
# gate rather than a comparison of the closure with itself.
mkdir -p "$OUT/.ncz-published-packages/$ARCH"
: > "$OUT/.ncz-published-packages/$ARCH/Packages"
while read -r index component index_arch; do
    case "$component" in main|non-free-firmware) ;; *) continue ;; esac
    [ "$index_arch" = "$ARCH" ] || continue
    /usr/lib/apt/apt-helper cat-file "$index" \
        >> "$OUT/.ncz-published-packages/$ARCH/Packages"
done < <(apt-get "${APTOPTS[@]}" indextargets \
    --format '$(FILENAME) $(COMPONENT) $(ARCHITECTURE)' \
    'Identifier: Packages')
[ -s "$OUT/.ncz-published-packages/$ARCH/Packages" ] || {
    echo "ERROR: could not preserve local $SUITE/$ARCH publication indices" >&2
    exit 1
}
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

# Provenance record for SBOM/audit -- which exact archive state this ISO's
# base packages came from, since MIRROR_URL alone in the build log scrolls
# away and isn't attached to the artifact itself.
{
    echo "source=$MIRROR_URL"
    echo "snapshot=${NCZ_BASE_MIRROR_SNAPSHOT:-none (live mirror)}"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/NCZ_MIRROR_PROVENANCE.txt"
