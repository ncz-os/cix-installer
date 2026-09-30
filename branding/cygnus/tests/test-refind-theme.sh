#!/bin/bash
# test-refind-theme.sh -- boot the real rEFInd binaries NCZ ships
# (assets/refind/refind_{x64,aa64}.efi) in QEMU with the Cygnus theme and
# screenshot the menu. Nothing touches a real ESP or host: the ESP is a
# throwaway FAT image under $WORK.
#
# The refind.conf used here copies the directives and entry titles that
# assets/refind/ncz-refind-refresh{,-amd64}.sh generate (timeout, banner /
# banner_scale noscale, showtools, scanfor manual, default_selection, the
# Default / Console / Rescue entries), then appends the one-line include
# from branding/cygnus/refind/refind.conf.snippet. Screens are saved as
# $OUT/refind-<arch>-<W>x<H>.png.
#
# Usage: test-refind-theme.sh THEME_DIR OUT_DIR [x64|aa64|both]
# Env: RESOLUTIONS="1920x1080 ...", NO_THEME=1 (baseline without the
#      include), PICK=fallback (1920x1080 background at every size).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
THEME="$(cd "${1:?theme dir}" && pwd)"
OUT="$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)"
ARCHES="${3:-both}"
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
    icon    /EFI/BOOT/icons/os_linux.png
}
menuentry "NCZ-OS 26.10  -  7.2 Panthor (Experimental)" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/icons/os_linux.png
}
menuentry "NCZ-OS 26.10  -  Console" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/icons/os_linux.png
}
menuentry "Rescue Partition (Console)" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/icons/os_linux.png
}
menuentry "RESCUE  -  known-good kernel" {
    loader  /vmlinuz-test
    icon    /EFI/BOOT/icons/os_linux.png
}

EOF
    [ "${NO_THEME:-0}" = 1 ] || cat "$THEME/refind.conf.snippet"
}

run_one() { # arch W H
    local arch=$1 W=$2 H=$3 img="$WORK/esp-$1-$2.img" efi bootname qemu fw vars
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
    # What pick-theme.sh does on a real install: select the background that
    # matches the screen. PICK=fallback keeps the 1920x1080 file everywhere.
    rm -rf "$WORK/cygnus"; cp -r "$THEME" "$WORK/cygnus"
    [ "${PICK:-native}" = native ] && cp "$THEME/theme-${W}x${H}.conf" "$WORK/cygnus/theme.conf"
    mcopy -i "$img" -s "$WORK/cygnus" ::/EFI/BOOT/themes/cygnus
    head -c 4096 /dev/urandom > "$WORK/vmlinuz-test"
    mcopy -i "$img" "$WORK/vmlinuz-test" ::/vmlinuz-test
    conf "$W" "$H" > "$WORK/refind.conf"
    mcopy -i "$img" "$WORK/refind.conf" ::/EFI/BOOT/refind.conf

    local tag=""; [ "${NO_THEME:-0}" = 1 ] && tag="-baseline"; [ "${PICK:-native}" = fallback ] && tag="-fallback"
    local qmp="$WORK/qmp-$arch.sock" shot="$OUT/refind-$arch-${W}x${H}$tag.ppm"
    if [ "$arch" = x64 ]; then
        vars="$WORK/vars-x64.fd"; cp /usr/share/OVMF/OVMF_VARS_4M.fd "$vars"
        qemu=(qemu-system-x86_64 -machine q35 -m 1024
              -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
              -drive if=pflash,format=raw,file="$vars"
              -device "VGA,vgamem_mb=64,xres=$W,yres=$H")
        [ -w /dev/kvm ] && qemu+=(-enable-kvm)
    else
        vars="$WORK/vars-aa64.fd"; cp /usr/share/AAVMF/AAVMF_VARS.fd "$vars"
        qemu=(qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 1024
              -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
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
}

for arch in x64 aa64; do
    [ "$ARCHES" = both ] || [ "$ARCHES" = "$arch" ] || continue
    for res in ${RESOLUTIONS:-1920x1080 2560x1440 3840x2160}; do
        run_one "$arch" "${res%x*}" "${res#*x}"
    done
done
