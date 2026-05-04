#!/bin/bash
# build-iso-di.sh — bookworm d-i base + our Sky1 kernel + Ubuntu via late_command
#
# This rebuilds the r6 (Debian d-i) flow that's PROVEN to boot on Sky1
# UEFI on MS-R1, with two extensions:
#   1. Latest post-install hooks (incl. mali_csffw.bin symlink fix)
#   2. late_command swaps /etc/apt/sources.list from Debian to Ubuntu
#      after Debian 12 base lands, then apt full-upgrade to Ubuntu noble.
#      End-state is an Ubuntu system on disk with our Sky1 LTS kernel.
#
# Why d-i not casper: r17-r24 proved Ubuntu casper kernel-panics on Sky1
# USB boot regardless of bootloader (rEFInd, GRUB, systemd-boot). r6
# proved bookworm d-i busybox initrd works. The bootloader doesn't matter;
# the initrd init script does. d-i's busybox init is simple enough to
# avoid whatever casper trips on.

set -euo pipefail

BOOKWORM_ISO=""
ROOT=""
VERSION=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --bookworm-iso) BOOKWORM_ISO="$2"; shift 2 ;;
        --root)         ROOT="$2"; shift 2 ;;
        --version)      VERSION="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -f "$BOOKWORM_ISO" ] || { echo "ERROR: --bookworm-iso not a file"; exit 1; }
[ -d "$ROOT" ]         || { echo "ERROR: --root not a dir"; exit 1; }
[ -n "$VERSION" ]      || { echo "ERROR: --version required"; exit 1; }
[ -n "$OUTPUT" ]       || { echo "ERROR: --output required"; exit 1; }

STAGING="$ROOT/build/iso-staging-di"
EXTRA="$STAGING/cixmini"

for t in xorriso 7z cpio gzip find depmod dd ar; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t"; exit 1; }
done

BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_HOST=$(hostname -s 2>/dev/null || echo unknown)

# r27-compat-fix:
# Ubuntu questing .debs use control.tar.zst/data.tar.zst. Bookworm d-i's
# bootstrap extractor recognizes the member but shells out to zstdcat, which
# the busybox initrd does not ship. Build or reuse a static arm64 zstd and add
# it to the initrd as a separate concatenated cpio member.
prepare_static_zstd_aarch64() {
    local version="${ZSTD_VERSION:-1.5.7}"
    local cache="$ROOT/build/tool-cache/zstd-$version-aarch64-static"
    local bin="${ZSTD_STATIC_AARCH64:-$cache/zstd}"
    local src="$cache/src/zstd-$version"
    local tarball="$cache/zstd-$version.tar.gz"
    local jobs

    if [ -n "${ZSTD_STATIC_AARCH64:-}" ]; then
        [ -x "$ZSTD_STATIC_AARCH64" ] || {
            echo "ERROR: ZSTD_STATIC_AARCH64 is set but not executable: $ZSTD_STATIC_AARCH64" >&2
            exit 1
        }
        printf '%s\n' "$ZSTD_STATIC_AARCH64"
        return 0
    fi

    if [ -x "$bin" ]; then
        printf '%s\n' "$bin"
        return 0
    fi

    for t in curl tar make aarch64-linux-gnu-gcc aarch64-linux-gnu-ar aarch64-linux-gnu-ranlib; do
        command -v "$t" >/dev/null 2>&1 || {
            echo "ERROR: missing $t; install the arm64 cross toolchain or set ZSTD_STATIC_AARCH64=/path/to/static-arm64-zstd" >&2
            exit 1
        }
    done

    mkdir -p "$cache/src"
    if [ ! -f "$tarball" ]; then
        curl -fL \
            "https://github.com/facebook/zstd/releases/download/v$version/zstd-$version.tar.gz" \
            -o "$tarball.tmp"
        mv "$tarball.tmp" "$tarball"
    fi

    rm -rf "$src"
    tar xzf "$tarball" -C "$cache/src"
    jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
    make -C "$src" -j"$jobs" \
        CC=aarch64-linux-gnu-gcc \
        AR=aarch64-linux-gnu-ar \
        RANLIB=aarch64-linux-gnu-ranlib \
        HAVE_THREAD=0 HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 \
        ZSTD_LEGACY_SUPPORT=0 \
        CFLAGS="-Os" LDFLAGS="-static" \
        zstd >&2
    install -m 0755 "$src/programs/zstd" "$bin"
    if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
        aarch64-linux-gnu-strip --strip-all "$bin" || true
    fi
    if command -v file >/dev/null 2>&1; then
        file "$bin" | grep -Eq 'ARM aarch64|ARM64' || {
            echo "ERROR: built zstd is not an aarch64 ELF: $(file "$bin")" >&2
            exit 1
        }
        file "$bin" | grep -qi 'statically linked' || {
            echo "ERROR: built zstd is not static: $(file "$bin")" >&2
            exit 1
        }
    fi
    printf '%s\n' "$bin"
}

# r27-compat-fix:
# Fail fast on package member formats that this bookworm d-i flow does not
# handle. zstd is allowed because we append zstdcat below; lzma is deliberately
# rejected because this initrd has no lzmacat symlink and questing should not
# need it. If it appears, use REPACK_DEBS_TO_XZ=1 in build-mirror.sh.
check_deb_member_formats_for_di() {
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

    echo "    deb member format summary:"
    awk '{ print $2 "\t" $3 }' "$report" | sort | uniq -c | sed 's/^/      /'

    bad=$(awk '
        $2 !~ /^control\.tar(\.gz|\.xz|\.zst)?$/ { print }
        $3 !~ /^data\.tar(\.gz|\.xz|\.bz2|\.zst)?$/ { print }
        $2 ~ /\.lzma$/ || $3 ~ /\.lzma$/ { print }
    ' "$report" | sort -u)
    if [ -n "$bad" ]; then
        echo "ERROR: unsupported .deb member formats for bookworm d-i:"
        printf '%s\n' "$bad" | sed 's/^/    /'
        echo "       Rebuild the mirror with REPACK_DEBS_TO_XZ=1 or inject the missing decompressor."
        exit 1
    fi
}

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

    echo "    wrote $count per-component Release files"
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
# Kernel discovery — match build-iso.sh asset paths:
#   $ROOT/assets/kernel/lts/Image-cixmini.bin
#   $ROOT/assets/kernel/lts/modules-cixmini.tgz
#   $ROOT/assets/kernel/lts/KVER
# ----------------------------------------------------------------------
LTS_KERN="$ROOT/assets/kernel/lts/Image-cixmini.bin"
LTS_TGZ="$ROOT/assets/kernel/lts/modules-cixmini.tgz"
LTS_KVER_FILE="$ROOT/assets/kernel/lts/KVER"
for f in "$LTS_KERN" "$LTS_TGZ" "$LTS_KVER_FILE"; do
    [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

KVER_LTS=$(cat "$LTS_KVER_FILE")
[ -n "$KVER_LTS" ] || { echo "ERROR: empty KVER file"; exit 1; }
echo "[info] LTS kernel KVER: $KVER_LTS"

# ----------------------------------------------------------------------
# Step 1 — extract bookworm netinst
# ----------------------------------------------------------------------
echo "[1] preparing staging at $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$EXTRA"

7z x -y -o"$STAGING" "$BOOKWORM_ISO" >/dev/null
echo "    bookworm extracted: $(du -sh "$STAGING" | cut -f1)"

# Match Debian DVD structure EXACTLY: ONE suite (questing) with TWO
# indexes (regular debs + debian-installer udebs) under main/. No
# leftover dists/bookworm/ to confuse anna. Bookworm's udebs are merged
# INTO the questing pool, and bookworm's debian-installer Packages.gz
# is moved INTO dists/questing/main/debian-installer/.
#
# Step 1: capture bookworm's udebs and udeb index BEFORE we nuke bookworm
echo "    capturing bookworm udebs + udeb index (will merge into questing)"
TMP_UDEBS="$STAGING/.tmp-bookworm-udebs"
rm -rf "$TMP_UDEBS"
mkdir -p "$TMP_UDEBS/pool" "$TMP_UDEBS/dists-installer"
# Copy all .udeb files (preserve pool/main/<letter>/<pkg>/<file>.udeb structure)
if [ -d "$STAGING/pool" ]; then
    UDEBCT=$(find "$STAGING/pool" -name '*.udeb' | wc -l)
    (cd "$STAGING" && find pool -name '*.udeb' -print0 | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$TMP_UDEBS"
    echo "    captured $UDEBCT udebs from bookworm pool"
fi
# Copy bookworm's debian-installer index (Packages, Packages.gz, Release)
if [ -d "$STAGING/dists/bookworm/main/debian-installer/binary-arm64" ]; then
    cp -a "$STAGING/dists/bookworm/main/debian-installer/binary-arm64/." "$TMP_UDEBS/dists-installer/"
    echo "    captured bookworm udeb index ($(ls "$TMP_UDEBS/dists-installer/" | tr '\n' ' '))"
fi

# Step 2: drop bookworm pool + dists ENTIRELY (we kept what we needed in TMP)
echo "    dropping bookworm pool/, dists/, doc/, firmware/"
rm -rf "$STAGING/pool" "$STAGING/dists" "$STAGING/doc" "$STAGING/firmware" 2>/dev/null || true

# Step 3: embed our offline questing mirror (regular debs + Release)
MIRROR_DIR="${MIRROR_DIR:-$ROOT/build/questing-mirror}"
if [ -d "$MIRROR_DIR/pool" ] && [ -d "$MIRROR_DIR/dists" ]; then
    echo "    embedding questing mirror from $MIRROR_DIR"
    cp -a "$MIRROR_DIR/pool"  "$STAGING/pool"
    cp -a "$MIRROR_DIR/dists" "$STAGING/dists"
    echo "    questing mirror embedded: $(du -sh "$STAGING/pool" "$STAGING/dists" | head -1 | cut -f1)"
else
    echo "    ERROR: $MIRROR_DIR missing — abort"
    exit 1
fi

# Step 4: merge bookworm udebs into questing pool/main/<letter>/<pkg>/
echo "    merging bookworm udebs into questing pool/"
if [ -d "$TMP_UDEBS/pool" ]; then
    cp -a "$TMP_UDEBS/pool/." "$STAGING/pool/"
    MERGED=$(find "$STAGING/pool" -name '*.udeb' | wc -l)
    echo "    pool/ now has $MERGED udebs alongside the questing debs"
fi

# Step 4.5: GRAFT trixie's debootstrap + zstd udebs onto bookworm pool.
# Per GRAEAE + codex consult: keep bookworm's busybox boot substrate
# (proven to boot Sky1 USB), but replace bookworm's cdebootstrap-static
# (no zstd) with trixie's debootstrap (1.0.141, zstd-aware shell). Plus
# trixie's libzstd1-udeb + liblzma5-udeb so anna installs them at runtime.
# Plus trixie's base-installer 1.226 (bootstrap-base calls debootstrap not
# cdebootstrap). Net effect: bookworm boot path + trixie installer logic +
# zero ABI risk (debootstrap is shell, libs are loaded by anna at runtime).
TRIXIE_ISO_PATH="${TRIXIE_ISO:-$ROOT/downloads/debian-13.4.0-arm64-netinst.iso}"
[ -f "$TRIXIE_ISO_PATH" ] || { echo "ERROR: missing required TRIXIE_ISO=$TRIXIE_ISO_PATH" >&2; exit 1; }

echo "    grafting trixie udebs (debootstrap + libzstd + liblzma + base-installer 1.226)"
TRIXIE_TMP="$STAGING/.tmp-trixie-udebs"
rm -rf "$TRIXIE_TMP"
mkdir -p "$TRIXIE_TMP"
7z x -y -o"$TRIXIE_TMP" "$TRIXIE_ISO_PATH" \
    'pool/main/d/debootstrap/debootstrap-udeb_*_all.udeb' \
    'pool/main/libz/libzstd/libzstd1-udeb_*_arm64.udeb' \
    'pool/main/x/xz-utils/liblzma5-udeb_*_arm64.udeb' \
    'pool/main/b/base-installer/base-installer_*_all.udeb' \
    'pool/main/b/base-installer/bootstrap-base_*_arm64.udeb' \
    >/dev/null

# Codex A1 fix: verify ALL 5 expected udebs were extracted, not silently miss
for need_pkg in debootstrap-udeb libzstd1-udeb liblzma5-udeb base-installer bootstrap-base; do
    find "$TRIXIE_TMP/pool" -name "${need_pkg}_*.udeb" | grep -q . || \
        { echo "ERROR: trixie graft missing $need_pkg" >&2; exit 1; }
done
if true; then

    # Drop bookworm's cdebootstrap-static udebs (debootstrap replaces it)
    find "$STAGING"/pool/main/c/cdebootstrap -name '*.udeb' -delete 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGING"/pool/main/c/cdebootstrap 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGING"/pool/main/c 2>/dev/null || true

    # Drop bookworm's base-installer udebs (trixie's 1.226 replaces them)
    find "$STAGING"/pool/main/b/base-installer -name '*.udeb' -delete 2>/dev/null || true

    # Drop bookworm's debootstrap if any (trixie's replaces it)
    find "$STAGING"/pool/main/d/debootstrap -name '*.udeb' -delete 2>/dev/null || true

    # Drop bookworm's libzstd / liblzma udebs if any (trixie's are newer)
    find "$STAGING"/pool/main/libz/libzstd -name '*.udeb' -delete 2>/dev/null || true
    find "$STAGING"/pool/main/x/xz-utils -name 'liblzma*.udeb' -delete 2>/dev/null || true

    # Copy trixie udebs into pool at canonical paths
    cp -a "$TRIXIE_TMP/pool/." "$STAGING/pool/"

    GRAFTED=$(find "$TRIXIE_TMP/pool" -name '*.udeb' | wc -l)
    echo "    grafted $GRAFTED trixie udebs into pool/"
    rm -rf "$TRIXIE_TMP"
fi

# Step 5: regenerate dists/questing/main/debian-installer/binary-arm64/Packages
# from the actual pool contents (not just copy bookworm's stale Packages).
# After the trixie graft, the d-i Packages index MUST reflect the new udeb set
# or anna can't find the new udebs.
echo "    regenerating udeb Packages index from actual pool contents"
mkdir -p "$STAGING/dists/questing/main/debian-installer/binary-arm64"
(
    cd "$STAGING"
    dpkg-scanpackages --type udeb --multiversion pool/main /dev/null 2>/dev/null \
        > dists/questing/main/debian-installer/binary-arm64/Packages
    gzip -9cn dists/questing/main/debian-installer/binary-arm64/Packages \
        > dists/questing/main/debian-installer/binary-arm64/Packages.gz
    UDEBCT=$(grep -c '^Package: ' dists/questing/main/debian-installer/binary-arm64/Packages || echo 0)
    echo "    udeb Packages: $UDEBCT entries indexed"
)

# Step 6: regenerate dists/questing/Release to include BOTH the regular
# Packages indexes AND the debian-installer Packages indexes. apt-ftparchive
# reads the entire dists/questing/ tree and computes hashes for everything.
echo "    regenerating dists/questing/Release with both regular + udeb indexes"
(
    cd "$STAGING"
    write_translation_indexes questing main
    write_component_release_files questing arm64
    write_suite_release questing arm64 main "nclawzero cixmini offline mirror — questing arm64 (regular + udebs)"
)
echo "    Release file regenerated:"
head -16 "$STAGING/dists/questing/Release" | sed 's/^/      /'

# r27-compat-fix:
# Verify the actual embedded mirror payload formats before we build an ISO.
# This is the authoritative check for "what Questing packages use" in this
# offline image.
check_deb_member_formats_for_di "$STAGING" "$STAGING/.deb-format-report.tsv"

# Cleanup tmp
rm -rf "$TMP_UDEBS"

# Rewrite .disk/ — d-i's cdrom-detect needs these markers to recognize
# the media as a valid install source. Bookworm's .disk/info pointed at
# Debian; ours points at our offline mirror.
echo "    rewriting .disk/ markers for offline mirror"
mkdir -p "$STAGING/.disk" "$STAGING/.disk/id"
printf 'main\n' > "$STAGING/.disk/base_components"
: > "$STAGING/.disk/base_installable"
printf 'dvd\n' > "$STAGING/.disk/cd_type"
printf 'nclawzero cixmini questing - Offline arm64 Binary 1\n' > "$STAGING/.disk/info"
# .disk/udeb_include: tells d-i to use our network-console udeb etc.
echo "    .disk/info:    $(cat "$STAGING/.disk/info")"

# ----------------------------------------------------------------------
# Step 2 — replace install.a64/vmlinuz with our LTS kernel
# ----------------------------------------------------------------------
echo "[2] swapping /install.a64/vmlinuz to linux-cix-sky1 LTS ($KVER_LTS)"
[ -f "$STAGING/install.a64/vmlinuz" ] || { echo "ERROR: bookworm has no /install.a64/vmlinuz"; exit 1; }
cp -L "$LTS_KERN" "$STAGING/install.a64/vmlinuz"
echo "    replaced: $(du -h "$STAGING/install.a64/vmlinuz" | cut -f1)"

# ----------------------------------------------------------------------
# Step 3 — concat our modules cpio onto install.a64/initrd.gz
# ----------------------------------------------------------------------
echo "[3] appending modules cpio to /install.a64/initrd.gz ($KVER_LTS)"

WORK="$STAGING/.lts-overlay"
rm -rf "$WORK"
mkdir -p "$WORK"
tar xzf "$LTS_TGZ" -C "$WORK"
[ -d "$WORK/lib/modules/$KVER_LTS" ] || \
    { echo "ERROR: tarball didn't extract to lib/modules/$KVER_LTS"; exit 1; }

depmod -a -b "$WORK" "$KVER_LTS"
[ -f "$WORK/lib/modules/$KVER_LTS/modules.dep" ] || \
    { echo "ERROR: depmod failed"; exit 1; }

OVERLAY_GZ="$STAGING/.lts-overlay.cpio.gz"
( cd "$WORK" && find lib -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$OVERLAY_GZ"
gzip -t "$OVERLAY_GZ"
echo "    overlay cpio: $(du -h "$OVERLAY_GZ" | cut -f1)"
rm -rf "$WORK"

# initrd.gz is a gzipped cpio. Linux supports concatenated multiple gzipped
# initramfs members. Append directly — no padding needed for gz members.
cat "$OVERLAY_GZ" >> "$STAGING/install.a64/initrd.gz"
rm -f "$OVERLAY_GZ"
echo "    initrd.gz now: $(du -h "$STAGING/install.a64/initrd.gz" | cut -f1)"

# ----------------------------------------------------------------------
# Step 3.1 — append zstd tools for questing data.tar.zst/control.tar.zst
# ----------------------------------------------------------------------
echo "[3.1] appending zstdcat for questing .deb extraction"

# r27-compat-fix:
# d-i's bootstrap extractor shells out to zstdcat for .tar.zst members.
# Put zstd in both /bin and /usr/bin because different extractor code paths
# use different PATHs across debootstrap/cdebootstrap/dpkg-deb variants.
ZSTD_STATIC_BIN=$(prepare_static_zstd_aarch64)
TOOLS_WORK="$STAGING/.r27-tools-overlay"
rm -rf "$TOOLS_WORK"
mkdir -p "$TOOLS_WORK/bin" "$TOOLS_WORK/usr/bin"
install -m 0755 "$ZSTD_STATIC_BIN" "$TOOLS_WORK/bin/zstd"
ln -s zstd "$TOOLS_WORK/bin/zstdcat"
ln -s ../../bin/zstd "$TOOLS_WORK/usr/bin/zstd"
ln -s ../../bin/zstd "$TOOLS_WORK/usr/bin/zstdcat"

TOOLS_GZ="$STAGING/.r27-tools-overlay.cpio.gz"
( cd "$TOOLS_WORK" && find . -mindepth 1 -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$TOOLS_GZ"
gzip -t "$TOOLS_GZ"
cat "$TOOLS_GZ" >> "$STAGING/install.a64/initrd.gz"
rm -rf "$TOOLS_WORK" "$TOOLS_GZ"
echo "    zstd: $ZSTD_STATIC_BIN"
echo "    initrd.gz now: $(du -h "$STAGING/install.a64/initrd.gz" | cut -f1)"

# ----------------------------------------------------------------------
# Step 4 — stage /cixmini/ with preseed.cfg + late.sh + post-install + assets
# ----------------------------------------------------------------------
echo "[4] staging /cixmini extras"
cp "$ROOT/preseed/preseed-ubuntu.cfg" "$EXTRA/preseed.cfg"
cp "$ROOT/preseed/late.sh"            "$EXTRA/late.sh"
chmod 0755 "$EXTRA/late.sh"

cp -a "$ROOT/post-install" "$EXTRA/post-install"

if [ -d "$ROOT/assets" ]; then
    mkdir -p "$EXTRA/assets"
    # copy everything except the kernel + sky1-firmware tree (we ship those
    # separately via specific paths)
    for d in "$ROOT/assets"/*; do
        bn=$(basename "$d")
        case "$bn" in
            kernel) ;;  # skip raw kernel images; we embed via vmlinuz
            *) cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true ;;
        esac
    done
fi

# Sky1 firmware assets: drop into /cixmini/assets/sky1-firmware/ exactly
# where 12-sky1-firmware.sh expects to find it after late.sh stages it.
if [ -d "$ROOT/assets/sky1-firmware" ]; then
    cp -rL "$ROOT/assets/sky1-firmware" "$EXTRA/assets/" 2>/dev/null || true
    echo "    sky1-firmware: $(du -sh "$EXTRA/assets/sky1-firmware" | cut -f1)"
fi

echo "$VERSION"     > "$EXTRA/BUILD_VERSION"
echo "$BUILD_DATE"  > "$EXTRA/BUILD_DATE"
echo "$BUILD_HOST"  > "$EXTRA/BUILD_HOST"
echo "$KVER_LTS"    > "$EXTRA/KVER_LTS"
echo "${BUILD_CODENAME:-Reinhardt}" > "$EXTRA/BUILD_CODENAME"

echo "    build id: $VERSION  ($BUILD_DATE on $BUILD_HOST)"
echo "    codename: ${BUILD_CODENAME:-Reinhardt}"

# ----------------------------------------------------------------------
# Step 5 — write /boot/grub/grub.cfg with r6-style menu
# ----------------------------------------------------------------------
echo "[5] writing /boot/grub/grub.cfg (r6-style preseed cmdline)"
GRUB_CFG="$STAGING/boot/grub/grub.cfg"
mkdir -p "$STAGING/boot/grub"

# Working r6 cmdline (extracted from running cixmini install /proc/cmdline).
# Plus auto/priority/preseed/file for unattended d-i operation.
MARTJOHNSON_R6="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"
DI_OPTS="auto=true priority=high preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=120"

CODENAME="${BUILD_CODENAME:-Reinhardt}"
cat > "$GRUB_CFG" <<GRUB
# ncz-installer (cixmini "$CODENAME" / $VERSION)
# bookworm d-i busybox boot substrate + trixie udeb graft + Sky1 LTS kernel
# + offline Ubuntu questing mirror
# Build: $VERSION  ($BUILD_DATE)  Host: $BUILD_HOST
# Kernel: LTS=$KVER_LTS
set timeout=10
set default=0
# Green-on-black VT100 phosphor terminal aesthetic
set menu_color_normal=light-green/black
set menu_color_highlight=black/light-green
set color_normal=light-green/black
set color_highlight=black/light-green
insmod gzio
clear

echo ""
echo "             ___    ___    ___"
echo "            |    \\\\ |    | |    |"
echo "            | n  c | i  x | n  c |              ncz-installer"
echo "            |  l   |  m   |  l   |              \"$CODENAME\""
echo "            |    /  |____| |    /                $VERSION"
echo "             ===                  ==="
echo ""
echo "                   .-=-=-=-=-=-=-=-=-."
echo "                  /  V . I . N . CENT \\\\"
echo "                 |   .--.       .--.  |          (Vital Information"
echo "                 |  ( ●● )    ( ●● )  |           Necessary"
echo "                 |   '--'       '--'  |           CENTralized)"
echo "                  \\\\__________________/"
echo "                   |  ____________  |"
echo "                   | | NCLAWZERO | |"
echo "                   | |  CIXMINI  | |             cixmini @ Sky1 / CP8180"
echo "                   |_|___________|_|             ARM64 / questing 25.10"
echo "                  /__|  -----  |__\\\\"
echo "                  | / |________| \\\\ |             kernel: $KVER_LTS"
echo "                   --             --              build:  $BUILD_DATE"
echo ""
echo "    bookworm busybox boot + trixie udeb graft + offline questing mirror"
echo ""

menuentry "Install ncz-installer \"$CODENAME\" (LTS 6.18.26 + Ubuntu questing)" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> ncz-installer loading Sky1 LTS kernel + d-i..."
    linux  /install.a64/vmlinuz $DI_OPTS $MARTJOHNSON_R6
    echo ">> Loading initrd (modules + preseed + zstd)..."
    initrd /install.a64/initrd.gz
}

menuentry "SAFE — rescue shell (LTS, no install)" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> Loading rescue mode (LTS $KVER_LTS)..."
    linux  /install.a64/vmlinuz rescue/enable=true $MARTJOHNSON_R6
    initrd /install.a64/initrd.gz
}
GRUB
echo "    grub.cfg written ($(wc -l < "$GRUB_CFG") lines)"

# ----------------------------------------------------------------------
# Step 6 — regenerate md5sum.txt
# ----------------------------------------------------------------------
echo "[6] regenerating md5sum.txt"
( cd "$STAGING" && find . -type f \! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt 2>/dev/null || true )

# ----------------------------------------------------------------------
# Step 7 — repack as UEFI-bootable hybrid ISO via xorriso
# ----------------------------------------------------------------------
echo "[7] repacking via xorriso → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

EFI_IMG_REL="boot/grub/efi.img"
[ -f "$STAGING/$EFI_IMG_REL" ] || { echo "ERROR: bookworm efi.img missing"; exit 1; }

# xorriso flags matched to bookworm's mkisofs invocation (extracted from
# bookworm netinst's .disk/mkisofs). Codex r26 review flagged that
# -isohybrid-gpt-basdat is weaker than -append_partition + -partition_cyl_align
# on arm64 EFI USB. Switching to bookworm's exact flag combination so the
# hybrid GPT/MBR layout produces a proper EFI System Partition (type 0xef)
# at GPT slot 2, which Sky1 UEFI is known to recognize (r6 worked).
xorriso -as mkisofs \
    -r -V "NCLAWZERO_CIXMINI" \
    -J -joliet-long \
    -cache-inodes \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -append_partition 2 0xef "$STAGING/$EFI_IMG_REL" \
    -appended_part_as_gpt \
    -partition_cyl_align all \
    -o "$OUTPUT" \
    "$STAGING"

echo ""
echo "OUTPUT: $OUTPUT"
ls -lh "$OUTPUT"
