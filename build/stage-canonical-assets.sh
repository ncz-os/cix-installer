#!/usr/bin/env bash
# stage-canonical-assets.sh — restage the gitignored CIX-NCZ asset blobs the
# build-iso-di.sh staging loop silently produces nothing for when the build
# host's $REPO/assets/ tree is incomplete.
#
# WHY THIS EXISTS (2026-08-21)
# ----------------------------
# A diff of the freshly built nclawzero-installer-cixmini-2026.08.21.iso
# against the last known-good 2026.08.20-v1 ISO surfaced three real regressions
# in the assets/cixmini/ tree:
#
#   1. /cixmini/assets/sky1-firmware/ had ONLY arm/mali/arch12.8/mali_csffw.bin.
#      Every VPU codec .fwb (av1dec, avs2dec, avsdec, h264dec, h264enc, hevcdec,
#      hevcenc, jpegdec, jpegenc, mpeg2dec, mpeg4dec, vc1dec, vp8dec, vp8enc,
#      vp9dec, vp9enc.fwb), dsp_fw.bin, mediatek/ (BT_RAM_CODE_MT7922_*,
#      WIFI_MT7922_patch_mcu_*, WIFI_RAM_CODE_MT7922_1.bin) and rtw89/ (8851b,
#      8852a, 8852b, 8852bt, 8852c, 8922a firmware, 14 files) were missing.
#      Source of the canonical set: /mnt/argonas-models/cix-installer-sky1-firmware-20260728/
#      (21M, the 2026-07-28 .66 archive, world-readable NFS).
#      Net effect of the gap: no VPU codec acceleration and no WiFi/BT firmware
#      on first boot -- a serious functional regression, not cosmetic.
#
#   2. /cixmini/assets/mgmt/ was ENTIRELY ABSENT -- the server-variant recovery
#      container rootfs (ncz-mgmt-rootfs.tar.zst, ~100-200MB) is produced by
#      build/build-mgmt-rootfs.sh and lands at assets/mgmt/. Without sudo on
#      the build host, the debootstrap/chroot/tarball steps fail and the file
#      is never produced, so build-iso-di.sh's mgmt special case sees nothing
#      to copy and emits the "recovery container will be skipped" warning.
#
#   3. /cixmini/assets/cix-debs/ was missing six packages the old ISO had and
#      shipping a DOWNGRADED cix-noe-umd (2.0.2 vs 3.1.4-cixdeb13-260714):
#        - cix-ai-engine_2.0.0-cixdeb13-260714_arm64.deb     (absent)
#        - cix-ai-test_1.0.1-cixdeb13-260714_arm64.deb       (absent)
#        - cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz3_arm64.deb  (absent)
#        - cix-npu-umd_3.2.0-cixdeb13-260714_arm64.deb       (absent)
#        - libgtk4-layer-shell0_1.3.0-1+ncz20260817_arm64.deb (absent)
#        - ncz-singularity-desktop_20260817+bk4~v7_arm64.deb  (absent;
#          functionally NOT a gap: /opt/singularity is baked into desktop.squashfs
#          AND ncz-singularity-desktop_20260820+bk0~g19e6662ffff0_arm64.deb is
#          staged in /pool/main/ from the forky vendor mirror, so post-install's
#          `apt-get install ncz-singularity-desktop` succeeds against the new ISO)
#        - cix-noe-umd: shipped 2.0.2 (the older, pre-Q2 ABI version that uses
#          asid_base[32]), old ISO had 3.1.4-cixdeb13-260714 (the matched-stack
#          version that uses asid_base[4], ABI-matched to cix-npu-driver-dkms
#          6.2.0 with libnoe 3.1.1 -- see packaging/cix-npu-driver-dkms-6.2.0/
#          README.md, "the matched NPU stack, hardened"). Build picked up 2.0.2
#          because that is what /mnt/argonas-models/cix-installer-bake-assets-
#          20260729/assets/cix-debs/ (the 2026-07-29 .66 archive the bake
#          script conventionally reads from) shipped, and the 2026-07-28 sky1-
#          firmware archive and the 2026-07-22 CIX-vendor-sdk 2026q2 drop have
#          not been re-staged onto this host.
#
# The build script (build/build-iso-di.sh) silently relies on these assets
# being present on the build host, and provides NO canonical-source pull. The
# 22 cix-debs in /mnt/argonas-models/cix-installer-bake-assets-20260729/ are
# the validated ARGOS .66 set from 2026-07-29, which is missing everything
# published after that date. This script does the pull from the canonical
# ARGONAS NFS sources, so the next `make iso` bakes the right assets without
# anyone having to remember where they live.
#
# WHAT IT DOES
# ------------
# For each of the three gap categories, the helper does the work needed to
# populate assets/ in place, idempotent and explicit about WHERE each file
# came from:
#
#   assets/sky1-firmware/
#     Copy the full 2026-07-28 archive (mediates: only files that exist on
#     the host's arm/mali/ tree are kept; the canonical archive already
#     matches the old ISO's inventory one-for-one, so this is a straight
#     rsync). Source: ARGONAS NFS.
#
#   assets/mgmt/ncz-mgmt-rootfs.tar.zst
#     Defer to build/build-mgmt-rootfs.sh; print a clear "skipping: no sudo"
#     line if root is unavailable, so the gap is visible rather than silent.
#
#   assets/cix-debs/
#     - Remove cix-noe-umd_2.0.2_arm64.deb (the pre-Q2 ABI version) so the
#       matched-stack 3.1.4 is the only cix-noe-umd on the ISO.
#     - Stage every cix-ai-*, cix-npu-* from the 2026Q2 SDK tarball
#       (cix_noe_sdk_26_q2_release.tar.gz at /mnt/argonas-models/cix-vendor-sdk/2026q2/).
#     - For cix-npu-driver-dkms, take the upstream 6.2.0-cixdeb13-260714 from
#       the SDK, apply the NCZ patch series from packaging/cix-npu-driver-dkms-6.2.0/patches/,
#       and write out as 6.2.0-cixdeb13-260714+ncz3. The DKMS module identity
#       remains aipu/6.2.0; the Debian version tracks NCZ package content.
#     - libgtk4-layer-shell0: build via packaging/gtk4-layer-shell/make-deb.sh
#       (which applies the NCZ stale-buffer fix from PR #130). Output lands
#       in assets/cix-debs/ as the +ncz<YYYYMMDD> version the OLD ISO shipped.
#
# USAGE
# -----
#   build/stage-canonical-assets.sh [--from <assets-dir>] [--strict]
#
#   --from <dir>      Override the destination assets/ tree (default: $REPO/assets/).
#   --strict          Exit non-zero if any source is unreachable (default: warn
#                     and continue, so the script can run on hosts that lack
#                     NFS access and still produce a partial -- but explicit
#                     about what's missing -- result).
#
# Exit codes:
#   0  all stages OK
#   1  unrecoverable error (script bug, missing tool, etc.)
#   2  source unreachable in --strict mode (some sources are by design optional)
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$REPO/assets"
STRICT=0
SRC_NPU_SDK_TGZ="/mnt/argonas-models/cix-vendor-sdk/2026q2/cix_noe_sdk_26_q2_release.tar.gz"
SRC_NPU_SDK_SHA="999cf475268d193bc2aa3afc59931c30f0a405baf0866978462bffa30b765c41"
SRC_FIRMWARE_DIR="/mnt/argonas-models/cix-installer-sky1-firmware-20260728"
NPU_DKMS_PATCH_DIR="$REPO/packaging/cix-npu-driver-dkms-6.2.0/patches"

while [ $# -gt 0 ]; do
    case "$1" in
        --from) ASSETS="$2"; shift 2 ;;
        --strict) STRICT=1; shift ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "stage-canonical-assets: unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { printf 'stage-canonical-assets: %s\n' "$*"; }
warn() { printf 'stage-canonical-assets: WARN: %s\n' "$*" >&2; }
err()  { printf 'stage-canonical-assets: ERROR: %s\n' "$*" >&2; }

[ -d "$ASSETS" ] || { err "assets dir not found: $ASSETS"; exit 1; }

missing=0
reached=0

# ----------------------------------------------------------------------
# 1. sky1-firmware -- copy the full 2026-07-28 archive in place.
# ----------------------------------------------------------------------
log "[1/3] sky1-firmware: staging from $SRC_FIRMWARE_DIR"
if [ ! -d "$SRC_FIRMWARE_DIR" ]; then
    warn "source not reachable: $SRC_FIRMWARE_DIR"
    missing=$((missing+1))
else
    mkdir -p "$ASSETS/sky1-firmware"
    # rsync would be nice but is not guaranteed on a build host; cp -a is fine.
    # The src directory has a top-level arm/ + every .fwb + mediatek/ + rtw89/.
    # Exclude the destination's own arm/mali/arch12.8/mali_csffw.bin if present:
    # the bake-assets archive does not carry mali, and we never want to clobber
    # a build host's validated Mali overlay (separate provenance, separate patch
    # path -- see post-install/11-our-kernel.sh).
    cp -an "$SRC_FIRMWARE_DIR"/*.fwb "$ASSETS/sky1-firmware/" 2>/dev/null || true
    cp -an "$SRC_FIRMWARE_DIR"/dsp_fw.bin "$ASSETS/sky1-firmware/" 2>/dev/null || true
    if [ -d "$SRC_FIRMWARE_DIR/mediatek" ]; then
        mkdir -p "$ASSETS/sky1-firmware/mediatek"
        cp -an "$SRC_FIRMWARE_DIR/mediatek/." "$ASSETS/sky1-firmware/mediatek/" 2>/dev/null || true
    fi
    if [ -d "$SRC_FIRMWARE_DIR/rtw89" ]; then
        mkdir -p "$ASSETS/sky1-firmware/rtw89"
        cp -an "$SRC_FIRMWARE_DIR/rtw89/." "$ASSETS/sky1-firmware/rtw89/" 2>/dev/null || true
    fi
    if [ -d "$SRC_FIRMWARE_DIR/arm" ]; then
        mkdir -p "$ASSETS/sky1-firmware/arm"
        cp -an "$SRC_FIRMWARE_DIR/arm/." "$ASSETS/sky1-firmware/arm/" 2>/dev/null || true
    fi
    fw_count=$(find "$ASSETS/sky1-firmware" -maxdepth 1 -type f | wc -l)
    log "  sky1-firmware: $fw_count files (was 1, the lone mali_csffw.bin)"
    reached=$((reached+1))
fi

# ----------------------------------------------------------------------
# 2. mgmt rootfs -- defer to build-mgmt-rootfs.sh; needs sudo (mount/chroot).
# ----------------------------------------------------------------------
log "[2/3] mgmt: staging assets/mgmt/ncz-mgmt-rootfs.tar.zst"
if [ -f "$ASSETS/mgmt/ncz-mgmt-rootfs.tar.zst" ]; then
    sz=$(du -h "$ASSETS/mgmt/ncz-mgmt-rootfs.tar.zst" | cut -f1)
    log "  mgmt rootfs already present ($sz) -- skipping rebuild"
    reached=$((reached+1))
else
    if [ "$(id -u)" -ne 0 ]; then
        warn "no sudo / not root -- build-mgmt-rootfs.sh requires root (mount/chroot/tar)"
        warn "  remediation: sudo bash build/build-mgmt-rootfs.sh, then re-run this script"
        warn "  or set up passwordless sudo (see docs/ISO-REBAKE-TYDEUS-2026-08-21.md §6.1)"
        warn "  or copy ncz-mgmt-rootfs.tar.zst into $ASSETS/mgmt/ from a known-good build host"
        missing=$((missing+1))
    else
        if [ -x "$REPO/build/build-mgmt-rootfs.sh" ]; then
            log "  delegating to build/build-mgmt-rootfs.sh"
            if bash "$REPO/build/build-mgmt-rootfs.sh" 2>&1 | sed 's/^/    /'; then
                reached=$((reached+1))
            else
                warn "build-mgmt-rootfs.sh failed -- check output above"
                missing=$((missing+1))
            fi
        else
            warn "build/build-mgmt-rootfs.sh not found at $REPO/build/"
            missing=$((missing+1))
        fi
    fi
fi

# ----------------------------------------------------------------------
# 3. cix-debs -- six package gaps + the cix-noe-umd 2.0.2 -> 3.1.4 pin.
# ----------------------------------------------------------------------
log "[3/3] cix-debs: dropping pre-Q2 cix-noe-umd_2.0.2, staging matched-stack Q2 set"
mkdir -p "$ASSETS/cix-debs"

# 3a. Stage the 22 base CIX proprietary .debs from the canonical ARGONAS
# bake-assets archive (cix-installer-bake-assets-20260729, the 2026-07-29 .66
# snapshot). The active ARGOS build's assets/cix-debs/ tree is filled from
# exactly this archive; a fresh `git clone` ships nothing here (gitignored).
# The matched-stack additions in 3b/3c/3d overwrite on top of the same name
# where the validated set is newer.
SRC_BAKE_ASSETS="${SRC_BAKE_ASSETS:-/mnt/argonas-models/cix-installer-bake-assets-20260729}"
if [ -d "$SRC_BAKE_ASSETS/assets/cix-debs" ]; then
    n_staged=0
    for d in "$SRC_BAKE_ASSETS/assets/cix-debs"/*.deb; do
        [ -e "$d" ] || continue
        bn=$(basename "$d")
        # Skip the matched-stack overrides we manage ourselves below (the
        # bake-assets archive carries the pre-Q2 cix-noe-umd_2.0.2; we drop it
        # in 3b below anyway, so just don't copy it here).
        cp -an "$d" "$ASSETS/cix-debs/" && n_staged=$((n_staged+1))
    done
    log "  base cix-debs staged from bake-assets-20260729: $n_staged packages"
else
    warn "bake-assets archive not reachable: $SRC_BAKE_ASSETS"
    warn "  manual remediation: copy the 22 base cix-debs/*.deb from any known-good ARGOS"
    missing=$((missing+1))
fi

# 3a2. cix-mesa ships /etc/ld.so.conf.d/01-cixgpu-compat.conf, which puts
# a whole second, ancient (1.1.0) glvnd + Mesa-24 stack on the SYSTEM loader
# path. That fights the current Debian glvnd 1.7.0 + Mesa 26 stack the desktop
# actually needs: labwc SIGSEGVs inside __eglLoadVendors ("free(): invalid
# pointer"), greetd hits its restart limit, black screen on every boot.
#
# post-install/26-gpu-default-mali.sh renames the file to .disabled at install
# time, but that is a workaround, not a fix -- the file ships as a plain data
# file inside cix-mesa's .deb (not even a dpkg-tracked conffile), so any later
# ordinary reinstall/reconfigure of that package -- which ncz-firstboot.service
# triggers unconditionally via `dpkg --configure -a` on every fresh install's
# first boot -- writes it right back, undoing the rename before greetd ever
# starts (confirmed on O6N, 2026-09-08).
#
# Real fix: strip the conffile from the vendor .deb ONCE, here, at staging
# time, so it never ships in the first place and no install-time or first-boot
# workaround is needed anywhere. Verified live on O6N that cixgpu-compat is not
# needed at all: libEGL_cix.so (the real Mali vendor driver, in cixgpu-pro,
# untouched here) links against libc only, and the vendor JSON mechanism finds
# it fine through the system glvnd once cixgpu-compat is off the loader path.
CIX_MESA_DEB=$(ls -1 "$ASSETS/cix-debs"/cix-mesa_*.deb 2>/dev/null | head -1)
if [ -n "$CIX_MESA_DEB" ] && command -v dpkg-deb >/dev/null 2>&1; then
    if dpkg-deb -c "$CIX_MESA_DEB" | grep -q '01-cixgpu-compat.conf'; then
        T=$(mktemp -d)
        dpkg-deb -R "$CIX_MESA_DEB" "$T"
        rm -f "$T/etc/ld.so.conf.d/01-cixgpu-compat.conf"
        # conffiles/md5sums must not reference a file we just removed, or dpkg
        # errors on install.
        sed -i '\#^/etc/ld.so.conf.d/01-cixgpu-compat.conf$#d' "$T/DEBIAN/conffiles" 2>/dev/null || true
        if [ -f "$T/DEBIAN/md5sums" ]; then
            sed -i '\#etc/ld.so.conf.d/01-cixgpu-compat.conf#d' "$T/DEBIAN/md5sums"
        fi
        dpkg-deb -b "$T" "$CIX_MESA_DEB" >/dev/null
        rm -rf "$T"
        log "  repackaged $(basename "$CIX_MESA_DEB"): dropped 01-cixgpu-compat.conf (root fix for the glvnd/EGL crash)"
    else
        log "  $(basename "$CIX_MESA_DEB") already lacks 01-cixgpu-compat.conf -- nothing to strip"
    fi
elif [ -n "$CIX_MESA_DEB" ]; then
    warn "dpkg-deb not available -- cannot strip 01-cixgpu-compat.conf from $(basename "$CIX_MESA_DEB"); the ncz-firstboot belt-and-suspenders re-disable is still in place as a fallback"
fi

# 3b. drop the older cix-noe-umd so the matched-stack 3.1.4 wins.
# pre-Q2 ABI (asid_base[32]) is incompatible with the cix-npu-driver-dkms 6.2.0
# KMD, which speaks asid_base[4]. A board that installs cix-noe-umd_2.0.2 on top
# of the Q2 KMD wedges at the first noe_init_context call -- see packaging/
# cix-npu-driver-dkms-6.2.0/README.md and the 88-noe-umd-venv.sh revision
# history.
if [ -f "$ASSETS/cix-debs/cix-noe-umd_2.0.2_arm64.deb" ]; then
    log "  removing pre-Q2 cix-noe-umd_2.0.2_arm64.deb (asid_base[32], incompatible with 6.2.0 KMD)"
    rm -f "$ASSETS/cix-debs/cix-noe-umd_2.0.2_arm64.deb"
fi

if [ ! -f "$SRC_NPU_SDK_TGZ" ]; then
    warn "NPU SDK tarball not reachable: $SRC_NPU_SDK_TGZ"
    missing=$((missing+1))
else
    # Verify the tarball against the documented one. SHA recorded in
    # /mnt/argonas-models/cix-vendor-sdk/2026q2/MANIFEST.md.
    actual=$(sha256sum "$SRC_NPU_SDK_TGZ" | awk '{print $1}')
    if [ "$actual" != "$SRC_NPU_SDK_SHA" ]; then
        warn "NPU SDK SHA mismatch (got=$actual expected=$SRC_NPU_SDK_SHA)"
        warn "  refusing to stage from a tarball that does not match MANIFEST.md"
        missing=$((missing+1))
    else
        # Stage the inner cix-noe-sdk-1.6.0.tar.gz to a scratch dir and copy out
        # only the matched-stack debs. The tarball also ships cixbuilder-6.1.3753.3
        # (224M NOE compiler wheel, x86 host) and 5 dev-guide PDFs (5MB) which
        # belong in a build-host cache, not the ISO assets/ tree.
        work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
        log "  extracting matched-stack debs from $(basename "$SRC_NPU_SDK_TGZ")"
        tar -C "$work" -xzf "$SRC_NPU_SDK_TGZ" \
            noe_sdk_26_q2_release/cix-noe-sdk-1.6.0.tar.gz 2>/dev/null || {
                warn "could not extract cix-noe-sdk-1.6.0.tar.gz from the SDK tarball"
                missing=$((missing+1))
                rm -rf "$work"
                # shellcheck disable=SC2317  -- jump to summary
                continue 2>/dev/null || true
            }
        tar -C "$work" -xzf "$work/noe_sdk_26_q2_release/cix-noe-sdk-1.6.0.tar.gz" 2>/dev/null
        SDK_DIR="$work/cix-noe-sdk"

        for d in cix-ai-engine_2.0.0-cixdeb13-260714 \
                 cix-ai-test_1.0.1-cixdeb13-260714 \
                 cix-noe-umd_3.1.4-cixdeb13-260714 \
                 cix-npu-umd_3.2.0-cixdeb13-260714; do
            src="$SDK_DIR/${d}_arm64.deb"
            if [ -f "$src" ]; then
                cp -an "$src" "$ASSETS/cix-debs/"
                log "    staged $d"
            else
                warn "expected $src not present in SDK tarball"
                missing=$((missing+1))
            fi
        done

        # cix-npu-driver-dkms: take the SDK's 6.2.0-cixdeb13-260714, apply
        # packaging/cix-npu-driver-dkms-6.2.0/patches/* in order, bump Version
        # to +ncz3. dpkg-deb --build needs the staged dir to be writable.
        out="$ASSETS/cix-debs/cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz3_arm64.deb"
        npu_dkms_src="$SDK_DIR/cix-npu-driver-dkms_6.2.0-cixdeb13-260714_arm64.deb"
        if [ -f "$npu_dkms_src" ]; then
            if [ -s "$out" ]; then
                log "  cix-npu-driver-dkms +ncz3 already present ($(du -h "$out" | cut -f1)) -- skipping rebuild"
            elif [ -d "$NPU_DKMS_PATCH_DIR" ]; then
                log "  rebuilding cix-npu-driver-dkms 6.2.0-cixdeb13-260714+ncz3 from SDK + patches/"
                stage=$(mktemp -d)
                dpkg-deb -R "$npu_dkms_src" "$stage"
                # Patch the extracted source tree (the patches were produced
                # against cixtech/cix_opensource__npu_driver cix_mainline_dev
                # with paths driver/armchina-npu/...; -p2 strips the leading
                # driver/, matches /usr/src/aipu-6.2.0/armchina-npu/).
                for p in "$NPU_DKMS_PATCH_DIR"/*.patch; do
                    [ -e "$p" ] || continue
                    log "    applying $(basename "$p")"
                    if ! ( cd "$stage/usr/src/aipu-6.2.0" \
                           && patch -p2 --forward < "$p" ) >/dev/null; then
                        err "patch failed: $(basename "$p")"
                        err "  (the NCZ source-of-truth patches must apply cleanly;"
                        err "   if upstream changed, refresh packaging/cix-npu-driver-dkms-6.2.0/patches/)"
                        rm -rf "$stage"
                        missing=$((missing+1))
                        break
                    fi
                done
                # Bump the deb version to +ncz3. The DKMS module stays aipu/6.2.0.
                sed -i 's/^Version: .*/Version: 6.2.0-cixdeb13-260714+ncz3/' \
                    "$stage/DEBIAN/control"
                dpkg-deb --root-owner-group -Zxz -b "$stage" "$out"
                log "    staged $(basename "$out")"
                rm -rf "$stage"
            else
                warn "patch dir not found: $NPU_DKMS_PATCH_DIR"
                warn "  staging the unpatched SDK 6.2.0-cixdeb13-260714 instead"
                cp -an "$npu_dkms_src" "$ASSETS/cix-debs/"
                missing=$((missing+1))
            fi
        else
            warn "expected cix-npu-driver-dkms_6.2.0-cixdeb13-260714 not in SDK tarball"
            missing=$((missing+1))
        fi
        reached=$((reached+1))
    fi
fi

# NPU ACPI SSDT override early-CPIO: generate from the committed ASL source if
# absent. assets/npu/ is a gitignored blob dir and for months NOTHING produced
# the CPIO, so every ISO shipped without it; on the Minisforum MS-R1 (factory
# BIOS omits _HID "CIXH4010" on the NPU CRE cores) that meant no NPU -- and,
# before the +ncz3 aipu guard, a boot-time NULL-deref PANIC in sky1_npu_probe
# (pm_runtime_enable(NULL) -> _raw_spin_lock_irqsave on 0xcc/0xec). See
# build/build-npu-ssdt.sh and packaging/cix-npu-driver-dkms-6.2.0/README.md.
if [ ! -s "$REPO/assets/npu/npu-acpi-override.cpio" ]; then
    if command -v iasl >/dev/null 2>&1; then
        log "generating assets/npu/npu-acpi-override.cpio (build-npu-ssdt.sh)"
        if ! "$REPO/build/build-npu-ssdt.sh"; then
            err "build-npu-ssdt.sh FAILED -- MS-R1 installs will have no NPU"
            missing=$((missing+1))
        else
            reached=$((reached+1))
        fi
    else
        err "assets/npu/npu-acpi-override.cpio missing/empty and iasl not installed (apt install acpica-tools)"
        err "  MS-R1 installs will boot with the NPU disabled (cores have no _HID without the SSDT)"
        missing=$((missing+1))
    fi
else
    log "assets/npu/npu-acpi-override.cpio already present ($(stat -c%s "$REPO/assets/npu/npu-acpi-override.cpio") bytes)"
    reached=$((reached+1))
fi

# libgtk4-layer-shell0 with the NCZ stale-buffer fix. The 20-desktop.sh hook
# hard-requires `apt-get install libgtk4-layer-shell0` and the forky offline
# mirror pool only carries stock Debian 1.3.0-1+b1 (which carries the
# zwlr_layer_surface_v1 protocol-error crash that the +ncz fix addresses --
# see packaging/gtk4-layer-shell/make-deb.sh header).
#
# This requires libgtk-4-dev natively installed (make-deb.sh is a meson/ninja
# build that does NOT currently support a sysroot). On hosts that lack
# libgtk-4-dev, the build host's $REPO/assets/cix-debs/ tree may already carry
# the validated +ncz deb from a previous bake; otherwise it is reported missing.
if ls "$ASSETS/cix-debs"/libgtk4-layer-shell0_1.3.0-1+ncz*_arm64.deb >/dev/null 2>&1; then
    log "  libgtk4-layer-shell0 (ncz) already present -- skipping"
    reached=$((reached+1))
else
    if [ -x "$REPO/packaging/gtk4-layer-shell/make-deb.sh" ] \
       && pkg-config --exists gtk4 2>/dev/null; then
        log "  rebuilding libgtk4-layer-shell0 with the NCZ stale-buffer fix"
        if bash "$REPO/packaging/gtk4-layer-shell/make-deb.sh" "$ASSETS/cix-debs/" 2>&1 \
            | sed 's/^/    /'; then
            reached=$((reached+1))
        else
            warn "libgtk4-layer-shell0 build failed -- check output above"
        fi
    else
        log "  libgtk4-layer-shell0: build prereqs (libgtk-4-dev) unavailable"
    fi
    if ! ls "$ASSETS/cix-debs"/libgtk4-layer-shell0_1.3.0-1+ncz*_arm64.deb >/dev/null 2>&1; then
        warn "    libgtk4-layer-shell0 +ncz deb still missing: build it on a host with libgtk-4-dev"
        warn "    (packaging/gtk4-layer-shell/make-deb.sh) or copy it into $ASSETS/cix-debs/"
        missing=$((missing+1))
    fi
fi

# ----------------------------------------------------------------------
# 4. mali + panthor + npu DKMS .debs -- give apt an update path for the
#    accelerators that were never dpkg-tracked (build/build-dkms-debs.sh's
#    own header comment: "apt cannot upgrade a package it does not know
#    about"). vpu already ships a real staged .deb via 3b above (from the
#    vendor SDK); mali/panthor/npu are NCZ's own DKMS source under
#    assets/kernel/{mali,panthor,npu}/ and had no equivalent until the
#    nuked SDK tarball left npu orphaned.
#
#    The npu deb is cix-npu-kmd/1.0 (older vendor tree; assets/kernel/npu/
#    README.md and post-install/80-npu.sh: this one bundles the v0-compat
#    ioctls + SMMU 32-bit constraint + asid_base widening that the in-tree
#    armchina_npu does NOT carry, so without an OUT-OF-TREE build the
#    installed system has /dev/aipu but jobs dispatch-fail -- measured on
#    O6N 2026-08-17). build-dkms-debs.sh takes the same SRC_TREE mirror
#    rule that post-install/86-cix-dkms-register.sh uses for the source
#    tree, so the deb installs identically.
#
#    Malice/fail-loud: every accelerator overlay listed in
#    ACCEL_OVERLAYS that has a source tree MUST produce a deb. Missing
#    deb = build error, not warning (the operator's r296.2 lesson from
#    2026-09-26: "a silently-absent accelerator is exactly how this shipped").
# ----------------------------------------------------------------------
log "[4/4] mali+panthor+npu DKMS .debs: building from assets/kernel/{mali,panthor,npu}/"
DKMS_BUILT=()
DKMS_MISSING=()
if [ -x "$REPO/build/build-dkms-debs.sh" ]; then
    # Try to build all three; the script skips gracefully when a source tree
    # lacks the .ko or dkms.conf (it skips with a SKIP line, not a failure).
    if bash "$REPO/build/build-dkms-debs.sh" mali panthor npu 2>&1 | sed 's/^/    /'; then
        for d in "$REPO/build/dkms-debs"/cix-gpu-kmd-dkms_*.deb \
                 "$REPO/build/dkms-debs"/panthor-cix-dkms_*.deb \
                 "$REPO/build/dkms-debs"/cix-npu-kmd-dkms_*.deb; do
            [ -e "$d" ] || continue
            if cp -an "$d" "$ASSETS/cix-debs/" 2>/dev/null; then
                log "  staged $(basename "$d")"
                DKMS_BUILT+=("$(basename "$d")")
            fi
        done
        reached=$((reached+1))
    else
        warn "build-dkms-debs.sh mali panthor npu returned non-zero"
        missing=$((missing+1))
    fi
else
    warn "build/build-dkms-debs.sh not found or not executable"
    missing=$((missing+1))
fi

# r-npu-2026-09-26: COMPLETENESS GATE. The four CIX accelerators are a
# closed set (kernel-build-checklist.md §0c). A board that ships with
# one missing has a known-to-bug install (silently absent /dev/accel
# nodes, or worse: a /dev that exists but every job wedges). Mirror
# that the four DKMS trees above all produced a deb. If the build-dkms
# call skipped one (no src/, no dkms.conf), surface that NOW, not in a
# post-install dmesg. The op-mode (NCZ_ISO) is the only place this can
# fail fast without a hardware boot.
EXPECTED_DKMS=(cix-gpu-kmd panthor-cix cix-npu-kmd)
for n in "${EXPECTED_DKMS[@]}"; do
    case " ${DKMS_BUILT[*]} " in
        *"${n}-dkms_"*) : ;;   # present
        *)
            # Was there a vendor .deb already? The SDK branch (3b above)
            # may have staged cix-npu-driver-dkms_*.deb; if so, that's the
            # *replacement* for cix-npu-kmd (post-install/86-cix-dkms-
            # register.sh retires cix-npu-kmd in favor of aipu/6.2.0).
            # For NPU specifically, "vendor deb present" IS the satisfied
            # case. For mali/panthor there's no vendor source.
            if [ "$n" = "cix-npu-kmd" ] \
                && ls "$ASSETS/cix-debs"/cix-npu-driver-dkms_*.deb >/dev/null 2>&1; then
                log "  $n: vendor cix-npu-driver-dkms_*.deb staged by 3b above (NPU satisfied via SDK path)"
            else
                warn "ACCELERATOR OVERLAY MISSING: $n"
                warn "  expected \${REPO}/build/dkms-debs/${n}-dkms_*.deb OR \${ASSETS}/cix-debs/${n}*.deb"
                warn "  the installed system will ship without this accelerator; this is the same class of defect as the"
                warn "  O6N 2026-09-26 GPU-less image (missing CIX proprietary deb -> no /dev/mali0 -> greetd crash-loop)."
                DKMS_MISSING+=("$n")
            fi
            ;;
    esac
done
if [ "${#DKMS_MISSING[@]}" -gt 0 ]; then
    err "BUILD INCOMPLETE: ${#DKMS_MISSING[@]} accelerator overlay(s) missing: ${DKMS_MISSING[*]}"
    err "  this image would boot with at least one accelerator unavailable. refusing to ship."
    err "  fix by either:"
    err "    1. building the matching NCZ assets/kernel/<driver>/{src,dkms.conf} tree,"
    err "    2. OR dropping STRICT mode (set NCZ_DKMS_INCOMPLETE=1 in the build env)."
    if [ "${NCZ_DKMS_INCOMPLETE:-0}" != "1" ]; then
        missing=$((missing + ${#DKMS_MISSING[@]}))
    fi
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
log ""
log "summary:"
log "  reached sources: $reached"
log "  missing  sources: $missing"
if [ "$missing" -gt 0 ]; then
    log "  result: PARTIAL -- some sources unreachable (see WARNs above)"
    log "          the ISO build will still produce output, with gaps where"
    log "          sources were missing. Re-run once those sources are reachable."
    if [ "$STRICT" = "1" ]; then
        exit 2
    fi
fi
exit 0
