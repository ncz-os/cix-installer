#!/bin/bash
# 60-boot-splash.sh — NCZ-OS 26.7 native KMS boot splash (Plymouth REPLACEMENT).
#
# ZERO-COMPROMISE NATIVE STACK (supersedes 60-plymouth). singularity-boot-splash
# (github.com/singularityos-lab/singularity-boot-splash) is a toolkit-less KMS
# splash: it opens the DRM card with a connected output and waits for a mode.
# DRM card numbering is not stable (on O6N the monitor is commonly card1).
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
    echo "[60] ERROR: singularity-boot-splash absent (payload + staged asset both missing)" >&2
    echo "[60] keeping Plymouth and refusing to enable a service with a missing ExecStart" >&2
    systemctl disable singularity-boot-splash.service 2>/dev/null || true
    rm -f /etc/systemd/system/graphical.target.wants/singularity-boot-splash.service
    rm -f /etc/systemd/system/singularity-boot-splash.service
    exit 1
fi
_splash_missing=$(ldd "$BSP" 2>&1 | awk '/not found/ { print }')
if [ -n "$_splash_missing" ]; then
    echo "[60] ERROR: unresolved singularity-boot-splash runtime libraries:" >&2
    printf '%s\n' "$_splash_missing" | sed 's/^/[60]   /' >&2
    exit 1
fi
echo "[60] verified: singularity-boot-splash dynamic-link closure complete"

# --- (2) systemd unit: paint from early boot to the greeter ------------------
# Runs as root, owns /dev/tty1 in process mode. It remains visible while Sky1
# USB recovery obtains a keyboard, then the greeter creates a readiness marker
# that makes the splash drop DRM master before labwc starts. This avoids both a
# fixed-duration boot delay and a black splash->greeter gap.
# NOTE(metal): the exact boot-splash -> greeter handoff timing is gated on the
# Sky1 DP-link-training/early-framebuffer work (fix/trilin-dp-link-training) — the
# splash cannot paint before KMS is live; validate on-metal once DP trains early.
cat > /usr/local/bin/ncz-boot-splash <<'WRAPPER'
#!/bin/sh
set -eu
BSP=/opt/singularity/bin/singularity-boot-splash
install -d -m 1777 /run/singularity
rm -f /run/singularity/greeter-ready
card=""
for status in /sys/class/drm/card*-*/status; do
    [ -f "$status" ] || continue
    [ "$(cat "$status" 2>/dev/null || true)" = connected ] || continue
    name=$(basename "$(dirname "$status")")
    card="/dev/dri/${name%%-*}"
    [ -e "$card" ] && break
    card=""
done
if [ -z "$card" ]; then
    echo "boot-splash: no connected DRM output; skipping"
    exit 0
fi
echo "boot-splash: using connected DRM device $card"
set +e
# The splash exits immediately when the greeter marker appears. Keep a safety
# cap for headless/failed-greeter boots, but never use the cap as normal timing.
timeout --kill-after=2s 22s "$BSP" --device "$card" --wait-seconds 2 --handoff 0.4 --max-life 20
rc=$?
set -e
if [ "$rc" -eq 1 ] || [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "boot-splash: DRM already owned; skipping"
    exit 0
fi
exit "$rc"
WRAPPER
chmod 0755 /usr/local/bin/ncz-boot-splash

cat > /etc/systemd/system/singularity-boot-splash.service <<'UNIT'
[Unit]
Description=NCZ-OS native KMS boot splash (singularity-boot-splash)
Documentation=https://github.com/singularityos-lab/singularity-boot-splash
DefaultDependencies=no
# DRM connectors are populated asynchronously after the kernel registers the
# Sky1 display pipeline. Wait for the detector so the splash does not race the
# connector and incorrectly conclude that the machine is headless. Do not order
# greetd after this unit: it supplies the greeter-ready handoff marker.
After=systemd-udevd.service systemd-udev-settle.service local-fs.target cix-detect-display.service
Before=graphical.target
Conflicts=getty@tty1.service plymouth-start.service plymouth-quit.service

[Service]
# Type=oneshot owns DRM until the greeter-ready marker requests a handoff.
# greetd starts after USB readiness in parallel with this unit.
Type=oneshot
RemainAfterExit=no
TimeoutStartSec=22s
# Wait for late Sky1 KMS without turning a legitimately headless/KVM boot into
# a failed service. ExecCondition exit 1 is a clean skip, not a unit failure.
ExecStart=/usr/local/bin/ncz-boot-splash
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
echo "[60] singularity-boot-splash.service installed + enabled (adaptive greeter handoff, tty1)"

# --- (3) PURGE plymouth entirely (operator: native KMS splash only) ----------
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"
# Record which initrds the package trigger rebuilds. The explicit pass below
# updates only kernels that the purge did not already regenerate.
INITRAMFS_STAMPS="/tmp/ncz-initramfs-before.$$"
mkdir -p "$INITRAMFS_STAMPS"
for initrd in /boot/initrd.img-*; do
    [ -f "$initrd" ] || continue
    stat -c %Y "$initrd" > "$INITRAMFS_STAMPS/${initrd##*/}" 2>/dev/null || true
done
echo "[60] purging plymouth (superseded by native KMS boot splash)"
PLYMOUTH_PURGE_RC=0
DEBIAN_FRONTEND=noninteractive apt-get purge -y 'plymouth*' 2>/dev/null || \
    PLYMOUTH_PURGE_RC=$?
# Do not run a global autoremove here. On v14 it removed 77 packages, including
# pipewire-alsa and other packages installed explicitly by 20-desktop.sh.
# A nonzero apt result can be harmless when no Plymouth package was installed.
# The installed-package query below is authoritative. If anything remains,
# neutralize only those residual units so plymouth-quit-wait cannot hold the
# graphical boot forever (the exact failure captured on the O6 serial console).
PLYMOUTH_REMAINS=$(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' \
    'plymouth*' 2>/dev/null | awk '$2 ~ /^ii/ { print $1 }')
if [ -n "$PLYMOUTH_REMAINS" ]; then
    echo "[60] ERROR: Plymouth packages remain after purge (apt rc=$PLYMOUTH_PURGE_RC):" >&2
    printf '%s\n' "$PLYMOUTH_REMAINS" | sed 's/^/[60]   /' >&2
    for unit in plymouth-start.service plymouth-read-write.service \
                plymouth-quit.service plymouth-quit-wait.service \
                plymouth-switch-root.service \
                plymouth-switch-root-initramfs.service \
                plymouth-halt.service plymouth-kexec.service \
                plymouth-poweroff.service plymouth-reboot.service \
                systemd-ask-password-plymouth.path \
                systemd-ask-password-plymouth.service; do
        systemctl disable "$unit" >/dev/null 2>&1 || true
        systemctl mask "$unit" >/dev/null 2>&1 || true
    done
else
    echo "[60] verified: no installed Plymouth packages remain"
fi
# Scrub any residual plymouth wiring the old 60-plymouth hook left behind.
rm -f /etc/systemd/system/plymouth-quit.service.d/10-retain-splash.conf 2>/dev/null
rmdir /etc/systemd/system/plymouth-quit.service.d 2>/dev/null || true
rm -f /etc/initramfs-tools/conf.d/10-ncz-splash.conf 2>/dev/null
rm -f /etc/plymouth/plymouthd.conf 2>/dev/null
# The native splash is systemd/KMS-driven and does not consume a kernel `splash`
# flag. Pin the graphical cmdline to quiet early console messages without hiding
# them from dmesg/journal/serial. ncz-refind-refresh reads this compatibility
# filename for both the initial install and later kernel upgrades.
install -d -m0755 /etc/kernel/cmdline.d
cat > /etc/kernel/cmdline.d/10-splash.conf <<'CMDLINE'
quiet loglevel=3 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false
CMDLINE
# Drop the plymouth DRM modules the old hook forced into the initramfs (the native
# splash opens KMS from userspace after root mounts, so no early-KMS initramfs
# modules are needed for the splash). Leave the file present but emptied of them.
if [ -f /etc/initramfs-tools/modules ]; then
    sed -i -E '/^(linlon_dp|linlondp|komeda|trilin_dpsub|panthor)$/d' /etc/initramfs-tools/modules 2>/dev/null || true
fi

# --- initramfs rebuild (plymouth removal changes the initramfs) --------------
KERNELS=""
for sidecar in /usr/local/lib/cix-installer/KVER_NEXT; do
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
    initrd="/boot/initrd.img-$kver"
    before=$(cat "$INITRAMFS_STAMPS/${initrd##*/}" 2>/dev/null || echo 0)
    after=$(stat -c %Y "$initrd" 2>/dev/null || echo 0)
    if [ "$before" -gt 0 ] && [ "$after" -gt "$before" ]; then
        echo "[60] initramfs already rebuilt by package trigger: $kver"
        continue
    fi
    if [ -f "/boot/initrd.img-$kver" ]; then
        update-initramfs -u -k "$kver" 2>&1 | tail -2
    else
        update-initramfs -c -k "$kver" 2>&1 | tail -2
    fi
done
rm -rf "$INITRAMFS_STAMPS"
echo "[60] plymouth purged; native singularity-boot-splash enabled; initramfs rebuilt for:$KERNELS"
if [ -n "$PLYMOUTH_REMAINS" ]; then
    echo "[60] ERROR: residual Plymouth packages were neutralized but must be investigated" >&2
    exit 1
fi
