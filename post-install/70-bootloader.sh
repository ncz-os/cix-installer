#!/bin/bash
# 70-bootloader.sh — systemd-boot install + staged kernel loader entries.
# 26.6-take1: DEFAULT flipped to LTS 6.18 (stable, all working drivers).
# 7.1 NEXT ships as an explicit, clearly-labeled [BETA] choice — its SCMI
# transport still times out on MS-R1 firmware, so it is NOT the default
# for a recovery-focused release. r78 netinstall may stage NEXT only.
#
# Loader entries (in menu order when all staged kernels exist):
#   1. cixmini-lts.conf       (DEFAULT — Sky1 linux-cix-sky1-lts 6.18.x)
#   2. cixmini-next+3-0.conf  ([BETA] — Sky1 linux-cix-sky1-next 7.1.x, 3-try rollback)
#   3. cixmini-rescue.conf    (FULLY SAFE: rescue.target on LTS, NPU/GPU/VPU blacklisted)
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

# ----------------------------------------------------------------------
# Install systemd-boot + efibootmgr
# ----------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-boot efibootmgr || true

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
# WIPE STALE ESP STATE before writing fresh entries.
#
# Every prior install accumulated loader entry .conf files and
# vmlinuz copies on the ESP. systemd-boot reads ALL *.conf files in
# /boot/efi/loader/entries/ — leftover entries from r1/r2/r3 installs
# show up alongside the new ones, defaulting to whichever has the
# lowest sort name. This caused multiple "nclawzero (cixmini)"
# entries on cixmini.66 (r6 era + earlier) and confused systemd-boot's
# default selection.
#
# Wipe everything we own here. If the user has an out-of-band entry
# they want preserved, they can re-add it after install.
echo "  wiping stale ESP entries + kernel images..."
rm -f /boot/efi/loader/entries/*.conf
rm -f /boot/efi/vmlinuz-*
# Some installs put kernels in /boot/efi/EFI/Linux/ via systemd-boot's
# automatic discovery. Wipe those too.
rm -f /boot/efi/EFI/Linux/*.efi 2>/dev/null
echo "  ESP wiped — about to write fresh dual-kernel entries"

# ----------------------------------------------------------------------
# loader.conf
# ----------------------------------------------------------------------
mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/loader.conf <<'EOF'
default cixmini-lts
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
NEXT_CMDLINE_BASE="loglevel=4 console=tty0 console=ttyAMA2,115200 acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"

# Optional Plymouth splash flags (if 60-plymouth.sh ran)
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"

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

if [ -n "$KVER_LTS" ] && [ -f "/boot/vmlinuz-$KVER_LTS" ]; then
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

if [ -n "$KVER_NEXT" ] && [ -f "/boot/vmlinuz-$KVER_NEXT" ]; then
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
# Entry 1 — cixmini-lts.conf (DEFAULT, production-stable, only if LTS available)
# ----------------------------------------------------------------------
if [ "$LTS_AVAILABLE" = "1" ]; then
    LTS_OPTIONS="$ROOT_OPTS $LTS_CMDLINE_BASE"
    [ -n "$SPLASH" ] && LTS_OPTIONS="$LTS_OPTIONS $SPLASH"

    # sort-key forces menu-order (systemd-boot 252+).
    # Order (per RULE 2026-05-03 update): NEXT (7.x) first/default,
    # LTS (6.18) second/fallback, rescue last.
    cat > /boot/efi/loader/entries/cixmini-lts.conf <<EOF
title   nclawzero (cixmini) — kernel $KVER_LTS [LTS 6.18, default] — $BUILD_VERSION
sort-key 1-lts
version $KVER_LTS
linux   /vmlinuz-$KVER_LTS
options $LTS_OPTIONS
EOF
    if [ "$LTS_INITRD_AVAILABLE" = "1" ]; then
        # Insert initrd line after "linux" — required for NPU SSDT override
        sed -i "/^linux /a initrd  /initrd.img-$KVER_LTS" /boot/efi/loader/entries/cixmini-lts.conf
        echo "  added initrd line to cixmini-lts.conf"
    fi
    echo "  wrote cixmini-lts.conf (sort-key 1-lts, default)"
else
    echo "  skipping cixmini-lts.conf (LTS kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 2 — cixmini-next.conf ([BETA] — only if NEXT kernel was installed)
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
    # .failed and systemd-boot falls back to cixmini-lts (sort-key 2-lts).
    # Closes the Codex finding "NEXT default without rollback".
    cat > /boot/efi/loader/entries/cixmini-next+3-0.conf <<EOF
title   *** [BETA — UNSTABLE SCMI] nclawzero kernel $KVER_NEXT [NEXT 7.1, A/B only] — $BUILD_VERSION ***
sort-key 2-next
version $KVER_NEXT
linux   /vmlinuz-$KVER_NEXT
options $NEXT_OPTIONS
EOF
    if [ "$NEXT_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$KVER_NEXT" /boot/efi/loader/entries/cixmini-next+3-0.conf
        echo "  added initrd line to cixmini-next+3-0.conf"
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
    echo "  wrote cixmini-next+3-0.conf (sort-key 2-next, BETA, 3-try rollback to LTS)"
else
    echo "  skipping cixmini-next.conf (BETA kernel not installed)"
fi

# ----------------------------------------------------------------------
# Entry 3 — cixmini-rescue.conf (FULLY SAFE rescue shell on LTS kernel)
#
# rescue.target boots multi-user services down (no graphical, no
# auto-mount of network FS) but leaves the system bootable + login-able
# for recovery. Useful when default cixmini-lts.conf wedges from a bad
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
title   SAFE rescue (cixmini) — kernel $RESCUE_KVER rescue.target [no NPU/GPU/VPU] — $BUILD_VERSION
sort-key 3-rescue
version $RESCUE_KVER
linux   /vmlinuz-$RESCUE_KVER
options $RESCUE_OPTIONS
EOF
    # Rescue entry uses initrd if available for the chosen kernel
    if [ "$RESCUE_KVER" = "$KVER_LTS" ] && [ "$LTS_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$RESCUE_KVER" /boot/efi/loader/entries/cixmini-rescue.conf
    elif [ "$RESCUE_KVER" = "$KVER_NEXT" ] && [ "$NEXT_INITRD_AVAILABLE" = "1" ]; then
        sed -i "/^linux /a initrd  /initrd.img-$RESCUE_KVER" /boot/efi/loader/entries/cixmini-rescue.conf
    fi
    echo "  wrote cixmini-rescue.conf (sort-key 3-rescue, accelerators blacklisted)"
    echo "    rescue options: $RESCUE_OPTIONS"
fi

# 26.6-take1: prefer LTS 6.18 as default (stable, all working drivers).
# 7.1 NEXT is shipped as an explicit [BETA] choice only — its SCMI
# transport still times out on MS-R1 firmware, so making it the default
# (even with boot-counting rollback) risks the exact black-screen wedge
# this recovery release exists to avoid. LTS is only NOT default when it
# wasn't staged at all (e.g. a NEXT-only netinstall image), in which case
# NEXT becomes default and its 3-try rollback is the safety net.
if [ "$LTS_AVAILABLE" = "1" ]; then
    DEFAULT_ENTRY="cixmini-lts"
elif [ "$NEXT_AVAILABLE" = "1" ]; then
    # cixmini-next* glob matches the +N-M.conf boot-counter rotations
    # written by systemd-bless-boot. Per Codex round-4: trust the
    # systemd generator; do not gate this on systemctl enable success.
    #
    # 26.6-take1 (Codex review blocker 2, 2026-06-01): reaching here in a
    # recovery release is a STAGING REGRESSION — LTS 6.18 should always be
    # present per the dual-kernel rule. We deliberately do NOT hard-fail
    # (a bootloader hook that exits non-zero writes no loader entries =
    # an unbootable box, which violates "there must always be a boot/rescue
    # choice"). Instead: scream loudly in the install log, and rely on the
    # NEXT +3-0 boot-counter to auto-roll-back if 7.1 wedges. The rescue
    # entry (which also falls back to NEXT) remains selectable by hand.
    echo "##############################################################"
    echo "## WARNING: LTS 6.18 kernel NOT staged — defaulting to 7.1   ##"
    echo "## NEXT [BETA]. This is a STAGING REGRESSION for a recovery  ##"
    echo "## release: LTS should always be present (dual-kernel rule). ##"
    echo "## Safety net: NEXT default has 3-try boot-count rollback;   ##"
    echo "## the SAFE rescue entry is still available at the menu.     ##"
    echo "##############################################################"
    DEFAULT_ENTRY="cixmini-next*"
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
# treats default as a glob; for cixmini-next* match either the canonical
# +3-0.conf (boot-counter) or any later +N-M rotation.
if [ "$DEFAULT_ENTRY" = "cixmini-next*" ]; then
    if ! ls /boot/efi/loader/entries/cixmini-next*.conf >/dev/null 2>&1; then
        echo "ERROR: loader.conf default=cixmini-next* but no cixmini-next*.conf in entries/" >&2
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
