#!/bin/bash
# 60-boot-splash.sh — NCZ-OS 26.7 native KMS boot splash (Plymouth REPLACEMENT).
#
# ZERO-COMPROMISE NATIVE STACK (supersedes 60-plymouth). singularity-boot-splash
# (github.com/singularityos-lab/singularity-boot-splash) is a toolkit-less KMS
# splash: it opens /dev/dri/card0 directly, waits for a connected output+mode
# (--wait-seconds — the exact reason plymouth failed on Sky1: KMS comes up LATE,
# after the DP link trains, so plymouth in the initramfs had no framebuffer and
# the screen stayed dark), double-buffers an animated NCZ logo + loading bar with
# the shared singularity-loginui Cairo renderer, and hands the display to the
# labwc greeter. Same loginui pixels as the greeter/lock/session-splash. Ships in
# the /opt/singularity payload (build-singularity.sh builds it into the tarball);
# a separately-staged asset is a fallback if the payload predates it.
#
# This hook: (1) ensure the binary is present, (2) install + enable the systemd
# unit that paints from early boot to the greeter, (3) PURGE plymouth entirely.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop).
set +e

echo "[60] native KMS boot splash (singularity-boot-splash) — plymouth replacement"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[60] BUILD_VARIANT=$VARIANT — headless SKU; skipping boot splash"
        exit 0
        ;;
esac

BSP=/opt/singularity/bin/singularity-boot-splash

# --- (1) ensure the binary is present ----------------------------------------
if [ ! -x "$BSP" ]; then
    echo "[60] singularity-boot-splash not in payload — installing staged asset"
    for c in /usr/local/lib/cix-installer/assets/singularity-boot-splash/singularity-boot-splash \
             /cdrom/assets/singularity-boot-splash/singularity-boot-splash \
             /run/cixmini/assets/singularity-boot-splash/singularity-boot-splash; do
        if [ -f "$c" ]; then
            install -d -m0755 /opt/singularity/bin
            install -m0755 "$c" "$BSP"
            echo "[60] installed singularity-boot-splash -> $BSP"
            break
        fi
    done
fi
if [ ! -x "$BSP" ]; then
    echo "[60] WARN: singularity-boot-splash absent (payload + staged asset both missing) — no native splash" >&2
fi

# --- (2) systemd unit: paint from early boot to the greeter ------------------
# Runs as root, owns /dev/tty1 in process mode. --wait-seconds tolerates Sky1's
# late KMS (DP link-train). When greetd (vt=7) brings up the labwc greeter, the
# VT switch away from tty1 makes boot-splash drop DRM master so the greeter paints
# over it; --max-life is the safety cap so it never wedges the framebuffer.
# NOTE(metal): the exact boot-splash -> greeter handoff timing is gated on the
# Sky1 DP-link-training/early-framebuffer work (fix/trilin-dp-link-training) — the
# splash cannot paint before KMS is live; validate on-metal once DP trains early.
cat > /etc/systemd/system/singularity-boot-splash.service <<'UNIT'
[Unit]
Description=NCZ-OS native KMS boot splash (singularity-boot-splash)
Documentation=https://github.com/singularityos-lab/singularity-boot-splash
DefaultDependencies=no
After=systemd-udevd.service local-fs.target
Before=greetd.service
Conflicts=getty@tty1.service plymouth-start.service plymouth-quit.service

[Service]
Type=simple
ExecStart=/opt/singularity/bin/singularity-boot-splash --device /dev/dri/card0 --wait-seconds 12 --max-life 30
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
UNIT
systemctl enable singularity-boot-splash.service 2>/dev/null || \
    ln -sf /etc/systemd/system/singularity-boot-splash.service \
        /etc/systemd/system/graphical.target.wants/singularity-boot-splash.service
echo "[60] singularity-boot-splash.service installed + enabled (Before=greetd, tty1)"

# --- (3) PURGE plymouth entirely (operator: native KMS splash only) ----------
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"
echo "[60] purging plymouth (superseded by native KMS boot splash)"
DEBIAN_FRONTEND=noninteractive apt-get purge -y 'plymouth*' 2>/dev/null || \
    echo "[60] apt purge plymouth returned nonzero (may be absent already) — continuing"
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
# Scrub any residual plymouth wiring the old 60-plymouth hook left behind.
rm -f /etc/systemd/system/plymouth-quit.service.d/10-retain-splash.conf 2>/dev/null
rmdir /etc/systemd/system/plymouth-quit.service.d 2>/dev/null || true
rm -f /etc/initramfs-tools/conf.d/10-ncz-splash.conf 2>/dev/null
rm -f /etc/plymouth/plymouthd.conf 2>/dev/null
# Drop the plymouth DRM modules the old hook forced into the initramfs (the native
# splash opens KMS from userspace after root mounts, so no early-KMS initramfs
# modules are needed for the splash). Leave the file present but emptied of them.
if [ -f /etc/initramfs-tools/modules ]; then
    sed -i -E '/^(linlon_dp|linlondp|komeda|trilin_dpsub|panthor)$/d' /etc/initramfs-tools/modules 2>/dev/null || true
fi

# --- initramfs rebuild (plymouth removal changes the initramfs) --------------
KERNELS=""
for sidecar in /usr/local/lib/cix-installer/KVER_LTS /usr/local/lib/cix-installer/KVER_NEXT; do
    if [ -s "$sidecar" ]; then
        kver=$(tr -d ' \t\r\n' < "$sidecar")
        [ -n "$kver" ] && [ -d "/lib/modules/$kver" ] && KERNELS="$KERNELS $kver"
    fi
done
if [ -z "$KERNELS" ]; then
    for initrd in /boot/initrd.img-*; do
        [ -e "$initrd" ] || continue
        kver=${initrd#/boot/initrd.img-}
        [ -d "/lib/modules/$kver" ] && KERNELS="$KERNELS $kver"
    done
fi
KERNELS=$(printf '%s\n' $KERNELS | awk 'NF && !seen[$0]++')
for kver in $KERNELS; do
    if [ -f "/boot/initrd.img-$kver" ]; then
        update-initramfs -u -k "$kver" 2>&1 | tail -2
    else
        update-initramfs -c -k "$kver" 2>&1 | tail -2
    fi
done
echo "[60] plymouth purged; native singularity-boot-splash enabled; initramfs rebuilt for:$KERNELS"
