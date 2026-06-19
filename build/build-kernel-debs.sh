#!/bin/bash
# build-kernel-debs.sh — debianize the staged cixmini kernels for APT/OTA.
#
# Produces three .debs under build/kernel-debs/:
#   cixmini-boot_<ver>_arm64.deb           — OTA-safe systemd-boot entry hook
#   linux-image-cixmini-lts_<KVER>_arm64.deb
#   linux-image-cixmini-edge_<KVER>_arm64.deb
#
# These are the OTA-upgradable form of post-install/10-our-kernel.sh +
# build/70-bootloader.sh. The bootloader hook is initrd-less and never wipes
# the ESP — it only adds/updates entries for currently-installed kernels,
# matching the validated r97/r98 boot exactly.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"   # cix-installer/
ASSETS="$REPO/assets/kernel"
NPU="$REPO/assets/npu"
OUT="$REPO/build/kernel-debs"
BUILD_REV="${BUILD_REV:-r98}"
MAINT="NCZ <nczero@nclawzero.dev>"

KVER_LTS="${KVER_LTS:-$(cat "$REPO/build/iso-staging-di/cixmini/KVER_LTS" 2>/dev/null || echo 6.18.26-ncz-lts)}"
KVER_NEXT="${KVER_NEXT:-$(cat "$REPO/build/iso-staging-di/cixmini/KVER_NEXT" 2>/dev/null || echo 7.0.12-cix-sky1-next)}"

echo "== build-kernel-debs =="
echo "   LTS=$KVER_LTS  NEXT=$KVER_NEXT  rev=$BUILD_REV"
echo "   out=$OUT"

# Drift guard: verify the kernel/NPU manifest invariants before packaging the
# kernels. Catches e.g. an NPU module whose vermagic != the kernel KVER (the
# armchina_npu.ko is vermagic-locked). Non-fatal by default because the edge/next
# kernel may legitimately be ahead of its NPU rebuild; set STRICT_MANIFEST=1 to
# make any drift abort the build (recommended for release/CI).
if [ -f "$REPO/build/kernel-manifest.py" ]; then
    if ! python3 "$REPO/build/kernel-manifest.py" check; then
        if [ "${STRICT_MANIFEST:-0}" = 1 ]; then
            echo "ERROR: kernel manifest drift (STRICT_MANIFEST=1) — aborting" >&2
            exit 1
        fi
        echo "WARN: kernel manifest drift detected (continuing; set STRICT_MANIFEST=1 to enforce)" >&2
    fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------
# Shared: the OTA-safe bootloader helper (ported from 70-bootloader.sh).
# ----------------------------------------------------------------------
write_bootloader_helper() {
    local dst="$1"
    install -d "$(dirname "$dst")"
    cat > "$dst" <<'HELPER'
#!/bin/bash
# cixmini-update-bootloader — OTA-safe systemd-boot entry generator.
# Faithful to the installer's build/70-bootloader.sh, but:
#   1. NEVER wipes the ESP (no destructive clear of loader/entries).
#   2. Only adds/updates entries for currently-installed cixmini kernels.
#   3. initrd-less, exactly like the validated r97/r98 boot (Sky1 kernel
#      has ext4/nvme/smmu built-in and roots directly via root=PARTUUID).
set -uo pipefail

ESP=/boot/efi
[ -d "$ESP" ] || { echo "cixmini-boot: no ESP at $ESP; skipping"; exit 0; }
command -v bootctl >/dev/null 2>&1 || { echo "cixmini-boot: bootctl missing; skipping"; exit 0; }
if ! findmnt -no FSTYPE "$ESP" 2>/dev/null | grep -qi vfat; then
    echo "cixmini-boot: $ESP not a vfat ESP; skipping"; exit 0
fi

# Idempotent: install systemd-boot only if not already present on the ESP.
bootctl is-installed >/dev/null 2>&1 || \
    bootctl install --esp-path="$ESP" --no-variables >/dev/null 2>&1 || true
mkdir -p "$ESP/loader/entries"

ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC" 2>/dev/null)
[ -n "$ROOT_PARTUUID" ] || { echo "cixmini-boot: cannot determine root PARTUUID; aborting"; exit 0; }

# MartJohnson 2026-04-30 working set for MS-R1 (identical LTS+NEXT), kept in
# lockstep with build/70-bootloader.sh.
CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453 video=DP-4:1920x1080@60e"
ROOT_OPTS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 rw"
SPLASH=""; [ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)
VER="ncz-ota"; [ -f /usr/local/lib/cix-installer/BUILD_VERSION ] && VER=$(cat /usr/local/lib/cix-installer/BUILD_VERSION)

# Discover installed cixmini kernels (must have BOTH a module tree and a vmlinuz).
LTS=""; NEXT=""
for k in $(ls /usr/lib/modules 2>/dev/null); do
    [ -f "/boot/vmlinuz-$k" ] || continue
    case "$k" in
        *-ncz-lts)       LTS="$k" ;;
        *-cix-sky1-next) NEXT="$k" ;;
    esac
done

write_entry() {
    local name="$1" sk="$2" title="$3" k="$4" extra="$5"
    local opts="$ROOT_OPTS $CMDLINE"
    [ -n "$SPLASH" ] && opts="$opts $SPLASH"
    [ -n "$extra" ] && opts="$opts $extra"
    cat > "$ESP/loader/entries/$name.conf" <<EOF
title   $title
sort-key $sk
version $k
linux   /vmlinuz-$k
options $opts
EOF
}

# LTS channel
if [ -n "$LTS" ]; then
    rm -f "$ESP"/vmlinuz-*-ncz-lts 2>/dev/null || true
    install -m 0644 "/boot/vmlinuz-$LTS" "$ESP/vmlinuz-$LTS"
    write_entry cixmini-lts 1-lts "nclawzero (cixmini) — kernel $LTS [LTS, default] — $VER" "$LTS" ""
    echo "cixmini-boot: staged LTS $LTS"
else
    rm -f "$ESP/loader/entries/cixmini-lts.conf" "$ESP"/vmlinuz-*-ncz-lts 2>/dev/null || true
fi

# NEXT/edge channel
if [ -n "$NEXT" ]; then
    rm -f "$ESP"/vmlinuz-*-cix-sky1-next 2>/dev/null || true
    install -m 0644 "/boot/vmlinuz-$NEXT" "$ESP/vmlinuz-$NEXT"
    write_entry cixmini-next 2-next "*** [BETA — UNSTABLE] nclawzero kernel $NEXT — $VER ***" "$NEXT" ""
    echo "cixmini-boot: staged NEXT $NEXT"
else
    rm -f "$ESP/loader/entries/cixmini-next.conf" "$ESP"/vmlinuz-*-cix-sky1-next 2>/dev/null || true
fi

# Rescue prefers LTS, falls back to NEXT.
RESCUE="${LTS:-$NEXT}"
if [ -n "$RESCUE" ]; then
    write_entry cixmini-rescue 3-rescue "SAFE rescue (cixmini) — kernel $RESCUE rescue.target — $VER" "$RESCUE" "systemd.unit=rescue.target"
else
    rm -f "$ESP/loader/entries/cixmini-rescue.conf"
fi

# Safety: never leave the ESP with a default pointing at nothing.
if [ -z "$LTS$NEXT" ]; then
    echo "cixmini-boot: no cixmini kernels installed; leaving loader.conf untouched"
    exit 0
fi
DEFAULT_ENTRY="cixmini-lts"; [ -z "$LTS" ] && DEFAULT_ENTRY="cixmini-next"
cat > "$ESP/loader/loader.conf" <<EOF
default $DEFAULT_ENTRY
timeout 5
console-mode auto
editor yes
EOF
echo "cixmini-update-bootloader: LTS=${LTS:-none} NEXT=${NEXT:-none} default=$DEFAULT_ENTRY"
HELPER
    chmod 0755 "$dst"
}

# ----------------------------------------------------------------------
# Package 1: cixmini-boot
# ----------------------------------------------------------------------
build_cixmini_boot() {
    local root="$WORK/cixmini-boot"
    local ver="1.0+$BUILD_REV"
    rm -rf "$root"
    install -d "$root/DEBIAN" "$root/usr/lib/cixmini" \
        "$root/etc/kernel/postinst.d" "$root/etc/kernel/postrm.d"

    write_bootloader_helper "$root/usr/lib/cixmini/cixmini-update-bootloader"

    # Standard kernel hooks so any future linux-image-* install triggers us too.
    cat > "$root/etc/kernel/postinst.d/zz-cixmini-bootloader" <<'EOF'
#!/bin/sh
set -e
[ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
EOF
    cat > "$root/etc/kernel/postrm.d/zz-cixmini-bootloader" <<'EOF'
#!/bin/sh
set -e
[ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
EOF
    chmod 0755 "$root/etc/kernel/postinst.d/zz-cixmini-bootloader" \
               "$root/etc/kernel/postrm.d/zz-cixmini-bootloader"

    cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
fi
exit 0
EOF
    chmod 0755 "$root/DEBIAN/postinst"

    local isize
    isize=$(du -sk "$root" | cut -f1)
    cat > "$root/DEBIAN/control" <<EOF
Package: cixmini-boot
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: admin
Priority: optional
Installed-Size: $isize
Depends: systemd, efibootmgr, util-linux, kmod
Description: NCZ cixmini systemd-boot entry generator (OTA-safe)
 Idempotent bootloader hook that stages installed cixmini kernels to the ESP
 and writes systemd-boot loader entries (lts/next/rescue) without ever wiping
 the ESP. Invoked automatically on kernel install/upgrade/removal.
EOF
    dpkg-deb --root-owner-group --build "$root" \
        "$OUT/cixmini-boot_${ver}_arm64.deb"
}

# ----------------------------------------------------------------------
# linux-image-cixmini-<channel>
# ----------------------------------------------------------------------
build_kernel_deb() {
    local channel="$1"   # lts | edge
    local kver="$2"
    local label="$3"     # stable | edge (asset subdir)
    local with_npu="$4"  # path to OOT npu .ko, or ""

    local pkg="linux-image-cixmini-$channel"
    local ver="$kver+$BUILD_REV"
    local root="$WORK/$pkg"
    rm -rf "$root"
    install -d "$root/DEBIAN" "$root/boot" "$root/usr"

    echo "  [$channel] $kver -> $pkg ($ver)"
    install -D -m 0644 "$ASSETS/$label/Image-cixmini.bin" "$root/boot/vmlinuz-$kver"
    install -D -m 0644 "$ASSETS/$label/config-$kver"       "$root/boot/config-$kver"

    # Modules: tgz has top-level lib/modules/... -> extract into /usr so it
    # lands at /usr/lib/modules/$kver (usrmerge-safe; see 10-our-kernel.sh).
    tar xzf "$ASSETS/$label/modules-cixmini.tgz" -C "$root/usr" --keep-directory-symlink
    [ -d "$root/usr/lib/modules/$kver" ] || { echo "ERROR: modules tgz did not yield $kver"; exit 1; }
    local mc
    mc=$(find "$root/usr/lib/modules/$kver" -name '*.ko' | wc -l)
    [ "$mc" -ge 50 ] || { echo "ERROR: suspiciously few modules ($mc) for $kver"; exit 1; }

    if [ -n "$with_npu" ]; then
        local vm
        vm=$(modinfo -F vermagic "$with_npu" 2>/dev/null | awk '{print $1}')
        [ "$vm" = "$kver" ] || { echo "ERROR: NPU ko vermagic '$vm' != '$kver'"; exit 1; }
        install -D -m 0644 "$with_npu" "$root/usr/lib/modules/$kver/extra/armchina_npu.ko"
        echo "    baked OOT armchina_npu.ko (vermagic $vm)"
    fi

    # Drop stale dep maps; postinst regenerates with depmod on target.
    rm -f "$root/usr/lib/modules/$kver"/modules.dep* \
          "$root/usr/lib/modules/$kver"/modules.alias* \
          "$root/usr/lib/modules/$kver"/modules.symbols* 2>/dev/null || true

    cat > "$root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
KVER="$kver"
if [ "\$1" = configure ]; then
    depmod -a "\$KVER" || true
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -c -k "\$KVER" 2>/dev/null || update-initramfs -u -k "\$KVER" 2>/dev/null || true
    fi
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
fi
exit 0
EOF
    cat > "$root/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
KVER="$kver"
case "\$1" in
  remove|purge)
    rm -f "/boot/initrd.img-\$KVER" "/boot/efi/vmlinuz-\$KVER" "/boot/efi/initrd.img-\$KVER" 2>/dev/null || true
    rm -rf "/usr/lib/modules/\$KVER" 2>/dev/null || true
    [ -x /usr/lib/cixmini/cixmini-update-bootloader ] && /usr/lib/cixmini/cixmini-update-bootloader || true
    ;;
esac
exit 0
EOF
    chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

    local isize
    isize=$(du -sk "$root" | cut -f1)
    cat > "$root/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: arm64
Maintainer: $MAINT
Section: kernel
Priority: optional
Installed-Size: $isize
Depends: cixmini-boot, kmod, initramfs-tools, systemd
Provides: linux-image-cixmini
Description: NCZ cixmini Linux kernel ($channel channel, $kver)
 Prebuilt linux-cix-sky1 kernel image + modules for the NCZ cixmini (MS-R1).
 Installs vmlinuz, the module tree$( [ -n "$with_npu" ] && echo " (incl. armchina_npu)") and config,
 then refreshes the systemd-boot entry via cixmini-boot.
EOF
    dpkg-deb --root-owner-group --build "$root" "$OUT/${pkg}_${ver}_arm64.deb"
}

build_cixmini_boot
build_kernel_deb lts  "$KVER_LTS"  stable "$NPU/armchina_npu-${KVER_LTS}.ko"
build_kernel_deb edge "$KVER_NEXT" edge   ""

echo ""
echo "== built debs =="
ls -lh "$OUT"
echo ""
echo "== control summaries =="
for d in "$OUT"/*.deb; do
    echo "--- $d ---"
    dpkg-deb -f "$d" Package Version Architecture Depends Installed-Size
done
