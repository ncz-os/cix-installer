#!/bin/bash
# verify-installed-target.sh -- assert the INSTALLED target rootfs
# actually carries the Sky1 accelerator userspace the install chain claims.
#
# Companion to kvm-install-gate-gpt.sh. The gate builds a raw ext4 image of
# the installed root partition ($EVIDENCE_ROOT), copies the install logs out
# of it with debugfs, and deletes it. Before it is deleted, this script reads
# the same image (rootless, debugfs only) and asserts:
#   (i)   Sky1 firmware: 16 .fwb + dsp_fw.bin + arm/mali/arch12.8/mali_csffw.bin
#   (ii)  NPU: /usr/src/aipu-6.2.0, /usr/sbin/dkms, and a DKMS-built aipu.ko
#         for the installed Sky1 kernel whose embedded version is 6.2.0
#         (never the 5.11.0 in-tree generation)
#   (iii) VPU: amvx module registered in modules.dep, the load-modules.sh
#         helper that creates /dev/video-cixdec0, and a distro ffmpeg whose
#         libavcodec carries the *_v4l2m2m codecs
#   (iv)  browsers: google-chrome-stable and chromium-ncz-sky1 installed
#   (v-b) Sky1 HDMI/DP audio autoswitch: daemon + user unit installed and enabled
#         under a .wants dir, pactl present (without it the desktop only ever
#         shows PipeWire's Dummy Output)
#   (info) VA-API driver files (reported, never a failure)
#
# Usage: verify-installed-target.sh <EVIDENCE_ROOT_RAW> <DEBUGFS> [arm64|amd64]
# VERIFY_EXPECT_COMPONENTS=<record> (set by the KVM gate from its options answer)
# must equal the target's /etc/cix-installer/COMPONENTS; the desktop-layer
# sections run only when that record has the desktop, and the (opt) section
# checks the recovery console/container and the rescue marker against it.
# COMMON sections run for both architectures; Sky1 (arm64) sections only for arm64; the amd64
# section also proves no Sky1 policy leaked onto x86 (the cause of the T2 boot hangs). Every run
# prints machine-readable '[fact] key=value' lines that build/verify-dual-arch-parity.sh compares.
# Exit:  0 all required artifacts present, 1 at least one missing (every miss
#        is printed as "GATE: missing [class]: what"), 2 bad invocation.
set -uo pipefail

# This script's own checkout root (the build/ directory it lives in). The
# caller may be a test harness that defines its own ROOT in a separate
# process -- never assume the caller's environment here (set -u).
HERE_VT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EVIDENCE_ROOT="${1:?usage: verify-installed-target.sh EVIDENCE_ROOT_RAW DEBUGFS [arm64|amd64]}"
DEBUGFS="${2:?usage: verify-installed-target.sh EVIDENCE_ROOT_RAW DEBUGFS [arm64|amd64]}"
ARCH="${3:-${NCZ_TARGET_ARCH:-arm64}}"
case "$ARCH" in arm64|amd64) ;; *) echo "GATE FAIL: arch must be arm64 or amd64, got $ARCH" >&2; exit 2 ;; esac
[ -f "$EVIDENCE_ROOT" ] || { echo "GATE FAIL: $EVIDENCE_ROOT is not a regular file" >&2; exit 2; }
[ -x "$DEBUGFS" ] || { echo "GATE FAIL: $DEBUGFS is not executable" >&2; exit 2; }

TMP="$(mktemp -d -t verify-target.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
gate_miss() { echo "GATE: missing [$1]: $2" >&2; FAIL=1; }

# Arch-scoped firmware BOM, resolved ONCE here for BOTH of the checks below
# ((net-fw) network firmware and (fw-bom) the whole firmware BOM):
# manifests/firmware-$ARCH.pkgs when present (the trimmed sky1-arm64 set), else
# the complete architecture-neutral manifests/firmware.pkgs (amd64).
BOM_PKGS="$HERE_VT/../manifests/firmware-$ARCH.pkgs"
[ -f "$BOM_PKGS" ] || BOM_PKGS="$HERE_VT/../manifests/firmware.pkgs"

# debugfs prints "<path>: File not found by ext2_lookup" (rc stays 0) for a
# missing path and an "Inode:" line for a present one. Key on the positive
# marker; never on the absence of an error string.
dfs() { "$DEBUGFS" -R "$1" "$EVIDENCE_ROOT" 2>&1; }
exists() { dfs "stat $1" | grep >/dev/null '^Inode:'; }
# dump <path-in-image> <local-file>; success only if a non-empty file landed.
fetch() {
    rm -f "$2"
    "$DEBUGFS" -R "dump $1 $2" "$EVIDENCE_ROOT" >/dev/null 2>&1
    [ -s "$2" ]
}
# Names in a directory ("ls -p" fields: /inode/mode/uid/gid/name/size/).
lsnames() { dfs "ls -p $1" | awk -F/ 'NF>=6 && $6!="." && $6!=".." {print $6}'; }

# Decompress a dumped module in place by suffix; echo the resulting path.
# Returns non-zero (and prints nothing) if the needed tool is missing.
plain_module() {
    local f="$1"
    case "$f" in
        *.xz)  command -v xz   >/dev/null 2>&1 && xz   -dc "$f" > "${f%.xz}"  && echo "${f%.xz}"  ;;
        *.zst) command -v zstd >/dev/null 2>&1 && zstd -dqc "$f" > "${f%.zst}" && echo "${f%.zst}" ;;
        *.gz)  gzip -dc "$f" > "${f%.gz}" && echo "${f%.gz}" ;;
        *)     echo "$f" ;;
    esac
}


# --- (opt) install options: the recorded selection and what it installs -------------------------------
# The record is the comma list preseed/component-selector.sh wrote (`none` = no
# option). Without a record the old behaviour holds: every component expected.
echo "[verify-target] (opt) install options"
V_RECORD=""
if fetch /etc/cix-installer/COMPONENTS "$TMP/components"; then
    V_RECORD="$(tr -d ' \t\r\n' < "$TMP/components")"
fi
if [ -n "${VERIFY_EXPECT_COMPONENTS:-}" ] && [ "$V_RECORD" != "$VERIFY_EXPECT_COMPONENTS" ]; then
    gate_miss options "/etc/cix-installer/COMPONENTS is '${V_RECORD:-missing}', the installer was answered '$VERIFY_EXPECT_COMPONENTS'"
fi
V_DESKTOP=1; V_MGMT=1; V_RESCUE=1
if [ -n "$V_RECORD" ]; then
    case ",$V_RECORD," in *,desktop,*) : ;; *) V_DESKTOP=0 ;; esac
    case ",$V_RECORD," in *,mgmt-container,*) : ;; *) V_MGMT=0 ;; esac
    case ",$V_RECORD," in *,rescue-partition,*) : ;; *) V_RESCUE=0 ;; esac
fi
echo "[verify-target]     record '${V_RECORD:-none recorded}': desktop=$V_DESKTOP mgmt-container=$V_MGMT rescue-partition=$V_RESCUE"
# mgmt-container carries both recovery tiers: the nspawn container (38) and the
# static console on :2323 (37). Both present with it, both absent without it.
for _o in /etc/systemd/nspawn/ncz-recovery.nspawn /etc/systemd/system/ncz-failsafe.service /opt/ncz-failsafe/bin/busybox; do
    if exists "$_o"; then
        [ "$V_MGMT" = 1 ] || gate_miss options "$_o is installed but mgmt-container was not selected"
    else
        [ "$V_MGMT" = 0 ] || gate_miss options "$_o is missing (mgmt-container selected; post-install/37-failsafe-access.sh, 38-recovery-container.sh)"
    fi
done
# 72-rescue-partition.sh writes RESCUE_READY (PARTUUID=) only for a selected partition.
if fetch /usr/local/lib/cix-installer/RESCUE_READY "$TMP/rescue_ready"; then
    grep -q '^PARTUUID=..*' "$TMP/rescue_ready" || gate_miss options "RESCUE_READY has no PARTUUID"
    [ "$V_RESCUE" = 1 ] || gate_miss options "RESCUE_READY exists but rescue-partition was not selected"
else
    [ "$V_RESCUE" = 0 ] || gate_miss options "/usr/local/lib/cix-installer/RESCUE_READY missing (rescue-partition selected; post-install/72-rescue-partition.sh)"
fi
echo "[fact] components=${V_RECORD:-unrecorded}"

# --- (id) release identity, same on both architectures ------------------------------------------------
echo "[verify-target] (id) release identity"
if fetch /usr/local/lib/cix-installer/BUILD_ARCH "$TMP/build_arch"; then
    BA="$(tr -d '[:space:]' < "$TMP/build_arch")"
    [ "$BA" = "$ARCH" ] || gate_miss identity "BUILD_ARCH is '$BA', expected $ARCH"
else
    gate_miss identity "/usr/local/lib/cix-installer/BUILD_ARCH"
fi
if fetch /usr/local/lib/cix-installer/BUILD_VERSION "$TMP/build_version"; then
    echo "[fact] build_version=$(tr -d '[:space:]' < "$TMP/build_version")"
else
    gate_miss identity "/usr/local/lib/cix-installer/BUILD_VERSION"
fi
# /etc/os-release is a symlink (debugfs cannot cat it); the image's own identity is RELEASE + /etc/issue.
if fetch /usr/local/lib/cix-installer/RELEASE "$TMP/release" && grep -q '^NCZ_PRODUCT_NAME="NCZ-OS"' "$TMP/release"; then
    echo "[fact] release_version=$(sed -n 's/^NCZ_RELEASE_VERSION=//p' "$TMP/release" | tr -d '"' | head -1)"
    echo "[fact] release_codename=$(sed -n 's/^NCZ_RELEASE_CODENAME=//p' "$TMP/release" | tr -d '"' | head -1)"
else
    gate_miss identity "/usr/local/lib/cix-installer/RELEASE does not identify NCZ-OS"
fi
if fetch /etc/issue "$TMP/issue" && grep -q '^NCZ-OS ' "$TMP/issue"; then :; else gate_miss identity "/etc/issue does not carry the NCZ-OS banner"; fi

# --- (ld) the final ldconfig ran and first-boot ldconfig.service cannot race ---------------------------
echo "[verify-target] (ld) ldconfig"
exists /etc/systemd/system/ldconfig.service.d/10-ncz-tolerate-race.conf || gate_miss ldconfig "ldconfig.service tolerate-race drop-in (late.sh final ldconfig block did not run)"
exists /etc/ld.so.cache || gate_miss ldconfig "/etc/ld.so.cache"
exists /etc/.updated || gate_miss ldconfig "/etc/.updated stamp (late.sh)"

# --- (apt) NCZ-OS / Debian apt separation (r201), same on both architectures ---------------------------
# The installed apt configuration must keep NCZ packages and Debian packages apart: the origin pin
# file present and current, the kernel-purity pin present, exactly ONE NCZ repo enabled, a T2 repo
# covered by its pin, and the ncz-apt-policy package installed (it keeps the pin current). The audit
# itself is build/check-installed-apt-config.sh, run here on the files read out of the image.
echo "[verify-target] (apt) NCZ/Debian apt separation"
APTROOT="$TMP/aptroot"
mkdir -p "$APTROOT/etc/apt/preferences.d" "$APTROOT/etc/apt/sources.list.d"
for _f in 10-ncz-origin-separation.pref 00-ncz-kernel-purity.pref; do
    fetch "/etc/apt/preferences.d/$_f" "$APTROOT/etc/apt/preferences.d/$_f" || true
done
fetch /etc/apt/sources.list "$APTROOT/etc/apt/sources.list" || true
while IFS= read -r _n; do
    case "$_n" in *.list|*.sources) fetch "/etc/apt/sources.list.d/$_n" "$APTROOT/etc/apt/sources.list.d/$_n" || true ;; esac
done < <(lsnames /etc/apt/sources.list.d)
if _aud="$(bash "$HERE_VT/check-installed-apt-config.sh" "$APTROOT" 2>&1)"; then
    echo "[fact] apt_separation_ok=1"
else
    echo "[fact] apt_separation_ok=0"
    gate_miss apt-separation "$(printf '%s\n' "$_aud" | grep '^FAIL' | tr '\n' ';')"
fi
if fetch /var/lib/dpkg/status "$TMP/apt-status" \
   && awk '/^Package:/ {p=$2} /^Status:/ {s=$0} /^$/ {if (p=="ncz-apt-policy" && s ~ /install ok installed/) f=1; p=""; s=""} END {if (p=="ncz-apt-policy" && s ~ /install ok installed/) f=1; exit !f}' "$TMP/apt-status"; then
    :
else
    gate_miss apt-separation "ncz-apt-policy is not installed (nothing keeps the pin current)"
fi

# --- (net-fw) NIC / WiFi / Bluetooth firmware packages, arch-scoped ----------
# manifests/net-firmware.tsv maps each network driver we ship to the firmware
# package that carries its blobs. post-install/13-firmware-bom.sh installs the
# arch-scoped BOM (manifests/firmware-$ARCH.pkgs when present, else the complete
# manifests/firmware.pkgs). Assert every package in that map the TARGET ARCH
# actually ships really landed: a missing one is a dead NIC/WiFi/BT radio on
# the installed system (MS-R1 MT7922, O6N RTL8125B, T2/GU502LV iwlwifi).
# Rows whose package is deliberately not in the arch BOM (firmware-iwlwifi /
# firmware-brcm80211 / firmware-intel-graphics on arm64) are not required.
echo "[verify-target] (net-fw) network firmware packages"
NETFW_TSV="$HERE_VT/../manifests/net-firmware.tsv"
# BOM_PKGS is resolved once near the top of this script (shared with (fw-bom)).
if [ ! -f "$NETFW_TSV" ]; then
    gate_miss net-firmware "verifier checkout has no manifests/net-firmware.tsv"
elif [ ! -f "$BOM_PKGS" ]; then
    gate_miss net-firmware "verifier checkout has no manifests/firmware-$ARCH.pkgs nor firmware.pkgs"
elif ! fetch /var/lib/dpkg/status "$TMP/netfw-status"; then
    gate_miss net-firmware "/var/lib/dpkg/status"
else
    # One pass over dpkg status: every "install ok installed" package name,
    # whatever order the fields of its stanza are in.
    awk '/^Package:/ {p=$2} /^Status:/ {s=$0} /^$/ {if (s ~ /install ok installed/) print p; p=""; s=""}
         END {if (s ~ /install ok installed/) print p}' "$TMP/netfw-status" | sort -u > "$TMP/netfw-installed"
    grep -hvE '^[[:space:]]*(#|$)' "$BOM_PKGS" | awk '{print $1}' | sort -u > "$TMP/bom-pkgs"
    while IFS= read -r _p; do
        # Only firmware the target arch's BOM ships is required.
        grep -qxF -- "$_p" "$TMP/bom-pkgs" || continue
        if grep -qxF -- "$_p" "$TMP/netfw-installed"; then
            echo "[fact] net_firmware_${_p}=installed"
        else
            gate_miss net-firmware "$_p not installed (manifests/net-firmware.tsv; post-install/13-firmware-bom.sh)"
        fi
    done < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF==5 {print $3}' "$NETFW_TSV" | sort -u)
fi

# --- (fw-bom) the arch firmware BOM, plus systemd-coredump, must be really installed ------------------
# r201: 13-firmware-bom.sh's `dpkg -s` check counted "install ok not-installed" (licence preinst
# failed: firmware-ipw2x00, firmware-ivtv) as present, and 20-desktop.sh printed "systemd-coredump
# installed" after `E: Unable to locate package`. Both hooks now fail themselves; this is the
# independent check on the installed dpkg database.
echo "[verify-target] (fw-bom) firmware BOM + diagnostics packages"
if [ ! -f "$BOM_PKGS" ]; then
    gate_miss fw-bom "verifier checkout has no manifests/firmware-$ARCH.pkgs nor firmware.pkgs"
elif [ -s "$TMP/netfw-installed" ]; then
    _bom_n=0
    while IFS= read -r _p; do
        _bom_n=$((_bom_n + 1))
        grep -qxF -- "$_p" "$TMP/netfw-installed" || gate_miss fw-bom "$_p is not 'install ok installed' (manifests/firmware-$ARCH.pkgs; post-install/13-firmware-bom.sh)"
    done < <(grep -hvE '^[[:space:]]*(#|$)' "$BOM_PKGS" | awk '{print $1}' | sort -u)
    echo "[fact] firmware_bom_checked=$_bom_n"
    if [ "$V_DESKTOP" = 1 ]; then
        grep -qxF -- systemd-coredump "$TMP/netfw-installed" || gate_miss diagnostics "systemd-coredump is not installed (post-install/20-desktop.sh)"
    fi
else
    # An empty or unreadable installed-package list must FAIL, never skip the BOM check.
    gate_miss fw-bom "no installed-package list to check (empty or missing /var/lib/dpkg/status)"
fi
if [ "$ARCH" = arm64 ]; then
# --- (i) firmware ---------------------------------------------------------
FW=/usr/lib/firmware
exists "$FW" || FW=/lib/firmware
echo "[verify-target] (i) Sky1 firmware under $FW"
n=0
for f in av1dec avs2dec avsdec h264dec h264enc hevcdec hevcenc jpegdec jpegenc \
         mpeg2dec mpeg4dec vc1dec vp8dec vp8enc vp9dec vp9enc; do
    if exists "$FW/$f.fwb"; then n=$((n + 1)); else gate_miss firmware "$FW/$f.fwb"; fi
done
for f in dsp_fw.bin arm/mali/arch12.8/mali_csffw.bin; do
    exists "$FW/$f" || gate_miss firmware "$FW/$f"
done
echo "[verify-target]     .fwb present: $n/16"

# --- kernel version (newest Sky1 kernel in the image) --------------------
# The kernel this image ships and boots is recorded in KVER_NEXT (the payload's
# edge kernel). The rootfs can also carry an older/experimental Sky1 kernel from
# the baked base layer (2026-09-29: 7.3.0-rc3 next to 7.2.8), so "newest
# directory" would verify the wrong one. Fall back to newest only if KVER_NEXT
# is unreadable.
KVER=""
if fetch /usr/local/lib/cix-installer/KVER_NEXT "$TMP/KVER_NEXT"; then
    KVER="$(tr -d '[:space:]' < "$TMP/KVER_NEXT")"
    exists "/usr/lib/modules/$KVER" || { gate_miss kernel "KVER_NEXT names $KVER but /usr/lib/modules/$KVER is absent"; KVER=""; }
fi
[ -n "$KVER" ] || KVER="$(lsnames /usr/lib/modules | grep -E -- '-sky1-ncz$' | sort -V | tail -1)"
if [ -z "$KVER" ]; then
    gate_miss kernel "no *-sky1-ncz directory under /usr/lib/modules"
else
    echo "[verify-target]     installed Sky1 kernel: $KVER"
fi
MODDEP=""
if [ -n "$KVER" ] && fetch "/usr/lib/modules/$KVER/modules.dep" "$TMP/modules.dep"; then
    MODDEP="$TMP/modules.dep"
elif [ -n "$KVER" ]; then
    gate_miss kernel "/usr/lib/modules/$KVER/modules.dep (missing or empty; depmod never ran)"
fi
# modules.dep line: "<relpath>.ko[.ext]: deps"
mod_path() { [ -n "$MODDEP" ] && grep -E "(^|/)$1\.ko(\.[a-z]+)?:" "$MODDEP" | head -1 | cut -d: -f1; }

# --- (ii) NPU -------------------------------------------------------------
echo "[verify-target] (ii) NPU (aipu 6.2.0)"
exists /usr/src/aipu-6.2.0 || gate_miss npu "/usr/src/aipu-6.2.0"
exists /usr/sbin/dkms || exists /usr/bin/dkms || gate_miss npu "dkms binary"
AIPU_REL="$(mod_path aipu)"
if [ -z "$AIPU_REL" ]; then
    [ -n "$MODDEP" ] && gate_miss npu "aipu module not registered in /usr/lib/modules/$KVER/modules.dep"
else
    case "$AIPU_REL" in
        updates/*) : ;;
        *) gate_miss npu "aipu is at $AIPU_REL, not a DKMS/updates build (expected updates/dkms/aipu.ko*)" ;;
    esac
    ext="${AIPU_REL##*/}"; ext="$TMP/${ext}"
    if ! fetch "/usr/lib/modules/$KVER/$AIPU_REL" "$ext"; then
        gate_miss npu "cannot read /usr/lib/modules/$KVER/$AIPU_REL"
    elif ! ko="$(plain_module "$ext")" || [ -z "$ko" ]; then
        gate_miss npu "cannot decompress $AIPU_REL (missing xz/zstd tool)"
    else
        # The aipu module carries no MODULE_VERSION tag. Its KMD version is the
        # %s argument of the probe banner "AIPU KMD (v%s) probe start...", stored
        # as a standalone string immediately before the format string, so the
        # old generation reads "5.11.0" there and the matched one "6.2.0".
        strs="$(grep -aoE '[[:print:]]{3,}' "$ko")"
        if printf '%s\n' "$strs" | grep -A1 -xE '6\.2\.0' | grep >/dev/null 'AIPU KMD (v%s)'; then
            echo "[verify-target]     aipu $AIPU_REL KMD version 6.2.0"
        elif printf '%s\n' "$strs" | grep >/dev/null -xE '5\.11\.0'; then
            gate_miss npu "aipu $AIPU_REL is KMD 5.11.0 (old generation)"
        else
            gate_miss npu "aipu $AIPU_REL does not carry KMD version 6.2.0 before its probe banner"
        fi
        # DKMS must also hold it as built for this kernel.
        exists "/var/lib/dkms/aipu/6.2.0/$KVER" || gate_miss npu "/var/lib/dkms/aipu/6.2.0/$KVER (dkms state for the shipped kernel)"
    fi
fi

# --- (iii) VPU ------------------------------------------------------------
echo "[verify-target] (iii) VPU (amvx)"
AMVX_REL="$(mod_path amvx)"
if [ -n "$AMVX_REL" ]; then
    echo "[verify-target]     amvx module: $AMVX_REL"
elif [ -n "$MODDEP" ]; then
    gate_miss vpu "amvx module not registered in modules.dep for $KVER"
fi
# The /dev/video-cixdec0 symlink is created by the load-modules.sh helper.
if fetch /usr/bin/load-modules.sh "$TMP/load-modules.sh" && grep -q 'video-cixdec0' "$TMP/load-modules.sh"; then
    echo "[verify-target]     /usr/bin/load-modules.sh creates /dev/video-cixdec0"
else
    gate_miss vpu "/usr/bin/load-modules.sh with the video-cixdec0 symlink logic"
fi
# ffmpeg + libavcodec carrying h264_v4l2m2m.
#
# There are TWO ffmpegs, and which one exists depends on the install option set:
#   - desktop sets install the Debian `ffmpeg` package -> /usr/bin/ffmpeg and
#     /usr/lib{,64}/libavcodec.so.*
#   - headless sets (nodesktop, minimal, server/Magnetar) do NOT, but
#     post-install/83-vpu-ffmpeg.sh installs the cix-mm bundle to /opt/cix-ffmpeg
#     and wraps it as /usr/local/bin/cix-ffmpeg (bin/ + cixlib/ inside).
# Requiring the Debian package made every headless variant fail this gate even
# though its VPU userspace was correctly installed -- this was only ever visible
# once the 5-variant matrix (commit a7dbb1a3) started running nodesktop/minimal;
# before that every KVM gate run was the single hardcoded desktop set.
# Accept either, and assert the codec on whichever is actually present, because
# the real requirement is a working VPU transcode route, not a specific package.
_ffmpeg=""
for _c in /usr/bin/ffmpeg /opt/cix-ffmpeg/bin/ffmpeg; do
    if fetch "$_c" "$TMP/ncz-ffmpeg-probe"; then _ffmpeg="$_c"; break; fi
done
if [ -z "$_ffmpeg" ]; then
    gate_miss vpu "ffmpeg (neither /usr/bin/ffmpeg nor the 83-vpu-ffmpeg bundle /opt/cix-ffmpeg/bin/ffmpeg)"
else
    echo "[verify-target]     ffmpeg: $_ffmpeg"
fi
avc=""
for d in /usr/lib/aarch64-linux-gnu /usr/lib /opt/cix-ffmpeg/cixlib; do
    avc="$(lsnames $d | grep -E '^libavcodec\.so\.[0-9.]+$' | sort -V | tail -1)"
    [ -n "$avc" ] && { avc="$d/$avc"; break; }
done
if [ -z "$avc" ]; then
    gate_miss vpu "libavcodec shared library (searched system libs and /opt/cix-ffmpeg/cixlib)"
elif fetch "$avc" "$TMP/libavcodec.so" && grep -aq 'h264_v4l2m2m' "$TMP/libavcodec.so"; then
    echo "[verify-target]     $avc carries h264_v4l2m2m"
else
    gate_miss vpu "$avc without the h264_v4l2m2m codec"
fi

# --- (v-c) Sky1 serial login + installed boot cmdline ------------------------
# 36-telemetry enables the ttyAMA0 login (the O6N's only remote way in when the
# NIC does not come up). The installed rEFInd entries come from
# /usr/local/sbin/ncz-refind-refresh: they must keep the serial console with
# tty0 last, and the ACPI PCIe host mode (sky1_pcie_native=off pcie_pnp_en) the
# installer entries now share (build/iso/build-refind-esp.py SKY1_PCIE_ACPI_MODE).
echo "[verify-target] (v-c) Sky1 serial login + installed boot cmdline"
if exists /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service; then
    echo "[verify-target]     serial-getty@ttyAMA0 enabled (getty.target.wants)"
else
    gate_miss serial "serial-getty@ttyAMA0 not enabled under getty.target.wants"
fi
if fetch /usr/local/sbin/ncz-refind-refresh "$TMP/ncz-refind-refresh" \
    && grep -q '^NEXT_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0 ' "$TMP/ncz-refind-refresh" \
    && grep -q '^NEXT_CMDLINE_EXTRA=".*sky1_pcie_native=off pcie_pnp_en' "$TMP/ncz-refind-refresh"; then
    echo "[verify-target]     installed boot entries: console=ttyAMA0,115200 console=tty0 + sky1_pcie_native=off pcie_pnp_en"
else
    gate_miss serial "/usr/local/sbin/ncz-refind-refresh lacks console=ttyAMA0,115200 console=tty0 or sky1_pcie_native=off pcie_pnp_en"
fi

else
# --- (amd64) x86 target: a T2/x86 kernel is installed and no Sky1 policy leaked onto it ----------
# 36-telemetry enabled serial-getty@ttyAMA0, 85-power-perf-mode pinned the max P-state and 22-display-fix
# enabled cix-detect-display on amd64 because run-all.sh runs every hook on every architecture. Fixed
# with arch gates in the hooks; assert the RESULT on the installed system so it cannot come back.
echo "[verify-target] (amd64) x86 target"
if [ -n "$(lsnames /usr/lib/modules)" ]; then
    echo "[verify-target]     kernel module trees: $(lsnames /usr/lib/modules | tr '\n' ' ')"
else
    gate_miss kernel "no /usr/lib/modules/<kver> on the amd64 target"
fi
# --- (boot-GPU) the INSTALLED kernel must be the pinned r2 build -------------
# The KVM gate pins the INSTALLER kernel to the manifest's r2 vmlinuz and
# exports VERIFY_EXPECT_KVER / VERIFY_EXPECT_VMLINUZ_SHA256 here. Assert the
# INSTALLED /boot/vmlinuz-<kver> is that same boot-GPU-fixed r2 build (patch
# 2010). KVER alone is not enough: r1 and r2 share the release string
# 7.3.0-rc7-t2-ncz, so a stale r1 kernel on the target would pass every
# KVER-keyed check while silently bringing back the Macmini5,1 i915
# EPROBE_DEFER bug (no /dev/dri, no greetd, no error). Skipped when the pin is
# not provided (e.g. a legacy invocation), never treated as a pass.
if [ -n "${VERIFY_EXPECT_KVER:-}" ] && [ -n "${VERIFY_EXPECT_VMLINUZ_SHA256:-}" ]; then
    echo "[verify-target] (boot-GPU) installed kernel pin"
    if [ -n "$(lsnames /usr/lib/modules)" ] && ! lsnames /usr/lib/modules | grep >/dev/null -x "$VERIFY_EXPECT_KVER"; then
        gate_miss kernel "installed module tree is not the pinned $VERIFY_EXPECT_KVER (have: $(lsnames /usr/lib/modules | tr '\n' ' '))"
    fi
    if fetch "/boot/vmlinuz-$VERIFY_EXPECT_KVER" "$TMP/vmlinuz"; then
        _have_vmlinuz=$(sha256sum "$TMP/vmlinuz" | awk '{print $1}')
        if [ "$_have_vmlinuz" = "$VERIFY_EXPECT_VMLINUZ_SHA256" ]; then
            echo "[verify-target]     /boot/vmlinuz-$VERIFY_EXPECT_KVER == pinned r2 vmlinuz (2010 boot-GPU fix)"
        else
            gate_miss kernel "/boot/vmlinuz-$VERIFY_EXPECT_KVER sha256=$_have_vmlinuz != pinned $VERIFY_EXPECT_VMLINUZ_SHA256 (not the 2010 boot-GPU-fixed kernel)"
        fi
    else
        gate_miss kernel "/boot/vmlinuz-$VERIFY_EXPECT_KVER unreadable on the installed target"
    fi
fi
for leak in /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service \
            /etc/systemd/system/multi-user.target.wants/serial-getty@ttyAMA0.service \
            /etc/systemd/system/graphical.target.wants/ncz-performance-mode.service \
            /etc/systemd/system/greetd.service.d/ncz-performance-mode.conf \
            /etc/systemd/system/sysinit.target.wants/cix-detect-display.service \
            /etc/dracut.conf.d/10-ncz-sky1.conf; do
    exists "$leak" && gate_miss sky1-leak "$leak is enabled on amd64 (Sky1 policy leaked onto x86)"
done
# A greetd drop-in with Wants=/After=cix-detect-display.service pulls the disabled
# unit in on every boot (7.4 s on MacBookPro16,1, r201); 55-greeter writes it on arm64 only.
for _gd in $(lsnames /etc/systemd/system/greetd.service.d); do
    case "$_gd" in *.conf) ;; *) continue ;; esac
    if fetch "/etc/systemd/system/greetd.service.d/$_gd" "$TMP/greetd-dropin" \
       && grep -Eq '^[[:space:]]*(Wants|Requires|After)=.*cix-detect-display' "$TMP/greetd-dropin"; then
        gate_miss sky1-leak "greetd drop-in $_gd orders/pulls cix-detect-display.service on amd64"
    fi
done
fi
# --- (iv) browsers --------------------------------------------------------
echo "[verify-target] (iv) browsers"
if fetch /var/lib/dpkg/status "$TMP/dpkg-status"; then
    BROWSERS="google-chrome-stable"; [ "$ARCH" = arm64 ] && BROWSERS="$BROWSERS chromium-ncz-sky1"
    # Browsers come with the desktop option only (post-install/run-all.sh skips 52/53 without it).
    [ "$V_DESKTOP" = 1 ] || { BROWSERS=""; echo "[verify-target]     desktop not selected: no browsers expected"; }
    for pkg in $BROWSERS; do
        if awk -v p="$pkg" '
            BEGIN { RS=""; FS="\n" }
            { pk=""; st=""
              for (i = 1; i <= NF; i++) {
                  if ($i ~ /^Package: /) pk = substr($i, 10)
                  if ($i ~ /^Status: /)  st = substr($i, 9)
              }
              if (pk == p && st == "install ok installed") found = 1 }
            END { exit(found ? 0 : 1) }' "$TMP/dpkg-status"; then
            echo "[verify-target]     dpkg: $pkg installed"
        else
            gate_miss browser "$pkg (no 'install ok installed' dpkg stanza)"
        fi
    done
else
    gate_miss browser "/var/lib/dpkg/status unreadable"
fi

# --- (iv-b) first user has working sudo ------------------------------------------------
# user-setup runs `apt-get install sudo` in the target; when the media index could not
# resolve it ("Package 'sudo' has no installation candidate") the step failed and the
# first user had no sudo. Assert the package is installed and the sudo group has a member.
echo "[verify-target] (iv-b) sudo for the first user"
if awk 'BEGIN{RS="";FS="\n"} { pk=""; st=""; for(i=1;i<=NF;i++){ if($i ~ /^Package: /) pk=substr($i,10); if($i ~ /^Status: /) st=substr($i,9)} if(pk=="sudo" && st=="install ok installed") f=1 } END{exit(f?0:1)}' "$TMP/dpkg-status" 2>/dev/null; then
    if fetch /etc/group "$TMP/group" && awk -F: '$1=="sudo" && $4!="" {f=1} END{exit(f?0:1)}' "$TMP/group"; then
        SUDO_MEMBERS="$(awk -F: '$1=="sudo"{print $4}' "$TMP/group")"
        echo "[verify-target]     sudo installed; sudo group members: $SUDO_MEMBERS"
    else
        gate_miss sudo "the sudo group in /etc/group has no members (first user not added)"
    fi
else
    gate_miss sudo "sudo is not installed (user-setup could not resolve it from the media index)"
fi

# --- (iv-c) hostname: the generated IAU name, not a placeholder or a MAC-hex fallback ------
# The unattended gate install must end with ncz-<star>-<4 digits> (preseed/ncz-hostname-gen.sh).
# 18e8a14 on the O6N ended as ncz-20e7bc: the historical media preseed reload (the duplicate load was
# removed 2026-10-08) had reset netcfg/get_hostname to ncz-setup and first boot fell back to a
# MAC-derived name. Set VERIFY_EXPECT_GENERATED_HOSTNAME=0
# to skip when a run deliberately overrides the name.
echo "[verify-target] (iv-c) hostname"
if [ "${VERIFY_EXPECT_GENERATED_HOSTNAME:-1}" = 1 ]; then
    if fetch /etc/hostname "$TMP/hostname"; then
        HN="$(tr -d '[:space:]' < "$TMP/hostname")"
        if printf '%s' "$HN" | grep >/dev/null -E '^ncz-[a-z]{1,8}-[0-9]{4}$'; then
            echo "[verify-target]     hostname $HN"
        else
            gate_miss hostname "/etc/hostname is '$HN', expected ncz-<star>-<4 digits> (the installer's suggestion was lost)"
        fi
    else
        gate_miss hostname "/etc/hostname unreadable"
    fi
fi

# --- (iv-d) resolver config and hosts belong to this system ---------------------------
# The image layers carry no resolver config (strip_build_host_state truncates the
# copy the build chroot gets); the installer writes the target's own
# (preseed/extract-rootfs.sh, preseed/late.sh) and systemd-resolved or the network
# manager replaces it at boot. A REGULAR /etc/resolv.conf carrying the
# systemd-resolved stub header is a copied file, not one written for this system
# (resolved only ever writes that text under /run). /etc/hosts may name only the
# local names and this system's hostname.
echo "[verify-target] (iv-d) resolv.conf and hosts"
RCT="$(dfs "stat /etc/resolv.conf" | sed -n 's/.*Type: \([a-z]*\).*/\1/p' | head -1)"
case "$RCT" in
    symlink)
        echo "[verify-target]     /etc/resolv.conf -> $(dfs "stat /etc/resolv.conf" | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p' | head -1)" ;;
    regular)
        if fetch /etc/resolv.conf "$TMP/resolv.conf"; then
            if grep >/dev/null 'managed by man:systemd-resolved' "$TMP/resolv.conf"; then
                gate_miss resolv "/etc/resolv.conf is a regular file with the systemd-resolved stub header (a copied file)"
            elif grep >/dev/null -E '^[[:space:]]*nameserver[[:space:]]' "$TMP/resolv.conf"; then
                echo "[verify-target]     /etc/resolv.conf written for this system ($(grep -c '^[[:space:]]*nameserver' "$TMP/resolv.conf") nameserver line(s); first line: $(head -1 "$TMP/resolv.conf" | cut -c1-60))"
            else
                gate_miss resolv "/etc/resolv.conf has no nameserver line"
            fi
        else
            gate_miss resolv "/etc/resolv.conf is empty or unreadable"
        fi ;;
    *) gate_miss resolv "/etc/resolv.conf missing (type '${RCT:-none}')" ;;
esac
if fetch /etc/hosts "$TMP/hosts"; then
    [ -s "$TMP/hostname" ] || fetch /etc/hostname "$TMP/hostname" || :
    HNH="$(tr -d '[:space:]' < "$TMP/hostname" 2>/dev/null)"
    HX="$(awk '!/^[[:space:]]*#/ && NF>1 { for (i=2; i<=NF; i++) { if ($i ~ /^#/) break; print $i } }' "$TMP/hosts" \
        | grep -v -E '^(localhost|localhost\.localdomain|ip6-localhost|ip6-loopback|ip6-allnodes|ip6-allrouters|ip6-localnet|ip6-mcastprefix)$' \
        | grep -v -x -F "${HNH:-//}" | grep -v -E "^${HNH:-//}\." | tr '\n' ' ')"
    if [ -n "${HX// /}" ]; then
        gate_miss hosts "/etc/hosts names other hosts: $HX"
    else
        echo "[verify-target]     /etc/hosts names only local names and ${HNH:-this system}"
    fi
else
    gate_miss hosts "/etc/hosts unreadable"
fi

# (v) and (v-b) are desktop-layer pieces (84-vpu-mpv, 20-desktop).
if [ "$ARCH" = arm64 ] && [ "$V_DESKTOP" = 1 ]; then
# --- (v) media stack: V4L2 on the amvx VPU (VA-API is optional) -------------------
# VA-API is NOT the browser path: chromium-ncz-sky1 decodes and encodes through V4L2-M2M, and
# stock Google Chrome on arm64 has no such patches. mpv follows what is installed.
echo "[verify-target] (v) media stack (V4L2 on the VPU; VA-API optional)"
if [ -s "$TMP/load-modules.sh" ] && grep -q 'video-cixenc0' "$TMP/load-modules.sh"; then
    echo "[verify-target]     /usr/bin/load-modules.sh also creates /dev/video-cixenc0"
else
    gate_miss vpu "/usr/bin/load-modules.sh with the video-cixenc0 symlink logic (encode node)"
fi
if fetch /etc/mpv/mpv.conf "$TMP/mpv.conf" && grep -q '^hwdec=' "$TMP/mpv.conf"; then
    HW="$(grep -m1 '^hwdec=' "$TMP/mpv.conf")"
    # 2026-10-06: VA-API decode fails or hangs on 7.3 with the CIX VA
    # driver on both O6N and MS-R1, V4L2 M2M is healthy; mpv must use V4L2 whether or not the VA
    # driver is installed.
    echo "$HW" | grep >/dev/null 'v4l2m2m' || gate_miss vpu "mpv $HW (expect hwdec=v4l2m2m-copy: the VA-API decode route fails/hangs on Sky1, V4L2 M2M is the working VPU path)"
    echo "[verify-target]     mpv: $HW"
else
    gate_miss vpu "/etc/mpv/mpv.conf with a hwdec= line (84-vpu-mpv)"
fi

# --- (v-b) Sky1 audio: a real (non-dummy) sink can be created ---------------
# WirePlumber ACP cannot expose the Sky1 card (UCM HiFi probes all 3 DP PCMs and
# is dropped when any connector has no monitor), so the autoswitch user service
# is the only thing that creates a real sink. Regression 2026-09-29 (image
# 28a868c): 20-desktop.sh looked only under /cdrom, installed nothing, and the
# desktop showed only "Dummy Output".
echo "[verify-target] (v-b) Sky1 HDMI/DP audio autoswitch"
exists /usr/local/bin/ncz-sky1-audio-autoswitch || gate_miss audio "/usr/local/bin/ncz-sky1-audio-autoswitch (20-desktop did not install it)"
exists /etc/systemd/user/ncz-sky1-audio-autoswitch.service || gate_miss audio "/etc/systemd/user/ncz-sky1-audio-autoswitch.service"
exists /usr/bin/pactl || gate_miss audio "/usr/bin/pactl (pulseaudio-utils; the autoswitch daemon needs it)"
# the installed daemon must be the multi-board one (analog fallback for boards with
# the cix-ipbloq-hda card, e.g. MS-R1), not the DP-only first version
if fetch /usr/local/bin/ncz-sky1-audio-autoswitch "$TMP/audsw.py"; then
    grep -q '^def analog_device(' "$TMP/audsw.py" && grep -q '^def hda_cards(' "$TMP/audsw.py" || gate_miss audio "installed ncz-sky1-audio-autoswitch lacks the HDA analog fallback (MS-R1 would have no sink)"
fi
audsw=0
for w in $(lsnames /etc/systemd/user | grep '\.wants$'); do
    lsnames "/etc/systemd/user/$w" | grep >/dev/null -x 'ncz-sky1-audio-autoswitch.service' && audsw=1
done
[ "$audsw" = 1 ] || gate_miss audio "ncz-sky1-audio-autoswitch.service is not enabled (no .wants symlink under /etc/systemd/user)"

fi
# (vii) .. (vi) check the desktop layer; they run only when the desktop was selected.
if [ "$V_DESKTOP" = 1 ]; then
# --- (vii) Bing wallpaper prefetch (helper, user units, patched plugin) -----------------------
# LEAD 4's fix: the helper prefetches at login (no jitter) and daily; the Settings plugin gained a
# "Preferred market" row. Assert the helper, the three units (enabled for users) and that the
# wallpapers-bing plugin .so is the PATCHED build (its settings string is in the binary). The helper's
# `fetch --if-stale` smoke run (exit 0 or 75) is checked from the first-boot report by the gate.
echo "[verify-target] (vii) Bing wallpaper prefetch"
exists /usr/local/bin/ncz-wallpaper-bing || gate_miss wallpaper "/usr/local/bin/ncz-wallpaper-bing"
exists /usr/local/bin/singularity-wallpaper-bing || gate_miss wallpaper "/usr/local/bin/singularity-wallpaper-bing"
exists /usr/local/bin/ncz-wallpaper-ocs || gate_miss wallpaper "/usr/local/bin/ncz-wallpaper-ocs"
exists /usr/local/bin/singularity-wallpaper-ocs || gate_miss wallpaper "/usr/local/bin/singularity-wallpaper-ocs"
for u in ncz-wallpaper-bing.service ncz-wallpaper-bing.timer ncz-wallpaper-bing-daily.timer; do
    exists "/usr/lib/systemd/user/$u" || gate_miss wallpaper "/usr/lib/systemd/user/$u"
done
for t in ncz-wallpaper-bing.timer ncz-wallpaper-bing-daily.timer; do
    en=0
    for w in $(lsnames /etc/systemd/user | grep '\.wants$'); do
        lsnames "/etc/systemd/user/$w" | grep >/dev/null -x "$t" && en=1
    done
    [ "$en" = 1 ] || gate_miss wallpaper "$t is not enabled for users (no .wants symlink under /etc/systemd/user)"
done
WSO=/opt/singularity/lib/singularity/plugins/wallpapers-bing/libwallpapers-bing.so
if fetch "$WSO" "$TMP/libwallpapers-bing.so"; then
    if grep -aq 'Bing Preferred Region' "$TMP/libwallpapers-bing.so"; then
        echo "[verify-target]     wallpapers-bing plugin is the patched build (Bing Preferred Region row)"
        BING_PATCHED=1
    else
        gate_miss wallpaper "$WSO does not contain 'Bing Preferred Region' (stale, unpatched plugin build)"
    fi
else
    gate_miss wallpaper "$WSO (plugin missing)"
fi

# --- (viii) sensors plugin carries the adaptive-contrast code -----------------------------------
# 0005-sensors-adaptive-contrast.patch adds sensors/contrast.vala; its compiled symbols are in the
# plugin. A plugin without them is a stale/unpatched build.
echo "[verify-target] (viii) sensors plugin"
SSO=/opt/singularity/lib/singularity/plugins/sensors/libsensors.so
if fetch "$SSO" "$TMP/libsensors.so"; then
    if grep -aq 'sensors_contrast_ensure_contrast' "$TMP/libsensors.so"; then
        echo "[verify-target]     libsensors.so contains the adaptive-contrast code"
        SENSORS_PATCHED=1
    else
        gate_miss sensors "$SSO has no sensors_contrast_* symbols (stale, unpatched plugin build)"
    fi
else
    gate_miss sensors "$SSO (plugin missing)"
fi

# --- (ix) NCZ-OS tour slides (post-install/51-ncz-tour-slides.sh) ------------------------------
# The desktop tour (dev.sinty.tour) is data-driven: ten upstream slides in
# /opt/singularity/share/singularity/tour/ plus NCZ slides this project adds. Four
# are on every desktop (wallpapers, online wallpapers, screensavers, lock screen);
# 85-ncz-chromium-vpu.slide (the NCZ Chromium VPU slide) is arm64/Sky1 only, since
# only arm64 ships chromium-ncz-sky1. Assert the four always, require the fifth on
# arm64 and forbid it on amd64 -- so a hook that silently skipped is caught, and a
# Sky1-only slide can never leak into an amd64 image.
echo "[verify-target] (ix) NCZ tour slides"
TOURDIR=/opt/singularity/share/singularity/tour
for s in 55-ncz-wallpapers 56-ncz-online-wallpapers 65-ncz-screensavers 75-ncz-lock; do
    exists "$TOURDIR/$s.slide" || gate_miss tour-slides "$TOURDIR/$s.slide (post-install/51-ncz-tour-slides.sh)"
done
if [ "$ARCH" = arm64 ]; then
    exists "$TOURDIR/85-ncz-chromium-vpu.slide" || gate_miss tour-slides "$TOURDIR/85-ncz-chromium-vpu.slide (arm64 NCZ Chromium VPU slide; post-install/51-ncz-tour-slides.sh)"
else
    exists "$TOURDIR/85-ncz-chromium-vpu.slide" && gate_miss tour-slides "$TOURDIR/85-ncz-chromium-vpu.slide leaked onto amd64 (the NCZ Chromium VPU slide is Sky1-only)"
fi

# --- (ixa) NCZ first-login tour (post-install/51-ncz-tour-slides.sh + 20-desktop.sh) ----------
# The tour opens once from a guarded autostart entry the installer drops. Assert
# the entry + guard are present, the entry names Singularity in OnlyShowIn (the
# shipped shell's AutostartManager only launches a SYSTEM /etc/xdg/autostart
# entry that does), the guard keeps its marker under a user-writable XDG state
# dir, and the upstream unconditional switch is off (so the two never race).
echo "[verify-target] (ixa) NCZ first-login tour"
exists /usr/local/bin/ncz-first-login-tour || gate_miss first-login-tour "/usr/local/bin/ncz-first-login-tour (post-install/51-ncz-tour-slides.sh)"
if fetch /etc/xdg/autostart/ncz-first-login-tour.desktop "$TMP/tour.desktop"; then
    grep -q '^OnlyShowIn=Singularity;$' "$TMP/tour.desktop" || gate_miss first-login-tour "autostart entry lacks OnlyShowIn=Singularity (the shell would never launch it)"
    grep -q '^Exec=/usr/local/bin/ncz-first-login-tour show$' "$TMP/tour.desktop" || gate_miss first-login-tour "autostart entry Exec does not run the guard"
else
    gate_miss first-login-tour "/etc/xdg/autostart/ncz-first-login-tour.desktop (post-install/51-ncz-tour-slides.sh)"
fi
if fetch /usr/local/bin/ncz-first-login-tour "$TMP/tourguard"; then
    grep -q 'XDG_STATE_HOME' "$TMP/tourguard" || gate_miss first-login-tour "guard has no user XDG state marker path"
    grep -q '\.local/state' "$TMP/tourguard" || gate_miss first-login-tour "guard marker is not under a user-writable state dir"
else
    gate_miss first-login-tour "/usr/local/bin/ncz-first-login-tour is unreadable"
fi
if fetch /opt/singularity/share/glib-2.0/schemas/99-ncz-defaults.gschema.override "$TMP/ncz.gschema.override"; then
    grep -q '^show-tour=false$' "$TMP/ncz.gschema.override" || gate_miss first-login-tour "upstream first-run switch is not disabled (show-tour=false missing): the shell would open the tour unguarded"
fi

# --- (vi) ncz-screensavers (mandatory on desktop images; 2026-10-05) ---------
# The checks live in verify-installed-target-screensavers.sh (sourced so
# SS_STATUS / SS_PLUGIN remain in this shell for the [fact] lines below).
# Split out so this file's review hunk stays under 9000 bytes.
SS_STATUS=""; SS_PLUGIN=""
# shellcheck source=./verify-installed-target-screensavers.sh
. "$HERE_VT/verify-installed-target-screensavers.sh"
else
    echo "[verify-target] (vii)-(vi) desktop not selected: wallpaper, sensors, tour and screensaver checks do not apply"
fi

if [ "$ARCH" = arm64 ]; then
# --- (info) VA-API ---------------------------------------------------------
va=""
for d in /usr/lib/aarch64-linux-gnu/dri /usr/lib/dri; do
    va="$va $(lsnames $d | grep -E '_drv_video\.so$' | tr '\n' ' ')"
done
echo "[verify-target] (info) VA-API drivers:${va:- none}"

fi

# --- (gpu) never-software-render policy, both architectures -------------------------------------------
# A machine with a GPU must not render in software. Assert the pieces that enforce it are on the target: the shared
# hardware probe, the --require-hardware health check + its boot unit, the ncz-gpu-env refusal (no unconditional
# software branch), the labwc-session overlay patch (no software retry with a GPU), and on Sky1 the system-wide Mali
# EGL vendor (so processes without the compositor's environment do not fall back to llvmpipe).
echo "[verify-target] (gpu) never-software-render"
GPU_OK=1
exists /usr/local/bin/ncz-gpu-hw-present || { gate_miss gpu "/usr/local/bin/ncz-gpu-hw-present (98-gpu-health.sh)"; GPU_OK=0; }
if fetch /usr/bin/ncz-gpu-status "$TMP/gpustatus"; then
    grep -q -- '--require-hardware' "$TMP/gpustatus" || { gate_miss gpu "ncz-gpu-status lacks --require-hardware"; GPU_OK=0; }
else gate_miss gpu "/usr/bin/ncz-gpu-status"; GPU_OK=0; fi
exists /etc/systemd/system/multi-user.target.wants/ncz-gpu-health.service || { gate_miss gpu "ncz-gpu-health.service is not enabled"; GPU_OK=0; }
# ncz-gpu-env and the labwc session belong to the desktop layer (20-desktop.sh).
if [ "$V_DESKTOP" = 1 ]; then
if fetch /usr/local/bin/ncz-gpu-env "$TMP/gpuenv"; then
    grep -q 'NCZ_ALLOW_SOFTWARE_FALLBACK' "$TMP/gpuenv" || { gate_miss gpu "ncz-gpu-env has no software-refusal guard"; GPU_OK=0; }
else gate_miss gpu "/usr/local/bin/ncz-gpu-env"; GPU_OK=0; fi
if fetch /opt/singularity/bin/singularity-labwc-session "$TMP/labwcsession"; then
    grep -q 'hw_render_device_present' "$TMP/labwcsession" || { gate_miss gpu "singularity-labwc-session still retries with software rendering on a GPU machine (overlay patch not applied)"; GPU_OK=0; }
else gate_miss gpu "/opt/singularity/bin/singularity-labwc-session"; GPU_OK=0; fi
fi
if [ "$ARCH" = arm64 ]; then
    if exists /opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json; then
        exists /etc/glvnd/egl_vendor.d/10_cix.json || { gate_miss gpu "/etc/glvnd/egl_vendor.d/10_cix.json (Mali EGL vendor not registered system-wide: any process without the compositor environment renders in llvmpipe)"; GPU_OK=0; }
    fi
else
    exists /etc/glvnd/egl_vendor.d/10_cix.json && { gate_miss gpu "Mali EGL vendor entry leaked onto amd64"; GPU_OK=0; }
fi

# --- (ssh) LAN password login stays possible (policy 2026-09-29: every host reachable by password) ------
# sshd uses the FIRST value it sees for a keyword. Rebuild the effective config from /etc/ssh/sshd_config with its
# Include lines expanded in place (drop-ins sort lexically), then require PasswordAuthentication yes. A key-only or
# keyboard-interactive-only setup would lock out `sshpass` and remote scripts.
echo "[verify-target] (ssh) sshd effective config"
SSH_EFF=""
if fetch /etc/ssh/sshd_config "$TMP/sshd_config"; then
    while IFS= read -r _l; do
        case "$_l" in
            [Ii]nclude*sshd_config.d*)
                for _n in $(lsnames /etc/ssh/sshd_config.d | grep '\.conf$' | LC_ALL=C sort); do
                    fetch "/etc/ssh/sshd_config.d/$_n" "$TMP/sshd_dropin" && SSH_EFF="$SSH_EFF
$(cat "$TMP/sshd_dropin")"
                done ;;
            *) SSH_EFF="$SSH_EFF
$_l" ;;
        esac
    done < "$TMP/sshd_config"
    _pa="$(printf '%s\n' "$SSH_EFF" | awk 'tolower($1)=="passwordauthentication" {print tolower($2); exit}')"
    _ki="$(printf '%s\n' "$SSH_EFF" | awk 'tolower($1)=="kbdinteractiveauthentication" {print tolower($2); exit}')"
    case "$_pa" in
        yes) echo "[verify-target]     PasswordAuthentication yes (kbd-interactive: ${_ki:-default})"; SSH_PW_OK=1 ;;
        "")  gate_miss ssh "sshd sets no PasswordAuthentication and the Debian default is not asserted; set it to yes (35-ssh.sh)"; SSH_PW_OK=0 ;;
        *)   gate_miss ssh "effective PasswordAuthentication is '$_pa': LAN tooling needs password login (sshpass)"; SSH_PW_OK=0 ;;
    esac
else
    gate_miss ssh "/etc/ssh/sshd_config"; SSH_PW_OK=0
fi

echo "[fact] arch=$ARCH"
echo "[fact] gpu_policy_ok=${GPU_OK:-0}"
echo "[fact] ssh_password_ok=${SSH_PW_OK:-0}"
echo "[fact] hostname_format_ok=$([ -n "${HN:-}" ] && printf '%s' "$HN" | grep >/dev/null -E '^ncz-[a-z]{1,8}-[0-9]{4}$' && echo 1 || echo 0)"
echo "[fact] sudo_ok=$([ -n "${SUDO_MEMBERS:-}" ] && echo 1 || echo 0)"
echo "[fact] screensavers_version=${SS_STATUS:-none}"
echo "[fact] screensaver_plugin_version=${SS_PLUGIN:-none}"
# ncz-screensavers-plugin is a separate package (pinned deb on the install
# medium); the engine deb ships no plugin files.
# Report the plugin package's version when it is installed, "none" otherwise.
# Emitted as a fact either way because build/verify-dual-arch-parity.sh
# compares this line across arches.
echo "[fact] bing_plugin_patched=${BING_PATCHED:-0}"
echo "[fact] sensors_plugin_patched=${SENSORS_PATCHED:-0}"
if [ "$FAIL" -ne 0 ]; then
    echo "GATE: $ARCH installed-target check FAILED (see GATE: lines above)" >&2
    exit 1
fi
echo "[verify-target] OK: $ARCH installed-target artifacts present"
exit 0
