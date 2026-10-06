#!/bin/bash
# kvm-splash-shot.sh -- boot the REAL singularity-boot-splash binary in a KVM
# guest on a QEMU stdvga display of a chosen resolution and capture what it
# scans out (QEMU `screendump`), one PNG per resolution.
#
# Manual proof tool for docs/HIDPI-SCALING.md, not wired into `make`. Runs on
# an amd64 build host (needs qemu-system-x86_64 and python3; /dev/kvm makes it
# fast but is optional) after build/hidpi/kvm-splash-stage.sh has produced the
# guest kernel and initramfs inside a Debian container:
#
#   STAGE=/path/stage OUT_DIR=/path/out VARIANT=patched \
#       bash build/hidpi/kvm-splash-shot.sh 3072x1920 1920x1080 1366x768 1024x768
#
# STAGE must hold vmlinuz and initrd.img. GPU=vga (default, stdvga + bochs
# DRM) or GPU=virtio (virtio-gpu) picks the display device. VARIANT picks the binary inside the
# initramfs (patched = NCZ loginui patch applied, upstream = unpatched).
set -euo pipefail

STAGE="${STAGE:?set STAGE to the kvm-splash-stage.sh output directory}"
OUT="${OUT_DIR:?set OUT_DIR}"
VARIANT="${VARIANT:-patched}"
SETTLE="${SETTLE:-3}"
[ "$#" -gt 0 ] || set -- 3072x1920 1920x1080 1366x768 1024x768
mkdir -p "$OUT"
accel=(-machine q35)
if [ -w /dev/kvm ]; then accel=(-machine "q35,accel=kvm" -cpu host); fi

for res in "$@"; do
    w=${res%x*}; h=${res#*x}
    # Widths that are not a multiple of 8 (1366) come out sheared on BOTH
    # QEMU devices, for the unpatched and the patched binary alike; capture
    # 1360x768 or 1368x768 instead and rely on test-splash-logo-fit.sh for
    # the exact 1366x768 frame.
    if [ "${GPU:-vga}" = virtio ]; then
        dev="virtio-vga,xres=$w,yres=$h"
    else
        dev="VGA,xres=$w,yres=$h,vgamem_mb=128,edid=on"
    fi
    run="$(mktemp -d "${TMPDIR:-$OUT}/kvmshot.XXXXXX")"
    mon="$run/mon.sock"; log="$run/serial.log"
    qemu-system-x86_64 "${accel[@]}" -m 1024 -smp 2 -nodefaults -no-reboot \
        -kernel "$STAGE/vmlinuz" -initrd "$STAGE/initrd.img" \
        -append "console=ttyS0 quiet ncz_splash=$VARIANT ${KDEBUG:+ncz_debug=1}" \
        -device "$dev" \
        -display none -serial "file:$log" \
        -monitor "unix:$mon,server,nowait" &
    qpid=$!
    ok=0
    for _ in $(seq 1 120); do
        if grep -q "NCZ-SPLASH-RUNNING" "$log" 2>/dev/null; then ok=1; break; fi
        kill -0 "$qpid" 2>/dev/null || break
        sleep 0.5
    done
    if [ "$ok" = 1 ]; then
        sleep "$SETTLE"
        python3 - "$mon" "$run/shot.ppm" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(f"screendump {sys.argv[2]}\n".encode())
time.sleep(1.5)
s.sendall(b"quit\n")
time.sleep(0.5)
s.close()
PY
    fi
    # The guest powers itself off about 60 s after boot; if the splash never
    # reported running there is nothing to capture, so stop QEMU now.
    [ "$ok" = 1 ] || kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    grep -E "${LOGGREP:-NCZ-SPLASH|boot-splash}" "$log" | sed "s/^/[$res] /" || true
    if [ -s "$run/shot.ppm" ]; then
        python3 - "$run/shot.ppm" "$OUT/kvm-splash-$VARIANT-${w}x${h}.png" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
# QEMU writes a binary PPM with a three-line header: "P6\n<w> <h>\n255\n"
magic, dims, _maxval, body = data.split(b"\n", 3)
assert magic == b"P6", magic
w, h = (int(v) for v in dims.split())
raw = b"".join(b"\x00" + body[y * w * 3:(y + 1) * w * 3] for y in range(h))
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print(f"[shot] {w}x{h} -> {sys.argv[2]}")
PY
    else
        echo "[$res] FAIL: no screendump (splash never reported running)"
    fi
    rm -rf "$run"
done
