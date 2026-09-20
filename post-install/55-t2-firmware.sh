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
# CAVEAT, stated plainly rather than glossed over: apple-firmware-script's
# get-apple-firmware (wiki.t2linux.org/tools/firmware.sh, Asahi-derived
# Python tooling) fetches real macOS firmware packages from Apple's own CDN
# based on the detected Mac model at RUN TIME — this is a genuine network
# fetch to Apple's own servers, not a static offline blob, and has NOT been
# tested against real T2 hardware in this pass (no T2 machine was available
# to verify). If it fails or needs interaction on real hardware, that is a
# real follow-on to fix with MEDUSA once it's repurposed as the T2
# boot-validation target — this hook installs the tool and calls it
# non-interactively; verify the actual result on real hardware before
# trusting this blindly.
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

install -d -m0755 /etc/apt/trusted.gpg.d
T2_KEYRING=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg
if [ ! -f "$T2_KEYRING" ] || [ ! -s "$T2_KEYRING" ]; then
    rm -f "$T2_KEYRING"
    # Same key-material validation discipline as 54-gpu-accel.sh's AMD/Intel
    # blocks — don't trust a bare curl exit code, confirm real key bytes.
    if curl -fsSL --compressed "https://adityagarg8.github.io/t2-ubuntu-repo/KEY.gpg" 2>/dev/null | gpg --dearmor -o "$T2_KEYRING" 2>/dev/null && \
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
apt-get install -y apple-firmware-script apple-t2-audio-config 2>&1 | tail -10

# get-apple-firmware's `get_from_online` path (Recovery Image download,
# extracted with dmg2img) is not a hard dependency of the apple-firmware-script
# package -- confirmed missing on a real install (MEDUSA, 2026-09-20). Without
# it, the tool prints "dmg2img and/or its dependencies are missing!" and does
# nothing further; install it explicitly here rather than relying on it being
# pulled in as a Recommends this offline-mirror build may strip.
if ! dpkg-query -W -f='${Status}\n' dmg2img 2>/dev/null | grep -q "install ok installed"; then
    apt-get install -y dmg2img 2>&1 | tail -10
fi

# get-apple-firmware's OWN internal dependency check (`dmg2img >/dev/null
# 2>&1 || install_package dmg2img`) triggers its own install-and-prompt flow
# if dmg2img isn't actually runnable -- and that flow consumes stdin too,
# which would eat the macOS-version answer piped in below and corrupt BOTH
# prompts silently. Verify dmg2img is real and runnable before proceeding,
# rather than assuming the apt-get above succeeded.
if ! command -v dmg2img >/dev/null 2>&1; then
    echo "[55] WARN: dmg2img still missing after install attempt -- skipping get-apple-firmware (would hit its own internal dependency prompt and corrupt the piped macOS-version answer below)"
elif command -v get-apple-firmware >/dev/null 2>&1; then
    echo "[55] running get-apple-firmware get_from_online (downloads a real macOS Recovery Image from Apple's CDN and extracts firmware from it)"
    # PREVIOUSLY (and WRONG, metal-confirmed on MEDUSA 2026-09-20): calling
    # `get-apple-firmware < /dev/null` with no subcommand hits its interactive
    # "How do you want to copy the firmware to Linux?" menu; reading the
    # closed stdin returns immediate EOF, so `read -r choice` gets an empty
    # string, falls into the `(*) Error: Invalid option! exit 1` branch --
    # except this whole invocation is piped through `tail -20`, and the
    # script's own `echo "[55] T2 firmware wiring done"` runs unconditionally
    # right after regardless of that exit code, so the failure was completely
    # silent in every install log. Zero firmware files were ever written.
    #
    # THE FIX: pass the subcommand directly (documented via `get-apple-firmware
    # -h`) to skip that menu entirely. `get_from_online` needs no prior macOS
    # or EFI-partition staging -- a pure network fetch, matching what this
    # hook's own header already describes. It still has ONE inner interactive
    # prompt (which macOS version's Recovery Image to fetch); feed it the
    # tool's own "RECOMMENDED" choice (Sonoma, option 7 as of apple-firmware-
    # script 1.4-3 -- re-verify this number if the tool's menu ever
    # reorders/adds entries) via stdin instead of closing it.
    #
    # Metal-confirmed end-to-end on MEDUSA: this downloaded a real ~753MB
    # Recovery Image from oscdn.apple.com, extracted real per-board-model
    # brcmfmac4364b2/b3 WiFi firmware + Bluetooth firmware, and after a
    # `modprobe -r brcmfmac && modprobe brcmfmac` (first-boot-only; nothing
    # needs to reload firmware on a real first boot, the driver simply hasn't
    # tried yet) the WiFi chip loaded real firmware and a live
    # `nmcli device wifi list` scan returned real nearby access points.
    echo 7 | get-apple-firmware get_from_online 2>&1 | tail -30
    # NOTE: a bare `brcmfmac*.bin` glob is NOT sufficient here -- the
    # firmware-brcm80211 package (already in the amd64 manifests, a generic
    # non-Apple Broadcom firmware set) can populate /lib/firmware/brcm/ with
    # its OWN brcmfmac*.bin files independent of this hook, so that check
    # would report success even when get-apple-firmware's own extraction
    # failed. Apple's board-specific files are always named
    # `<chip>-pcie.apple,<boardname>.bin` -- require that exact pattern.
    if ls /lib/firmware/brcm/brcmfmac*.apple,*.bin >/dev/null 2>&1; then
        echo "[55] Apple WiFi/BT firmware present in /lib/firmware/brcm/ ($(ls /lib/firmware/brcm/brcmfmac*.apple,*.bin | wc -l) board file(s))"
    else
        echo "[55] WARN: get-apple-firmware ran but no Apple-specific brcmfmac*.apple,*.bin firmware appeared in /lib/firmware/brcm/ -- check the tail above for the real failure"
    fi
else
    echo "[55] WARN: apple-firmware-script installed but get-apple-firmware not on PATH — check package contents"
fi

echo "[55] T2 firmware wiring done"
