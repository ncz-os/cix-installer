#!/bin/bash
# kvm-splash-stage.sh -- build singularity-boot-splash twice (unpatched and with
# assets/singularity/patches/singularity-loginui applied) and pack a minimal
# guest kernel + initramfs that runs one of them on the QEMU stdvga display.
# Companion of build/hidpi/kvm-splash-shot.sh; manual proof tool, not wired
# into `make`.
#
# Run INSIDE a disposable Debian container that has: gcc, meson, ninja,
# pkg-config, git, libdrm/cairo/pango/gdk-pixbuf dev packages, linux-image-amd64,
# busybox-static, cpio, kmod. Inputs:
#   SPLASH_SRC  singularity-boot-splash checkout (with its loginui submodule)
#   STAGE       output directory (vmlinuz, initrd.img, build logs)
#   LOGO        logo PNG installed as /usr/share/pixmaps/<LOGO_NAME>.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SPLASH_SRC:?set SPLASH_SRC}"
STAGE="${STAGE:?set STAGE}"
LOGO="${LOGO:-$ROOT/assets/branding/greeter/cygnus/ncz-os-cygnus-logo.png}"
LOGO_NAME="${LOGO_NAME:-ncz-os-cygnus}"
mkdir -p "$STAGE"
WORK="$(mktemp -d "${TMPDIR:-$STAGE}/kvmstage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

build_variant() {
    local name="$1" patch="$2"
    cp -a "$SRC" "$WORK/src-$name"
    if [ "$patch" = 1 ]; then
        for p in "$ROOT"/assets/singularity/patches/singularity-loginui/*.patch; do
            git -C "$WORK/src-$name/subprojects/singularity-loginui" apply "$p"
            echo "[$name] applied $(basename "$p")"
        done
    fi
    (cd "$WORK/src-$name" && meson setup build --buildtype=release >"$STAGE/meson-$name.log" 2>&1 \
        && ninja -C build >>"$STAGE/meson-$name.log" 2>&1)
    install -D -m0755 "$WORK/src-$name/build/singularity-boot-splash" \
        "$WORK/root/opt/splash/$name/singularity-boot-splash"
}

mkdir -p "$WORK/root"/{bin,sbin,dev,proc,sys,run,tmp,mnt,etc,usr/share/pixmaps,lib/modules}
build_variant upstream 0
build_variant patched 1

# a one-line decoder probe, run by the guest when booted with ncz_debug=1
cat > "$WORK/probe.c" <<'PROBE'
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdio.h>
int main(int c, char **v) {
    GError *e = NULL;
    GdkPixbuf *p = gdk_pixbuf_new_from_file_at_scale(v[1], -1, 256, TRUE, &e);
    if (!p) { printf("NCZ-SPLASH-PROBE fail: %s\n", e ? e->message : "?"); return 1; }
    printf("NCZ-SPLASH-PROBE ok %dx%d\n", gdk_pixbuf_get_width(p), gdk_pixbuf_get_height(p));
    return 0;
}
PROBE
# shellcheck disable=SC2046
cc -o "$WORK/root/opt/splash/pixbuf-probe" "$WORK/probe.c" $(pkg-config --cflags --libs gdk-pixbuf-2.0)

# userspace: busybox + the dynamic closure of both binaries and the pixbuf loaders
cp /bin/busybox "$WORK/root/bin/busybox"
for a in sh mount mkdir sleep cat echo poweroff modprobe ls grep head seq cp touch switch_root; do ln -sf busybox "$WORK/root/bin/$a"; done
pixdir=$(pkg-config --variable=gdk_pixbuf_binarydir gdk-pixbuf-2.0)
mkdir -p "$WORK/root$pixdir"
cp -a "$pixdir/." "$WORK/root$pixdir/"
# gdk-pixbuf >= 2.44 decodes PNG out of process through glycin (a bwrap
# sandboxed loader), exactly as on the installed system, so ship it too,
# with the shared-mime-info database it uses to recognise the file type.
for f in /usr/bin/bwrap /usr/libexec/glycin-loaders/2+/glycin-image-rs \
         /usr/share/glycin-loaders/2+/conf.d/glycin-image-rs.conf \
         /usr/share/mime/mime.cache /usr/share/mime/magic /usr/share/mime/globs2 \
         /usr/share/mime/types /usr/share/mime/aliases /usr/share/mime/subclasses; do
    [ -e "$f" ] && cp -L --parents "$f" "$WORK/root/"
done
objs=("$WORK"/root/opt/splash/*/singularity-boot-splash "$WORK/root/opt/splash/pixbuf-probe")
for f in /usr/bin/bwrap /usr/libexec/glycin-loaders/2+/glycin-image-rs; do
    [ -e "$f" ] && objs+=("$f")
done
while IFS= read -r so; do objs+=("$so"); done < <(find "$pixdir" -name '*.so')
for o in "${objs[@]}"; do
    ldd "$o" | awk '/=> \// { print $3 } /^\t\/lib|^\t\/usr/ { print $1 }'
done | sort -u | while read -r lib; do
    cp -L --parents "$lib" "$WORK/root/"
done
cp -L --parents /lib64/ld-linux-x86-64.so.2 "$WORK/root/" 2>/dev/null || true
# NB: gdk-pixbuf resolves loaders through loaders.cache, which is copied verbatim
install -m0644 "$LOGO" "$WORK/root/usr/share/pixmaps/$LOGO_NAME.png"
printf 'ID=ncz\nLOGO=%s\n' "$LOGO_NAME" > "$WORK/root/etc/os-release"

# kernel: the container's Debian kernel and just its DRM stack
kver=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -V | tail -1)
cp "/boot/vmlinuz-$kver" "$STAGE/vmlinuz"
mkdir -p "$WORK/root/lib/modules/$kver"
cp -a "/lib/modules/$kver/kernel" "$WORK/root/lib/modules/$kver/"
# keep only what a stdvga guest needs, to keep the initramfs small
K="$WORK/root/lib/modules/$kver/kernel"
find "$K" -type f -name '*.ko*' \
    ! -path "$K/drivers/gpu/drm/*" ! -path "$K/drivers/video/*" ! -path "$K/drivers/i2c/*" \
    ! -path "$K/drivers/dma-buf/*" ! -path "$K/drivers/virtio/*" ! -path "$K/lib/*" -delete
rm -rf "$K"/drivers/gpu/drm/{amd,i915,xe,nouveau,radeon,nova}
cp "/lib/modules/$kver/modules.order" "/lib/modules/$kver/modules.builtin"* "$WORK/root/lib/modules/$kver/" 2>/dev/null || true
depmod -b "$WORK/root" "$kver"

cat > "$WORK/root/init" <<'INIT'
#!/bin/sh
# glycin sandboxes the PNG decoder with bwrap, and bwrap cannot pivot_root out
# of the initramfs rootfs, so first move everything onto a tmpfs root.
if [ ! -e /.ncz-switched ]; then
    mount -t tmpfs -o size=512m tmpfs /mnt
    for d in bin sbin etc lib lib64 usr opt init; do [ -e "/$d" ] && cp -a "/$d" /mnt/; done
    mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/mnt
    touch /mnt/.ncz-switched
    exec switch_root /mnt /init
fi
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /run/singularity
variant=patched
for a in $(cat /proc/cmdline); do case "$a" in ncz_splash=*) variant=${a#ncz_splash=} ;; ncz_debug=1) NCZ_SPLASH_DEBUG=1 ;; esac; done
modprobe bochs 2>/dev/null
modprobe virtio_gpu 2>/dev/null
for i in $(seq 1 50); do [ -e /dev/dri/card0 ] && break; sleep 0.1; done
echo "NCZ-SPLASH-CARD $(ls /dev/dri 2>/dev/null)" > /dev/ttyS0
for s in /sys/class/drm/card*-*/modes; do echo "NCZ-SPLASH-MODES $s $(head -1 "$s")" > /dev/ttyS0; done
[ -n "$NCZ_SPLASH_DEBUG" ] && /opt/splash/pixbuf-probe /usr/share/pixmaps/*.png > /dev/ttyS0 2>&1
G_MESSAGES_DEBUG=${NCZ_SPLASH_DEBUG:+all} /opt/splash/$variant/singularity-boot-splash --device /dev/dri/card0 --wait-seconds 5 --max-life 60 > /dev/ttyS0 2>&1 &
sleep 2
echo "NCZ-SPLASH-RUNNING variant=$variant" > /dev/ttyS0
sleep 60
poweroff -f
INIT
chmod 0755 "$WORK/root/init"
(cd "$WORK/root" && find . | cpio -o -H newc --quiet | zstd -q -3 > "$STAGE/initrd.img")
echo "stage: kernel $kver, initrd $(du -h "$STAGE/initrd.img" | cut -f1)"
