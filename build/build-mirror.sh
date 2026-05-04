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
for t in apt-ftparchive ar dpkg-deb find gzip; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t"; exit 1; }
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

# r27-compat-fix:
# Scan the actual .deb ar members in the generated mirror. Packages metadata
# does not record whether payloads are data.tar.zst/data.tar.xz/etc.; the ar
# member list is the source of truth for bookworm d-i compatibility.
scan_deb_package_formats() {
    local root="$1"
    local report="$2"
    local deb members control data bad

    : > "$report"
    while IFS= read -r -d '' deb; do
        members=$(ar t "$deb" 2>/dev/null || true)
        control=$(printf '%s\n' "$members" | awk '/^control\.tar(\.|$)/ { print; exit }')
        data=$(printf '%s\n' "$members" | awk '/^data\.tar(\.|$)/ { print; exit }')
        printf '%s\t%s\t%s\n' "${deb#$root/}" "${control:-MISSING}" "${data:-MISSING}" >> "$report"
    done < <(find "$root" -name '*.deb' -print0)

    echo "[mirror] .deb member format summary:"
    awk '{ print $2 "\t" $3 }' "$report" | sort | uniq -c | sed 's/^/[mirror]   /'

    bad=$(awk '
        $2 !~ /^control\.tar(\.gz|\.xz|\.zst)?$/ { print }
        $3 !~ /^data\.tar(\.gz|\.xz|\.bz2|\.lzma|\.zst)?$/ { print }
    ' "$report" | sort -u)
    if [ -n "$bad" ]; then
        echo "[mirror] ERROR: unknown .deb member format(s):"
        printf '%s\n' "$bad" | sed 's/^/[mirror]   /'
        exit 1
    fi
}

# r27-compat-fix:
# Heavy fallback: rewrite zstd/lzma package members to xz so old installer
# environments do not need new decompressors. This is intentionally opt-in;
# the default fix is the much smaller initrd zstdcat injection in
# build-iso-di.sh.
repack_debs_to_xz() {
    local root="$1"
    local deb tmp members control data new_control new_data count=0

    command -v ar >/dev/null 2>&1 || { echo "[mirror] ERROR: missing ar"; exit 1; }
    command -v zstd >/dev/null 2>&1 || { echo "[mirror] ERROR: missing zstd for REPACK_DEBS_TO_XZ=1"; exit 1; }
    command -v xz >/dev/null 2>&1 || { echo "[mirror] ERROR: missing xz for REPACK_DEBS_TO_XZ=1"; exit 1; }

    while IFS= read -r -d '' deb; do
        members=$(ar t "$deb" 2>/dev/null || true)
        printf '%s\n' "$members" | grep -Eq '^(control|data)\.tar\.(zst|lzma)$' || continue

        tmp=$(mktemp -d "${TMPDIR:-/tmp}/deb-repack.XXXXXX")
        ( cd "$tmp" && ar x "$deb" )

        for member in control.tar.zst data.tar.zst; do
            if [ -f "$tmp/$member" ]; then
                zstd -dc "$tmp/$member" | xz -T0 -6e > "$tmp/${member%.zst}.xz"
                rm -f "$tmp/$member"
            fi
        done
        if [ -f "$tmp/data.tar.lzma" ]; then
            xz -dc "$tmp/data.tar.lzma" | xz -T0 -6e > "$tmp/data.tar.xz"
            rm -f "$tmp/data.tar.lzma"
        fi

        control=$(find "$tmp" -maxdepth 1 -name 'control.tar*' -print -quit)
        data=$(find "$tmp" -maxdepth 1 -name 'data.tar*' -print -quit)
        [ -n "$control" ] && [ -n "$data" ] || {
            echo "[mirror] ERROR: failed to repack $deb; missing control/data member"
            rm -rf "$tmp"
            exit 1
        }
        new_control=$(basename "$control")
        new_data=$(basename "$data")
        ( cd "$tmp" && ar rc "$deb.new" debian-binary "$new_control" "$new_data" )
        mv "$deb.new" "$deb"
        rm -rf "$tmp"
        count=$((count + 1))
    done < <(find "$root" -name '*.deb' -print0)

    echo "[mirror] repacked $count .deb(s) to xz members"
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
  # r27-compat-fix: Ubuntu uses ubuntu-keyring; there is no questing-specific archive-keyring package.
  sudo apt-utils ca-certificates gnupg lsb-release ubuntu-keyring
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

# Per-package fallback: if any single package is unavailable, don't let it
# kill the whole download. apt-get install -d aborts on first error, so
# loop one-by-one if the bulk install fails.
if ! sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -d -y "${PKGS[@]}" 2>&1 | tail -20; then
    echo "[mirror] bulk install failed — falling back to per-package downloads"
    for pkg in "${PKGS[@]}"; do
        sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
            apt-get install -d -y "$pkg" 2>&1 | tail -2 || \
            echo "[mirror]   skip: $pkg"
    done
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
    sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get install -d -y --reinstall $INSTALLED_LIST 2>&1 | tail -5 || \
        echo "[mirror] WARNING: --reinstall pull had errors (some pkgs may be unavailable)"
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

# r27-compat-fix:
# Record the actual package member compression used by this offline mirror.
# Leave zstd in place by default; build-iso-di.sh injects zstdcat into d-i.
# Set REPACK_DEBS_TO_XZ=1 only if you want the heavy no-initrd-surgery path.
scan_deb_package_formats "$MIRROR_DIR/pool" "$MIRROR_DIR/deb-format-scan.before.tsv"
if [ "${REPACK_DEBS_TO_XZ:-0}" = "1" ]; then
    echo "[mirror] REPACK_DEBS_TO_XZ=1 — rewriting zstd/lzma package members to xz"
    repack_debs_to_xz "$MIRROR_DIR/pool"
    scan_deb_package_formats "$MIRROR_DIR/pool" "$MIRROR_DIR/deb-format-scan.after.tsv"
fi

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
