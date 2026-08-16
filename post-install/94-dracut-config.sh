#!/bin/bash
# 94-dracut-config.sh — stage the Sky1 dracut configuration.
#
# WHY THIS EXISTS, AND WHY IT DOES NOT SWITCH ANYTHING:
# Debian is switching the default initramfs builder to dracut during the FORKY
# cycle, which is the release we are on (Debian bug #1114857: the kernel team
# and the dracut maintainers agreed the change, the kernel dependency becomes
# "dracut | initramfs-tools | linux-initramfs-tool", and new d-i installs are
# expected to include dracut). So we will land on dracut whether or not we
# choose it, and we would rather arrive with a config we measured than inherit
# a default we did not.
#
# But we are NOT flipping the default here. initramfs-tools remains the
# preferred alternative in the kernel package Depends, and this hook only
# DROPS A CONFIG FILE. It does nothing at all unless dracut is installed.
# The switch itself is gated on:
#   1. KVM boot validation (done once: both initrds boot clean, no oops), and
#   2. a supervised O6N metal boot, with the initramfs-tools initrd retained as
#      a working rescue boot entry throughout.
# initramfs-tools is NOT to be purged afterwards: it is a FALLBACK, not
# redundancy (operator rule: remove legacy that is redundant, keep legacy that
# is a fallback).
#
# What the config carries and why is documented in the file itself; the short
# version is that stock dracut silently omits linlon-dp -- the only video
# console on the O6N -- and the whole USB-ethernet recovery set, while
# producing a module COUNT identical to initramfs-tools (45 vs 45).
#
# Idempotent, re-runnable, never fatal.
set -euo pipefail

CONF_NAME=10-ncz-sky1.conf
DST_DIR=/etc/dracut.conf.d
DST="$DST_DIR/$CONF_NAME"
PIN_NAME=99-ncz-initramfs-tool
PIN_DST="/etc/apt/preferences.d/$PIN_NAME"

# Install the apt pin FIRST and unconditionally -- it must be present even when
# dracut is not, because its whole job is to stop dracut being pulled in
# automatically. linux-image-cixmini depends on
# "initramfs-tools | dracut | linux-initramfs-tool", and without this pin
# `apt remove initramfs-tools` would be satisfied by installing dracut,
# silently switching the initramfs builder. initramfs-tools is a FALLBACK and
# must not be purged as a side effect.
for _p in "${INSTALLER_META:-/usr/local/lib/cix-installer}/assets/dracut/$PIN_NAME" \
          "/cdrom/cixmini/assets/dracut/$PIN_NAME"; do
    if [ -r "$_p" ]; then
        mkdir -p /etc/apt/preferences.d
        if cmp -s "$_p" "$PIN_DST"; then
            echo "[94] apt pin already current: $PIN_DST"
        else
            install -m 0644 "$_p" "$PIN_DST"
            echo "[94] installed apt pin $PIN_DST (dracut not auto-installable)"
        fi
        break
    fi
done

# PERFORM the migration; do not assume it already happened.
#
# The base squashfs layer is unpacked from a prebuilt rootfs tarball that still
# contains initramfs-tools, and manifests/installer-base.pkgs only seeds the
# MIRROR -- it is never installed into a layer. So apt satisfies the kernel's
#   Depends: dracut | initramfs-tools | linux-initramfs-tool
# with the initramfs-tools already present, and dracut never arrives on its own.
# Measured while building the first dracut-primary ISO: base.squashfs contained
# update-initramfs and zero dracut binaries.
#
# Order matters. dracut is installed FIRST so the kernel's dependency is
# satisfied at every point; only then is initramfs-tools removed. Doing it the
# other way round would momentarily leave linux-image-cixmini unsatisfiable.
if ! dpkg-query -W -f='${Status}' dracut 2>/dev/null | grep -q "install ok installed"; then
    echo "[94] installing dracut (primary initramfs builder for 26.7)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dracut 2>&1 | tail -4; then
        echo "[94] FATAL: could not install dracut, and it is the PRIMARY initramfs" >&2
        echo "[94]        builder. Check the offline mirror carries dracut + dracut-core" >&2
        echo "[94]        (seeded in manifests/installer-base.pkgs)." >&2
        exit 1
    fi
fi

if dpkg-query -W -f='${Status}' initramfs-tools 2>/dev/null | grep -q "install ok installed"; then
    # Safe now that dracut Provides linux-initramfs-tool. Simulated first: if the
    # removal would take anything except initramfs-tools and its own helpers with
    # it, leave it alone and say so rather than gutting the image.
    _rm=$(apt-get remove -s -y initramfs-tools 2>/dev/null | grep -c '^Remv')
    if [ "${_rm:-99}" -le 3 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y initramfs-tools 2>&1 | tail -3
        echo "[94] initramfs-tools removed (dracut is the builder; it survives in the rescue toolkit)"
    else
        echo "[94] WARN: removing initramfs-tools would take $_rm packages — left installed;"
        echo "[94]       dracut still owns the initrd (update_initramfs disabled below)"
    fi
fi

SRC=""
for _s in "${INSTALLER_META:-/usr/local/lib/cix-installer}/assets/dracut/$CONF_NAME" \
          "/cdrom/cixmini/assets/dracut/$CONF_NAME"; do
    [ -r "$_s" ] && { SRC="$_s"; break; }
done
if [ -z "$SRC" ]; then
    echo "[94] WARNING: $CONF_NAME not found in assets; dracut left at its defaults" >&2
    exit 0
fi

mkdir -p "$DST_DIR"
if cmp -s "$SRC" "$DST"; then
    echo "[94] $DST already current"
else
    install -m 0644 "$SRC" "$DST"
    echo "[94] installed $DST"
fi

# --- generate the initrd -------------------------------------------------
# dracut is the primary builder as of 26.7, so this hook now OWNS the initrd
# rather than merely staging config. The old "gated switch" comment here is
# obsolete: the gate was passed on O6N 2026-08-16 (booted to desktop on a
# dracut initrd, dracut-112-1 in the journal, zero initramfs-tools fingerprints,
# zero failed units).
#
# If initramfs-tools is present for any reason, stop it regenerating so there is
# exactly ONE builder writing initrd.img-<kver>. Two builders racing for the
# same path is the "two sources of truth" failure this project keeps paying for.
if [ -d /etc/initramfs-tools ]; then
    install -d -m 0755 /etc/initramfs-tools
    if ! grep -qs '^update_initramfs=no' /etc/initramfs-tools/update-initramfs.conf 2>/dev/null; then
        # Rewrite the existing assignment rather than appending a second one.
        # Appending left the shipped `update_initramfs=yes` in place with
        # `update_initramfs=no` below it -- last-wins makes that behave, but a
        # config file that states both answers is one edit away from stating
        # the wrong one, and it reads as an accident to whoever opens it next.
        # OBSERVED on the r243 KVM install: both lines present in the target.
        sed -i 's/^[[:space:]]*update_initramfs=.*/update_initramfs=no/' \
            /etc/initramfs-tools/update-initramfs.conf 2>/dev/null || true
        grep -qs '^update_initramfs=no' /etc/initramfs-tools/update-initramfs.conf 2>/dev/null || \
            printf 'update_initramfs=no\n' >> /etc/initramfs-tools/update-initramfs.conf
        echo "[94] initramfs-tools present — regeneration disabled (dracut owns the initrd)"
    fi
fi

rc=0
for _kdir in /usr/lib/modules/*/; do
    _kver="$(basename "$_kdir")"
    [ -s "/boot/vmlinuz-$_kver" ] || continue
    if dracut --force --kver "$_kver" "/boot/initrd.img-$_kver" >/dev/null 2>&1; then
        # Verify rather than trust: with no initramfs-tools to fall back on, a
        # silent dracut failure would leave the system with no initrd and the
        # rEFInd generator would then refuse to write a boot entry at all.
        if [ -s "/boot/initrd.img-$_kver" ]; then
            echo "[94] built initrd.img-$_kver ($(du -h "/boot/initrd.img-$_kver" | cut -f1)) with dracut"
        else
            echo "[94] ERROR: dracut reported success but /boot/initrd.img-$_kver is empty" >&2
            rc=1
        fi
    else
        echo "[94] ERROR: dracut failed to build an initrd for $_kver" >&2
        rc=1
    fi
done
exit $rc
