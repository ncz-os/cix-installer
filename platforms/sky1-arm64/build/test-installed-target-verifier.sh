#!/bin/bash
# test-installed-target-verifier.sh -- prove build/verify-installed-target-arm64.sh
# in BOTH directions against a synthetic installed root (real ext4 image built
# rootlessly with mke2fs -d, read back through real debugfs). Needs mke2fs,
# debugfs, xz. A guard is only trusted once it has failed on purpose.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="$HERE/verify-installed-target.sh"
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
    printf 'ln -sf $_d /dev/video-cixdec0\nln -sf $_e /dev/video-cixenc0\n' > "$r/usr/bin/load-modules.sh"
    printf 'xx h264_v4l2m2m xx' > "$r/usr/lib/aarch64-linux-gnu/libavcodec.so.62.1.100"
    printf 'Package: google-chrome-stable\nStatus: install ok installed\n\nPackage: chromium-ncz-sky1\nStatus: install ok installed\n\n' > "$r/var/lib/dpkg/status"
    mkdir -p "$r/etc"; echo ncz-acrab-1717 > "$r/etc/hostname"
    # bing wallpaper prefetch
    mkdir -p "$r/usr/local/bin" "$r/usr/lib/systemd/user" "$r/etc/systemd/user/timers.target.wants" "$r/opt/singularity/lib/singularity/plugins/wallpapers-bing"
    echo x > "$r/usr/local/bin/ncz-wallpaper-bing"
    for u in ncz-wallpaper-bing.service ncz-wallpaper-bing.timer ncz-wallpaper-bing-daily.timer; do echo x > "$r/usr/lib/systemd/user/$u"; done
    ln -s /usr/lib/systemd/user/ncz-wallpaper-bing.timer "$r/etc/systemd/user/timers.target.wants/ncz-wallpaper-bing.timer"
    ln -s /usr/lib/systemd/user/ncz-wallpaper-bing-daily.timer "$r/etc/systemd/user/timers.target.wants/ncz-wallpaper-bing-daily.timer"
    printf 'xx Preferred market xx' > "$r/opt/singularity/lib/singularity/plugins/wallpapers-bing/libwallpapers-bing.so"
    mkdir -p "$r/opt/singularity/lib/singularity/plugins/sensors"
    printf 'xx sensors_contrast_ensure_contrast xx' > "$r/opt/singularity/lib/singularity/plugins/sensors/libsensors.so"
    # release identity + final ldconfig (common to both architectures)
    mkdir -p "$r/usr/local/lib/cix-installer" "$r/etc/systemd/system/ldconfig.service.d"
    echo "${TEST_ARCH:-arm64}" > "$r/usr/local/lib/cix-installer/BUILD_ARCH"
    echo "2026.09.29-abcdef0" > "$r/usr/local/lib/cix-installer/BUILD_VERSION"
    printf 'NCZ_PRODUCT_NAME="NCZ-OS"\nNCZ_RELEASE_VERSION="26.7"\nNCZ_RELEASE_CODENAME="Maximilian"\n' > "$r/usr/local/lib/cix-installer/RELEASE"
    printf 'NCZ-OS 26.7 Maximilian Desktop\n' > "$r/etc/issue"
    printf '[Service]\nSuccessExitStatus=1\n' > "$r/etc/systemd/system/ldconfig.service.d/10-ncz-tolerate-race.conf"
    echo x > "$r/etc/ld.so.cache"; echo x > "$r/etc/.updated"
    # sshd: Include first, password login in the fleet drop-in (as 35-ssh.sh / extract-rootfs.sh write it)
    mkdir -p "$r/etc/ssh/sshd_config.d"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nKbdInteractiveAuthentication no\nUsePAM yes\n' > "$r/etc/ssh/sshd_config"
    printf 'PasswordAuthentication yes\n' > "$r/etc/ssh/sshd_config.d/10-ncz-fleet.conf"
    # never-software-render pieces (common)
    mkdir -p "$r/usr/local/bin" "$r/usr/bin" "$r/etc/systemd/system/multi-user.target.wants" "$r/opt/singularity/bin"
    echo '#!/bin/sh' > "$r/usr/local/bin/ncz-gpu-hw-present"
    printf '#!/bin/sh\n# --require-hardware\n' > "$r/usr/bin/ncz-gpu-status"
    echo x > "$r/etc/systemd/system/ncz-gpu-health.service"; ln -s /etc/systemd/system/ncz-gpu-health.service "$r/etc/systemd/system/multi-user.target.wants/ncz-gpu-health.service"
    echo 'NCZ_ALLOW_SOFTWARE_FALLBACK' > "$r/usr/local/bin/ncz-gpu-env"
    echo 'hw_render_device_present() { :; }' > "$r/opt/singularity/bin/singularity-labwc-session"
    if [ "${TEST_ARCH:-arm64}" = arm64 ]; then
        mkdir -p "$r/opt/cixgpu-compat/share/glvnd/egl_vendor.d" "$r/etc/glvnd/egl_vendor.d"
        echo '{}' > "$r/opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json"
        ln -s /opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json "$r/etc/glvnd/egl_vendor.d/10_cix.json"
    fi
    # sudo
    printf 'Package: sudo\nStatus: install ok installed\n\n' >> "$r/var/lib/dpkg/status"
    mkdir -p "$r/etc"; printf 'root:x:0:\nsudo:x:27:nczuser\n' > "$r/etc/group"
    # media stack: no VA driver, mpv on V4L2
    mkdir -p "$r/etc/mpv"
    echo 'hwdec=v4l2m2m-copy' > "$r/etc/mpv/mpv.conf"
    # Sky1 audio autoswitch
    mkdir -p "$r/usr/local/bin" "$r/etc/systemd/user/graphical-session.target.wants"
    printf "def hda_cards():\n    pass\ndef analog_device(c):\n    pass\n" > "$r/usr/local/bin/ncz-sky1-audio-autoswitch"
    echo x > "$r/etc/systemd/user/ncz-sky1-audio-autoswitch.service"
    echo x > "$r/usr/bin/pactl"
    ln -s /etc/systemd/user/ncz-sky1-audio-autoswitch.service "$r/etc/systemd/user/graphical-session.target.wants/ncz-sky1-audio-autoswitch.service"
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
    out="$("$VERIFIER" "$img" "$DEBUGFS" "${TEST_ARCH:-arm64}" 2>&1)"; rc=$?
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
m_va_but_mpv_v4l2() { echo x > "$1/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so"; }
m_no_encnode()  { echo 'ln -sf $_d /dev/video-cixdec0' > "$1/usr/bin/load-modules.sh"; }
m_no_mpv()      { echo 'vo=gpu' > "$1/etc/mpv/mpv.conf"; }
m_mpv_vaapi_no_driver() { echo 'hwdec=vaapi' > "$1/etc/mpv/mpv.conf"; }
m_ss_missing()  { sed -i '/ncz-screensavers/,+3d' "$1/var/lib/dpkg/status"; }
m_ss_hacks()    { rm -f "$1"/usr/lib/ncz-screensavers/hack1*_gles3; }
m_ss_noidled()  { rm -f "$1/etc/systemd/user/graphical-session.target.wants/ncz-screensaver-idled.service"; }
m_ss_oldidle()  { ln -s /usr/lib/systemd/user/ncz-idle-manager.service "$1/etc/systemd/user/graphical-session.target.wants/ncz-idle-manager.service"; }
m_ss_schema()   { printf 'nothing' > "$1/usr/share/glib-2.0/schemas/gschemas.compiled"; }
m_ss_launcher() { rm -f "$1/usr/bin/ncz-screensaver"; }
m_ss_unrequested() { : > "$1/usr/local/lib/cix-installer/manifests/install-extra.pkgs"; m_ss_missing "$1"; }
m_no_sudo()     { sed -i '/^Package: sudo$/,+2d' "$1/var/lib/dpkg/status"; }
m_sudo_empty()  { printf 'root:x:0:\nsudo:x:27:\n' > "$1/etc/group"; }
m_aud_nodaemon() { rm -f "$1/usr/local/bin/ncz-sky1-audio-autoswitch"; }
m_aud_dponly()   { printf "# ncz_sky1_analog only in a comment\n" > "$1/usr/local/bin/ncz-sky1-audio-autoswitch"; }
m_aud_nounit()   { rm -f "$1/etc/systemd/user/ncz-sky1-audio-autoswitch.service"; }
m_aud_noenable() { rm -f "$1/etc/systemd/user/graphical-session.target.wants/ncz-sky1-audio-autoswitch.service"; }
m_aud_nopactl()  { rm -f "$1/usr/bin/pactl"; }
m_hn_setup()    { echo ncz-setup > "$1/etc/hostname"; }
m_hn_machex()   { echo ncz-20e7bc > "$1/etc/hostname"; }
m_hn_upper()    { echo NCZ-Acrab-1717 > "$1/etc/hostname"; }
m_wp_nohelper() { rm -f "$1/usr/local/bin/ncz-wallpaper-bing"; }
m_wp_nounit()   { rm -f "$1/usr/lib/systemd/user/ncz-wallpaper-bing-daily.timer"; }
m_wp_noenable() { rm -f "$1/etc/systemd/user/timers.target.wants/ncz-wallpaper-bing.timer"; }
m_wp_stale()    { printf 'old plugin build' > "$1/opt/singularity/lib/singularity/plugins/wallpapers-bing/libwallpapers-bing.so"; }
m_wp_noplugin() { rm -f "$1/opt/singularity/lib/singularity/plugins/wallpapers-bing/libwallpapers-bing.so"; }
m_sens_stale()  { printf 'old sensors build' > "$1/opt/singularity/lib/singularity/plugins/sensors/libsensors.so"; }
m_sens_missing() { rm -f "$1/opt/singularity/lib/singularity/plugins/sensors/libsensors.so"; }
m_id_arch()     { echo arm64 > "$1/usr/local/lib/cix-installer/BUILD_ARCH"; }
m_id_release()  { echo 'NCZ_PRODUCT_NAME="Other"' > "$1/usr/local/lib/cix-installer/RELEASE"; }
m_ld_dropin()   { rm -f "$1/etc/systemd/system/ldconfig.service.d/10-ncz-tolerate-race.conf"; }
m_ld_stamp()    { rm -f "$1/etc/.updated"; }
m_leak_getty()  { mkdir -p "$1/etc/systemd/system/getty.target.wants"; ln -s /lib/systemd/system/serial-getty@.service "$1/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"; }
m_leak_perf()   { mkdir -p "$1/etc/systemd/system/graphical.target.wants"; ln -s /etc/systemd/system/ncz-performance-mode.service "$1/etc/systemd/system/graphical.target.wants/ncz-performance-mode.service"; }
m_leak_display() { mkdir -p "$1/etc/systemd/system/sysinit.target.wants"; ln -s /etc/systemd/system/cix-detect-display.service "$1/etc/systemd/system/sysinit.target.wants/cix-detect-display.service"; }
m_amd64_strip() {   # what an x86 install does NOT have: everything Sky1
    rm -rf "$1/usr/lib/firmware" "$1/usr/src/aipu-6.2.0" "$1/usr/lib/aarch64-linux-gnu" "$1/usr/bin/load-modules.sh" \
           "$1/etc/mpv" "$1/usr/local/bin/ncz-sky1-audio-autoswitch" "$1/etc/systemd/user/ncz-sky1-audio-autoswitch.service"
    rm -f "$1/etc/systemd/user/graphical-session.target.wants/ncz-sky1-audio-autoswitch.service"
    rm -rf "$1/usr/lib/modules/$KVER"; mkdir -p "$1/usr/lib/modules/7.2.8-1-t2-trixie"
    sed -i '/^Package: chromium-ncz-sky1$/,+2d' "$1/var/lib/dpkg/status"
}
m_id_arch_amd64() { m_amd64_strip "$1"; echo arm64 > "$1/usr/local/lib/cix-installer/BUILD_ARCH"; }
m_id_arch_arm()  { echo amd64 > "$1/usr/local/lib/cix-installer/BUILD_ARCH"; }
m_amd64_leak_perf() { m_amd64_strip "$1"; m_leak_perf "$1"; }
m_amd64_leak_display() { m_amd64_strip "$1"; m_leak_display "$1"; }
m_amd64_strip_leak() { m_amd64_strip "$1"; m_leak_getty "$1"; }
m_amd64_strip_nohost() { m_amd64_strip "$1"; echo ncz-setup > "$1/etc/hostname"; }
m_amd64_strip_nosudo() { m_amd64_strip "$1"; sed -i '/^Package: sudo$/,+2d' "$1/var/lib/dpkg/status"; }
m_amd64_strip_nochrome() { m_amd64_strip "$1"; sed -i '/^Package: google-chrome-stable$/,+2d' "$1/var/lib/dpkg/status"; }
m_amd64_strip_stale_bing() { m_amd64_strip "$1"; printf 'old' > "$1/opt/singularity/lib/singularity/plugins/wallpapers-bing/libwallpapers-bing.so"; }
m_amd64_strip_nokernel() { m_amd64_strip "$1"; rm -rf "$1/usr/lib/modules"; }
m_ssh_off()      { printf 'PasswordAuthentication no\n' > "$1/etc/ssh/sshd_config.d/10-ncz-fleet.conf"; }
m_ssh_late_no()  { printf 'PasswordAuthentication no\n' > "$1/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"; }
m_ssh_unset()    { rm -f "$1/etc/ssh/sshd_config.d/10-ncz-fleet.conf"; }
m_ssh_main_first() { printf 'PasswordAuthentication no\nInclude /etc/ssh/sshd_config.d/*.conf\n' > "$1/etc/ssh/sshd_config"; }
m_ssh_nofile()   { rm -f "$1/etc/ssh/sshd_config"; }
m_gpu_hwp()      { rm -f "$1/usr/local/bin/ncz-gpu-hw-present"; }
m_gpu_status()   { echo '#!/bin/sh' > "$1/usr/bin/ncz-gpu-status"; }
m_gpu_unit()     { rm -f "$1/etc/systemd/system/multi-user.target.wants/ncz-gpu-health.service"; }
m_gpu_env()      { echo x > "$1/usr/local/bin/ncz-gpu-env"; }
m_gpu_session()  { echo x > "$1/opt/singularity/bin/singularity-labwc-session"; }
m_gpu_egl()      { rm -f "$1/etc/glvnd/egl_vendor.d/10_cix.json"; }
m_gpu_egl_leak() { m_amd64_strip "$1"; mkdir -p "$1/etc/glvnd/egl_vendor.d"; ln -s /x "$1/etc/glvnd/egl_vendor.d/10_cix.json"; }
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
run_case "placeholder hostname fails"           1 m_hn_setup
run_case "MAC-hex fallback hostname fails"      1 m_hn_machex
run_case "malformed generated hostname fails"   1 m_hn_upper
run_case "no wallpaper helper fails"            1 m_wp_nohelper
run_case "missing daily timer unit fails"       1 m_wp_nounit
run_case "wallpaper timer not enabled fails"    1 m_wp_noenable
run_case "stale unpatched plugin .so fails"     1 m_wp_stale
run_case "missing wallpapers-bing plugin fails" 1 m_wp_noplugin
run_case "stale sensors plugin fails"           1 m_sens_stale
run_case "missing sensors plugin fails"         1 m_sens_missing
run_case "sudo not installed fails"             1 m_no_sudo
run_case "empty sudo group fails"               1 m_sudo_empty
run_case "VA driver present but mpv on v4l2 fails" 1 m_va_but_mpv_v4l2
run_case "no encode node helper fails"          1 m_no_encnode
run_case "mpv vaapi without a VA driver fails"   1 m_mpv_vaapi_no_driver
run_case "mpv without hwdec fails"              1 m_no_mpv
run_case "screensavers requested but absent fails" 1 m_ss_missing
run_case "screensavers with 74 of 84 hacks fails"  1 m_ss_hacks
run_case "screensavers without launcher fails"  1 m_ss_launcher
run_case "idled timer not enabled fails"        1 m_ss_noidled
run_case "old idle-manager still enabled fails" 1 m_ss_oldidle
run_case "schema not compiled fails"            1 m_ss_schema
run_case "no audio autoswitch daemon fails"     1 m_aud_nodaemon
run_case "DP-only audio daemon (no analog fallback) fails" 1 m_aud_dponly
run_case "no audio autoswitch unit fails"       1 m_aud_nounit
run_case "audio autoswitch not enabled fails"   1 m_aud_noenable
run_case "no pactl fails"                       1 m_aud_nopactl
run_case "screensavers not requested is skipped" 0 m_ss_unrequested
VERIFY_EXPECT_SCREENSAVERS=1 run_case "expected by the caller but absent fails even with no manifest" 1 m_ss_unrequested


# ---- arm64-only checks must not run on amd64 and Sky1 policy must not leak onto it -----------------
export TEST_ARCH=amd64
run_case "amd64: a healthy x86 target passes with no Sky1 content"  0 m_amd64_strip
run_case "amd64: serial-getty@ttyAMA0 leak fails"                   1 m_amd64_strip_leak
run_case "amd64: placeholder hostname fails"                        1 m_amd64_strip_nohost
run_case "amd64: sudo missing fails"                                1 m_amd64_strip_nosudo
run_case "amd64: google-chrome-stable missing fails"                1 m_amd64_strip_nochrome
run_case "amd64: stale Bing plugin fails"                           1 m_amd64_strip_stale_bing
run_case "amd64: no kernel module tree fails"                       1 m_amd64_strip_nokernel
run_case "amd64: BUILD_ARCH of the other architecture fails"        1 m_id_arch_amd64
run_case "amd64: ncz-performance-mode leak fails"                   1 m_amd64_leak_perf
run_case "amd64: cix-detect-display leak fails"                     1 m_amd64_leak_display
run_case "gpu: amd64 with a leaked Mali EGL entry fails"        1 m_gpu_egl_leak
unset TEST_ARCH
run_case "ssh: PasswordAuthentication no fails"                1 m_ssh_off
run_case "ssh: a later drop-in saying no does not override 10-"  0 m_ssh_late_no
run_case "ssh: no PasswordAuthentication anywhere fails"        1 m_ssh_unset
run_case "ssh: a main-file 'no' before the Include wins and fails" 1 m_ssh_main_first
run_case "ssh: missing sshd_config fails"                       1 m_ssh_nofile
run_case "gpu: missing ncz-gpu-hw-present fails"               1 m_gpu_hwp
run_case "gpu: ncz-gpu-status without --require-hardware fails" 1 m_gpu_status
run_case "gpu: health unit not enabled fails"                   1 m_gpu_unit
run_case "gpu: ncz-gpu-env without the software guard fails"    1 m_gpu_env
run_case "gpu: labwc-session without the overlay patch fails"   1 m_gpu_session
run_case "gpu: arm64 without the Mali EGL vendor entry fails"   1 m_gpu_egl
run_case "arm64: wrong BUILD_ARCH fails"                        1 m_id_arch_arm
run_case "identity: RELEASE not NCZ-OS fails"                   1 m_id_release
run_case "ldconfig: tolerate-race drop-in missing fails"        1 m_ld_dropin
run_case "ldconfig: /etc/.updated stamp missing fails"         1 m_ld_stamp
echo "verifier tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
