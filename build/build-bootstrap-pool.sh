#!/bin/bash
# build-bootstrap-pool.sh - build the small pkgsel bootstrap pool for
# netinstall-bootstrap ISOs.
#
# This is intentionally not a base-installable mirror. It carries the
# pkgsel/include hard dependency closure so pkgsel can install the SSH,
# curl, gnupg, lsb-release, sudo, and CA package set from /cdrom, while
# debootstrap still uses the configured HTTP mirror for the base system.

set -euo pipefail

CHROOT="${1:-/home/jasonperlow/cix-installer-build/cix-installer/build/questing-bootstrap}"
MIRROR_DIR="${2:-/home/jasonperlow/cix-installer-build/cix-installer/build/questing-bootstrap-pool}"
SUITE="${3:-questing}"
ARCH="${4:-arm64}"
UBUNTU_URL="${5:-http://ports.ubuntu.com/ubuntu-ports}"

PKGS=(
  openssh-server
  ca-certificates
  curl
  gnupg
  lsb-release
  sudo
)

[ -d "$CHROOT" ] || { echo "ERROR: chroot $CHROOT does not exist" >&2; exit 1; }
[ -d "$CHROOT/var/cache/apt" ] || { echo "ERROR: chroot does not look bootstrapped" >&2; exit 1; }

for t in apt-ftparchive awk basename chroot cp cut dpkg-deb du find gzip head \
         mkdir mktemp mount mountpoint mv rm sed sort sudo tee umount wc; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done

for t in /usr/bin/env /usr/bin/apt-cache /usr/bin/apt-get; do
    [ -x "$CHROOT$t" ] || { echo "ERROR: chroot missing executable: $t" >&2; exit 1; }
done

echo "[bootstrap-pool] chroot:   $CHROOT"
echo "[bootstrap-pool] mirror:   $MIRROR_DIR"
echo "[bootstrap-pool] suite:    $SUITE"
echo "[bootstrap-pool] arch:     $ARCH"
echo "[bootstrap-pool] upstream: $UBUNTU_URL"
echo "[bootstrap-pool] explicit: ${PKGS[*]}"
echo ""

write_component_release_files() {
    local suite="$1"
    local arch="$2"
    local base="dists/$suite"
    local dir rel component count=0

    [ -d "$base" ] || return 0

    while IFS= read -r dir; do
        rel="${dir#$base/}"
        component="${rel%%/*}"
        [ -n "$component" ] || continue

        cat > "$dir/Release" <<EOF
Archive: stable
Origin: nclawzero
Label: nclawzero-cixmini-questing
Version: 1.0
Acquire-By-Hash: yes
Component: $component
Architecture: $arch
EOF
        count=$((count + 1))
    done < <(find "$base" -type f \( -name Packages -o -name Packages.gz \) -path "*/binary-$arch/*" -exec dirname {} \; | sort -u)

    echo "[bootstrap-pool] wrote $count per-component Release files"
}

write_translation_indexes() {
    local suite="$1"
    local component="$2"
    local dir="dists/$suite/$component/i18n"

    mkdir -p "$dir"
    : > "$dir/Translation-en"
    gzip -9cn "$dir/Translation-en" > "$dir/Translation-en.gz"
}

write_suite_release() {
    local suite="$1"
    local arch="$2"
    local components="$3"
    local description="$4"
    local conf release_tmp filtered_tmp

    conf=$(mktemp "${TMPDIR:-/tmp}/aptftp.XXXXXX")
    release_tmp=$(mktemp "${TMPDIR:-/tmp}/Release.XXXXXX")
    filtered_tmp="${release_tmp}.filtered"

    cat > "$conf" <<EOF
APT::FTPArchive::Release {
  Origin "nclawzero";
  Label "nclawzero-cixmini-$suite";
  Suite "$suite";
  Codename "$suite";
  Version "1.0";
  Acquire-By-Hash "yes";
  Architectures "$arch";
  Components "$components";
  Description "$description";
};
APT::FTPArchive::Release::Patterns {
  "main/binary-$arch/Packages";
  "main/binary-$arch/Packages.gz";
  "main/binary-$arch/Release";
  "main/i18n/Translation-*";
};
EOF

    rm -f "dists/$suite/Release" "dists/$suite/InRelease" "dists/$suite/Release.gpg"
    apt-ftparchive -c "$conf" release "dists/$suite" > "$release_tmp"
    awk '
        /^[[:space:]]+[0-9A-Fa-f]+[[:space:]]+[0-9]+[[:space:]]+Release$/ { next }
        { print }
    ' "$release_tmp" > "$filtered_tmp"
    mv "$filtered_tmp" "dists/$suite/Release"
    rm -f "$conf" "$release_tmp"
}

sudo tee "$CHROOT/etc/apt/sources.list" > /dev/null <<EOF
deb $UBUNTU_URL $SUITE main universe multiverse restricted
deb $UBUNTU_URL $SUITE-updates main universe multiverse restricted
deb $UBUNTU_URL $SUITE-security main universe multiverse restricted
EOF

echo "[bootstrap-pool] sources.list configured"

for d in /dev /proc /sys; do
    if ! mountpoint -q "$CHROOT$d"; then
        sudo mount --bind "$d" "$CHROOT$d"
    fi
done
trap 'for d in /sys /proc /dev; do mountpoint -q "$CHROOT$d" && sudo umount "$CHROOT$d" || true; done' EXIT

sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update

CHROOT_DOWNLOAD_DIR="/tmp/ncz-bootstrap-pool-downloads"
CHROOT_RAW_LIST="/tmp/ncz-bootstrap-pool-packages.raw"
CHROOT_PKG_LIST="/tmp/ncz-bootstrap-pool-packages.txt"
CHROOT_PLAN_LIST="/tmp/ncz-bootstrap-pool-install-plan.txt"

sudo rm -rf "$CHROOT$CHROOT_DOWNLOAD_DIR"
sudo mkdir -p "$CHROOT$CHROOT_DOWNLOAD_DIR"

sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    /bin/sh -s -- "$CHROOT_DOWNLOAD_DIR" "$CHROOT_RAW_LIST" "$CHROOT_PKG_LIST" "$CHROOT_PLAN_LIST" "${PKGS[@]}" <<'CHROOT_SCRIPT'
set -eu
download_dir="$1"
raw_list="$2"
pkg_list="$3"
plan_list="$4"
shift 4

apt-cache depends --recurse \
    --no-recommends --no-suggests --no-conflicts --no-breaks \
    --no-replaces --no-enhances "$@" |
awk '
    /^[[:alnum:]][[:alnum:]+.-]+$/ {
        print $1
        next
    }
    /^[[:space:]]*\|?(PreDepends|Depends):[[:space:]]+/ {
        pkg=$2
        gsub(/[<>]/, "", pkg)
        sub(/:.*/, "", pkg)
        if (pkg ~ /^[[:alnum:]][[:alnum:]+.-]+$/) {
            print pkg
        }
    }
' | sort -u > "$raw_list"

: > "$pkg_list.unsorted"
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        printf '%s\n' "$pkg" >> "$pkg_list.unsorted"
    fi
done < "$raw_list"
sort -u "$pkg_list.unsorted" > "$pkg_list"
rm -f "$pkg_list.unsorted"

apt-get install -s -y --no-install-recommends "$@" |
awk '/^Inst / { print $2 }' | sort -u > "$plan_list" || true

cd "$download_dir"
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    apt-get download "$pkg"
done < "$pkg_list"
CHROOT_SCRIPT

PKG_COUNT=$(sudo wc -l "$CHROOT$CHROOT_PKG_LIST" | awk '{print $1}')
PLAN_COUNT=$(sudo wc -l "$CHROOT$CHROOT_PLAN_LIST" | awk '{print $1}')
echo "[bootstrap-pool] package closure: $PKG_COUNT packages"
echo "[bootstrap-pool] simulated install needs: $PLAN_COUNT packages"

sudo rm -rf "$MIRROR_DIR"
mkdir -p "$MIRROR_DIR/pool/main" \
         "$MIRROR_DIR/dists/$SUITE/main/binary-$ARCH"

sudo cp "$CHROOT$CHROOT_RAW_LIST" "$MIRROR_DIR/bootstrap-pool.packages.raw.txt"
sudo cp "$CHROOT$CHROOT_PKG_LIST" "$MIRROR_DIR/bootstrap-pool.packages.txt"
sudo cp "$CHROOT$CHROOT_PLAN_LIST" "$MIRROR_DIR/bootstrap-pool.install-plan.txt"

echo "[bootstrap-pool] assembling pool tree"
for deb in "$CHROOT$CHROOT_DOWNLOAD_DIR"/*.deb; do
    [ -f "$deb" ] || continue
    pkg_name=$(dpkg-deb -f "$deb" Package)
    [ -n "$pkg_name" ] || continue
    if [[ "$pkg_name" == lib* ]]; then
        letter="${pkg_name:0:4}"
    else
        letter="${pkg_name:0:1}"
    fi
    dest="$MIRROR_DIR/pool/main/$letter/$pkg_name"
    mkdir -p "$dest"
    sudo cp "$deb" "$dest/"
done

POOL_COUNT=$(find "$MIRROR_DIR/pool" -name '*.deb' | wc -l)
if [ "$POOL_COUNT" -eq 0 ]; then
    echo "ERROR: bootstrap pool has no debs" >&2
    exit 1
fi
echo "[bootstrap-pool] pool/ has $POOL_COUNT debs ($(du -sh "$MIRROR_DIR/pool" | cut -f1))"

echo "[bootstrap-pool] generating Packages indexes"
cd "$MIRROR_DIR"
apt-ftparchive packages pool/main > "dists/$SUITE/main/binary-$ARCH/Packages"
gzip -9cn "dists/$SUITE/main/binary-$ARCH/Packages" > "dists/$SUITE/main/binary-$ARCH/Packages.gz"

write_translation_indexes "$SUITE" main
write_component_release_files "$SUITE" "$ARCH"
write_suite_release "$SUITE" "$ARCH" "main" "nclawzero cixmini netinstall bootstrap pool - $SUITE $ARCH"

echo "[bootstrap-pool] Release file:"
head -20 "dists/$SUITE/Release" | sed 's/^/    /'

echo ""
echo "[bootstrap-pool] mirror tree complete:"
echo "    $MIRROR_DIR/"
du -sh "$MIRROR_DIR/"
