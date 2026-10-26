#!/bin/bash
# build-kernel-debs.sh — debianize the staged cixmini kernel for APT/OTA.
#
# Produces two .debs under build/kernel-debs/:
#   cixmini-boot_<ver>_arm64.deb           — OTA-safe systemd-boot entry hook
#   linux-image-cixmini_<KVER>_arm64.deb    — mainline kernel (assets/kernel/mainline),
#                                             the only PACKAGED Sky1 channel
#   linux-headers-cixmini_<KVER>_arm64.deb  — matching headers for DKMS rebuilds
#
# These are the OTA-upgradable form of post-install/10-our-kernel.sh +
# build/70-bootloader.sh. The bootloader hook is initrd-less and never wipes
# the ESP — it only adds/updates entries for currently-installed kernels,
# matching the validated r97/r98 boot exactly.
#
# 2026-08-21: legacy 7.0.12-cix-sky1-next channel retired.
# The shipping channel is named "mainline" (assets/kernel/mainline): the single
# unified 7.3 Sky1 kernel (7.3.0-rc7-sky1-ncz, r290). There is no edge channel
# (retired 2026-10-05). Only mainline is packaged. linux-image-cixmini-legacy and linux-image-cixmini-lts are gone
# from the build; the empty-transitional-package trick that used to depend on
# the legacy channel is also gone.
set -euo pipefail
umask 022   # reproducible file modes: the version gate compares content, modes included

REPO="$(cd "$(dirname "$0")/.." && pwd)"   # cix-installer/
ASSETS="$REPO/assets/kernel"
NPU="$REPO/assets/npu"
OUT="$REPO/build/kernel-debs"

# ---------------------------------------------------------------------------
# Reproducible .debs (r203 arm64 provenance finding, 2026-10-10).
#
# The kernel packages must be byte-identical across runs and hosts or their
# reviewed ledger rows in manifests/ncz-packages.tsv can never match: two
# builds of the SAME staged kernel 20 s apart produced four different sha256s
# because every staged file kept its wall-clock mtime and Installed-Size came
# from `du -sk` (allocated blocks, filesystem-dependent -- the same defect the
# peer fixed for ncz-apt-policy 1.0.1).  Anchor SOURCE_DATE_EPOCH to the PINNED
# substrate snapshot epoch (manifests/base.pin), NOT the packaging script's own
# commit time and NOT the build's global git-commit epoch: a commit anchor moves
# on every rebase (the arm64 "pinned reproduction" is a rebased branch) and
# forces a ledger re-derivation each time; the snapshot column is the stable
# build-wide temporal anchor.  Then clamp every staged mtime to it before
# dpkg-deb and compute Installed-Size from the actual file sizes.  The bytes
# change only when the package content changes.
_kernel_sde_stamp="$(awk -F'\t' '$1=="arm64"{print $4}' "$REPO/manifests/base.pin" 2>/dev/null | head -1)"
SOURCE_DATE_EPOCH="$(python3 -I "$REPO/build/lib/reproducible.py" snapshot-epoch \
    "${_kernel_sde_stamp:-20261005T120000Z}" 2>/dev/null || true)"
: "${SOURCE_DATE_EPOCH:=1791201600}"   # 20261005T120000Z fallback
export SOURCE_DATE_EPOCH
# host-independent Installed-Size (KiB, rounded up): sum real file sizes
installed_size_kb() {
    find "$1" -type f -printf '%s\n' 2>/dev/null \
        | awk '{s+=$1} END{printf "%d", (s+1023)/1024}'
}
# normalise modes + clamp every member mtime to SOURCE_DATE_EPOCH so dpkg-deb
# emits a deterministic control.tar + data.tar
repro_finalize_root() {
    local r="$1"
    find "$r" -type d -exec chmod 0755 {} + 2>/dev/null || true
    find "$r" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
}
# Default revision must never be older than what is already published, or the
# "new" kernel is a DOWNGRADE and apt silently keeps the installed one. r211 is
# the published rc7 build (2026-08-11); bump this when the kernel is rebuilt.
# r245 = the binder-enabled 7.2 build (CONFIG_ANDROID_BINDER_IPC/BINDERFS=y),
# staged in assets/kernel/edge and KVM-boot-gated. r212 was the last
# pre-binder revision. Bumping this is NOT cosmetic: the revision is the only
# thing that distinguishes the two packages, because the kernel VERSION string
# is 7.2.0-sky1-ncz in both. Leaving it at r212 would ship a binder kernel
# labelled as the non-binder one -- apt would consider it already installed,
# and anyone reading the version would be told something false.
# r246 = first OTA install with the headers .deb package fix included; same
# kernel VERSION, but the postinst is the OTA-DKMS-HEADER-FIX-2026-08-21
# sequence, so a board coming from r245 will accept the upgrade cleanly
# (without it, every r245 board has manually-fixed headers on disk that the
# r246 postinst must reconcile against).
# r247 = headers .deb postinst sequencing finalized; same fix, no behaviour
# change visible to the user. The revision is bumped because nothing else is.
# r248 = same fix, identical control; the bump exists to outrank any local
# rebuild of r247 that did NOT include the fix, so an installed board picks
# up the real fix on the next apt run.
# r249 = real post-0220/0221 kernel rebuild; also teaches the OTA boot helper
# to discover the current -sky1-ncz edge kernel suffix instead of only the
# retired -cix-sky1-next suffix.
# r250 = v7.2 MAINLINE release rebuild after the rc7 regression; same
# KERNELRELEASE, but the Image source identity is the v7.2 tag commit.
# r251 = same v7.2 release base plus patch 0222 for lost USB2 connect events
# on powered but runtime-suspended Sky1 hub ports.
# r252 = patch 0223, DisplayPort-audio ELD fix; same KERNELRELEASE.
# r253 = same r252 kernel content, but linux-headers-cixmini postinst now
# finds /usr/sbin/dkms even when dpkg invokes it with a non-sbin PATH.
# r254 = srcshelton audio follow-up: fold DPTX shutdown cleanup into 0223
# and add the reconciled CIX ASoC/I2S/HDMI-codec hardening patch as 0224.
# r255 = same r254 kernel content -- fixes linux-headers-cixmini postinst
# to FORCE dkms rebuilds (dkms remove + autoinstall) instead of relying on
# plain `dkms autoinstall`, which silently skips a package DKMS already
# considers installed for KVER. Confirmed live on O6N: a stale mali_kbase
# from a prior manual DKMS fix caused a symbol-CRC mismatch that hung the
# default boot after upgrading straight from r252 to r254.
# r256 = same r254 kernel content -- r255's fix was itself wrong: `dkms
# remove -k $KVER` on a package's only remaining kernel version drops it
# from `dkms status` entirely, not just its KVER build, so the follow-up
# `dkms autoinstall` had nothing registered left to rebuild -- confirmed
# live on O6N, dkms status came back completely empty after r255's
# postinst ran. r256 instead force-builds+force-installs each already-
# registered package directly (dkms build/install --force), matching the
# manual recovery that actually worked, and only uses `dkms autoinstall`
# afterward as a catch-all for genuinely new registrations.

# r257 = display-cluster synthesis (patch 0225) + NFS client + vhost-net.
# 0225 makes the driver synthesize the linlondp cluster when firmware omits
# the CIXH50C0 ACPI device, so MS-R1 gets ONE DRM card instead of four.
# Measured cause of Chromium losing gpu_compositing on MS-R1 (its Ozone layer
# logs "Preferred drm_render_node not found, picking linlondp" and then
# disables gpu compositing; O6N, which has a single card, shows neither).
# Also adds CONFIG_NFS_FS/NFS_V4/SUNRPC -- absent entirely before, so no Sky1
# board on this kernel could mount the NFS artifact-store shares -- and CONFIG_VHOST_NET
# for KVM hosts.
# r258 = r257 (patch 0225 display-cluster synthesis + NFS client + vhost-net)
# PLUS the restored desktop capability set. The defconfig was derived from a
# board-bringup config and whole categories were simply absent: CONFIG_TUN was
# missing, so NO VPN of any kind could work (OpenVPN/WireGuard/Tailscale/
# ZeroTier all need /dev/net/tun) while wireguard-tools shipped in
# manifests/desktop.pkgs against a kernel that could not run it. Same shape for
# USB audio and webcams (SND_USB_AUDIO, USB_VIDEO_CLASS), USB-serial adapters
# (CP210x/FTDI/CH341/PL2303 -- on a dev-board distro whose own docs drive
# boards over ttyUSB), exFAT, CIFS, LUKS (DM_CRYPT) and Bluetooth HID.
# All added as modules, so the boot path is unchanged. Verified present in the
# BUILT .config, not just the defconfig -- olddefconfig silently drops symbols
# whose dependencies are unmet.
# The revision must follow the kernel that is actually staged. It was a constant
# (r258) while assets/kernel/edge pointed at r277, so images shipped
# linux-image-cixmini 7.2.8-sky1-ncz+r258, which sorts BELOW the +r277 already
# installed on boards from the previous image and silently loses to it in apt.
# Derive it from the staging directory name (rNNN-<kver>-...) and refuse a
# BUILD_REV override that is older than the staged directory.
# Read the symlink TARGET STRING (no -f): resolving it needs the NFS staging tree mounted, and
# an unreachable mount must not silently fall back to the stale constant.
# The staged release name is tracked in assets/kernel/mainline.release; the
# link (build/link-kernel-mainline.sh) is read only when that file is absent.
_MAINLINE_DIR_NAME="$(sed 's/#.*//' "$REPO/assets/kernel/mainline.release" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$_MAINLINE_DIR_NAME" ]; then
    _MAINLINE_LINK="$(readlink "$REPO/assets/kernel/mainline" 2>/dev/null || true)"
    _MAINLINE_DIR_NAME="$(basename "${_MAINLINE_LINK:-mainline}")"
fi
_MAINLINE_REV=""
case "$_MAINLINE_DIR_NAME" in r[0-9]*-*) _MAINLINE_REV="${_MAINLINE_DIR_NAME%%-*}" ;; esac
case "${_MAINLINE_REV#r}" in *[!0-9]*) _MAINLINE_REV="" ;; esac
BUILD_REV="${BUILD_REV:-${_MAINLINE_REV:-r258}}"
if [ -n "$_MAINLINE_REV" ] && [ "${BUILD_REV#r}" -lt "${_MAINLINE_REV#r}" ] 2>/dev/null; then
    echo "ERROR: BUILD_REV=$BUILD_REV is older than the staged kernel directory ($_MAINLINE_DIR_NAME); refusing to build a downgrade-labelled kernel deb" >&2
    exit 1
fi

# cixmini-boot package version. BUMP THIS whenever the bootloader helper or the
# shipped rEFInd generator (assets/refind/ncz-refind-refresh.sh) changes: apt only
# unpacks cixmini-boot if its version is newer, and the kernel packages can upgrade
# independently. Without a bump an installed board keeps running the STALE
# /usr/local/sbin/ncz-refind-refresh, which rewrites refind.conf with the old
# hard-coded efi=noruntime and re-breaks the O6/O6N RTC on every kernel refresh.
# 1.1: board-gated efi=noruntime + generator shipped through the OTA path.
# 1.2: generator preserves /boot/efi/vmlinuz-*-rescue through the ESP wipe and
#      emits a menuentry for it. Without this bump an installed board keeps the
#      1.1 generator, which deletes the rescue kernel on the next apt run.
# 1.3: not needed for the OTA-DKMS-HEADER-FIX-2026-08-21 fix (the helper itself
#      is unchanged). CIXMINI_BOOT_VER is bumped in lockstep with BUILD_REV
#      only so the kernel's Depends: cixmini-boot (>= $CIXMINI_BOOT_MIN_VER) forces
#      a re-configure of cixmini-boot, and the helper runs in the same apt
#      transaction; the bootloader entries are correct end-of-transaction
#      without a follow-up invocation. Behaviourally identical to 1.2+r246.
# 1.3: comment and log-text refresh of the helper and the generator; behaviour unchanged.
# 1.4: generator requires the rescue partition only when it was selected at
#      install time, checks it before the ESP wipe, leaves the ESP alone while
#      the install is still running, and reads the root PARTUUID from the GPT
#      when blkid has none (never writes an empty root=PARTUUID=).
# 1.5: GPT fallback requires a successful root filesystem probe.
CIXMINI_BOOT_VER="1.5+$BUILD_REV"
# What the kernel packages require. Kept at 1.2 while the helper behaviour is unchanged, so
# the r289 kernel debs keep their published bytes (their Depends field is part of them).
CIXMINI_BOOT_MIN_VER="1.2+$BUILD_REV"

# mtime epoch of every deb this script writes, fixed per kernel revision once its debs are
# recorded in manifests/ncz-packages.tsv. The snapshot-derived value above moves with every
# base.pin refresh: the r289 debs were built at the 20261005 snapshot, and after the 20261012
# refresh the same inputs produced other bytes. NCZ_KERNEL_DEB_EPOCH overrides (one-off).
case "${NCZ_KERNEL_DEB_EPOCH:-}" in
    '') case "$BUILD_REV" in
            r289) SOURCE_DATE_EPOCH=1791201600 ;;   # 2026-10-05T12:00:00Z (ledger rows for r289)
            r290) SOURCE_DATE_EPOCH=1791772496 ;;   # 2026-10-12T02:34:56Z, base.pin arm64 snapshot (ledger rows for r290)
        esac ;;
    *[!0-9]*) echo "ERROR: NCZ_KERNEL_DEB_EPOCH must be an integer" >&2; exit 1 ;;
    *) SOURCE_DATE_EPOCH="$NCZ_KERNEL_DEB_EPOCH" ;;
esac
export SOURCE_DATE_EPOCH
MAINT="NCZ <nczero@nclawzero.dev>"

# KVER comes from the ASSET WE ARE ABOUT TO PACKAGE, not from a previous
# ISO staging run. build/iso-staging-di/ is a build OUTPUT dir: after a
# kernel bump it still holds the PREVIOUS KVER until an ISO is rebuilt, so
# preferring it made this script package the new Image under the old
# version string. Confirmed 2026-08-02 on the rc5 -> rc6 bump: it announced
# "[edge] 7.2.0-rc5-sky1-ncz" against an rc6 Image and then died with a bare
# "install: No such file or directory" when the rc5 config was gone.
# assets/kernel/mainline/KVER is written by the kernel build itself and is the
# only source of truth here; the staging sidecar stays as a fallback.
# Falling back to the staging sidecar is still allowed (a caller may package
# from a tree with no built kernel assets), but it must never be SILENT --
# a silent fallback re-creates exactly the stale-KVER mismatch this block
# exists to prevent. Say which source won.
resolve_kver() {   # <channel-dir> <sidecar-name> <default>
    local asset="$REPO/assets/kernel/$1/KVER"
    local sidecar="$REPO/build/iso-staging-di/ncz-payload/$2"
    local v
    if [ -s "$asset" ]; then
        v=$(tr -d " \t\r\n" < "$asset")
        [ -n "$v" ] && { printf %s "$v"; return 0; }
    fi
    if [ -s "$sidecar" ]; then
        v=$(tr -d " \t\r\n" < "$sidecar")
        # HARD FAIL if the sidecar disagrees with the manifest. This fallback
        # exists for the case where the asset KVER file is missing, but the
        # staging directory is a build OUTPUT and routinely holds the PREVIOUS
        # kernel: on 2026-09-04 it still read 7.2.0-sky1-ncz while the shipped
        # kernel was 7.2.3-sky1-ncz. Warning and continuing means an ISO can be
        # built against a kernel nobody intended, which is indistinguishable
        # from success until the board boots the wrong thing.
        mkver=$(sed -n 's/.*"kver": "\([^"]*\)".*/\1/p' "$ROOT/assets/kernel-manifest.json" 2>/dev/null | head -1)
        if [ -n "$v" ] && [ -n "$mkver" ] && [ "$v" != "$mkver" ]; then
            echo "ERROR: ISO-staging sidecar KVER ($v) disagrees with the kernel manifest ($mkver)." >&2
            echo "       $sidecar is stale build output. Rebuild the kernel assets," >&2
            echo "       delete build/iso-staging-di, or pass KVER_$3 explicitly." >&2
            return 1
        fi
        if [ -n "$v" ]; then
            echo "WARN: $asset absent/empty -- falling back to the ISO-staging sidecar" >&2
            echo "      $sidecar = $v" >&2
            echo "      That directory is a build OUTPUT and can hold a PREVIOUS KVER." >&2
            echo "      Build the kernel assets, or pass KVER_$3 explicitly, to be sure." >&2
            printf %s "$v"; return 0
        fi
    fi
    echo "ERROR: no KVER for channel '$1' (neither $asset nor $sidecar)" >&2
    return 1
}
# KVER_NEXT keeps its historical name: it is the sidecar installed systems
# already carry. It now means "the mainline (shipping) channel KVER".
KVER_NEXT="${KVER_NEXT:-$(resolve_kver mainline KVER_NEXT NEXT 7.2.0-sky1-ncz)}"
KVER_NEXT=$(printf %s "$KVER_NEXT" | tr -d " \t\r\n")

echo "== build-kernel-debs =="
echo "   mainline=$KVER_NEXT  rev=$BUILD_REV"
echo "   out=$OUT"

# Drift guard: verify the kernel/NPU manifest invariants before packaging the
# kernels. Catches e.g. an NPU module whose vermagic != the kernel KVER (the
# armchina_npu.ko is vermagic-locked). Non-fatal by default because the edge/next
# kernel may legitimately be ahead of its NPU rebuild; set STRICT_MANIFEST=1 to
# make any drift abort the build (recommended for release/CI).
if [ -f "$REPO/build/kernel-manifest.py" ]; then
    if ! python3 "$REPO/build/kernel-manifest.py" check; then
        if [ "${STRICT_MANIFEST:-0}" = 1 ]; then
            echo "ERROR: kernel manifest drift (STRICT_MANIFEST=1) — aborting" >&2
            exit 1
        fi
        echo "WARN: kernel manifest drift detected (continuing; set STRICT_MANIFEST=1 to enforce)" >&2
    fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------
# Shared: the OTA-safe bootloader helper (ported from 70-bootloader.sh).
# ----------------------------------------------------------------------
write_bootloader_helper() {
    local dst="$1"
    install -d "$(dirname "$dst")"
    cat > "$dst" <<'HELPER'
#!/bin/bash
# cixmini-update-bootloader — OTA-safe systemd-boot entry generator.
# Faithful to the installer's build/70-bootloader.sh, but:
#   1. NEVER wipes the ESP (no destructive clear of loader/entries).
#   2. Only adds/updates entries for currently-installed cixmini kernels.
#   3. initrd-less, exactly like the validated r97/r98 boot (Sky1 kernel
#      has ext4/nvme/smmu built-in and roots directly via root=PARTUUID).
set -uo pipefail

ESP=/boot/efi
[ -d "$ESP" ] || { echo "cixmini-boot: no ESP at $ESP; skipping"; exit 0; }
command -v bootctl >/dev/null 2>&1 || { echo "cixmini-boot: bootctl missing; skipping"; exit 0; }
if ! findmnt -no FSTYPE "$ESP" 2>/dev/null | grep -qi vfat; then
    echo "cixmini-boot: $ESP not a vfat ESP; skipping"; exit 0
fi

# Idempotent: install systemd-boot only if not already present on the ESP.
bootctl is-installed >/dev/null 2>&1 || \
    bootctl install --esp-path="$ESP" --no-variables >/dev/null 2>&1 || true
mkdir -p "$ESP/loader/entries"

ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC" 2>/dev/null)
[ -n "$ROOT_PARTUUID" ] || { echo "cixmini-boot: cannot determine root PARTUUID; aborting"; exit 0; }

# MartJohnson 2026-04-30 working set for MS-R1, kept in
# lockstep with build/70-bootloader.sh.
# ----------------------------------------------------------------------
# efi=noruntime is an MS-R1 firmware workaround, NOT a Sky1-wide one.
#
# Gate it on the actual board. MS-R1's EFI runtime services are buggy, but
# every other Sky1 target (Radxa Orion O6/O6N, Orange Pi 6 / 6 Plus) needs
# EFI runtime ENABLED or it boots with no RTC at all: those boards' RTCs are
# firmware-owned and reachable only through UEFI GetTime/SetTime. On O6N the
# clock sits behind ACPI Device (ERTC), _HID "ERTC0000", _STA = Zero (so Linux
# never enumerates it), bit-banging a Cadence I2C at 0x04040000 that is not
# among the buses exposed to Linux. CONFIG_RTC_DRV_EFI=y is built in, but
# drivers/firmware/efi/efi.c registers the "rtc-efi" platform device only when
# efi_rt_services_supported(EFI_RT_SUPPORTED_TIME_SERVICES) is true -- which
# efi=noruntime makes false. Metal-verified on O6N (7.2.0-rc6 and 7.0.12 at
# the time): /dev/rtc0 appears, driver rtc-efi, hctosys=1, clean boot.
#
# Gate on the board, not the kernel version: the board firmware, not the
# kernel, decides whether EFI runtime is safe.
#
# Fail-safe: if DMI is unreadable we cannot prove we are NOT on an MS-R1, so
# emit the workaround and favour a bootable system over a working clock.
# ----------------------------------------------------------------------
# NOTE: duplicated verbatim in assets/refind/ncz-refind-refresh.sh,
# build/70-bootloader.sh and build/build-kernel-debs.sh. KEEP ALL THREE IN SYNC.
#
# Why not a sourced library: all three copies execute ON THE TARGET, detached from
# this repo -- ncz-refind-refresh is installed standalone to /usr/local/sbin, and the
# build-kernel-debs.sh copy is emitted inside a quoted heredoc into the standalone
# /usr/lib/cixmini/cixmini-update-bootloader. A shared library would therefore need
# its own packaging and delivery path, and a stale-or-missing copy of THAT is exactly
# the failure mode that already bit us once with the rEFInd generator. Self-contained
# duplication trades DRY for a delivery path that cannot silently go stale.
ncz_efi_rt_workaround() {
    local pn vendor
    pn=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    if [ -z "$pn" ] && [ -z "$vendor" ]; then
        # No DMI: a chroot or build context with /sys unmounted. We cannot prove
        # we are not on an MS-R1, so fail safe -- but say so, because on an O6/O6N
        # this costs the RTC until the on-target run corrects it.
        echo "ncz_efi_rt_workaround: DMI unreadable (/sys not mounted?); assuming MS-R1" >&2
        echo "efi=noruntime"; return
    fi
    # Known-good boards first: these need EFI runtime for their RTC, and the
    # allow-list must win over the vendor fallback below so an odd/shared
    # vendor string can never take the RTC away from them.
    case "$pn" in
        *"Orion O6"*|*"Orange Pi 6"*|*"OrangePi 6"*) echo ""; return ;;
    esac
    case "$vendor" in
        *Radxa*|*Xunlong*|*"Shenzhen Xunlong"*) echo ""; return ;;
    esac
    case "$pn" in
        MS-R1*) echo "efi=noruntime"; return ;;
    esac
    case "$vendor" in
        *"Micro Computer (HK)"*) echo "efi=noruntime"; return ;;
    esac
    echo ""
}
EFI_RT_WORKAROUND="$(ncz_efi_rt_workaround)"

CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 $EFI_RT_WORKAROUND acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453 video=DP-4:1920x1080@60e"
ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"
SPLASH=""; [ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)
VER="ncz-ota"; [ -f /usr/local/lib/cix-installer/BUILD_VERSION ] && VER=$(cat /usr/local/lib/cix-installer/BUILD_VERSION)

# Discover installed cixmini kernel (must have BOTH a module tree and a vmlinuz).
NEXT=""
for k in $(ls /usr/lib/modules 2>/dev/null); do
    [ -f "/boot/vmlinuz-$k" ] || continue
    case "$k" in
        *-sky1-ncz|*-cix-sky1-next) NEXT="$k" ;;
    esac
done

write_entry() {
    local name="$1" sk="$2" title="$3" k="$4" extra="$5"
    local opts="$ROOT_OPTS $CMDLINE"
    [ -n "$SPLASH" ] && opts="$opts $SPLASH"
    [ -n "$extra" ] && opts="$opts $extra"
    cat > "$ESP/loader/entries/$name.conf" <<EOF
title   $title
sort-key $sk
version $k
linux   /vmlinuz-$k
options $opts
EOF
}

# The single shipping kernel
if [ -n "$NEXT" ]; then
    rm -f "$ESP"/vmlinuz-*-cix-sky1-next 2>/dev/null || true
    install -m 0644 "/boot/vmlinuz-$NEXT" "$ESP/vmlinuz-$NEXT"
    write_entry cixmini-next 1-next "nclawzero (cixmini) — kernel $NEXT [edge, default] — $VER" "$NEXT" ""
    echo "cixmini-boot: staged kernel $NEXT"
else
    rm -f "$ESP/loader/entries/cixmini-next.conf" "$ESP"/vmlinuz-*-cix-sky1-next 2>/dev/null || true
fi

# Rescue entry reuses the same kernel (single-kernel release).
RESCUE="${NEXT}"
if [ -n "$RESCUE" ]; then
    write_entry cixmini-rescue 2-rescue "SAFE rescue (cixmini) — kernel $RESCUE rescue.target — $VER" "$RESCUE" "systemd.unit=rescue.target"
else
    rm -f "$ESP/loader/entries/cixmini-rescue.conf"
fi

# Safety: never leave the ESP with a default pointing at nothing.
if [ -z "$NEXT" ]; then
    echo "cixmini-boot: no cixmini kernels installed; leaving loader.conf untouched"
    exit 0
fi
DEFAULT_ENTRY="cixmini-next"
cat > "$ESP/loader/loader.conf" <<EOF
default $DEFAULT_ENTRY
timeout 5
console-mode auto
editor yes
EOF
echo "cixmini-update-bootloader: NEXT=${NEXT:-none} default=$DEFAULT_ENTRY"
HELPER
    chmod 0755 "$dst"
}

# ----------------------------------------------------------------------
# Package 1: cixmini-boot
# ----------------------------------------------------------------------
build_cixmini_boot() {
    local root="$WORK/cixmini-boot"
    local ver="$CIXMINI_BOOT_VER"
    rm -rf "$root"
    install -d "$root/DEBIAN" "$root/usr/lib/cixmini" \
        "$root/etc/kernel/postinst.d" "$root/etc/kernel/postrm.d"

    write_bootloader_helper "$root/usr/lib/cixmini/cixmini-update-bootloader"

    # Ship the rEFInd generator through the OTA path too.
    # post-install/70-bootloader.sh installs assets/refind/ncz-refind-refresh.sh
    # to /usr/local/sbin/ncz-refind-refresh, but post-install only runs at
    # INSTALL time. On an already-installed system the wrapper that apt invokes
    # calls that persistent path, so without shipping it here an apt kernel
    # upgrade would rerun the STALE generator and rewrite refind.conf with the
    # old hard-coded efi=noruntime -- silently re-breaking the O6/O6N RTC that
    # this package's own cmdline gating just fixed.
    # Staged under /usr/lib (dpkg must not own /usr/local); postinst syncs it
    # into place.
    if [ -f "$REPO/assets/refind/ncz-refind-refresh.sh" ]; then
        install -m 0755 "$REPO/assets/refind/ncz-refind-refresh.sh" \
            "$root/usr/lib/cixmini/ncz-refind-refresh"
    else
        echo "build-kernel-debs: WARNING: assets/refind/ncz-refind-refresh.sh missing;" \
             "cixmini-boot will not refresh the installed rEFInd generator" >&2
    fi

    # Standard kernel hooks so any future linux-image-* install triggers us too.
    cat > "$root/etc/kernel/postinst.d/zz-cixmini-bootloader" <<'EOF'
#!/bin/sh
set -e
[ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
EOF
    cat > "$root/etc/kernel/postrm.d/zz-cixmini-bootloader" <<'EOF'
#!/bin/sh
set -e
[ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
EOF
    chmod 0755 "$root/etc/kernel/postinst.d/zz-cixmini-bootloader" \
               "$root/etc/kernel/postrm.d/zz-cixmini-bootloader"

    cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    # Refresh the installed rEFInd generator before regenerating entries, so an
    # OTA upgrade picks up cmdline changes (e.g. the board-gated efi=noruntime)
    # instead of rerunning a stale copy from the original install.
    if [ -f /usr/lib/cixmini/ncz-refind-refresh ]; then
        mkdir -p /usr/local/sbin
        if install -m 0755 /usr/lib/cixmini/ncz-refind-refresh \
                /usr/local/sbin/.ncz-refind-refresh.new; then
            mv -f /usr/local/sbin/.ncz-refind-refresh.new \
                /usr/local/sbin/ncz-refind-refresh \
                || echo "cixmini-boot: WARNING: could not install ncz-refind-refresh" >&2
        else
            rm -f /usr/local/sbin/.ncz-refind-refresh.new
            echo "cixmini-boot: WARNING: staging ncz-refind-refresh failed" >&2
        fi
    fi
    # This distro boots rEFInd, not systemd-boot. post-install/11-fix-cixmini-boot.sh
    # keeps a stable copy of the rEFInd wrapper at
    # /usr/local/sbin/.ncz-cixmini-update-bootloader and redirects
    # /usr/lib/cixmini/cixmini-update-bootloader at it -- but dpkg has just
    # overwritten that path with OUR packaged systemd-boot helper. An apt
    # Post-Invoke hook does restore and rerun the wrapper at end of transaction,
    # so refind.conf is eventually correct; prefer the wrapper directly here
    # anyway rather than depend on hook ordering, and so refind.conf is refreshed
    # even if that hook is ever absent.
    # Restore the redirect over /usr/lib BEFORE invoking it. dpkg has just
    # overwritten that path with our packaged systemd-boot helper, and when
    # cixmini-boot and a linux-image-cixmini-* upgrade in the same transaction
    # cixmini-boot is configured FIRST (the kernel depends on it) -- so every
    # later kernel postinst would call the /usr/lib path and refresh only inert
    # systemd-boot entries, leaving the real refind.conf stale. Putting the
    # wrapper back here fixes it for the whole rest of the transaction and does
    # not rely on the installer's DPkg::Post-Invoke hook being present.
    if [ -s /usr/local/sbin/.ncz-cixmini-update-bootloader ]; then
        # temp + atomic rename: never leave a half-written wrapper visible to a
        # concurrently-configuring kernel postinst
        if install -m 0755 /usr/local/sbin/.ncz-cixmini-update-bootloader \
                /usr/lib/cixmini/.cixmini-update-bootloader.new; then
            mv -f /usr/lib/cixmini/.cixmini-update-bootloader.new \
                /usr/lib/cixmini/cixmini-update-bootloader \
                || echo "cixmini-boot: WARNING: could not restore the rEFInd wrapper" >&2
        else
            rm -f /usr/lib/cixmini/.cixmini-update-bootloader.new
            echo "cixmini-boot: WARNING: staging the rEFInd wrapper failed" >&2
        fi
    fi
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
fi
exit 0
EOF
    chmod 0755 "$root/DEBIAN/postinst"

    local isize
    isize=$(installed_size_kb "$root")
    # NOTE (initramfs alternation): dracut is listed FIRST, matching the form
    # Debian adopts in bug #1114857. dracut is the primary builder as of 26.7
    # (metal-validated on O6N 2026-08-16) and initramfs-tools is no longer
    # shipped in the main image, surviving only in the rescue toolkit.
    #
    # This comment lives OUT here on purpose. It previously sat INSIDE the
    # heredoc below, which writes DEBIAN/control verbatim -- so every '#' line
    # was emitted as a control field and dpkg-deb refused the package with
    # "field name '#' must be followed by colon". That bug was latent: the
    # comment block was added with the alternation change and nothing rebuilt
    # the kernel deb until the dracut migration forced it.
    cat > "$root/DEBIAN/control" <<EOF
Package: cixmini-boot
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: admin
Priority: optional
Installed-Size: $isize
Depends: systemd, efibootmgr, util-linux, kmod, ncz-usb-recovery
Description: NCZ cixmini systemd-boot entry generator (OTA-safe)
 Idempotent bootloader hook that stages installed cixmini kernels to the ESP
 and writes systemd-boot loader entries (lts/next/rescue) without ever wiping
 the ESP. Invoked automatically on kernel install/upgrade/removal.
EOF
    repro_finalize_root "$root"
    dpkg-deb --root-owner-group --build "$root" \
        "$OUT/cixmini-boot_${ver}_arm64.deb"
}

# ----------------------------------------------------------------------
# linux-image-cixmini-<channel>
# ----------------------------------------------------------------------
build_kernel_deb() {
    local channel="$1"   # mainline (only packaged channel)
    local kver="$2"
    local label="$3"     # asset subdir (mainline)
    local with_npu="$4"  # path to OOT npu .ko, or ""

    # ONE KERNEL, ONE NAME (2026-08-11: no LTS or edge channel; one kernel
    # line, now the unified 7.3). The channel suffix is gone: the package is simply
    # linux-image-cixmini. The channel argument survives only to pick the asset
    # subdirectory and label the build log.
    local pkg="linux-image-cixmini"
    local ver="$kver+$BUILD_REV"
    local root="$WORK/$pkg"
    rm -rf "$root"
    install -d "$root/DEBIAN" "$root/boot" "$root/usr"

    echo "  [$channel] $kver -> $pkg ($ver)"
    install -D -m 0644 "$ASSETS/$label/Image-cixmini.bin" "$root/boot/vmlinuz-$kver"
    install -D -m 0644 "$ASSETS/$label/config-$kver"       "$root/boot/config-$kver"

    # Modules: tgz has top-level lib/modules/... -> extract into /usr so it
    # lands at /usr/lib/modules/$kver (usrmerge-safe; see 10-our-kernel.sh).
    tar xzf "$ASSETS/$label/modules-cixmini.tgz" -C "$root/usr" --keep-directory-symlink
    [ -d "$root/usr/lib/modules/$kver" ] || { echo "ERROR: modules tgz did not yield $kver"; exit 1; }
    local mc
    # SHIP THE OUT-OF-TREE GPU MODULES WITH THE KERNEL THAT MATCHES THEM.
    #
    # WHY (2026-08-11, cost a working desktop): this package OWNS
    # /usr/lib/modules/$kver, so installing it over an existing board with the
    # SAME kernel version string replaces that tree wholesale -- deleting
    # everything DKMS had put in updates/. On O6N that silently removed
    # mali_kbase, memory_group_manager and protected_memory_allocator. Result:
    # /dev/mali0 gone, ncz-gpu-env fell back to llvmpipe/pixman, the whole
    # desktop went software-rendered, and Chromium consequently dropped
    # hardware video decode (V4L2VideoDecoder -> VpxVideoDecoder) so 4K video
    # crawled. Nothing reported an error; the box just got slow.
    #
    # DKMS is NOT installed on these images, so nothing rebuilds them. The
    # kernel and its GPU modules are one unit and must ship together, keyed on
    # the exact $kver they were built against. Same reasoning as the NPU module
    # installed just below, which already worked this way.
    #
    # /updates matches assets/kernel/mali/dkms.conf DEST_MODULE_LOCATION, so a
    # DKMS-built module lands in the same place and overrides cleanly.
    if [ -d "$ASSETS/mali/$kver" ]; then
        gm=0
        for _ko in "$ASSETS/mali/$kver"/*.ko; do
            [ -e "$_ko" ] || continue
            install -D -m 0644 "$_ko" "$root/usr/lib/modules/$kver/updates/$(basename "$_ko")"
            gm=$((gm + 1))
        done
        echo "  [$channel] staged $gm out-of-tree GPU module(s) into updates/"
        # r-npu-2026-09-26: was a WARN. Promote to a fatal gate. Same class
        # of defect as the proprietary CIX deb shortfall (r-cix1, 9e3e0a2)
        # and the missing-NPU-DKMS build (stage-canonical-assets.sh /
        # kernel-manifest.py this same commit): a silent accelerator
        # absence at build time becomes a black-screen, no-/dev/mali0
        # boot at flash time. kbase defers -517 without memory_group_manager,
        # which the original WARN warned about but did not block.
        if [ "$gm" -lt 3 ]; then
            echo "  ERROR: [$channel] only $gm/3 mali GPU modules staged" >&2
            echo "         (need mali_kbase, memory_group_manager, protected_memory_allocator)" >&2
            echo "         the kernel will boot with kbase deferring -517 'Memory group manager is not ready'" >&2
            echo "         -> no /dev/mali0 -> greetd crash-loop -> black screen." >&2
            echo "         this is the O6N 2026-09-26 GPU-less install class." >&2
            exit 1
        fi
    else
        echo "  ERROR: [$channel] no prebuilt GPU modules at $ASSETS/mali/$kver" >&2
        echo "         the installed system would have NO GPU and fall back to software rendering." >&2
        echo "         this is the O6N 2026-09-26 GPU-less install class." >&2
        exit 1
    fi

    mc=$(find "$root/usr/lib/modules/$kver" \( -name '*.ko' -o -name '*.ko.xz' \) | wc -l)
    [ "$mc" -ge 50 ] || { echo "ERROR: suspiciously few modules ($mc) for $kver"; exit 1; }

    if [ -n "$with_npu" ]; then
        local vm
        vm=$(modinfo -F vermagic "$with_npu" 2>/dev/null | awk '{print $1}')
        [ "$vm" = "$kver" ] || { echo "ERROR: NPU ko vermagic '$vm' != '$kver'"; exit 1; }
        install -D -m 0644 "$with_npu" "$root/usr/lib/modules/$kver/extra/armchina_npu.ko"
        echo "    baked OOT armchina_npu.ko (vermagic $vm)"
    fi

    # Every out-of-tree module this package ships (updates/, extra/) must have
    # the kernel's struct module layout and vermagic. 2026-10-26 (r292): the
    # mali overlays had this_module 0x4c0 against the kernel's 0x500, the CRC
    # and vermagic checks passed, and the kernel refused all three on O6N
    # ("section size must match") -> no GPU, no desktop. Compare against an
    # in-tree module of this same package.
    python3 "$REPO/build/verify-module-abi.py" "$root/usr/lib/modules/$kver" \
        || { echo "ERROR: [$channel] out-of-tree modules do not match $kver (see above); refusing to package" >&2; exit 1; }

    # Drop stale dep maps; postinst regenerates with depmod on target.
    rm -f "$root/usr/lib/modules/$kver"/modules.dep* \
          "$root/usr/lib/modules/$kver"/modules.alias* \
          "$root/usr/lib/modules/$kver"/modules.symbols* 2>/dev/null || true

    cat > "$root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
KVER="$kver"
# Guard against an empty KVER: a bare "/usr/lib/modules/" in the postrm
# would rm -rf every kernel's modules. Bail if the version is missing.
[ -n "\$KVER" ] || exit 0
if [ "\$1" = configure ]; then
    # The initramfs is regenerated by linux-headers-cixmini's postinst AFTER
    # dkms autoinstall has rebuilt every accelerator module. Regenerating
    # it HERE would race that step and bake in stale modules. The standard
    # Debian kernel-package postinst triggers (update-initramfs / dracut via
    # /etc/kernel/postinst.d/) would do exactly that, so we deliberately
    # do NOT call any initramfs builder in this postinst. See
    # docs/OTA-DKMS-HEADER-FIX-2026-08-21.md.
    #
    # The Depends: linux-headers-cixmini (= \$ver) in DEBIAN/control forces
    # apt to configure the headers package BEFORE this one, so by the time
    # we reach this line, the initrd at /boot/initrd.img-\$KVER is the one
    # built by the headers postinst and already contains the correct DKMS
    # modules. We only need to refresh the depmod maps (which the headers
    # postinst may or may not have done, depending on tool order) and the
    # bootloader entries.
    if [ -d /usr/lib/modules/\$KVER ]; then
        depmod -a "\$KVER" || true
    fi
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
fi
exit 0
EOF
    cat > "$root/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
KVER="$kver"
# Guard against an empty KVER: a bare "/usr/lib/modules/" here would
# rm -rf every kernel's modules. Bail if the version is missing.
[ -n "\$KVER" ] || exit 0
case "\$1" in
  remove|purge)
    rm -f "/boot/initrd.img-\$KVER" "/boot/efi/vmlinuz-\$KVER" "/boot/efi/initrd.img-\$KVER" 2>/dev/null || true
    rm -rf "/usr/lib/modules/\$KVER" 2>/dev/null || true
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
    ;;
esac
exit 0
EOF
    chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

    local isize
    isize=$(installed_size_kb "$root")
    cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: kernel
Priority: optional
Installed-Size: $isize
Depends: cixmini-boot (>= $CIXMINI_BOOT_MIN_VER), linux-headers-cixmini (= $ver), kmod, dracut | initramfs-tools | linux-initramfs-tool, systemd
Description: NCZ cixmini Linux kernel ($kver)
 Prebuilt linux-cix-sky1 kernel image + modules for the NCZ cixmini (MS-R1).
 Installs vmlinuz, the module tree$( [ -n "$with_npu" ] && echo " (incl. armchina_npu)") and config,
 then refreshes the systemd-boot entry via cixmini-boot. Depends on a
 matching linux-headers-cixmini (= $ver); that package's postinst rebuilds
 every DKMS module against the new kernel and regenerates the initrd BEFORE
 this package's postinst runs (OTA-DKMS-HEADER-FIX-2026-08-21).
EOF
    # Renamed-package handoff. linux-image-cixmini-legacy ships the same
    # /boot and /usr/lib/modules paths the old linux-image-cixmini-lts did,
    # so without Replaces dpkg refuses to unpack it over a pre-rename board
    # ("trying to overwrite ... which is also in package ..."). VERSIONED,
    # and Breaks rather than Conflicts, because the old NAME survives as the
    # empty transitional package built below -- an unversioned Conflicts
    # would make that transitional package impossible to install alongside
    # the very package it depends on.
    # Take over from EVERY name this kernel was ever published under. Without
    # this dpkg refuses to unpack over an existing board ("trying to overwrite
    # ... which is also in package ...") because the file paths are identical,
    # and an upgrade would strand the old package installed alongside.
    # CONFLICTS, not Breaks. Breaks means "deconfigure the other package",
    # which dpkg refuses on its own -- MEASURED on O6N: "installing
    # linux-image-cixmini would break linux-image-cixmini-edge, and
    # deconfiguration is not permitted (--auto-deconfigure might help)".
    # Provides+Replaces+Conflicts is the canonical take-over triple: apt
    # REMOVES the retired name and installs this in its place.
    # ONE field each, comma-separated. dpkg-deb rejects a control file with the
    # same field repeated ("duplicate value for 'Replaces' field"), so these
    # cannot be emitted one relation per line.
    # Also take over the RAW kernel package name, linux-image-<kver>. The Yocto
    # build publishes one and it ships the identical /boot/vmlinuz-<kver> and
    # config-<kver> paths, so a board that ever installed it directly (every
    # kernel test board does) would otherwise hit "trying to overwrite ...
    # which is also in package linux-image-<kver>". Declaring it beats the
    # --force-overwrite that post-install/10-our-kernel.sh has been using to
    # push past exactly this collision.
    _OLD_NAMES="linux-image-cixmini-edge, linux-image-cixmini-lts, linux-image-cixmini-legacy, linux-image-$kver"
    printf 'Replaces: %s\n' "$_OLD_NAMES" >> "$root/DEBIAN/control"
    printf 'Conflicts: %s\n' "$_OLD_NAMES" >> "$root/DEBIAN/control"
    printf 'Provides: %s\n' "$_OLD_NAMES" >> "$root/DEBIAN/control"
    repro_finalize_root "$root"
    dpkg-deb --root-owner-group --build "$root" "$OUT/${pkg}_${ver}_arm64.deb"
}

# ----------------------------------------------------------------------
# Package 3: linux-headers-cixmini
#
# WHY THIS PACKAGE EXISTS (r246/r247, both reproduced on O6N):
#
# Every CIX accelerator (mali_kbase, memory_group_manager,
# protected_memory_allocator, panthor, amvx, aipu) ships out-of-tree via
# DKMS. DKMS builds modules against /lib/modules/$KVER/build/, which must
# be a header tree whose Makefile/.config/Module.symvers all agree on the
# SAME $KVER. linux-image-cixmini ONLY shipped /usr/lib/modules/$KVER/kernel/
# and /boot/{vmlinuz,config} -- it did NOT ship the build/ tree, because
# before r246 the header tarball (assets/kernel/<ch>/headers-cixmini.tar.zst)
# was a build-side artifact that stayed in the source repo and was
# transferred to the target only by post-install/10-our-kernel.sh on a
# fresh install.
#
# On a FRESH INSTALL, that hand-off worked: post-install copied the tarball,
# 79-dkms-prep.sh repaired the localversion + foreign-binaries problems,
# 86-cix-dkms-register.sh registered the four packages, and dkms built
# the modules against the matching headers. First boot had correct vermagic.
#
# On an OTA KERNEL UPGRADE the .deb was the ONLY thing that ran. There was
# no post-install path, no header handoff, and the standard Debian kernel
# postinst regenerated the initramfs against whatever DKMS modules were
# already on disk -- the OLD ones, built against the PREVIOUS kernel's
# headers. The result was a fresh boot with mismatched vermagic on every
# accelerator module; vulkaninfo reported llvmpipe (software-rendered) on
# O6N both times. The operator had to manually stage the headers tarball,
# run `make modules_prepare`, dkms remove+install every package, then
# regenerate the initramfs. Same fix, twice. r246 and r247, both manual.
#
# This package carries the matching /lib/modules/$KVER/build/ tree and its
# postinst performs the full remediation automatically:
#
#   1. Stage the tarball content to /lib/modules/$KVER/build/ (idempotent
#      -- safe to re-run on a board that already has the headers).
#   2. Run `make ARCH=arm64 modules_prepare` to rebuild the host tools the
#      headers tarball omits (fixdep, modpost -- both unrunnable because
#      they are Yocto build-host binaries; see 79-dkms-prep.sh for the
#      full story). The expected late failure on kernel/bounds.s is
#      documented and harmless: modpost and fixdep are built by then.
#   3. Run `dkms autoinstall -k $KVER` to rebuild every registered DKMS
#      package against the now-correct headers. FAIL LOUDLY if any package
#      fails to build -- a silently-stale GPU driver is worse than a failed
#      dpkg transaction a human will notice.
#   4. Regenerate the initramfs (dracut primary, update-initramfs fallback)
#      so the freshly-rebuilt modules get baked into the new initrd.
#
# linux-image-cixmini declares Depends: linux-headers-cixmini (= $ver), so
# apt always installs the headers package FIRST in the same transaction.
# By the time the image's own postinst runs, the build/ tree is in place
# and DKMS modules are correct -- the image's own (now-suppressed) initrd
# trigger would have raced against step 4 and baked in stale modules.
#
# Full root cause + reproduction: docs/OTA-DKMS-HEADER-FIX-2026-08-21.md.
# ----------------------------------------------------------------------
build_headers_deb() {
    local channel="$1"   # mainline (only packaged channel)
    local kver="$2"
    local label="$3"     # asset subdir (mainline)
    local pkg=linux-headers-cixmini
    local ver="$kver+$BUILD_REV"
    local src_tar="$ASSETS/$label/headers-cixmini.tar.zst"
    local root="$WORK/$pkg"
    rm -rf "$root"

    if [ ! -s "$src_tar" ]; then
        # No headers tarball = no headers .deb. This is the failure mode that
        # made r245 and earlier r246 builds ship a kernel without a matching
        # build/ tree at all. Refuse to build silently: a board that takes
        # this .deb will reboot into a broken GPU. A loud error here is
        # strictly better than the silent-stale-modules outcome this package
        # exists to prevent.
        echo "  [$channel] $pkg: ERROR: $src_tar missing; cannot build" >&2
        echo "  [$channel]         headers .deb without it" >&2
        echo "  [$channel]         (linux-image-cixmini depends on this package, so" >&2
        echo "  [$channel]         a missing headers .deb will break the kernel install)" >&2
        return 1
    fi

    echo "  [$channel] $kver -> $pkg ($ver)"
    install -d "$root/DEBIAN" "$root/usr"

    # The tarball is rooted at lib/modules/$KVER/build/. Extract into /usr
    # so it lands at /usr/lib/modules/$KVER/build -- the path DKMS reads.
    # --keep-directory-symlink matches the modules tarball extraction above
    # (10-our-kernel.sh / post-install use the same flag).
    tar --zstd -xf "$src_tar" -C "$root/usr" --keep-directory-symlink
    [ -d "$root/usr/lib/modules/$kver/build" ] \
        || { echo "ERROR: $src_tar did not yield $root/usr/lib/modules/$kver/build" >&2; exit 1; }
    [ -f "$root/usr/lib/modules/$kver/build/Makefile" ] \
        || { echo "ERROR: $src_tar did not yield a complete build/ tree" >&2; exit 1; }

    # Postinst: the OTA-DKMS-HEADER-FIX-2026-08-21 sequence.
    # This is the file that does what the operator has been doing by hand
    # twice (r246, r247). Keep the rationale in the heredoc, not just in
    # docs/, because the heredoc is the ONLY place the next maintainer
    # will read when they are trying to figure out why a kernel upgrade
    # is hanging on a fresh install.
    #
    # Use a SINGLE-QUOTED heredoc so neither $ nor ` is interpreted at
    # write time. The build script and the target postinst are different
    # shells; a $KVER in the heredoc must be a literal $KVER (and the
    # shell on the target will expand it), not the build script's $kver.
    # A backtick in a heredoc comment MUST stay a backtick in the file --
    # an unquoted heredoc eats it as command substitution (measured 2026-08-21:
    # the r248 first build emitted a postinst that had silently dropped the
    # backticked words in the comments, and bash itself tripped over an
    # unbound $KVER in the build script while executing one of those
    # command substitutions). The kver is then substituted via sed from the
    # __KVER__ placeholder -- a unique enough token that it cannot collide
    # with anything in the comment text.
    sed -e "s|__KVER__|$kver|g" > "$root/DEBIAN/postinst" <<'POSTINST_EOF'
#!/bin/sh
set -e
# Debian maintainer scripts must not trust the caller's PATH. Tonight's r252
# O6N incident proved why: dkms existed at /usr/sbin/dkms, but the postinst
# inherited a PATH without sbin and skipped the whole autoinstall block.
PATH="/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"
export PATH
KVER="__KVER__"
[ -n "$KVER" ] || { echo "linux-headers-cixmini: empty KVER, aborting"; exit 1; }
B="/usr/lib/modules/$KVER/build"

log() { echo "linux-headers-cixmini[$KVER]: $*"; }
warn() { echo "linux-headers-cixmini[$KVER]: WARNING: $*" >&2; }

# 1. Stage the header tree to /lib/modules/$KVER/build.
#
# The .deb's data.tar already extracted it under /usr/lib/modules/$KVER/build,
# which IS the canonical path -- the /lib -> /usr/lib symlink in modern
# Debian/Trixie resolves /lib/modules/$KVER/build to /usr/lib/modules/$KVER/build
# transparently. This block is therefore almost a no-op on a fresh install
# (the files are already there), but it makes the postinst safe to re-run
# after a manual `rm -rf /usr/lib/modules/$KVER/build` and provides a
# single, debuggable "is the tree present?" check.
if [ ! -f "$B/Makefile" ] || [ ! -f "$B/.config" ] || [ ! -f "$B/Module.symvers" ]; then
    echo "linux-headers-cixmini: ERROR: $B is missing required build files" >&2
    echo "                       (Makefile/.config/Module.symvers -- all three required)" >&2
    echo "                       Refusing to run dkms autoinstall without a header tree" >&2
    exit 1
fi

# 2. modules_prepare -- rebuild the host tools the tarball omits.
#
# The headers tarball is built from a Yocto split build dir. The compiled
# host tools (scripts/basic/fixdep, scripts/mod/modpost) are Yocto
# build-host binaries linked against the uninative loader, which does not
# exist on the target. Running them produces
#   /bin/sh: 1: .../fixdep: not found
# which DKMS surfaces as a baffling "Error 127" on the first .o. Rebuild
# them natively here, before any dkms call.
#
# Pin the localversion while we are in the tree. The tarball already
# carries a localversion-ncz (see extract-kernel-headers.sh), but a manual
# re-extract or a re-run of `make modules_prepare` can REWRITE the kernel
# release string and silently stamp every rebuilt module with a vermagic
# that does not match the running kernel. This is the SECOND mode of the
# r246/r247 bug -- 79-dkms-prep.sh already guards it; do so again here so
# the OTA path is independent of any post-install step.
SUFFIX=""
case "$KVER" in
    *-sky1-ncz) SUFFIX="-sky1-ncz" ;;
    *-cix-sky1-next) SUFFIX="-cix-sky1-next" ;;
esac
if [ -n "$SUFFIX" ]; then
    if [ "$(cat "$B/localversion-ncz" 2>/dev/null)" != "$SUFFIX" ]; then
        printf '%s\n' "$SUFFIX" > "$B/localversion-ncz"
        log "pinned localversion-ncz=$SUFFIX"
    fi
fi

# Detect-and-rebuild the foreign host tools, exactly as 79-dkms-prep.sh
# does. Reproduced here (rather than shelling out to 79) because the OTA
# path cannot assume the post-install hooks ever ran: a board that
# upgraded from a pre-79 world, or that was installed via a non-standard
# path, will never have invoked 79. The header tree must be self-healing.
#
# FIX 2026-10-21 (r291): the original was
#     "$1" --version >/dev/null 2>&1 || return 1
#     case $? in 126|127) return 1;; esac
#     return 0
# The `|| return 1` fires on ANY non-zero exit, so a tool that execs fine and
# then rejects the bogus `--version` argument -- which is what BOTH fixdep and
# modpost do, exit 1 with a usage message on stderr -- was reported UNUSABLE.
# The 126/127 case afterwards was dead code: `||` had already returned, so $?
# was always 0 there. Measured against the real r290 headers tree: both tools
# are native and execute, yet this function returned "unusable" for both,
# which forced a pointless modules_prepare on every install and then printed
# the alarming "fixdep/modpost still unusable; DKMS builds will fail"
# warning on boards where DKMS was about to work perfectly. The correct
# predicate is the one 79-dkms-prep.sh already uses: ONLY 126 (found but not
# executable) and 127 (interpreter/loader missing) mean "cannot exec", because
# those are the execve failures -- a Yocto uninative-linked binary whose
# loader path does not exist on the target. Any other exit means it ran.
# 79-dkms-prep.sh is the reference implementation; keep the two in step.
tool_usable() {
    [ -x "$1" ] || return 1
    "$1" --version </dev/null >/dev/null 2>&1
    case $? in
        126|127) return 1 ;;   # cannot exec: wrong ABI or missing loader
        *)       return 0 ;;   # ran (a usage error is still a successful exec)
    esac
}
# genksyms matters as much as fixdep/modpost and was missing here: a module
# that exports symbols (aipu) runs it for CONFIG_MODVERSIONS, and the shipped
# headers carry a genksyms linked against Yocto's uninative loader even when
# fixdep and modpost are already native (2026-10-06, r201 arm64 KVM gate:
# "genksyms: not found", no aipu.ko). 79-dkms-prep.sh hit exactly that and
# added genksyms to its list; this postinst never got the same change.
need_rebuild=0
for tool in scripts/basic/fixdep scripts/mod/modpost scripts/genksyms/genksyms; do
    tool_usable "$B/$tool" || need_rebuild=1
done

# >>> ncz_prepare_pristine (keep identical in build/build-kernel-debs.sh,
# post-install/79-dkms-prep.sh and post-install/10-our-kernel.sh;
# build/test-headers-prepare-pristine.sh checks that they match)
#
# Rebuild the kernel host tools (fixdep, modpost, genksyms) with
# `make modules_prepare` WITHOUT letting it change the kernel configuration the
# header tree describes. modules_prepare re-runs Kconfig (syncconfig) whenever
# the compiler differs from the one that built the kernel, which on these
# trees is always (OE gcc built the kernel, Debian gcc builds DKMS). Kconfig
# then re-derives every toolchain-dependent symbol for the NEW compiler and
# rewrites .config, include/config/auto.conf and include/generated/autoconf.h.
# Every DKMS module is compiled against that autoconf.h, so a dropped symbol
# changes the module ABI. 2026-10-26 (r292): on a host without pahole,
# CONFIG_PAHOLE_VERSION became 0, CONFIG_DEBUG_INFO_BTF_MODULES disappeared,
# struct module shrank from 0x500 to 0x4c0, and the kernel refused the Mali
# modules built there ("section size must match"). On O6N the same step also
# dropped CONFIG_GCC_PLUGINS and prompted for new symbols on the terminal.
# So: snapshot the Kconfig output, run modules_prepare with stdin closed (a new
# symbol takes its default instead of waiting for an answer on a terminal
# during an apt run), put the snapshot back, and verify it is byte-identical.
#
# tools/bpf/resolve_btfids fails to build here ("linux/kasan-checks.h: No such
# file or directory": the header tree carries no tools/ sources). DKMS does not
# need it: it is only used to add BTF to a module when vmlinux is present, and
# the header tree has no vmlinux, so kbuild prints "Skipping BTF generation"
# and the module loads without BTF. That failure, like the missing
# kernel/bounds.s and asm-offsets sources, is why make runs with -k.
#
# A listed file that make creates (the shipped tree has no
# include/config/auto.conf.cmd) is removed again, so the tree ends as shipped.
#
# Safe under set -e whether or not the caller tests its status.
#
# ncz_prepare_pristine <build-dir> <log>
#   returns 0 when make was clean, make's status when it was not (expected for
#   this trimmed tree; check the tools instead), 3 when the configuration could
#   not be restored (do NOT build modules against that tree).
# Also the generated headers the kernel build shipped (bounds.h, asm-offsets.h,
# timeconst.h are computed from the configuration; compile.h names the
# compiler): the kernel's copies are the right ones, whatever make regenerated.
NCZ_KCONFIG_FILES=".config include/config/auto.conf include/config/auto.conf.cmd include/generated/autoconf.h include/generated/rustc_cfg include/config/kernel.release include/generated/utsrelease.h include/generated/bounds.h include/generated/asm-offsets.h include/generated/timeconst.h include/generated/compile.h"
ncz_prepare_pristine() {
    _np_b=$1; _np_log=$2
    _np_snap=$(mktemp -d) || return 3
    for _np_f in $NCZ_KCONFIG_FILES; do
        [ -f "$_np_b/$_np_f" ] || continue
        mkdir -p "$_np_snap/$(dirname "$_np_f")" && cp -p "$_np_b/$_np_f" "$_np_snap/$_np_f" \
            || { rm -rf "$_np_snap"; return 3; }
    done
    _np_off=$(($({ wc -c <"$_np_log"; } 2>/dev/null || echo 0) + 1))
    _np_rc=0
    make -k -C "$_np_b" -j"$(nproc 2>/dev/null || echo 2)" modules_prepare </dev/null >>"$_np_log" 2>&1 || _np_rc=$?
    # 3 is reserved for "not restored"; GNU make never exits 3, but keep it unambiguous
    if [ "$_np_rc" = 3 ]; then _np_rc=2; fi
    _np_bad=0
    for _np_f in $NCZ_KCONFIG_FILES; do
        if [ ! -f "$_np_snap/$_np_f" ]; then
            [ -e "$_np_b/$_np_f" ] || continue
            echo "ncz_prepare_pristine: Kconfig created $_np_f; removed it (the kernel's tree has none)" >>"$_np_log"
            rm -rf "${_np_b:?}/$_np_f" 2>>"$_np_log"
            if [ -e "$_np_b/$_np_f" ]; then _np_bad=1; fi
            continue
        fi
        if cmp -s "$_np_snap/$_np_f" "$_np_b/$_np_f" 2>/dev/null; then continue; fi
        echo "ncz_prepare_pristine: Kconfig rewrote $_np_f; restored the kernel's copy" >>"$_np_log"
        # a path make turned into a directory: remove it so the copy can land
        if [ -d "$_np_b/$_np_f" ]; then rm -rf "${_np_b:?}/$_np_f"; fi
        cp -p "$_np_snap/$_np_f" "$_np_b/$_np_f" 2>>"$_np_log" || _np_bad=1
        cmp -s "$_np_snap/$_np_f" "$_np_b/$_np_f" 2>/dev/null || _np_bad=1
    done
    rm -rf "$_np_snap"
    if tail -c +"$_np_off" "$_np_log" 2>/dev/null | grep -q 'resolve_btfids'; then
        echo "ncz_prepare_pristine: tools/bpf/resolve_btfids not built (no tools/ sources in the header tree); not needed for DKMS: without vmlinux kbuild skips module BTF" >>"$_np_log"
    fi
    [ "$_np_bad" = 0 ] || return 3
    return "$_np_rc"
}
# <<< ncz_prepare_pristine

if [ "$need_rebuild" = "1" ]; then
    log "rebuilding host tools natively (shipped ones are Yocto build-host binaries)"
    SEL="$B/scripts/selinux/Makefile"
    SELBAK=""
    restore_selinux() {
        [ -n "${SELBAK:-}" ] && [ -f "$SELBAK" ] && cp -a "$SELBAK" "$SEL"
        [ -n "${SELBAK:-}" ] && rm -f "$SELBAK"
        SELBAK=""
    }
    trap 'restore_selinux' EXIT INT TERM
    if [ -f "$SEL" ]; then
        SELBAK="$(mktemp)"; cp -a "$SEL" "$SELBAK"; : > "$SEL"
    fi
    LOG=/var/log/ncz-headers-modules-prepare.log
    # -k matters here, and the reason is ordering, not the bounds failure per
    # se. The top-level Kbuild builds include/generated/bounds.h from
    # kernel/bounds.s, and arch/$(SRCARCH)/kernel/asm-offsets.s depends on that
    # header; the header extraction did not ship kernel/bounds.c, so without
    # it make stops at prepare0 on "No rule to make target 'kernel/bounds.s'"
    # (reproduced 2026-10-21 on ULTRA, logs/bounds-repro-before.txt). -k lets
    # make carry on past that stop so the host tools this block exists to
    # produce are still built and the verdict below is taken from re-running
    # tool_usable on each tool rather than from make's exit status. Shipping
    # kernel/bounds.c (extract-kernel-headers.sh) removes the stop at its
    # source; -k is kept because the tree has other generated-source gaps by
    # construction (any file outside include/ that the extension filters do not
    # match) and 79-dkms-prep.sh already depends on -k for exactly that reason.
    _prep_rc=0
    ncz_prepare_pristine "$B" "$LOG" || _prep_rc=$?
    case "$_prep_rc" in
        0) log "modules_prepare clean (log: $LOG)" ;;
        3)  restore_selinux
            warn "modules_prepare changed the kernel configuration in $B and it could not be restored"
            warn "Refusing to run dkms autoinstall: modules built against it would not load (see $LOG)"
            exit 1 ;;
        # Non-zero is EXPECTED: the headers tarball does not carry the full
        # source tree. The tools we actually needed are verified usable below,
        # so a non-zero exit here is not itself a failure.
        *) log "modules_prepare returned non-zero (expected: headers omit some generated sources; see $LOG)" ;;
    esac
    restore_selinux
    trap - EXIT INT TERM
    for tool in scripts/basic/fixdep scripts/mod/modpost scripts/genksyms/genksyms; do
        if tool_usable "$B/$tool"; then
            log "$tool -> native"
        else
            warn "$tool still unusable; DKMS builds will fail (see $LOG)"
        fi
    done
else
    log "host tools already native"
fi

# Verify the release string the tree will stamp equals KVER. If it does
# not, every module DKMS is about to build will be stamped with a vermagic
# the running kernel will reject. Refuse to continue -- this is the
# silent-stale-modules failure mode this whole package exists to prevent.
REL="$(cat "$B/include/config/kernel.release" 2>/dev/null || true)"
if [ -n "$REL" ] && [ "$REL" != "$KVER" ]; then
    warn "build tree reports release '$REL' but kernel is '$KVER'"
    warn "DKMS modules would be stamped with the wrong vermagic and refuse to load"
    warn "Refusing to run dkms autoinstall -- investigate the headers tree"
    exit 1
fi
log "release string OK (${REL:-$KVER})"

# 3. dkms autoinstall -- rebuild every registered DKMS package against the
# now-correct headers. Use `autoinstall`, not a manual loop: it walks
# /var/lib/dkms and handles ordering, locks, and the modules_dep rebuild
# automatically. A package that fails to build here is a REAL defect, not
# a deferral: with the headers tree now present, a build failure means the
# source no longer compiles against this kernel, and the operator needs
# to know RIGHT NOW -- not at the next reboot when the GPU is missing.
#
# Loud failure is mandatory (set -e + explicit check). Dpkg surfaces a
# postinst failure as a package-install error on the user's terminal, and
# the apt transaction leaves the package in a half-configured state that
# every subsequent apt invocation reports until the operator runs
# `dpkg --configure -a` or `apt install -f`. A silently-stale GPU driver
# is the worse outcome (the r246/r247 bug), so we err toward visibility.
DKMS_BIN="$(command -v dkms 2>/dev/null || true)"
[ -n "$DKMS_BIN" ] || [ ! -x /usr/sbin/dkms ] || DKMS_BIN=/usr/sbin/dkms
if [ -n "$DKMS_BIN" ] && [ -x "$DKMS_BIN" ]; then
    # This project pins the SAME kernel uname release string ($KVER,
    # "7.2.0-sky1-ncz") across every content change -- only the .deb's
    # +rNNN revision differs (see kernel-build-checklist.md). `dkms
    # autoinstall` treats a package already marked "installed" for KVER as
    # up to date and silently skips rebuilding it -- confirmed live on O6N
    # 2026-08-25: a prior manual DKMS fix (r252-era) left mali_kbase and its
    # siblings registered as installed for 7.2.0-sky1-ncz. The r254 upgrade
    # ran `dkms autoinstall` (produced a 0-byte log, nothing to do by its
    # own bookkeeping) instead of actually rebuilding, so mali_kbase stayed
    # stale and failed to load with a real symbol-CRC mismatch, which hung
    # the default boot.
    #
    # FIRST FIX ATTEMPT (also caught live on O6N, do not repeat): running
    # `dkms remove -m PKG -v VER -k $KVER` on every already-registered
    # package before calling autoinstall does NOT make autoinstall rebuild
    # them -- `dkms remove` with the package's only remaining kernel
    # version drops it from `dkms status` entirely (not just the KVER-
    # specific build), and `autoinstall` only rebuilds packages it already
    # knows should exist for KVER. The result was dkms status coming back
    # completely EMPTY after the "fixed" postinst ran -- WORSE than stale,
    # zero accelerators registered at all.
    #
    # SECOND BUG (caught live on O6N 2026-08-28, r256 -> r257): the NCZ
    # kernel packages use a KVER that does NOT change between revisions --
    # KERNELRELEASE is "7.2.0-sky1-ncz" for both r256 and r257; only the
    # Debian package revision differs. On such a same-KVER upgrade the
    # package is already registered as "installed" for KVER from the prior
    # revision, and `dkms install ... --force` short-circuits with
    # "Error! This module/version combo is already installed for kernel
    # 7.2.0-sky1-ncz" -- `--force` does NOT override that check (verified
    # live on the board; every one of aipu/6.2.0, cix-gpu-kmd/1.0,
    # cix-vpu-driver/1.0.2-ncz1 and panthor-cix/7.2.0 hit it). The build
    # step right before it succeeds, so the only real failure is the
    # install -- but the postinst (below) treated any non-zero exit as
    # FATAL, leaving the machine half-configured (headers in iF, image in
    # iU) for EVERY same-KVER upgrade. Verified live that the right
    # sequence is `dkms uninstall -m PKG -v VER -k KVER` immediately
    # before the build+install pair: uninstall drops only the installed
    # .ko for that kernel and KEEPS the package's registration in
    # `dkms status` (so it is still in our loop next time and autoinstall
    # still picks it up), which is exactly what we want.
    #
    # `dkms uninstall` (NOT `dkms remove`) is the right tool here. The
    # r255 attempt used `dkms remove -k $KVER`; on a package whose only
    # remaining kernel version was $KVER, `dkms remove` deletes the
    # package's registration entirely (not just the KVER-specific build),
    # so `dkms status` comes back empty after the postinst and autoinstall
    # has nothing to rebuild. uninstall is the surgical equivalent --
    # it removes the .ko for KVER only, leaves the source registration
    # intact, and lets the subsequent build+install --force land cleanly.
    # The uninstall itself may legitimately fail (module not installed
    # yet, e.g. a brand-new package on its first KVER), so its exit
    # status is tolerated -- what matters is whether build+install then
    # succeeds.
    #
    # CORRECT FIX: uninstall + force-build + force-install each already-
    # registered package DIRECTLY, by name. Do not depend on `dkms remove`
    # or `dkms autoinstall`'s own staleness heuristics at all. An install
    # that fails ONLY because the combo is already present is also
    # tolerated -- if `dkms status` still shows the package installed for
    # $KVER after the attempt, the package is fine regardless of the
    # install command's exit status (this can happen if a prior
    # postinst's build step landed the .ko but crashed before the
    # status record was updated, or after a manual recovery).
    # Parse `dkms status` into unique `name/version` lines. dkms emits
    # two shapes and the original `awk -F, ... | awk '{print $1}'`
    # pipeline mishandled the registered-but-never-built one:
    #   name/version: added                                 (registered, never built)
    #   name/version, kver, arch: installed|built           (built for some kernel)
    #   name/version, kver, arch: installed (Original modules exist)
    # The `added` form has NO comma before the colon, so the pipeline
    # never split on one and the trailing colon survived into `ver=`,
    # making every dkms uninstall/build/install call below die with
    # `The module/version combo: panthor-cix/7.2.0: is not located in
    # the DKMS tree`. Reproduced on O6N upgrading 7.2.8 -> 7.2.9 on
    # 2026-10-04; the whole postinst exited 1 and left headers+image
    # half-configured. This function strips the status chunk correctly
    # for both shapes and tolerates leading whitespace, the
    # `(Original modules exist)` suffix, and blank lines.
    # BEGIN ncz_dkms_registered_pkgvers
    ncz_dkms_registered_pkgvers() {
        awk '
            {
                # trim leading/trailing whitespace so leading-space garbage
                # and trailing-space garbage never reach the parser
                sub(/[ \t\r]+$/, "")
                sub(/^[ \t]+/, "")
                # the package/version chunk is everything before the first
                # comma OR the first colon -- whichever comes first is the
                # boundary between the `name/version` and the
                # `, kver, arch: status` tail. This collapses both forms:
                #   name/version: added                       -> name/version
                #   name/version, kver, arch: installed      -> name/version
                #   name/version, kver, arch: installed (...) -> name/version
                if (match($0, /[,:]/)) {
                    $0 = substr($0, 1, RSTART - 1)
                }
                if ($0 == "" || $0 !~ /\//) next
                print
            }
        ' | sort -u
    }
    # END ncz_dkms_registered_pkgvers

    log "forcing DKMS rebuild for every already-registered package (KVER-invariant versioning defeats autoinstall's own staleness check)"
    DKMS_LOG=/var/log/ncz-dkms-autoinstall.log
    : > "$DKMS_LOG"
    dkms_force_failed=0
    for pkgver in $("$DKMS_BIN" status 2>/dev/null | ncz_dkms_registered_pkgvers); do
        pkg="${pkgver%%/*}"
        ver="${pkgver#*/}"
        [ -n "$pkg" ] && [ -n "$ver" ] || continue
        log "  forcing $pkg/$ver for $KVER"
        # Uninstall first to clear any stale installed .ko for this KVER
        # from a prior same-KVER revision. Tolerate failure -- the module
        # may not be installed yet (first-KVER install of a new package).
        "$DKMS_BIN" uninstall -m "$pkg" -v "$ver" -k "$KVER" >>"$DKMS_LOG" 2>&1 || true
        if "$DKMS_BIN" build -m "$pkg" -v "$ver" -k "$KVER" --force >>"$DKMS_LOG" 2>&1 \
           && "$DKMS_BIN" install -m "$pkg" -v "$ver" -k "$KVER" --force >>"$DKMS_LOG" 2>&1; then
            log "  $pkg/$ver OK"
        else
            # The build almost always succeeds; the install may still
            # complain that the combo is already installed for KVER
            # despite the uninstall above (e.g. uninstall did not clear
            # the status record on this DKMS version). If `dkms status`
            # confirms the package is installed for $KVER, the postinst's
            # job is done -- do not fail the package upgrade over it.
            if "$DKMS_BIN" status -m "$pkg" -v "$ver" -k "$KVER" 2>/dev/null \
               | grep -q "$KVER"; then
                log "  $pkg/$ver already installed for $KVER (install reported a non-zero exit but the .ko is in place); treating as OK"
            else
                echo "linux-headers-cixmini[$KVER]: FATAL: forced rebuild of $pkg/$ver failed" >&2
                dkms_force_failed=1
            fi
        fi
    done
    # Catch anything registered under /usr/src but never built for KVER at
    # all (genuinely new, not a stale-KVER case) -- autoinstall is the
    # right tool for that, it is only the "already installed" skip that is
    # wrong for already-registered packages.
    "$DKMS_BIN" autoinstall -k "$KVER" >>"$DKMS_LOG" 2>&1 || true
    if [ "$dkms_force_failed" -eq 0 ]; then
        log "dkms forced rebuild OK"
        "$DKMS_BIN" status 2>/dev/null | sed 's/^/           /'
    else
        echo "linux-headers-cixmini[$KVER]: FATAL: one or more forced DKMS rebuilds failed" >&2
        echo "                              see $DKMS_LOG" >&2
        if [ -s "$DKMS_LOG" ]; then
            tail -30 "$DKMS_LOG" | sed 's/^/                              /' >&2
        fi
        # Surface the per-package failure mode for the four packages this
        # project's post-install registers. This is not exhaustive -- new
        # packages get the same treatment automatically -- but it gives the
        # operator the exact name+ver to grep /var/lib/dkms/.../build/make.log
        # for. dkms status AFTER a failed forced rebuild is the only ground
        # truth for "which package broke".
        echo "                              current dkms status:" >&2
        "$DKMS_BIN" status 2>/dev/null | sed 's/^/                              /' >&2
        exit 1
    fi
else
    warn "dkms binary not found; skipping autoinstall"
    warn "install dkms + the four CIX DKMS packages separately, then re-run"
    warn "  apt install --reinstall -y linux-headers-cixmini=\$(dpkg-query -W -f='\${Version}' linux-headers-cixmini)"
fi

# 4. Regenerate the initramfs. dracut is the primary builder (see
# post-install/94-dracut-config.sh), initramfs-tools is the fallback. By
# the time we reach this line DKMS has just produced fresh .ko files in
# /usr/lib/modules/$KVER/updates/, so the initrd we build NOW will
# contain the correct vermagic -- which is the whole point of the fix.
# depmod is implicit in both dracut and initramfs-tools, but call it
# explicitly first so /lib/modules/$KVER/modules.dep is in sync even if
# both builders are absent (a minimum rescue image).
if command -v depmod >/dev/null 2>&1; then
    depmod -a "$KVER" || warn "depmod -a $KVER failed (continuing)"
fi
if command -v dracut >/dev/null 2>&1; then
    log "regenerating initrd via dracut"
    if dracut --force --kver "$KVER" "/boot/initrd.img-$KVER"; then
        log "initrd regenerated (dracut)"
    else
        echo "linux-headers-cixmini[$KVER]: FATAL: dracut failed" >&2
        exit 1
    fi
elif command -v update-initramfs >/dev/null 2>&1; then
    log "regenerating initrd via update-initramfs (dracut absent)"
    if update-initramfs -c -k "$KVER" 2>/dev/null \
       || update-initramfs -u -k "$KVER" 2>/dev/null; then
        log "initrd regenerated (update-initramfs)"
    else
        echo "linux-headers-cixmini[$KVER]: FATAL: update-initramfs failed" >&2
        exit 1
    fi
else
    warn "neither dracut nor update-initramfs present; initrd not regenerated"
fi

log "OTA-DKMS-HEADER-FIX sequence complete"
exit 0
POSTINST_EOF
    chmod 0755 "$root/DEBIAN/postinst"

    # postrm: drop the build tree on remove, but ONLY for this $KVER (and
    # only if it is empty -- a manual /usr/src/ that is still referenced
    # must not be wiped). Matches the kernel .deb's own postrm style.
    sed -e "s|__KVER__|$kver|g" > "$root/DEBIAN/postrm" <<'POSTRM_EOF'
#!/bin/sh
set -e
KVER="__KVER__"
[ -n "$KVER" ] || exit 0
case "$1" in
  remove|purge)
    # Refuse to remove a non-empty tree -- a hand-installed src/ lives
    # next to the build/ tree and must survive a package uninstall.
    if [ -d "/usr/lib/modules/$KVER/build" ]; then
        other=$(ls -A "/usr/lib/modules/$KVER" 2>/dev/null | grep -v '^build$' | wc -l)
        if [ "$other" = "0" ]; then
            rm -rf "/usr/lib/modules/$KVER/build" 2>/dev/null || true
        fi
    fi
    # Best-effort depmod: kernel .deb's own postrm may have removed
    # /usr/lib/modules/$KVER entirely already; ignore the error.
    command -v depmod >/dev/null 2>&1 && depmod -a "$KVER" 2>/dev/null || true
    ;;
esac
exit 0
POSTRM_EOF
    chmod 0755 "$root/DEBIAN/postrm"

    local isize
    isize=$(installed_size_kb "$root")
    # Control: unquoted heredoc is fine here (no backticks in the body), and
    # we WANT the build-side values ($pkg, $ver, $isize, $kver, ...) substituted.
    cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: kernel
Priority: optional
Installed-Size: $isize
Depends: cixmini-boot (>= $CIXMINI_BOOT_MIN_VER), kmod, make
Recommends: dkms, build-essential, flex, bison, bc, libelf-dev, dracut | initramfs-tools | linux-initramfs-tool
Description: NCZ cixmini kernel headers ($kver) with OTA-DKMS rebuild
  Header tree for linux-image-cixmini-$kver, packaged as a separate .deb
  so an OTA install pulls both together. The postinst performs the full
  OTA-DKMS-HEADER-FIX-2026-08-21 sequence: stage the build/ tree, rebuild
  the host tools, run dkms autoinstall, and regenerate the initramfs.
  Without this package the kernel .deb boots with stale (previous-kernel)
  vermagic on every DKMS-built accelerator module -- confirmed on O6N
  against r246 and r247. See docs/OTA-DKMS-HEADER-FIX-2026-08-21.md.
EOF
    repro_finalize_root "$root"
    dpkg-deb --root-owner-group --build "$root" "$OUT/${pkg}_${ver}_arm64.deb"
}

# ---------------------------------------------------------------------------
# MANDATORY KERNEL BOOT GATE (2026-08-14).
#
# No kernel gets packaged without being booted first. r236 shipped a kernel
# that panicked at 1.2s into every boot of the installed system
# (cdns3_pci_probe NULL deref, PID 1, reboot loop) -- the installer booted
# fine, so nothing downstream of this script could have caught it.
#
# The gate boots the staged Image under qemu/KVM and additionally refuses any
# builtin driver whose PCI match table collides with an ID Sky1 itself
# presents. See build/kvm-kernel-gate.sh for why both halves are needed.
# ---------------------------------------------------------------------------
if [ -s "$ASSETS/mainline/Image-cixmini.bin" ]; then
    echo ""
    echo "== kernel boot gate =="
    "$REPO/build/kvm-kernel-gate.sh" "$ASSETS/mainline/Image-cixmini.bin" \
        || { echo "ERROR: kernel boot gate failed -- refusing to package this kernel." >&2; exit 1; }
    echo ""
fi

build_cixmini_boot

# ONE KERNEL TREE (2026-08-10): one Sky1 kernel tree only (26.7 shipped
# 7.2.0-rc7-sky1-ncz; 26.10 ships 7.3.0-rc7-sky1-ncz); 7.0.12-cix-sky1-next
# ("legacy") is superseded and its assets are gone.
#
# Guard on the ASSETS, not on KVER: resolve_kver falls back to the ISO-staging
# sidecar when assets/kernel/legacy/KVER is missing, so KVER_LEGACY still
# resolved to a stale 7.0.12 and the build died trying to package a kernel that
# is no longer on disk. A retired channel must be skipped, not resurrected from
# a leftover sidecar.
#
# Headers .deb is built in lockstep with the image. If a kernel .deb builds,
# its matching headers-cixmini.tar.zst MUST also build -- a kernel without a
# matching build/ tree was the entire r246/r247 defect, and silently skipping
# the headers .deb would reproduce it on the very next OTA. Set -e in this
# script means a failed build_headers_deb aborts the build, which is correct.
build_kernel_deb mainline "$KVER_NEXT" mainline ""
build_headers_deb mainline "$KVER_NEXT" mainline

# ----------------------------------------------------------------------
# Transitional packages: linux-image-cixmini-{edge,lts,legacy}
#
# 2026-08-21: the legacy channel is gone, so a board holding one of
# the old kernel package names (edge, lts, legacy) needs to upgrade to
# the new unified name `linux-image-cixmini`. That replacement is handled
# by the linux-image-cixmini control's Provides+Replaces+Conflicts list
# (see build_kernel_deb), not by an empty transitional package -- the
# kernel deb itself owns the rename.
#
# No separate linux-image-cixmini-{edge,lts,legacy} package is built
# any more.
# ----------------------------------------------------------------------

echo ""
echo "== built debs =="
ls -lh "$OUT"
echo ""
echo "== control summaries =="
for d in "$OUT"/*.deb; do
    echo "--- $d ---"
    dpkg-deb -f "$d" Package Version Architecture Depends Installed-Size
done
