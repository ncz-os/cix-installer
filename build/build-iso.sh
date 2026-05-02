#!/bin/bash
# build-iso.sh — repack Debian netinst-arm64 ISO with our customizations.
#
# Process:
#   1. Extract the upstream ISO contents to a staging dir
#   2. Inject preseed.cfg into the initrd of d-i
#   3. Patch GRUB cmdline to autoload the preseed (auto + url=...)
#   4. Stage our /cixmini/ subdir on the ISO with assets + post-install
#      hooks (preseed late_command picks them up via /cdrom/cixmini)
#   5. Repack as UEFI-bootable hybrid ISO via xorriso
#
# Reference: https://wiki.debian.org/DebianInstaller/Preseed/EditIso

set -euo pipefail

UPSTREAM=""
ROOT=""
VERSION=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --upstream) UPSTREAM="$2"; shift 2 ;;
        --root)     ROOT="$2"; shift 2 ;;
        --version)  VERSION="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -f "$UPSTREAM" ] || { echo "ERROR: --upstream not a file"; exit 1; }
[ -d "$ROOT" ]     || { echo "ERROR: --root not a dir"; exit 1; }
[ -n "$VERSION" ]  || { echo "ERROR: --version required"; exit 1; }
[ -n "$OUTPUT" ]   || { echo "ERROR: --output required"; exit 1; }

STAGING="$ROOT/build/iso-staging"
EXTRA="$STAGING/cixmini"

# Sanity: tools we need
for t in xorriso 7z cpio gzip find; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t"; exit 1; }
done

# ----------------------------------------------------------------------
# Step 1 — fresh staging dir
# ----------------------------------------------------------------------
echo "[1] preparing staging at $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# ----------------------------------------------------------------------
# Step 2 — extract upstream ISO contents (via 7z to preserve UEFI bits)
# ----------------------------------------------------------------------
echo "[2] extracting upstream ISO via 7z"
7z x -y -o"$STAGING" "$UPSTREAM" >/dev/null

# ----------------------------------------------------------------------
# Step 3 — inject preseed.cfg into d-i initrd
#
# The d-i initrd (initrd.gz under install.a64/ on bookworm-arm64)
# auto-loads /preseed.cfg if present.
# ----------------------------------------------------------------------
echo "[3] injecting preseed.cfg via concatenated cpio (no extraction needed)"
# Linux initramfs supports concatenated cpio archives — kernel's
# init/initramfs.c reads multiple back-to-back cpio streams and overlays
# them in order. So instead of extracting the d-i initrd (which fails
# without root because it contains device nodes), we just append a
# tiny cpio that contains only preseed.cfg.
#
# Strip the gtk (graphical) installer variant entirely. We only ship a
# character-mode installer — single boot path, no framebuffer console
# dependency, ~600 MB less in the rootfs.gz. If we ever want the gtk
# UI back, restore install.a64/gtk/ here and re-add the menu entry.
if [ -d "$STAGING/install.a64/gtk" ]; then
    rm -rf "$STAGING/install.a64/gtk"
    echo "    removed install.a64/gtk/ (text-mode only)"
fi

PRESEED_WORK="$STAGING/.preseed-cpio"
rm -rf "$PRESEED_WORK"
mkdir -p "$PRESEED_WORK"
cp "$ROOT/preseed/preseed.cfg" "$PRESEED_WORK/preseed.cfg"
PRESEED_GZ="$STAGING/.preseed.cpio.gz"
( cd "$PRESEED_WORK" && echo preseed.cfg | cpio -o -H newc --quiet | gzip ) > "$PRESEED_GZ"

if [ ! -f "$STAGING/install.a64/initrd.gz" ]; then
    echo "ERROR: install.a64/initrd.gz not found"
    ls -R "$STAGING/install.a64" 2>&1 | head -20
    exit 1
fi
cat "$PRESEED_GZ" >> "$STAGING/install.a64/initrd.gz"
echo "    preseed appended to install.a64/initrd.gz"
rm -rf "$PRESEED_WORK" "$PRESEED_GZ"

# ----------------------------------------------------------------------
# Step 3.5 — replace d-i's stock arm64 kernel + modules with our
#            Yocto-built linux-cix-msr1 6.6.10 kernel
#
# Debian's netinst-arm64 ships a generic linux-image-6.1.0-42-arm64
# kernel that doesn't know Cix Sky1 hardware (no GMAC ethernet, no
# Cix MMC controller, no GIC bindings, no Sky1 USB host glue).
# Running d-i on real MS-R1 with that kernel = ethernet autodetect
# fails, drives don't probe, and the screen fills with "wonky kernel
# messages". Our 6.6.10 kernel is the only one that boots this SoC
# cleanly, so we use it for the d-i runtime as well as the installed
# system.
#
# The d-i userspace (busybox + cdebconf + partman + udebs) is kernel-
# agnostic and works fine when run against a different kernel — what
# matters is that /lib/modules/<uname -r>/ inside the initrd matches
# the kernel that's booting. Append a cpio of our modules so that
# directory exists at the right path; d-i's modprobe + hotplug pick
# it up the same way it would for the stock kernel.
# ----------------------------------------------------------------------
if [ -f "$ROOT/assets/kernel/Image-cixmini.bin" ] && \
   [ -f "$ROOT/assets/kernel/modules-cixmini.tgz" ]; then
    echo "[3.5] swapping d-i kernel to linux-cix-msr1 6.6.10 + injecting Cix modules"
    KVER="6.6.10-cix-build-cix-build-generic"

    # Replace install.a64/vmlinuz with our Image (gtk variant already
    # stripped above).
    install -m 0644 "$ROOT/assets/kernel/Image-cixmini.bin" "$STAGING/install.a64/vmlinuz"
    echo "    replaced install.a64/vmlinuz ($(du -h "$STAGING/install.a64/vmlinuz" | cut -f1))"

    # Build a cpio of our modules at the canonical /lib/modules/$KVER/
    # path, then concatenate it onto each initrd. The kernel's
    # initramfs reader merges concatenated cpio streams so this stacks
    # cleanly on top of the preseed cpio + the original Debian initrd.
    MOD_WORK="$STAGING/.modules-cpio"
    rm -rf "$MOD_WORK"
    mkdir -p "$MOD_WORK"
    tar xzf "$ROOT/assets/kernel/modules-cixmini.tgz" -C "$MOD_WORK"
    if [ ! -d "$MOD_WORK/lib/modules/$KVER" ]; then
        echo "ERROR: modules tarball didn't extract to lib/modules/$KVER"
        ls "$MOD_WORK/lib/modules/" 2>&1
        exit 1
    fi

    # Yocto's `make modules_install` ships only the static index files
    # (modules.builtin, modules.order). modules.alias / modules.dep /
    # modules.devname / modules.softdep / modules.symbols are generated
    # by depmod at the *target system's* first boot, not at build time.
    # The d-i runtime never gets that chance — its initramfs is ours,
    # whatever's in our cpio is what udev sees forever. Without
    # modules.alias, udev cannot match hardware uevent MODALIAS strings
    # to .ko paths, so NO driver auto-loads on hotplug — including USB
    # ethernet dongles that should "just work". Run depmod here against
    # the staged module tree so the cpio carries proper alias/dep maps.
    if ! command -v depmod >/dev/null; then
        echo "ERROR: depmod not on PATH; install kmod package on builder"
        exit 1
    fi
    depmod -a -b "$MOD_WORK" "$KVER"
    echo "    depmod-generated index files:"
    ls -la "$MOD_WORK/lib/modules/$KVER/" | grep -E "modules\.(alias|dep|devname|softdep|symbols)" | awk '{print "      " $NF " (" $5 " bytes)"}'

    MOD_GZ="$STAGING/.modules.cpio.gz"
    ( cd "$MOD_WORK" && find lib -print | cpio -o -H newc --quiet | gzip ) > "$MOD_GZ"
    echo "    modules cpio: $(du -h "$MOD_GZ" | cut -f1)"

    cat "$MOD_GZ" >> "$STAGING/install.a64/initrd.gz"
    echo "    modules appended to install.a64/initrd.gz ($(du -h "$STAGING/install.a64/initrd.gz" | cut -f1))"
    rm -rf "$MOD_WORK" "$MOD_GZ"
else
    echo "    WARN: assets/kernel/ missing — d-i will run Debian's stock 6.1 arm64 kernel"
    echo "    expect: ethernet autodetect fail, no Cix block probes, kernel msg noise"
fi

# ----------------------------------------------------------------------
# Step 4 — stage our extras at /cixmini on the ISO
#
# preseed late_command copies /cdrom/cixmini → /target/usr/local/lib/
# cix-installer, then runs run-all.sh in the target chroot.
# ----------------------------------------------------------------------
echo "[4] staging /cixmini extras"
mkdir -p "$EXTRA/post-install" "$EXTRA/assets"
cp -r "$ROOT/post-install/"*.sh "$EXTRA/post-install/"
chmod 755 "$EXTRA/post-install/"*.sh

# late.sh — invoked by preseed late_command from /cdrom/cixmini/late.sh
# (with fallback path detection). Lives at the top of /cixmini/ on the
# ISO so a single hard-coded path can find it across cdrom / hd-media
# / live-medium mountpoint variants.
cp "$ROOT/preseed/late.sh" "$EXTRA/late.sh"
chmod 755 "$EXTRA/late.sh"

# assets/agent-stack — committed quadlet files
cp -rL "$ROOT/assets/agent-stack" "$EXTRA/assets/"
# assets/branding — committed images + Plymouth theme.
# Skip _candidates/ subdir (the AI-image-gen exploration set);
# only ship the canonical-promoted assets that the post-install hooks
# actually consume.
if [ -d "$ROOT/assets/branding" ]; then
    mkdir -p "$EXTRA/assets/branding"
    for sub in logo plymouth gdm wallpaper; do
        if [ -d "$ROOT/assets/branding/$sub" ]; then
            cp -rL "$ROOT/assets/branding/$sub" "$EXTRA/assets/branding/"
        fi
    done
    # also copy the README if present
    [ -f "$ROOT/assets/branding/README.md" ] && cp "$ROOT/assets/branding/README.md" "$EXTRA/assets/branding/" || true
    bytes=$(du -sh "$EXTRA/assets/branding" 2>/dev/null | cut -f1)
    echo "    branding assets: $bytes"
fi

# assets/cix-debs — gitignored, supplied at build time
if [ -d "$ROOT/assets/cix-debs" ] && [ "$(ls -A $ROOT/assets/cix-debs 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/cix-debs" "$EXTRA/assets/"
    echo "    cix-debs: $(ls $EXTRA/assets/cix-debs | wc -l) files, $(du -sh $EXTRA/assets/cix-debs | cut -f1)"
else
    echo "    WARN: assets/cix-debs/ empty — install will skip Cix proprietary layer"
fi

# assets/kernel — gitignored, supplied at build time
if [ -d "$ROOT/assets/kernel" ] && [ "$(ls -A $ROOT/assets/kernel 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/kernel" "$EXTRA/assets/"
    echo "    kernel: $(du -sh $EXTRA/assets/kernel | cut -f1)"
else
    echo "    WARN: assets/kernel/ empty — install will keep Debian's linux-image-arm64"
fi

# ----------------------------------------------------------------------
# Step 5 — patch GRUB cmdline to default to auto-install
# ----------------------------------------------------------------------
echo "[5] prepending nclawzero auto-install entry to GRUB menu"
GRUB_CFG="$STAGING/boot/grub/grub.cfg"
if [ ! -f "$GRUB_CFG" ]; then
    echo "ERROR: $GRUB_CFG not found" >&2
    ls -la "$STAGING/boot/grub/" 2>&1 | head -5
    exit 1
fi

# Replace grub.cfg entirely with a single character-mode auto-install
# entry. We don't ship the gtk variant or the Debian fallback menu —
# this ISO has one job (preseed-driven install of nclawzero on Cix
# Sky1), and the fewer alternate boot paths the cleaner.
cat > "$GRUB_CFG" <<'GRUB'
# nclawzero installer — character-mode auto-install via preseed.
# Boots in 3 seconds. No alternate menu entries.
set timeout=3
set default=0
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue
insmod gzio

menuentry "Install nclawzero (cixmini, auto)" {
    set background_color=black
    echo "Loading linux-cix-msr1 6.6.10..."
    # preseed.cfg is embedded in the initrd (appended cpio, picked up
    # at /preseed.cfg in initramfs root). d-i auto-loads it.
    #
    # Console: tty0 first so the on-screen kernel msgs are visible
    # whenever the framebuffer is alive, plus ttyAMA0,115200 mirror so
    # serial-cable diagnostics keep working when DRM hands off and tty0
    # blanks. earlycon + keep_bootcon = no missing early-boot lines.
    # loglevel=8 + ignore_loglevel = every printk visible. printk.time
    # adds timestamps. panic=10 auto-reboots on panic. clk_ignore_unused
    # is a Cix Sky1 hard requirement.
    #
    # DEBCONF_DEBUG=5 + BOOT_DEBUG=2: verbose d-i logging.
    linux  /install.a64/vmlinuz priority=medium preseed/file=/preseed.cfg interface=auto netcfg/dhcp_timeout=60 DEBCONF_DEBUG=developer BOOT_DEBUG=3 log_host=192.168.207.22 console=tty0 console=ttyAMA0,115200 earlycon keep_bootcon loglevel=8 ignore_loglevel printk.time=y panic=10 clk_ignore_unused drm.debug=0xff log_buf_len=16M video=DP-1:1024x768@60e trilin_dpsub.power_on_delay_ms=250
    echo "Loading initrd..."
    initrd /install.a64/initrd.gz
}
GRUB
echo "    GRUB cfg replaced (single entry, $(wc -l < $GRUB_CFG) lines)"

# ----------------------------------------------------------------------
# Step 6 — rebuild md5sum.txt (d-i checks integrity)
# ----------------------------------------------------------------------
echo "[6] regenerating md5sum.txt"
( cd "$STAGING" && find . -type f \! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )

# ----------------------------------------------------------------------
# Step 7 — repack as UEFI-bootable hybrid ISO via xorriso
# ----------------------------------------------------------------------
echo "[7] repacking via xorriso → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

# Find the EFI image (varies by Debian release layout)
EFI_IMG=""
for candidate in "$STAGING/boot/grub/efi.img" \
                 "$STAGING/efi.img"; do
    [ -f "$candidate" ] && EFI_IMG="$candidate"
done
[ -z "$EFI_IMG" ] && { echo "ERROR: no EFI image found"; exit 1; }
EFI_IMG_REL="${EFI_IMG#$STAGING/}"

# Volume label: ISO 9660 limits to 32 chars, all-uppercase/digits/_
VOLID="NCLAWZERO_CIXMINI"

xorriso -as mkisofs \
    -r -V "$VOLID" \
    -J -joliet-long \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$OUTPUT" \
    "$STAGING"

echo ""
echo "OUTPUT: $OUTPUT"
ls -lh "$OUTPUT"
