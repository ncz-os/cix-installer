#!/bin/bash
# test-installed-target-verifier.sh -- prove build/verify-installed-target-arm64.sh
# in BOTH directions against a synthetic installed root (real ext4 image built
# rootlessly with mke2fs -d, read back through real debugfs). Needs mke2fs,
# debugfs, xz. A guard is only trusted once it has failed on purpose.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="$HERE/verify-installed-target-arm64.sh"
MKE2FS="$(command -v mke2fs || echo /usr/sbin/mke2fs)"
DEBUGFS="$(command -v debugfs || echo /sbin/debugfs)"
for t in "$MKE2FS" "$DEBUGFS"; do [ -x "$t" ] || { echo "SKIP: $t not available"; exit 0; }; done
command -v xz >/dev/null || { echo "SKIP: xz not available"; exit 0; }

W="$(mktemp -d -t verifier-test.XXXXXX)"
trap 'rm -rf "$W"' EXIT
KVER=7.2.8-sky1-ncz
PASS=0; FAILS=0

build_root() {   # $1 = root dir to populate with a healthy installed system
    local r="$1" f
    mkdir -p "$r/usr/lib/firmware/arm/mali/arch12.8" "$r/usr/lib/modules/$KVER/updates/dkms" \
             "$r/usr/lib/modules/$KVER/kernel/drivers/media/platform/cix" "$r/usr/src/aipu-6.2.0" \
             "$r/usr/sbin" "$r/usr/bin" "$r/var/lib/dpkg" "$r/usr/lib/aarch64-linux-gnu/dri"
    ln -s usr/lib "$r/lib"
    for f in av1dec avs2dec avsdec h264dec h264enc hevcdec hevcenc jpegdec jpegenc mpeg2dec mpeg4dec vc1dec vp8dec vp8enc vp9dec vp9enc; do
        echo fw > "$r/usr/lib/firmware/$f.fwb"
    done
    echo fw > "$r/usr/lib/firmware/dsp_fw.bin"
    echo fw > "$r/usr/lib/firmware/arm/mali/arch12.8/mali_csffw.bin"
    printf 'junk\0006.2.0\000AIPU KMD (v%%s) probe start...\000more' | xz -c > "$r/usr/lib/modules/$KVER/updates/dkms/aipu.ko.xz"
    printf 'amvx' | xz -c > "$r/usr/lib/modules/$KVER/kernel/drivers/media/platform/cix/amvx.ko.xz"
    printf 'updates/dkms/aipu.ko.xz:\nkernel/drivers/media/platform/cix/amvx.ko.xz:\n' > "$r/usr/lib/modules/$KVER/modules.dep"
    echo x > "$r/usr/src/aipu-6.2.0/dkms.conf"
    mkdir -p "$r/var/lib/dkms/aipu/6.2.0/$KVER"
    mkdir -p "$r/usr/local/lib/cix-installer" "$r/usr/lib/modules/7.3.0-rc3-sky1-ncz"
    echo "$KVER" > "$r/usr/local/lib/cix-installer/KVER_NEXT"
    printf 'x' > "$r/usr/lib/modules/7.3.0-rc3-sky1-ncz/modules.dep"   # older kernel must be ignored
    echo x > "$r/usr/sbin/dkms"; echo x > "$r/usr/bin/ffmpeg"
    echo 'ln -sf $_d /dev/video-cixdec0' > "$r/usr/bin/load-modules.sh"
    printf 'xx h264_v4l2m2m xx' > "$r/usr/lib/aarch64-linux-gnu/libavcodec.so.62.1.100"
    printf 'Package: google-chrome-stable\nStatus: install ok installed\n\nPackage: chromium-ncz-sky1\nStatus: install ok installed\n\n' > "$r/var/lib/dpkg/status"
    # VA-API + mpv
    mkdir -p "$r/usr/share/cix/lib" "$r/etc/environment.d" "$r/etc/mpv"
    echo x > "$r/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so"
    ln -s libcix_va_drv_video.so "$r/usr/lib/aarch64-linux-gnu/dri/linlondp_drv_video.so"
    echo x > "$r/usr/share/cix/lib/libva.so.2"
    echo 'LIBVA_DRIVER_NAME=libcix_va' > "$r/etc/environment.d/60-ncz-vaapi.conf"
    echo 'hwdec=vaapi' > "$r/etc/mpv/mpv.conf"
    # ncz-screensavers
    mkdir -p "$r/usr/local/lib/cix-installer/manifests" "$r/usr/lib/ncz-screensavers" "$r/usr/libexec" "$r/usr/lib/systemd/user" \
             "$r/usr/share/glib-2.0/schemas" "$r/usr/share/ncz-screensavers" "$r/etc/systemd/user/graphical-session.target.wants"
    echo ncz-screensavers > "$r/usr/local/lib/cix-installer/manifests/install-extra.pkgs"
    for n in $(seq 1 84); do echo x > "$r/usr/lib/ncz-screensavers/hack${n}_gles3"; done
    echo x > "$r/usr/bin/ncz-screensaver"; echo x > "$r/usr/bin/ncz-screensaver-settings"
    echo x > "$r/usr/libexec/ncz-screensaver-idled"; echo x > "$r/usr/libexec/ncz-screensaver-run"
    echo x > "$r/usr/lib/systemd/user/ncz-screensaver-idled.service"
    echo x > "$r/usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml"
    echo x > "$r/usr/share/ncz-screensavers/hacks.tsv"
    printf 'GSettings dev.ncz.screensaver blob' > "$r/usr/share/glib-2.0/schemas/gschemas.compiled"
    ln -s /usr/lib/systemd/user/ncz-screensaver-idled.service "$r/etc/systemd/user/graphical-session.target.wants/ncz-screensaver-idled.service"
    printf 'Package: ncz-screensavers\nStatus: install ok installed\nVersion: 0.3.2\n\n' >> "$r/var/lib/dpkg/status"
}

run_case() {   # $1 = name, $2 = expected rc (0|1), $3 = mutation function name or ""
    local name="$1" want="$2" mut="$3" r="$W/root-$RANDOM" img out rc
    build_root "$r"
    [ -n "$mut" ] && "$mut" "$r"
    img="$W/img-$RANDOM"; truncate -s 16M "$img"
    "$MKE2FS" -q -t ext4 -d "$r" "$img" 2>/dev/null || { echo "FAIL  $name: mke2fs"; FAILS=$((FAILS+1)); return; }
    out="$("$VERIFIER" "$img" "$DEBUGFS" 2>&1)"; rc=$?
    if [ "$rc" = "$want" ]; then echo "PASS  $name (rc=$rc)"; PASS=$((PASS+1));
    else echo "FAIL  $name: rc=$rc want=$want"; printf '%s\n' "$out" | sed 's/^/      /'; FAILS=$((FAILS+1)); fi
    rm -rf "$r" "$img"
}

m_no_fwb()      { rm -f "$1/usr/lib/firmware/hevcenc.fwb"; }
m_no_dsp()      { rm -f "$1/usr/lib/firmware/dsp_fw.bin"; }
m_old_aipu()    { printf 'junk\0005.11.0\000AIPU KMD (v%%s) probe start...\000' | xz -c > "$1/usr/lib/modules/$KVER/updates/dkms/aipu.ko.xz"; }
m_no_aipu()     { rm -f "$1/usr/lib/modules/$KVER/updates/dkms/aipu.ko.xz"; printf 'kernel/drivers/media/platform/cix/amvx.ko.xz:\n' > "$1/usr/lib/modules/$KVER/modules.dep"; }
m_no_src()      { rm -rf "$1/usr/src/aipu-6.2.0"; }
m_no_dkmsstate() { rm -rf "$1/var/lib/dkms/aipu/6.2.0/$KVER"; }
m_no_dkms()     { rm -f "$1/usr/sbin/dkms"; }
m_no_amvx()     { printf 'updates/dkms/aipu.ko.xz:\n' > "$1/usr/lib/modules/$KVER/modules.dep"; }
m_no_chrome()   { printf 'Package: chromium-ncz-sky1\nStatus: install ok installed\n\n' > "$1/var/lib/dpkg/status"; }
m_half_chrome() { printf 'Package: google-chrome-stable\nStatus: deinstall ok config-files\n\nPackage: chromium-ncz-sky1\nStatus: install ok installed\n\n' > "$1/var/lib/dpkg/status"; }
m_no_v4l2m2m()  { printf 'plain' > "$1/usr/lib/aarch64-linux-gnu/libavcodec.so.62.1.100"; }
m_no_vadrv()    { rm -f "$1/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so"; }
m_no_vasym()    { rm -f "$1/usr/lib/aarch64-linux-gnu/dri/linlondp_drv_video.so"; }
m_no_libva()    { rm -f "$1/usr/share/cix/lib/libva.so.2"; }
m_no_mpv()      { echo 'vo=gpu' > "$1/etc/mpv/mpv.conf"; }
m_ss_missing()  { sed -i '/ncz-screensavers/,+3d' "$1/var/lib/dpkg/status"; }
m_ss_hacks()    { rm -f "$1"/usr/lib/ncz-screensavers/hack1*_gles3; }
m_ss_noidled()  { rm -f "$1/etc/systemd/user/graphical-session.target.wants/ncz-screensaver-idled.service"; }
m_ss_oldidle()  { ln -s /usr/lib/systemd/user/ncz-idle-manager.service "$1/etc/systemd/user/graphical-session.target.wants/ncz-idle-manager.service"; }
m_ss_schema()   { printf 'nothing' > "$1/usr/share/glib-2.0/schemas/gschemas.compiled"; }
m_ss_launcher() { rm -f "$1/usr/bin/ncz-screensaver"; }
m_ss_unrequested() { : > "$1/usr/local/lib/cix-installer/manifests/install-extra.pkgs"; m_ss_missing "$1"; }
m_no_loader()   { rm -f "$1/usr/bin/load-modules.sh"; }

run_case "healthy installed root passes"        0 ""
run_case "missing hevcenc.fwb fails"            1 m_no_fwb
run_case "missing dsp_fw.bin fails"             1 m_no_dsp
run_case "aipu 5.11.0 fails"                    1 m_old_aipu
run_case "aipu not built fails"                 1 m_no_aipu
run_case "no /usr/src/aipu-6.2.0 fails"         1 m_no_src
run_case "no dkms state for the kernel fails"   1 m_no_dkmsstate
run_case "no dkms binary fails"                 1 m_no_dkms
run_case "amvx not registered fails"            1 m_no_amvx
run_case "google-chrome-stable absent fails"    1 m_no_chrome
run_case "chrome removed-not-purged fails"      1 m_half_chrome
run_case "ffmpeg without v4l2m2m fails"         1 m_no_v4l2m2m
run_case "no cixdec0 loader fails"              1 m_no_loader
run_case "no VA driver fails"                   1 m_no_vadrv
run_case "no linlondp symlink fails"            1 m_no_vasym
run_case "no matched libva runtime fails"       1 m_no_libva
run_case "mpv without hwdec fails"              1 m_no_mpv
run_case "screensavers requested but absent fails" 1 m_ss_missing
run_case "screensavers with 74 of 84 hacks fails"  1 m_ss_hacks
run_case "screensavers without launcher fails"  1 m_ss_launcher
run_case "idled timer not enabled fails"        1 m_ss_noidled
run_case "old idle-manager still enabled fails" 1 m_ss_oldidle
run_case "schema not compiled fails"            1 m_ss_schema
run_case "screensavers not requested is skipped" 0 m_ss_unrequested
VERIFY_EXPECT_SCREENSAVERS=1 run_case "expected by the caller but absent fails even with no manifest" 1 m_ss_unrequested

echo "verifier tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
