#!/bin/bash
# test-arm64-gates.sh -- exercise build/verify-arm64-inputs.sh against
# synthetic ROOT trees, mirroring the testing posture of
# build/test-arm64-freshness-gate.sh and build/test-amd64-kernel-classifier.sh:
# drive the real script from script-controlled fixtures so the test has no
# dependency on the live asset tree being in any particular state.
#
# The script under test has TWO directions we must prove:
#
#   1. amd64 direction -- NCZ_TARGET_ARCH=amd64 (or x86_64 / anything that
#      isn't arm64) makes the script a NO-OP: exit 0, exactly one SKIP
#      line, and NO "MISSING:" lines. This must hold even when VERIFY_ROOT
#      points at a totally empty fixture tree -- amd64 never reads the
#      tree, so an empty one is fine.
#
#   2. arm64 direction -- NCZ_TARGET_ARCH=arm64 makes the script actually
#      run the four checks (sky1 firmware, cix-debs, rescue, --mirror).
#      We exercise both the positive (everything present -> exit 0) and
#      negative (one class missing -> exit 1, MISSING line emitted) cases
#      for each class. The arm64 path must honour VERIFY_ROOT (the env
#      override that lets us point the script at a fixture instead of the
#      real repo tree) and VERIFY_FIRMWARE_DIR (the per-flag override
#      used to check a different staged firmware dir than $ROOT/assets).
#
# Run: bash build/test-arm64-gates.sh
# Exit 0 = every case passed; exit 1 = at least one failed; exit 2 = extraction
# of the script under test failed (i.e. the script is missing or unreadable).
#
# What this test is NOT: it does not exec `make image`. The
# gate is a single shell script that doesn't need QEMU, KVM, root, or the
# real asset tree to validate; it only needs to read a tree it points at,
# which is exactly what a fixture gives us.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/verify-arm64-inputs.sh"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }

# A scratch ROOT for every case. Each case writes into a sub-tree so cases
# can't poison each other (the cix-debs class marks `N_DEBS = $(find |
# wc -l)` against the directory, so reusing a single fixture for a positive
# case after a negative case would leak residual files into the count).
TMPROOT="$(mktemp -d -t arm64-gates-test.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0

# Helper: make a non-empty stub file. The gate uses `[ -f ] && [ -s ]` on
# every firmware blob, so 0-byte files are NOT valid stubs. Use 16 bytes
# of zeroes -- the gate doesn't read the contents.
mkstub() {
    # $1 = path
    mkdir -p "$(dirname "$1")"
    dd if=/dev/zero of="$1" bs=16 count=1 status=none
}

# Build a minimal passing arm64 fixture tree under $1. Creates:
#   assets/sky1-firmware/<16 .fwb> + dsp_fw.bin + arm/mali/arch12.8/mali_csffw.bin
#   assets/cix-debs/<one .deb per NEED_PREFIXES prefix, plus spares>
#   assets/rescue/rescue-rootfs-arm64.tar.zst (non-empty)
# Returns the absolute path of the ROOT it built. The 16 .fwb are stub
# files (16 bytes each); the gate only checks -f + -s, never their contents.
mkpassing_root() {
    local root="$1"
    rm -rf "$root"; mkdir -p "$root/assets/sky1-firmware/arm/mali/arch12.8"
    local fwb
    for fwb in av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb \
               hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb \
               mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb; do
        mkstub "$root/assets/sky1-firmware/$fwb"
    done
    mkstub "$root/assets/sky1-firmware/dsp_fw.bin"
    mkstub "$root/assets/sky1-firmware/arm/mali/arch12.8/mali_csffw.bin"
    mkdir -p "$root/assets/cix-debs"
    local prefix
    for prefix in cix-gpu-umd_ cix-libglvnd_ cix-mesa_ cix-noe-umd_ \
                  cix-npu-driver-dkms_ cix-vpu-driver-dkms_ \
                  cix-gpu-kmd-dkms_ panthor-cix-dkms_ cix-firmware_; do
        mkstub "$root/assets/cix-debs/${prefix}1.0.0_arm64.deb"
    done
    # Pad to the default NCZ_CIX_DEB_MIN=22 so the count check passes too.
    local i
    for i in $(seq 1 22); do
        mkstub "$root/assets/cix-debs/spare_${i}_1.0_arm64.deb"
    done
    mkdir -p "$root/assets/rescue"
    mkstub "$root/assets/rescue/rescue-rootfs-arm64.tar.zst"
}

# Run the gate with the given env overrides, capture exit code and output.
# Args: label, expected_exit, expected_pattern (regex), env assignments,
# extra args to the script. The env assignments are `KEY=VAL KEY2=VAL2 ...`
# on a single string; we splat them inside bash -c.
run_gate() {
    local label="$1" want_rc="$2" want_pat="$3" envstr="$4"; shift 4
    local out rc
    out=$(env -i PATH="$PATH" HOME="$HOME" LC_ALL=C \
        NCZ_CIX_DEB_MIN=22 \
        $envstr \
        bash "$GATE" "$@" 2>&1) || rc=$?
    rc="${rc:-0}"
    echo "--- $label (rc=$rc, want=$want_rc) ---"
    printf '%s\n' "$out" | sed 's/^/    /'
    if [ "$rc" = "$want_rc" ] \
       && { [ -z "$want_pat" ] || printf '%s\n' "$out" | grep -qE "$want_pat"; }; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label (want rc=$want_rc, got rc=$rc; want_pat=$want_pat)"
        FAIL=$((FAIL+1))
    fi
}

# Helper: assert that the script emitted NO MISSING line. We do this by
# running the gate, then checking the captured output separately so a
# failed-assertion case still prints useful diagnostics.
assert_no_missing() {
    local label="$1" envstr="$2"; shift 2
    local out
    out=$(env -i PATH="$PATH" HOME="$HOME" LC_ALL=C \
        NCZ_CIX_DEB_MIN=22 \
        $envstr \
        bash "$GATE" "$@" 2>&1) || true
    if printf '%s\n' "$out" | grep -qE 'verify-arm64-inputs: MISSING'; then
        echo "  FAIL  $label -- unexpected MISSING line:"
        printf '%s\n' "$out" | grep -E 'verify-arm64-inputs: MISSING' | sed 's/^/      /' >&2
        FAIL=$((FAIL+1))
    else
        echo "  PASS  $label (no MISSING line)"
        PASS=$((PASS+1))
    fi
}

echo "=== amd64 direction (no-op) ==="

# Case A1: amd64 default-on (env), empty VERIFY_ROOT -> SKIP, exit 0.
# An empty fixture is allowed here: amd64 never reads it. We point
# VERIFY_ROOT at $TMPROOT/empty to prove the gate respects the override
# AND proves it doesn't accidentally read it on amd64.
mkdir -p "$TMPROOT/empty"
run_gate "amd64 -> SKIP (VERIFY_ROOT=$TMPROOT/empty, empty fixture)" \
    0 'verify-arm64-inputs: SKIP' \
    "NCZ_TARGET_ARCH=amd64 VERIFY_ROOT=$TMPROOT/empty"

# Case A2: amd64 default-on (x86_64 spelling is the uname -m form; the
# gate maps it), again empty VERIFY_ROOT. This mirrors the case where the
# host's `uname -m` returns x86_64 but the script doesn't have dpkg.
run_gate "amd64 -> SKIP (NCZ_TARGET_ARCH=x86_64)" \
    0 'verify-arm64-inputs: SKIP' \
    "NCZ_TARGET_ARCH=x86_64 VERIFY_ROOT=$TMPROOT/empty"

# Case A3: amd64 must not emit any MISSING line, even on an EMPTY fixture.
# This is the strongest form of "no-op": we force the branch that would
# normally run every check, and verify it short-circuits before reading
# the tree.
assert_no_missing "amd64 emits no MISSING line on empty fixture" \
    "NCZ_TARGET_ARCH=amd64 VERIFY_ROOT=$TMPROOT/empty"

# Case A4: amd64 still SKIPs when --mirror is requested (the --mirror
# branch is gated by arm64 too, so this must NOT run either).
run_gate "amd64 --mirror -> SKIP" \
    0 'verify-arm64-inputs: SKIP' \
    "NCZ_TARGET_ARCH=amd64 VERIFY_ROOT=$TMPROOT/empty" \
    --mirror

echo
echo "=== arm64 direction (real checks) ==="

# Case B1: arm64, fully populated fixture -> exit 0, OK summary line.
PASSING="$TMPROOT/passing"
mkpassing_root "$PASSING"
run_gate "arm64 PASSING fixture -> OK" \
    0 'verify-arm64-inputs: OK ' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING"

# Case B2: arm64, fully populated fixture still passes when --mirror is
# NOT requested (the --mirror branch is opt-in; without it we don't check
# the desktop-mirror tree even if it exists).
run_gate "arm64 PASSING without --mirror" \
    0 'verify-arm64-inputs: OK ' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING"

# Case B3: arm64, no sky1-firmware directory at all -> exit 1, MISSING
# line for every .fwb + dsp_fw.bin + mali_csffw.bin.
NOPATH_ROOT="$TMPROOT/nofw"
mkdir -p "$NOPATH_ROOT/assets"
run_gate "arm64 with no sky1-firmware dir -> FAIL" \
    1 'verify-arm64-inputs: MISSING: sky1-firmware\.fwb' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$NOPATH_ROOT"

# Case B4: arm64, sky1-firmware dir exists but is empty -> FAIL on
# every .fwb + dsp_fw.bin + mali_csffw.bin (the gate treats zero-byte
# files as missing via `[ -f ] && [ -s ]`).
EMPTYFW_ROOT="$TMPROOT/emptyfw"
mkdir -p "$EMPTYFW_ROOT/assets/sky1-firmware"
run_gate "arm64 with empty sky1-firmware dir -> FAIL" \
    1 'verify-arm64-inputs: MISSING: sky1-firmware' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$EMPTYFW_ROOT"

# Case B5: arm64, all 16 .fwb present but dsp_fw.bin missing -> FAIL
# naming dsp_fw.bin specifically. This proves the gate distinguishes
# the .fwb check from the dsp_fw.bin check (the former iterates a list,
# the latter is a named-file check).
PARTFW_ROOT="$TMPROOT/partfw"
mkdir -p "$PARTFW_ROOT/assets/sky1-firmware/arm/mali/arch12.8"
for fwb in av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb \
           hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb \
           mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb; do
    mkstub "$PARTFW_ROOT/assets/sky1-firmware/$fwb"
done
mkstub "$PARTFW_ROOT/assets/sky1-firmware/arm/mali/arch12.8/mali_csffw.bin"
# Deliberately do NOT create dsp_fw.bin. The fixture also needs the
# cix-debs prefix check to pass and the rescue rootfs to exist, otherwise
# those MISSING lines swamp the message and the dsp_fw.bin line gets
# buried. Reuse the same valid cix-debs + rescue blocks as the passing
# root so the only MISSING is dsp_fw.bin.
mkdir -p "$PARTFW_ROOT/assets/cix-debs"
for prefix in cix-gpu-umd_ cix-libglvnd_ cix-mesa_ cix-noe-umd_ \
              cix-npu-driver-dkms_ cix-vpu-driver-dkms_ \
              cix-gpu-kmd-dkms_ panthor-cix-dkms_ cix-firmware_; do
    mkstub "$PARTFW_ROOT/assets/cix-debs/${prefix}1.0.0_arm64.deb"
done
for i in $(seq 1 22); do
    mkstub "$PARTFW_ROOT/assets/cix-debs/spare_${i}_1.0_arm64.deb"
done
mkdir -p "$PARTFW_ROOT/assets/rescue"
mkstub "$PARTFW_ROOT/assets/rescue/rescue-rootfs-arm64.tar.zst"
run_gate "arm64 with dsp_fw.bin missing -> FAIL (named)" \
    1 'verify-arm64-inputs: MISSING: sky1-firmware\.other.*dsp_fw\.bin' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PARTFW_ROOT"

# Case B6: arm64, cix-debs dir present but missing one of the required
# prefixes (panthor-cix-dkms_). All other classes present.
NOPANTHOR="$TMPROOT/nopanthor"
mkpassing_root "$NOPANTHOR"
# Wipe the panthor deb specifically (the gate glob-matches panthor-cix-dkms_*).
rm -f "$NOPANTHOR/assets/cix-debs/panthor-cix-dkms_"*.deb
run_gate "arm64 missing panthor-cix-dkms_ -> FAIL" \
    1 'verify-arm64-inputs: MISSING: cix-debs\.prefix.*panthor-cix-dkms_' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$NOPANTHOR"

# Case B7: arm64, rescue rootfs missing entirely -> FAIL.
NORESCUE="$TMPROOT/norescue"
mkdir -p "$NORESCUE/assets/sky1-firmware/arm/mali/arch12.8"
for fwb in av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb \
           hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb \
           mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb; do
    mkstub "$NORESCUE/assets/sky1-firmware/$fwb"
done
mkstub "$NORESCUE/assets/sky1-firmware/dsp_fw.bin"
mkstub "$NORESCUE/assets/sky1-firmware/arm/mali/arch12.8/mali_csffw.bin"
mkdir -p "$NORESCUE/assets/cix-debs"
for prefix in cix-gpu-umd_ cix-libglvnd_ cix-mesa_ cix-noe-umd_ \
              cix-npu-driver-dkms_ cix-vpu-driver-dkms_ \
              cix-gpu-kmd-dkms_ panthor-cix-dkms_ cix-firmware_; do
    mkstub "$NORESCUE/assets/cix-debs/${prefix}1.0.0_arm64.deb"
done
for i in $(seq 1 22); do
    mkstub "$NORESCUE/assets/cix-debs/spare_${i}_1.0_arm64.deb"
done
# Deliberately do NOT create assets/rescue/ -- exercise the rescue miss.
run_gate "arm64 missing rescue-rootfs -> FAIL" \
    1 'verify-arm64-inputs: MISSING: rescue-rootfs' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$NORESCUE"

# Case B8: arm64 BUILD_VARIANT=server skips the cix-debs check entirely,
# even when there are no .debs at all. This is the variant gate: server
# images deliberately do NOT carry the proprietary blobs, so a missing
# cix-debs must NOT fail on server.
SERVER_ROOT="$TMPROOT/server"
mkdir -p "$SERVER_ROOT/assets/sky1-firmware/arm/mali/arch12.8"
for fwb in av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb \
           hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb \
           mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb; do
    mkstub "$SERVER_ROOT/assets/sky1-firmware/$fwb"
done
mkstub "$SERVER_ROOT/assets/sky1-firmware/dsp_fw.bin"
mkstub "$SERVER_ROOT/assets/sky1-firmware/arm/mali/arch12.8/mali_csffw.bin"
mkdir -p "$SERVER_ROOT/assets/rescue"
mkstub "$SERVER_ROOT/assets/rescue/rescue-rootfs-arm64.tar.zst"
# Deliberately no assets/cix-debs/ directory.
run_gate "arm64 BUILD_VARIANT=server skips cix-debs check -> OK" \
    0 'verify-arm64-inputs: OK' \
    "NCZ_TARGET_ARCH=arm64 BUILD_VARIANT=server VERIFY_ROOT=$SERVER_ROOT"

# Case B9: --verify-firmware-dir flag overrides the firmware root. This
# is the per-flag path (used by the retired ISO builder) to check a different
# staged tree than $ROOT/assets/sky1-firmware. We populate VERIFY_ROOT
# WITHOUT firmware but populate VERIFY_FIRMWARE_DIR WITH firmware, and
# assert the gate reports OK.
VFD_ROOT="$TMPROOT/vfd"
mkdir -p "$VFD_ROOT/assets/cix-debs"
for prefix in cix-gpu-umd_ cix-libglvnd_ cix-mesa_ cix-noe-umd_ \
              cix-npu-driver-dkms_ cix-vpu-driver-dkms_ \
              cix-gpu-kmd-dkms_ panthor-cix-dkms_ cix-firmware_; do
    mkstub "$VFD_ROOT/assets/cix-debs/${prefix}1.0.0_arm64.deb"
done
for i in $(seq 1 22); do
    mkstub "$VFD_ROOT/assets/cix-debs/spare_${i}_1.0_arm64.deb"
done
mkdir -p "$VFD_ROOT/assets/rescue"
mkstub "$VFD_ROOT/assets/rescue/rescue-rootfs-arm64.tar.zst"
# Deliberately no $VFD_ROOT/assets/sky1-firmware/ -- the gate must NOT
# check it because VERIFY_FIRMWARE_DIR overrides the firmware root.
VFD_FW="$TMPROOT/vfd-fw"
mkdir -p "$VFD_FW/arm/mali/arch12.8"
for fwb in av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb \
           hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb \
           mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb; do
    mkstub "$VFD_FW/$fwb"
done
mkstub "$VFD_FW/dsp_fw.bin"
mkstub "$VFD_FW/arm/mali/arch12.8/mali_csffw.bin"
run_gate "arm64 --verify-firmware-dir overrides firmware root -> OK" \
    0 'verify-arm64-inputs: OK' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$VFD_ROOT" \
    --verify-firmware-dir "$VFD_FW"

# Case B10: --mirror flag enables the desktop-mirror browser check, and
# both packages present -> OK. The mirror root inside the gate is
# ${BUILD_DIR:-$ROOT/build}/desktop-mirror, so we set BUILD_DIR to a
# parent that has a desktop-mirror/pool child.
MIRROR_PARENT="$TMPROOT/mirror"
mkdir -p "$MIRROR_PARENT/desktop-mirror/pool/main/c/chromium-ncz-sky1"
mkdir -p "$MIRROR_PARENT/desktop-mirror/pool/main/g/google-chrome-stable"
mkstub "$MIRROR_PARENT/desktop-mirror/pool/main/c/chromium-ncz-sky1/chromium-ncz-sky1_1.0_arm64.deb"
mkstub "$MIRROR_PARENT/desktop-mirror/pool/main/g/google-chrome-stable/google-chrome-stable_120.0_arm64.deb"
run_gate "arm64 --mirror with both browser debs -> OK" \
    0 'verify-arm64-inputs: OK' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING BUILD_DIR=$MIRROR_PARENT" \
    --mirror

# Case B11: --mirror with a mirror tree missing the chromium-ncz-sky1 deb
# -> FAIL on the mirror.deb class. This proves --mirror actually scans
# (it's a no-op without the flag -- proven by Case B2 above).
NOMIRROR_PARENT="$TMPROOT/nomirror"
mkdir -p "$NOMIRROR_PARENT/desktop-mirror/pool/main/g/google-chrome-stable"
mkstub "$NOMIRROR_PARENT/desktop-mirror/pool/main/g/google-chrome-stable/google-chrome-stable_120.0_arm64.deb"
# Deliberately do NOT create the chromium-ncz-sky1 dir.
run_gate "arm64 --mirror missing chromium-ncz-sky1 -> FAIL" \
    1 'verify-arm64-inputs: MISSING: mirror\.deb.*chromium-ncz-sky1' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING BUILD_DIR=$NOMIRROR_PARENT" \
    --mirror

# Case B12: bad invocation -- --verify-firmware-dir without a path
# argument must exit 2 (the gate's "bad invocation" branch). This proves
# the arg parser actually parses the flag rather than silently ignoring
# it.
run_gate "arm64 --verify-firmware-dir without path -> exit 2" \
    2 'verify-arm64-inputs:.*--verify-firmware-dir requires a path' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING" \
    --verify-firmware-dir

# Case B13: bad invocation -- unknown flag -> exit 2.
run_gate "arm64 --bogus-flag -> exit 2" \
    2 'verify-arm64-inputs: unknown arg: --bogus-flag' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING" \
    --bogus-flag

# Case B14: -h / --help emits the brief (the first ~29 lines, with
# leading "# " stripped) and exits 0. We just check for a known line
# from the brief ("Exit codes:") which appears in the help text.
run_gate "arm64 -h shows help" \
    0 'Exit codes:' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING" \
    -h

# Case B15: the overlay MODVERSIONS check (f) is wired in. A fixture tree
# without assets/kernel/mainline has no pin and reports overlay_crc=skip; a
# dangling pin (staging not mounted) fails with an overlay-modversions MISSING
# line. The CRC comparison itself is covered by build/test-overlay-modversions.sh.
run_gate "arm64 PASSING fixture without a kernel pin -> overlay_crc=skip" \
    0 'verify-arm64-inputs: OK .*overlay_crc=skip' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$PASSING"
DANGLING_PIN="$TMPROOT/dangling-pin"
mkpassing_root "$DANGLING_PIN"
mkdir -p "$DANGLING_PIN/assets/kernel"
ln -s "$TMPROOT/no-such-staging-dir" "$DANGLING_PIN/assets/kernel/mainline"
run_gate "arm64 dangling kernel pin -> overlay-modversions FAIL" \
    1 'verify-arm64-inputs: MISSING: overlay-modversions' \
    "NCZ_TARGET_ARCH=arm64 VERIFY_ROOT=$DANGLING_PIN"

echo
echo "=== arm64 gates test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
