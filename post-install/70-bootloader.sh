#!/bin/bash
# 70-bootloader.sh — systemd-boot install + staged kernel loader entries.
# 26.6-r92: DEFAULT is the NEXT 7.0.12 edge channel when it is staged.
# LTS remains present as stable fallback and rescue source. The edge entry
# keeps systemd-boot +3-0 boot-count rollback semantics so failed NEXT boots
# automatically fall back to stable/rescue choices.
#
# Loader entries (in menu order when all staged kernels exist):
#   1. cixmini-stable.conf      (NCZ LTS kernel 6.18.x, stable fallback)
#   2. cixmini-edge+3-0.conf    (DEFAULT when present — NCZ NEXT kernel, 3-try rollback)
#   3. cixmini-rescue.conf      (FULLY SAFE: rescue.target on a PINNED clean
#                              kernel, NPU/GPU/VPU/KMS blacklisted)
#
# THREE PHYSICAL KERNELS on the ESP (operator requirement 2026-06-01 — "3
# kernels"):
#   /vmlinuz-$KVER_LTS          daily driver (default)
#   /vmlinuz-$KVER_NEXT         7.1 edge [BETA]
#   /vmlinuz-$KVER_LTS-rescue   clean/rescue/dev — an independent, pinned
#                               copy of the proven 6.18.26 BSP binary. Same
#                               bits as LTS today, but a SEPARATE file so a
#                               later daily-LTS kernel swap can never disturb
#                               the known-good recovery kernel. This is "there
#                               must always be a rescue kernel choice" in its
#                               strongest form.
#
# CRITICAL: systemd-boot's loader entry parser does NOT support
# backslash line-continuation — every line MUST be standalone. Earlier
# version tried multi-line `options \` and bootctl silently dropped
# half the cmdline.
set -euo pipefail

echo "[70] systemd-boot bootloader (staged kernel payload)"

INSTALLER_META=/usr/local/lib/cix-installer
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

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-boot efibootmgr

command -v bootctl >/dev/null || { echo "ERROR: bootctl not installed"; exit 1; }

# Validate /boot/efi is actually mounted as the ESP — without this, a
# missing ESP mount (e.g. preseed partman edge case) would let
# `bootctl install` write loader files into a plain directory on the
# rootfs, then we'd write entries that go nowhere, and the disk would
# boot to nothing. Fail fast with clear diagnostics.
if ! findmnt -no FSTYPE /boot/efi >/dev/null 2>&1; then
    echo "ERROR: /boot/efi is not mounted — cannot install systemd-boot."
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
echo "  /boot/efi is mounted (vfat) — proceeding with systemd-boot install"

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

# Two-stage install — first try without efivar registration (works in
# chroot / QEMU without RW efivarfs), fall back to default if that
# rejects. If BOTH fail, that's a hard error; without bootctl install,
# /boot/efi/EFI/systemd/systemd-bootaa64.efi won't be on the ESP and
# anything we write under loader/ goes nowhere.
if ! bootctl install --esp-path=/boot/efi --no-variables 2>&1; then
    echo "  --no-variables install failed; retrying with efivar reg"
    if ! bootctl install --esp-path=/boot/efi 2>&1; then
        echo "ERROR: both bootctl install attempts failed."
        echo "  Check /boot/efi mount + writability + /sys/firmware/efi/efivars."
        exit 1
    fi
fi
# Verify the systemd-boot binary actually landed on the ESP
if [ ! -f /boot/efi/EFI/systemd/systemd-bootaa64.efi ]; then
    echo "ERROR: bootctl install reported success but"
    echo "       /boot/efi/EFI/systemd/systemd-bootaa64.efi is missing."
    ls -la /boot/efi/EFI/ 2>&1 | head -10 || true
    exit 1
fi
echo "  systemd-bootaa64.efi present on ESP"

# 2026-05-08 take22 (per .66 take21 install: target booted into UEFI menu,
# manual boot-from-drive fell back to UEFI menu — firmware found no
# bootable EFI binary at the default fallback path):
#
# Cix Sky1 / MS-R1 firmware (and most arm64 UEFI firmwares) WILL boot
# from the well-known fallback path EFI/BOOT/BOOTAA64.EFI without
# needing an NVRAM EFI variable entry. `bootctl install --no-variables`
# (which we use to avoid efivar write issues in d-i chroot) does NOT
# write that fallback. We must copy it explicitly.
#
# Without this copy, install completes cleanly but the firmware sees
# no bootable target → returns to the UEFI menu after every "boot from
# drive" attempt.
install -d -m 0755 /boot/efi/EFI/BOOT
cp /boot/efi/EFI/systemd/systemd-bootaa64.efi /boot/efi/EFI/BOOT/BOOTAA64.EFI
if [ ! -f /boot/efi/EFI/BOOT/BOOTAA64.EFI ]; then
    echo "ERROR: failed to install firmware fallback EFI/BOOT/BOOTAA64.EFI"
    exit 1
fi
echo "  EFI/BOOT/BOOTAA64.EFI fallback installed (firmware-default path)"

# ----------------------------------------------------------------------
# loader.conf
# ----------------------------------------------------------------------
mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/loader.conf <<'EOF'
default cixmini-stable
timeout 5
console-mode auto
editor yes
EOF

# ----------------------------------------------------------------------
# Discover root partition by PARTUUID
# ----------------------------------------------------------------------
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
echo "  root PARTUUID=$ROOT_PARTUUID"

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
# LTS keeps efi=noruntime (r74 ship stability; original MS-R1 EFI
# runtime quirk worked around by disabling it). NEXT drops it because
# systemd-bless-boot requires EFI runtime variables (LoaderBootCountPath)
# to mark a successful boot as good — without that, repeated successful
# NEXT boots burn the +N-M counter to .failed and roll back to LTS.
# linux-cix-sky1-next 7.0.x has newer EFI handling than the 6.6 fork
# the noruntime workaround was originally added for; defaulting to
# runtime-enabled on NEXT lets the auto-rollback semantics actually
# work as designed.
LTS_CMDLINE_BASE="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"
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
NEXT_CMDLINE_BASE="loglevel=7 earlycon=efifb console=tty0 console=ttyAMA2,115200 acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"

# Optional Plymouth splash flags (if 60-plymouth.sh ran)
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"

# ----------------------------------------------------------------------
# WIPE STALE ESP STATE immediately before writing fresh entries + kernels.
#
# This broad clear is intentional, but only after the fail-closed preflight
# has proven /boot/efi is the vfat ESP, bootctl exists, and at least one
# declared kernel has a complete kernel+initrd payload ready to restage.
# ----------------------------------------------------------------------
echo "  wiping stale ESP entries + kernel images..."
rm -f /boot/efi/loader/entries/*
rm -f /boot/efi/vmlinuz-*
rm -f /boot/efi/initrd.img-*
rm -rf /boot/efi/[0-9a-f]*  # Wipe 32-hex kernel-install machine-id dirs
rm -f /boot/efi/EFI/Linux/* 2>/dev/null
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

# ----------------------------------------------------------------------
# Entry 1 — cixmini-stable.conf (DEFAULT, production-stable, only if LTS available)
# ----------------------------------------------------------------------
if [ "$LTS_AVAILABLE" = "1" ]; then
    LTS_OPTIONS="$ROOT_OPTS $LTS_CMDLINE_BASE"
    [ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"

    # sort-key forces menu-order (systemd-boot 252+).
    # Order (26.6-take1): stable/LTS (6.18) first/default, edge (7.x)
    # second/BETA, rescue last.
    cat > /boot/efi/loader/entries/cixmini-stable.conf <<EOF
title   NCZ kernel $KVER_LTS [LTS 6.18, stable fallback] — $BUILD_VERSION
sort-key 1-stable
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $LTS_OPTIONS
EOF
    if [ "$LTS_INITRD_AVAILABLE" = "1" ]; then
        # Insert initrd line after "linux" — required for NPU SSDT override
        sed -i "/^linux /a initrd  /initrd.img-$KVER_LTS" /boot/efi/loader/entries/cixmini-stable.conf
        echo "  added initrd line to cixmini-stable.conf"
    fi
    echo "  wrote cixmini-stable.conf (sort-key 1-stable, stable fallback)"
else
    echo "  skipping cixmini-stable.conf (LTS kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 2 — cixmini-edge+3-0.conf ([BETA] — only if edge kernel was installed)
#
# Title is intentionally LOUD with [BETA] markers so the user cannot
# misclick this in the boot menu thinking it's the stable choice.
# Per Sky1-Linux issue #12 (MartJohnson 2026-04-30): kernel 7.0.1 boots
# on MS-R1 but has known SCMI transition errors and occasional boot
# freezes / shutdown crashes — the BIOS doesn't have the SCMI updates
# 7.0 expects yet. 6.18.26 LTS does NOT have these issues. This BETA
# entry is for A/B testing only; production users should pick LTS.
# ----------------------------------------------------------------------
if [ "$NEXT_AVAILABLE" = "1" ]; then
    # NEXT uses NEXT_CMDLINE_BASE (no efi=noruntime) so systemd-bless-boot
    # can write LoaderBootCountPath EFI variable to mark a successful
    # boot as good. Without this, the +3-0 boot-counter burns down to
    # .failed even on healthy NEXT boots — defeating the rollback design.
    NEXT_OPTIONS="$ROOT_OPTS $NEXT_CMDLINE_BASE"
    [ -n "$SPLASH" ] && NEXT_OPTIONS="$NEXT_OPTIONS $SPLASH"

    # r75 K3 v2: filename uses systemd-boot boot-counting suffix +3-0
    # (3 tries left, 0 successful boots). systemd-bless-boot.service
    # decrements tries at boot; on a successful userspace handoff it
    # writes back +N-(M+1). After 3 failed boots the file is renamed
    # .failed and systemd-boot falls back to cixmini-stable (sort-key 1-stable).
    # Closes the Codex finding "NEXT default without rollback".
    cat > /boot/efi/loader/entries/cixmini-edge+3-0.conf <<EOF
title   *** [edge — DEFAULT] NCZ kernel $KVER_NEXT [NEXT, 3-try rollback] — $BUILD_VERSION ***
sort-key 2-edge
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $NEXT_OPTIONS
EOF
    if [ "$NEXT_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$KVER_NEXT" /boot/efi/loader/entries/cixmini-edge+3-0.conf
        echo "  added initrd line to cixmini-edge+3-0.conf"
    fi
    # r75 Codex round-4 HIGH fix — drop the systemctl enable+is-enabled
    # gate. Codex round-3 added the gate to close "bless-boot best-effort"
    # but the gate itself was over-aggressive: systemd-bless-boot.service
    # is generator-pulled via boot-counted entries (per systemd docs;
    # systemd-boot-system-token.service + systemd-bless-boot.service are
    # both static units pulled implicitly when +N-M.conf entries exist).
    # `systemctl list-unit-files` may not show generator-pulled static
    # units in all systemd configurations, and `systemctl enable` of a
    # static unit fails non-zero — both made the gate falsely flip every
    # NEXT-default install to LTS.
    #
    # New approach: write the boot-counted entry. Trust the generator.
    # The `efi=noruntime` cmdline does NOT prevent boot-counting because
    # systemd-bless-boot uses ESP filename rename (not EFI variables) per
    # https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/ — so this is safe on
    # the MS-R1 even with EFI runtime disabled.
    #
    # If a future deploy proves boot-counting non-functional on Sky1,
    # the runtime fix is `ncz desktop status`-style operator tooling
    # rather than gating at install time.
    if systemctl list-unit-files systemd-bless-boot.service systemd-boot-check-no-failures.service 2>/dev/null | grep -q "^systemd-bless"; then
        echo "  systemd-bless-boot.service is in unit-files set — generator path active"
    else
        echo "  systemd-bless-boot.service not in list-unit-files (likely generator-pulled at boot — typical) — proceeding"
    fi
    echo "  wrote cixmini-edge+3-0.conf (sort-key 2-edge, default when present, 3-try rollback to stable)"
else
    echo "  skipping cixmini-edge.conf (BETA kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 3 — cixmini-rescue.conf (FULLY SAFE rescue shell on LTS kernel)
#
# rescue.target boots multi-user services down (no graphical, no
# auto-mount of network FS) but leaves the system bootable + login-able
# for recovery. Useful when default cixmini-stable.conf wedges from a bad
# config + we need to roll something back.
#
# "FULLY SAFE" (operator requirement 2026-06-01): the rescue entry must
# reach a login shell + network even if every accelerator is flaky. So
# beyond rescue.target we DISABLE all the heavy/optional silicon:
#   - NPU  : armchina_npu (Zhouyi Z2/Compass)
#   - GPU  : panthor + mali + bifrost (Arm Mali on Sky1)
#   - VPU  : cix_vpu + linlon_vpu (Arm Linlon video codec)
# These are MERGED into the existing typec_rts5453 blacklist (the MS-R1
# IRQ-151 wedge) so there is a single module_blacklist= token (the
# kernel keeps only the last one it parses). Blacklisting a module that
# isn't present is harmless.
#
# We DELIBERATELY DO NOT add `nomodeset`: on Sky1 the only console is
# efifb/simplefb handed over by firmware, and nomodeset can kill it →
# black screen, the exact failure rescue must avoid (GRAEAE consult
# 52f790d1, 2026-06-01). We KEEP arm-smmu-v3.disable_bypass=0 so NVMe +
# RTL8125 NIC DMA still work in rescue (without it the SMMU blocks
# device DMA → no disk, no network).
# ----------------------------------------------------------------------
# Rescue uses LTS by preference, falls back to NEXT if LTS missing.
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

if [ -n "$RESCUE_KVER" ]; then
    # 3-kernel layout (operator requirement 2026-06-01): the rescue/clean
    # kernel is a PHYSICALLY INDEPENDENT copy of the proven BSP binary,
    # staged under -rescue filenames. Same 6.18.26 BSP bits as the daily
    # LTS today, but a separate file/inode — so a future daily-LTS kernel
    # swap can never touch the known-good recovery kernel. The wipe step
    # above already cleared stale vmlinuz-*; we recreate the pin fresh from
    # the LTS binary we just staged to the ESP.
    RESCUE_PIN="${RESCUE_KVER}-rescue"
    # Refuse to pin a zero-byte kernel (Codex 26.6 HIGH): the LTS/NEXT
    # staging above uses -f not -s, so a truncated bake could leave an empty
    # /boot/efi/vmlinuz-$RESCUE_KVER. Pinning that would hand the operator a
    # rescue entry that loads nothing — the exact unbootable state rescue
    # exists to prevent.
    if [ ! -s "/boot/efi/vmlinuz-$RESCUE_KVER" ]; then
        echo "ERROR: /boot/efi/vmlinuz-$RESCUE_KVER is missing or empty — cannot pin a clean rescue kernel."
        exit 1
    fi
    install -m 0644 "/boot/efi/vmlinuz-$RESCUE_KVER" "/boot/efi/vmlinuz-$RESCUE_PIN"
    echo "  staged pinned clean/rescue kernel /boot/efi/vmlinuz-$RESCUE_PIN"
    RESCUE_HAS_INITRD=0
    if { [ "$RESCUE_KVER" = "$KVER_LTS" ] && [ "$LTS_INITRD_AVAILABLE" = "1" ]; } || \
       { [ "$RESCUE_KVER" = "$KVER_NEXT" ] && [ "$NEXT_INITRD_AVAILABLE" = "1" ]; }; then
        install -m 0644 "/boot/efi/initrd.img-$RESCUE_KVER" "/boot/efi/initrd.img-$RESCUE_PIN"
        echo "  staged pinned clean/rescue initrd /boot/efi/initrd.img-$RESCUE_PIN"
        RESCUE_HAS_INITRD=1
    fi

    # Modules to keep OUT of the rescue boot. Extends — never replaces —
    # the production typec_rts5453,rts5453 blacklist.
    #   GPU/NPU/VPU : armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu
    #   Display/KMS : trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display
    # The display/KMS group is the one that actually black-screened the box:
    # a KMS driver that seizes the panel from the firmware efifb/simplefb
    # console recreates the exact no-video wedge this recovery release exists
    # to prevent (Codex 26.6 review blocker 1, 2026-06-01). Rescue relies on
    # the firmware framebuffer ONLY — no KMS takeover.
    RESCUE_EXTRA_BLACKLIST="armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu,trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display"

    # Build exactly ONE canonical module_blacklist= token (Codex 26.6 review
    # blocker 3). The kernel honours only the LAST module_blacklist= it parses,
    # so a sed that merges into the first occurrence would silently drop our
    # extras if a second token ever crept into the base cmdline. Instead:
    # collect every existing module_blacklist= value, strip them all out, then
    # append a single merged token at the end. Fail-closed for 0, 1, or N
    # pre-existing tokens.
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

    cat > /boot/efi/loader/entries/cixmini-rescue.conf <<EOF
title   SAFE rescue (cixmini) — clean kernel $RESCUE_PIN rescue.target [no NPU/GPU/VPU] — $BUILD_VERSION
sort-key 3-rescue
version $RESCUE_PIN
linux   /vmlinuz-$RESCUE_PIN
options $RESCUE_OPTIONS
EOF
    # Rescue entry uses the pinned initrd if we staged one above
    if [ "$RESCUE_HAS_INITRD" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$RESCUE_PIN" /boot/efi/loader/entries/cixmini-rescue.conf
    fi
    echo "  wrote cixmini-rescue.conf (sort-key 3-rescue, independent pinned kernel, accelerators blacklisted)"
    echo "    rescue options: $RESCUE_OPTIONS"
fi

# 26.6-r92: prefer NEXT as the default when staged, while keeping LTS
# and the independent pinned rescue entry available. cixmini-edge* is a
# glob so it follows systemd-boot boot-counter rotations (+3-0, +2-0,
# .failed handling). If NEXT is absent, LTS becomes the default.
if [ "$NEXT_AVAILABLE" = "1" ]; then
    DEFAULT_ENTRY="cixmini-edge*"
elif [ "$LTS_AVAILABLE" = "1" ]; then
    DEFAULT_ENTRY="cixmini-stable"
else
    echo "ERROR: NEITHER kernel installed — cannot set default loader entry"
    exit 1
fi
cat > /boot/efi/loader/loader.conf <<EOF
default $DEFAULT_ENTRY
timeout 5
console-mode auto
editor yes
EOF
echo "  loader.conf default = $DEFAULT_ENTRY"

# Verify the default actually resolves to a written entry. systemd-boot
# treats default as a glob; for cixmini-edge* match either the canonical
# +3-0.conf (boot-counter) or any later +N-M rotation.
if [ "$DEFAULT_ENTRY" = "cixmini-edge*" ]; then
    if ! ls /boot/efi/loader/entries/cixmini-edge*.conf >/dev/null 2>&1; then
        echo "ERROR: loader.conf default=cixmini-edge* but no cixmini-edge*.conf in entries/" >&2
        ls /boot/efi/loader/entries/ 2>&1 | sed 's/^/  /'
        exit 1
    fi
else
    if ! [ -f "/boot/efi/loader/entries/${DEFAULT_ENTRY}.conf" ]; then
        echo "ERROR: loader.conf default=$DEFAULT_ENTRY but ${DEFAULT_ENTRY}.conf not in entries/" >&2
        exit 1
    fi
fi
echo "  loader.conf default resolves to a real entry — verified"

# ----------------------------------------------------------------------
# Add a UEFI boot entry pointing at systemd-boot.
# Strip the trailing partition number off the source path
# (/dev/nvme0n1p2 → 2) — portable across the chroot's util-linux ver.
# ----------------------------------------------------------------------
EFI_DEV=$(findmnt -no SOURCE /boot/efi)
EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV")
EFI_PART="${EFI_DEV##*[!0-9]}"
efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
    -L "nclawzero" -l '\EFI\systemd\systemd-bootaa64.efi' || true

# UEFI NVRAM fallback per 2026-05-04 codex review: some UEFI implementations
# (esp. older firmware) don't persist NVRAM entries written via efibootmgr.
# Drop a copy of systemd-bootaa64.efi at the canonical removable-media fallback
# path /EFI/BOOT/BOOTAA64.EFI so the device boots even with empty BootOrder.
if [ -f /boot/efi/EFI/systemd/systemd-bootaa64.efi ]; then
    install -D -m 0644 /boot/efi/EFI/systemd/systemd-bootaa64.efi \
        /boot/efi/EFI/BOOT/BOOTAA64.EFI
    echo "  /EFI/BOOT/BOOTAA64.EFI fallback installed (NVRAM-independent boot)"
else
    echo "  WARN: /boot/efi/EFI/systemd/systemd-bootaa64.efi missing — no fallback installed"
fi

echo ""
echo "===== systemd-boot loader entries written ====="
ls -la /boot/efi/loader/entries/
echo ""
for entry in /boot/efi/loader/entries/cixmini-*.conf; do
    echo "--- $entry ---"
    cat "$entry"
    echo ""
done
echo ""
echo "bootctl status — Unknown-line warnings should be EMPTY:"
bootctl status 2>&1 | grep -E "Unknown line|without value" | head -5 || true
echo ""
echo "Final EFI boot entries:"
efibootmgr -v 2>&1 | head -10 || true
