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
# COMMON sections run for both architectures; Sky1 (arm64) sections only for arm64; the amd64
# section also proves no Sky1 policy leaked onto x86 (the cause of the T2 boot hangs). Every run
# prints machine-readable '[fact] key=value' lines that build/verify-dual-arch-parity.sh compares.
# Exit:  0 all required artifacts present, 1 at least one missing (every miss
#        is printed as "GATE: missing [class]: what"), 2 bad invocation.
set -uo pipefail

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

# debugfs prints "<path>: File not found by ext2_lookup" (rc stays 0) for a
# missing path and an "Inode:" line for a present one. Key on the positive
# marker; never on the absence of an error string.
dfs() { "$DEBUGFS" -R "$1" "$EVIDENCE_ROOT" 2>&1; }
exists() { dfs "stat $1" | grep -q '^Inode:'; }
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
        if printf '%s\n' "$strs" | grep -A1 -xE '6\.2\.0' | grep -q 'AIPU KMD (v%s)'; then
            echo "[verify-target]     aipu $AIPU_REL KMD version 6.2.0"
        elif printf '%s\n' "$strs" | grep -qxE '5\.11\.0'; then
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
exists /usr/bin/ffmpeg || gate_miss vpu "/usr/bin/ffmpeg"
avc=""
for d in /usr/lib/aarch64-linux-gnu /usr/lib; do
    avc="$(lsnames $d | grep -E '^libavcodec\.so\.[0-9.]+$' | sort -V | tail -1)"
    [ -n "$avc" ] && { avc="$d/$avc"; break; }
done
if [ -z "$avc" ]; then
    gate_miss vpu "libavcodec shared library"
elif fetch "$avc" "$TMP/libavcodec.so" && grep -aq 'h264_v4l2m2m' "$TMP/libavcodec.so"; then
    echo "[verify-target]     $avc carries h264_v4l2m2m"
else
    gate_miss vpu "$avc without the h264_v4l2m2m codec"
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
for leak in /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service \
            /etc/systemd/system/multi-user.target.wants/serial-getty@ttyAMA0.service \
            /etc/systemd/system/graphical.target.wants/ncz-performance-mode.service \
            /etc/systemd/system/sysinit.target.wants/cix-detect-display.service \
            /etc/dracut.conf.d/10-ncz-sky1.conf; do
    exists "$leak" && gate_miss sky1-leak "$leak is enabled on amd64 (Sky1 policy leaked onto x86)"
done
fi
# --- (iv) browsers --------------------------------------------------------
echo "[verify-target] (iv) browsers"
if fetch /var/lib/dpkg/status "$TMP/dpkg-status"; then
    BROWSERS="google-chrome-stable"; [ "$ARCH" = arm64 ] && BROWSERS="$BROWSERS chromium-ncz-sky1"
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
# 18e8a14 on the O6N ended as ncz-20e7bc: the media preseed reload had reset netcfg/get_hostname to
# ncz-setup and first boot fell back to a MAC-derived name. Set VERIFY_EXPECT_GENERATED_HOSTNAME=0
# to skip when a run deliberately overrides the name.
echo "[verify-target] (iv-c) hostname"
if [ "${VERIFY_EXPECT_GENERATED_HOSTNAME:-1}" = 1 ]; then
    if fetch /etc/hostname "$TMP/hostname"; then
        HN="$(tr -d '[:space:]' < "$TMP/hostname")"
        if printf '%s' "$HN" | grep -Eq '^ncz-[a-z]{1,8}-[0-9]{4}$'; then
            echo "[verify-target]     hostname $HN"
        else
            gate_miss hostname "/etc/hostname is '$HN', expected ncz-<star>-<4 digits> (the installer's suggestion was lost)"
        fi
    else
        gate_miss hostname "/etc/hostname unreadable"
    fi
fi

if [ "$ARCH" = arm64 ]; then
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
    if exists /usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so; then
        echo "$HW" | grep -q 'vaapi' || gate_miss vpu "mpv $HW although the CIX VA driver is installed"
    else
        echo "$HW" | grep -q 'v4l2m2m' || gate_miss vpu "mpv $HW but no VA driver is installed (mpv would silently fall back to software; expect hwdec=v4l2m2m-copy)"
    fi
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
    lsnames "/etc/systemd/user/$w" | grep -qx 'ncz-sky1-audio-autoswitch.service' && audsw=1
done
[ "$audsw" = 1 ] || gate_miss audio "ncz-sky1-audio-autoswitch.service is not enabled (no .wants symlink under /etc/systemd/user)"

fi
# --- (vii) Bing wallpaper prefetch (helper, user units, patched plugin) -----------------------
# LEAD 4's fix: the helper prefetches at login (no jitter) and daily; the Settings plugin gained a
# "Preferred market" row. Assert the helper, the three units (enabled for users) and that the
# wallpapers-bing plugin .so is the PATCHED build (its settings string is in the binary). The helper's
# `fetch --if-stale` smoke run (exit 0 or 75) is checked from the first-boot report by the gate.
echo "[verify-target] (vii) Bing wallpaper prefetch"
exists /usr/local/bin/ncz-wallpaper-bing || gate_miss wallpaper "/usr/local/bin/ncz-wallpaper-bing"
for u in ncz-wallpaper-bing.service ncz-wallpaper-bing.timer ncz-wallpaper-bing-daily.timer; do
    exists "/usr/lib/systemd/user/$u" || gate_miss wallpaper "/usr/lib/systemd/user/$u"
done
for t in ncz-wallpaper-bing.timer ncz-wallpaper-bing-daily.timer; do
    en=0
    for w in $(lsnames /etc/systemd/user | grep '\.wants$'); do
        lsnames "/etc/systemd/user/$w" | grep -qx "$t" && en=1
    done
    [ "$en" = 1 ] || gate_miss wallpaper "$t is not enabled for users (no .wants symlink under /etc/systemd/user)"
done
WSO=/opt/singularity/lib/singularity/plugins/wallpapers-bing/libwallpapers-bing.so
if fetch "$WSO" "$TMP/libwallpapers-bing.so"; then
    if grep -aq 'Preferred market' "$TMP/libwallpapers-bing.so"; then
        echo "[verify-target]     wallpapers-bing plugin is the patched build (Preferred market row)"
        BING_PATCHED=1
    else
        gate_miss wallpaper "$WSO does not contain 'Preferred market' (stale, unpatched plugin build)"
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

# --- (vi) ncz-screensavers (only when this image is meant to ship it) ---------
# The image records that intent in its own payload: manifests/install-extra.pkgs.
# Intent, in order: VERIFY_EXPECT_SCREENSAVERS=1|0 from the caller (the gate sets it from the
# checkout's manifests/install-extra.pkgs); else auto = the target's own manifest asks for it or
# the package is already present in its dpkg database. A silent skip here once hid a missing
# assertion, so "not requested" is only reachable when nothing points at the package.
WANT_SS="${VERIFY_EXPECT_SCREENSAVERS:-auto}"
if [ "$WANT_SS" = auto ]; then
    WANT_SS=0
    if fetch /usr/local/lib/cix-installer/manifests/install-extra.pkgs "$TMP/extra.pkgs" && sed 's/#.*//' "$TMP/extra.pkgs" | awk 'NF {print $1}' | grep -qx ncz-screensavers; then WANT_SS=1; fi
    grep -q '^Package: ncz-screensavers$' "$TMP/dpkg-status" 2>/dev/null && WANT_SS=1
fi
if [ "$WANT_SS" = 1 ]; then
    echo "[verify-target] (vi) ncz-screensavers"
    SS_STATUS="$(awk 'BEGIN{RS="";FS="\n"} { pk=""; st=""; ver=""; for(i=1;i<=NF;i++){ if($i ~ /^Package: /) pk=substr($i,10); if($i ~ /^Status: /) st=substr($i,9); if($i ~ /^Version: /) ver=substr($i,10)} if(pk=="ncz-screensavers" && st=="install ok installed") print ver }' "$TMP/dpkg-status" 2>/dev/null)"
    if [ -z "$SS_STATUS" ]; then
        gate_miss screensavers "ncz-screensavers is not installed (59-ncz-screensavers-pkg did not install it)"
    else
        echo "[verify-target]     ncz-screensavers $SS_STATUS installed"
        for f in /usr/bin/ncz-screensaver /usr/libexec/ncz-screensaver-idled /usr/libexec/ncz-screensaver-run \
                 /usr/lib/systemd/user/ncz-screensaver-idled.service /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml \
                 /usr/share/ncz-screensavers/hacks.tsv; do
            exists "$f" || gate_miss screensavers "$f"
        done
        # 0.7: the engine ships NO settings app, desktop entry or icon -- the Singularity plugin is the only UX
        if fetch /var/lib/dpkg/info/ncz-screensavers.list "$TMP/ss.list"; then
            if grep -Eq 'ncz-screensaver-settings|\.desktop$|/icons/' "$TMP/ss.list"; then
                gate_miss screensavers "ncz-screensavers still ships a settings app / desktop entry / icon: $(grep -E 'ncz-screensaver-settings|\.desktop$|/icons/' "$TMP/ss.list" | head -2 | tr '\n' ' ')"
            fi
        else
            gate_miss screensavers "/var/lib/dpkg/info/ncz-screensavers.list (cannot prove the package has no settings app)"
        fi
        for f in /usr/bin/ncz-screensaver-settings /usr/share/applications/ncz-screensaver-settings.desktop; do
            exists "$f" && gate_miss screensavers "$f exists (the plugin is the only screensaver UX)"
        done
        # the Singularity plugin: installed, files present, 'screensaver' enabled by default via the gschema override
        SS_PLUGIN="$(awk 'BEGIN{RS="";FS="\n"} { pk=""; st=""; ver=""; for(i=1;i<=NF;i++){ if($i ~ /^Package: /) pk=substr($i,10); if($i ~ /^Status: /) st=substr($i,9); if($i ~ /^Version: /) ver=substr($i,10)} if(pk=="ncz-screensavers-plugin" && st=="install ok installed") print ver }' "$TMP/dpkg-status" 2>/dev/null)"
        if [ -z "$SS_PLUGIN" ]; then
            gate_miss screensavers "ncz-screensavers-plugin is not installed (59-ncz-screensavers-pkg did not install it)"
        else
            echo "[verify-target]     ncz-screensavers-plugin $SS_PLUGIN installed"
            for f in /opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so /opt/singularity/lib/singularity/plugins/screensaver/screensaver.plugin; do
                exists "$f" || gate_miss screensavers "$f"
            done
            if fetch /opt/singularity/share/glib-2.0/schemas/99-zz-ncz-screensaver-plugin.gschema.override "$TMP/ss-override" && grep -q "^enabled-plugins=.*'screensaver'" "$TMP/ss-override"; then :; else
                gate_miss screensavers "the default enabled-plugins does not contain 'screensaver' (99-zz-ncz-screensaver-plugin.gschema.override missing or wrong)"
            fi
        fi
        # the GTK4 reference app is for OTHER distros
        grep -q '^Package: ncz-screensavers-gtk4-reference$' "$TMP/dpkg-status" 2>/dev/null && gate_miss screensavers "ncz-screensavers-gtk4-reference is installed on NCZ-OS (it must not be)"
        NHACK="$(lsnames /usr/lib/ncz-screensavers | grep -c '_gles3$')"
        [ "$NHACK" -ge 84 ] && echo "[verify-target]     hack binaries: $NHACK" || gate_miss screensavers "only $NHACK *_gles3 hack binaries in /usr/lib/ncz-screensavers (need 84)"
        # the schema must be compiled into gschemas.compiled or the settings UI and idle timer cannot read it
        if fetch /usr/share/glib-2.0/schemas/gschemas.compiled "$TMP/gschemas.compiled" && grep -aq 'dev.ncz.screensaver' "$TMP/gschemas.compiled"; then :; else gate_miss screensavers "dev.ncz.screensaver missing from gschemas.compiled (glib-compile-schemas did not run)"; fi
        # the idle timer is enabled, and the older swayidle idle manager is NOT (they would both lock the session)
        idled=0; oldidle=0
        for w in $(lsnames /etc/systemd/user | grep '\.wants$'); do
            lsnames "/etc/systemd/user/$w" | grep -qx 'ncz-screensaver-idled.service' && idled=1
            lsnames "/etc/systemd/user/$w" | grep -qx 'ncz-idle-manager.service' && oldidle=1
        done
        [ "$idled" = 1 ] || gate_miss screensavers "ncz-screensaver-idled.service is not enabled (no .wants symlink under /etc/systemd/user)"
        [ "$oldidle" = 0 ] || gate_miss screensavers "ncz-idle-manager.service is still enabled next to ncz-screensaver-idled"

        # A (O6N 2026-10-04): /opt/singularity is also owned by the wallpaper
        # packs. A payload swap with an opaque /opt/singularity overlay dropped
        # their collection/artistpack files even though dpkg still listed the
        # packages installed. Assert them explicitly; the dpkg -V ownership gate
        # (build/verify-singularity-opt-owners.sh) covers the full set on a
        # mounted root.
        WCOL=/opt/singularity/share/singularity/wallpaper-collections
        for pack in ncz cygnus-2610 singularity brandon-perlow alex-jay-brady; do
            exists "$WCOL/$pack.collection" || gate_miss wallpaper "$WCOL/$pack.collection (payload swap dropped the pack)"
            exists "$WCOL/$pack.artistpack/artist.json" || gate_miss wallpaper "$WCOL/$pack.artistpack/artist.json (payload swap dropped the pack)"
            exists "$WCOL/$pack.artistpack/pack.json" || gate_miss wallpaper "$WCOL/$pack.artistpack/pack.json (payload swap dropped the pack)"
        done

        # B (O6N 2026-10-04): the shell sets GSETTINGS_SCHEMA_DIR to
        # /opt/singularity/share/glib-2.0/schemas, so THAT gschemas.compiled is
        # what it reads. Compare its effective dev.sinty.desktop defaults with a
        # fresh compile of the same dumped inputs; a stale compiled file fails.
        SSD=/opt/singularity/share/glib-2.0/schemas
        if command -v glib-compile-schemas >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1; then
            if exists "$SSD/gschemas.compiled"; then
                SGT="$TMP/sinty-schemas"; mkdir -p "$SGT/installed" "$SGT/fresh"
                fetch "$SSD/gschemas.compiled" "$SGT/installed/gschemas.compiled" || true
                for n in $(lsnames "$SSD"); do
                    case "$n" in
                        *.gschema.xml|*.gschema.override) fetch "$SSD/$n" "$SGT/fresh/$n" || true ;;
                    esac
                done
                if [ -s "$SGT/installed/gschemas.compiled" ]; then
                    if glib-compile-schemas --strict "$SGT/fresh" >/dev/null 2>&1; then
                        for k in pinned-apps enabled-plugins; do
                            iv="$(GSETTINGS_SCHEMA_DIR="$SGT/installed" GSETTINGS_BACKEND=memory gsettings get dev.sinty.desktop "$k" 2>/dev/null)"
                            fv="$(GSETTINGS_SCHEMA_DIR="$SGT/fresh" GSETTINGS_BACKEND=memory gsettings get dev.sinty.desktop "$k" 2>/dev/null)"
                            if [ "$iv" != "$fv" ] && { [ -n "$iv" ] || [ -n "$fv" ]; }; then
                                gate_miss schemas "dev.sinty.desktop $k stale: installed=${iv:-<absent>} fresh=${fv:-<absent>} (gschemas.compiled under /opt/singularity predates its overrides)"
                            fi
                        done
                    else
                        gate_miss schemas "dumped /opt/singularity schema inputs do not compile --strict"
                    fi
                else
                    gate_miss schemas "$SSD/gschemas.compiled could not be read (the shell reads this file)"
                fi
            else
                gate_miss schemas "$SSD/gschemas.compiled missing (the shell reads this file, not /usr/share)"
            fi
        fi
    fi
else
    echo "[verify-target] (vi) ncz-screensavers not requested by this image; skipped"
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
if fetch /usr/local/bin/ncz-gpu-env "$TMP/gpuenv"; then
    grep -q 'NCZ_ALLOW_SOFTWARE_FALLBACK' "$TMP/gpuenv" || { gate_miss gpu "ncz-gpu-env has no software-refusal guard"; GPU_OK=0; }
else gate_miss gpu "/usr/local/bin/ncz-gpu-env"; GPU_OK=0; fi
if fetch /opt/singularity/bin/singularity-labwc-session "$TMP/labwcsession"; then
    grep -q 'hw_render_device_present' "$TMP/labwcsession" || { gate_miss gpu "singularity-labwc-session still retries with software rendering on a GPU machine (overlay patch not applied)"; GPU_OK=0; }
else gate_miss gpu "/opt/singularity/bin/singularity-labwc-session"; GPU_OK=0; fi
if [ "$ARCH" = arm64 ]; then
    if exists /opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json; then
        exists /etc/glvnd/egl_vendor.d/10_cix.json || { gate_miss gpu "/etc/glvnd/egl_vendor.d/10_cix.json (Mali EGL vendor not registered system-wide: any process without the compositor environment renders in llvmpipe)"; GPU_OK=0; }
    fi
else
    exists /etc/glvnd/egl_vendor.d/10_cix.json && { gate_miss gpu "Mali EGL vendor entry leaked onto amd64"; GPU_OK=0; }
fi

# --- (ssh) LAN password login stays possible (operator policy 2026-09-29: every host reachable by password) ------
# sshd uses the FIRST value it sees for a keyword. Rebuild the effective config from /etc/ssh/sshd_config with its
# Include lines expanded in place (drop-ins sort lexically), then require PasswordAuthentication yes. A key-only or
# keyboard-interactive-only setup would lock out `sshpass` and the fleet scripts.
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
        *)   gate_miss ssh "effective PasswordAuthentication is '$_pa': the LAN fleet needs password login (sshpass)"; SSH_PW_OK=0 ;;
    esac
else
    gate_miss ssh "/etc/ssh/sshd_config"; SSH_PW_OK=0
fi

echo "[fact] arch=$ARCH"
echo "[fact] gpu_policy_ok=${GPU_OK:-0}"
echo "[fact] ssh_password_ok=${SSH_PW_OK:-0}"
echo "[fact] hostname_format_ok=$([ -n "${HN:-}" ] && printf '%s' "$HN" | grep -Eq '^ncz-[a-z]{1,8}-[0-9]{4}$' && echo 1 || echo 0)"
echo "[fact] sudo_ok=$([ -n "${SUDO_MEMBERS:-}" ] && echo 1 || echo 0)"
echo "[fact] screensavers_version=${SS_STATUS:-none}"
echo "[fact] screensaver_plugin_version=${SS_PLUGIN:-none}"
echo "[fact] bing_plugin_patched=${BING_PATCHED:-0}"
echo "[fact] sensors_plugin_patched=${SENSORS_PATCHED:-0}"
if [ "$FAIL" -ne 0 ]; then
    echo "GATE: $ARCH installed-target check FAILED (see GATE: lines above)" >&2
    exit 1
fi
echo "[verify-target] OK: $ARCH installed-target artifacts present"
exit 0
