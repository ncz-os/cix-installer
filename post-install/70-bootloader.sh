#!/bin/bash
# 70-bootloader.sh — rEFInd boot manager install + staged kernel menu.
# 26.6-r118: switched from systemd-boot to rEFInd (operator preference —
# "more resilient"; reverts to the 26.5 image-builder bootloader). rEFInd
# ships as a binary (refind_aa64.efi) under
# /usr/local/lib/cix-installer/assets/refind/ and is installed to the ESP at
# the firmware removable-media fallback path /EFI/BOOT/BOOTAA64.EFI, so the
# box boots even with an empty NVRAM BootOrder (confirmed on Sky1/MS-R1).
#
# Kernels + initrds are staged to the FAT ESP root (/boot/efi/vmlinuz-*,
# /boot/efi/initrd.img-*); rEFInd loads them directly from FAT and the
# kernel's OWN initramfs mounts the (btrfs) root — so rEFInd needs no
# btrfs/ext4 EFI filesystem driver.
#
# Menu (refind.conf manual entries), in order:
#   1. stable  — NCZ LTS kernel 6.18.x
#   2. edge    — NCZ NEXT 7.0.x kernel (DEFAULT when staged)
#   3. rescue  — pinned clean kernel, rescue.target, NPU/GPU/VPU/KMS blacklisted
#
# THREE PHYSICAL KERNELS on the ESP (operator requirement 2026-06-01 — "3
# kernels"):
#   /vmlinuz-$KVER_LTS          daily driver
#   /vmlinuz-$KVER_NEXT         edge [BETA] (default when staged)
#   /vmlinuz-$KVER_LTS-rescue   clean/rescue/dev — an independent, pinned
#                               copy of the proven BSP binary so a later
#                               daily-LTS kernel swap can never disturb the
#                               known-good recovery kernel.
#
# TRADEOFF vs systemd-boot (deliberate, r118): rEFInd has no boot-counting,
# so there is NO automatic edge->stable rollback. The 3-entry menu is for
# MANUAL rescue selection — the refind.conf `timeout` always presents the
# menu so the operator can pick stable/rescue if an edge boot misbehaves.
set -euo pipefail

echo "[70] rEFInd bootloader (staged kernel menu)"

INSTALLER_META=/usr/local/lib/cix-installer
REFIND_SRC="$INSTALLER_META/assets/refind/refind_aa64.efi"
KVER_LTS=""
[ -f "$INSTALLER_META/KVER_LTS" ] && KVER_LTS=$(cat "$INSTALLER_META/KVER_LTS" 2>/dev/null || true)
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)

if [ -z "$KVER_LTS" ] && [ -z "$KVER_NEXT" ]; then
    echo "ERROR: no KVER_LTS or KVER_NEXT sidecar present"
    exit 1
fi

BUILD_VERSION="(unknown)"
[ -f "$INSTALLER_META/BUILD_VERSION" ] && BUILD_VERSION=$(cat "$INSTALLER_META/BUILD_VERSION" 2>/dev/null || true)

echo "  KVER_LTS=$KVER_LTS"
echo "  KVER_NEXT=${KVER_NEXT:-(not present)}"
echo "  BUILD_VERSION=$BUILD_VERSION"

# Prevent systemd-boot deb postinst from double-staging kernels to the ESP
mkdir -p /etc/kernel
echo "layout=other" > /etc/kernel/install.conf
echo "  /etc/kernel/install.conf set to layout=other (disables double-staging)"

# r118: rEFInd ships as a prebuilt binary in the installer payload — NO apt
# needed (rEFInd isn't in Ubuntu ports' default pool). This also makes the
# bootloader install immune to the dpkg-wedge failure modes that previously
# made `apt install systemd-boot` flaky (a held dpkg frontend lock, or an
# unrelated half-configured cix-* py3.14 package poisoning apt's exit code).
if [ ! -s "$REFIND_SRC" ]; then
    echo "ERROR: rEFInd binary missing/empty at $REFIND_SRC"
    echo "       (build did not stage build/refind-bin/refind_aa64.efi) — cannot install a bootloader."
    exit 1
fi
echo "  rEFInd binary present: $REFIND_SRC ($(du -h "$REFIND_SRC" | cut -f1))"
# efibootmgr is best-effort only — we boot via the EFI/BOOT fallback path.
command -v efibootmgr >/dev/null 2>&1 || echo "  note: efibootmgr not present — relying on /EFI/BOOT/BOOTAA64.EFI fallback"

# Validate /boot/efi is actually mounted as the ESP — without this, a
# missing ESP mount (e.g. preseed partman edge case) would let
# `bootctl install` write loader files into a plain directory on the
# rootfs, then we'd write entries that go nowhere, and the disk would
# boot to nothing. Fail fast with clear diagnostics.
if ! findmnt -no FSTYPE /boot/efi >/dev/null 2>&1; then
    echo "ERROR: /boot/efi is not mounted — cannot install the bootloader."
    echo "  findmnt /boot/efi → not found"
    echo "  block devices:"
    lsblk 2>&1 | head -10 || true
    echo "  fstab entry for /boot/efi:"
    grep -E "/boot/efi" /etc/fstab 2>&1 || echo "  (no /boot/efi entry)"
    exit 1
fi
ESP_FSTYPE=$(findmnt -no FSTYPE /boot/efi)
if [ "$ESP_FSTYPE" != "vfat" ]; then
    echo "ERROR: /boot/efi is mounted as $ESP_FSTYPE, expected vfat (FAT32 ESP)."
    exit 1
fi
echo "  /boot/efi is mounted (vfat) — proceeding with rEFInd install"

# Fail-closed before touching existing ESP contents. A failed required
# kernel phase must not let this script wipe a previously bootable ESP.
verify_payload_readable() {
    local label="$1"
    local path="$2"

    if [ ! -r "$path" ]; then
        echo "ERROR: $label payload $path is not readable."
        echo "       Refusing to wipe the ESP until the source payload can be staged."
        exit 1
    fi
    if ! dd if="$path" of=/dev/null bs=1M status=none; then
        echo "ERROR: failed read probe for $label payload $path."
        echo "       Refusing to wipe the ESP until the source payload can be copied."
        exit 1
    fi
}

LTS_PREFLIGHT_READY=0
NEXT_PREFLIGHT_READY=0
if [ -n "$KVER_LTS" ]; then
    if [ -s "/boot/vmlinuz-$KVER_LTS" ] && [ -s "/boot/initrd.img-$KVER_LTS" ]; then
        verify_payload_readable "LTS kernel" "/boot/vmlinuz-$KVER_LTS"
        verify_payload_readable "LTS initrd" "/boot/initrd.img-$KVER_LTS"
        LTS_PREFLIGHT_READY=1
        echo "  preflight OK: LTS kernel/initrd present and readable for $KVER_LTS"
    elif [ -s "/boot/vmlinuz-$KVER_LTS" ] && [ ! -s "/boot/initrd.img-$KVER_LTS" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LTS exists but /boot/initrd.img-$KVER_LTS is missing or empty."
        echo "       Refusing to wipe the ESP without a complete LTS kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_LTS" ]; then
        echo "ERROR: incomplete LTS kernel payload for $KVER_LTS."
        echo "       Need non-empty /boot/vmlinuz-$KVER_LTS and /boot/initrd.img-$KVER_LTS before ESP wipe."
        exit 1
    else
        echo "  WARN: LTS kernel payload for $KVER_LTS missing — LTS entry will be skipped"
    fi
fi
if [ -n "$KVER_NEXT" ]; then
    if [ -s "/boot/vmlinuz-$KVER_NEXT" ] && [ -s "/boot/initrd.img-$KVER_NEXT" ]; then
        verify_payload_readable "NEXT kernel" "/boot/vmlinuz-$KVER_NEXT"
        verify_payload_readable "NEXT initrd" "/boot/initrd.img-$KVER_NEXT"
        NEXT_PREFLIGHT_READY=1
        echo "  preflight OK: NEXT kernel/initrd present and readable for $KVER_NEXT"
    elif [ -s "/boot/vmlinuz-$KVER_NEXT" ] && [ ! -s "/boot/initrd.img-$KVER_NEXT" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_NEXT exists but /boot/initrd.img-$KVER_NEXT is missing or empty."
        echo "       Refusing to wipe the ESP without a complete NEXT kernel payload."
        exit 1
    elif [ -e "/boot/vmlinuz-$KVER_NEXT" ]; then
        echo "ERROR: incomplete NEXT kernel payload for $KVER_NEXT."
        echo "       Need non-empty /boot/vmlinuz-$KVER_NEXT and /boot/initrd.img-$KVER_NEXT before ESP wipe."
        exit 1
    else
        echo "  WARN: NEXT kernel payload for $KVER_NEXT missing — NEXT entry will be skipped"
    fi
fi
if [ "$LTS_PREFLIGHT_READY" = "0" ] && [ "$NEXT_PREFLIGHT_READY" = "0" ]; then
    echo "ERROR: no declared kernel has both a non-empty vmlinuz and initrd in /boot."
    echo "       Refusing to wipe the ESP because there is nothing bootable to restage."
    exit 1
fi
echo "  preflight OK: at least one complete declared kernel payload is present"

# r118: the rEFInd binary + refind.conf are installed at the END of this
# script, AFTER kernels/initrds are staged to the ESP and per-entry cmdlines
# are computed (see the "Install rEFInd" section below). Nothing to do here.

# ----------------------------------------------------------------------
# Discover root partition by PARTUUID
#
# r121 btrfs fix: on a btrfs root installed into a subvolume (d-i
# partman-btrfs uses @rootfs), `findmnt -no SOURCE /` returns the device
# WITH the subvolume bracket, e.g. "/dev/nvme0n1p2[/@rootfs]". Passing that
# to blkid makes blkid exit 2 ("device not found"), which under
# `set -euo pipefail` aborted 70-bootloader -> run-all -> late.sh with the
# red "preseeded command failed (exit 2)" dialog. `--nofsroot` strips the
# [/subvol] suffix so blkid sees the bare partition device.
# ----------------------------------------------------------------------
ROOT_SRC=$(findmnt -no SOURCE --nofsroot /)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC")
ROOT_FSTYPE=$(findmnt -no FSTYPE /)
# btrfs subvolume (e.g. /@rootfs) -> rootflags=subvol=@rootfs so the kernel
# mounts the installed subvolume, not the btrfs top-level. Empty / "/" means
# the root is the top-level volume and no rootflags is needed.
ROOT_SUBVOL=""
if [ "$ROOT_FSTYPE" = "btrfs" ]; then
    ROOT_FSROOT=$(findmnt -no FSROOT / 2>/dev/null || echo "/")
    case "$ROOT_FSROOT" in
        ""|"/") ROOT_SUBVOL="" ;;
        *)      ROOT_SUBVOL="${ROOT_FSROOT#/}" ;;
    esac
fi
echo "  root source=$ROOT_SRC PARTUUID=$ROOT_PARTUUID fstype=$ROOT_FSTYPE subvol=${ROOT_SUBVOL:-(none)}"

# ----------------------------------------------------------------------
# Cmdline (MartJohnson 2026-04-30 working set for MS-R1, both LTS+NEXT)
#
#   loglevel=4                          — visible kernel msgs through boot
#   console=tty0 console=ttyAMA2,115200 — HDMI primary + serial mirror
#   efi=noruntime                       — disable buggy MS-R1 EFI runtime services
#   acpi=force                          — bypass DSDT preference checks
#   arm-smmu-v3.disable_bypass=0        — SMMUv3 IORT compatibility
#   audit_backlog_limit=8192            — early-boot audit subsystem doesn't drop msgs
#   clk_ignore_unused                   — Cix Sky1 SCMI requires this
#   keep_bootcon                        — early console persists through handoff
#   panic=30                            — 30s grace before reboot on panic
#
# NPU is config-disabled in MartJohnson configs (CONFIG_ARMCHINA_NPU=n)
# so cmdline module_blacklist=armchina_npu is unnecessary. We don't
# add module blacklists here — the configs already disable everything
# that would cause boot trouble on MS-R1.
# ----------------------------------------------------------------------
# r75 Codex round-5 HIGH fix — per-entry cmdline split.
#
# r130.6 (Codex audit): LTS and NEXT both keep efi=noruntime. The old
# rationale for dropping it on NEXT was systemd-bless-boot boot-counting
# (LoaderBootCountPath needs EFI runtime variables) — but this installer boots
# via rEFInd with `use_nvram false`, so there is no bless-boot path to protect
# and the MS-R1 EFI-runtime quirk is still relevant. Keep noruntime on both.
# r123 (2026-06-22) boot speed + cleanliness fix:
#   - DROPPED console=ttyAMA2,115200 — /dev/ttyAMA2 does NOT enumerate on the
#     MS-R1 when booting from disk (only the debug-harness exposes it). systemd
#     auto-generates serial-getty@ttyAMA2 -> BindsTo dev-ttyAMA2.device, which
#     then blocks boot for the full 90s device timeout. Removing it cuts ~90s.
#   - DROPPED keep_bootcon — held the verbose early console through handoff,
#     fighting the Plymouth splash. SPLASH="quiet splash" (below) is appended
#     to stable+edge for a clean graphical boot; rescue stays verbose.
#   - DROPPED loglevel — stable/edge get `quiet` (via SPLASH); rescue inherits
#     this base WITHOUT splash so it boots at the kernel-default verbose level.
LTS_CMDLINE_BASE="console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"
# r105 boot-visibility fix (2026-06-17): NEXT (7.0.x) does NOT get an early
# framebuffer console like LTS does. With identical fb config, LTS's sysfb
# registers an efi-framebuffer device → efifb binds → colour console + boot
# penguins from ~1s. On 7.0.12, sysfb registers NO framebuffer device
# (screen_info isn't populated for it — a 7.0.x regression vs 6.18), so the
# panel is a dummy console until linlondp/panthor power on via SCMI at ~5.2s
# — i.e. the whole early boot is invisible on HDMI.
#   earlycon=efifb  — write straight to the firmware GOP framebuffer (the one
#                     systemd-boot drew its menu on) from t=0, so early kernel
#                     messages are visible on the panel before the real KMS
#                     display comes up. keep_bootcon holds it through handoff.
#   loglevel=7      — show info-level boot messages (NOT ignore_loglevel,
#                     which firehoses debug spam onto the console at runtime).
# Verified on .66: early messages now render on HDMI from boot. The brief
# dark gap before the colour linlondp console is the SCMI display power-on
# latency and is not removable from cmdline (needs efifb to bind early —
# kernel-side screen_info fix, tracked separately).
# r123: also dropped earlycon=efifb here. It was added (r105) to make early
# NEXT boot text visible on HDMI before KMS, but that is exactly the verbose
# "ugly" boot we now replace with the Plymouth splash. Early text is still
# available via the rescue entry (verbose, no splash).
NEXT_CMDLINE_BASE="console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453"

# Plymouth splash flags for a clean graphical boot. Appended to stable+edge
# only (see LTS_OPTIONS/NEXT_OPTIONS below) — rescue deliberately omits these
# so it stays text-verbose. 60-plymouth.sh sets the `nclawzero` default theme
# and embeds it (+ the script module) in the initramfs; here we just pass the
# kernel flags. An optional /etc/kernel/cmdline.d/10-splash.conf overrides.
SPLASH="quiet splash"
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

# r118: rootfstype is DETECTED from the live mount (was hardcoded ext4, which
# silently broke btrfs roots — the kernel couldn't mount /). btrfs/ext4 both
# handled; btrfs.ko + deps ship in the -next initramfs.
# r121: for a btrfs subvolume root, also pass rootflags=subvol=<subvol> so the
# kernel mounts the installed @rootfs subvolume rather than the top-level.
ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=$ROOT_FSTYPE rw"
if [ -n "$ROOT_SUBVOL" ]; then
    ROOT_OPTS="$ROOT_OPTS rootflags=subvol=$ROOT_SUBVOL"
fi

# ----------------------------------------------------------------------
# WIPE STALE ESP STATE immediately before writing fresh entries + kernels.
#
# This broad clear is intentional, but only after the fail-closed preflight
# has proven /boot/efi is the vfat ESP, bootctl exists, and at least one
# declared kernel has a complete kernel+initrd payload ready to restage.
# ----------------------------------------------------------------------
echo "  wiping stale ESP entries + kernel images..."
rm -f /boot/efi/vmlinuz-*
rm -f /boot/efi/initrd.img-*
rm -rf /boot/efi/[0-9a-f]*  # Wipe 32-hex kernel-install machine-id dirs
rm -f /boot/efi/EFI/Linux/* 2>/dev/null
# r118: clear any prior systemd-boot install + stale rEFInd config so a
# re-run lands a clean rEFInd-only ESP.
rm -rf /boot/efi/loader 2>/dev/null || true
rm -rf /boot/efi/EFI/systemd 2>/dev/null || true
rm -f /boot/efi/EFI/BOOT/refind.conf 2>/dev/null || true
echo "  ESP wiped — proceeding with kernel/initrd staging"

# ----------------------------------------------------------------------
# Stage kernels/initrds onto ESP — systemd-boot reads /boot/efi by default.
#
# Tolerant only for an absent kernel image: if a KVER sidecar exists but
# that kernel was not installed, log a clear warning and skip that entry.
# A present kernel without a present initrd is a hard error, because it means
# the required 10-our-kernel.sh initramfs step failed.
# ----------------------------------------------------------------------
LTS_AVAILABLE=0
NEXT_AVAILABLE=0
LTS_INITRD_AVAILABLE=0
NEXT_INITRD_AVAILABLE=0

if [ -n "$KVER_LTS" ] && [ -s "/boot/vmlinuz-$KVER_LTS" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_LTS" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_LTS exists but /boot/initrd.img-$KVER_LTS is missing or empty."
        echo "       Refusing to write an LTS loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_LTS" "/boot/efi/vmlinuz-$KVER_LTS"
    echo "  staged /boot/efi/vmlinuz-$KVER_LTS"
    LTS_AVAILABLE=1
    # Stage initrd (NPU SSDT override is prepended by 80-npu.sh)
    install -m 0644 "/boot/initrd.img-$KVER_LTS" "/boot/efi/initrd.img-$KVER_LTS"
    echo "  staged /boot/efi/initrd.img-$KVER_LTS"
    LTS_INITRD_AVAILABLE=1
elif [ -n "$KVER_LTS" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_LTS missing — LTS entry will be SKIPPED"
else
    echo "  LTS kernel not staged — skipping LTS fallback entry"
fi

if [ -n "$KVER_NEXT" ] && [ -s "/boot/vmlinuz-$KVER_NEXT" ]; then
    if [ ! -s "/boot/initrd.img-$KVER_NEXT" ]; then
        echo "ERROR: /boot/vmlinuz-$KVER_NEXT exists but /boot/initrd.img-$KVER_NEXT is missing or empty."
        echo "       Refusing to write a NEXT loader entry without an initrd."
        exit 1
    fi
    install -m 0644 "/boot/vmlinuz-$KVER_NEXT" "/boot/efi/vmlinuz-$KVER_NEXT"
    echo "  staged /boot/efi/vmlinuz-$KVER_NEXT"
    NEXT_AVAILABLE=1
    install -m 0644 "/boot/initrd.img-$KVER_NEXT" "/boot/efi/initrd.img-$KVER_NEXT"
    echo "  staged /boot/efi/initrd.img-$KVER_NEXT"
    NEXT_INITRD_AVAILABLE=1
elif [ -n "$KVER_NEXT" ]; then
    echo "  WARN: /boot/vmlinuz-$KVER_NEXT missing — BETA entry will be SKIPPED"
fi

if [ "$LTS_AVAILABLE" = "0" ] && [ "$NEXT_AVAILABLE" = "0" ]; then
    echo "ERROR: NEITHER kernel installed — system is unbootable."
    echo "       Check 10-our-kernel.sh log for failures."
    exit 1
fi

# ======================================================================
# Build per-entry kernel cmdlines (assembled into refind.conf below).
# No per-entry files for rEFInd — everything lives in one refind.conf.
# ======================================================================
LTS_OPTIONS=""
if [ "$LTS_AVAILABLE" = "1" ]; then
    LTS_OPTIONS="$ROOT_OPTS $LTS_CMDLINE_BASE"
    [ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"
fi

NEXT_OPTIONS=""
if [ "$NEXT_AVAILABLE" = "1" ]; then
    NEXT_OPTIONS="$ROOT_OPTS $NEXT_CMDLINE_BASE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"
fi

# ----------------------------------------------------------------------
# Rescue: pin an INDEPENDENT clean kernel copy + a fully-safe cmdline.
#
# "FULLY SAFE" (operator requirement 2026-06-01): rescue must reach a
# login shell + network even if every accelerator is flaky. Beyond
# rescue.target we blacklist NPU/GPU/VPU + the KMS/display drivers that
# can seize the panel and black-screen the box. We DO NOT add nomodeset
# (kills the firmware efifb console on Sky1) and we KEEP
# arm-smmu-v3.disable_bypass=0 so NVMe + NIC DMA still work in rescue.
#
# 3-kernel layout: the rescue kernel is a PHYSICALLY INDEPENDENT copy of
# the proven BSP binary (separate inode), so a later daily-LTS kernel
# swap can never disturb the known-good recovery kernel.
# (logic unchanged from r116; only the consumer is now refind.conf.)
# ----------------------------------------------------------------------
if [ "$LTS_AVAILABLE" = "1" ]; then
    RESCUE_KVER="$KVER_LTS"
    RESCUE_CMDLINE_BASE="$LTS_CMDLINE_BASE"
elif [ "$NEXT_AVAILABLE" = "1" ]; then
    RESCUE_KVER="$KVER_NEXT"
    RESCUE_CMDLINE_BASE="$NEXT_CMDLINE_BASE"
else
    RESCUE_KVER=""
    RESCUE_CMDLINE_BASE=""
fi

RESCUE_PIN=""
RESCUE_OPTIONS=""
RESCUE_HAS_INITRD=0
if [ -n "$RESCUE_KVER" ]; then
    RESCUE_PIN="${RESCUE_KVER}-rescue"
    if [ ! -s "/boot/efi/vmlinuz-$RESCUE_KVER" ]; then
        echo "ERROR: /boot/efi/vmlinuz-$RESCUE_KVER is missing or empty — cannot pin a clean rescue kernel."
        exit 1
    fi
    install -m 0644 "/boot/efi/vmlinuz-$RESCUE_KVER" "/boot/efi/vmlinuz-$RESCUE_PIN"
    echo "  staged pinned clean/rescue kernel /boot/efi/vmlinuz-$RESCUE_PIN"
    if { [ "$RESCUE_KVER" = "$KVER_LTS" ] && [ "$LTS_INITRD_AVAILABLE" = "1" ]; } || \
       { [ "$RESCUE_KVER" = "$KVER_NEXT" ] && [ "$NEXT_INITRD_AVAILABLE" = "1" ]; }; then
        install -m 0644 "/boot/efi/initrd.img-$RESCUE_KVER" "/boot/efi/initrd.img-$RESCUE_PIN"
        echo "  staged pinned clean/rescue initrd /boot/efi/initrd.img-$RESCUE_PIN"
        RESCUE_HAS_INITRD=1
    fi

    # Single canonical module_blacklist= token (kernel honours only the last).
    RESCUE_EXTRA_BLACKLIST="armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu,trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display"
    RESCUE_EXISTING_BL=$(printf '%s\n' "$RESCUE_CMDLINE_BASE" \
        | tr ' ' '\n' | sed -n 's/^module_blacklist=//p' | paste -sd, -)
    RESCUE_CMDLINE_NOBL=$(printf '%s\n' "$RESCUE_CMDLINE_BASE" \
        | tr ' ' '\n' | grep -vE '^(module_blacklist=|$)' | paste -sd' ' -)
    if [ -n "$RESCUE_EXISTING_BL" ]; then
        RESCUE_MERGED_BL="$RESCUE_EXISTING_BL,$RESCUE_EXTRA_BLACKLIST"
    else
        RESCUE_MERGED_BL="$RESCUE_EXTRA_BLACKLIST"
    fi
    RESCUE_CMDLINE_SAFE="$RESCUE_CMDLINE_NOBL module_blacklist=$RESCUE_MERGED_BL"
    RESCUE_OPTIONS="$ROOT_OPTS $RESCUE_CMDLINE_SAFE systemd.unit=rescue.target"
fi

# ----------------------------------------------------------------------
# r130: dedicated on-disk RESCUE PARTITION entry. This is DISTINCT from the
# rescue pin above (which is rescue.target on the SHARED production root): the
# rescue PARTITION is an entirely separate Ubuntu arm64 rootfs on its own
# partition (NCZRESCUE), populated by post-install/72-rescue-partition.sh and
# booted via its OWN root=PARTUUID with the LTS kernel + full recovery toolset.
# If the main root is unbootable, this entry still boots.
#
# r130.6 (operator: rescue booted but screen was blank): the rescue partition
# boots the LTS 6.18 kernel with the NORMAL LTS cmdline (display drivers KEPT),
# NOT the rescue.target NPU/GPU/VPU/KMS blacklist. This is a standalone operator
# environment — it MUST have a usable local console, so we must not strip the
# display/KMS drivers. (The rescue.target pin above keeps the blacklist; that
# one recovers a broken MAIN root and is fine headless-over-serial.)
#
# 72 runs as a numbered hook and leaves a RESCUE_READY marker (PARTUUID + kver);
# we read it here and, if present, emit a 4th rEFInd menuentry. We reuse the
# already-staged LTS kernel/initrd on the ESP (vmlinuz-$KVER_LTS) — only the
# root= + cmdline differ from the stable entry — so no extra ESP kernel copy.
# ----------------------------------------------------------------------
RESCUE_READY="$INSTALLER_META/RESCUE_READY"
RESCUEPART_OPTIONS=""
if [ -f "$RESCUE_READY" ] && [ "$LTS_AVAILABLE" = "1" ]; then
    RESCUEPART_PARTUUID=$(sed -n 's/^PARTUUID=//p' "$RESCUE_READY" | head -1)
    if [ -n "$RESCUEPART_PARTUUID" ]; then
        # Use the NORMAL LTS cmdline (display drivers kept) so the rescue
        # partition has a working local console. NO module_blacklist and NO
        # "quiet splash" (stays text-verbose for recovery visibility).
        RESCUEPART_OPTIONS="root=PARTUUID=$RESCUEPART_PARTUUID rootwait rootfstype=ext4 rw $LTS_CMDLINE_BASE"
        echo "  rescue-partition ready (PARTUUID=$RESCUEPART_PARTUUID) — adding rEFInd rescuepart entry (LTS + normal display cmdline)"
    else
        echo "  rescue-partition marker present but no PARTUUID — skipping rescuepart entry"
    fi
else
    echo "  no rescue-partition marker ($RESCUE_READY) or no LTS kernel — skipping rescuepart entry"
fi

# ======================================================================
# Install rEFInd: binary at the firmware fallback path + refind.conf menu.
# ======================================================================
install -d -m 0755 /boot/efi/EFI/BOOT
install -m 0644 "$REFIND_SRC" /boot/efi/EFI/BOOT/BOOTAA64.EFI
if [ ! -s /boot/efi/EFI/BOOT/BOOTAA64.EFI ]; then
    echo "ERROR: failed to install rEFInd to /boot/efi/EFI/BOOT/BOOTAA64.EFI"
    exit 1
fi
echo "  rEFInd installed → /boot/efi/EFI/BOOT/BOOTAA64.EFI (firmware fallback path)"

# r127: startup banner ("NCZ-OS 26.6"). Installed next to refind.conf so
# rEFInd resolves it by bare filename. Optional — if the asset is absent we
# simply omit the `banner` directive (rEFInd falls back to its built-in art).
BANNER_SRC="$INSTALLER_META/assets/refind/ncz-banner.png"
REFIND_BANNER=""
if [ -s "$BANNER_SRC" ]; then
    install -m 0644 "$BANNER_SRC" /boot/efi/EFI/BOOT/ncz-banner.png
    REFIND_BANNER="ncz-banner.png"
    echo "  rEFInd banner installed → /boot/efi/EFI/BOOT/ncz-banner.png"
else
    echo "  note: rEFInd banner asset absent ($BANNER_SRC) — using default rEFInd art"
fi

# r128: NCZ tile icon for each menu entry (replaces rEFInd's generic Linux
# glyph). Installed next to refind.conf so a bare `icon ncz.png` resolves.
ICON_SRC="$INSTALLER_META/assets/refind/ncz.png"
REFIND_ICON=""
if [ -s "$ICON_SRC" ]; then
    install -m 0644 "$ICON_SRC" /boot/efi/EFI/BOOT/ncz.png
    REFIND_ICON="ncz.png"
    echo "  rEFInd entry icon installed → /boot/efi/EFI/BOOT/ncz.png"
fi

# r128: rEFInd's standard icons/ directory MUST exist next to refind.conf, or
# rEFInd silently falls back to TEXT-ONLY mode (no banner, no graphical menu) —
# this is documented rEFInd behaviour and was why the NCZ-OS 26.6 banner did
# not paint on Sky1. Installing it enables the graphical boot menu.
ICONS_SRC="$INSTALLER_META/assets/refind/icons"
if [ -d "$ICONS_SRC" ]; then
    rm -rf /boot/efi/EFI/BOOT/icons
    cp -a "$ICONS_SRC" /boot/efi/EFI/BOOT/icons
    echo "  rEFInd icons/ installed → /boot/efi/EFI/BOOT/icons ($(ls /boot/efi/EFI/BOOT/icons 2>/dev/null | wc -l | tr -d ' ') files)"
else
    echo "  WARN: rEFInd icons/ asset absent ($ICONS_SRC) → menu will render TEXT-ONLY (no banner)"
fi

# default_selection matches a substring of the menu-entry title. edge is the
# default when staged (operator: edge supports more hardware and is the
# intended default), else stable. rescue is always manual-only.
if [ "$NEXT_AVAILABLE" = "1" ]; then
    DEFAULT_TOKEN="edge"
else
    DEFAULT_TOKEN="stable"
fi

# refind.conf lives next to the binary; rEFInd resolves loader/initrd paths
# from the volume (ESP) root, where we staged the kernels.
REFIND_CONF=/boot/efi/EFI/BOOT/refind.conf
{
    echo "# rEFInd — NCZ cixmini $BUILD_VERSION (generated by 70-bootloader.sh)"
    echo "# Kernels live on the FAT ESP; each kernel's initramfs mounts the"
    echo "# $ROOT_FSTYPE root. No btrfs/ext4 EFI driver is required."
    echo "timeout 10"
    echo "log_level 0"
    echo "use_nvram false"
    # r128: force a graphical GOP mode. Without this the Sky1 firmware can leave
    # rEFInd rendering text-only; `resolution max` selects the largest reported
    # GOP mode and locks in graphics so the NCZ-OS 26.6 banner + icons paint.
    echo "resolution max"
    [ -n "$REFIND_BANNER" ] && echo "banner $REFIND_BANNER"
    # fillscreen makes the NCZ-OS 26.6 art the full menu background (not a
    # small top strip), so the whole rEFInd main menu is branded.
    [ -n "$REFIND_BANNER" ] && echo "banner_scale fillscreen"
    echo "showtools shell,reboot,shutdown,firmware"
    echo "scanfor manual"
    echo "scan_all_linux_kernels false"
    echo "default_selection \"$DEFAULT_TOKEN\""
    echo
    if [ "$LTS_AVAILABLE" = "1" ]; then
        echo "menuentry \"NCZ-OS 26.6  ·  stable — kernel $KVER_LTS (LTS 6.18)\" {"
        echo "    loader  /vmlinuz-$KVER_LTS"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$LTS_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_LTS"
        echo "    options \"$LTS_OPTIONS\""
        echo "}"
        echo
    fi
    if [ "$NEXT_AVAILABLE" = "1" ]; then
        echo "menuentry \"NCZ-OS 26.6  ·  edge — kernel $KVER_NEXT (NEXT 7.0.x) [DEFAULT]\" {"
        echo "    loader  /vmlinuz-$KVER_NEXT"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$NEXT_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_NEXT"
        echo "    options \"$NEXT_OPTIONS\""
        echo "}"
        echo
    fi
    if [ -n "$RESCUE_PIN" ]; then
        echo "menuentry \"NCZ-OS 26.6  ·  rescue — $RESCUE_PIN (safe: no NPU/GPU/VPU/KMS)\" {"
        echo "    loader  /vmlinuz-$RESCUE_PIN"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$RESCUE_HAS_INITRD" = "1" ] && echo "    initrd  /initrd.img-$RESCUE_PIN"
        echo "    options \"$RESCUE_OPTIONS\""
        echo "}"
        echo
    fi
    # r130.6: dedicated on-disk RESCUE PARTITION (separate rootfs, LTS kernel,
    # NORMAL display cmdline so the local console works, full toolset). Reuses
    # the staged LTS kernel/initrd; only root= differs from the stable entry.
    if [ -n "$RESCUEPART_OPTIONS" ]; then
        echo "menuentry \"NCZ-OS 26.6  ·  RESCUE PARTITION — LTS $KVER_LTS, full toolset (telnet/dropbear/ssh)\" {"
        echo "    loader  /vmlinuz-$KVER_LTS"
        [ -n "$REFIND_ICON" ] && echo "    icon    $REFIND_ICON"
        [ "$LTS_INITRD_AVAILABLE" = "1" ] && echo "    initrd  /initrd.img-$KVER_LTS"
        echo "    options \"$RESCUEPART_OPTIONS\""
        echo "}"
        echo
    fi
} > "$REFIND_CONF"
echo "  wrote $REFIND_CONF (default_selection=$DEFAULT_TOKEN)"

# Best-effort NVRAM entry. We boot via the EFI/BOOT fallback path regardless,
# so this failing (no efibootmgr, RO efivars in chroot) is non-fatal.
if command -v efibootmgr >/dev/null 2>&1; then
    EFI_DEV=$(findmnt -no SOURCE /boot/efi)
    EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV" 2>/dev/null || true)
    EFI_PART="${EFI_DEV##*[!0-9]}"
    if [ -n "$EFI_DISK" ] && [ -n "$EFI_PART" ]; then
        efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
            -L "nclawzero (rEFInd)" -l '\EFI\BOOT\BOOTAA64.EFI' >/dev/null 2>&1 || true
    fi
fi

echo ""
echo "===== rEFInd installed — refind.conf ====="
cat "$REFIND_CONF"
echo ""
echo "ESP contents:"
ls -la /boot/efi/ 2>&1 | sed 's/^/  /' | head -25
echo "  EFI/BOOT:"
ls -la /boot/efi/EFI/BOOT/ 2>&1 | sed 's/^/    /'
