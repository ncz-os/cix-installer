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
# control.tar.zst/data.tar.zst from offline questing mirror successfully.
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

# r40: replace /usr/sbin/debootstrap in the staged debootstrap-udeb with a stub.
# partman/late_command extracts rootfs.tar.zst into /target BEFORE bootstrap-base
# runs. Then bookworm bootstrap-base.run-debootstrap calls /usr/sbin/debootstrap
# (our stub), which detects /target is populated and exits 0. base-installer
# proceeds to finish-install, which fires preseed/late_command (our late.sh).
echo "    replacing /usr/sbin/debootstrap with r40 stub (rootfs.tar.zst install path)"
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

# r48: amber CRT phosphor palette via binary-patch of cdebconf-newt newt.so.
# libnewt 0.52 only has 6 color names compiled in (white/black/blue/brown/
# lightgray/red) so NEWT_COLORS=brightgreen is silently dropped. cdebconf-newt
# also OVERRIDES with its own newtDefaultColorPalette via newtSetColors().
# The only fix is to binary-patch cdebconf-newt's palette pointers IN-PLACE
# to use yellow+black+white instead of red+blue+grey, then ship the patched
# newt.so via cpio overlay (later cpio entries supersede earlier).
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
existing = struct.unpack_from("<Q", data, PALETTE_OFFSET)[0]
if existing != WHITE:
    print(f"    ERROR: palette[0] at 0x{PALETTE_OFFSET:x} = 0x{existing:x}, expected 0x{WHITE:x}", file=sys.stderr)
    sys.exit(1)

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
cp "$ROOT/preseed/extract-rootfs.sh"  "$EXTRA/extract-rootfs.sh"
chmod 0755 "$EXTRA/late.sh" "$EXTRA/extract-rootfs.sh"

cp -a "$ROOT/post-install" "$EXTRA/post-install"

if [ -d "$ROOT/assets" ]; then
    mkdir -p "$EXTRA/assets"
    # Stage all asset trees except the raw kernel images (handled below
    # in their own block — both LTS and NEXT need to land in the ISO so
    # 10-our-kernel.sh can install them on the target).
    for d in "$ROOT/assets"/*; do
        bn=$(basename "$d")
        case "$bn" in
            kernel) ;;  # handled below — staged into /cixmini/assets/kernel/
            *) cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true ;;
        esac
    done
fi

# Stage both kernels for sibling install. The d-i installer's own
# /install.a64/vmlinuz was already swapped to LTS at step [2]; this
# block ships the SAME LTS kernel plus the NEXT kernel into the ISO at
# /cixmini/assets/kernel/{lts,next}/ so 10-our-kernel.sh can install
# both onto the target via late.sh "cp -r /cdrom/cixmini".
mkdir -p "$EXTRA/assets/kernel"
if [ -f "$ROOT/assets/kernel/lts/Image-cixmini.bin" ] && [ -f "$ROOT/assets/kernel/lts/modules-cixmini.tgz" ]; then
    mkdir -p "$EXTRA/assets/kernel/lts"
    cp -L "$ROOT/assets/kernel/lts/Image-cixmini.bin"   "$EXTRA/assets/kernel/lts/"
    cp -L "$ROOT/assets/kernel/lts/modules-cixmini.tgz" "$EXTRA/assets/kernel/lts/"
    if [ -f "$ROOT/assets/kernel/lts/headers-cixmini.tar.zst" ]; then
        cp -L "$ROOT/assets/kernel/lts/headers-cixmini.tar.zst" "$EXTRA/assets/kernel/lts/"
        echo "    LTS headers staged: $(du -h "$EXTRA/assets/kernel/lts/headers-cixmini.tar.zst" | cut -f1)"
    else
        echo "    LTS headers: not present (skip — DKMS rebuild will fail on target)"
    fi
    echo "    LTS kernel staged: $(du -h "$EXTRA/assets/kernel/lts/Image-cixmini.bin" | cut -f1) image, $(du -h "$EXTRA/assets/kernel/lts/modules-cixmini.tgz" | cut -f1) modules"
else
    echo "ERROR: assets/kernel/lts/{Image-cixmini.bin,modules-cixmini.tgz} missing — re-run assemble-kernel-assets.sh" >&2
    exit 1
fi

NEXT_KVER_FILE="$ROOT/assets/kernel/next/KVER"
if [ -f "$NEXT_KVER_FILE" ] && [ -f "$ROOT/assets/kernel/next/Image-cixmini.bin" ] && [ -f "$ROOT/assets/kernel/next/modules-cixmini.tgz" ]; then
    KVER_NEXT=$(cat "$NEXT_KVER_FILE")
    mkdir -p "$EXTRA/assets/kernel/next"
    cp -L "$ROOT/assets/kernel/next/Image-cixmini.bin"   "$EXTRA/assets/kernel/next/"
    cp -L "$ROOT/assets/kernel/next/modules-cixmini.tgz" "$EXTRA/assets/kernel/next/"
    if [ -f "$ROOT/assets/kernel/next/headers-cixmini.tar.zst" ]; then
        cp -L "$ROOT/assets/kernel/next/headers-cixmini.tar.zst" "$EXTRA/assets/kernel/next/"
        echo "    NEXT headers staged: $(du -h "$EXTRA/assets/kernel/next/headers-cixmini.tar.zst" | cut -f1)"
    else
        echo "    NEXT headers: not present (skip — DKMS rebuild will fail on target)"
    fi
    echo "    NEXT kernel staged: $KVER_NEXT  ($(du -h "$EXTRA/assets/kernel/next/Image-cixmini.bin" | cut -f1) image, $(du -h "$EXTRA/assets/kernel/next/modules-cixmini.tgz" | cut -f1) modules)"
else
    KVER_NEXT=""
    echo "    NEXT kernel: not present — installer will ship LTS only"
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
# r40: stage the pre-built rootfs tarball so partman/late_command can extract
# it into /target before bootstrap-base runs.
ROOTFS_TARBALL="$ROOT/assets/rootfs/rootfs-questing-arm64.tar.zst"
if [ -f "$ROOTFS_TARBALL" ]; then
    cp -L "$ROOTFS_TARBALL" "$EXTRA/rootfs.tar.zst"
    echo "    rootfs.tar.zst staged: $(du -h "$EXTRA/rootfs.tar.zst" | cut -f1) (questing arm64 pre-built target)"
else
    echo "ERROR: $ROOTFS_TARBALL missing — run build-rootfs.sh first" >&2
    exit 1
fi

echo "$KVER_LTS"    > "$EXTRA/KVER_LTS"
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
echo "               N C X   2 6 . 5   I N S T A L L E R"
echo ""
echo "                cixmini  ·  Sky1 / CP8180"
echo "                  ARM64  ·  questing 25.10"
echo ""
echo "                     $VERSION"
echo "                     \"$CODENAME\""
echo "               kernel: $KVER_LTS"
echo "               build:  $BUILD_DATE"
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
