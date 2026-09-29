#!/bin/bash
# verify-installed-target-arm64.sh -- assert the INSTALLED target rootfs
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
# Usage: verify-installed-target-arm64.sh <EVIDENCE_ROOT_RAW> <DEBUGFS>
# Exit:  0 all required artifacts present, 1 at least one missing (every miss
#        is printed as "GATE: missing [class]: what"), 2 bad invocation.
set -uo pipefail

EVIDENCE_ROOT="${1:?usage: verify-installed-target-arm64.sh EVIDENCE_ROOT_RAW DEBUGFS}"
DEBUGFS="${2:?usage: verify-installed-target-arm64.sh EVIDENCE_ROOT_RAW DEBUGFS}"
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

# --- (iv) browsers --------------------------------------------------------
echo "[verify-target] (iv) browsers"
if fetch /var/lib/dpkg/status "$TMP/dpkg-status"; then
    for pkg in google-chrome-stable chromium-ncz-sky1; do
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
        echo "[verify-target]     sudo installed; sudo group members: $(awk -F: '$1=="sudo"{print $4}' "$TMP/group")"
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
audsw=0
for w in $(lsnames /etc/systemd/user | grep '\.wants$'); do
    lsnames "/etc/systemd/user/$w" | grep -qx 'ncz-sky1-audio-autoswitch.service' && audsw=1
done
[ "$audsw" = 1 ] || gate_miss audio "ncz-sky1-audio-autoswitch.service is not enabled (no .wants symlink under /etc/systemd/user)"

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
        for f in /usr/bin/ncz-screensaver /usr/bin/ncz-screensaver-settings /usr/libexec/ncz-screensaver-idled /usr/libexec/ncz-screensaver-run \
                 /usr/lib/systemd/user/ncz-screensaver-idled.service /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml \
                 /usr/share/ncz-screensavers/hacks.tsv; do
            exists "$f" || gate_miss screensavers "$f"
        done
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
    fi
else
    echo "[verify-target] (vi) ncz-screensavers not requested by this image; skipped"
fi

# --- (info) VA-API ---------------------------------------------------------
va=""
for d in /usr/lib/aarch64-linux-gnu/dri /usr/lib/dri; do
    va="$va $(lsnames $d | grep -E '_drv_video\.so$' | tr '\n' ' ')"
done
echo "[verify-target] (info) VA-API drivers:${va:- none}"

if [ "$FAIL" -ne 0 ]; then
    echo "GATE: arm64 installed-target accelerator check FAILED (see GATE: lines above)" >&2
    exit 1
fi
echo "[verify-target] OK: arm64 installed-target accelerator artifacts present"
exit 0
