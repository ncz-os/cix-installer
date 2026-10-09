#!/bin/bash
# 55-t2-firmware.sh — Apple T2 hardware: WiFi/Bluetooth firmware + audio
# config, Forky-native, with NO third-party apt repository.
#
# POSTURE CHANGE (r201 native-vendor closure, 2026-10-08): this hook used to
# wire AdityaGarg8's `t2-ubuntu-repo` (adityagarg8.github.io) and apt-install
# `apple-firmware-script` + `apple-t2-audio-config` from it. That source is a
# PENDING, UNAPPROVED row in manifests/vendor-repos.tsv (operator directive:
# no blanket Ubuntu exception, no invented vendor approval), and both of its
# packages are Ubuntu-built. The repo is now ELIMINATED: this hook makes no
# network call and runs no apt transaction. Nothing about WiFi/BT/audio is
# dropped — every input below is a pinned, licensed, official t2linux artifact.
#
# Where each input comes from now (see assets/t2/README.md and
# assets/t2/SOURCES.tsv for the exact source SHAs, licenses and file hashes):
#
#   * WiFi/BT firmware blobs — the pre-extracted staged build-time asset
#     `assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz` (128 Apple
#     brcmfmac board files, extracted once from the macOS Sonoma 14 Recovery
#     Image). This was already the primary path; it is now the ONLY path, and
#     a missing tarball is a HARD error — the old "quiet fallback" that tried
#     to run get-apple-firmware after a per-install Apple CDN fetch is gone.
#
#   * Audio config — `assets/t2/t2-better-audio/files/`, verbatim from
#     github.com/kekrby/t2-better-audio @ e46839a28963e2f7d364020518b9dac98236bcae
#     (the same tree is mirrored at github.com/t2linux/t2-better-audio), MIT.
#     This is the T2 audio config the official t2linux wiki
#     (wiki.t2linux.org/guides/audio-config) tells T2 users to install, and it
#     targets the model-specific `AppleT2xN` sound card the in-tree
#     apple-bce/t2bce driver exposes.
#
#   * Firmware helper — `assets/t2/firmware-helper/get-apple-firmware`, the
#     official t2linux wiki tool (wiki.t2linux.org/tools/firmware.sh) from
#     github.com/t2linux/wiki @ 986f5a79d43b75d93d84b8d57bc338853b51a0e0, MIT
#     (license text embedded in the script). Installed to /usr/bin and
#     /usr/libexec so an operator can still fetch firmware from Apple's CDN
#     manually on a model whose chip variant the staged set does not cover —
#     but the hook never depends on the network or on apt for it.
#
# IMPORTANT — do NOT install this hardware's kernel driver packages here. Our
# own v7.2.6+T2 kernel (built from t2linux's linux-t2-patches) already carries
# apple-bce/applesmc/HID/APFS support IN-TREE.
#
# RUNS AT REAL INSTALL TIME ON THE TARGET MACHINE (same class of hook as
# 54-gpu-accel.sh — T2 hardware detection is target-specific, not
# meaningfully baked into a shared image at chroot-build time).
# AMD64 only — never wired into the arm64 hook loops.
#
# The T2 PCI-bridge check lives in the shared, unit-testable
# post-install/lib/hw-detect.sh (`is_t2_hardware` / `t2_hardware_detail`);
# detection is the same [106b:1801] signature + DMI fallback as before, and it
# ALSO logs "T2 hardware: detected/not detected" unconditionally on amd64.
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

echo "[55] Apple T2 hardware confirmed — installing Forky-native T2 firmware + audio config (no third-party apt repo)"

# Test seams: NCZ_T2_ASSETS overrides the staged asset root; NCZ_T2_FW_TARBALL
# overrides the firmware tarball path; NCZ_T2_DMI_PRODUCT overrides the DMI
# product-name read (so the BT coverage note can be exercised in a chroot).
T2_ASSETS="${NCZ_T2_ASSETS:-/usr/local/lib/cix-installer/assets/t2}"
STAGED_FW_TARBALL="${NCZ_T2_FW_TARBALL:-/usr/local/lib/cix-installer/assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz}"
T2_PKG_FAIL=0

# Expected sha256 of the staged firmware tarball. Pinned HERE (not only in the
# base-layer fingerprint) so a swapped/tampered archive is refused before it is
# extracted; the base fingerprint is build-time, this is install-time. Override
# only for tests.
NCZ_T2_FW_SHA256="${NCZ_T2_FW_SHA256:-78810308c304eb999555b90de5debba7ad77eebe4614327a7539efe385e1e72a}"

# ncz_t2_extract_firmware TARBALL DEST
#   Verify the archive, refuse an unsafe one, then extract without inheriting
#   owner/permissions. Any refusal returns non-zero and leaves DEST untouched
#   (no host mutation). In-archive hardlinks the Apple firmware set uses are
#   preserved (never --hard-dereference); symlinks and escaped paths are refused.
ncz_t2_extract_firmware() {
    local tb="$1" dest="$2" names bad hl
    if ! printf '%s  %s\n' "$NCZ_T2_FW_SHA256" "$tb" | sha256sum -c --quiet - >/dev/null 2>&1; then
        echo "[55] ERROR: firmware tarball sha256 mismatch: $tb (want $NCZ_T2_FW_SHA256)" >&2
        return 1
    fi
    names="$(tar -tJf "$tb" 2>/dev/null)" || {
        echo "[55] ERROR: firmware tarball is unreadable or corrupt: $tb" >&2; return 1; }
    bad="$(printf '%s\n' "$names" | grep -nE '^/|(^|/)\.\.(/|$)' | head -1)"
    if [ -n "$bad" ]; then
        echo "[55] ERROR: firmware tarball has an unsafe member path: $bad" >&2; return 1
    fi
    if tar -tvJf "$tb" 2>/dev/null | grep -q '^l'; then
        echo "[55] ERROR: firmware tarball contains a symlink; refusing" >&2; return 1
    fi
    hl="$(tar -tvJf "$tb" 2>/dev/null | grep '^h' || true)"
    if printf '%s\n' "$hl" | grep -qE ' link to (/|\.\./|.*/\.\./)'; then
        echo "[55] ERROR: firmware tarball hardlink target escapes the archive; refusing" >&2; return 1
    fi
    mkdir -p "$dest"
    tar -xJf "$tb" --no-same-owner --no-same-permissions -C "$dest"
}

# --- Audio config: official t2-better-audio (MIT) --------------------------
# Same install layout the historical apple-t2-audio-config deb used (both the
# alsa-card-profile and the pulseaudio mixer trees, plus the udev rule), so an
# image that previously got the deb gets the identical file set from a
# license-clean, pinned upstream instead.
if [ -d "$T2_ASSETS/t2-better-audio/files" ]; then
    for _d in /usr/share/alsa-card-profile/mixer /usr/share/pulseaudio/alsa-mixer; do
        mkdir -p "$_d/profile-sets" "$_d/paths"
        cp -a "$T2_ASSETS/t2-better-audio/files/profile-sets/." "$_d/profile-sets/"
        cp -a "$T2_ASSETS/t2-better-audio/files/paths/." "$_d/paths/"
    done
    install -d -m0755 /usr/lib/udev/rules.d
    install -m0644 "$T2_ASSETS/t2-better-audio/files/91-audio-custom.rules" \
        /usr/lib/udev/rules.d/92-apple-t2-audio.rules
    echo "[55] installed T2 audio config from t2-better-audio @ e46839a2 (MIT)"
else
    echo "[55] ERROR: $T2_ASSETS/t2-better-audio/files missing — cannot install the T2 audio config (no fallback: the unapproved third-party repo is deliberately not used)" >&2
    T2_PKG_FAIL=1
fi

# --- Firmware helper: official t2linux wiki tool (MIT) ---------------------
if [ -f "$T2_ASSETS/firmware-helper/get-apple-firmware" ]; then
    install -d -m0755 /usr/bin /usr/libexec
    install -m0755 "$T2_ASSETS/firmware-helper/get-apple-firmware" /usr/bin/get-apple-firmware
    install -m0755 "$T2_ASSETS/firmware-helper/get-apple-firmware" /usr/libexec/get-apple-firmware
    echo "[55] installed get-apple-firmware (t2linux wiki tool @ 986f5a79, MIT)"
else
    echo "[55] WARN: $T2_ASSETS/firmware-helper/get-apple-firmware missing — the manual firmware helper is unavailable (WiFi/BT firmware below is unaffected)" >&2
fi

# --- WiFi/BT firmware blobs: staged asset (mandatory, sha256-verified) ------
if [ -f "$STAGED_FW_TARBALL" ]; then
    echo "[55] extracting staged Apple T2 firmware ($(du -h "$STAGED_FW_TARBALL" | cut -f1)) into /lib/firmware/brcm/ (sha256-checked, hardlink-preserving)"
    ncz_t2_extract_firmware "$STAGED_FW_TARBALL" /lib/firmware/brcm || T2_PKG_FAIL=1
else
    echo "[55] ERROR: staged firmware tarball missing ($STAGED_FW_TARBALL) — refusing a per-install Apple CDN fetch (the old quiet fallback is deliberately removed); WiFi/BT firmware cannot be installed" >&2
    T2_PKG_FAIL=1
fi

# BEGIN t2-pkg-status
# Read the real installed state; the historical shape (`apt-get ... | tail`)
# could hide a failure. Nothing here is behind a pipe. Default only if unset so
# an earlier block's failure is not clobbered.
: "${T2_PKG_FAIL:=0}"
for _p in /usr/bin/get-apple-firmware \
          /usr/share/alsa-card-profile/mixer/profile-sets/apple-t2x2.conf \
          /usr/lib/udev/rules.d/92-apple-t2-audio.rules; do
    if [ ! -e "$_p" ]; then echo "[55] ERROR: $_p is not installed" >&2; T2_PKG_FAIL=1; fi
done
# END t2-pkg-status

# NOTE: a bare `brcmfmac*.bin` glob is NOT sufficient here -- the
# firmware-brcm80211 package (already in the amd64 manifests, a generic
# non-Apple Broadcom firmware set) can populate /lib/firmware/brcm/ with its
# OWN brcmfmac*.bin files independent of this hook, so that check would
# report success even when firmware staging/extraction failed. Apple's
# board-specific files are always named `<chip>-pcie.apple,<boardname>.bin`.
if ls /lib/firmware/brcm/brcmfmac*.apple,*.bin >/dev/null 2>&1; then
    echo "[55] Apple WiFi/BT firmware present in /lib/firmware/brcm/ ($(ls /lib/firmware/brcm/brcmfmac*.apple,*.bin | wc -l) board file(s))"
else
    echo "[55] WARN: no Apple-specific brcmfmac*.apple,*.bin firmware appeared in /lib/firmware/brcm/ -- check the staged tarball" >&2
    T2_PKG_FAIL=1
fi

if [ "$T2_PKG_FAIL" = 1 ]; then
    echo "[55] FAILED: the T2 firmware/audio assets did not install" >&2
    exit 1
fi

# --- Bluetooth staging inventory + recovery-hint (diagnosis, not a fix) ---
# The Sonoma14 tarball ships Apple Bluetooth firmware for a known set of board
# names whose `brcmbt<chip><stepping>-apple,<board>-{m,u}.ptb` files end up in
# /lib/firmware/brcm/ above. We log the staged set so an operator can compare
# it to their T2 model's BT chip without booting a debugger. The audited gaps
# are *not* fixable in user-space: the kernel's `hci_uart_bcm` driver only
# matches firmware by chip-id+board rev, and there is no in-kernel entry for
# BCM4364B3 "Trinidad Olympic GEN" on the current 7.3.0-rc6-t2-ncz tree, so
# even with an Apple file present, the driver will not load it. The
# source-authorised recovery for the missing boards is the same helper the hook
# already installed above (MIT, pinned in assets/t2/SOURCES.tsv): invoke it from
# a Linux session with internet to fetch the matching firmware.
#
# We deliberately do NOT install a `brcm/BCM.hcd` symlink shortcut. A blind
# alias of `BCM.hcd` to a `brcmbt4377b3-apple,formosa-m.ptb` (or any other
# board) breaks the kernel's chip-id matching and only adds noise:
#   `Bluetooth: hci0: BCM: firmware Patch file not found, tried: brcm/BCM.hcd`
# masks the real chip-id+board-rev gap, and
#   `Bluetooth: hci0: HCI Read Transmit Power Level command is advertised,
#    but not supported.`
# is independent harmless Apple firmware noise (the HCI command is advertised
# but stubbed by the BCM ROM; it is not a fault and not suppressed).
#
# The adjacent `brcmf_p2p_set_firmware` returns -52 (-EBUSY) symptom on this
# family is a kernel-side WiFi P2P path, NOT this hook's path -- see
# docs branch followup/amd64-kernel-audit-20261008 for the separate diagnosis.
bt_boards_staged=""
# The tarball uses two filename shapes for BT firmware:
#   - newer/revendorised files: brcmbt<chip><stepping>-apple,<board>-m.ptb
#     (or -u for Murata vendor).  Both end in '.<x>.ptb' where x is one of
#     {m, u}.
#   - the BCM4377B3 (formosa) BT files do NOT carry a -m/-u vendor suffix:
#     brcmbt4377b3-apple,formosa.bin / .ptb.
# We parse the board name out of either form and strip an optional trailing
# -m/-u so the inventory line lists one entry per board.
#
# Glob note: this hook runs under bash 3.2 on macOS Studio (`#!/bin/bash`
# build images target Debian forky but the host shell is the Apple-supplied
# bash 3.2 from /bin/bash), which interprets a literal `,` in a glob
# pattern as list-union semantics and silently fails to expand the glob.
# `brcmbt*apple*.ptb` is the smallest pattern that does NOT contain a literal
# `,` and still matches both shapes (because the `*` covers any intermediate
# characters, including the `,` separator).
for ptb in /lib/firmware/brcm/brcmbt*apple*.ptb /lib/firmware/brcm/brcmbt*apple*.bin; do
    [ -e "$ptb" ] || continue
    bn="${ptb##*/}"
    # Every Apple firmware file uses 'apple,<board>' as the manufacturer
    # separator. If a file in the staged directory doesn't carry that
    # canonical separator, it is either a non-Apple file or a tarball entry
    # that escaped an earlier filter -- skip it (no silent prefix-leak into
    # the inventory line). The pre-image formatter for this hook is the
    # upstream `BluetoothFWCollection` in `assets/t2/firmware-helper/
    # get-apple-firmware`, which always emits `brcmbt<chip><stepping>-apple,
    # <board>-<m|u>.{bin,ptb}` (with `formosa` etc. as the no-vendor edge case).
    case "$bn" in
        brcmbt*-apple,*) board="${bn#brcmbt*-apple,}" ;;
        *) continue ;;
    esac
    # Strip the trailing Apple-firmware extension. Apple firmware uses both
    # `.ptb` (Bluetooth) and `.bin` (Bluetooth / firmware blob) extensions;
    # `%.*` removes the trailing `.<anything>`, handling both without a
    # multi-clause case and tolerating any future `.N+char` extension that
    # Apple might add (this hook's only contract is the staging inventory,
    # not validation).
    board="${board%.*}"
    # Optional vendor suffix: -m (GEN/Murata-derived) or -u (USI).
    case "$board" in
        *-[mu]) board="${board%-[mu]}" ;;
    esac
    case ",${bt_boards_staged}," in
        *",${board},"*) ;;
        *) bt_boards_staged="${bt_boards_staged:+$bt_boards_staged,}$board" ;;
    esac
done
if [ -n "$bt_boards_staged" ]; then
    echo "[55] Apple Bluetooth staged boards (board names parsed from .ptb files): ${bt_boards_staged}"
else
    echo "[55] Apple Bluetooth staged boards: none in this tarball"
fi
# Cross-check against the host DMI product_name so a T2 Mac whose BCM chip the
# staged set does not cover does not silently succeed. The MEDUSA audit
# snapshot (MacBookPro16,1, kernel 7.3.0-rc6-4-t2-edge-aer9010) reports:
#   Bluetooth: hci0: BCM4364B3 Trinidad Olympic GEN (MFG)
#   Bluetooth: hci0: BCM: chip id 150
#   Bluetooth: hci0: BCM: firmware Patch file not found, tried: 'brcm/BCM.hcd'
# i.e. BCM4364B3 BT firmware is NOT in the staged set and the kernel has no
# chip-id entry for it. The recovery command is therefore surfaced, not a
# fabricated fix.
_ncz_t2_product="${NCZ_T2_DMI_PRODUCT:-}"
if [ -z "$_ncz_t2_product" ]; then
    if [ -r /sys/class/dmi/id/product_name ]; then
        _ncz_t2_product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    elif command -v dmidecode >/dev/null 2>&1; then
        _ncz_t2_product=$(dmidecode -s system-product-name 2>/dev/null)
    fi
fi
case "$_ncz_t2_product" in
    MacBookPro16,[12]|iMac20,1|iMac20,2)
        echo "[55] NOTE: $_ncz_t2_product Bluetooth is BCM4364B3 'Trinidad Olympic GEN' (NOT in staged set; the kernel chip-id table also lacks BCM4364B3 on this branch). Recovery: '/usr/bin/get-apple-firmware get_from_online' from a Linux session with internet (helper is MIT, installed above by this hook)."
        ;;
esac
unset _ncz_t2_product bt_boards_staged

echo "[55] T2 firmware wiring done"
