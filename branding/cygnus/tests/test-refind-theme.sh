#!/bin/bash
# test-refind-theme.sh -- boot the real rEFInd binaries NCZ ships
# (assets/refind/refind_{x64,aa64}.efi) in QEMU with the Cygnus theme and
# screenshot the menu. Nothing touches a real ESP or host: the ESP is a
# throwaway FAT image under $WORK.
#
# The refind.conf used here copies the directives and entry titles that
# assets/refind/ncz-refind-refresh{,-amd64}.sh generate (timeout, banner /
# banner_scale noscale, showtools, scanfor manual, default_selection, the
# Default / Console / Rescue entries), then appends the include line from
# branding/cygnus/refind/refind.conf.snippet. The theme itself is a SINGLE
# 1920x1080 background with `banner_scale fillscreen`; the generated
# `resolution <W> <H>` here forces the GOP mode under test (it stands in for
# the `resolution max` production line) so the same theme is exercised at every
# resolution. Screens are saved as $OUT/refind-<arch>-<W>x<H>.png and each is
# checked against a stretch of the one background: a crop or a black/letterbox
# band fails the run (MAD threshold).
#
# Usage: test-refind-theme.sh THEME_DIR OUT_DIR [x64|aa64|both]
# Env: RESOLUTIONS="1920x1080 ...", NO_THEME=1 (baseline without the include),
#      REFIND_WAIT / REFIND_WAIT_AA64 (boot settle), CHECK_METRICS=0 to only
#      screenshot, MAD_MAX=<float> override.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
THEME="$(cd "${1:?theme dir}" && pwd)"
OUT="$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)"
ARCHES="${3:-both}"
# Debian ships AAVMF_CODE.no-secboot.fd; Fedora ships AAVMF_CODE.fd.
AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
[ -r "$AAVMF_CODE" ] || AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
# Debian ships the 4M OVMF images; Fedora 44 ships the 2M ones.
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -r "$OVMF_CODE" ] || OVMF_CODE=/usr/share/OVMF/OVMF_CODE.fd
[ -r "$OVMF_VARS" ] || OVMF_VARS=/usr/share/OVMF/OVMF_VARS.fd
WORK="$(mktemp -d "${TMPDIR:-$HOME/.cache}/refind-theme.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

conf() { # $1 = W, $2 = H
    cat <<EOF
timeout 0
log_level 0
use_nvram false
resolution $1 $2
banner ncz-banner.png
banner_scale noscale
showtools shell,reboot,shutdown,firmware
scanfor manual
scan_all_linux_kernels false
default_selection "NCZ-OS 26.10  -  7.2 Mali (Default)"

menuentry "NCZ-OS 26.10  -  7.2 Mali (Default)" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/ncz.png
}
menuentry "NCZ-OS 26.10  -  7.2 Panthor (Experimental)" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/ncz.png
}
menuentry "NCZ-OS 26.10  -  Console" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/ncz.png
}
menuentry "Rescue Partition (Console)" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/ncz.png
}
menuentry "RESCUE  -  known-good kernel" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/ncz.png
}

EOF
    [ "${NO_THEME:-0}" = 1 ] || cat "$THEME/refind.conf.snippet"
}

# check_shot SHOT W H -- fail if the screenshot is not the single background
# stretched to the full screen. Compares 160x90 BOX-downsampled means (which
# average out the menu text) against (a) the background stretched to WxH and
# (b) the background cropped top-left to WxH, if it is larger. A crop scores
# far worse against (a) than a correct fill.
check_shot() {
    local shot=$1 W=$2 H=$3
    [ "${CHECK_METRICS:-1}" = 1 ] || return 0
    python3 - "$shot" "$THEME/background-1920x1080.png" "$W" "$H" "${MAD_MAX:-8.0}" <<'PY'
import sys
from PIL import Image, ImageChops

shot, bg, W, H, mad_max = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
s = Image.open(shot).convert("RGB")
b = Image.open(bg).convert("RGB")
if s.size != (W, H):
    print(f"    FAIL {shot}: screenshot is {s.size}, expected {(W, H)}"); sys.exit(1)

def box(im):
    return im.resize((160, 90), Image.BOX)

def mad(a, c):
    d = ImageChops.difference(a, c)
    px = list(d.getdata())
    return sum(sum(p) for p in px) / (len(px) * 3)

fill = mad(box(s), box(b.resize((W, H), Image.BILINEAR)))
line = f"    {W}x{H}: MAD(stretch)={fill:.2f}"
crop = None
if b.width > W and b.height > H:
    crop = mad(box(s), box(b.crop((0, 0, W, H))))
    line += f" MAD(topleft-crop)={crop:.2f}"
print(line)
if fill > mad_max:
    print(f"    FAIL {shot}: not the background stretched to fill (MAD {fill:.2f} > {mad_max})"); sys.exit(1)
if crop is not None and crop < fill:
    print(f"    FAIL {shot}: screenshot matches a crop better than a fill"); sys.exit(1)
PY
}

qemu_arch_available() { # arch
    if [ "$1" = x64 ]; then
        command -v qemu-system-x86_64 >/dev/null 2>&1 && [ -r "$OVMF_CODE" ] && [ -r "$OVMF_VARS" ]
    else
        command -v qemu-system-aarch64 >/dev/null 2>&1 && [ -r "$AAVMF_CODE" ] && [ -r /usr/share/AAVMF/AAVMF_VARS.fd ]
    fi
}

run_one() { # arch W H
    local arch=$1 W=$2 H=$3 img="$WORK/esp-$1-$2.img" efi bootname qemu vars
    rm -f "$img"
    mkfs.vfat -C -n NCZESP "$img" 65536 >/dev/null
    case $arch in
        x64)  efi="$ROOT/assets/refind/refind_x64.efi"; bootname=BOOTX64.EFI ;;
        aa64) efi="$ROOT/assets/refind/refind_aa64.efi"; bootname=BOOTAA64.EFI ;;
    esac
    mmd -i "$img" ::/EFI ::/EFI/BOOT ::/EFI/BOOT/themes
    mcopy -i "$img" "$efi" "::/EFI/BOOT/$bootname"
    mcopy -i "$img" -s "$ROOT/assets/refind/icons" ::/EFI/BOOT/
    mcopy -i "$img" "$ROOT/assets/refind/ncz-banner.png" ::/EFI/BOOT/ncz-banner.png
    # entry icon exactly as the refresh scripts install it (Cygnus os_ncz.png -> ncz.png)
    mcopy -i "$img" "$THEME/os_ncz.png" ::/EFI/BOOT/ncz.png
    # The refresh scripts copy the whole theme dir; theme.conf is the design.
    rm -rf "$WORK/cygnus"; cp -r "$THEME" "$WORK/cygnus"
    mcopy -i "$img" -s "$WORK/cygnus" ::/EFI/BOOT/themes/cygnus
    head -c 4096 /dev/urandom > "$WORK/vmlinuz-test"
    mcopy -i "$img" "$WORK/vmlinuz-test" ::/vmlinuz-test
    conf "$W" "$H" > "$WORK/refind.conf"
    mcopy -i "$img" "$WORK/refind.conf" ::/EFI/BOOT/refind.conf

    local tag=""; [ "${NO_THEME:-0}" = 1 ] && tag="-baseline"
    local qmp="$WORK/qmp-$arch.sock" shot="$OUT/refind-$arch-${W}x${H}$tag.ppm"
    if [ "$arch" = x64 ]; then
        vars="$WORK/vars-x64.fd"; cp "$OVMF_VARS" "$vars"
        qemu=(qemu-system-x86_64 -machine q35 -m 1024
              -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
              -drive if=pflash,format=raw,file="$vars"
              -device "VGA,vgamem_mb=64,xres=$W,yres=$H")
        # KVM can only accelerate a guest of the host's own arch: on an arm64
        # host an x86_64 guest must run under TCG even though /dev/kvm exists.
        [ "$(uname -m)" = x86_64 ] && [ -w /dev/kvm ] && qemu+=(-enable-kvm)
    else
        vars="$WORK/vars-aa64.fd"; cp /usr/share/AAVMF/AAVMF_VARS.fd "$vars"
        qemu=(qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 1024
              -drive if=pflash,format=raw,readonly=on,file=$AAVMF_CODE
              -drive if=pflash,format=raw,file="$vars"
              -device "virtio-gpu-pci,xres=$W,yres=$H" -device qemu-xhci -device usb-kbd)
    fi
    "${qemu[@]}" -drive "format=raw,file=$img" -display none -serial none \
        -qmp "unix:$qmp,server,nowait" -daemonize -pidfile "$WORK/qemu.pid"
    local wait=${REFIND_WAIT:-25}; [ "$arch" = aa64 ] && wait=${REFIND_WAIT_AA64:-70}
    sleep "$wait"
    timeout 20 python3 - "$qmp" "$shot" <<'PY'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
f.readline()
for cmd in ({"execute": "qmp_capabilities"},
            {"execute": "screendump", "arguments": {"filename": sys.argv[2]}}):
    f.write(json.dumps(cmd) + "\n"); f.flush(); f.readline()
time.sleep(1)
PY
    sleep 2
    kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true
    python3 -c "from PIL import Image; import sys; Image.open(sys.argv[1]).save(sys.argv[2])" \
        "$shot" "${shot%.ppm}.png" && rm -f "$shot"
    echo "  $arch ${W}x${H}: ${shot%.ppm}.png"
    check_shot "${shot%.ppm}.png" "$W" "$H"
}

for arch in x64 aa64; do
    [ "$ARCHES" = both ] || [ "$ARCHES" = "$arch" ] || continue
    if ! qemu_arch_available "$arch"; then
        echo "  SKIP $arch: qemu/firmware not installed on this host" >&2
        continue
    fi
    for res in ${RESOLUTIONS:-1920x1080 2560x1440 1280x800 1920x1200}; do
        run_one "$arch" "${res%x*}" "${res#*x}"
    done
done
