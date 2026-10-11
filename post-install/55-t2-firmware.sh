#!/bin/bash
# 55-t2-firmware.sh — Apple T2 hardware: real WiFi/Bluetooth firmware +
# audio config, from AdityaGarg8's real, verified t2-ubuntu-repo apt repo.
#
# Same posture as 53-chrome.sh / 54-gpu-accel.sh (operator directive
# 2026-09-14: "We are not a free only distro like Debian, we install to
# make things work.") — real official repo, real signed packages.
#
# Real repo verified 2026-09-14 (curl, not guessed): KEY.gpg and t2.list at
# adityagarg8.github.io/t2-ubuntu-repo both return HTTP 200 with real
# content. Debian 13 (trixie) is an explicitly listed supported codename.
#
# IMPORTANT — do NOT install this repo's kernel driver packages here.
# Our own v7.2.6+T2 kernel (built 2026-09-14, t2linux's linux-t2-patches
# applied) already carries apple-bce/applesmc/HID/APFS support IN-TREE —
# the repo's own README explicitly warns apple-bce, apple-touchbar,
# applesmc-t2, apfs-dkms and bcm5974-t2 must NOT be installed alongside a
# linux-t2-class kernel (driver conflict). Only two packages are actually
# needed here:
#   - apple-firmware-script  — WiFi/BT firmware (the actual operator ask
#     tonight: "T2 needs Apple firmware blobs")
#   - apple-t2-audio-config  — audio config for the apple-bce audio device
#
# FIRMWARE SOURCE (2026-09-22, real fix, replaces the runtime-fetch
# approach below): the real WiFi/BT firmware blobs are pre-extracted ONCE
# at build time and shipped as a static asset
# (assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz, staged into
# base.squashfs by build-squashfs-layers.sh's existing `assets/firmware`
# copy loop) — NOT fetched from Apple's CDN at every real install.
#
# Why: get-apple-firmware's `get_from_online` path downloads a full ~753MB
# macOS Sonoma Recovery Image just to extract ~3.6MB of real firmware
# (confirmed live on MEDUSA, 2026-09-22) — a >99% waste ratio repeated on
# EVERY T2 install. The extracted set (128 files: brcmfmac4355c1/4364b2/
# 4364b3/4377b3 board variants) covers all real T2-era Mac WiFi chips, not
# just MEDUSA's specific model — Apple ships every board's firmware in the
# same Recovery Image bundle, we just extracted the whole set once.
#
# CAVEAT: if a future T2 Mac model needs a chip variant NOT covered by this
# Sonoma-14 extraction (Apple occasionally adds new boards in later macOS
# releases), the online fallback below still exists for that case.
#
# RUNS AT REAL INSTALL TIME ON THE TARGET MACHINE (same class of hook as
# 54-gpu-accel.sh — T2 hardware detection is target-specific, not
# meaningfully baked into a shared image at chroot-build time).
# AMD64 only — never wired into the arm64 hook loops.
#
# UPDATED 2026-09-15 (operator follow-up): the T2 PCI-bridge check that used
# to live inline here moved to the shared, unit-testable
# post-install/lib/hw-detect.sh (`is_t2_hardware` / `t2_hardware_detail`) so
# it isn't a copy-paste-only fact living in one hook. Detection itself is
# unchanged (same [106b:1801] signature, verified 2026-09-14 in t2linux's
# own patch) and now ALSO verified against REAL T2 hardware 2026-09-15
# (read-only oracle check on MEDUSA, a real MacBookPro16,1 — see
# hw-detect.sh's header for the exact lspci/DMI output). A DMI fallback was
# added for when lspci itself is unavailable — this is a strict addition,
# not a behavior change, since the old code skipped ALL T2 work whenever
# lspci was missing regardless of real hardware.
#
# This hook ALSO now unconditionally logs "T2 hardware: detected/not
# detected" on every amd64 run (before the headless/server variant check),
# per operator directive: the diagnostic should be visible in install logs
# whether or not it ends up mattering for this SKU.
# NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not amd64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set +e

if [ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]; then
    echo "[55] not an amd64 target — skipping (this hook is AMD64-only)"
    exit 0
fi

echo "[55] Apple T2 hardware detection + firmware wiring"

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=post-install/lib/hw-detect.sh
. "$HOOK_LIB_DIR/hw-detect.sh"

# --- diagnostic: always logged on amd64, regardless of variant/gating ----
if is_t2_hardware; then
    echo "[55] T2 hardware: detected ($(t2_hardware_detail))"
else
    echo "[55] T2 hardware: not detected ($(t2_hardware_detail))"
fi

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[55] BUILD_VARIANT=$VARIANT — headless SKU; skipping T2 firmware"
        exit 0
        ;;
esac

if ! is_t2_hardware; then
    echo "[55] not T2 hardware — nothing to wire, skipping firmware install"
    exit 0
fi

echo "[55] Apple T2 hardware confirmed — wiring real t2-ubuntu-repo apt source"

# --- T2 boot-noise quirks (modprobe.d) -------------------------------------
# Written here, immediately after T2 is confirmed and BEFORE any apt/CDN step,
# so a later network failure cannot skip them (this hook exits early on those).
# These remove two recurring error-level boot-log lines at their root cause on
# T2 Macs; both are benign-but-noisy and are fixed by not loading/announcing
# something the hardware cannot do.
#
# (1) brcmfmac P2P: the BCM4364 firmware rejects the "p2p_da_override" iovar
#     with -EBADE (-52), so creating the P2P Device interface always fails and
#     logs three error lines every boot:
#       brcmf_p2p_set_firmware: failed to update device address ret -52
#       brcmf_p2p_create_p2pdev: set p2p_disc error
#       brcmf_cfg80211_add_iface: add iface p2p-dev-wlan0 ... err=-52
#     Wi-Fi Direct is unusable on this firmware, so clear the P2P feature and
#     never advertise the interface; wpa_supplicant/NM then stop trying.
#     feature_disable is a bitmask indexed by enum brcmf_feat_id (see
#     drivers/net/wireless/broadcom/brcm80211/brcmfmac/feature.h): MBSS=0,
#     MCHAN=1, PNO=2, WOWL=3, P2P=4 -> 0x10. If upstream ever reorders the
#     enum this bit must be re-derive; the debugfs "features" list shows it.
install -d -m0755 /etc/modprobe.d
cat > /etc/modprobe.d/ncz-t2-brcmfmac-p2p.conf <<'MODEOF'
# T2 (BCM4364): the firmware has no working P2P; do not advertise a P2P Device
# interface, so userspace stops trying and logging -52. Bit 4 = BRCMF_FEAT_P2P.
options brcmfmac feature_disable=0x10
MODEOF
echo "  [55] brcmfmac P2P disabled (T2 firmware rejects p2p_da_override, -52)"

# (2) pcspkr / snd_pcsp duplicate platform-driver registration: both modules
#     register a platform driver named "pcspkr" and carry
#     MODULE_ALIAS("platform:pcspkr"), so udev autoloads BOTH for the single PC
#     Speaker platform device. Whichever loses the race fails its probe with:
#       Error: Driver 'pcspkr' is already registered, aborting...
#     (the loser's module init returns the error, so it is not even listed in
#     lsmod). Blacklist the ALSA one; the input pcspkr driver keeps the terminal
#     bell working and the error line disappears.
cat > /etc/modprobe.d/ncz-t2-pcspkr.conf <<'MODEOF'
# pcspkr (input) and snd_pcsp (ALSA) both register platform driver "pcspkr"
# (MODULE_ALIAS platform:pcspkr) -> duplicate-registration error every boot.
# Keep the input driver; block the ALSA one.
blacklist snd_pcsp
install snd_pcsp /bin/true
MODEOF
echo "  [55] snd_pcsp blacklisted (duplicate 'pcspkr' platform-driver registration)"

install -d -m0755 /etc/apt/trusted.gpg.d
T2_KEYRING=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg
if [ ! -f "$T2_KEYRING" ] || [ ! -s "$T2_KEYRING" ]; then
    rm -f "$T2_KEYRING"
    # Same key-material validation discipline as 54-gpu-accel.sh's AMD/Intel
    # blocks — don't trust a bare curl exit code, confirm real key bytes.
    if curl -fsSL --compressed --connect-timeout 5 --max-time 30 "https://adityagarg8.github.io/t2-ubuntu-repo/KEY.gpg" 2>/dev/null | gpg --dearmor -o "$T2_KEYRING" 2>/dev/null && \
       [ -s "$T2_KEYRING" ] && [ "$(stat -c%s "$T2_KEYRING" 2>/dev/null || echo 0)" -gt 100 ]; then
        echo "[55] fetched t2-ubuntu-repo signing key ($(stat -c%s "$T2_KEYRING") bytes)"
    else
        rm -f "$T2_KEYRING"
        echo "[55] WARN: could not fetch a real t2-ubuntu-repo KEY.gpg (no network at install time, or key content invalid) — skipping T2 firmware stack"
        exit 0
    fi
fi

# Common repo (covers apple-firmware-script + apple-t2-audio-config —
# neither needs the release-specific repo, which is only for kernel
# packages/tiny-dfr that we deliberately do NOT install here).
cat > /etc/apt/sources.list.d/t2.list <<'EOF'
# Written by post-install/55-t2-firmware.sh — real AdityaGarg8 t2-ubuntu-repo.
deb [signed-by=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg] https://adityagarg8.github.io/t2-ubuntu-repo ./
EOF

apt-get update 2>&1 | tail -5
# BEGIN t2-pkg-status
apt-get install -y apple-firmware-script apple-t2-audio-config 2>&1 | tail -10
_t2_rc=${PIPESTATUS[0]}
# `| tail` hid the status; check the apt rc AND that each package really landed (r201 review).
T2_PKG_FAIL=0
for _p in apple-firmware-script apple-t2-audio-config; do
    case "$(dpkg-query -W -f='${Status}' "$_p" 2>/dev/null)" in
        *"install ok installed"*) ;;
        *) echo "[55] ERROR: $_p is not installed (apt-get rc=$_t2_rc)" >&2; T2_PKG_FAIL=1 ;;
    esac
done
# END t2-pkg-status

# --- Real Apple WiFi/BT firmware: extract from the staged build-time asset
# (fast, offline, no Apple CDN hit) instead of fetching per-install. ------
STAGED_FW_TARBALL=/usr/local/lib/cix-installer/assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz
if [ -f "$STAGED_FW_TARBALL" ]; then
    echo "[55] extracting staged Apple T2 firmware ($(du -h "$STAGED_FW_TARBALL" | cut -f1)) into /lib/firmware/brcm/"
    mkdir -p /lib/firmware/brcm
    tar -xJf "$STAGED_FW_TARBALL" -C /lib/firmware/brcm
else
    echo "[55] WARN: staged firmware tarball missing ($STAGED_FW_TARBALL) — falling back to a real per-install Apple CDN fetch"
    if ! dpkg-query -W -f='${Status}\n' dmg2img 2>/dev/null | grep -q "install ok installed"; then
        apt-get install -y dmg2img 2>&1 | tail -10
        [ "${PIPESTATUS[0]}" -eq 0 ] || echo "[55] WARN: apt-get install dmg2img failed (rc=${PIPESTATUS[0]})" >&2
    fi
    if ! command -v dmg2img >/dev/null 2>&1; then
        echo "[55] WARN: dmg2img still missing after install attempt -- skipping get-apple-firmware fallback (would hit its own internal dependency prompt and corrupt the piped macOS-version answer below)"
    elif command -v get-apple-firmware >/dev/null 2>&1; then
        echo "[55] running get-apple-firmware get_from_online fallback (downloads a real macOS Recovery Image from Apple's CDN and extracts firmware from it -- ~753MB, only happens because the staged asset above was missing)"
        # Pass the subcommand directly to skip the interactive
        # "How do you want to copy the firmware to Linux?" menu (see
        # `get-apple-firmware -h`). It still has one inner interactive
        # prompt (which macOS version's Recovery Image to fetch) --
        # Sonoma is the tool's own "RECOMMENDED" choice, option 7 as of
        # apple-firmware-script 1.4-3 (re-verify this number if the
        # tool's menu ever reorders/adds entries).
        echo 7 | get-apple-firmware get_from_online 2>&1 | tail -30
    else
        echo "[55] WARN: apple-firmware-script installed but get-apple-firmware not on PATH — check package contents"
    fi
fi

# NOTE: a bare `brcmfmac*.bin` glob is NOT sufficient here -- the
# firmware-brcm80211 package (already in the amd64 manifests, a generic
# non-Apple Broadcom firmware set) can populate /lib/firmware/brcm/ with
# its OWN brcmfmac*.bin files independent of this hook, so that check
# would report success even when firmware staging/extraction failed.
# Apple's board-specific files are always named
# `<chip>-pcie.apple,<boardname>.bin` -- require that exact pattern.
if ls /lib/firmware/brcm/brcmfmac*.apple,*.bin >/dev/null 2>&1; then
    echo "[55] Apple WiFi/BT firmware present in /lib/firmware/brcm/ ($(ls /lib/firmware/brcm/brcmfmac*.apple,*.bin | wc -l) board file(s))"
else
    echo "[55] WARN: no Apple-specific brcmfmac*.apple,*.bin firmware appeared in /lib/firmware/brcm/ -- check the tail above for the real failure"
fi

# --- Bluetooth firmware verification (chip-class aware) --------------------
# The Wi-Fi check above intentionally says nothing about Bluetooth. Per the
# t2linux wiki (Device Support / state), Bluetooth on T2 Macs needs macOS
# firmware *only* on devices whose combo chip is a BCM4377 (PCIe driver
# hci_bcm4377; files brcmbt<chip>-apple,<board>.bin + .ptb). Those are exactly
# MacBookPro15,4 / MacBookPro16,3 / MacBookAir9,1.
#
# Every other T2 Mac (e.g. MacBookPro16,1) has a UART Broadcom chip --
# BCM4364B3 here -- driven by hci_uart + btbcm. Because mainline btbcm has no
# LMP-subver entry for this chip and no Open Firmware board name exists on
# x86/ACPI, the kernel's only candidate is the generic "brcm/BCM.hcd", which
# does not exist and cannot be shipped (Apple's patchram is not
# redistributable). Those machines run on ROM firmware and the boot line
#   "Bluetooth: hci0: BCM: firmware Patch file not found, tried: 'brcm/BCM.hcd'"
# is expected, not a staging failure. Reporting it as if it were a fixable gap
# is the defect this block removes.
#
# See amd64-kernel-t2 docs/T2-BLUETOOTH-FIRMWARE.md for the full analysis, and
# that repo's patches/9002 for the ROM-firmware advertising workaround this
# kernel already carries.
T2_BT_FW_MODELS="MacBookPro15,4 MacBookPro16,3 MacBookAir9,1"
t2_model="$(cat /sys/class/dmi/id/product_name 2>/dev/null \
    || dmidecode -s system-product-name 2>/dev/null)"
case " ${T2_BT_FW_MODELS} " in
    *" ${t2_model} "*)
        if ls /lib/firmware/brcm/brcmbt*.bin >/dev/null 2>&1; then
            echo "[55] Apple Bluetooth firmware present (BCM4377-class ${t2_model}; $(ls /lib/firmware/brcm/brcmbt*.bin 2>/dev/null | wc -l) file(s))"
        else
            echo "[55] WARN: ${t2_model} needs BCM4377 Bluetooth firmware but no brcmbt*.bin appeared in /lib/firmware/brcm/ -- check the tail above"
        fi
        ;;
    *)
        if [ -e /lib/firmware/brcm/BCM.hcd ]; then
            echo "[55] Bluetooth: user-supplied brcm/BCM.hcd present for UART chip on ${t2_model:-unknown model}"
        else
            echo "[55] Bluetooth: ${t2_model:-this T2 model} uses a UART Broadcom chip on ROM firmware; brcm/BCM.hcd is intentionally absent (no redistributable patchram; see amd64-kernel-t2 docs/T2-BLUETOOTH-FIRMWARE.md)"
        fi
        ;;
esac

if [ "$T2_PKG_FAIL" = 1 ]; then
    echo "[55] FAILED: the T2 audio/firmware packages did not install" >&2
    exit 1
fi
echo "[55] T2 firmware wiring done"
