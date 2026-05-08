#!/bin/bash
# build-mirror.sh — build offline questing arm64 apt mirror for r26 ISO
#
# Run AFTER debootstrap finishes. Inside the chroot, runs apt-get update +
# apt-get -d install for our full package set. Then assembles the result
# into /pool + /dists/questing/ structure with apt-ftparchive-generated
# Packages files + Release file.
#
# Result: $MIRROR_DIR/{pool,dists}/ — drop into ISO at root, point d-i
# preseed at it via mirror/protocol cdrom.

set -euo pipefail

CHROOT="${1:-/home/jasonperlow/cix-installer-build/cix-installer/build/questing-bootstrap}"
MIRROR_DIR="${2:-/home/jasonperlow/cix-installer-build/cix-installer/build/questing-mirror}"
SUITE="${3:-questing}"
ARCH="${4:-arm64}"
UBUNTU_URL="${5:-http://ports.ubuntu.com/ubuntu-ports}"

[ -d "$CHROOT" ] || { echo "ERROR: chroot $CHROOT does not exist"; exit 1; }
[ -d "$CHROOT/var/cache/apt" ] || { echo "ERROR: chroot doesn't look bootstrapped"; exit 1; }

for t in apt-ftparchive awk basename chroot cp cut dpkg-deb du find gzip head \
         mkdir mount mountpoint mv rm sed sort sudo tail tee tr umount wc; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done

for t in /usr/bin/env /usr/bin/apt-get /usr/bin/dpkg-query; do
    [ -x "$CHROOT$t" ] || { echo "ERROR: chroot missing executable: $t" >&2; exit 1; }
done

echo "[mirror] chroot:   $CHROOT"
echo "[mirror] mirror:   $MIRROR_DIR"
echo "[mirror] suite:    $SUITE"
echo "[mirror] arch:     $ARCH"
echo "[mirror] upstream: $UBUNTU_URL"
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

    echo "[mirror] wrote $count per-component Release files"
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
  "main/debian-installer/binary-$arch/Packages";
  "main/debian-installer/binary-$arch/Packages.gz";
  "main/debian-installer/binary-$arch/Release";
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

# ----------------------------------------------------------------------
# Configure sources.list inside chroot — main, universe, multiverse,
# restricted on the upstream URL. This is what apt sees inside the
# chroot when we run apt-get install.
# ----------------------------------------------------------------------
sudo tee "$CHROOT/etc/apt/sources.list" > /dev/null <<EOF
deb $UBUNTU_URL $SUITE main universe multiverse restricted
deb $UBUNTU_URL $SUITE-updates main universe multiverse restricted
deb $UBUNTU_URL $SUITE-security main universe multiverse restricted
EOF

echo "[mirror] sources.list configured"

# Bind-mount /dev /proc /sys for chroot apt operations
for d in /dev /proc /sys; do
    if ! mountpoint -q "$CHROOT$d"; then
        sudo mount --bind "$d" "$CHROOT$d"
    fi
done
trap 'for d in /sys /proc /dev; do mountpoint -q "$CHROOT$d" && sudo umount "$CHROOT$d" || true; done' EXIT

# ----------------------------------------------------------------------
# Inside chroot: apt-get update + apt-get -d install full package list
# ----------------------------------------------------------------------
sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update

# Comprehensive package list — server + full GNOME + XFCE + drivers +
# dev tools + multimedia + native driver support. Ubuntu-correct names.
PKGS=(
  # Server / infrastructure
  ubuntu-server openssh-server openssh-client
  network-manager systemd-resolved
  sudo apt-utils ca-certificates gnupg lsb-release
  curl wget rsync less vim nano
  htop btop iotop ncdu tree lsof strace ltrace
  zstd xz-utils p7zip-full unzip pigz
  pciutils usbutils dmidecode acpid
  dnsutils iputils-ping iputils-tracepath mtr-tiny
  tcpdump nmap netcat-openbsd
  ethtool iproute2 net-tools
  bash-completion software-properties-common
  unattended-upgrades update-manager-core

  # GNOME desktop (full)
  ubuntu-desktop-minimal ubuntu-desktop
  gnome-tweaks gnome-shell-extensions
  gnome-software gnome-software-plugin-flatpak
  gnome-remote-desktop nautilus gedit
  gnome-terminal

  # XFCE desktop (full)
  xubuntu-core xfce4 xfce4-goodies
  xfce4-terminal xfce4-power-manager
  xfce4-screenshooter xfce4-taskmanager
  xfce4-pulseaudio-plugin mousepad thunar
  lightdm

  # Login / plymouth
  gdm3 plymouth plymouth-themes
  xrdp

  # Graphics / Mesa / Vulkan / firmware
  mesa-utils mesa-vulkan-drivers mesa-va-drivers
  libdrm2 libgbm1 libegl1 libgl1-mesa-dri libglu1-mesa
  vulkan-tools glmark2-x11 glmark2-wayland
  linux-firmware

  # Multimedia
  ffmpeg mpv vlc
  gstreamer1.0-libav
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
  gstreamer1.0-plugins-ugly gstreamer1.0-vaapi
  pipewire pipewire-pulse

  # Dev tooling
  build-essential git neovim tmux gdb
  python3 python3-pip python3-venv python3-dev
  nodejs npm
  golang
  rustc cargo

  # Containers
  podman skopeo buildah
  docker.io docker-compose

  # Flatpak (newer apps later)
  flatpak

  # Branding / image manipulation
  imagemagick

  # Browsers — Ubuntu uses 'firefox' (deb pulls snap on default Ubuntu;
  # we accept that for now since snap support is included)
  firefox

  # Bluetooth + audio
  bluez bluetooth

  # Misc essentials
  file man-db manpages
)

echo ""
echo "[mirror] downloading ${#PKGS[@]} explicit packages + dependencies..."

# Per-package fallback identifies every unavailable package instead of stopping
# at the first apt error, but an incomplete mirror is still a hard failure.
if ! sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -d -y "${PKGS[@]}" 2>&1 | tail -20; then
    echo "[mirror] bulk install failed — falling back to per-package downloads"
    FAILED_PKGS=()
    for pkg in "${PKGS[@]}"; do
        if sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
            apt-get install -d -y "$pkg" 2>&1 | tail -2; then
            :
        else
            echo "[mirror]   FAIL: $pkg" >&2
            FAILED_PKGS+=("$pkg")
        fi
    done
    if [ "${#FAILED_PKGS[@]}" -gt 0 ]; then
        echo "[mirror] ERROR: package downloads failed; refusing to build incomplete mirror" >&2
        printf '    %s\n' "${FAILED_PKGS[@]}" >&2
        exit 1
    fi
fi

# CRITICAL (codex r26 review, rank 3): pull the bootstrap base set too.
# debootstrap on the TARGET needs Essential + Priority required/important
# packages from our mirror. Our chroot already has them INSTALLED from the
# initial debootstrap, so apt-get -d install would skip them. Force re-
# download via --reinstall on every installed package — this populates
# /var/cache/apt/archives with the full base set.
echo "[mirror] forcing re-download of bootstrap base set (--reinstall every installed pkg)..."
INSTALLED_LIST=$(sudo chroot "$CHROOT" dpkg-query -W -f='${Package}\n' 2>/dev/null | tr '\n' ' ')
if [ -n "$INSTALLED_LIST" ]; then
    if ! sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get install -d -y --reinstall $INSTALLED_LIST 2>&1 | tail -20; then
        echo "[mirror] ERROR: --reinstall base-set pull failed; refusing incomplete mirror" >&2
        exit 1
    fi
fi
echo "[mirror] base-set re-download complete"

DEB_COUNT=$(find "$CHROOT/var/cache/apt/archives" -name '*.deb' | wc -l)
echo "[mirror] downloaded $DEB_COUNT .debs"
echo "[mirror] total size: $(du -sh "$CHROOT/var/cache/apt/archives" | cut -f1)"

# ----------------------------------------------------------------------
# Assemble mirror tree — pool/<component>/<letter>/<pkg>/<file.deb>
# ----------------------------------------------------------------------
echo ""
echo "[mirror] assembling /pool tree at $MIRROR_DIR"
sudo rm -rf "$MIRROR_DIR"
mkdir -p "$MIRROR_DIR/pool/main" "$MIRROR_DIR/pool/universe" \
         "$MIRROR_DIR/pool/multiverse" "$MIRROR_DIR/pool/restricted" \
         "$MIRROR_DIR/dists/$SUITE/main/binary-$ARCH"

# Copy all .debs to pool/main first; we'll re-classify by component using
# apt-cache later if we want.
for deb in "$CHROOT/var/cache/apt/archives"/*.deb; do
    [ -f "$deb" ] || continue
    base=$(basename "$deb")
    # Use first letter (or 'lib' prefix) for pool subdir per Debian convention
    pkg_name=$(dpkg-deb -f "$deb" Package)
    if [ -z "$pkg_name" ]; then continue; fi
    if [[ "$pkg_name" == lib* ]]; then
        letter="${pkg_name:0:4}"
    else
        letter="${pkg_name:0:1}"
    fi
    dest="$MIRROR_DIR/pool/main/$letter/$pkg_name"
    mkdir -p "$dest"
    cp "$deb" "$dest/"
done

POOL_COUNT=$(find "$MIRROR_DIR/pool" -name '*.deb' | wc -l)
echo "[mirror] pool/ has $POOL_COUNT debs ($(du -sh "$MIRROR_DIR/pool" | cut -f1))"

# ----------------------------------------------------------------------
# Generate Packages + Packages.gz via apt-ftparchive
# ----------------------------------------------------------------------
echo "[mirror] generating Packages indexes via apt-ftparchive"
cd "$MIRROR_DIR"

apt-ftparchive packages pool/main > "dists/$SUITE/main/binary-$ARCH/Packages"
gzip -9c "dists/$SUITE/main/binary-$ARCH/Packages" > "dists/$SUITE/main/binary-$ARCH/Packages.gz"

write_translation_indexes "$SUITE" main
write_component_release_files "$SUITE" "$ARCH"

# ----------------------------------------------------------------------
# Generate Release file for the suite
# ----------------------------------------------------------------------
echo "[mirror] generating Release file"
write_suite_release "$SUITE" "$ARCH" "main" "nclawzero cixmini offline mirror — $SUITE $ARCH"

echo "[mirror] Release file:"
head -20 "dists/$SUITE/Release" | sed 's/^/    /'

echo ""
echo "[mirror] mirror tree complete:"
echo "    $MIRROR_DIR/"
du -sh "$MIRROR_DIR/"
