#!/bin/bash
# 55-t2-firmware.sh — Apple T2 hardware: real WiFi/Bluetooth firmware +
# audio config, from native NCZ packages built against Debian Forky only.
#
# Native packages (built for NCZ/Forky; this hook just does the APT install,
# it does NOT generate or trust any apt source):
#   A) apple-t2-audio-config  0.5.1+ncz1  (Arch: all; 6 UCM files; depends on
#                                              alsa-ucm-conf>=1.2.16)
#   B) apple-firmware-script  20261015+ncz1 (Arch: all)
#
# The signed NCZ apt source is wired by hook24 (post-install/24-apt-sources.sh
# via post-install/lib/apt-separation.sh). This hook never fetches a key, never
# writes a sources.list entry, never adds a vendor repo: the only acquisition
# is `apt-get install` from the already-configured NCZ/Forky suite.
#
# Posture (same as 53-chrome.sh / 54-gpu-accel.sh since 2026-09-14: install
# what makes the hardware work). No Ubuntu exception: this hook does not
# consume Ubuntu-built packages from the third-party AdityaGarg8
# `t2-ubuntu-repo` anymore. If the native NCZ package is unavailable, the
# hook reports honest deferred/failure state; it does NOT silently fall back
# to a vendor Ubuntu origin.
#
# IMPORTANT — do NOT install any kernel driver packages here. Our own
# v7.2.6+T2 kernel already carries apple-bce/applesmc/HID/APFS support
# IN-TREE; the upstream t2-ubuntu-repo README itself warns apple-bce,
# apple-touchbar, applesmc-t2, apfs-dkms and bcm5974-t2 must NOT be installed
# alongside a linux-t2-class kernel. Only the two audio/firmware packages
# above are needed here.
#
# FIRMWARE SOURCE (real fix): the real WiFi/BT firmware blobs are
# pre-extracted at build time and shipped as a static asset
# (assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz, staged into
# base.squashfs). Not fetched from Apple's CDN at every install.
#
# The staged firmware path runs FIRST, before any APT step that might fail
# on a missing package. A missing native package MUST NOT cause the staged
# bytes to be skipped: the operator still gets real firmware offline.
#
# RUNS AT REAL INSTALL TIME ON THE TARGET MACHINE (same class of hook as
# 54-gpu-accel.sh — T2 hardware detection is target-specific, not
# meaningfully baked into a shared image at chroot-build time).
# AMD64 only — never wired into the arm64 hook loops.
#
# UPDATED: native NCZ/Forky acquisition only; legacy AdityaGarg8
# `t2-ubuntu-repo` is no longer added or trusted; if its sources.list entry
# is found on an upgraded system it is moved aside (reversible: renamed to
# `.disabled-for-build`, not removed) so a stray Ubuntu origin cannot
# shadow the native packages.
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

echo "[55] Apple T2 hardware confirmed — wiring native NCZ/Forky audio + firmware packages"

# --- T2 boot-noise quirks (modprobe.d) -------------------------------------
# Written here, immediately after T2 is confirmed and BEFORE any apt/CDN step,
# so a later network failure cannot skip them (this hook exits early on those).
# These remove recurring error-level boot-log lines at their root cause on
# T2 Macs; all are benign-but-noisy and are fixed by not loading/announcing
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

# (3) hid_sensor_rotation on the T2 sensor hub (device 05AC:8104, usage
#     0x20008a): Apple's HID report descriptor declares the orientation
#     collection but omits the standard sensor "common attributes" report, so
#     hid_sensor_parse_common_attributes() asks the hub for report id
#     0xffffffff, gets nothing, and the probe fails. Three lines per boot:
#       hid-sensor-hub ...: No report with id 0xffffffff found        (WARN)
#       hid_sensor_rotation HID-SENSOR-20008a...: failed to setup common attributes
#       hid_sensor_rotation HID-SENSOR-20008a...: probe with driver hid_sensor_rotation failed with error -22
#     The sensor is unusable (auto-rotation is simply unavailable) and nothing
#     depends on it, so do not bind the driver at all. Not binding is the
#     correct model here: the device has no usable interface, and skipping it
#     removes the failed probe AND the "No report" warning together. This is
#     deliberately a driver blacklist rather than a kernel patch -- a kernel
#     quirk would either leave a broken IIO device registered or only relocate
#     the same messages.
cat > /etc/modprobe.d/ncz-t2-hid-sensor-rotation.conf <<'MODEOF'
# Apple T2 HID sensor hub (05AC:8104) exposes an orientation collection whose
# descriptor lacks the generic common-attributes report, so hid_sensor_rotation
# cannot parse it and fails probe (-22). The sensor is non-functional, so do not
# bind the driver; this removes the failed-probe error and the hub warning.
blacklist hid_sensor_rotation
install hid_sensor_rotation /bin/true
MODEOF
echo "  [55] hid_sensor_rotation blacklisted (T2 hub descriptor lacks the common-attributes report)"

# --- legacy vendor sources list, disabled (reversible) -----------------------
# Older installers wrote /etc/apt/sources.list.d/t2.list with the third-party
# AdityaGarg8 `t2-ubuntu-repo` (Ubuntu-built packages). This hook now consumes
# only native NCZ/Forky packages; a stray legacy Ubuntu origin would shadow
# the native names by version. Comment out ONLY the matching legacy deb/deb-src
# lines in place (REVERSIBLE: the original bytes are preserved in a unique
# ${f}.disabled-for-build.XXXXXX backup); do not touch unrelated user files or
# comments. Match by the actual URI on the line: the ONLY legacy host/path this
# hook knows about. No generation/trust: nothing is written or fetched here.
ncz_t2_disable_legacy_vendor_list() {
    # Reversibly disable KNOWN-legacy vendor source lines so the native NCZ
    # suite cannot be shadowed by a stray Ubuntu origin. Only lines whose
    # actual URI matches the known legacy host/path are commented out; every
    # other active deb/deb-src line, comment, and unrelated user content is
    # preserved byte-for-byte. The original file is rewritten in place
    # atomically; a byte-identical backup is kept as
    # ${f}.disabled-for-build.XXXXXX (never overwriting an existing backup).
    #
    # Safety guarantees (tested by build/test-t2-native-packages.sh with real
    # temporary files):
    #   * Files already ending in `.disabled-for-build` are skipped.
    #   * Bracket options on a `deb` line (e.g. `deb [signed-by=...key.gpg]
    #     http://...`) are skipped when extracting the URI -- the legacy
    #     t2.list ships with `[signed-by=...]` between the keyword and the
    #     URL, so a naive `awk '{print $2}'` would return `[signed-by=...]`
    #     and never match the legacy URL.
    #   * Only lines whose actual URI matches the known legacy host/path are
    #     commented; unrelated active deb/deb-src lines and comments are
    #     preserved verbatim.
    #   * A unique backup is created with mktemp; an existing backup is never
    #     overwritten or deleted.
    #   * On any error the original file and any backup are preserved; only
    #     our own temp files are removed.
    local f="$1" tmp bak
    [ -f "$f" ] || return 0
    case "$f" in
        *.disabled-for-build|*.disabled-for-build.*) return 0 ;;
    esac
    # Refuse symlinks: rewriting through a symlink could clobber an unrelated
    # target. Honest failure rather than a silent skip.
    if [ -L "$f" ]; then
        echo "[55] WARN: $f is a symlink; refusing to rewrite (leaving untouched)" >&2
        return 1
    fi
    tmp=$(mktemp "${f}.ncz.XXXXXX") || {
        echo "[55] WARN: could not create temp file next to $f; leaving it untouched" >&2
        return 1
    }
    # Preserve the original mode and owner on the temp file.
    if ! cp -p "$f" "$tmp"; then
        echo "[55] WARN: could not copy $f to temp; leaving it untouched" >&2
        rm -f "$tmp"
        return 1
    fi
    # Rewrite: comment out ONLY active deb/deb-src lines whose actual URI
    # matches the known legacy host/path. Everything else is emitted verbatim.
    if ! awk '
        /^[[:space:]]*deb(-src)?[[:space:]]/ {
            uri = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) { uri = $i; break }
            }
            if (uri ~ /^https?:\/\/adityagarg8\.github\.io\/t2-ubuntu-repo(\/|$)/) {
                print "# [55] disabled legacy vendor source: " $0
                next
            }
        }
        { print }
    ' "$f" > "$tmp"; then
        echo "[55] WARN: awk rewrite failed for $f; leaving it untouched" >&2
        rm -f "$tmp"
        return 1
    fi
    # If nothing changed, remove our temp and report success (idempotent).
    if cmp -s "$f" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    # Create a UNIQUE backup (never overwrite/delete an existing one).
    bak=$(mktemp "${f}.disabled-for-build.XXXXXX") || {
        echo "[55] WARN: could not create backup for $f; leaving it untouched" >&2
        rm -f "$tmp"
        return 1
    }
    if ! cp -p "$f" "$bak"; then
        echo "[55] WARN: could not write backup $bak; leaving $f untouched" >&2
        rm -f "$tmp" "$bak"
        return 1
    fi
    # Atomic replace of the original with the rewritten temp.
    if ! mv "$tmp" "$f"; then
        echo "[55] WARN: could not replace $f atomically; original preserved, backup at $bak" >&2
        rm -f "$tmp"
        return 1
    fi
    echo "[55] disabled known legacy vendor source line(s) in $f (backup: ${bak##*/})"
    return 0
}
T2_LEGACY_FAIL=0
for _lf in /etc/apt/sources.list.d/t2.list \
           /etc/apt/sources.list.d/t2-ubuntu-repo.list; do
    ncz_t2_disable_legacy_vendor_list "$_lf" || T2_LEGACY_FAIL=1
done
unset _lf

# --- Native NCZ/Forky APT acquisition (small, testable function) ------------
# ncz_t2_apt_acquire PACKAGE... -> 0 installed, 2 refused (Remv/sim-fail),
# 4 install-failed, 5 not-installed-after-success-exit (honest status).
#
# Simulate first; refuse any removal; on a clean sim, run the EXACT same
# expanded args and verify each package really landed. apt-get update is
# fail-closed/ErrorMode-any but offline already-seeded packages still
# resolve, so the network-down path can still succeed on the mirror.
#
# This function is intentionally small (no new framework) and is exported so
# build/test-t2-native-packages.sh can drive it directly under mocks without
# executing the whole hook. The marker block below is the test seam: the
# test extracts it and sources it (NCZ_T2_APT_BASE_ARGS + ncz_t2_apt_acquire
# + ncz_t2_log), then calls ncz_t2_apt_acquire under various mocked apt-get /
# dpkg-query scenarios.
# BEGIN t2-acquire-fn
NCZ_T2_APT_BASE_ARGS=( -y --no-install-recommends )
ncz_t2_apt_acquire() {
    ncz_t2_log "packages: $*"
    if [ "${T2_LEGACY_FAIL:-0}" != 0 ]; then
        ncz_t2_log "legacy source migration failed; refusing APT acquisition"
        return 2
    fi
    # apt-get update is best-effort: a stale or unreachable index is logged,
    # but offline already-seeded packages still resolve. No metadata
    # date-check bypass (`Acquire::Check-Date=false`) is set here -- that is
    # an unrelated TUF/Release-date weakness and not needed: a cached signed
    # index already on disk is used as-is, and a fresh fetch failing date
    # validation is a real failure we want to surface.
    apt-get update 2>&1 | tail -5
    local _sim _rc _rm
    _sim=$(LC_ALL=C apt-get install -s "${NCZ_T2_APT_BASE_ARGS[@]}" "$@" 2>&1); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '%s\n' "$_sim" | tail -5
        ncz_t2_log "simulation failed (rc=$_rc) for: $*"; return 2
    fi
    _rm=$(printf '%s\n' "$_sim" | grep -c '^Remv ')
    if [ "$_rm" -gt 0 ]; then
        printf '%s\n' "$_sim" | grep '^Remv ' | head -10
        ncz_t2_log "simulation would remove $_rm package(s); refusing: $*"; return 2
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install "${NCZ_T2_APT_BASE_ARGS[@]}" "$@" 2>&1 | tail -10
    if [ "${PIPESTATUS[0]:-0}" -ne 0 ]; then
        ncz_t2_log "install failed (rc=${PIPESTATUS[0]}) for: $*"; return 4
    fi
    local _p _s
    for _p in "$@"; do
        _s=$(dpkg-query -W -f='${Status}' "${_p%%=*}" 2>/dev/null)
        case "$_s" in
            *"install ok installed"*) ;;
            *) ncz_t2_log "post-install status: $_p not installed (apt-get rc ok but dpkg disagrees)"; return 5 ;;
        esac
    done
    return 0
}
ncz_t2_log() { echo "[55] $*"; }
# END t2-acquire-fn

# --- staged firmware extraction FIRST --------------------------------------
# Native NCZ A/B may install or fail offline; the staged bytes (assets staged
# at build time) must still be deployed regardless. Network/key/vendor-repo
# failures can NEVER skip the stage path: a T2 Mac with no network at install
# time still gets real firmware from base.squashfs.
STAGED_FW_TARBALL=/usr/local/lib/cix-installer/assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz
ncz_t2_extract_staged_firmware() {
    # Returns 0 only when an actual extraction succeeded; 1 when the tarball
    # is missing (recoverable via the online fallback); 2 when tar itself
    # failed (NOT recoverable -- the online fallback depends on the native
    # package, and a corrupt staged asset must not be reported as success).
    if [ -f "$STAGED_FW_TARBALL" ]; then
        echo "[55] extracting staged Apple T2 firmware ($(du -h "$STAGED_FW_TARBALL" | cut -f1)) into /lib/firmware/brcm/"
        mkdir -p /lib/firmware/brcm
        tar -xJf "$STAGED_FW_TARBALL" -C /lib/firmware/brcm
        _tar_rc=$?
        if [ "$_tar_rc" -eq 0 ]; then
            return 0
        fi
        echo "[55] WARN: staged firmware extraction FAILED (tar rc=$_tar_rc) -- NOT delivered, will rely on online get-apple-firmware fallback if available" >&2
        return 2
    fi
    echo "[55] staged firmware tarball missing ($STAGED_FW_TARBALL) -- online get-apple-firmware fallback will run after native package install"
    return 1
}
# Track staged-firmware delivery so the post-install status block cannot claim
# success when extraction actually failed (a missing tarball is recoverable
# via the online fallback; a tar failure is NOT).
#   0 = extracted OK
#   1 = tarball missing (recoverable via online fallback)
#   2 = tar extraction failed (hard failure; NOT recoverable)
STAGED_FW_RC=0
ncz_t2_extract_staged_firmware || STAGED_FW_RC=$?

# --- native NCZ A/B acquisition (apple-firmware-script + apple-t2-audio-config) -
# Both packages are native NCZ built against Debian Forky (Arch: all). The
# signed NCZ source is supplied by hook24 (24-apt-sources.sh); this hook does
# not fetch a key, write one sources.list entry, or trust any Ubuntu origin.
# Failure is honest: if the package is not yet published, the operator sees
# a clear deferred status; the staged firmware path above has already
# delivered real bytes offline.
_t2_native_rc=2
if [ "$T2_LEGACY_FAIL" = 0 ]; then
    ncz_t2_apt_acquire apple-firmware-script=20261015+ncz1 apple-t2-audio-config=0.5.1+ncz1
    _t2_native_rc=$?
else
    echo "[55] ERROR: legacy source migration failed; refusing native APT acquisition" >&2
fi
# BEGIN t2-pkg-status
# Post-install honest status check (r201 review: `| tail` hid the apt status,
# so the helper function's rc alone is insufficient — dpkg must agree, and
# the marker block is the test seam that build/test-hooks-fail-loudly.sh
# extracts to verify a failed install is reported).
T2_PKG_FAIL=0
for _p in apple-firmware-script apple-t2-audio-config; do
    case "$(dpkg-query -W -f='${Status}' "$_p" 2>/dev/null)" in
        *"install ok installed"*) ;;
        *) echo "[55] ERROR: $_p is not installed (apt-get rc=$_t2_native_rc)" >&2; T2_PKG_FAIL=1 ;;
    esac
done
# END t2-pkg-status

# The ncz_t2_apt_acquire rc is authoritative. An old/leftover dpkg-installed
# version of the package may keep `dpkg-query -W` happy even when this run's
# sim/removal/install refused or failed — the hook must NOT silently mark
# success in that case. Required for "even if old packages already installed"
# (the contract test at build/test-t2-native-packages.sh verifies by driving
# the function under a removal-conflicting scenario with leftover dpkg state).
if [ "$_t2_native_rc" -ne 0 ]; then
    echo "[55] ERROR: ncz_t2_apt_acquire rc=$_t2_native_rc (sim/removal/install refused or failed); package state may be a leftover from an earlier install -- not declaring success" >&2
    T2_PKG_FAIL=1
fi
# Staged-firmware extraction failure also blocks the success path -- a tar
# failure is NOT recoverable (the online fallback depends on the native pkg).
if [ "$STAGED_FW_RC" -ge 2 ]; then
    # 1 == "tarball missing, will retry via online path" -- acceptable; only
    # hard tar-extract failures (>=2) block the success claim.
    echo "[55] ERROR: staged firmware extraction rc=$STAGED_FW_RC (hard failure); not declaring success" >&2
    T2_PKG_FAIL=1
fi

# --- online get-apple-firmware fallback (only when stage was absent) ---------
# If the stage was absent AND the native apple-firmware-script installed
# (which provides get-apple-firmware), AND dmg2img is now needed for the
# per-install CDN fallback, ensure dmg2img is present (also from the
# configured NCZ/Forky suite — same acquire discipline: sim, no-Remv,
# EXACT same args parity, real install + status check).
if [ ! -f "$STAGED_FW_TARBALL" ] && [ "$_t2_native_rc" = 0 ]; then
    if ! dpkg-query -W -f='${Status}\n' dmg2img 2>/dev/null | grep -q "install ok installed"; then
        ncz_t2_apt_acquire dmg2img || ncz_t2_log "dmg2img not installed (rc=$?); the get-apple-firmware fallback may not run"
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
        # apple-firmware-script 20261015+ncz1 (re-verify this number if the
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
# The kernel side is patch 9102 in the linux-t2-ncz series, and
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
            echo "[55] Bluetooth: ${t2_model:-this T2 model} uses a UART Broadcom chip on ROM firmware; brcm/BCM.hcd is intentionally absent (no redistributable patchram; see linux-t2-ncz patch 9102)"
        fi
        ;;
esac

if [ "$T2_PKG_FAIL" = 1 ]; then
    # Honest deferred/failure: do NOT silently mark success, and do NOT claim
    # a deferred-retry unit exists (none does for T2 -- unlike the Intel
    # ncz-intel-accel-setup.timer this hook has no native retry unit; an
    # operator running the installer again is the real recovery path). The
    # staged firmware extraction above had its own rc tracking; only an
    # online-fallback path remains when the staging tarball was missing.
    case "$STAGED_FW_RC:$_t2_native_rc" in
        0:0) ;;  # unreachable, kept for symmetry
        1:*) echo "[55] (staged firmware bytes missing -- online get-apple-firmware may still recover after apple-firmware-script installs)" >&2 ;;
        *)   echo "[55] (staged firmware extraction failed -- rely on online get-apple-firmware fallback)" >&2 ;;
    esac
    echo "[55] FAILED: the T2 audio/firmware packages did not install" >&2
    exit 1
fi
echo "[55] T2 firmware wiring done"
