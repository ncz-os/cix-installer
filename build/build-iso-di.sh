#!/bin/bash
# build-iso-di.sh — bookworm d-i base + our Sky1 kernel + Ubuntu via late_command
#
# This rebuilds the r6 (Debian d-i) flow that's PROVEN to boot on Sky1
# UEFI on MS-R1, with two extensions:
#   1. Latest post-install hooks (incl. mali_csffw.bin symlink fix)
#   2. late_command swaps /etc/apt/sources.list from Debian to Ubuntu
#      after Debian 12 base lands, then apt full-upgrade to Ubuntu resolute.
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
VARIANT="desktop"   # r75 M1: 'desktop' (Reinhardt SKU) | 'server' (Magnetar SKU)
MODE="full"         # r78: full | thin | netinstall | netinstall-bootstrap

usage() {
    cat <<'EOF'
Usage: build/build-iso-di.sh --bookworm-iso PATH --root PATH --version VERSION --output PATH [options]

Options:
  --mode {full|thin|netinstall|netinstall-bootstrap}
      full       default; bundled rootfs.tar.zst + embedded resolute mirror
      thin       embedded resolute mirror, real debootstrap, no rootfs.tar.zst
      netinstall canonical ports.ubuntu.com debootstrap, NEXT kernel only, <500 MB
      netinstall-bootstrap
                 netinstall + local pkgsel bootstrap pool, still <1 GB
  --variant {desktop|server}
      Bake-time default variant; GRUB chooser can override via ncz_variant=
  --bookworm-iso PATH
  --root PATH
  --version VERSION
  --output PATH
  -h, --help
EOF
}

if [ "$#" -eq 0 ]; then
    usage
    exit 0
fi

need_arg() {
    local opt="$1"
    local argc="$2"
    if [ "$argc" -lt 2 ]; then
        echo "ERROR: $opt requires an argument" >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bookworm-iso) need_arg "$1" "$#"; BOOKWORM_ISO="$2"; shift 2 ;;
        --root)         need_arg "$1" "$#"; ROOT="$2"; shift 2 ;;
        --version)      need_arg "$1" "$#"; VERSION="$2"; shift 2 ;;
        --output)       need_arg "$1" "$#"; OUTPUT="$2"; shift 2 ;;
        --variant)      need_arg "$1" "$#"; VARIANT="$2"; shift 2 ;;
        --mode)         need_arg "$1" "$#"; MODE="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Validate MODE before staging
case "$MODE" in
    full|thin|netinstall|netinstall-bootstrap) ;;
    *) echo "ERROR: --mode must be 'full', 'thin', 'netinstall', or 'netinstall-bootstrap' (got '$MODE')" >&2; exit 1 ;;
esac

# Validate VARIANT before staging
case "$VARIANT" in
    desktop|server) ;;
    *) echo "ERROR: --variant must be 'desktop' or 'server' (got '$VARIANT')" >&2; exit 1 ;;
esac

EMBED_MIRROR=1
STAGE_ROOTFS=1
PATCH_DEBOOTSTRAP_STUB=1
STAGE_LTS_KERNEL=1
STAGE_NEXT_KERNEL=1
INSTALLER_KERNEL_FLAVOR=next
BOOTSTRAP_POOL=0
# 2026-05-08: ceiling set to 1GB so the netinstall ISO stays in the
# easy-GitHub-release-distribution band (GitHub allows up to 2GB per
# release asset but practical distribution wants <1GB). Current ISO
# lands at ~588MB across take15-20 with our 7.0.3 NEXT kernel +
# initramfs + firmware + branding. 1GB gives ~440MB headroom for
# additional bundled artifacts before we'd need to split or move to
# Git LFS / external mirror.
NETINSTALL_MAX_BYTES=$((1024 * 1024 * 1024))

case "$MODE" in
    full)
        ;;
    thin)
        STAGE_ROOTFS=0
        PATCH_DEBOOTSTRAP_STUB=0
        ;;
    netinstall)
        EMBED_MIRROR=0
        STAGE_ROOTFS=0
        PATCH_DEBOOTSTRAP_STUB=0
        STAGE_LTS_KERNEL=0
        INSTALLER_KERNEL_FLAVOR=next
        ;;
    netinstall-bootstrap)
        EMBED_MIRROR=0
        STAGE_ROOTFS=0
        PATCH_DEBOOTSTRAP_STUB=0
        STAGE_LTS_KERNEL=0
        INSTALLER_KERNEL_FLAVOR=next
        BOOTSTRAP_POOL=1
        ;;
esac

[ -f "$BOOKWORM_ISO" ] || { echo "ERROR: --bookworm-iso not a file"; exit 1; }
[ -d "$ROOT" ]         || { echo "ERROR: --root not a dir"; exit 1; }
# Absolutize ROOT: derived paths (STAGING, DEBOOTSTRAP_PATCH_TMP) are used as
# `ar`/output targets inside `cd`'d subshells, where a relative --root resolves
# against the wrong cwd and fails (e.g. debootstrap-udeb repack: ar rc).
ROOT="$(cd "$ROOT" && pwd)"
[ -n "$VERSION" ]      || { echo "ERROR: --version required"; exit 1; }
[ -n "$OUTPUT" ]       || { echo "ERROR: --output required"; exit 1; }

# Drift guard: surface kernel/NPU manifest drift (e.g. NPU vermagic != KVER)
# before building the ISO. Non-fatal by default; STRICT_MANIFEST=1 makes it abort.
if [ -f "$ROOT/build/kernel-manifest.py" ]; then
    if ! python3 "$ROOT/build/kernel-manifest.py" check; then
        if [ "${STRICT_MANIFEST:-0}" = 1 ]; then
            echo "ERROR: kernel manifest drift (STRICT_MANIFEST=1) — aborting" >&2
            exit 1
        fi
        echo "WARN: kernel manifest drift detected (continuing; set STRICT_MANIFEST=1 to enforce)" >&2
    fi
fi

STAGING="$ROOT/build/iso-staging-di"
EXTRA="$STAGING/cixmini"

for t in xorriso 7z cpio gzip gunzip find depmod dd ar tar stat apt-ftparchive \
         dpkg-scanpackages python3 awk sed sort uniq grep head du wc md5sum \
         xargs readlink install bash; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t"; exit 1; }
done

file_size_bytes() {
    local path="$1"
    local size=""

    if size=$(stat -c %s "$path" 2>/dev/null); then
        case "$size" in
            ''|*[!0-9]*)
                echo "ERROR: malformed GNU stat size for $path: '$size'" >&2
                return 1
                ;;
            *)
                printf '%s\n' "$size"
                return 0
                ;;
        esac
    fi

    if size=$(stat -f %z "$path" 2>/dev/null); then
        case "$size" in
            ''|*[!0-9]*)
                echo "ERROR: malformed BSD stat size for $path: '$size'" >&2
                return 1
                ;;
            *)
                printf '%s\n' "$size"
                return 0
                ;;
        esac
    fi

    if size=$(wc -c < "$path" 2>/dev/null); then
        size="${size//[[:space:]]/}"
        case "$size" in
            ''|*[!0-9]*)
                echo "ERROR: malformed wc size for $path: '$size'" >&2
                return 1
                ;;
            *)
                printf '%s\n' "$size"
                return 0
                ;;
        esac
    fi

    echo "ERROR: could not determine file size for $path" >&2
    return 1
}

BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_HOST=$(hostname -s 2>/dev/null || echo unknown)

# r27-compat-fix:
# Ubuntu resolute .debs use control.tar.zst/data.tar.zst. Bookworm d-i's
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
# rejected because this initrd has no lzmacat symlink and resolute should not
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
Label: nclawzero-cixmini-resolute
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
#   $ROOT/assets/kernel/stable/Image-cixmini.bin
#   $ROOT/assets/kernel/stable/modules-cixmini.tgz
#   $ROOT/assets/kernel/stable/KVER
# ----------------------------------------------------------------------
LTS_KERN="$ROOT/assets/kernel/stable/Image-cixmini.bin"
LTS_TGZ="$ROOT/assets/kernel/stable/modules-cixmini.tgz"
LTS_KVER_FILE="$ROOT/assets/kernel/stable/KVER"
NEXT_KERN="$ROOT/assets/kernel/edge/Image-cixmini.bin"
NEXT_TGZ="$ROOT/assets/kernel/edge/modules-cixmini.tgz"
NEXT_KVER_FILE="$ROOT/assets/kernel/edge/KVER"

KVER_LTS=""
KVER_NEXT=""

if [ "$STAGE_LTS_KERNEL" = "1" ] || [ "$INSTALLER_KERNEL_FLAVOR" = "lts" ]; then
    for f in "$LTS_KERN" "$LTS_TGZ" "$LTS_KVER_FILE"; do
        [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
    done
    KVER_LTS=$(cat "$LTS_KVER_FILE")
    [ -n "$KVER_LTS" ] || { echo "ERROR: empty KVER file: $LTS_KVER_FILE"; exit 1; }
    echo "[info] LTS kernel KVER: $KVER_LTS"
fi

if [ -f "$NEXT_KVER_FILE" ] && [ -f "$NEXT_KERN" ] && [ -f "$NEXT_TGZ" ]; then
    KVER_NEXT=$(cat "$NEXT_KVER_FILE")
    [ -n "$KVER_NEXT" ] || { echo "ERROR: empty KVER file: $NEXT_KVER_FILE"; exit 1; }
    echo "[info] NEXT kernel KVER: $KVER_NEXT"
elif [ "$INSTALLER_KERNEL_FLAVOR" = "next" ] || [ "$MODE" = "netinstall" ]; then
    echo "ERROR: --mode netinstall requires assets/kernel/edge/{KVER,Image-cixmini.bin,modules-cixmini.tgz}" >&2
    exit 1
fi

case "$INSTALLER_KERNEL_FLAVOR" in
    lts)
        INSTALLER_KERN="$LTS_KERN"
        INSTALLER_TGZ="$LTS_TGZ"
        KVER_INSTALLER="$KVER_LTS"
        INSTALLER_KERNEL_LABEL="LTS"
        ;;
    next)
        INSTALLER_KERN="$NEXT_KERN"
        INSTALLER_TGZ="$NEXT_TGZ"
        KVER_INSTALLER="$KVER_NEXT"
        INSTALLER_KERNEL_LABEL="NEXT"
        ;;
    *)
        echo "ERROR: internal unknown installer kernel flavor: $INSTALLER_KERNEL_FLAVOR" >&2
        exit 1
        ;;
esac

# ----------------------------------------------------------------------
# Step 1 — extract d-i substrate (bookworm or trixie netinst)
# ----------------------------------------------------------------------
echo "[1] preparing staging at $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$EXTRA"

7z x -y -o"$STAGING" "$BOOKWORM_ISO" >/dev/null
echo "    substrate extracted: $(du -sh "$STAGING" | cut -f1)"

# Auto-detect d-i substrate codename from extracted /dists/. Supports
# bookworm (Debian 12) and trixie (Debian 13). Trixie d-i has the DNS
# resilience improvements we want (netcfg/get_nameservers append,
# busybox 1.37 with nohup applet, udhcpc /etc/resolv.conf.head support).
# 2026-05-08 (Codex r78 take13 audit MEDIUM #2): if both bookworm AND trixie
# directories are present, refuse to silently pick one — fragile for
# multi-codename or symlink-heavy media, since `find pool -name '*.udeb'`
# would mix runtime udebs across substrates. Operator can force via
# DI_CODENAME_OVERRIDE=trixie (or bookworm) env var.
DI_CODENAME=""
DI_CODENAMES_FOUND=()
for cn in trixie bookworm; do
    if [ -d "$STAGING/dists/$cn" ]; then
        DI_CODENAMES_FOUND+=("$cn")
    fi
done
if [ -n "${DI_CODENAME_OVERRIDE:-}" ]; then
    if [ -d "$STAGING/dists/$DI_CODENAME_OVERRIDE" ]; then
        DI_CODENAME="$DI_CODENAME_OVERRIDE"
        echo "    d-i substrate codename: $DI_CODENAME (DI_CODENAME_OVERRIDE)"
    else
        echo "ERROR: DI_CODENAME_OVERRIDE=$DI_CODENAME_OVERRIDE but $STAGING/dists/$DI_CODENAME_OVERRIDE not present" >&2
        exit 1
    fi
elif [ "${#DI_CODENAMES_FOUND[@]}" -eq 0 ]; then
    echo "ERROR: could not detect d-i substrate codename from $STAGING/dists/" >&2
    ls "$STAGING/dists/" 2>&1 >&2 || true
    exit 1
elif [ "${#DI_CODENAMES_FOUND[@]}" -gt 1 ]; then
    echo "ERROR: multiple d-i substrate codenames present in $STAGING/dists/: ${DI_CODENAMES_FOUND[*]}" >&2
    echo "       set DI_CODENAME_OVERRIDE=<codename> to choose one explicitly" >&2
    exit 1
else
    DI_CODENAME="${DI_CODENAMES_FOUND[0]}"
    echo "    d-i substrate codename: $DI_CODENAME"
fi

# Match Debian DVD structure EXACTLY: ONE suite (resolute) with TWO
# indexes (regular debs + debian-installer udebs) under main/. No
# leftover dists/<substrate>/ to confuse anna. Substrate's udebs are
# merged INTO the resolute pool, and substrate's debian-installer
# Packages.gz is moved INTO dists/resolute/main/debian-installer/.
#
# Step 1: capture substrate's udebs and udeb index BEFORE we nuke them
echo "    capturing $DI_CODENAME udebs + udeb index (will merge into resolute)"
TMP_UDEBS="$STAGING/.tmp-substrate-udebs"
rm -rf "$TMP_UDEBS"
mkdir -p "$TMP_UDEBS/pool" "$TMP_UDEBS/dists-installer"
# Copy all .udeb files (preserve pool/main/<letter>/<pkg>/<file>.udeb structure)
if [ -d "$STAGING/pool" ]; then
    UDEBCT=$(find "$STAGING/pool" -name '*.udeb' | wc -l)
    (cd "$STAGING" && find pool -name '*.udeb' -print0 | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$TMP_UDEBS"
    echo "    captured $UDEBCT udebs from $DI_CODENAME pool"
fi
# Copy substrate's debian-installer index (Packages, Packages.gz, Release)
if [ -d "$STAGING/dists/$DI_CODENAME/main/debian-installer/binary-arm64" ]; then
    cp -a "$STAGING/dists/$DI_CODENAME/main/debian-installer/binary-arm64/." "$TMP_UDEBS/dists-installer/"
    echo "    captured $DI_CODENAME udeb index ($(ls "$TMP_UDEBS/dists-installer/" | tr '\n' ' '))"
fi

# Step 2: drop substrate pool + dists ENTIRELY (we kept what we needed in TMP)
echo "    dropping $DI_CODENAME pool/, dists/, doc/, firmware/"
rm -rf "$STAGING/pool" "$STAGING/dists" "$STAGING/doc" "$STAGING/firmware" 2>/dev/null || true

# Step 3: embed our offline mirror or bootstrap pool.
# NCZ policy (2026-06): embed the SERVER-only mirror (build/server-mirror,
# Ubuntu-Server closure + boot essentials, ~143MB / 365 debs, single 'main'
# component) so server/Magnetar installs fully offline; desktop/Reinhardt pulls
# its long tail from ports.ubuntu.com online (see post-install/20-desktop.sh).
# Falls back to the legacy full resolute-mirror only if server-mirror is absent.
if [ -z "${MIRROR_DIR:-}" ]; then
    if [ -d "$ROOT/build/server-mirror/pool" ]; then
        MIRROR_DIR="$ROOT/build/server-mirror"
    else
        MIRROR_DIR="$ROOT/build/resolute-mirror"
    fi
fi
if [ "$EMBED_MIRROR" = "1" ]; then
    if [ -d "$MIRROR_DIR/pool" ] && [ -d "$MIRROR_DIR/dists" ]; then
        echo "    embedding offline mirror from $MIRROR_DIR"
        cp -a "$MIRROR_DIR/pool"  "$STAGING/pool"
        cp -a "$MIRROR_DIR/dists" "$STAGING/dists"
        echo "    offline mirror embedded: $(du -sh "$STAGING/pool" | cut -f1) pool / $(find "$STAGING/pool" -name '*.deb' | wc -l) debs"
    else
        echo "    ERROR: $MIRROR_DIR missing — abort"
        exit 1
    fi
else
    mkdir -p "$STAGING/pool" "$STAGING/dists"
    if [ "$BOOTSTRAP_POOL" = "1" ]; then
        BOOTSTRAP_POOL_DIR="${BOOTSTRAP_POOL_DIR:-$ROOT/build/resolute-bootstrap-pool}"
        BOOTSTRAP_POOL_CHROOT="${BOOTSTRAP_POOL_CHROOT:-$ROOT/build/resolute-bootstrap}"
        BOOTSTRAP_POOL_UPSTREAM="${BOOTSTRAP_POOL_UPSTREAM:-http://ports.ubuntu.com/ubuntu-ports}"

        if [ "${REFRESH_BOOTSTRAP_POOL:-0}" = "1" ] || [ ! -d "$BOOTSTRAP_POOL_DIR/pool" ] || [ ! -d "$BOOTSTRAP_POOL_DIR/dists" ]; then
            echo "    building netinstall bootstrap pool at $BOOTSTRAP_POOL_DIR"
            "$ROOT/build/build-bootstrap-pool.sh" \
                "$BOOTSTRAP_POOL_CHROOT" \
                "$BOOTSTRAP_POOL_DIR" \
                resolute \
                arm64 \
                "$BOOTSTRAP_POOL_UPSTREAM"
        fi

        if [ -d "$BOOTSTRAP_POOL_DIR/pool" ] && [ -d "$BOOTSTRAP_POOL_DIR/dists" ]; then
            echo "    embedding netinstall bootstrap pool from $BOOTSTRAP_POOL_DIR"
            cp -a "$BOOTSTRAP_POOL_DIR/pool/." "$STAGING/pool/"
            cp -a "$BOOTSTRAP_POOL_DIR/dists/." "$STAGING/dists/"
            echo "    bootstrap pool embedded: $(du -sh "$STAGING/pool" "$STAGING/dists" | head -1 | cut -f1)"
        else
            echo "    ERROR: $BOOTSTRAP_POOL_DIR missing pool/ or dists/ after bootstrap build" >&2
            exit 1
        fi
    else
        echo "    netinstall mode: skipping embedded resolute mirror"
    fi
fi

# Step 4: merge bookworm udebs into resolute pool/main/<letter>/<pkg>/
echo "    merging bookworm udebs into resolute pool/"
if [ -d "$TMP_UDEBS/pool" ]; then
    cp -a "$TMP_UDEBS/pool/." "$STAGING/pool/"
    MERGED=$(find "$STAGING/pool" -name '*.udeb' | wc -l)
    echo "    pool/ now has $MERGED udebs alongside the resolute debs"
fi

# Step 4.5: GRAFT trixie's debootstrap + zstd shell-side udebs onto bookworm.
# Per 2026-05-04 install failure investigation: trixie bootstrap-base 1.226
# arm64 binaries (run-debootstrap, pkgdetails) are linked against glibc 2.38;
# bookworm d-i runtime ships glibc 2.36 -> dynamic linker fails with
# "version GLIBC_2.38 not found".
#
# Path A fix (no rebuild needed): bookworm bootstrap-base 1.213 ships a
# run-debootstrap binary linked against glibc 2.17/2.34 only AND it exec's
# /usr/sbin/debootstrap (verified via strings dump). So we keep bookworm's
# bootstrap-base + base-installer (which work on the bookworm runtime), and
# graft ONLY the all-arch shell pieces: trixie debootstrap-udeb 1.0.141 (the
# /usr/sbin/debootstrap shell with zstd support) plus trixie libzstd1-udeb +
# liblzma5-udeb (loaded as runtime deps when debootstrap calls zstd).
#
# Net flow at install time: bookworm bootstrap-base.run-debootstrap (libc 2.36
# compatible) -> exec /usr/sbin/debootstrap (trixie shell, zstd-aware) -> reads
# control.tar.zst/data.tar.zst from offline resolute mirror successfully.
#
# 2026-05-08 take13: when the substrate IS trixie, this graft is a no-op —
# trixie's own debootstrap-udeb / libzstd1-udeb / liblzma5-udeb are already
# in the substrate's pool, captured into TMP_UDEBS and re-merged in step 4.
if [ "$DI_CODENAME" = "trixie" ]; then
    echo "    substrate is trixie — skipping bookworm-on-trixie udeb graft"
else
TRIXIE_ISO_PATH="${TRIXIE_ISO:-$ROOT/downloads/debian-13.4.0-arm64-netinst.iso}"
[ -f "$TRIXIE_ISO_PATH" ] || { echo "ERROR: missing required TRIXIE_ISO=$TRIXIE_ISO_PATH" >&2; exit 1; }

echo "    grafting trixie shell-side udebs (debootstrap + libzstd + liblzma)"
TRIXIE_TMP="$STAGING/.tmp-trixie-udebs"
rm -rf "$TRIXIE_TMP"
mkdir -p "$TRIXIE_TMP"
7z x -y -o"$TRIXIE_TMP" "$TRIXIE_ISO_PATH" \
    'pool/main/d/debootstrap/debootstrap-udeb_*_all.udeb' \
    'pool/main/libz/libzstd/libzstd1-udeb_*_arm64.udeb' \
    'pool/main/x/xz-utils/liblzma5-udeb_*_arm64.udeb' \
    >/dev/null

# Codex A1 fix: verify ALL 5 expected udebs were extracted, not silently miss
for need_pkg in debootstrap-udeb libzstd1-udeb liblzma5-udeb; do
    find "$TRIXIE_TMP/pool" -name "${need_pkg}_*.udeb" | grep -q . || \
        { echo "ERROR: trixie graft missing $need_pkg" >&2; exit 1; }
done
if true; then

    # Drop bookworm's cdebootstrap-static udebs (debootstrap replaces it)
    find "$STAGING"/pool/main/c/cdebootstrap -name '*.udeb' -delete 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGING"/pool/main/c/cdebootstrap 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$STAGING"/pool/main/c 2>/dev/null || true

    # KEEP bookworm's base-installer + bootstrap-base udebs (their binaries
    # are glibc-2.36-compatible and run-debootstrap exec's the trixie debootstrap
    # shell we install at /usr/sbin/debootstrap below).

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
fi  # end of "if [ DI_CODENAME != trixie ]" — graft-on-bookworm conditional

# 2026-05-08 (Codex r78 take13 audit MEDIUM #3): assert critical
# debootstrap-shell + zstd runtime udebs present in the merged pool
# regardless of substrate path. Bookworm-graft path already checked
# inline (lines 480-482); the trixie-substrate path skipped these,
# leaving runtime-deps presence undetected until install-time.
for need_pkg in debootstrap-udeb libzstd1-udeb liblzma5-udeb; do
    HITS=$(find "$STAGING/pool" -name "${need_pkg}_*.udeb" 2>/dev/null | wc -l)
    if [ "$HITS" -eq 0 ]; then
        echo "ERROR: substrate=$DI_CODENAME merged pool missing $need_pkg (search: $STAGING/pool/**/${need_pkg}_*.udeb)" >&2
        exit 1
    fi
done
echo "    udeb assertions: debootstrap-udeb + libzstd1-udeb + liblzma5-udeb present"

# r40 full mode: replace /usr/sbin/debootstrap in the staged debootstrap-udeb
# with a stub. thin/netinstall deliberately skip this so bookworm
# bootstrap-base.run-debootstrap executes the real trixie debootstrap shell.
DEBOOTSTRAP_UDEBS=( "$STAGING"/pool/main/d/debootstrap/debootstrap-udeb_*_all.udeb )
if [ ! -e "${DEBOOTSTRAP_UDEBS[0]}" ]; then
    echo "ERROR: staged debootstrap-udeb not found in $STAGING/pool/main/d/debootstrap/" >&2
    exit 1
fi
if [ "${#DEBOOTSTRAP_UDEBS[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one debootstrap-udeb, found ${#DEBOOTSTRAP_UDEBS[@]}" >&2
    printf '       %s\n' "${DEBOOTSTRAP_UDEBS[@]}" >&2
    exit 1
fi

DEBOOTSTRAP_UDEB="${DEBOOTSTRAP_UDEBS[0]}"
DEBOOTSTRAP_PATCH_TMP="$STAGING/.tmp-debootstrap-udeb"
DEBOOTSTRAP_PATCH_AR="$DEBOOTSTRAP_PATCH_TMP/ar"
DEBOOTSTRAP_PATCH_DATA="$DEBOOTSTRAP_PATCH_TMP/data"

if [ "$PATCH_DEBOOTSTRAP_STUB" = "1" ]; then
    echo "    replacing /usr/sbin/debootstrap with r40 stub (rootfs.tar.zst install path)"
rm -rf "$DEBOOTSTRAP_PATCH_TMP"
mkdir -p "$DEBOOTSTRAP_PATCH_AR" "$DEBOOTSTRAP_PATCH_DATA"

DEBOOTSTRAP_UDEB_ABS="$(readlink -f "$DEBOOTSTRAP_UDEB")"
(
    cd "$DEBOOTSTRAP_PATCH_AR"
    ar x "$DEBOOTSTRAP_UDEB_ABS"
)

[ -f "$DEBOOTSTRAP_PATCH_AR/debian-binary" ] || { echo "ERROR: debootstrap-udeb missing debian-binary" >&2; exit 1; }
DEBOOTSTRAP_CONTROL_MEMBERS=( "$DEBOOTSTRAP_PATCH_AR"/control.tar* )
DEBOOTSTRAP_DATA_MEMBERS=( "$DEBOOTSTRAP_PATCH_AR"/data.tar* )
DEBOOTSTRAP_CONTROL_MEMBER="$(basename "${DEBOOTSTRAP_CONTROL_MEMBERS[0]}")"
DEBOOTSTRAP_DATA_MEMBER="$(basename "${DEBOOTSTRAP_DATA_MEMBERS[0]}")"
tar -xf "$DEBOOTSTRAP_PATCH_AR/$DEBOOTSTRAP_DATA_MEMBER" -C "$DEBOOTSTRAP_PATCH_DATA"

# Overwrite /usr/sbin/debootstrap with the r40 stub. Whatever args bookworm
# bootstrap-base.run-debootstrap passes, the stub looks for the first
# absolute-path arg, treats it as $TARGET, and:
#   - if /target/etc/os-release exists (= rootfs.tar.zst already extracted) -> exit 0
#   - otherwise create minimum scaffolding so base-installer's post-extract checks
#     don't completely freak, then exit 0
#
# Either way we return success — base-installer believes bootstrap completed.
mkdir -p "$DEBOOTSTRAP_PATCH_DATA/usr/sbin"
cat > "$DEBOOTSTRAP_PATCH_DATA/usr/sbin/debootstrap" <<'STUB'
#!/bin/sh
# ncz r40 stub debootstrap — extracts rootfs.tar.zst into /target itself
# (no longer relies on partman/late_command, which is NOT a real preseed
# variable — only partman/early_command exists). When bookworm bootstrap-base
# calls /usr/sbin/debootstrap, this stub:
#   1. Finds the target dir from positional args
#   2. If /target already populated (re-run), exits 0
#   3. Else: locates rootfs.tar.zst on cdrom, extracts it via zstd | tar -xpf
#   4. Exits 0 so base-installer believes debootstrap succeeded
#
# After this, /target has the FULL Ubuntu desktop rootfs (from canonical's
# minimal.squashfs + apt upgrade + server packages + remote desktop). Any
# subsequent base-installer step (debconf-copydb, debconf-set-selections,
# mount /target/dev) finds the binaries/dirs it needs.

TARGET=""
for arg; do
    case "$arg" in
        /*) [ -d "$arg" ] && TARGET="$arg" && break ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "W: r40 stub debootstrap: no target dir in args (got: $*)" >&2
    exit 0
fi

# Already populated -> idempotent no-op
if [ -f "$TARGET/etc/os-release" ] && [ -d "$TARGET/usr/bin" ] && \
   [ "$(ls "$TARGET/usr/bin" 2>/dev/null | wc -l)" -gt 100 ]; then
    echo "I: r40 stub debootstrap: $TARGET already populated, skipping" >&2
    exit 0
fi

# Find rootfs.tar.zst on the install media
ROOTFS=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    if [ -f "$d/rootfs.tar.zst" ]; then
        ROOTFS="$d/rootfs.tar.zst"
        break
    fi
done
if [ -z "$ROOTFS" ]; then
    echo "FATAL: r40 stub debootstrap: rootfs.tar.zst not found in any candidate cdrom location" >&2
    exit 1
fi

# Verify zstd exists in d-i runtime (injected via prepare_static_zstd_aarch64)
if ! command -v zstd >/dev/null 2>&1; then
    if [ -x /usr/bin/zstd ]; then
        ZSTD=/usr/bin/zstd
    else
        echo "FATAL: r40 stub debootstrap: zstd binary not found" >&2
        exit 1
    fi
else
    ZSTD=$(command -v zstd)
fi

# Wipe any partial scaffolding from a prior failed attempt
rm -rf "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null || true

echo "I: r40 stub debootstrap: extracting $ROOTFS into $TARGET" >&2
echo "I:   ($(du -h "$ROOTFS" 2>/dev/null | cut -f1) compressed; expanded ~6 GB)" >&2
"$ZSTD" -dc "$ROOTFS" | tar -xpf - -C "$TARGET" || {
    echo "FATAL: r40 stub debootstrap: tar extract failed (exit $?)" >&2
    exit 1
}

# Sanity-check
if [ ! -f "$TARGET/etc/os-release" ] || [ ! -d "$TARGET/usr/bin" ]; then
    echo "FATAL: r40 stub debootstrap: extract did not produce expected layout" >&2
    ls -la "$TARGET" >&2 | head -10
    exit 1
fi

# Cloudimg has no /etc/fstab (cloud-init generates one at first boot).
# d-i base-installer post-extract step expects fstab to exist so it can back
# it up to fstab.orig before writing its own. Create an empty placeholder.
[ -e "$TARGET/etc/fstab" ] || touch "$TARGET/etc/fstab"

# r44: also pre-create /target/etc/fstab.orig — d-i base-installer's
# /usr/lib/base-installer/debootstrap wrapper (the one that calls our stub)
# does an unconditional 'mv $TARGET/etc/fstab.orig $TARGET/etc/fstab' after
# we return. Real debootstrap creates fstab.orig as a side effect; our stub
# doesn't. GRAEAE 8-muse consensus 2026-05-04: pre-create empty .orig.
: > "$TARGET/etc/fstab.orig"

# Same defensive empty-files for any other path d-i might write through:
[ -e "$TARGET/etc/hostname" ] || touch "$TARGET/etc/hostname"
[ -e "$TARGET/etc/resolv.conf" ] || touch "$TARGET/etc/resolv.conf"

echo "I: r43 stub debootstrap: rootfs ready at $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))" >&2
exit 0
STUB
chmod 0755 "$DEBOOTSTRAP_PATCH_DATA/usr/sbin/debootstrap"
bash -n "$DEBOOTSTRAP_PATCH_DATA/usr/sbin/debootstrap"

# Repack data.tar
rm -f "$DEBOOTSTRAP_PATCH_AR/$DEBOOTSTRAP_DATA_MEMBER"
(
    cd "$DEBOOTSTRAP_PATCH_DATA"
    tar --numeric-owner --owner=0 --group=0 -cf - .
) | gzip -9n > "$DEBOOTSTRAP_PATCH_AR/data.tar.gz"

DEBOOTSTRAP_NEW_UDEB="$DEBOOTSTRAP_PATCH_TMP/$(basename "$DEBOOTSTRAP_UDEB")"
(
    cd "$DEBOOTSTRAP_PATCH_AR"
    ar rc "$DEBOOTSTRAP_NEW_UDEB" debian-binary "$DEBOOTSTRAP_CONTROL_MEMBER" data.tar.gz
)
mv "$DEBOOTSTRAP_NEW_UDEB" "$DEBOOTSTRAP_UDEB"
rm -rf "$DEBOOTSTRAP_PATCH_TMP"
else
    echo "    skipping r40 debootstrap stub; real debootstrap will run for --mode $MODE"
fi

echo "    patching debootstrap usrmerge chroot wrappers"
rm -rf "$DEBOOTSTRAP_PATCH_TMP"
mkdir -p "$DEBOOTSTRAP_PATCH_AR" "$DEBOOTSTRAP_PATCH_DATA"

DEBOOTSTRAP_UDEB_ABS="$(readlink -f "$DEBOOTSTRAP_UDEB")"
(
    cd "$DEBOOTSTRAP_PATCH_AR"
    ar x "$DEBOOTSTRAP_UDEB_ABS"
)

[ -f "$DEBOOTSTRAP_PATCH_AR/debian-binary" ] || { echo "ERROR: debootstrap-udeb missing debian-binary" >&2; exit 1; }
DEBOOTSTRAP_CONTROL_MEMBERS=( "$DEBOOTSTRAP_PATCH_AR"/control.tar* )
DEBOOTSTRAP_DATA_MEMBERS=( "$DEBOOTSTRAP_PATCH_AR"/data.tar* )
if [ ! -e "${DEBOOTSTRAP_CONTROL_MEMBERS[0]}" ] || [ "${#DEBOOTSTRAP_CONTROL_MEMBERS[@]}" -ne 1 ]; then
    echo "ERROR: debootstrap-udeb must contain exactly one control.tar member" >&2
    exit 1
fi
if [ ! -e "${DEBOOTSTRAP_DATA_MEMBERS[0]}" ] || [ "${#DEBOOTSTRAP_DATA_MEMBERS[@]}" -ne 1 ]; then
    echo "ERROR: debootstrap-udeb must contain exactly one data.tar member" >&2
    exit 1
fi

DEBOOTSTRAP_CONTROL_MEMBER="$(basename "${DEBOOTSTRAP_CONTROL_MEMBERS[0]}")"
DEBOOTSTRAP_DATA_MEMBER="$(basename "${DEBOOTSTRAP_DATA_MEMBERS[0]}")"
tar -xf "$DEBOOTSTRAP_PATCH_AR/$DEBOOTSTRAP_DATA_MEMBER" -C "$DEBOOTSTRAP_PATCH_DATA"

DEBOOTSTRAP_FUNCTIONS="$DEBOOTSTRAP_PATCH_DATA/usr/share/debootstrap/functions"
[ -f "$DEBOOTSTRAP_FUNCTIONS" ] || { echo "ERROR: debootstrap-udeb missing usr/share/debootstrap/functions" >&2; exit 1; }
if grep -q '^ncz_usrmerge_chroot_fixups ()' "$DEBOOTSTRAP_FUNCTIONS"; then
    echo "ERROR: debootstrap functions already contain ncz_usrmerge_chroot_fixups" >&2
    exit 1
fi

cat > "$DEBOOTSTRAP_PATCH_TMP/ncz_usrmerge_chroot_fixups.sh" <<'EOF'
ncz_usrmerge_chroot_fixups () {
	case "$(uname -m)" in
		aarch64) ;;
		*) return 0 ;;
	esac

	[ -d "$TARGET" ] || return 0

	if [ -L "$TARGET/lib" ]; then
		if [ "$(readlink "$TARGET/lib" 2>/dev/null || true)" != usr/lib ]; then
			rm -f "$TARGET/lib" 2>/dev/null || true
			[ -e "$TARGET/lib" ] || ln -s usr/lib "$TARGET/lib" 2>/dev/null || true
		fi
	elif [ ! -e "$TARGET/lib" ]; then
		ln -s usr/lib "$TARGET/lib" 2>/dev/null || true
	elif [ -d "$TARGET/lib" ]; then
		rmdir "$TARGET/lib" 2>/dev/null && ln -s usr/lib "$TARGET/lib" 2>/dev/null || true
	elif [ ! -d "$TARGET/lib" ]; then
		rm -f "$TARGET/lib" 2>/dev/null || true
		[ -e "$TARGET/lib" ] || ln -s usr/lib "$TARGET/lib" 2>/dev/null || true
	fi

	if [ -e "$TARGET/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" ] &&
	   [ ! -e "$TARGET/lib/ld-linux-aarch64.so.1" ] &&
	   [ ! -L "$TARGET/lib/ld-linux-aarch64.so.1" ]; then
		ln -s aarch64-linux-gnu/ld-linux-aarch64.so.1 "$TARGET/lib/ld-linux-aarch64.so.1" 2>/dev/null || true
	fi
}
EOF

if ! awk -v fixup="$DEBOOTSTRAP_PATCH_TMP/ncz_usrmerge_chroot_fixups.sh" '
    $0 == "in_target_nofail () {" {
        while ((getline line < fixup) > 0) {
            print line
        }
        close(fixup)
        print ""
        print
        print "\tncz_usrmerge_chroot_fixups"
        inserted_fixup = 1
        inserted_nofail = 1
        next
    }
    $0 == "in_target_failmsg () {" {
        print
        in_failmsg = 1
        next
    }
    in_failmsg && $0 == "\tlocal code msg arg" {
        print
        print "\tncz_usrmerge_chroot_fixups"
        inserted_failmsg = 1
        in_failmsg = 0
        next
    }
    { print }
    END {
        if (!inserted_fixup || !inserted_nofail || !inserted_failmsg) {
            exit 42
        }
    }
' "$DEBOOTSTRAP_FUNCTIONS" > "$DEBOOTSTRAP_FUNCTIONS.patched"; then
    echo "ERROR: failed to patch debootstrap chroot wrappers" >&2
    exit 1
fi
mv "$DEBOOTSTRAP_FUNCTIONS.patched" "$DEBOOTSTRAP_FUNCTIONS"
bash -n "$DEBOOTSTRAP_FUNCTIONS"

# NCZ: gnu-coreutils naming fix (restored from take79, lost in 26.6-take1).
# resolute coreutils installs binaries as /usr/bin/gnuXXX (gnutrue, gnucat...).
# The chroot "/bin/true" sanity probe in second_stage_install fails unless the
# standard names exist. Patch BOTH the gutsy suite script (target symlinks
# before the in_target probe) and /usr/sbin/debootstrap (--second-stage-only
# path: pre-extract gnu-coreutils + symlink before any use of cat).
echo "    patching debootstrap gnu-coreutils naming (gutsy + sbin/debootstrap)"

DEBOOTSTRAP_GUTSY="$DEBOOTSTRAP_PATCH_DATA/usr/share/debootstrap/scripts/gutsy"
DEBOOTSTRAP_SBIN="$DEBOOTSTRAP_PATCH_DATA/usr/sbin/debootstrap"
[ -f "$DEBOOTSTRAP_GUTSY" ] || { echo "ERROR: debootstrap-udeb missing scripts/gutsy" >&2; exit 1; }
[ -f "$DEBOOTSTRAP_SBIN" ]  || { echo "ERROR: debootstrap-udeb missing usr/sbin/debootstrap" >&2; exit 1; }

if grep -q '_ncz_cmd' "$DEBOOTSTRAP_GUTSY"; then
    echo "ERROR: gutsy already contains _ncz_cmd patch" >&2
    exit 1
fi

printf '%s\n' \
'	# NCZ: create gnu->standard symlinks before the initial chroot /bin/true probe.' \
'	# In normal d-i debootstrap this runs outside the target and /bin/ln is' \
'	# the installer busybox/coreutils. In --second-stage-only TARGET=/, so' \
'	# also try the target gnuln/gnucp directly.' \
'	for _ncz_cmd in [ b2sum base32 base64 basename basenc cat chcon chgrp chmod chown chroot cksum comm cp csplit cut date dd df dir dircolors dirname du echo env expand expr factor false fmt fold groups head hostid id install join link ln logname ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od paste pathchk pinky pr printenv printf ptx pwd readlink realpath rm rmdir runcon seq sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort split stat stdbuf stty sum sync tac tail tee test timeout touch tr true truncate tsort tty uname unexpand uniq unlink users vdir wc who whoami yes; do' \
'		if [ ! -e "$TARGET/usr/bin/$_ncz_cmd" ] && [ -e "$TARGET/usr/bin/gnu$_ncz_cmd" ]; then' \
'			/bin/ln -sf "gnu$_ncz_cmd" "$TARGET/usr/bin/$_ncz_cmd" 2>/dev/null || ln -sf "gnu$_ncz_cmd" "$TARGET/usr/bin/$_ncz_cmd" 2>/dev/null || /usr/bin/gnuln -sf "gnu$_ncz_cmd" "$TARGET/usr/bin/$_ncz_cmd" 2>/dev/null || /bin/cp -a "$TARGET/usr/bin/gnu$_ncz_cmd" "$TARGET/usr/bin/$_ncz_cmd" 2>/dev/null || cp -a "$TARGET/usr/bin/gnu$_ncz_cmd" "$TARGET/usr/bin/$_ncz_cmd" 2>/dev/null || /usr/bin/gnucp -a "$TARGET/usr/bin/gnu$_ncz_cmd" "$TARGET/usr/bin/$_ncz_cmd" 2>/dev/null || true' \
'		fi' \
'	done' \
> "$DEBOOTSTRAP_PATCH_TMP/ncz_gutsy_block.sh"

printf '%s\n' \
'	# NCZ: ensure cat is available before using it below' \
'	if [ ! -x /usr/bin/cat ]; then' \
'		for _ncz_deb in /var/cache/apt/archives/gnu-coreutils_*.deb; do' \
'			[ -f "$_ncz_deb" ] && dpkg --force-all --unpack "$_ncz_deb" 2>/dev/null && break' \
'		done' \
'		for _ncz_cmd in cat ln cp true false env; do' \
'			if [ ! -e "/usr/bin/$_ncz_cmd" ] && [ -e "/usr/bin/gnu$_ncz_cmd" ]; then' \
'				/usr/bin/gnuln -sf "gnu$_ncz_cmd" "/usr/bin/$_ncz_cmd" 2>/dev/null || /usr/bin/gnucp -a "/usr/bin/gnu$_ncz_cmd" "/usr/bin/$_ncz_cmd" 2>/dev/null || true' \
'			fi' \
'		done' \
'	fi' \
> "$DEBOOTSTRAP_PATCH_TMP/ncz_sbin_block.sh"

if ! awk -v block="$DEBOOTSTRAP_PATCH_TMP/ncz_gutsy_block.sh" '
    $0 == "second_stage_install () {" {
        print
        while ((getline line < block) > 0) print line
        close(block)
        count++
        next
    }
    { print }
    END { if (count != 1) exit 42 }
' "$DEBOOTSTRAP_GUTSY" > "$DEBOOTSTRAP_GUTSY.patched"; then
    echo "ERROR: failed to patch gutsy (second_stage_install anchor not found exactly once)" >&2
    exit 1
fi
mv "$DEBOOTSTRAP_GUTSY.patched" "$DEBOOTSTRAP_GUTSY"
bash -n "$DEBOOTSTRAP_GUTSY"

# NCZ r98-fat: force dbus into the debootstrap base set so systemd-resolved's
# postinst finds its default-dbus-system-bus provider during the second-stage
# install. Fixes the r97 live-install failure ("systemd-resolved unpacked but
# not configured") which happened in base/debootstrap — before pkgsel runs, so
# pkgsel/include of dbus was too late. work_out_debs sets base= for the default
# (variant "-") debootstrap d-i uses; we append the dbus stack right after.
if grep -q '_ncz_dbus_base' "$DEBOOTSTRAP_GUTSY"; then
    echo "ERROR: gutsy already contains _ncz_dbus_base patch" >&2
    exit 1
fi
if ! awk '
    /base="\$\(get_debs Priority: important\)"/ && !ncz_done {
        print
        print "\t# _ncz_dbus_base (NCZ r98): pull dbus into base so systemd-resolved configures"
        print "\tbase=\"$base dbus dbus-system-bus-common dbus-bin dbus-daemon\""
        ncz_done=1
        next
    }
    { print }
    END { if (!ncz_done) exit 42 }
' "$DEBOOTSTRAP_GUTSY" > "$DEBOOTSTRAP_GUTSY.dbus"; then
    echo "ERROR: failed to patch gutsy work_out_debs (base= 'important' anchor not found)" >&2
    exit 1
fi
mv "$DEBOOTSTRAP_GUTSY.dbus" "$DEBOOTSTRAP_GUTSY"
bash -n "$DEBOOTSTRAP_GUTSY"
echo "    patched gutsy: dbus forced into debootstrap base set (r98 systemd-resolved fix)"

# Only patch /usr/sbin/debootstrap when the REAL debootstrap is shipped (thin /
# netinstall modes). In full mode PATCH_DEBOOTSTRAP_STUB=1 replaces it with the
# r40 stub, which has no SECOND_STAGE_ONLY anchor and never runs debootstrap.
if [ "$PATCH_DEBOOTSTRAP_STUB" != "1" ]; then
    if grep -q '_ncz_deb' "$DEBOOTSTRAP_SBIN"; then
        echo "ERROR: usr/sbin/debootstrap already contains _ncz_deb patch" >&2
        exit 1
    fi
    if ! awk -v block="$DEBOOTSTRAP_PATCH_TMP/ncz_sbin_block.sh" '
        $0 == "if [ \"$SECOND_STAGE_ONLY\" = \"true\" ]; then" {
            print
            while ((getline line < block) > 0) print line
            close(block)
            count++
            next
        }
        { print }
        END { if (count != 1) exit 42 }
    ' "$DEBOOTSTRAP_SBIN" > "$DEBOOTSTRAP_SBIN.patched"; then
        echo "ERROR: failed to patch usr/sbin/debootstrap (SECOND_STAGE_ONLY anchor not found exactly once)" >&2
        exit 1
    fi
    mv "$DEBOOTSTRAP_SBIN.patched" "$DEBOOTSTRAP_SBIN"
    chmod 0755 "$DEBOOTSTRAP_SBIN"
    bash -n "$DEBOOTSTRAP_SBIN"
else
    echo "    skipping usr/sbin/debootstrap gnu-coreutils patch (stub mode)"
fi

rm -f "$DEBOOTSTRAP_PATCH_AR/$DEBOOTSTRAP_DATA_MEMBER"
(
    cd "$DEBOOTSTRAP_PATCH_DATA"
    tar --numeric-owner --owner=0 --group=0 -cf - .
) | gzip -9n > "$DEBOOTSTRAP_PATCH_AR/data.tar.gz"

DEBOOTSTRAP_NEW_UDEB="$DEBOOTSTRAP_PATCH_TMP/$(basename "$DEBOOTSTRAP_UDEB")"
(
    cd "$DEBOOTSTRAP_PATCH_AR"
    ar rc "$DEBOOTSTRAP_NEW_UDEB" debian-binary "$DEBOOTSTRAP_CONTROL_MEMBER" data.tar.gz
)
mv "$DEBOOTSTRAP_NEW_UDEB" "$DEBOOTSTRAP_UDEB"
rm -rf "$DEBOOTSTRAP_PATCH_TMP"

# r120: neutralize the d-i "Make the system bootable" installers.
#
# The installed bootloader is rEFInd (post-install/70-bootloader.sh, run from
# late_command: stages kernels on the FAT ESP + writes refind.conf). We do NOT
# want d-i's own bootable-step installers touching the target/ESP because they
# (a) are redundant with rEFInd and (b) FAIL on a btrfs root / no-EFI / generic
# arm64 board, red-erroring the whole install at "Make the system bootable".
#
# TWO udebs register that menu item on arm64 (lower Installer-Menu-Item runs
# first):
#   flash-kernel-installer  Installer-Menu-Item: 7300  (PRIMARY on arm64)
#   grub-installer          Installer-Menu-Item: 7400
#
# d-i main-menu runs the udeb's *postinst* (control.tar) for the menu item —
# NOT data.tar's /usr/bin/<tool> (the r118 mistake). So we stub each udeb's
# POSTINST to exit 0. Step-5 index regen below updates the hashes.
#
# History: r118 stubbed only grub's data.tar binary (ineffective). r119 stubbed
# grub's postinst but missed flash-kernel-installer (7300), which still failed.
# r120 neutralizes BOTH postinsts.
neutralize_udeb_postinst() {
    # $1 = udeb path glob (first match used); $2 = human label
    local _glob="$1" _label="$2"
    local _matches; _matches=( $_glob )
    local _udeb="${_matches[0]}"
    if [ ! -e "$_udeb" ]; then
        echo "    NOTE: $_label udeb not in pool — nothing to neutralize"
        return 0
    fi
    echo "    neutralizing $_label udeb -> exit-0 postinst stub ($(basename "$_udeb"))"
    local _tmp="$STAGING/.tmp-neutralize-udeb"
    local _ar="$_tmp/ar" _ctl="$_tmp/ctl"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_ctl"
    local _udeb_abs; _udeb_abs="$(readlink -f "$_udeb")"
    ( cd "$_ar" && ar x "$_udeb_abs" )
    [ -f "$_ar/debian-binary" ] || { echo "ERROR: $_label udeb missing debian-binary" >&2; exit 1; }
    local _ctl_members=( "$_ar"/control.tar* )
    local _data_members=( "$_ar"/data.tar* )
    local _ctl_member; _ctl_member="$(basename "${_ctl_members[0]}")"
    local _data_member; _data_member="$(basename "${_data_members[0]}")"
    tar -xf "$_ar/$_ctl_member" -C "$_ctl"
    [ -f "$_ctl/postinst" ] || { echo "ERROR: $_label udeb missing control/postinst" >&2; exit 1; }
    cat > "$_ctl/postinst" <<GIPOST
#! /bin/sh -e
# ncz r120 stub $_label postinst — d-i "Make the system bootable" no-op.
# Installed bootloader is rEFInd (post-install/70-bootloader.sh from
# late_command). Upstream installer is redundant and FAILS on btrfs/no-EFI/
# generic-arm64; always succeed so the install completes.
. /usr/share/debconf/confmodule 2>/dev/null || true
logger -t $_label "ncz stub: skipping bootable step — rEFInd installed by 70-bootloader.sh" 2>/dev/null || true
exit 0
GIPOST
    chmod 0755 "$_ctl/postinst"
    bash -n "$_ctl/postinst"
    rm -f "$_ar/$_ctl_member"
    ( cd "$_ctl" && tar --numeric-owner --owner=0 --group=0 -cf - . ) | gzip -9n > "$_ar/control.tar.gz"
    # Repack: keep the ORIGINAL data.tar member untouched (its binaries are
    # never run as the menu action; only the postinst is).
    local _new_udeb="$_tmp/$(basename "$_udeb")"
    ( cd "$_ar" && ar rc "$_new_udeb" debian-binary control.tar.gz "$_data_member" )
    mv "$_new_udeb" "$_udeb"
    rm -rf "$_tmp"
    echo "    $_label neutralized: postinst exit-0 (rEFInd installs via 70-bootloader.sh)"
}
neutralize_udeb_postinst "$STAGING/pool/main/f/flash-kernel/flash-kernel-installer_*.udeb" "flash-kernel-installer"
neutralize_udeb_postinst "$STAGING/pool/main/g/grub-installer/grub-installer_*.udeb" "grub-installer"

# Step 5: regenerate dists/resolute/main/debian-installer/binary-arm64/Packages
# from the actual pool contents (not just copy bookworm's stale Packages).
# After the trixie graft, the d-i Packages index MUST reflect the new udeb set
# or anna can't find the new udebs.
echo "    regenerating udeb Packages index from actual pool contents"
mkdir -p "$STAGING/dists/resolute/main/debian-installer/binary-arm64"
(
    cd "$STAGING"
    dpkg-scanpackages --type udeb --multiversion pool/main /dev/null 2>/dev/null \
        > dists/resolute/main/debian-installer/binary-arm64/Packages
    gzip -9cn dists/resolute/main/debian-installer/binary-arm64/Packages \
        > dists/resolute/main/debian-installer/binary-arm64/Packages.gz
    UDEBCT=$(grep -c '^Package: ' dists/resolute/main/debian-installer/binary-arm64/Packages || echo 0)
    echo "    udeb Packages: $UDEBCT entries indexed"
)

if [ "$EMBED_MIRROR" = "0" ] && [ "$BOOTSTRAP_POOL" = "0" ]; then
    # 2026-05-07 (take7 chroot-target failure → take8 fix per
    # Codex R78-INVALID-RELEASE-AUDIT):
    #
    # take7 attempted to force base-installer onto the http mirror by
    # removing /cdrom/dists/resolute/main/binary-arm64 entirely. That
    # broke debootstrap's Release validation — it sees Components: main
    # declared but no main/binary-arm64/Packages hashes → "Invalid
    # Release file" red dialog.
    #
    # The actual lever for "use http, not cdrom" is `.disk/base_installable`,
    # NOT the regular Packages content. We remove the .disk markers
    # above; here we keep an empty regular Packages so the Release file
    # is consistent with `Components: main` and anna can still find
    # main/debian-installer/binary-arm64/Packages for udeb loading.
    echo "    netinstall mode: writing empty regular Packages index for Release-file consistency"
    mkdir -p "$STAGING/dists/resolute/main/binary-arm64"
    : > "$STAGING/dists/resolute/main/binary-arm64/Packages"
    gzip -9cn "$STAGING/dists/resolute/main/binary-arm64/Packages" \
        > "$STAGING/dists/resolute/main/binary-arm64/Packages.gz"
elif [ "$BOOTSTRAP_POOL" = "1" ]; then
    if [ ! -s "$STAGING/dists/resolute/main/binary-arm64/Packages" ]; then
        echo "ERROR: bootstrap pool did not provide a non-empty regular Packages index" >&2
        exit 1
    fi
    BOOTSTRAP_DEBCT=$(grep -c '^Package: ' "$STAGING/dists/resolute/main/binary-arm64/Packages" || echo 0)
    echo "    bootstrap pool regular Packages: $BOOTSTRAP_DEBCT entries indexed"
fi

# Step 6: regenerate dists/resolute/Release to include BOTH the regular
# Packages indexes AND the debian-installer Packages indexes. apt-ftparchive
# reads the entire dists/resolute/ tree and computes hashes for everything.
echo "    regenerating dists/resolute/Release with both regular + udeb indexes"
(
    cd "$STAGING"
    write_translation_indexes resolute main
    write_component_release_files resolute arm64
    if [ "$EMBED_MIRROR" = "1" ]; then
        write_suite_release resolute arm64 main "nclawzero cixmini offline mirror — resolute arm64 (regular + udebs)"
    elif [ "$BOOTSTRAP_POOL" = "1" ]; then
        write_suite_release resolute arm64 main "nclawzero cixmini netinstall bootstrap pool - resolute arm64"
    else
        write_suite_release resolute arm64 main "nclawzero cixmini netinstall udeb substrate — resolute arm64"
    fi
)
echo "    Release file regenerated:"
head -16 "$STAGING/dists/resolute/Release" | sed 's/^/      /'

# r27-compat-fix:
# Verify the actual embedded mirror payload formats before we build an ISO.
# This is the authoritative check for "what Resolute packages use" in this
# offline image.
check_deb_member_formats_for_di "$STAGING" "$STAGING/.deb-format-report.tsv"

# Cleanup tmp
rm -rf "$TMP_UDEBS"

# Rewrite .disk/ — d-i's cdrom-detect needs these markers to recognize
# the media as a valid install source. Bookworm's .disk/info pointed at
# Debian; ours points at our installer payload.
echo "    rewriting .disk/ markers for $MODE mode"
mkdir -p "$STAGING/.disk" "$STAGING/.disk/id"
# 2026-05-07 (take8 / Codex R78-INVALID-RELEASE-AUDIT): in netinstall
# mode the medium is NOT base-installable. base-installer's
# get_mirror_info checks for /cdrom/.disk/base_installable FIRST and,
# if present, forces PROTOCOL=file MIRROR= DIRECTORY=/cdrom/ regardless
# of mirror/* preseed values. Removing the marker (and its companion
# base_components) is the supported way to tell base-installer "use
# the configured HTTP mirror; this medium is for udebs/boot only".
if [ "$MODE" = "netinstall" ] || [ "$MODE" = "netinstall-bootstrap" ]; then
    rm -f "$STAGING/.disk/base_installable" "$STAGING/.disk/base_components"
else
    printf 'main\n' > "$STAGING/.disk/base_components"
    : > "$STAGING/.disk/base_installable"
fi
printf 'dvd\n' > "$STAGING/.disk/cd_type"
case "$MODE" in
    netinstall)
        printf 'nclawzero cixmini resolute - Netinstall arm64 Binary 1\n' > "$STAGING/.disk/info"
        ;;
    netinstall-bootstrap)
        printf 'nclawzero cixmini resolute - Netinstall Bootstrap arm64 Binary 1\n' > "$STAGING/.disk/info"
        ;;
    thin)
        printf 'nclawzero cixmini resolute - Thin arm64 Binary 1\n' > "$STAGING/.disk/info"
        ;;
    *)
        printf 'nclawzero cixmini resolute - Offline arm64 Binary 1\n' > "$STAGING/.disk/info"
        ;;
esac
# .disk/udeb_include: tells d-i to use our network-console udeb etc.
echo "    .disk/info:    $(cat "$STAGING/.disk/info")"

# ----------------------------------------------------------------------
# Step 2 — replace install.a64/vmlinuz with our Sky1 installer kernel
# ----------------------------------------------------------------------
echo "[2] swapping /install.a64/vmlinuz to linux-cix-sky1 $INSTALLER_KERNEL_LABEL ($KVER_INSTALLER)"
[ -f "$STAGING/install.a64/vmlinuz" ] || { echo "ERROR: bookworm has no /install.a64/vmlinuz"; exit 1; }
cp -L "$INSTALLER_KERN" "$STAGING/install.a64/vmlinuz"
echo "    replaced: $(du -h "$STAGING/install.a64/vmlinuz" | cut -f1)"

# ----------------------------------------------------------------------
# Step 3 — concat our modules cpio onto install.a64/initrd.gz
# ----------------------------------------------------------------------
echo "[3] appending modules cpio to /install.a64/initrd.gz ($KVER_INSTALLER)"

WORK="$STAGING/.installer-kernel-overlay"
rm -rf "$WORK"
mkdir -p "$WORK"
tar xzf "$INSTALLER_TGZ" -C "$WORK"
[ -d "$WORK/lib/modules/$KVER_INSTALLER" ] || \
    { echo "ERROR: tarball didn't extract to lib/modules/$KVER_INSTALLER"; exit 1; }

depmod -a -b "$WORK" "$KVER_INSTALLER"
[ -f "$WORK/lib/modules/$KVER_INSTALLER/modules.dep" ] || \
    { echo "ERROR: depmod failed"; exit 1; }

# r79: stage Realtek rtl_nic firmware into the installer initrd so the
# built-in r8169 driver can bring up the Orion O6 NIC (RTL8125/8126)
# during d-i netcfg. Without the blob the O6 link never comes up and
# the install dead-ends at "no network interface". The MS-R1 RTL8127
# links without fw, which is why this regression only hit O6.
if [ -d "$ROOT/assets/firmware/rtl_nic" ]; then
    mkdir -p "$WORK/lib/firmware/rtl_nic"
    cp -L "$ROOT/assets/firmware/rtl_nic/"*.fw "$WORK/lib/firmware/rtl_nic/" 2>/dev/null || true
    echo "    rtl_nic firmware → installer initrd: $(ls "$WORK/lib/firmware/rtl_nic" 2>/dev/null | wc -l | tr -d ' ') blobs"
else
    echo "    WARN: assets/firmware/rtl_nic absent — O6 NIC will not link in installer"
fi

OVERLAY_GZ="$STAGING/.installer-kernel-overlay.cpio.gz"
( cd "$WORK" && find lib -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$OVERLAY_GZ"
gzip -t "$OVERLAY_GZ"
echo "    overlay cpio: $(du -h "$OVERLAY_GZ" | cut -f1)"

# r48: amber CRT phosphor palette via binary-patch of cdebconf-newt newt.so.
# libnewt 0.52 only has 6 color names compiled in (white/black/blue/brown/
# lightgray/red) so NEWT_COLORS=brightgreen is silently dropped. cdebconf-newt
# also OVERRIDES with its own newtDefaultColorPalette via newtSetColors().
# The only fix is to binary-patch cdebconf-newt's palette pointers IN-PLACE
# to use yellow+black+white instead of red+blue+grey, then ship the patched
# newt.so via cpio overlay (later cpio entries supersede earlier).
#
# 2026-05-08 take13: the binary-patch step was calibrated against bookworm's
# newt.so layout (palette[0] = 0x5985 at offset 0x10380). Trixie's newt.so
# has a different palette[0] value and the safety check refuses to patch.
# Until we calibrate trixie palette offsets, skip the binary-patch step
# entirely on trixie substrate. NEWT_COLORS env-var injection still runs
# (which is the load-bearing path; binary patch was a fallback for older
# libnewt versions). User-visible effect: install dialogs use libnewt's
# default red/blue/grey on trixie d-i instead of amber phosphor. Cosmetic.
if [ "$DI_CODENAME" = "trixie" ]; then
    echo "[3.5] SKIP amber-phosphor binary patch on trixie (NEWT_COLORS env-var still applied below)"
    SKIP_NEWT_BINARY_PATCH=1
else
    SKIP_NEWT_BINARY_PATCH=0
fi
echo "[3.5] patching d-i for amber phosphor palette + injecting NEWT_COLORS"
INITRD_PATCH_TMP="$STAGING/.init-patch-tmp"
rm -rf "$INITRD_PATCH_TMP"
mkdir -p "$INITRD_PATCH_TMP/extract" "$INITRD_PATCH_TMP/overlay/usr/lib/cdebconf/frontend"

INITRD="$STAGING/install.a64/initrd.gz"

# Pull /init and newt.so out of the existing initrd (gunzip handles
# concatenated streams; cpio handles concatenated archives, last-wins)
# Bookworm initrd cpio entries are stored without leading ./ — extract everything,
# then read what we need. Suppress mknod-warnings (non-root cpio cant make device nodes).
gunzip -c "$INITRD" | ( cd "$INITRD_PATCH_TMP/extract" && cpio -idu --quiet 2>/dev/null ) || true
[ -s "$INITRD_PATCH_TMP/extract/init" ] || { echo "ERROR: /init not extractable from initrd"; exit 1; }
[ -s "$INITRD_PATCH_TMP/extract/usr/lib/cdebconf/frontend/newt.so" ] || { echo "ERROR: cdebconf newt.so not extractable from initrd"; exit 1; }

# Inject NEWT_COLORS export into /init using only libnewt-supported names
# (white, black, blue, lightgray, red, brown). brightgreen is NOT in
# libnewt 0.52's compiled name table so we use yellow+black instead.
python3 - "$INITRD_PATCH_TMP/extract/init" "$INITRD_PATCH_TMP/overlay/init" <<'PYEOF1'
import sys
src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path) as f: src = f.read()
inject = (
    '\n# r48 nclawzero amber CRT phosphor palette\n'
    'export NEWT_COLORS="root=yellow,black;'
    'border=yellow,black;window=yellow,black;shadow=yellow,black;'
    'title=yellow,black;button=black,yellow;'
    'actbutton=black,white;compactbutton=yellow,black;'
    'checkbox=yellow,black;actcheckbox=black,yellow;'
    'entry=yellow,black;disentry=lightgray,black;label=yellow,black;'
    'listbox=yellow,black;actlistbox=black,yellow;'
    'sellistbox=yellow,black;actsellistbox=black,yellow;'
    'textbox=yellow,black;acttextbox=black,yellow;'
    'helpline=yellow,black;roottext=yellow,black;'
    'emptyscale=yellow,lightgray;fullscale=yellow,yellow"\n'
)
if "NEWT_COLORS" in src:
    print("    SKIP: NEWT_COLORS already in /init")
    open(dst_path, "w").write(src)
else:
    lines = src.split("\n")
    out_idx = 0
    for i, line in enumerate(lines):
        if i == 0 and line.startswith("#!"):
            out_idx = 1; continue
        if line.startswith("#") or not line.strip():
            out_idx = i + 1; continue
        break
    new_src = "\n".join(lines[:out_idx]) + inject + "\n".join(lines[out_idx:])
    open(dst_path, "w").write(new_src)
    print("    OK: NEWT_COLORS exported in /init overlay (env-var path)")
PYEOF1

# Binary-patch cdebconf-newt's compiled palette pointer table at offset 0x10380.
# 44 pointers (22 fg/bg pairs) repointed to in-binary color name strings:
#   white     0x5985    yellow    0x5a20
#   black     0x5a1a    lightgray 0x5a27
#   gray      0x5a2c    brightred 0x5a31  (kept available, not used in patch)
#   blue      0x5a3b    brown     0x5a40
if [ "$SKIP_NEWT_BINARY_PATCH" = "1" ]; then
    # Trixie newt.so has different palette[0] value at 0x10380; copy
    # unmodified so the chmod + cpio overlay assembly still works.
    cp "$INITRD_PATCH_TMP/extract/usr/lib/cdebconf/frontend/newt.so" \
       "$INITRD_PATCH_TMP/overlay/usr/lib/cdebconf/frontend/newt.so"
    echo "    SKIP: newt.so binary patch (trixie substrate; NEWT_COLORS env-var path is sufficient)"
else
python3 - "$INITRD_PATCH_TMP/extract/usr/lib/cdebconf/frontend/newt.so" "$INITRD_PATCH_TMP/overlay/usr/lib/cdebconf/frontend/newt.so" <<'PYEOF2'
import sys, struct
src_path, dst_path = sys.argv[1], sys.argv[2]
data = bytearray(open(src_path, "rb").read())

PALETTE_OFFSET = 0x10380
WHITE   = 0x5985
BLACK   = 0x5a1a
YELLOW  = 0x5a20
LTGRAY  = 0x5a27
GRAY    = 0x5a2c
BLUE    = 0x5a3b

# Verify the pointer at offset 0x10380 still points to "white" (0x5985);
# confirms we're patching the right binary version.
# 2026-05-08 (Codex r78 take13 audit MEDIUM #4): on unknown pointer,
# downgrade to non-fatal — copy unmodified newt.so so the bake doesn't
# block on a cosmetic palette change. NEWT_COLORS env-var path in the
# /init overlay is the primary amber-phosphor mechanism; binary palette
# patch is the belt-and-suspenders pass.
existing = struct.unpack_from("<Q", data, PALETTE_OFFSET)[0]
if existing != WHITE:
    print(f"    WARN: palette[0] at 0x{PALETTE_OFFSET:x} = 0x{existing:x}, expected 0x{WHITE:x} — skipping binary palette patch (NEWT_COLORS env path remains active)", file=sys.stderr)
    open(dst_path, "wb").write(bytes(data))
    sys.exit(0)

# 22 pairs (44 pointers): fg, bg, fg, bg, ...
PALETTE = [
    YELLOW, BLACK,   # root
    YELLOW, BLACK,   # border
    YELLOW, BLACK,   # window
    YELLOW, BLACK,   # shadow
    YELLOW, BLACK,   # title
    BLACK,  YELLOW,  # button
    BLACK,  WHITE,   # actbutton
    YELLOW, BLACK,   # checkbox
    BLACK,  YELLOW,  # actcheckbox
    YELLOW, BLACK,   # entry
    YELLOW, BLACK,   # label  (was brightred,black — caused the red look)
    YELLOW, BLACK,   # listbox
    BLACK,  YELLOW,  # actlistbox  (was yellow,blue)
    YELLOW, BLACK,   # textbox
    BLACK,  YELLOW,  # acttextbox
    YELLOW, BLACK,   # helpline
    YELLOW, BLACK,   # roottext  (was yellow,blue)
    YELLOW, LTGRAY,  # emptyscale  (was black,blue)
    YELLOW, YELLOW,  # fullscale   (was blue,lightgray)
    GRAY,   BLACK,   # disentry
    YELLOW, BLACK,   # compactbutton
    BLACK,  YELLOW,  # actsellistbox  (was black,brown)
]
assert len(PALETTE) == 44, f"expected 44 pointers, got {len(PALETTE)}"

for i, ptr in enumerate(PALETTE):
    struct.pack_into("<Q", data, PALETTE_OFFSET + i*8, ptr)

open(dst_path, "wb").write(bytes(data))
print(f"    OK: cdebconf-newt newt.so palette repointed for amber phosphor (44 ptrs)")
PYEOF2
fi  # end SKIP_NEWT_BINARY_PATCH conditional

# Preserve permissions on overlay files
chmod 0755 "$INITRD_PATCH_TMP/overlay/init"
chmod 0644 "$INITRD_PATCH_TMP/overlay/usr/lib/cdebconf/frontend/newt.so"

# Build cpio overlay containing both init + newt.so. Append to initrd.
( cd "$INITRD_PATCH_TMP/overlay" && find . | cpio -o -H newc --quiet | gzip -9 -n ) >> "$INITRD"
echo "    initrd patched: amber phosphor palette via cpio overlay"
rm -rf "$INITRD_PATCH_TMP"
rm -rf "$WORK"

# initrd.gz is a gzipped cpio. Linux supports concatenated multiple gzipped
# initramfs members. Append directly — no padding needed for gz members.
cat "$OVERLAY_GZ" >> "$STAGING/install.a64/initrd.gz"
rm -f "$OVERLAY_GZ"
echo "    initrd.gz now: $(du -h "$STAGING/install.a64/initrd.gz" | cut -f1)"

# ----------------------------------------------------------------------
# Step 3.1 — append zstd tools for resolute data.tar.zst/control.tar.zst
# ----------------------------------------------------------------------
echo "[3.1] appending zstdcat for resolute .deb extraction"

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
# --- NCZ 26.6: Add custom APT repository to the ISO payload
if [ -d "$ROOT/build/apt-repo" ]; then
    echo "--- staging NCZ offline apt repository ---"
    mkdir -p "$STAGING/cixmini/apt-repo"
    cp -r "$ROOT/build/apt-repo/"* "$STAGING/cixmini/apt-repo/"
fi

if [ "$MODE" = "full" ]; then
    cp "$ROOT/preseed/preseed-ubuntu.cfg" "$EXTRA/preseed.cfg"
else
    awk -v mode="$MODE" '
        function disabled(line) {
            print "# disabled by build/build-iso-di.sh --mode " mode ": " line
        }
        /^d-i partman\/late_command / {
            disabled($0)
            next
        }
        /^d-i partman\/late_command seen / {
            disabled($0)
            next
        }
        mode ~ /^netinstall/ && /^d-i cdrom\/(suite|codename) / {
            disabled($0)
            next
        }
        mode ~ /^netinstall/ && $0 == "d-i apt-setup/use_mirror boolean false" {
            print "d-i apt-setup/use_mirror boolean true"
            next
        }
        mode ~ /^netinstall/ && $0 == "d-i apt-cdrom-setup/no-cd boolean false" {
            print "d-i apt-cdrom-setup/no-cd boolean true"
            next
        }
        mode == "netinstall-bootstrap" && $0 == "d-i pkgsel/upgrade select full-upgrade" {
            print "d-i pkgsel/upgrade select none"
            next
        }
        { print }
    ' "$ROOT/preseed/preseed-ubuntu.cfg" > "$EXTRA/preseed.cfg"
fi
cp "$ROOT/preseed/late.sh"            "$EXTRA/late.sh"
cp "$ROOT/preseed/extract-rootfs.sh"  "$EXTRA/extract-rootfs.sh"
cp "$ROOT/preseed/sshd-watcher.sh"    "$EXTRA/sshd-watcher.sh"
chmod 0755 "$EXTRA/late.sh" "$EXTRA/extract-rootfs.sh" "$EXTRA/sshd-watcher.sh"
# Remote-diagnostics module (single, removable). DIAG_ENABLE=0 ships clean:
# the module is not staged and ncz_diag/DEBCONF_DEBUG are not added below.
if [ "${DIAG_ENABLE:-1}" = 1 ]; then
    cp "$ROOT/preseed/diag-console.sh"    "$EXTRA/diag-console.sh"
    cp "$ROOT/assets/diag/busybox-arm64"  "$EXTRA/busybox-arm64"
    chmod 0755 "$EXTRA/diag-console.sh" "$EXTRA/busybox-arm64"
    echo "    diag module staged (ncz_diag toggle; telnet :23 + http :8080 + remote syslog)"
else
    echo "    diag module DISABLED (DIAG_ENABLE=0) — ship-clean image"
fi

cp -a "$ROOT/post-install" "$EXTRA/post-install"

if [ -d "$ROOT/assets" ]; then
    mkdir -p "$EXTRA/assets"
    # Stage all asset trees except the raw kernel images (handled below
    # in their own block so mode-specific kernel payloads stay explicit).
    for d in "$ROOT/assets"/*; do
        bn=$(basename "$d")
        case "$bn" in
            kernel) ;;  # handled below — staged into /cixmini/assets/kernel/
            rootfs)
                if [ "$STAGE_ROOTFS" = "1" ]; then
                    cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true
                else
                    echo "    assets/rootfs skipped in --mode $MODE"
                fi
                ;;
            *) cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true ;;
        esac
    done
fi

# Stage target kernels. full/thin ship the historical LTS+NEXT payload;
# netinstall ships NEXT only per R76-NETINSTALL-DESIGN.md.
mkdir -p "$EXTRA/assets/kernel"
if [ "$STAGE_LTS_KERNEL" = "1" ]; then
    mkdir -p "$EXTRA/assets/kernel/stable"
    cp -L "$LTS_KERN" "$EXTRA/assets/kernel/stable/"
    cp -L "$LTS_TGZ"  "$EXTRA/assets/kernel/stable/"
    if [ -f "$ROOT/assets/kernel/stable/headers-cixmini.tar.zst" ]; then
        cp -L "$ROOT/assets/kernel/stable/headers-cixmini.tar.zst" "$EXTRA/assets/kernel/stable/"
        echo "    LTS headers staged: $(du -h "$EXTRA/assets/kernel/stable/headers-cixmini.tar.zst" | cut -f1)"
    else
        echo "    LTS headers: not present (skip — DKMS rebuild will fail on target)"
    fi
    # r98: archive the LTS kernel .config (provenance / future OOT rebuilds).
    if [ -n "$KVER_LTS" ] && [ -f "$ROOT/assets/kernel/stable/config-$KVER_LTS" ]; then
        cp -L "$ROOT/assets/kernel/stable/config-$KVER_LTS" "$EXTRA/assets/kernel/stable/"
        echo "    LTS config archived: config-$KVER_LTS"
    fi
    echo "    LTS kernel staged: $(du -h "$EXTRA/assets/kernel/stable/Image-cixmini.bin" | cut -f1) image, $(du -h "$EXTRA/assets/kernel/stable/modules-cixmini.tgz" | cut -f1) modules"
else
    echo "    netinstall mode: LTS kernel assets intentionally not staged"
fi

if [ "$STAGE_NEXT_KERNEL" = "1" ] && [ -n "$KVER_NEXT" ]; then
    mkdir -p "$EXTRA/assets/kernel/edge"
    cp -L "$NEXT_KERN" "$EXTRA/assets/kernel/edge/"
    cp -L "$NEXT_TGZ"  "$EXTRA/assets/kernel/edge/"
    if [ -f "$ROOT/assets/kernel/edge/headers-cixmini.tar.zst" ]; then
        cp -L "$ROOT/assets/kernel/edge/headers-cixmini.tar.zst" "$EXTRA/assets/kernel/edge/"
        echo "    NEXT headers staged: $(du -h "$EXTRA/assets/kernel/edge/headers-cixmini.tar.zst" | cut -f1)"
    else
        echo "    NEXT headers: not present (skip — DKMS rebuild will fail on target)"
    fi
    # r98: archive the NEXT kernel .config (provenance / future OOT rebuilds).
    if [ -n "$KVER_NEXT" ] && [ -f "$ROOT/assets/kernel/edge/config-$KVER_NEXT" ]; then
        cp -L "$ROOT/assets/kernel/edge/config-$KVER_NEXT" "$EXTRA/assets/kernel/edge/"
        echo "    NEXT config archived: config-$KVER_NEXT"
    fi
    echo "    NEXT kernel staged: $KVER_NEXT  ($(du -h "$EXTRA/assets/kernel/edge/Image-cixmini.bin" | cut -f1) image, $(du -h "$EXTRA/assets/kernel/edge/modules-cixmini.tgz" | cut -f1) modules)"
else
    echo "    NEXT kernel: not present — installer will ship LTS only"
fi

# Sky1 firmware assets: drop into /cixmini/assets/sky1-firmware/ exactly
# where 12-sky1-firmware.sh expects to find it after late.sh stages it.
if [ -d "$ROOT/assets/sky1-firmware" ]; then
    cp -rL "$ROOT/assets/sky1-firmware" "$EXTRA/assets/" 2>/dev/null || true
    echo "    sky1-firmware: $(du -sh "$EXTRA/assets/sky1-firmware" | cut -f1)"
fi

# r79: Realtek rtl_nic firmware (upstream linux-firmware) for the INSTALLED
# system. late.sh copies all of $EXTRA → /target/usr/local/lib/cix-installer,
# and 12-sky1-firmware.sh installs assets/firmware/rtl_nic → /lib/firmware so
# the Orion O6 NIC keeps linking after first boot, not just in the installer.
if [ -d "$ROOT/assets/firmware/rtl_nic" ]; then
    mkdir -p "$EXTRA/assets/firmware/rtl_nic"
    cp -L "$ROOT/assets/firmware/rtl_nic/"*.fw "$EXTRA/assets/firmware/rtl_nic/" 2>/dev/null || true
    echo "    rtl_nic firmware (target): $(ls "$EXTRA/assets/firmware/rtl_nic" 2>/dev/null | wc -l | tr -d ' ') blobs"
fi

# NPU py3.11 uv venv toolchain (staged by the generic assets loop above):
# relocatable CPython 3.11 + uv. 46-python311.sh consumes it offline-first.
if [ -d "$EXTRA/assets/python311" ]; then
    echo "    python311 (NPU uv venv): $(du -sh "$EXTRA/assets/python311" | cut -f1) — $(find "$EXTRA/assets/python311" -maxdepth 1 -type f | wc -l | tr -d ' ') file(s)"
else
    echo "    python311 (NPU uv venv): NOT staged — NPU-from-Python will need network at install (uv fetches 3.11)"
fi

# r104: validated kernel-module overlays (e.g. armchina_npu.ko with ARCH_V3 +
# iova_region=2 fixes). The 'kernel' subdir is special-cased above so only
# stable/+edge/ get staged — explicitly stage modules-overlay/ so 80-npu.sh
# can drop the validated NPU module into /usr/lib/modules/$KVER/updates/.
# Lands at /usr/local/lib/cix-installer/assets/kernel/modules-overlay/ via late.sh.
if [ -d "$ROOT/assets/kernel/modules-overlay" ]; then
    mkdir -p "$EXTRA/assets/kernel/modules-overlay"
    cp -rL "$ROOT/assets/kernel/modules-overlay/"* "$EXTRA/assets/kernel/modules-overlay/" 2>/dev/null || true
    echo "    modules-overlay: $(find "$EXTRA/assets/kernel/modules-overlay" -name '*.ko' 2>/dev/null | wc -l) .ko ($(du -sh "$EXTRA/assets/kernel/modules-overlay" 2>/dev/null | cut -f1))"
fi

# r118: rEFInd boot manager binary for the INSTALLED system. 70-bootloader.sh
# installs it to the target ESP at the firmware fallback path
# /EFI/BOOT/BOOTAA64.EFI and writes refind.conf. We ship the binary (rEFInd
# is not in Ubuntu ports' default pool) and let the kernel's own initramfs
# mount the btrfs root, so rEFInd needs no btrfs/ext4 EFI filesystem driver.
# Lands at /usr/local/lib/cix-installer/assets/refind/ via late.sh.
if [ -f "$ROOT/build/refind-bin/refind_aa64.efi" ]; then
    mkdir -p "$EXTRA/assets/refind"
    cp -L "$ROOT/build/refind-bin/refind_aa64.efi" "$EXTRA/assets/refind/"
    echo "    refind: refind_aa64.efi staged ($(du -h "$EXTRA/assets/refind/refind_aa64.efi" | cut -f1))"
else
    echo "    refind: build/refind-bin/refind_aa64.efi MISSING — 70-bootloader will FAIL (no installed bootloader)" >&2
fi

echo "$VERSION"     > "$EXTRA/BUILD_VERSION"
echo "$BUILD_DATE"  > "$EXTRA/BUILD_DATE"
echo "$BUILD_HOST"  > "$EXTRA/BUILD_HOST"
echo "$MODE"        > "$EXTRA/BUILD_MODE"
echo "$VARIANT"     > "$EXTRA/BUILD_VARIANT"   # r75 M1: read by 48-magnetar-variant.sh
# r40 full mode: stage the pre-built rootfs tarball so the debootstrap stub
# can populate /target without a real bootstrap.
if [ "$STAGE_ROOTFS" = "1" ]; then
    ROOTFS_TARBALL="$ROOT/assets/rootfs/rootfs-resolute-arm64.tar.zst"
    if [ -f "$ROOTFS_TARBALL" ]; then
        cp -L "$ROOTFS_TARBALL" "$EXTRA/rootfs.tar.zst"
        echo "    rootfs.tar.zst staged: $(du -h "$EXTRA/rootfs.tar.zst" | cut -f1) (resolute arm64 pre-built target)"
    else
        echo "ERROR: $ROOTFS_TARBALL missing — run build-rootfs.sh first" >&2
        exit 1
    fi
else
    echo "    rootfs.tar.zst not staged in --mode $MODE"
fi

if [ -n "$KVER_LTS" ]; then
    echo "$KVER_LTS" > "$EXTRA/KVER_LTS"
fi
if [ -n "${KVER_NEXT:-}" ]; then
    echo "$KVER_NEXT" > "$EXTRA/KVER_NEXT"
fi
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
DI_PRIORITY=high
if [ "$MODE" = "netinstall" ]; then
    DI_PRIORITY=critical
fi
DI_OPTS="auto=true priority=$DI_PRIORITY preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=120"
# Diagnostics build switch: when on, enable the in-installer diag module
# (ncz_diag=1) and verbose debconf logging (DEBCONF_DEBUG=5). Both are
# omitted for DIAG_ENABLE=0 ship builds. Boot-time override: ncz_diag=0.
if [ "${DIAG_ENABLE:-1}" = 1 ]; then
    DI_OPTS="$DI_OPTS ncz_diag=1 DEBCONF_DEBUG=5"
fi

CODENAME="${BUILD_CODENAME:-Reinhardt}"
GRUB_KERNEL_SUMMARY="$INSTALLER_KERNEL_LABEL=$KVER_INSTALLER"
GRUB_DESKTOP_TITLE='Install NCZ \"Reinhardt\" — Desktop (XFCE)'
GRUB_SERVER_TITLE='Install NCZ \"Magnetar\" — Server (headless, agent appliance)'
if [ "$MODE" = "netinstall" ]; then
    GRUB_DESKTOP_TITLE='Install NCZ \"Reinhardt\" — Desktop (XFCE, wired link required)'
    GRUB_SERVER_TITLE='Install NCZ \"Magnetar\" — Server (headless, wired link required)'
fi
cat > "$GRUB_CFG" <<GRUB
# ncz-installer (cixmini "$CODENAME" / $VERSION)
# bookworm d-i busybox boot substrate + trixie udeb graft + Sky1 $INSTALLER_KERNEL_LABEL kernel
# Mode: $MODE
# Build: $VERSION  ($BUILD_DATE)  Host: $BUILD_HOST
# Kernel: $GRUB_KERNEL_SUMMARY
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
echo ""
echo "      ███╗   ██╗  ██████╗  ███████╗"
echo "      ████╗  ██║ ██╔════╝  ╚══███╔╝"
echo "      ██╔██╗ ██║ ██║         ███╔╝"
echo "      ██║╚██╗██║ ██║        ███╔╝"
echo "      ██║ ╚████║ ╚██████╗  ███████╗"
echo "      ╚═╝  ╚═══╝  ╚═════╝  ╚══════╝"
echo ""
echo "      Dr. Reinhardt has gone into the Black Hole."
echo ""
echo "               N C Z   I N S T A L L E R"
echo ""
echo "                cixmini  ·  Sky1 / CP8180"
echo "                  ARM64  ·  resolute 26.04"
echo ""
echo "                     $VERSION"
echo "                     \"$CODENAME\""
echo "               kernel: $KVER_INSTALLER ($INSTALLER_KERNEL_LABEL)"
echo "               build:  $BUILD_DATE"
echo ""

menuentry "$GRUB_DESKTOP_TITLE" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> ncz-installer loading Sky1 $INSTALLER_KERNEL_LABEL kernel + d-i (Reinhardt / desktop)..."
    linux  /install.a64/vmlinuz $DI_OPTS ncz_variant=desktop $MARTJOHNSON_R6
    echo ">> Loading initrd (modules + preseed + zstd)..."
    initrd /install.a64/initrd.gz
}

menuentry "$GRUB_SERVER_TITLE" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> ncz-installer loading Sky1 $INSTALLER_KERNEL_LABEL kernel + d-i (Magnetar / server)..."
    linux  /install.a64/vmlinuz $DI_OPTS ncz_variant=server $MARTJOHNSON_R6
    echo ">> Loading initrd (modules + preseed + zstd)..."
    initrd /install.a64/initrd.gz
}

menuentry "SAFE — rescue shell ($INSTALLER_KERNEL_LABEL, no install)" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> Loading rescue mode ($INSTALLER_KERNEL_LABEL $KVER_INSTALLER)..."
    linux  /install.a64/vmlinuz rescue/enable=true $MARTJOHNSON_R6
    initrd /install.a64/initrd.gz
}
GRUB
echo "    grub.cfg written ($(wc -l < "$GRUB_CFG") lines)"

# ----------------------------------------------------------------------
# Step 6 — regenerate md5sum.txt
# ----------------------------------------------------------------------
echo "[6] regenerating md5sum.txt"
( cd "$STAGING" && find . -type f \! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )
[ -s "$STAGING/md5sum.txt" ] || { echo "ERROR: md5sum.txt generation produced no entries" >&2; exit 1; }

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
    -r -V "NCX_REINHARDT" \
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

if [ "$MODE" = "netinstall" ] || [ "$MODE" = "netinstall-bootstrap" ]; then
    ISO_SIZE_BYTES=$(file_size_bytes "$OUTPUT") || exit 1
    if [ "$ISO_SIZE_BYTES" -le 0 ]; then
        echo "ERROR: could not determine $MODE ISO size for $OUTPUT" >&2
        exit 1
    fi
    if [ "$ISO_SIZE_BYTES" -ge "$NETINSTALL_MAX_BYTES" ]; then
        max_mb=$((NETINSTALL_MAX_BYTES / 1024 / 1024))
        echo "ERROR: $MODE ISO is ${ISO_SIZE_BYTES} bytes, expected < ${NETINSTALL_MAX_BYTES} bytes (<${max_mb} MB)" >&2
        exit 1
    fi
    max_mb=$((NETINSTALL_MAX_BYTES / 1024 / 1024))
    echo "$MODE size OK: ${ISO_SIZE_BYTES} bytes (<${max_mb} MB)"
fi
