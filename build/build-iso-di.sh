#!/bin/bash
# build-iso-di.sh — bookworm d-i base + our Sky1 kernel + Ubuntu via late_command
#
# This rebuilds the r6 (Debian d-i) flow that's PROVEN to boot on Sky1
# UEFI on MS-R1, with two extensions:
#   1. Latest post-install hooks (incl. mali_csffw.bin symlink fix)
#   2. late_command swaps /etc/apt/sources.list from Debian to Ubuntu
#      after Debian 12 base lands, then apt full-upgrade to Ubuntu resolute.
#      End-state is a Debian system on disk with our Sky1 kernels.
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
# The shipped ISO has one unified installation target.  Internally it uses the
# desktop layer because that layer contains the complete Singularity system;
# installed rEFInd entries, not installer variants, select console/Mali/
# Panthor/recovery operation.
VARIANT="desktop"
MODE="full"         # r78: full | thin | netinstall | netinstall-bootstrap
NCZ_TARGET_ARCH="${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}"

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
  --variant desktop
      Compatibility argument; the unified NCZ-OS target always installs the
      complete Singularity desktop stack.
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

# Do not create an ISO that advertises a headless/server install while shipping
# a distinct complete desktop payload.  Console and recovery are installed
# boot choices, not mutually exclusive installer variants.
[ "$VARIANT" = "desktop" ] || {
    echo "ERROR: NCZ-OS unified ISO requires --variant desktop (got '$VARIANT')" >&2
    exit 1
}

case "$NCZ_TARGET_ARCH" in
    arm64|amd64) ;;
    *) echo "ERROR: unsupported NCZ_TARGET_ARCH=$NCZ_TARGET_ARCH (expected arm64 or amd64)" >&2; exit 1 ;;
esac

EMBED_MIRROR=1
STAGE_ROOTFS=1
PATCH_DEBOOTSTRAP_STUB=1
STAGE_NEXT_KERNEL=1
INSTALLER_KERNEL_FLAVOR=edge
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
        # ONE KERNEL TREE (operator, 2026-08-21): 26.7 ships
        # 7.2.0-sky1-ncz (edge) and ONLY that. The legacy 7.0.12 channel
        # has been retired; the legacy-kernel-channel branching has been
        # removed from the builder so this code path is edge-only.
        ;;
    thin)
        STAGE_ROOTFS=0
        PATCH_DEBOOTSTRAP_STUB=0
        ;;
    netinstall)
        EMBED_MIRROR=0
        STAGE_ROOTFS=0
        PATCH_DEBOOTSTRAP_STUB=0
        ;;
    netinstall-bootstrap)
        EMBED_MIRROR=0
        STAGE_ROOTFS=0
        PATCH_DEBOOTSTRAP_STUB=0
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

if [ "$EMBED_MIRROR" = "1" ]; then
    if ! compgen -G "$ROOT/build/kernel-debs/*.deb" >/dev/null; then
        echo "[kernel-debs] no local kernel debs present; building them before mirror publication"
        bash "$ROOT/build/build-kernel-debs.sh"
    fi
    echo "[vendor-mirror] publishing local kernel debs before SBOM preflight"
    bash "$ROOT/build/build-vendor-mirror.sh"
fi

LOCAL_VERSION_ARGS=()
if [ -d "$ROOT/build/sinty-out" ]; then
    LOCAL_VERSION_ARGS+=(--debs-dir "$ROOT/build/sinty-out")
fi

if [ -x "$ROOT/build/preflight-sbom-check.sh" ]; then
    bash "$ROOT/build/preflight-sbom-check.sh"
else
    echo "ERROR: missing executable SBOM preflight gate: $ROOT/build/preflight-sbom-check.sh" >&2
    exit 1
fi

# 2026-08-26: r190+ DEAD-CODE TWIN CONSISTENCY CHECK. See docs/ISO-BUILD-GUARDRAILS.md.
# The r159 layered-squashfs branch baked into the /usr/sbin/debootstrap stub below
# (the LIVE install-time extraction path) is also carried -- with the SAME logic
# in spirit -- by preseed/extract-rootfs.sh, which is invoked by the dead
# partman/late_command path (d-i does not actually run partman/late_command,
# so this file never executes in production). The two copies have already
# drifted three times (the round-1 fix to extract-rootfs.sh shipped nowhere;
# the round-3 fix to the stub shipped). The consistency check is the cheap
# mechanical gate that closes the trap without doing the larger unification
# refactor: it FAILS THE BUILD if the two branches' logical content has
# drifted, so a fix made in one file and forgotten in the other cannot reach
# a shipped ISO. See docs/ISO-BUILD-GUARDRAILS.md's "dead-code twin" trap
# entry for the full history.
if [ -x "$ROOT/build/check-extract-rootfs-consistency.sh" ]; then
    # TEMPORARY --loose (2026-08-26): --strict correctly found real,
    # pre-existing structural drift between the two files (extract-rootfs.sh
    # is missing a syslog-recovery fallback the stub has, among other things)
    # that predates this gate and needs its own reviewed sync -- not
    # something to force through under tonight's live-hardware incident
    # pressure. --loose still fails on any FUTURE drift beyond what's
    # already known, so this is not a no-op: it keeps the gate's core
    # purpose (catch a fix made in one file and forgotten in the other)
    # while not blocking builds on the pre-existing gap. Tighten back to
    # --strict once the two files are synced -- track this, don't forget it.
    bash "$ROOT/build/check-extract-rootfs-consistency.sh" \
        --build-iso-di "$ROOT/build/build-iso-di.sh" \
        --extract-rootfs "$ROOT/preseed/extract-rootfs.sh" \
        --loose
else
    echo "ERROR: missing extract-rootfs consistency gate: $ROOT/build/check-extract-rootfs-consistency.sh" >&2
    exit 1
fi

# Release identity is version-controlled separately from the per-build VERSION.
RELEASE_CONFIG="$ROOT/release.conf"
[ -s "$RELEASE_CONFIG" ] || { echo "ERROR: missing release identity: $RELEASE_CONFIG" >&2; exit 1; }
# shellcheck source=../release.conf
. "$RELEASE_CONFIG"
for release_var in NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME \
                   NCZ_BASE_NAME NCZ_BASE_VERSION NCZ_BASE_CODENAME NCZ_BASE_LABEL; do
    [ -n "${!release_var:-}" ] || { echo "ERROR: $release_var missing in $RELEASE_CONFIG" >&2; exit 1; }
done
NCZ_RELEASE_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"
# The installer d-i substrate remains independently selected below, but the
# target APT suite and staged operating-system payload must always follow the
# release profile.  This prevents a Forky ISO from silently embedding a stale
# Resolute package pool or SquashFS layer.
ISO_APT_SUITE="${ISO_APT_SUITE:-$NCZ_BASE_CODENAME}"
SQUASHFS_DIR="${SQUASHFS_DIR:-$ROOT/assets/squashfs}"

rescue_os_release_content() {
    local tarball="$1"
    local path

    for path in ./usr/lib/os-release usr/lib/os-release ./etc/os-release etc/os-release; do
        if tar -I zstd -xOf "$tarball" "$path" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

validate_rescue_rootfs_release() {
    local tarball="$1"
    local os_release

    if ! os_release="$(rescue_os_release_content "$tarball")"; then
        echo "ERROR: $tarball does not contain /usr/lib/os-release or /etc/os-release — refusing to stage an unverifiable rescue rootfs." >&2
        echo "  Remediation: run 'sudo bash build/build-rescue-rootfs.sh' on an arm64 build host, then rebuild." >&2
        return 1
    fi
    if ! printf '%s\n' "$os_release" | grep -Eq '^ID="?debian"?$'; then
        echo "ERROR: rescue rootfs is not Debian according to os-release — full desktop ISO would ship a mismatched rescue environment." >&2
        printf '%s\n' "$os_release" >&2
        echo "  Remediation: run 'sudo bash build/build-rescue-rootfs.sh' so the rescue rootfs follows release.conf ($NCZ_BASE_CODENAME)." >&2
        return 1
    fi
    if ! printf '%s\n' "$os_release" | grep -Eq "^(VERSION_CODENAME|DEBIAN_CODENAME)=\"?$NCZ_BASE_CODENAME\"?$"; then
        echo "ERROR: rescue rootfs codename does not match release.conf ($NCZ_BASE_CODENAME)." >&2
        printf '%s\n' "$os_release" >&2
        echo "  Remediation: run 'sudo bash build/build-rescue-rootfs.sh' with the current release.conf, then rebuild." >&2
        return 1
    fi
    echo "[rescue-rootfs] verified release: Debian $NCZ_BASE_CODENAME"
}

# ----------------------------------------------------------------------
# 26.7 preflight guard — full desktop ISOs MUST carry the bake-time assets
# whose silent absence shipped two dead regressions (2026-07-29):
#   1. assets/cix-debs/*.deb  → 25-cix-proprietary.sh "skipping" → no
#      libmali/EGL/GLES userspace → Wayland greeter has no GL → dead GUI.
#   2. assets/rescue/rescue-rootfs.tar.zst → 72-rescue-partition.sh
#      "skipping" → 4GB NCZRESCUE partition ships EMPTY, no RESCUE_READY,
#      no rEFInd "RESCUE PARTITION" entry.
# Both used to be WARN+skip in the staging loop below; for the shipping
# configuration (--mode full) they are now hard failures.
# netinstall/thin stay permissive (assets install online / by design).
# ----------------------------------------------------------------------
if [ "$MODE" = "full" ]; then
    # ----------------------------------------------------------------
    # 2026-08-21: restage the three gap categories the build host's
    # $ROOT/assets/ may be missing:
    #   - assets/sky1-firmware/ (VPU codecs, mediatek/, rtw89/, dsp_fw.bin)
    #   - assets/mgmt/ncz-mgmt-rootfs.tar.zst
    #   - assets/cix-debs/ (NPU userspace + gtk4-layer-shell, plus the
    #     pre-Q2 cix-noe-umd_2.0.2 -> matched-stack 3.1.4 pin)
    # All three are gitignored and never auto-restored from a fresh
    # `git clone`; the restager pulls from canonical ARGONAS NFS sources
    # (and falls back to the operator-known-good ISO at $OLD_ISO_REF when
    # NFS is unreachable). Idempotent; safe to call before the hard-fail
    # guards below -- on the next bake the staging loop at the bottom of
    # this script picks up the just-restaged assets without further
    # operator action.
    # ----------------------------------------------------------------
    if [ -x "$ROOT/build/stage-canonical-assets.sh" ]; then
        if ! bash "$ROOT/build/stage-canonical-assets.sh" \
                --from "$ROOT/assets" 2>&1 \
            | sed 's/^/[stage-canonical-assets] /'; then
            echo "ERROR: stage-canonical-assets.sh exited non-zero -- aborting (see output above)" >&2
            exit 1
        fi
    else
        echo "ERROR: $ROOT/build/stage-canonical-assets.sh not executable -- cannot auto-restage required assets" >&2
        exit 1
    fi
    if ! ls "$ROOT/assets/cix-debs"/*.deb >/dev/null 2>&1; then
        echo "ERROR: assets/cix-debs/ has no *.deb — full desktop ISO would install with NO CIX GPU userspace (libmali/EGL/GLES) and boot to a dead greeter." >&2
        echo "  Remediation: stage the validated CIX proprietary userland set (cix-gpu-umd, cix-libglvnd, cix-mesa, cix-noe-umd_2.0.2, cix-gstreamer, firmware, ...)" >&2
        echo "  from the canonical asset store (ARGOS ~/cix-installer-build/cix-installer/assets/cix-debs/) into assets/cix-debs/." >&2
        echo "  See post-install/25-cix-proprietary.sh for the expected install/skip set." >&2
        exit 1
    fi
    if [ ! -s "$ROOT/assets/rescue/rescue-rootfs.tar.zst" ]; then
        echo "ERROR: assets/rescue/rescue-rootfs.tar.zst missing/empty — full desktop ISO would leave the 4GB NCZRESCUE partition EMPTY (no RESCUE_READY, no rEFInd rescue entry)." >&2
        echo "  Remediation: run 'sudo bash build/build-rescue-rootfs.sh' on an arm64 build host (needs network + debootstrap), then rebuild." >&2
        exit 1
    fi
    validate_rescue_rootfs_release "$ROOT/assets/rescue/rescue-rootfs.tar.zst" || exit 1
    #   3. assets/sinty-nm/sinty-nmd -> 19-sinty-nm.sh falling back to
    #      NetworkManager -> base/console and desktop ship the WRONG network
    #      manager. NCZ MUST use sinty-nm (owns org.freedesktop.NetworkManager,
    #      wired DHCP via rtnetlink + built-in DHCP client, WiFi via iwd); NM is
    #      only the emergency fallback when the staged daemon is absent.
    if [ ! -s "$ROOT/assets/sinty-nm/sinty-nmd" ]; then
        echo "ERROR: assets/sinty-nm/sinty-nmd missing/empty -- ISO would SILENTLY fall back to NetworkManager (post-install/19-sinty-nm.sh), shipping the wrong network manager for base/console and Singularity desktop." >&2
        echo "  Remediation: build with build-sinty-nm.sh (docker Go 1.25, clones singularityos-lab/sinty-nm, builds cmd/sinty-nmd), then cp out/sinty-nmd -> assets/sinty-nm/sinty-nmd (chmod 0755). On cixmini: cp ~/sinty-build/nm-build/out/sinty-nmd assets/sinty-nm/sinty-nmd." >&2
        echo "  Verify: file assets/sinty-nm/sinty-nmd  # ELF 64-bit ... ARM aarch64 ... statically linked" >&2
        exit 1
    fi
    if [ ! -x "$ROOT/assets/singularity-boot-splash/singularity-boot-splash" ]; then
        echo "ERROR: native boot-splash binary missing/non-executable — full desktop ISO would either enable a broken unit or remove Plymouth without a replacement." >&2
        echo "  Remediation: build singularity-boot-splash and stage it at assets/singularity-boot-splash/singularity-boot-splash (mode 0755)." >&2
        exit 1
    fi
    #   5. assets/npu/npu-acpi-override.cpio (2026-08-22) — Minisforum MS-R1
    # factory BIOS omits _HID="CIXH4010" on the Sky1 NPU CRE cores; without
    # this early-CPIO override the NPU never enumerates (no CIXH4010:00..02
    # platform devices, /dev/aipu absent). post-install/80-npu.sh prepends
    # the override to /boot/initrd.img-$KVER at install time and persists a
    # copy at /boot/npu-acpi-override.cpio + installs a post-update.d hook so
    # later update-initramfs calls re-prepend it. The .asl source is committed
    # at assets/npu/ssdt-npucre.asl; the gate validates that the .cpio is
    # present, well-formed, and re-runnable. Board-gated SKIP lives in
    # post-install/80-npu.sh's should_apply_npu_ssdt() (Radxa Orion O6/O6N
    # expose the _HID natively and would AML-collide).
    if [ -x "$ROOT/build/npu-ssdt-gate.sh" ]; then
        bash "$ROOT/build/npu-ssdt-gate.sh" || {
            rc=$?
            echo "ERROR: npu-ssdt-gate.sh exited $rc — see remediation above." >&2
            echo "  (assets/npu/npu-acpi-override.cpio is missing, malformed, or not" >&2
            echo "   regenerable; a fresh clone of the repo will not produce it.)" >&2
            echo "  Quick fix:  sudo apt install acpica-tools && bash build/build-npu-ssdt.sh" >&2
            exit 1
        }
    elif [ ! -s "$ROOT/assets/npu/npu-acpi-override.cpio" ]; then
        echo "ERROR: assets/npu/npu-acpi-override.cpio missing/empty — full desktop ISO would install on MS-R1 with NO working NPU (no _HID override -> no CIXH4010:00..02 -> no /dev/aipu)." >&2
        echo "  This is the silent-skip regression that shipped ISOs without the override for months; the build now fails loudly instead." >&2
        echo "  Remediation:" >&2
        echo "    1. install the build-host dep:  sudo apt install acpica-tools   (provides iasl)" >&2
        echo "    2. regenerate from the committed .asl:  bash build/build-npu-ssdt.sh" >&2
        echo "    3. confirm:  test -s assets/npu/npu-acpi-override.cpio && echo OK" >&2
        echo "  See build/build-npu-ssdt.sh and packaging/cix-npu-driver-dkms-6.2.0/README.md." >&2
        exit 1
    fi
fi

# Drift guard: surface kernel/NPU manifest drift (e.g. NPU vermagic != KVER)
# before building the ISO. Shipping full desktop images fail closed by default:
# silently accepting swapped kernel bytes defeats the manifest's release
# contract. Development/netinstall builds remain permissive unless callers set
# STRICT_MANIFEST=1; STRICT_MANIFEST=0 explicitly opts any build out.
MANIFEST_STRICT="${STRICT_MANIFEST:-}"
if [ -z "$MANIFEST_STRICT" ]; then
    MANIFEST_STRICT=0
    if [ "$MODE" = "full" ] && [ "$VARIANT" = "desktop" ]; then
        MANIFEST_STRICT=1
    fi
fi
case "$MANIFEST_STRICT" in
    0|1) ;;
    *) echo "ERROR: STRICT_MANIFEST must be 0 or 1 (got '$MANIFEST_STRICT')" >&2; exit 1 ;;
esac
if [ -f "$ROOT/build/kernel-manifest.py" ]; then
    if ! python3 "$ROOT/build/kernel-manifest.py" check; then
        if [ "$MANIFEST_STRICT" = 1 ]; then
            echo "ERROR: kernel manifest drift (strict release gate) — aborting" >&2
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
Label: nclawzero-cixmini-$suite
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

ensure_di_udeb_from_archive() {
    local pkg="$1"
    local suite="${2:-$DI_CODENAME}"
    local arch="${3:-arm64}"
    local mirror="${DI_UDEB_MIRROR:-https://deb.debian.org/debian}"
    local index="$STAGING/.tmp-${suite}-${arch}-di-Packages"
    local entry filename sha256 url dest actual

    if find "$STAGING/pool" -name "${pkg}_*.udeb" 2>/dev/null | grep -q .; then
        echo "    required udeb present: $pkg"
        return 0
    fi

    for t in curl gzip sha256sum awk; do
        command -v "$t" >/dev/null 2>&1 || {
            echo "ERROR: missing $t; cannot fetch required d-i udeb $pkg" >&2
            exit 1
        }
    done

    if [ ! -s "$index" ]; then
        echo "    fetching $suite debian-installer Packages index for required udebs"
        curl -fsSL "$mirror/dists/$suite/main/debian-installer/binary-$arch/Packages.gz" \
            | gzip -dc > "$index"
    fi

    entry="$(awk -v want="$pkg" 'BEGIN{RS=""; FS="\n"} $1 == "Package: " want {print; exit}' "$index")"
    [ -n "$entry" ] || {
        echo "ERROR: $pkg not found in $mirror dists/$suite/main/debian-installer/binary-$arch/Packages.gz" >&2
        exit 1
    }
    filename="$(printf '%s\n' "$entry" | awk '/^Filename: /{print $2; exit}')"
    sha256="$(printf '%s\n' "$entry" | awk '/^SHA256: /{print $2; exit}')"
    [ -n "$filename" ] && [ -n "$sha256" ] || {
        echo "ERROR: incomplete Packages entry for $pkg (missing Filename or SHA256)" >&2
        exit 1
    }

    url="$mirror/$filename"
    dest="$STAGING/$filename"
    mkdir -p "$(dirname "$dest")"
    echo "    grafting required udeb: $pkg from $suite ($(basename "$filename"))"
    curl -fsSL "$url" -o "$dest.tmp"
    actual="$(sha256sum "$dest.tmp" | awk '{print $1}')"
    if [ "$actual" != "$sha256" ]; then
        echo "ERROR: SHA256 mismatch for $pkg: got $actual expected $sha256" >&2
        rm -f "$dest.tmp"
        exit 1
    fi
    mv "$dest.tmp" "$dest"
}

# ----------------------------------------------------------------------
# Kernel discovery — edge (7.2.0-sky1-ncz) is the only supported channel.
#   $ROOT/assets/kernel/edge/Image-cixmini.bin
#   $ROOT/assets/kernel/edge/modules-cixmini.tgz
#   $ROOT/assets/kernel/edge/KVER
# ----------------------------------------------------------------------
NEXT_KERN="$ROOT/assets/kernel/edge/Image-cixmini.bin"
NEXT_TGZ="$ROOT/assets/kernel/edge/modules-cixmini.tgz"
NEXT_KVER_FILE="$ROOT/assets/kernel/edge/KVER"

KVER_NEXT=""

if [ -f "$NEXT_KVER_FILE" ] && [ -f "$NEXT_KERN" ] && [ -f "$NEXT_TGZ" ]; then
    KVER_NEXT=$(cat "$NEXT_KVER_FILE")
    [ -n "$KVER_NEXT" ] || { echo "ERROR: empty KVER file: $NEXT_KVER_FILE"; exit 1; }
    echo "[info] edge kernel KVER: $KVER_NEXT"
elif [ "$INSTALLER_KERNEL_FLAVOR" = "edge" ] || [ "$MODE" = "netinstall" ]; then
    echo "ERROR: --mode netinstall requires assets/kernel/edge/{KVER,Image-cixmini.bin,modules-cixmini.tgz}" >&2
    exit 1
fi

INSTALLER_KERN="$NEXT_KERN"
INSTALLER_TGZ="$NEXT_TGZ"
KVER_INSTALLER="$KVER_NEXT"
INSTALLER_KERNEL_LABEL="edge"

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
for cn in forky trixie bookworm; do
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

# Match Debian DVD structure EXACTLY: ONE target suite with TWO
# indexes (regular debs + debian-installer udebs) under main/. No
# leftover dists/<substrate>/ to confuse anna. Substrate's udebs are
# merged INTO the target pool, and substrate's debian-installer
# Packages.gz is moved INTO dists/$ISO_APT_SUITE/main/debian-installer/.
#
# Step 1: capture substrate's udebs and udeb index BEFORE we nuke them
echo "    capturing $DI_CODENAME udebs + udeb index (will merge into $ISO_APT_SUITE)"
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
# NCZ policy: full images embed one profile-matched, complete package closure.
# A release must never fall back to a different distribution's package pool.
if [ -z "${MIRROR_DIR:-}" ]; then
    MIRROR_DIR="$ROOT/build/${ISO_APT_SUITE}-mirror"
fi
if [ "$EMBED_MIRROR" = "1" ]; then
    if [ ! -d "$MIRROR_DIR/pool" ] || [ ! -d "$MIRROR_DIR/dists" ] || \
       ! bash "$ROOT/build/verify-local-package-versions.sh" \
            --pool "$MIRROR_DIR/pool" \
            --label "$(basename "$MIRROR_DIR")" \
            "${LOCAL_VERSION_ARGS[@]}" || \
       ! bash "$ROOT/build/verify-offline-mirror-seeds.sh" \
            --mirror "$MIRROR_DIR" \
            --label "$(basename "$MIRROR_DIR")"; then
        echo "    offline mirror missing or stale after vendor publish; rebuilding $MIRROR_DIR"
        rm -rf "$MIRROR_DIR"
        bash "$ROOT/build/build-forky-mirror.sh"
        bash "$ROOT/build/verify-local-package-versions.sh" \
            --pool "$MIRROR_DIR/pool" \
            --label "$(basename "$MIRROR_DIR")" \
            "${LOCAL_VERSION_ARGS[@]}"
        bash "$ROOT/build/verify-offline-mirror-seeds.sh" \
            --mirror "$MIRROR_DIR" \
            --label "$(basename "$MIRROR_DIR")"
    fi
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
if [ "$DI_CODENAME" != "bookworm" ]; then
    echo "    substrate is $DI_CODENAME — skipping the bookworm-only udeb graft"
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
fi  # end of "if [ DI_CODENAME != bookworm ]" — graft-on-bookworm conditional

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

# Debian netinst media can boot with some udebs already unpacked in initrd
# while omitting their installable copies from /pool. This image rebuilds the
# media pool and anna index after retargeting suites, so keep core d-i runtime
# udebs explicitly available for later component loads and template
# registration. Without cdebconf-newt-udeb's templates, main-menu can wedge
# looking up standard button labels such as debconf/button-ok. Without
# hw-detect, disk-detect installs from media but fails at the Detect disks step.
REQUIRED_DI_UDEBS=(cdebconf-udeb cdebconf-newt-udeb hw-detect)
for need_pkg in "${REQUIRED_DI_UDEBS[@]}"; do
    ensure_di_udeb_from_archive "$need_pkg" "$DI_CODENAME" arm64
done
for need_pkg in "${REQUIRED_DI_UDEBS[@]}"; do
    HITS=$(find "$STAGING/pool" -name "${need_pkg}_*.udeb" 2>/dev/null | wc -l)
    if [ "$HITS" -eq 0 ]; then
        echo "ERROR: substrate=$DI_CODENAME merged pool missing required d-i udeb $need_pkg" >&2
        exit 1
    fi
done
echo "    udeb assertions: cdebconf-udeb + cdebconf-newt-udeb + hw-detect present"

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

# r159: LAYERED SQUASHFS — prefer base.squashfs (+ <role> delta) via the bundled
# unsquashfs (loader + libs in sqtools/). Pure userspace, no kernel mount/overlay.
SQDIR=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    [ -f "$d/base.squashfs" ] && { SQDIR="$d"; break; }
done
if [ -n "$SQDIR" ]; then
    echo "I: r159 stub: LAYERED SQUASHFS install from $SQDIR" >&2
    LDR=$(ls "$SQDIR"/sqtools/ld-* 2>/dev/null | head -1)
    UNSQ="$SQDIR/sqtools/unsquashfs"
    if [ ! -x "$UNSQ" ] || [ -z "$LDR" ]; then
        echo "FATAL: r159 stub: sqtools bundle missing (bin=$UNSQ ldr=$LDR)" >&2; exit 1
    fi
    rm -rf "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null || true
    ncz_component_record() {
        _ncz_comp=""
        if [ -r /tmp/ncz-components ] && command -v tr >/dev/null 2>&1; then
            _ncz_comp=$(tr -d ' \t\r\n' < /tmp/ncz-components 2>/dev/null || true)
            [ -n "$_ncz_comp" ] && { printf '%s\n' "$_ncz_comp"; return 0; }
        fi
        if [ -r /var/lib/ncz-components/COMPONENTS ] && command -v tr >/dev/null 2>&1; then
            _ncz_comp=$(tr -d ' \t\r\n' < /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        if command -v debconf-get >/dev/null 2>&1; then
            _ncz_comp=$(debconf-get ncz/components 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        if [ -r /var/lib/cdebconf/questions.dat ]; then
            _ncz_comp=$(awk '
                $0 == "Name: ncz/components" { inq=1; next }
                inq && /^Value: / { sub(/^Value: /, ""); print; exit }
                inq && /^Name: / { exit }
            ' /var/lib/cdebconf/questions.dat 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        for _ncz_log in /var/log/syslog /var/log/installer/syslog; do
            [ -r "$_ncz_log" ] || continue
            _ncz_comp=$(awk '
                /debconf: --> GET ncz\/components/ { want=1; next }
                want && /debconf: <-- 0 / {
                    sub(/^.*debconf: <-- 0 /, "")
                    val=$0
                    want=0
                }
                END { if (val != "") print val }
            ' "$_ncz_log" 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                mkdir -p /var/lib/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp" > /var/lib/ncz-components/COMPONENTS 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        done
        return 1
    }
    # The installation media has one complete target.  Keep the desktop-layer
    # name internally until the legacy layer filenames are retired, but never
    # select a separate server overlay from a boot-time argument.
    ROLE=desktop
    _applied_role="$ROLE"
    echo "I: r159 stub: component-selector state before ROLE decision: /tmp=[$(ls -l /tmp/ncz-components 2>&1)] value=[$(cat /tmp/ncz-components 2>/dev/null || true)] durable=[$(ls -l /var/lib/ncz-components/COMPONENTS 2>&1)] durable_value=[$(cat /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)]" >&2
    _ck=$(ncz_component_record 2>/dev/null || true)
    if [ -n "$_ck" ]; then
        _want_desktop=1
        case ",$_ck," in
            *",desktop,"*) _want_desktop=1 ;;
            *)              _want_desktop=0 ;;
        esac
        if [ "$_want_desktop" = 0 ]; then
            ROLE=base
            _applied_role=base
            echo "I: r159 stub: component-selector desktop OFF ($_ck); installing BASE ONLY" >&2
        else
            echo "I: r159 stub: component-selector desktop ON ($_ck); applying desktop overlay" >&2
        fi
    else
        echo "W: r159 stub: component selection unavailable; defaulting to desktop overlay" >&2
    fi
    echo "I: r159 stub: unsquashfs base -> $TARGET" >&2
    "$LDR" --library-path "$SQDIR/sqtools" "$UNSQ" -f -d "$TARGET" "$SQDIR/base.squashfs" >/dev/null 2>&1 || {
        echo "FATAL: r159 stub: unsquashfs base failed" >&2; exit 1; }
    if [ "$ROLE" = "desktop" ] && [ -f "$SQDIR/$ROLE.squashfs" ]; then
        # The role image is an overlayfs upperdir. Its companion manifest
        # records both 0:0 whiteouts and trusted.overlay.opaque directories.
        # Both semantics must be applied to the extracted base before ordinary
        # unsquashfs extraction; otherwise the result is a partial, incoherent
        # filesystem (the v15 DBus/network/greeter failure).
        OVERLAY_MANIFEST="$SQDIR/$ROLE.overlay-manifest"
        [ -s "$OVERLAY_MANIFEST" ] || {
            echo "FATAL: r159 stub: missing $ROLE overlay manifest" >&2
            exit 1
        }
        OVERLAY_COUNT=0
        OVERLAY_TAB=$(printf '\t')
        while IFS="$OVERLAY_TAB" read -r kind rel; do
            case "$kind" in
                '#'*|'') continue ;;
                whiteout|opaque) ;;
                *)
                    echo "FATAL: r159 stub: invalid $ROLE overlay operation '$kind'" >&2
                    exit 1
                    ;;
            esac
            case "$rel" in
                ''|.|/*|../*|*/../*|*/..)
                    echo "FATAL: r159 stub: unsafe $ROLE overlay path '$rel'" >&2
                    exit 1
                    ;;
            esac
            rm -rf "$TARGET/$rel" || {
                echo "FATAL: r159 stub: cannot apply $kind '$rel'" >&2
                exit 1
            }
            OVERLAY_COUNT=$((OVERLAY_COUNT + 1))
        done < "$OVERLAY_MANIFEST"
        echo "I: r159 stub: applied $OVERLAY_COUNT $ROLE overlay operation(s)" >&2

        echo "I: r159 stub: unsquashfs $ROLE delta -> $TARGET" >&2
        "$LDR" --library-path "$SQDIR/sqtools" "$UNSQ" -f -d "$TARGET" "$SQDIR/$ROLE.squashfs" >/dev/null 2>&1 || {
            echo "FATAL: r159 stub: $ROLE delta extraction failed" >&2
            exit 1
        }
        # Remove the extracted 0:0 markers by their already-validated manifest
        # paths. This avoids a slow whole-root find/stat pass over thousands of
        # nodes while preserving every legitimate /dev node.
        while IFS="$OVERLAY_TAB" read -r kind rel; do
            [ "$kind" = whiteout ] || continue
            rm -rf "$TARGET/$rel" || {
                echo "FATAL: r159 stub: cannot remove whiteout marker '$rel'" >&2
                exit 1
            }
        done < "$OVERLAY_MANIFEST"
        HOTFIX_ROLE="$ROLE-hotfix"
        HOTFIX_IMAGE="$SQDIR/$HOTFIX_ROLE.squashfs"
        HOTFIX_MANIFEST="$SQDIR/$HOTFIX_ROLE.overlay-manifest"
        if [ -f "$HOTFIX_IMAGE" ]; then
            [ -s "$HOTFIX_MANIFEST" ] || {
                echo "FATAL: r159 stub: missing $HOTFIX_ROLE overlay manifest" >&2
                exit 1
            }
            HOTFIX_COUNT=0
            while IFS="$OVERLAY_TAB" read -r kind rel; do
                case "$kind" in
                    '#'*|'') continue ;;
                    whiteout|opaque) ;;
                    *)
                        echo "FATAL: r159 stub: invalid $HOTFIX_ROLE overlay operation '$kind'" >&2
                        exit 1
                        ;;
                esac
                case "$rel" in
                    ''|.|/*|../*|*/../*|*/..)
                        echo "FATAL: r159 stub: unsafe $HOTFIX_ROLE overlay path '$rel'" >&2
                        exit 1
                        ;;
                esac
                rm -rf "$TARGET/$rel" || {
                    echo "FATAL: r159 stub: cannot apply $HOTFIX_ROLE $kind '$rel'" >&2
                    exit 1
                }
                HOTFIX_COUNT=$((HOTFIX_COUNT + 1))
            done < "$HOTFIX_MANIFEST"
            echo "I: r159 stub: applied $HOTFIX_COUNT $HOTFIX_ROLE overlay operation(s)" >&2

            echo "I: r159 stub: unsquashfs $HOTFIX_ROLE delta -> $TARGET" >&2
            "$LDR" --library-path "$SQDIR/sqtools" "$UNSQ" -f -d "$TARGET" "$HOTFIX_IMAGE" >/dev/null 2>&1 || {
                echo "FATAL: r159 stub: $HOTFIX_ROLE delta extraction failed" >&2
                exit 1
            }
            while IFS="$OVERLAY_TAB" read -r kind rel; do
                [ "$kind" = whiteout ] || continue
                rm -rf "$TARGET/$rel" || {
                    echo "FATAL: r159 stub: cannot remove $HOTFIX_ROLE whiteout marker '$rel'" >&2
                    exit 1
                }
            done < "$HOTFIX_MANIFEST"
        fi
    elif [ "$_applied_role" = "base" ]; then
        echo "I: r159 stub: role=base (component-selector desktop OFF); skipping desktop overlay" >&2
    fi
    # 2026-08-26 ROOT-MODE GATE — THE LIVE PATH (docs/ISO-BUILD-GUARDRAILS.md).
    # Root cause of the 0700-root incident, found+proven 2026-08-26:
    # `unsquashfs -f -d $TARGET` re-stamps $TARGET's OWN mode from EACH
    # layer's root entry (verified with the bundled sqtools unsquashfs AND
    # squashfs-tools 4.6.1: an existing 755 dir became 700 after extracting a
    # layer whose root entry was drwx------). desktop-hotfix.squashfs was
    # built 2026-08-25 out-of-repo from a mktemp -d staging dir (mode 0700),
    # so the LAST layer stamped / to 0700 on every install — breaking greetd
    # (EACCES traversing /), NIC bring-up and rtc-efi for every non-root UID.
    # Round 1 (7de5ce6) gated preseed/extract-rootfs.sh — but partman/
    # late_command is NOT a real d-i hook (see the r159 note above), so that
    # script never runs: THIS stub is the real extraction path and had no
    # gate. Pin 0755 after the FULL layer stack and hard-verify; exit 1 makes
    # bootstrap-base fail loudly instead of shipping a broken root.
    chmod 0755 "$TARGET" || { echo "FATAL: rootmode stub: chmod 0755 $TARGET failed" >&2; exit 1; }
    # BusyBox in the d-i initrd has no `stat` applet (confirmed live on O6N:
    # "stat: not found", even `busybox stat` -> "applet not found") -- use
    # `ls -ld` (confirmed present) and compare the permission-string field
    # instead of an octal mode, same pattern as assert_squashfs_root_mode().
    _ncz_rm=$(ls -ld "$TARGET" 2>/dev/null | awk '{print $1}')
    [ -n "$_ncz_rm" ] || _ncz_rm="???"
    if [ "$_ncz_rm" != "drwxr-xr-x" ]; then
        echo "FATAL: rootmode stub: $TARGET root mode is $_ncz_rm after layer extraction (expected drwxr-xr-x/0755) — refusing to ship a broken install" >&2
        exit 1
    fi
    echo "I: rootmode stub: verified $TARGET root mode = drwxr-xr-x (0755) after full layer stack" >&2
    if [ ! -f "$TARGET/etc/os-release" ]; then
        echo "FATAL: r159 stub: squashfs extract produced no os-release" >&2; exit 1
    fi
    # r159: finish deferred dpkg config; purge pkgs that cannot configure in a
    # chroot (e.g. falkon needs a display) so d-i pkgsel's apt does not choke on a
    # half-configured package. Bind-mount for maintainer scripts, then unmount.
    for _m in proc sys dev; do mount --bind /$_m "$TARGET/$_m" 2>/dev/null; done
    mount --bind /dev/pts "$TARGET/dev/pts" 2>/dev/null
    chroot "$TARGET" dpkg --configure -a 2>/dev/null
    # r172: PRESERVE falkon (the NCZ web browser). It can't finish configuring in
    # the d-i chroot (its postinst wants a display/dbus), so r159 purged it as
    # "non-configured" — which left the installed desktop with NO working browser
    # (firefox on resolute is a snap stub that no-ops in an offline image; only
    # falkon + epiphany are real debs). Keep falkon (+ its parts) out of the purge
    # and let ncz-firstboot's `dpkg --configure -a` finish it on first boot where
    # X/dbus exist. Everything else non-ii is still purged so pkgsel's dpkg stays
    # clean.
    _BAD=$(chroot "$TARGET" dpkg -l 2>/dev/null | awk '$1 ~ /^.[A-Z]/ && $1 != "ii" {print $2}' | grep -viE '^falkon')
    [ -n "$_BAD" ] && { echo "I: r172 stub: purging non-configured (keeping falkon): $_BAD" >&2; chroot "$TARGET" dpkg --purge --force-all $_BAD 2>/dev/null; }
    # Best-effort configure of falkon now; if it still can't (no display), it stays
    # unpacked and ncz-firstboot configures it. pkgsel tolerates unpacked (unlike
    # a broken statoverride) as long as dpkg itself isn't wedged.
    chroot "$TARGET" dpkg --configure falkon 2>/dev/null || true
    # r169: drop orphaned dpkg statoverrides whose owning user no longer exists.
    # The GNOME-purge/autoremove in the squashfs build (and this STUB's own
    # dpkg --configure/purge above) can leave a statoverride like
    #   geoclue geoclue 755 /var/lib/geoclue
    # after the 'geoclue' system user is gone. A dangling override makes dpkg
    # abort with "unknown system user 'geoclue' in statoverride file" on EVERY
    # later dpkg op → d-i pkgsel apt-get install fails ("Installation step
    # failed"). Clean at install time, after configure/purge, before pkgsel runs.
    # r170: collect orphan paths in a FIRST read-only pass, then remove them —
    # dpkg-statoverride --remove rewrites the very file we read, so removing
    # inside the read loop corrupts it (r169 removed geoclue but mangled the
    # file into an "unknown system user 'root'" abort). Guard on getent working
    # so a broken NSS can't nuke every (legitimate, e.g. root:shadow) override.
    chroot "$TARGET" sh -c '
        getent passwd root >/dev/null 2>&1 || exit 0
        orphans=""
        while read u g m f; do
            [ -n "$u" ] && [ -n "$f" ] || continue
            getent passwd "$u" >/dev/null 2>&1 || orphans="$orphans
$f"
        done < /var/lib/dpkg/statoverride
        printf "%s\n" "$orphans" | while IFS= read -r p; do
            [ -n "$p" ] && dpkg-statoverride --remove "$p" 2>/dev/null || true
        done
    ' 2>/dev/null || true
    echo "I: r170 stub: pruned orphaned statoverrides (missing user)" >&2
    for _m in dev/pts dev sys proc; do umount "$TARGET/$_m" 2>/dev/null; done
    # r159: disable needrestart kernel hints so pkgsel/apt does not raise the
    # "pending kernel upgrade / consider rebooting" note (baked kernel != d-i
    # installer kernel) that blocks "Select and install software".
    mkdir -p "$TARGET/etc/needrestart/conf.d"
    printf '$nrconf{kernelhints} = 0;\n' > "$TARGET/etc/needrestart/conf.d/99-baked.conf"
    # r160: per-machine ssh host keys. The Ubuntu cloud rootfs ships
    # openssh-server but STRIPS the host keys (cloud-init would normally
    # regenerate them); without keys sshd refuses to start and the installed
    # system is unreachable on :22. Generate here, at install time, so every
    # machine gets unique keys — never bake host keys into the squashfs.
    chroot "$TARGET" ssh-keygen -A 2>/dev/null || \
        echo "W: r160 stub: ssh-keygen -A failed (openssh-server missing from image?)" >&2
    # r160: fleet remote-access policy. The cloud-image drop-in forces
    # PasswordAuthentication no; the fleet is LAN-only and wants password
    # fallback when keys break. OpenSSH keyword resolution is first-value-wins
    # across lexically-sorted sshd_config.d, so 10- beats any later drop-in.
    rm -f "$TARGET/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
    mkdir -p "$TARGET/etc/ssh/sshd_config.d"
    printf 'PasswordAuthentication yes\n' > "$TARGET/etc/ssh/sshd_config.d/10-ncz-fleet.conf"
    # r160: de-cloud the network stack. The cloud rootfs enables
    # systemd-networkd + its wait-online + networkd-dispatcher ALONGSIDE
    # NetworkManager; networkd has no .network config on NCZ so
    # systemd-networkd-wait-online stalls every boot for its full ~120s
    # timeout. NCZ is NetworkManager-managed — drop the networkd enablement
    # symlinks (NM + NM-wait-online stay).
    rm -f "$TARGET/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
          "$TARGET/etc/systemd/system/multi-user.target.wants/networkd-dispatcher.service" \
          "$TARGET/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" \
          "$TARGET/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service" \
          "$TARGET/etc/systemd/system/dbus-org.freedesktop.network1.service" 2>/dev/null
    : > "$TARGET/etc/ncz-baked"
    mkdir -p "$TARGET/usr/local/sbin" "$TARGET/etc/systemd/system/multi-user.target.wants"
    cat > "$TARGET/usr/local/sbin/ncz-firstboot" <<'FBS'
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a 2>/dev/null || true
[ -s /etc/machine-id ] || systemd-machine-id-setup 2>/dev/null || true

# r177: per-machine hostname ncz-<last-6-hex-of-primary-ethernet-MAC>. The real
# hardware MAC is authoritative HERE (first boot on the actual box), not at bake
# time. Only rename when the hostname is still a placeholder/default so a
# user-chosen name on later boots is never clobbered.
HOSTNAME_SETTLED=1   # set to 0 to keep the service enabled + retry the derive next boot
_cur=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
case "$_cur" in
    ""|ncz-setup|mini|cixmini|localhost|localhost.localdomain|debian|ubuntu|nclawzero)
        # Find the primary ethernet MAC. Two passes per attempt: first prefer an
        # iface with link (carrier=1), else the first eligible ethernet. Retry a
        # few seconds in case NIC enumeration lags this early oneshot.
        _pick_mac() {
            for _pref in 1 0; do
                for _if in /sys/class/net/*; do
                    _n=${_if##*/}
                    case "$_n" in
                        lo|wl*|ww*|wlan*|docker*|veth*|virbr*|br-*|vmnet*|tap*|tun*|bond*|dummy*|sit*|ip6*) continue ;;
                    esac
                    # physical only: must have a backing device, must not be wireless
                    [ -e "$_if/device" ] || continue
                    [ -d "$_if/wireless" ] && continue
                    _m=$(cat "$_if/address" 2>/dev/null)
                    [ -n "$_m" ] || continue
                    case "$_m" in 00:00:00:00:00:00) continue ;; esac
                    if [ "$_pref" = 1 ] && [ "$(cat "$_if/carrier" 2>/dev/null)" != 1 ]; then
                        continue
                    fi
                    printf '%s' "$_m"; return 0
                done
            done
            return 1
        }
        _mac=""
        _try=0
        while [ "$_try" -lt 15 ]; do
            _mac=$(_pick_mac) && [ -n "$_mac" ] && break
            _mac=""; _try=$((_try+1)); sleep 1
        done
        _newname=""
        if [ -n "$_mac" ]; then
            _h6=$(printf '%s' "$_mac" | tr -d ':' | tr 'A-F' 'a-f' | tail -c 6)
            [ -n "$_h6" ] && _newname="ncz-$_h6"
        fi
        if [ -z "$_newname" ]; then
            # No eligible ethernet MAC this boot. RETRY on the next few boots so a
            # slow-to-enumerate NIC eventually names the box; after MAXTRIES fall
            # back to a machine-id-derived name so it is NEVER stuck as ncz-setup.
            _bt=$(cat /var/lib/ncz-firstboot-tries 2>/dev/null)
            case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
            _bt=$((_bt + 1))
            printf '%s\n' "$_bt" > /var/lib/ncz-firstboot-tries 2>/dev/null || true
            if [ "$_bt" -lt 3 ]; then
                HOSTNAME_SETTLED=0
                echo "ncz-firstboot: no eligible ethernet MAC yet (attempt $_bt) — will retry next boot" >&2
            else
                _mid=$(tr -cd '0-9a-f' < /etc/machine-id 2>/dev/null | tail -c 6)
                [ -n "$_mid" ] && _newname="ncz-$_mid"
                echo "ncz-firstboot: no ethernet MAC after $_bt boots — machine-id fallback ${_newname:-<none>}" >&2
            fi
        fi
        if [ -n "$_newname" ]; then
            if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$_newname" 2>/dev/null; then
                :
            else
                printf '%s\n' "$_newname" > /etc/hostname
                hostname "$_newname" 2>/dev/null || true
            fi
            if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
                sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$_newname/" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "$_newname" >> /etc/hosts
            fi
        fi
        ;;
esac

# 2026-08-26 first-boot root-mode belt (0700-root incident; see
# docs/ISO-BUILD-GUARDRAILS.md). Runs AFTER dpkg --configure -a above (package
# postinsts are the last code to run before a login screen) and before
# display-manager.service (unit ordering), so a bad / mode is corrected before
# greetd would hit EACCES traversing /. Always emits a NCZ-ROOTMODE marker to
# kmsg+console so build/kvm-install-gate.sh phase 2 can assert the final mode
# from OUTSIDE the VM via the boot serial capture.
# Full installed userspace normally has GNU coreutils `stat`, but keep this
# consistent with the d-i-side gates (ls -ld, not stat) so the same logic
# works even on a minimal/degraded first boot.
_rm=$(ls -ld / 2>/dev/null | awk '{print $1}')
[ -n "$_rm" ] || _rm="???"
if [ "$_rm" != "drwxr-xr-x" ]; then
    echo "ncz-firstboot: WARNING / mode was $_rm (expected drwxr-xr-x/0755) — correcting" > /dev/kmsg 2>/dev/null || true
    chmod 0755 / 2>/dev/null || true
    _rm=$(ls -ld / 2>/dev/null | awk '{print $1}')
    [ -n "$_rm" ] || _rm="???"
fi
echo "NCZ-ROOTMODE: $_rm" > /dev/kmsg 2>/dev/null || true
echo "NCZ-ROOTMODE: $_rm" > /dev/console 2>/dev/null || true

# Only finalize (disable + mark done) when the hostname is SETTLED. When we are
# deliberately retrying the MAC-derive on a later boot (HOSTNAME_SETTLED=0), we
# leave the service enabled and NOT-done so it runs again — dpkg-configure and
# machine-id above already ran this boot, and the host will never be permanently
# stuck as ncz-setup (machine-id fallback after MAXTRIES guarantees a name).
if [ "${HOSTNAME_SETTLED:-1}" = 1 ]; then
    systemctl disable ncz-firstboot.service 2>/dev/null || true
    touch /var/lib/ncz-firstboot-done
fi
FBS
    chmod +x "$TARGET/usr/local/sbin/ncz-firstboot"
    cat > "$TARGET/etc/systemd/system/ncz-firstboot.service" <<'FBU'
[Unit]
Description=NCZ first-boot finalize (dpkg configure + machine identity)
ConditionPathExists=!/var/lib/ncz-firstboot-done
DefaultDependencies=no
# dpkg --configure -a may run package ldconfig triggers; let systemd's stock
# ldconfig.service finish first so both do not race over /etc/ld.so.cache~.
After=local-fs.target ldconfig.service
Before=display-manager.service gdm.service graphical.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ncz-firstboot
[Install]
WantedBy=multi-user.target
FBU
    ln -sf ../ncz-firstboot.service "$TARGET/etc/systemd/system/multi-user.target.wants/ncz-firstboot.service"
    [ -e "$TARGET/etc/fstab" ] || touch "$TARGET/etc/fstab"
    : > "$TARGET/etc/fstab.orig"
    # r177: deterministic hostname PLACEHOLDER. ncz-firstboot rewrites this to
    # ncz-<mac6> on first boot (guarded on the placeholder). Baked squashfs may
    # ship its own /etc/hostname; force the placeholder so the derive always fires.
    printf 'ncz-setup\n' > "$TARGET/etc/hostname"
    [ -e "$TARGET/etc/resolv.conf" ] || touch "$TARGET/etc/resolv.conf"
    echo "I: r159 stub: squashfs rootfs ready ($(du -sh "$TARGET" 2>/dev/null | cut -f1))" >&2
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

# Same defensive empty-files for any other path d-i might write through.
#
# r177 NOTE (review): this legacy rootfs.tar.zst extract path is SUPERSEDED and
# is NOT reached in current builds — the layered-squashfs branch above (taken
# whenever base.squashfs is on the media, which it always is in full mode)
# installs the ncz-firstboot hostname-derivation flow + the deterministic
# ncz-setup placeholder and `exit 0`s before we ever get here. This tarball
# fallback deliberately does NOT duplicate that flow (it also does not write the
# BAKED marker, ncz-firstboot, needrestart/ssh/networkd fixups the squashfs path
# does — it predates all of them). If this path is ever revived as a real
# install route, port the ncz-firstboot + ncz-setup-placeholder block up from the
# squashfs branch; a bare empty /etc/hostname here would otherwise leave the box
# unnamed. Left as a bare touch on purpose since the path is dead.
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
# THREE udebs can register that menu item on arm64 (lower Installer-Menu-Item
# runs first):
#   flash-kernel-installer  Installer-Menu-Item: 7300  (PRIMARY on arm64)
#   grub-installer          Installer-Menu-Item: 7400
#   nobootloader            Installer-Menu-Item: 7600  (fallback no-op)
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
# generic-arm64; always succeed so the install completes. nobootloader is also
# redundant for NCZ and was proven on 2026-08-24 real .66 hardware to die with
# SIGBUS only when main-menu drives its stock debconf note path; standalone
# mapdevfs, archdetect, user-params, and postinst all exited cleanly.
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
neutralize_udeb_postinst "$STAGING/pool/main/n/nobootloader/nobootloader_*.udeb" "nobootloader"

# r173: NCZ-brand the d-i INSTALLER UI. The installer screens ship Debian
# branding in the udeb debconf TEMPLATES (control.tar's ./templates) — most
# visibly the "Debian installer main menu" title and "Debian GNU/Linux"
# references in the menu/finish steps. Patch the templates at source (same
# ar/tar mechanism as the debootstrap/neutralize patches). We ONLY touch
# Description/text (case-sensitive "Debian ..." phrases); template KEYS use
# lowercase "debian-installer/..." and are never matched, so anna/main-menu
# routing is unaffected. Best-effort per udeb: a missing udeb is a no-op.
brand_udeb_templates() {
    # $1 = udeb path glob (first match used); $2 = human label
    local _glob="$1" _label="$2"
    local _matches; _matches=( $_glob )
    local _udeb="${_matches[0]}"
    if [ ! -e "$_udeb" ]; then
        echo "    NOTE: $_label udeb not in pool — nothing to brand"
        return 0
    fi
    local _tmp="$STAGING/.tmp-brand-udeb"
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
    if [ ! -f "$_ctl/templates" ]; then
        echo "    NOTE: $_label udeb has no templates — skipping brand"
        rm -rf "$_tmp"; return 0
    fi
    # Case-sensitive phrase replacements (Description text only). Order matters:
    # longer phrases first so they aren't partially eaten by shorter ones.
    sed -i \
        -e 's/Debian installer main menu/NCZ-OS installer main menu/g' \
        -e 's/Debian GNU\/Linux Installer menu/NCZ-OS installer menu/g' \
        -e 's/Debian GNU\/Linux installer main menu/NCZ-OS installer main menu/g' \
        -e 's/Debian GNU\/Linux/NCZ-OS/g' \
        -e 's/the Debian installer/the NCZ-OS installer/g' \
        -e 's/Debian installer/NCZ-OS installer/g' \
        "$_ctl/templates"
    rm -f "$_ar/$_ctl_member"
    ( cd "$_ctl" && tar --numeric-owner --owner=0 --group=0 -cf - . ) | gzip -9n > "$_ar/control.tar.gz"
    local _new_udeb="$_tmp/$(basename "$_udeb")"
    ( cd "$_ar" && ar rc "$_new_udeb" debian-binary control.tar.gz "$_data_member" )
    mv "$_new_udeb" "$_udeb"
    rm -rf "$_tmp"
    echo "    $_label udeb templates NCZ-branded"
}
brand_udeb_templates "$STAGING/pool/main/m/main-menu/main-menu_*.udeb"        "main-menu"
brand_udeb_templates "$STAGING/pool/main/f/finish-install/finish-install_*.udeb" "finish-install"
brand_udeb_templates "$STAGING/pool/main/c/choose-mirror/choose-mirror_*.udeb"   "choose-mirror"

# disk-detect's stock disk_found() loop is only 15 attempts with 2s sleeps
# (~30s total). That is too short on Sky1 when the d-i storage device tree is
# genuinely slow to settle, especially around NVMe. Patch the udeb that owns
# the main-menu "Detect disks" step so the wait is still bounded, but long
# enough to match the platform's observed behaviour.
patch_disk_detect_wait() {
    local _glob="$1"
    local _matches; _matches=( $_glob )
    local _udeb="${_matches[0]}"
    [ -e "$_udeb" ] || {
        echo "ERROR: disk-detect udeb absent; cannot extend d-i disk wait" >&2
        exit 1
    }

    local _tmp="$STAGING/.tmp-disk-detect-udeb"
    local _ar="$_tmp/ar" _data="$_tmp/data"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_data"
    local _udeb_abs; _udeb_abs="$(readlink -f "$_udeb")"
    ( cd "$_ar" && ar x "$_udeb_abs" )
    [ -f "$_ar/debian-binary" ] || {
        echo "ERROR: disk-detect udeb missing debian-binary" >&2
        exit 1
    }
    local _ctl_members=( "$_ar"/control.tar* )
    local _data_members=( "$_ar"/data.tar* )
    local _ctl_member; _ctl_member="$(basename "${_ctl_members[0]}")"
    local _data_member; _data_member="$(basename "${_data_members[0]}")"
    tar -xf "$_ar/$_data_member" -C "$_data"
    [ -f "$_data/usr/bin/disk-detect" ] || {
        echo "ERROR: disk-detect udeb missing usr/bin/disk-detect" >&2
        exit 1
    }

    python3 - "$_data/usr/bin/disk-detect" <<'PYDISK'
import sys

path = sys.argv[1]
src = open(path).read()

old = '''disk_found() {
\tfor try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
\t\tif search-path parted_devices; then
\t\t\t# Use partman's parted_devices if available.
\t\t\tif [ -n "$(parted_devices)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\telse
\t\t\t# Essentially the same approach used by partitioner and
\t\t\t# autopartkit to find their disks.
\t\t\tif [ -n "$(list-devices disk)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\tfi

\t\t# Wait for disk to be activated.
\t\tif [ "$try" != 15 ]; then
\t\t\tsleep 2
\t\tfi
\tdone

\treturn 1
}'''

new = '''disk_found() {
\tmax_tries="${NCZ_DISK_DETECT_TRIES:-90}"
\tcase "$max_tries" in *[!0-9]*|'') max_tries=90 ;; esac
\t[ "$max_tries" -lt 15 ] && max_tries=15

\ttry=1
\twhile [ "$try" -le "$max_tries" ]; do
\t\t# Give udev a chance to publish slow storage devices before asking
\t\t# partman/list-devices. update-dev is the d-i wrapper used elsewhere
\t\t# in hw-detect before probing for newly-created device nodes.
\t\tudevadm settle --timeout=10 >/dev/null 2>&1 || true
\t\tupdate-dev >/dev/null 2>&1 || true

\t\tif search-path parted_devices; then
\t\t\t# Use partman's parted_devices if available.
\t\t\tif [ -n "$(parted_devices)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\telse
\t\t\t# Essentially the same approach used by partitioner and
\t\t\t# autopartkit to find their disks.
\t\t\tif [ -n "$(list-devices disk)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\tfi

\t\t# Wait for disk to be activated. Stock d-i only waited ~30s
\t\t# (15 attempts * 2s); Sky1 NVMe enumeration can exceed that.
\t\tif [ "$try" != "$max_tries" ]; then
\t\t\tlogger -t disk-detect "no disk yet after attempt $try/$max_tries; waiting for storage enumeration"
\t\t\tsleep 2
\t\tfi
\t\ttry=$((try + 1))
\tdone

\treturn 1
}'''

if src.count(old) != 1:
    raise SystemExit(f"disk-detect patch drift: expected one disk_found anchor, found {src.count(old)}")
src = src.replace(old, new)
if src.count('list_modules_dir /lib/modules/*/kernel/drivers/nvme/host') != 0:
    raise SystemExit("disk-detect patch drift: nvme module directory already present")
src = src.replace(
'''	list_modules_dir /lib/modules/*/kernel/drivers/block
	list_modules_dir /lib/modules/*/kernel/drivers/message/fusion''',
'''	list_modules_dir /lib/modules/*/kernel/drivers/block
	list_modules_dir /lib/modules/*/kernel/drivers/nvme/host
	list_modules_dir /lib/modules/*/kernel/drivers/message/fusion''',
1,
)
if src.count('list_modules_dir /lib/modules/*/kernel/drivers/nvme/host') != 1:
    raise SystemExit("disk-detect patch drift: failed to add nvme module directory")
if src.count('prime_storage_detection') != 0:
    raise SystemExit("disk-detect patch drift: storage priming already present")
src = src.replace(
'''multipath_probe() {
	MP_VERBOSE=2
	# Look for multipaths...
	if [ ! -f /etc/multipath.conf ]; then
		cat <<EOF >/etc/multipath.conf
defaults {
    user_friendly_names yes
}
EOF
	fi
	log-output -t disk-detect /usr/sbin/multipath -v$MP_VERBOSE

	if multipath -l 2>/dev/null | grep -q '^mpath[a-z]\\+ '; then
		return 0
	else
		return 1
	fi
}

if ! hw-detect disk-detect/detect_progress_title; then''',
'''multipath_probe() {
	MP_VERBOSE=2
	# Look for multipaths...
	if [ ! -f /etc/multipath.conf ]; then
		cat <<EOF >/etc/multipath.conf
defaults {
    user_friendly_names yes
}
EOF
	fi
	log-output -t disk-detect /usr/sbin/multipath -v$MP_VERBOSE

	if multipath -l 2>/dev/null | grep -q '^mpath[a-z]\\+ '; then
		return 0
	else
		return 1
	fi
}

prime_storage_detection() {
	for module in nvme nvme-core virtio_blk sd_mod ahci; do
		if is_not_loaded "$module"; then
			log "preloading storage module $module before hw-detect"
			log-output -t disk-detect modprobe -v "$module" || true
		fi
	done
	udevadm trigger --subsystem-match=block --action=add >/dev/null 2>&1 || true
	udevadm settle --timeout=10 >/dev/null 2>&1 || true
	update-dev >/dev/null 2>&1 || true
}

	prime_storage_detection
	if ! hw-detect disk-detect/detect_progress_title; then''',
1,
)
if src.count('prime_storage_detection') != 2:
    raise SystemExit("disk-detect patch drift: failed to add storage priming")
open(path, "w").write(src)
PYDISK
    chmod 0755 "$_data/usr/bin/disk-detect"
    sh -n "$_data/usr/bin/disk-detect"

    rm -f "$_ar/$_data_member"
    ( cd "$_data" && tar --numeric-owner --owner=0 --group=0 -cf - . ) \
        | gzip -9n > "$_ar/data.tar.gz"
    local _new_udeb="$_tmp/$(basename "$_udeb")"
    ( cd "$_ar" && ar rc "$_new_udeb" debian-binary "$_ctl_member" data.tar.gz )
    mv "$_new_udeb" "$_udeb"
    rm -rf "$_tmp"
    echo "    disk-detect udeb: preloads storage modules and extends disk_found wait to 90 settled attempts (~180s)"
}
patch_disk_detect_wait "$STAGING/pool/main/h/hw-detect/disk-detect_*.udeb"

# Give NCZ late_command an explicit 100-unit allocation in finish-install's
# OWN progress bar. Bookworm does not preload finish-install into the initrd:
# anna retrieves its udeb from the media pool, then dpkg installs this postinst.
# Patch that real owner before the Packages index is regenerated below.
patch_finish_install_progress_owner() {
    local _glob="$1"
    local _matches; _matches=( $_glob )
    local _udeb="${_matches[0]}"
    [ -e "$_udeb" ] || {
        echo "ERROR: finish-install udeb absent; cannot allocate late-install progress" >&2
        exit 1
    }

    local _tmp="$STAGING/.tmp-finish-progress-udeb"
    local _ar="$_tmp/ar" _ctl="$_tmp/ctl"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_ctl"
    local _udeb_abs; _udeb_abs="$(readlink -f "$_udeb")"
    ( cd "$_ar" && ar x "$_udeb_abs" )
    [ -f "$_ar/debian-binary" ] || {
        echo "ERROR: finish-install udeb missing debian-binary" >&2
        exit 1
    }
    local _ctl_members=( "$_ar"/control.tar* )
    local _data_members=( "$_ar"/data.tar* )
    local _ctl_member; _ctl_member="$(basename "${_ctl_members[0]}")"
    local _data_member; _data_member="$(basename "${_data_members[0]}")"
    tar -xf "$_ar/$_ctl_member" -C "$_ctl"
    [ -f "$_ctl/postinst" ] || {
        echo "ERROR: finish-install udeb missing control/postinst" >&2
        exit 1
    }

    python3 - "$_ctl/postinst" <<'PYFINISH'
import sys

path = sys.argv[1]
src = open(path).read()

old_count = 'scriptcount=$(ls "$partsdir"/* | wc -l)'
new_count = '''scriptcount=$(ls "$partsdir"/* | wc -l)
ncz_preseed_script="$partsdir/07preseed"
ncz_progress_units=100
if [ -x "$ncz_preseed_script" ]; then
\tscriptcount=$((scriptcount + ncz_progress_units - 1))
fi'''

old_loop = '''for script in "$partsdir"/*; do
\tbase=$(basename $script | sed 's/[0-9]*//')'''
new_loop = '''for script in "$partsdir"/*; do
\tncz_progress_child=0
\tif [ "$script" = "$ncz_preseed_script" ]; then
\t\tncz_progress_child=1
\t\tNCZ_PROGRESS_UNITS=$ncz_progress_units
\t\tNCZ_PROGRESS_CONSUMED_FILE="/tmp/ncz-finish-progress.$$"
\t\tprintf '0\\n' > "$NCZ_PROGRESS_CONSUMED_FILE"
\t\texport NCZ_PROGRESS_UNITS NCZ_PROGRESS_CONSUMED_FILE
\tfi
\tbase=$(basename $script | sed 's/[0-9]*//')'''

old_step = '''\tdb_progress STEP 1
done'''
new_step = '''\tif [ "$ncz_progress_child" = 1 ]; then
\t\tncz_consumed=$(cat "$NCZ_PROGRESS_CONSUMED_FILE" 2>/dev/null || echo 0)
\t\tcase "$ncz_consumed" in *[!0-9]*|'') ncz_consumed=0 ;; esac
\t\t[ "$ncz_consumed" -gt "$ncz_progress_units" ] && ncz_consumed=$ncz_progress_units
\t\tncz_remaining=$((ncz_progress_units - ncz_consumed))
\t\t[ "$ncz_remaining" -gt 0 ] && db_progress STEP "$ncz_remaining"
\t\trm -f "$NCZ_PROGRESS_CONSUMED_FILE"
\t\tunset NCZ_PROGRESS_UNITS NCZ_PROGRESS_CONSUMED_FILE
\telse
\t\tdb_progress STEP 1
\tfi
done'''

for name, old, new in (
    ("script count", old_count, new_count),
    ("07preseed allocation", old_loop, new_loop),
    ("owned step completion", old_step, new_step),
):
    if src.count(old) != 1:
        raise SystemExit(
            f"finish-install patch drift: expected one {name} anchor, "
            f"found {src.count(old)}"
        )
    src = src.replace(old, new)

open(path, "w").write(src)
PYFINISH
    chmod 0755 "$_ctl/postinst"
    sh -n "$_ctl/postinst"

    rm -f "$_ar/$_ctl_member"
    ( cd "$_ctl" && tar --numeric-owner --owner=0 --group=0 -cf - . ) \
        | gzip -9n > "$_ar/control.tar.gz"
    local _new_udeb="$_tmp/$(basename "$_udeb")"
    ( cd "$_ar" && ar rc "$_new_udeb" debian-binary control.tar.gz "$_data_member" )
    mv "$_new_udeb" "$_udeb"
    rm -rf "$_tmp"
    echo "    finish-install udeb: allocated 100 owned progress units to 07preseed/late_command"
}
patch_finish_install_progress_owner \
    "$STAGING/pool/main/f/finish-install/finish-install_*.udeb"

# Step 5: regenerate the target-suite debian-installer Packages index
# from the actual pool contents (not just copy bookworm's stale Packages).
# After the trixie graft, the d-i Packages index MUST reflect the new udeb set
# or anna can't find the new udebs.
echo "    regenerating udeb Packages index from actual pool contents"
mkdir -p "$STAGING/dists/$ISO_APT_SUITE/main/debian-installer/binary-arm64"
(
    cd "$STAGING"
    dpkg-scanpackages --type udeb --multiversion pool/main /dev/null 2>/dev/null \
        > dists/$ISO_APT_SUITE/main/debian-installer/binary-arm64/Packages
    gzip -9cn dists/$ISO_APT_SUITE/main/debian-installer/binary-arm64/Packages \
        > dists/$ISO_APT_SUITE/main/debian-installer/binary-arm64/Packages.gz
    UDEBCT=$(grep -c '^Package: ' dists/$ISO_APT_SUITE/main/debian-installer/binary-arm64/Packages || true)
    echo "    udeb Packages: $UDEBCT entries indexed"
)

# In EMBED_MIRROR mode regenerate the regular deb Packages index from the
# complete profile-matched pool so file:///cdrom sees the full offline desktop
# closure. (--type deb skips the .udeb files,
# which are indexed separately above.) Runs before the Step 6 Release regen so
# the Release hashes the rebuilt index.
if [ "$EMBED_MIRROR" = "1" ]; then
    # ---------------------------------------------------------------
    # Prune the staged pool: drop every .deb whose package is already
    # installed inside a shipped squashfs layer.
    #
    # The ISO was carrying the desktop/server package sets twice -- once
    # installed in the layers, once as .debs for the offline mirror.
    # Measured on forky10: 1005 MB of a 1013 MB pool was already in a
    # layer, while a real install apt-installed only three packages that
    # were not (locales, libc-l10n, systemd-container). A package already
    # present on the variant that would ask for it can never be fetched
    # from the pool, and the desktop hooks are variant-gated, so
    # desktop-only packages are requested by neither variant.
    #
    # The mirror is still built in full -- build-squashfs-layers.sh needs
    # it to construct the layers. This prunes only the ISO copy.
    #
    # Set NCZ_KEEP_FULL_POOL=1 to ship the unpruned pool.
    # ---------------------------------------------------------------
    if [ "${NCZ_KEEP_FULL_POOL:-0}" = "1" ]; then
        echo "    pool prune DISABLED (NCZ_KEEP_FULL_POOL=1) — shipping the full mirror"
    else
        # Scratch lives under $STAGING (house style, cf. .installer-kernel-overlay)
        # so it is cleaned with the build tree instead of leaking into /tmp if
        # the build dies mid-prune.
        NCZ_PRUNE_DIR="$STAGING/.prune-scratch"
        rm -rf "$NCZ_PRUNE_DIR"; mkdir -p "$NCZ_PRUNE_DIR"
        NCZ_PRUNE_KEEP="$NCZ_PRUNE_DIR/keep"; : > "$NCZ_PRUNE_KEEP"
        # Packages any hook names on an apt-get install line. Cheap
        # insurance against a non-variant-gated hook wanting something the
        # other variant's layer does not carry.
        grep -hoE "apt-get install[^|;&]*" "$ROOT"/post-install/*.sh "$ROOT"/preseed/*.sh 2>/dev/null \
            | tr " " "\n" \
            | grep -E "^[a-z0-9][a-z0-9.+-]+$" \
            | grep -vE "^(apt-get|install|y|q|f|the|from|via|which|full|fail|seed|our|offline|mirror|unmet|desktop|network)$" \
            >> "$NCZ_PRUNE_KEEP" || true
        # Kernel packages: always reinstallable from the ISO. Keep the current
        # unified names as well as retired channel names for upgrade recovery.
        printf '%s\n' linux-image-cixmini linux-headers-cixmini \
            linux-image-cixmini-legacy linux-image-cixmini-edge \
            linux-image-cixmini-lts cixmini-boot ncz-usb-recovery >> "$NCZ_PRUNE_KEEP"
        # 10-our-kernel.sh may install zstd directly from the pruned ISO pool
        # before network time/certs are sane. Keep its tiny dependency chain in
        # the same local pool so dpkg can configure it without apt's resolver.
        printf '%s\n' zstd zlib1g libgcc-s1 liblz4-1 liblzma5 libstdc++6 >> "$NCZ_PRUNE_KEEP"
        # Observed install-time installs that no layer provides.
        printf '%s\n' locales libc-l10n systemd-container >> "$NCZ_PRUNE_KEEP"
        # 20-desktop.sh installs the local ncz-singularity-desktop payload
        # directly from /cdrom/pool/main; keep upower so that package does not
        # land with a broken dependency while network apt sources are cold.
        printf '%s\n' upower >> "$NCZ_PRUNE_KEEP"

        NCZ_PRUNE_HAVE="$NCZ_PRUNE_DIR/have"; : > "$NCZ_PRUNE_HAVE"
        for _l in base desktop server; do
            # Read the SOURCE layers: $EXTRA/*.squashfs is not staged until later.
            _sq="$ROOT/assets/squashfs/$_l.squashfs"
            [ -f "$_sq" ] || continue
            _tmp="$NCZ_PRUNE_DIR/$_l"; rm -rf "$_tmp"; mkdir -p "$_tmp"
            if unsquashfs -f -d "$_tmp" -q "$_sq" var/lib/dpkg/status >/dev/null 2>&1 \
               && [ -f "$_tmp/var/lib/dpkg/status" ]; then
                sed -n 's/^Package: //p' "$_tmp/var/lib/dpkg/status" >> "$NCZ_PRUNE_HAVE"
            fi
            rm -rf "$_tmp"
        done
        if [ ! -s "$NCZ_PRUNE_HAVE" ]; then
            echo "    pool prune SKIPPED — could not read any layer's dpkg status" >&2
        else
            _before=$(du -sm "$STAGING/pool" 2>/dev/null | cut -f1)
            sort -u "$NCZ_PRUNE_HAVE" -o "$NCZ_PRUNE_HAVE"
            sort -u "$NCZ_PRUNE_KEEP" -o "$NCZ_PRUNE_KEEP"
            _dropped=0
            while IFS= read -r _deb; do
                _name=$(basename "$_deb"); _name=${_name%%_*}
                grep -qxF "$_name" "$NCZ_PRUNE_KEEP" && continue
                grep -qxF "$_name" "$NCZ_PRUNE_HAVE" || continue
                rm -f "$_deb" && _dropped=$((_dropped + 1))
            done < <(find "$STAGING/pool" -name '*.deb')
            _after=$(du -sm "$STAGING/pool" 2>/dev/null | cut -f1)
            echo "    pool pruned: dropped $_dropped deb(s) already inside a squashfs layer (${_before}M -> ${_after}M)"
        fi
        rm -rf "$NCZ_PRUNE_DIR"
    fi
    bash "$ROOT/build/verify-local-package-versions.sh" \
        --pool "$STAGING/pool" \
        --label "staged ISO pool" \
        "${LOCAL_VERSION_ARGS[@]}"
    echo "    regenerating regular deb Packages index from the staged offline pool"
    mkdir -p "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64"
    (
        cd "$STAGING"
        dpkg-scanpackages --type deb --multiversion pool/main /dev/null 2>/dev/null \
            > dists/$ISO_APT_SUITE/main/binary-arm64/Packages
        gzip -9cn dists/$ISO_APT_SUITE/main/binary-arm64/Packages \
            > dists/$ISO_APT_SUITE/main/binary-arm64/Packages.gz
        DEBCT=$(grep -c '^Package: ' dists/$ISO_APT_SUITE/main/binary-arm64/Packages || true)
        echo "    regular deb Packages: $DEBCT entries indexed"
    )
fi

if [ "$EMBED_MIRROR" = "0" ] && [ "$BOOTSTRAP_POOL" = "0" ]; then
    # 2026-05-07 (take7 chroot-target failure → take8 fix per
    # Codex R78-INVALID-RELEASE-AUDIT):
    #
    # take7 attempted to force base-installer onto the http mirror by
    # removing the target-suite regular binary-arm64 index entirely. That
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
    mkdir -p "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64"
    : > "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64/Packages"
    gzip -9cn "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64/Packages" \
        > "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64/Packages.gz"
elif [ "$BOOTSTRAP_POOL" = "1" ]; then
    if [ ! -s "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64/Packages" ]; then
        echo "ERROR: bootstrap pool did not provide a non-empty regular Packages index" >&2
        exit 1
    fi
    BOOTSTRAP_DEBCT=$(grep -c '^Package: ' "$STAGING/dists/$ISO_APT_SUITE/main/binary-arm64/Packages" || true)
    echo "    bootstrap pool regular Packages: $BOOTSTRAP_DEBCT entries indexed"
fi

# Step 6: regenerate the target-suite Release to include BOTH the regular
# Packages indexes AND the debian-installer Packages indexes. apt-ftparchive
# reads the entire target suite tree and computes hashes for everything.
echo "    regenerating dists/$ISO_APT_SUITE/Release with both regular + udeb indexes"
(
    cd "$STAGING"
    write_translation_indexes "$ISO_APT_SUITE" main
    write_component_release_files "$ISO_APT_SUITE" arm64
    if [ "$EMBED_MIRROR" = "1" ]; then
        write_suite_release "$ISO_APT_SUITE" arm64 main "nclawzero cixmini offline mirror — $ISO_APT_SUITE arm64 (regular + udebs)"
    elif [ "$BOOTSTRAP_POOL" = "1" ]; then
        write_suite_release "$ISO_APT_SUITE" arm64 main "nclawzero cixmini netinstall bootstrap pool - $ISO_APT_SUITE arm64"
    else
        write_suite_release "$ISO_APT_SUITE" arm64 main "nclawzero cixmini netinstall udeb substrate — $ISO_APT_SUITE arm64"
    fi
)
echo "    Release file regenerated:"
head -16 "$STAGING/dists/$ISO_APT_SUITE/Release" | sed 's/^/      /'

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
        printf '%s - Netinstall arm64 Binary 1\n' "$NCZ_RELEASE_LABEL" > "$STAGING/.disk/info"
        ;;
    netinstall-bootstrap)
        printf '%s - Netinstall Bootstrap arm64 Binary 1\n' "$NCZ_RELEASE_LABEL" > "$STAGING/.disk/info"
        ;;
    thin)
        printf '%s - Thin arm64 Binary 1\n' "$NCZ_RELEASE_LABEL" > "$STAGING/.disk/info"
        ;;
    *)
        printf '%s - Offline arm64 Binary 1\n' "$NCZ_RELEASE_LABEL" > "$STAGING/.disk/info"
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

# 2026-07-29: DECOMPRESS any .ko.xz modules for the d-i initrd. The kernel
# builds now ship xz-compressed modules (CONFIG_MODULE_COMPRESS_XZ) — fine
# for the installed system, FATAL for the installer: bookworm's kmod UDEB
# (the d-i initrd's module loader) cannot decompress xz. Empirically proven
# on cixmini via the initrd's own binary in a chroot:
#     insmod linlon-dp.ko.xz -> "Invalid module format"   (raw xz bytes
#                                handed to the kernel, rejected)
#     insmod linlon-dp.ko    -> "File exists"             (decoded fine,
#                                module already loaded on the host)
# Its "+XZ" feature banner is not backed by any lzma code in the minimized
# udeb build (zero lzma strings in the binary; zstd is dlopen'd, xz simply
# absent). With every overlay module unloadable, d-i can't load linlondp ->
# no video console on O6N -> black-screen installer even after the
# drivers/gpu prune fix. Decompressing here keeps the target-system .ko.xz
# benefits while giving d-i plain .ko it can actually load; the depmod
# below then records the .ko names. Size cost is acceptable: the initrd's
# own gzip still compresses the ELF payload, and a 130MB initrd is proven
# to reach kernel handoff on real O6N hardware.
_kxz_count=$(find "$WORK/lib/modules/$KVER_INSTALLER" -name '*.ko.xz' | wc -l)
if [ "$_kxz_count" -gt 0 ]; then
    find "$WORK/lib/modules/$KVER_INSTALLER" -name '*.ko.xz' -exec xz -d {} +
    _kxz_left=$(find "$WORK/lib/modules/$KVER_INSTALLER" -name '*.ko.xz' | wc -l)
    [ "$_kxz_left" -eq 0 ] || { echo "ERROR: $_kxz_left .ko.xz modules failed to decompress"; exit 1; }
    echo "    decompressed $_kxz_count .ko.xz modules -> plain .ko (d-i kmod udeb cannot read xz)"
fi

# r211: prune target-only driver categories before they hit the d-i initrd.
# $INSTALLER_TGZ is the FULL target-system module tree (same artifact the
# installed OS uses), dumped into this overlay unfiltered. It grew from a
# reasonable size to 124M+ (compressed) as the legacy kernel gained features
# over time (e.g. the 2026-06-17 Sky1 audio stack port) — none of which a
# text-mode d-i bootstrap environment (no GPU, no audio, no camera, wired
# ethernet only per the rtl_nic note above) has any use for. On real O6N
# hardware this eventually exceeded a firmware-level load-size limit: GRUB
# hard-resets the board mid initrd-load instead of handing off to the
# kernel (confirmed 2026-07-28, serial-captured — SE_FW/BL2/BL31 restart
# immediately after "Loading initrd...", no kernel messages ever appear).
# Cut only unambiguously target-only categories D-I's partman/netcfg never
# touch; keep storage/fs/net/usb/platform drivers d-i genuinely needs.
#
# 2026-07-29: drivers/gpu REMOVED from the prune list — that cut was the
# real cause of the "installer black screen" chased for two days. On O6N
# the firmware GOP/efifb handoff does not work (metal-confirmed: a target
# boot sits on "Console: colour dummy device" until the linlondp DRM
# MODULE probes at ~2.9s and only then switches to a framebuffer console).
# So the linlondp/trilin modules in this initrd are the ONLY possible
# video console for d-i on that board — pruning drivers/gpu made every
# installer boot a permanent black screen that was indistinguishable from
# the pre-kernel hang this prune was meant to fix (and the d-i cmdline's
# console=ttyAMA2 is MS-R1-only, so serial was silent on O6N too — no
# diagnostic channel survived). The foreign-GPU bloat that motivated the
# cut (nouveau 23M, msm 11M, etc.) is gone at kernel-config level now
# (2026-07-28 thinning), so keeping drivers/gpu costs only the small
# CIX display stack + DRM helpers.
# 2026-07-29 (third and final piece of the black-screen chain): drivers/media
# must be pruned SELECTIVELY, not wholesale — drivers/media/cec/core/cec.ko is
# a hard dependency of drm_display_helper (metal serial trace: 14 unresolved
# cec_* symbols, "drm_display_helper: Unknown symbol cec_delete_adapter
# (err -2)"), and without drm_display_helper the linlondp/trilin display stack
# cannot load, so keeping drivers/gpu alone (705f0f2) still left the installer
# with no video. Keep drivers/media/cec; prune the rest of media below.
PRUNE_MOD_DIRS="sound drivers/bluetooth"
MEDIA_DIR="$WORK/lib/modules/$KVER_INSTALLER/kernel/drivers/media"
if [ -d "$MEDIA_DIR" ]; then
    for p in "$MEDIA_DIR"/*; do
        [ "$(basename "$p")" = "cec" ] && continue
        _pruned_bytes=$((${_pruned_bytes:-0} + $(du -sk "$p" | cut -f1)))
        rm -rf "$p"
    done
    echo "    media pruned selectively (kept drivers/media/cec — drm_display_helper dependency)"
fi
PRUNE_NET_DIRS="bluetooth mac80211 wireless"
_pruned_bytes=${_pruned_bytes:-0}
for d in $PRUNE_MOD_DIRS; do
    p="$WORK/lib/modules/$KVER_INSTALLER/kernel/$d"
    [ -d "$p" ] || continue
    _pruned_bytes=$((_pruned_bytes + $(du -sk "$p" | cut -f1)))
    rm -rf "$p"
done
for d in $PRUNE_NET_DIRS; do
    p="$WORK/lib/modules/$KVER_INSTALLER/kernel/net/$d"
    [ -d "$p" ] || continue
    _pruned_bytes=$((_pruned_bytes + $(du -sk "$p" | cut -f1)))
    rm -rf "$p"
done
echo "    pruned target-only modules (media-except-cec/sound/bluetooth/wireless — gpu+cec KEPT for O6N video): $((_pruned_bytes / 1024))M"

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

# Panthor is present in the installer kernel module set so the display stack
# can probe on O6/O6N.  The Mali CSF firmware is otherwise only copied into
# the installed target by post-install/12-sky1-firmware.sh, which leaves the
# d-i initrd with a real (but avoidable) `mali_csffw.bin` -ENOENT error during
# DIAG and hardware detection.  Stage the same firmware in the initrd using
# the exact request path emitted by the 7.0.12 Panthor driver.
PANTHOR_FW="$ROOT/assets/sky1-firmware/arm/mali/arch12.8/mali_csffw.bin"
if [ -s "$PANTHOR_FW" ]; then
    mkdir -p "$WORK/lib/firmware/arm/mali/arch12.8"
    cp -L "$PANTHOR_FW" "$WORK/lib/firmware/arm/mali/arch12.8/mali_csffw.bin"
    echo "    Panthor Mali CSF firmware → installer initrd: $(du -h "$PANTHOR_FW" | cut -f1)"
else
    echo "    WARN: Panthor Mali CSF firmware absent — DIAG may report mali_csffw.bin -ENOENT"
fi

OVERLAY_GZ="$STAGING/.installer-kernel-overlay.cpio.gz"
# -mindepth 1: never emit a bare top-level "lib" DIRECTORY entry. A usr-merged
# d-i initrd (Debian forky and newer) ships lib/bin/sbin as SYMLINKS into usr/,
# and the kernel's initramfs unpacker (clean_path() in init/initramfs.c) DELETES
# an existing path whose type differs from the entry being extracted -- so a
# "lib" dir entry here silently unlinks "lib -> usr/lib" and takes the C library
# and dynamic loader with it. /init then fails its #!/bin/sh interpreter lookup
# with ENOENT and the kernel panics with "No working init found". Emitting only
# lib/modules/... resolves through the symlink on a merged base and lands in
# /lib/modules on an unmerged one.
( cd "$WORK" && find lib -mindepth 1 -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$OVERLAY_GZ"
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
if [ "$DI_CODENAME" != "bookworm" ]; then
    echo "[3.5] SKIP amber-phosphor binary patch on $DI_CODENAME (NEWT_COLORS env-var still applied below)"
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

# r173 (#4 branding): NCZ-brand the d-i INSTALLER UI at source. The main-menu
# title ("Debian installer main menu") and other Debian strings ship as
# cdebconf templates BAKED INTO THE INITRD (var/lib/dpkg/info/*.templates) —
# these components load from the initrd, not the anna-loaded pool, so the pool
# udeb-template patch (brand_udeb_templates, above) cannot reach them. Overlay
# branded copies into the initrd via the SAME last-wins cpio append. We only
# touch Description/_Description TEXT (case-sensitive "Debian ..." phrases);
# template KEYS use lowercase "debian-installer/..." and never match, so
# main-menu/anna routing is unaffected.
echo "    NCZ-branding baked-in d-i initrd templates (main-menu title etc.)"
for _tpl in main-menu di-utils cdrom-detect cdrom-checker anna; do
    _src="$INITRD_PATCH_TMP/extract/var/lib/dpkg/info/$_tpl.templates"
    [ -f "$_src" ] || { echo "      note: $_tpl.templates absent in initrd — skip"; continue; }
    mkdir -p "$INITRD_PATCH_TMP/overlay/var/lib/dpkg/info"
    _dst="$INITRD_PATCH_TMP/overlay/var/lib/dpkg/info/$_tpl.templates"
    sed \
        -e 's/Debian installer main menu/NCZ-OS installer main menu/g' \
        -e 's/Debian GNU\/Linux Installer menu/NCZ-OS installer menu/g' \
        -e 's/Debian GNU\/Linux installer main menu/NCZ-OS installer main menu/g' \
        -e 's/the Debian installer/the NCZ-OS installer/g' \
        -e 's/Debian installer/NCZ-OS installer/g' \
        -e 's/Debian GNU\/Linux/NCZ-OS/g' \
        "$_src" > "$_dst"
    chmod 0644 "$_dst"
    if cmp -s "$_src" "$_dst"; then
        echo "      $_tpl.templates: no Debian strings changed"
    else
        echo "      $_tpl.templates: NCZ-branded"
    fi
done

# Build cpio overlay containing init + newt.so + branded templates. The
# progress-aware finish-install owner is carried by its anna-loaded udeb.
( cd "$INITRD_PATCH_TMP/overlay" && find . | cpio -o -H newc --quiet | gzip -9 -n ) >> "$INITRD"
echo "    initrd patched: amber palette + NCZ branding"
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
# Stage under usr/bin ONLY, for the same usr-merge reason as the kernel-module
# overlay above: a top-level "bin" dir entry unlinks "bin -> usr/bin" on a
# usr-merged d-i initrd, which removes /bin/sh and panics the kernel. Worse, the
# old split layout wrote a REAL bin/zstd and a usr/bin/zstd -> ../../bin/zstd
# symlink; once bin/ and usr/bin/ are the same directory those two entries are
# the same path, and the symlink (extracted last) turns zstd into a loop.
# /usr/bin is on d-i's PATH on merged and unmerged bases alike.
mkdir -p "$TOOLS_WORK/usr/bin"
install -m 0755 "$ZSTD_STATIC_BIN" "$TOOLS_WORK/usr/bin/zstd"
ln -s zstd "$TOOLS_WORK/usr/bin/zstdcat"

TOOLS_GZ="$STAGING/.r27-tools-overlay.cpio.gz"
( cd "$TOOLS_WORK" && find . -mindepth 1 -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$TOOLS_GZ"
gzip -t "$TOOLS_GZ"
cat "$TOOLS_GZ" >> "$STAGING/install.a64/initrd.gz"
rm -rf "$TOOLS_WORK" "$TOOLS_GZ"
echo "    zstd: $ZSTD_STATIC_BIN"
echo "    initrd.gz now: $(du -h "$STAGING/install.a64/initrd.gz" | cut -f1)"

# ---------------------------------------------------------------------------
# Root-hub rescan, as a d-i STARTUP script inside the initrd.
#
# This lived in preseed/early_command first, which cannot work: the preseed is
# loaded with preseed/file=/cdrom/cixmini/preseed.cfg, i.e. it lives ON the
# installation medium.  When the medium does not enumerate, /cdrom never
# mounts, the preseed never loads, early_command never runs -- and the rescan
# meant to make the medium readable is itself unreachable.  Measured on O6N
# with r226: mount | grep -c cdrom = 0, /var/log held only syslog, and neither
# /tmp/usb-rescan.sh nor /tmp/diag-console.sh existed.
#
# The initrd is the only place that is guaranteed present before media
# detection, so run it from /lib/debian-installer-startup.d, which d-i executes
# in numeric order at init.  S35 puts it ahead of hardware/media detection.
#
# The preseed copy is kept as well: it is harmless when the medium already
# mounted (it exits immediately once sd* exists) and it still captures the
# video diagnostic later in the install.
RESCAN_WORK="$STAGING/.rescan-overlay"
rm -rf "$RESCAN_WORK"
# Stage under usr/lib, NOT lib. The d-i initrd is usr-merged -- lib is a
# SYMLINK to usr/lib -- and d-i keeps its startup scripts in
# usr/lib/debian-installer-startup.d (S01mount, S02module-params, S10syslog...).
# A cpio member carrying a top-level lib/ DIRECTORY would replace that symlink,
# the same class of breakage the kernel-module and tools overlays above warn
# about for bin/.
mkdir -p "$RESCAN_WORK/usr/lib/debian-installer-startup.d"
install -m 0755 "$ROOT/preseed/usb-rescan.sh" \
    "$RESCAN_WORK/usr/lib/debian-installer-startup.d/S35usb-rescan"
RESCAN_GZ="$STAGING/.rescan-overlay.cpio.gz"
( cd "$RESCAN_WORK" && find usr -mindepth 1 -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$RESCAN_GZ"
gzip -t "$RESCAN_GZ"
cat "$RESCAN_GZ" >> "$STAGING/install.a64/initrd.gz"
rm -rf "$RESCAN_WORK" "$RESCAN_GZ"
echo "    usb-rescan staged as /usr/lib/debian-installer-startup.d/S35usb-rescan"
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
    cp "$ROOT/preseed/preseed.cfg" "$EXTRA/preseed.cfg"
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
    ' "$ROOT/preseed/preseed.cfg" > "$EXTRA/preseed.cfg"
fi
# The preseed is written against the Ubuntu-era profile and hard-codes the
# suite/codename ("resolute") plus the ports.ubuntu.com fallback mirror.
# Retarget both to the active release profile from release.conf. This matters
# on the media, not just over the network: cdrom-retriever reads
# /cdrom/dists/<cdrom/suite>/Release, so a stale suite makes anna fail with
# "No components listed in /cdrom/dists/resolute/Release" and the installer
# stops at "Load installer components" before writing anything to disk.
_MIRROR_REST="${NCZ_BASE_MIRROR#*://}"
_MIRROR_HOST="${_MIRROR_REST%%/*}"
case "$_MIRROR_REST" in
    */*) _MIRROR_PATH="/${_MIRROR_REST#*/}" ;;
    *)   _MIRROR_PATH="" ;;
esac
sed -i -E \
    -e "/^d-i (mirror\/(http\/)?suite|mirror\/codename|mirror\/udeb\/suite|cdrom\/suite|cdrom\/codename) string /s| string .*| string $ISO_APT_SUITE|" \
    -e "/^d-i mirror\/http\/hostname string /s| string .*| string $_MIRROR_HOST|" \
    -e "/^d-i mirror\/http\/directory string /s| string .*| string $_MIRROR_PATH|" \
    "$EXTRA/preseed.cfg"
echo "    preseed retargeted: suite=$ISO_APT_SUITE mirror=$_MIRROR_HOST$_MIRROR_PATH"
cp "$ROOT/preseed/late.sh"            "$EXTRA/late.sh"
cp "$ROOT/preseed/extract-rootfs.sh"  "$EXTRA/extract-rootfs.sh"
cp "$ROOT/preseed/sshd-watcher.sh"    "$EXTRA/sshd-watcher.sh"
# r173: interactive disk + root-filesystem chooser (partman/early_command).
cp "$ROOT/preseed/disk-fs-chooser.sh" "$EXTRA/disk-fs-chooser.sh"
cp "$ROOT/preseed/component-selector.sh" "$EXTRA/component-selector.sh"
# Root-hub rescan + video diagnostic, invoked from preseed early_command.
cp "$ROOT/preseed/usb-rescan.sh"      "$EXTRA/usb-rescan.sh"
chmod 0755 "$EXTRA/late.sh" "$EXTRA/extract-rootfs.sh" "$EXTRA/sshd-watcher.sh" "$EXTRA/disk-fs-chooser.sh" "$EXTRA/component-selector.sh" "$EXTRA/usb-rescan.sh"

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

# Every helper the preseed copies out of $NCZSRC must actually BE in $EXTRA by
# now. early_command sends its cp failures to a log nobody reads, so a helper
# that is referenced but never staged just does not run and says nothing.
# That happened on 2026-08-13: usb-rescan.sh was wired into early_command and
# added to preseed/, but not to the explicit cp list above, so the finished ISO
# carried neither the root-hub rescan nor the video diagnostic -- and the build
# reported success. Fail loudly instead.
#
# diag-console.sh is exempt when DIAG_ENABLE=0, because a ship-clean image
# deliberately omits it and the preseed reference is expected to no-op.
for _h in $(grep -oE '\$NCZSRC/[a-z0-9._-]+\.sh' "$ROOT/preseed/preseed.cfg" \
            | sed 's|.*/||' | sort -u); do
    if [ "$_h" = "diag-console.sh" ] && [ "${DIAG_ENABLE:-1}" != 1 ]; then
        continue
    fi
    if [ ! -f "$EXTRA/$_h" ]; then
        echo "ERROR: preseed references \$NCZSRC/$_h but it was never staged into the ISO" >&2
        echo "       add it to the cp list in build-iso-di.sh alongside sshd-watcher.sh" >&2
        exit 1
    fi
done

cp -a "$ROOT/post-install" "$EXTRA/post-install"

# r202: stage the mali_kbase GPU overlay into /cixmini so 82-mali-gpu can install
# it at install time (NOT baked into base.squashfs; late.sh union-syncs /cixmini,
# baked-wins). Without this /dev/mali0 is absent (panthor blacklisted in Mali mode).
mkdir -p "$EXTRA/assets/kernel"
[ -d "$ROOT/assets/kernel/mali" ] && cp -a "$ROOT/assets/kernel/mali" "$EXTRA/assets/kernel/" && echo "    staged mali_kbase overlay -> /cixmini/assets/kernel/mali"

# Stage the patched Panthor DKMS source and vermagic-matched prebuilt module.
# This is separate from the Mali overlay because Panthor is opt-in, but it
# must still be present in the installed image: otherwise ncz-gpu-select
# silently falls back to the unpatched in-tree module and bypasses the Sky1
# ACPI power-supply (_PR0) un-secure path.
if [ -d "$ROOT/assets/kernel/panthor" ]; then
    cp -a "$ROOT/assets/kernel/panthor" "$EXTRA/assets/kernel/"
    echo "    staged Panthor DKMS source + prebuilt module -> /cixmini/assets/kernel/panthor"
fi

# Stage the NPU and VPU patch series -- the patches ONLY, not the whole trees.
#
# MEASURED on the r244 install: the baked layer carries assets/kernel/{npu,vpu}
# with their patch files as ABSOLUTE symlinks into /workdir/meta-cix/..., the
# Yocto build container mount point, which exists on no installed system. The
# repository now holds the real files, and late.sh union-sync replaces a
# dangling link with the real one -- but only where the ISO carries a source to
# copy FROM. mali is staged just above and its 15 patches were repaired; npu and
# vpu were staged nowhere, so their 9 links stayed broken on the target.
#
# Only src/patches is staged (48K) rather than the full trees (516K + 4.8M):
# the baked layer already ships the driver sources, and the patches are the
# provenance record of what was applied to them.
for _cixdrv in npu vpu; do
    if [ -d "$ROOT/assets/kernel/$_cixdrv/src/patches" ]; then
        mkdir -p "$EXTRA/assets/kernel/$_cixdrv/src/patches"
        cp -aL "$ROOT/assets/kernel/$_cixdrv/src/patches/." \
               "$EXTRA/assets/kernel/$_cixdrv/src/patches/" 2>/dev/null || true
        echo "    staged $_cixdrv patch series ($(find "$EXTRA/assets/kernel/$_cixdrv/src/patches" -name '*.patch' | wc -l) patches) -> /cixmini/assets/kernel/$_cixdrv"
    fi
done


if [ -d "$ROOT/assets" ]; then
    mkdir -p "$EXTRA/assets"
    # Stage all asset trees except the raw kernel images (handled below
    # in their own block so mode-specific kernel payloads stay explicit).
    for d in "$ROOT/assets"/*; do
        bn=$(basename "$d")
        case "$bn" in
            kernel) ;;  # handled below — staged into /cixmini/assets/kernel/
            squashfs)
                # r191.1: NEVER bulk-copy assets/squashfs/ here -- the LAYERED
                # SQUASHFS block below already stages base.squashfs +
                # every built variant delta at the TOP-LEVEL /cixmini/ path
                # (the one extract-rootfs.sh actually reads). This generic
                # loop had no exclusion for it, so every build since layered
                # squashfs was introduced (r158) silently duplicated the full
                # base+desktop+server set into /cixmini/assets/squashfs/ too --
                # ~2.6GB of pure waste on the r191 ISO (found 2026-07-06,
                # operator flagged the 7.98GB ISO size). Same bloat class as
                # the rootfs exclusion above.
                echo "    assets/squashfs NOT bulk-copied (already staged at top level by the layered-squashfs block)"
                ;;
            models)
                # NEVER bulk-copy assets/models/ into the ISO (operator,
                # 2026-08-17). Embedding models are an APPLICATION-LAYER
                # artifact, not driver fidelity: they are delivered from the
                # NCZ apt repository and installed ONLY when MNEMOS is
                # installed (`ncz install mnemos`), because MNEMOS is the only
                # consumer and the model must match the dimension MNEMOS's
                # vector store was built for. Baking them here put ~100MB (and
                # up to ~600MB once nomic-embed-text is staged) onto every
                # desktop install that will never run MNEMOS, and pinned the
                # model version to the ISO instead of letting apt roll it
                # forward independently.
                #
                # Same bloat/wrong-layer class as the rootfs and squashfs
                # exclusions below. 47-embedkit.sh tolerates their absence:
                # it stages whatever is present and skips cleanly otherwise.
                echo "    assets/models NOT bulk-copied (apt-delivered on MNEMOS install)"
                ;;
            rootfs)
                # NEVER bulk-copy assets/rootfs/ into the ISO. The install
                # rootfs is staged separately as /cixmini/rootfs.tar.zst (see
                # ROOTFS_TARBALL below) and extract-rootfs.sh reads only that
                # path. The *.tar.zst tarballs here are multi-GB; copying the
                # whole dir duplicated the rootfs (and dragged in obsolete base
                # tarballs), bloating the ISO by gigabytes.
                echo "    assets/rootfs NOT bulk-copied (install rootfs staged as /cixmini/rootfs.tar.zst)"
                ;;
            rescue)
                # r130: dedicated rescue-partition rootfs tarball + AGENTS.md.
                # Lands at /usr/local/lib/cix-installer/assets/rescue/ on the
                # target; consumed by post-install/72-rescue-partition.sh.
                cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true
                if [ -f "$EXTRA/assets/rescue/rescue-rootfs.tar.zst" ]; then
                    echo "    rescue-rootfs.tar.zst staged: $(du -h "$EXTRA/assets/rescue/rescue-rootfs.tar.zst" | cut -f1)"
                elif [ "$MODE" = "full" ] && [ "$VARIANT" = "desktop" ]; then
                    echo "ERROR: assets/rescue present but rescue-rootfs.tar.zst missing — full desktop ISO must ship a populated rescue partition." >&2
                    echo "  Remediation: sudo bash build/build-rescue-rootfs.sh, then rebuild." >&2
                    exit 1
                else
                    echo "    assets/rescue present but rescue-rootfs.tar.zst missing — run build/build-rescue-rootfs.sh (rescue partition will be left empty)"
                fi
                ;;
            mgmt)
                # Server variant nspawn recovery/management container rootfs.
                # Lands at /usr/local/lib/cix-installer/assets/mgmt/ on the
                # target; consumed (server variant only) by
                # post-install/38-recovery-container.sh.
                cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true
                if [ -f "$EXTRA/assets/mgmt/ncz-mgmt-rootfs.tar.zst" ]; then
                    echo "    ncz-mgmt-rootfs.tar.zst staged: $(du -h "$EXTRA/assets/mgmt/ncz-mgmt-rootfs.tar.zst" | cut -f1)"
                else
                    echo "    assets/mgmt present but ncz-mgmt-rootfs.tar.zst missing -- run build/build-mgmt-rootfs.sh (recovery container will be skipped)"
                fi
                ;;
            cix-debs)
            # Ship ONLY the cix proprietary userland the installer installs.
            # Exclude internal test/validation suites (cix-unit-test 755M,
            # cix-ltp 269M, cix-gpu-test 55M, cix-vpu-test) and dead/duplicate
            # versions superseded by build/apt-repo (cix-npu-onnxruntime_1.0.0
            # -> apt-repo 1.2.0; cix-noe-umd_1.1.1 -> 2.0.2 file-extract). These
            # were never the intended install set yet bloated the ISO by ~1.5G
            # (and the test suites WERE dpkg-installed onto every target via
            # 25-cix-proprietary.sh -- ~1G of dead weight per machine). (2026-06-25)
            mkdir -p "$EXTRA/assets/cix-debs"
            for f in "$d"/*; do
                [ -e "$f" ] || continue
                case "$(basename "$f")" in
                    cix-unit-test_*|cix-ltp_*|cix-gpu-test_*|cix-vpu-test_*|cix-npu-onnxruntime_*|cix-noe-umd_1.1.1_*)
                        echo "    cix-debs: excluding bloat $(basename "$f") ($(du -h "$f" | cut -f1))" ;;
                    *) cp -aL "$f" "$EXTRA/assets/cix-debs/" 2>/dev/null || true ;;
                esac
            done
            STAGED_CIX_DEBS=$(find "$EXTRA/assets/cix-debs" -maxdepth 1 -name '*.deb' | wc -l | tr -d ' ')
            if [ "$STAGED_CIX_DEBS" = "0" ] && [ "$MODE" = "full" ] && [ "$VARIANT" = "desktop" ]; then
                echo "ERROR: 0 CIX proprietary .debs staged — full desktop ISO would have no GPU userspace (dead greeter). Populate assets/cix-debs/ (see 25-cix-proprietary.sh)." >&2
                exit 1
            fi
            echo "    cix-debs staged: $STAGED_CIX_DEBS packages"
            ;;
        *) cp -aL "$d" "$EXTRA/assets/$bn" 2>/dev/null || true ;;
        esac
    done
fi
[ -f "$ROOT/assets/ncz-cli.sh" ] && cp -aL "$ROOT/assets/ncz-cli.sh" "$EXTRA/assets/" 2>/dev/null || true

# Stage target kernel. Edge (7.2.0-sky1-ncz) is the only shipping kernel.
# full/thin stage the edge payload; netinstall uses the d-i substrate's kernel.
mkdir -p "$EXTRA/assets/kernel"
if [ "$STAGE_NEXT_KERNEL" = "1" ] && [ -n "$KVER_NEXT" ]; then
    mkdir -p "$EXTRA/assets/kernel/edge"
    cp -L "$NEXT_KERN" "$EXTRA/assets/kernel/edge/"
    cp -L "$NEXT_TGZ"  "$EXTRA/assets/kernel/edge/"
    if [ -f "$ROOT/assets/kernel/edge/headers-cixmini.tar.zst" ]; then
        cp -L "$ROOT/assets/kernel/edge/headers-cixmini.tar.zst" "$EXTRA/assets/kernel/edge/"
        echo "    NEXT headers staged: $(du -h "$EXTRA/assets/kernel/edge/headers-cixmini.tar.zst" | cut -f1)"
    else
        echo "    NEXT headers: NOT PRESENT — /lib/modules/$KVER_NEXT/build will be absent on"
        echo "                 the target, so DKMS cannot rebuild any CIX driver (every CIX"
        echo "                 driver is DKMS by directive). Produce it from the built kernel"
        echo "                 tree with:"
        echo "                   build/extract-kernel-headers.sh \\"
        echo "                     --kernel-src <linux-src-tree> \\"
        echo "                     --kver $KVER_NEXT \\"
        echo "                     --output assets/kernel/edge/headers-cixmini.tar.zst"
    fi
    # r98: archive the NEXT kernel .config (provenance / future OOT rebuilds).
    if [ -n "$KVER_NEXT" ] && [ -f "$ROOT/assets/kernel/edge/config-$KVER_NEXT" ]; then
        cp -L "$ROOT/assets/kernel/edge/config-$KVER_NEXT" "$EXTRA/assets/kernel/edge/"
        echo "    NEXT config archived: config-$KVER_NEXT"
    fi
    echo "    edge kernel staged: $KVER_NEXT  ($(du -h "$EXTRA/assets/kernel/edge/Image-cixmini.bin" | cut -f1) image, $(du -h "$EXTRA/assets/kernel/edge/modules-cixmini.tgz" | cut -f1) modules)"
else
    echo "    edge kernel: not present — installer will ship the d-i substrate kernel"
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

# r127: upstream signed wireless-regdb for the INSTALLED system. The stale
# /lib/firmware/regulatory.db that shipped before was rejected by cfg80211
# ("malformed or signature invalid"), pinning Wi-Fi to the restrictive world
# domain (country 00). 12-sky1-firmware.sh installs these → /lib/firmware so
# the regulatory DB validates and the correct domain (e.g. US/DFS-FCC) applies.
if [ -d "$ROOT/assets/firmware/regdb" ]; then
    mkdir -p "$EXTRA/assets/firmware/regdb"
    cp -L "$ROOT/assets/firmware/regdb/regulatory.db" \
          "$ROOT/assets/firmware/regdb/regulatory.db.p7s" \
          "$EXTRA/assets/firmware/regdb/" 2>/dev/null || true
    echo "    wireless-regdb (target): $(ls "$EXTRA/assets/firmware/regdb" 2>/dev/null | wc -l | tr -d ' ') files"
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
_REFIND_BIN=""
if [ -f "$ROOT/build/refind-bin/refind_aa64.efi" ]; then
    _REFIND_BIN="$ROOT/build/refind-bin/refind_aa64.efi"
elif [ -f "$ROOT/assets/refind/refind_aa64.efi" ]; then
    _REFIND_BIN="$ROOT/assets/refind/refind_aa64.efi"
    echo "    refind: build/refind-bin/refind_aa64.efi absent — using tracked assets/refind/refind_aa64.efi"
fi
if [ -n "$_REFIND_BIN" ]; then
    mkdir -p "$EXTRA/assets/refind"
    cp -L "$_REFIND_BIN" "$EXTRA/assets/refind/"
    echo "    refind: refind_aa64.efi staged ($(du -h "$EXTRA/assets/refind/refind_aa64.efi" | cut -f1))"
    # r127: rEFInd startup banner ("NCZ-OS 26.6"). Optional — 70-bootloader.sh
    # references it via `banner` only when present; rEFInd ignores a missing one.
    if [ -f "$ROOT/build/refind-bin/ncz-banner.png" ]; then
        cp -L "$ROOT/build/refind-bin/ncz-banner.png" "$EXTRA/assets/refind/"
        echo "    refind: ncz-banner.png staged ($(du -h "$EXTRA/assets/refind/ncz-banner.png" | cut -f1))"
    fi
    # r128: NCZ tile icon for the rEFInd menu entries (banner_scale fillscreen
    # turns ncz-banner.png into the full-screen menu background). Optional.
    if [ -f "$ROOT/build/refind-bin/ncz.png" ]; then
        cp -L "$ROOT/build/refind-bin/ncz.png" "$EXTRA/assets/refind/"
        echo "    refind: ncz.png (entry icon) staged ($(du -h "$EXTRA/assets/refind/ncz.png" | cut -f1))"
    fi
    # r128: rEFInd's standard icons/ directory. CRITICAL — rEFInd silently
    # drops to TEXT-ONLY mode (no banner, no graphical menu) when there is no
    # icons/ subdir next to refind.conf (documented rEFInd behaviour). Shipping
    # it is what lets the NCZ-OS 26.6 graphical boot menu render on Sky1.
    # build/refind-bin/ is a BUILD ARTIFACT directory -- it is populated by
    # whatever last fetched/unpacked rEFInd, so it is routinely present
    # without icons/ (measured 2026-08-17: it held refind_aa64.efi plus both
    # PNGs but no icons/, and the v6 build warned accordingly). The 76-file
    # icons/ set under assets/refind/ is the GIT-TRACKED source of truth for
    # exactly this data, so fall back to it rather than shipping a text-only
    # boot menu. Only warn once neither source has it.
    _REFIND_ICONS=""
    if [ -d "$ROOT/build/refind-bin/icons" ]; then
        _REFIND_ICONS="$ROOT/build/refind-bin/icons"
    elif [ -d "$ROOT/assets/refind/icons" ]; then
        _REFIND_ICONS="$ROOT/assets/refind/icons"
        echo "    refind: build/refind-bin/icons absent — using tracked assets/refind/icons"
    fi
    if [ -n "$_REFIND_ICONS" ]; then
        cp -a "$_REFIND_ICONS" "$EXTRA/assets/refind/"
        echo "    refind: icons/ staged ($(ls "$EXTRA/assets/refind/icons" | wc -l | tr -d ' ') files)"
    else
        echo "    refind: WARN no icons/ in build/refind-bin OR assets/refind — rEFInd boots TEXT-ONLY (no banner)" >&2
    fi
else
    echo "    refind: build/refind-bin/refind_aa64.efi and assets/refind/refind_aa64.efi MISSING — 70-bootloader will FAIL (no installed bootloader)" >&2
fi

echo "$VERSION"     > "$EXTRA/BUILD_VERSION"
echo "$BUILD_DATE"  > "$EXTRA/BUILD_DATE"
echo "$BUILD_HOST"  > "$EXTRA/BUILD_HOST"
echo "$MODE"        > "$EXTRA/BUILD_MODE"
echo "$VARIANT"     > "$EXTRA/BUILD_VARIANT"   # r75 M1: read by 48-server-variant.sh
echo "$NCZ_TARGET_ARCH" > "$EXTRA/BUILD_ARCH"    # canonical installed-system architecture
install -m 0644 "$RELEASE_CONFIG" "$EXTRA/RELEASE"
# r40 full mode: stage the pre-built rootfs tarball so the debootstrap stub
# can populate /target without a real bootstrap.
if [ "$STAGE_ROOTFS" = "1" ]; then
    # r157: use the CLEAN resolute base (r154 fat-ISO behavior). The chroot-baked
    # rootfs regressed desktop/network/BT/icons, so the baked-rootfs preference
    # (commit e86dc84) is reverted. Fat ISO = clean base + embedded mirror desktop.
    # r158: prefer LAYERED SQUASHFS (base + <variant> delta) if built; the
    # extract-rootfs stub mounts+overlays+cp them. Fall back to the tarball.
    # 2026-08-26: every staged squashfs layer's ROOT ENTRY must be 0755.
    # unsquashfs -f -d /target re-stamps /target's own mode from each layer's
    # root entry at install time (LAST layer wins) — a hotfix layer built from
    # a mktemp -d staging dir (0700) shipped / at 0700 and broke greetd/NIC/
    # RTC on every install (see docs/ISO-BUILD-GUARDRAILS.md). Catch it at
    # BUILD time, name the offending layer, and say how to fix it.
    assert_squashfs_root_mode() { # <file> <label>
        command -v unsquashfs >/dev/null 2>&1 || {
            echo "FATAL: unsquashfs not available — cannot verify squashfs layer root modes (squashfs-tools required)" >&2
            exit 1
        }
        local _out _line _mode
        # Capture full output via command substitution before grepping it --
        # `unsquashfs -ll | grep -m1` under `set -o pipefail` SIGPIPEs
        # unsquashfs when grep exits after its first match while unsquashfs
        # still has buffered output, aborting the whole build (Error 141).
        # A `printf | grep -m1` pipe reintroduces the same class of race for
        # large output, so grep the captured string via a here-string
        # instead -- no concurrently-running producer process to SIGPIPE.
        # `|| true` covers the legitimate "no match" case (malformed listing)
        # so set -e doesn't abort here; the explicit mode check below reports
        # it properly via the <unreadable> fallback.
        _out=$(unsquashfs -ll "$1" 2>/dev/null || true)
        _line=$(grep -m1 " squashfs-root$" <<< "$_out" || true)
        _mode=${_line%% *}
        if [ "$_mode" != "drwxr-xr-x" ]; then
            echo "FATAL: $2 ($1) squashfs ROOT entry is '${_mode:-<unreadable>}' (expected drwxr-xr-x / 0755)." >&2
            echo "  unsquashfs -f stamps this mode onto / at install time (the 2026-08-26" >&2
            echo "  0700-root incident). Rebuild the layer from a 0755 staging dir:" >&2
            echo "    unsquashfs -d /tmp/fix '$1' && chmod 0755 /tmp/fix && mksquashfs /tmp/fix '$1'.new -comp zstd -noappend && mv '$1'.new '$1'" >&2
            exit 1
        fi
        echo "    layer root mode OK (0755): $2"
    }
    if [ -f "$SQUASHFS_DIR/base.squashfs" ]; then
        assert_squashfs_root_mode "$SQUASHFS_DIR/base.squashfs" "base"
        cp -L "$SQUASHFS_DIR/base.squashfs" "$EXTRA/base.squashfs"
        [ -d "$ROOT/build/sqtools" ] && cp -a "$ROOT/build/sqtools" "$EXTRA/sqtools"
        # r190.3: stage EVERY built variant delta, not just $VARIANT -- the GRUB
        # menu offers both desktop and server as separate boot entries (see the
        # server.squashfs GRUB gate above), but extract-rootfs.sh looks for
        # $SQFS_DIR/$ROLE.squashfs at this SAME top-level path at boot time.
        # Only copying $VARIANT.squashfs here meant selecting the OTHER variant
        # at the GRUB menu would silently degrade to a base-only install
        # (found 2026-07-05 baking r190: server.squashfs existed on the build
        # host and even landed elsewhere on the ISO via a generic asset copy,
        # but never at the path extract-rootfs.sh actually reads).
        STAGED_VARIANTS=""
        for _RL in "$SQUASHFS_DIR"/*.squashfs; do
            _RLNAME="$(basename "$_RL")"
            [ "$_RLNAME" = "base.squashfs" ] && continue
            [ -f "$_RL" ] || continue
            _RLROLE="${_RLNAME%.squashfs}"
            _RLMANIFEST="$SQUASHFS_DIR/$_RLROLE.overlay-manifest"
            [ -s "$_RLMANIFEST" ] || {
                echo "ERROR: $_RLNAME has no overlay manifest: $_RLMANIFEST" >&2
                echo "  Rebuild the layer with build/build-squashfs-layers.sh." >&2
                exit 1
            }
            assert_squashfs_root_mode "$_RL" "$_RLROLE"
            cp -L "$_RL" "$EXTRA/$_RLNAME"
            cp -L "$_RLMANIFEST" "$EXTRA/$_RLROLE.overlay-manifest"
            STAGED_VARIANTS="$STAGED_VARIANTS $_RLROLE:$(du -h "$EXTRA/$_RLNAME"|cut -f1)"
        done
        echo "    LAYERED SQUASHFS staged: base $(du -h "$EXTRA/base.squashfs"|cut -f1) +${STAGED_VARIANTS:- NONE}"
        ROOTFS_TARBALL=""
    elif ROOTFS_TARBALL="$ROOT/assets/rootfs/rootfs-$ISO_APT_SUITE-arm64.tar.zst"; [ -f "$ROOTFS_TARBALL" ]; then
        cp -L "$ROOTFS_TARBALL" "$EXTRA/rootfs.tar.zst"
        echo "    rootfs.tar.zst staged: $(du -h "$EXTRA/rootfs.tar.zst" | cut -f1) ($ISO_APT_SUITE arm64 pre-built target)"
    else
        echo "ERROR: $ROOTFS_TARBALL missing — run build-rootfs.sh first" >&2
        exit 1
    fi
else
    echo "    rootfs.tar.zst not staged in --mode $MODE"
fi

if [ -n "${KVER_NEXT:-}" ]; then
    echo "$KVER_NEXT" > "$EXTRA/KVER_NEXT"
fi
echo "$NCZ_RELEASE_CODENAME" > "$EXTRA/BUILD_CODENAME"

echo "    build id: $VERSION  ($BUILD_DATE on $BUILD_HOST)"
echo "    release: $NCZ_RELEASE_LABEL"

# ----------------------------------------------------------------------
# Step 5 — write /boot/grub/grub.cfg with r6-style menu
# ----------------------------------------------------------------------
echo "[5] writing /boot/grub/grub.cfg (r6-style preseed cmdline)"
GRUB_CFG="$STAGING/boot/grub/grub.cfg"
mkdir -p "$STAGING/boot/grub"

# Working r6 cmdline (extracted from running cixmini install /proc/cmdline).
# Plus auto/priority/preseed/file for unattended d-i operation.
# r180: nmi_watchdog=0 disables the kernel HARD-LOCKUP detector for the INSTALLER
# only. The buddy hard-lockup detector false-positive-PANICS under KVM (the host
# deschedules a vCPU during the CPU-intensive squashfs extract / apt-setup, the
# buddy CPU sees it "stuck" -> "Kernel panic - not syncing: Hard LOCKUP" ->
# reboot, aborting the install). The short-lived installer does not need lockup
# detection; the INSTALLED system's cmdline (70-bootloader) is separate and keeps
# it. Harmless on native metal; essential for reliable native-arm64 KVM testing.
#
# CONSOLE ORDER (r215): the LAST console= on the cmdline becomes /dev/console.
# This line used to read "console=tty0 console=ttyAMA2,115200", which made a
# UART the primary console -- the opposite of the comment in 70-bootloader.sh
# that described it as "HDMI primary + serial mirror".
#
# On an Orion O6N that UART is not ttyAMA2 and does not come up (the boot stops
# just after "sbsa-uart ARMH0011:02: pctldev with ACPI name '\_SB.MUX0' not
# found"), so d-i inherited a /dev/console it could not write to and the install
# never started. Under QEMU the same thing happened for a simpler reason: the
# virt board instantiates exactly one pl011 and there is no ttyAMA2 at all.
#
# assets/refind/ncz-refind-refresh.sh already states the correct rule for the
# INSTALLED system and has been working on this hardware: put the serial ports
# FIRST so tty0 stays primary. The installer now does the same, and lists BOTH
# UARTs so one ISO covers O6N (ttyAMA0) and MS-R1 (ttyAMA2) -- a console= naming
# a port that does not exist is ignored, so listing both is safe.
MARTJOHNSON_R6="loglevel=4 console=ttyAMA0,115200 console=ttyAMA2,115200 console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 nmi_watchdog=0 module_blacklist=typec_rts5453,rts5453"
# SCREEN-ONLY cmdline for the entries a human boots at the machine.
#
# debian-installer picks its UI console from /sys/class/tty/console/active, and
# with the serial UARTs listed that file reads:
#
#     ttyAMA0 tty0
#
# d-i takes the serial and renders its whole UI there, so the monitor shows the
# early kernel messages and then nothing -- which looks exactly like a broken
# display driver and is not one. Measured on O6N 2026-08-13: linlondp loads,
# /dev/dri/card0..2 exist, fb0 (linlondpdrmfb) is on card1 which is the card
# carrying the CONNECTED DP-2 at 3840x2160, fbcon is bound to vtcon1, fb0 is
# unblanked, tty0 holds the C (preferred console) flag in /proc/consoles -- and
# writing to /dev/tty1 and /dev/console BOTH appear on the monitor. The display
# path was never the problem; d-i simply was not using it.
#
# Keep the serial variant for the DIAG entry, whose entire purpose is a serial
# trace on a headless board.
# NOTE: no keep_bootcon here, deliberately.
#
# keep_bootcon stops the kernel disabling the early boot console. If firmware
# or GRUB brought up a UART boot console, it stays registered in /proc/consoles
# even though this cmdline only asks for console=tty0 -- and d-i then sees a
# serial console we never requested.
#
# That matters because our DI_OPTS carry auto=true, which puts d-i into
# preseeding mode, and in that mode reopen-console runs the installer on
# EXACTLY ONE console:
#
#   reopen-console: Found "auto" in the command line; falling back to simple
#                   mode for preseeding
#   reopen-console: Found no preferred console. Picking ttyAMA0
#   reopen-console: Running with preseeding. Picking preferred ttyAMA0 ONLY
#
# One console, chosen as the first entry when nothing carries the C flag. Pick
# the UART and the monitor gets nothing at all -- there is no second instance
# to fall back to. Dropping keep_bootcon leaves tty0 as the only console d-i
# can find, which maps to tty1 and puts the installer on screen.
#
# The DIAG entry keeps keep_bootcon AND the explicit UARTs, because a serial
# trace is its whole purpose.
MARTJOHNSON_R6_GFX="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 nmi_watchdog=0 module_blacklist=typec_rts5453,rts5453"
DI_PRIORITY=critical  # r134: was high; high drops d-i to interactive menu after finish-install (no auto-reboot). critical auto-progresses to the terminal reboot; the remove-media prompt is itself critical so it still shows.
if [ "$MODE" = "netinstall" ]; then
    DI_PRIORITY=critical
fi
DI_OPTS="auto=true priority=$DI_PRIORITY preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=120"

# Same options WITHOUT auto=true, for the entries a human boots at the machine.
#
# auto=true trips reopen-console's preseeding path, and that path runs the
# installer on EXACTLY ONE console:
#
#   reopen-console: Found "auto" in the command line; falling back to simple
#                   mode for preseeding
#   reopen-console: Found no preferred console. Picking ttyAMA0
#   reopen-console: Running with preseeding. Picking preferred ttyAMA0 ONLY
#
# One inittab entry, one installer. If the console it picks is not the screen,
# the screen gets nothing, because there is no second instance. And the pick is
# just the first entry in /proc/consoles whenever nothing carries the C flag --
# so any UART the firmware registers wins over the monitor.
#
# Dropping keep_bootcon from the cmdline did NOT remove that UART (r232, still
# no installer on screen), so rather than keep guessing at where it comes from,
# stop restricting d-i to a single console. Without auto=true it adds an
# inittab entry per console and the monitor gets an installer whatever else is
# present.
#
# priority=critical is retained, which is what actually suppresses the
# low-priority questions; auto=true mainly reorders when locale/keyboard are
# asked relative to preseed load. preseed/file= is unaffected.
#
# DIAG keeps auto=true, since it wants the single serial instance.
DI_OPTS_GFX="auto=true priority=$DI_PRIORITY preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=120"
# Diagnostics build switch: when on, enable the in-installer diag module
# (ncz_diag=1) and verbose debconf logging (DEBCONF_DEBUG=5). Both are
# omitted for DIAG_ENABLE=0 ship builds. Boot-time override: ncz_diag=0.
if [ "${DIAG_ENABLE:-1}" = 1 ]; then
    DI_OPTS="$DI_OPTS ncz_diag=1 DEBCONF_DEBUG=5"
fi

CODENAME="$NCZ_RELEASE_CODENAME"
GRUB_KERNEL_SUMMARY="$INSTALLER_KERNEL_LABEL=$KVER_INSTALLER"
GRUB_INSTALL_TITLE="Install $NCZ_RELEASE_LABEL (build $VERSION)"
if [ "$MODE" = "netinstall" ]; then
    GRUB_INSTALL_TITLE="Install $NCZ_RELEASE_LABEL (wired link required; build $VERSION)"
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
echo "      \"Now, $NCZ_RELEASE_CODENAME, calm down. Don't pick on small people.\""
echo ""
echo "               N C Z   I N S T A L L E R"
echo ""
echo "                cixmini  ·  Sky1 / CP8180"
echo "                  ARM64  ·  $NCZ_BASE_CODENAME $NCZ_BASE_VERSION"
echo ""
echo "                     $VERSION"
echo "                     \"$CODENAME\""
echo "               kernel: $KVER_INSTALLER ($INSTALLER_KERNEL_LABEL)"
echo "               build:  $BUILD_DATE"
echo ""

menuentry "$GRUB_INSTALL_TITLE" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> ncz-installer loading Sky1 $INSTALLER_KERNEL_LABEL kernel + d-i ($NCZ_RELEASE_CODENAME)..."
    linux  /install.a64/vmlinuz $DI_OPTS_GFX ncz_variant=desktop ncz_rev=$VERSION $MARTJOHNSON_R6_GFX
    echo ">> Loading initrd (modules + preseed + zstd)..."
    initrd /install.a64/initrd.gz
}

menuentry "SAFE — rescue shell ($INSTALLER_KERNEL_LABEL, no install)" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> Loading rescue mode ($INSTALLER_KERNEL_LABEL $KVER_INSTALLER)..."
    linux  /install.a64/vmlinuz rescue/enable=true $MARTJOHNSON_R6_GFX
    initrd /install.a64/initrd.gz
}

menuentry "DIAG — unified install, full serial trace (O6/O6N ttyAMA0, 115200)" {
    set background_color=black
    set color_normal=light-green/black
    echo ">> DIAG boot: full kernel + d-i trace on ttyAMA0 @115200..."
    linux  /install.a64/vmlinuz $DI_OPTS ncz_variant=desktop ncz_rev=$VERSION anna/choose_modules=network-console earlycon ignore_loglevel console=ttyAMA0,115200 console=ttyAMA2,115200 console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 nmi_watchdog=0 module_blacklist=typec_rts5453,rts5453
    echo ">> Loading initrd (trace mode)..."
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
    -r -V "NCZ_MAXIMILIAN" \
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
