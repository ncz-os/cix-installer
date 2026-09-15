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

if command -v get-apple-firmware >/dev/null 2>&1; then
    echo "[55] running get-apple-firmware (fetches real macOS firmware from Apple's CDN)"
    # </dev/null: this hook runs non-interactively during install; if the
    # tool ever prompts (e.g. for a Mac model choice), reading from a closed
    # stdin fails fast instead of hanging the install indefinitely.
    get-apple-firmware < /dev/null 2>&1 | tail -20
else
    echo "[55] WARN: apple-firmware-script installed but get-apple-firmware not on PATH — check package contents"
fi

echo "[55] T2 firmware wiring done"
