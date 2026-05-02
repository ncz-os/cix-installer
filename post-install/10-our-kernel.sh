#!/bin/bash
# 10-our-kernel.sh — install our linux-cix-msr1 6.6.10 kernel.
#
# Replaces Debian's linux-image-arm64 (which would otherwise be the
# default kernel post-base-install) with the Yocto-built linux-cix-msr1
# kernel from meta-cix. The kernel binary + matching modules tarball
# are bundled on the installer ISO under assets/kernel/.
set -euo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/kernel
[ -f "$ASSETS/Image-cixmini.bin" ] || { echo "ERROR: kernel binary missing"; exit 1; }
[ -f "$ASSETS/modules-cixmini.tgz" ] || { echo "ERROR: modules tarball missing"; exit 1; }

# Our kernel uname-r:
KVER="6.6.10-cix-build-cix-build-generic"
echo "[10] installing kernel $KVER"

# Kernel binary
install -D -m 0644 "$ASSETS/Image-cixmini.bin" "/boot/vmlinuz-$KVER"

# Modules
mkdir -p "/lib/modules/$KVER"
tar xzf "$ASSETS/modules-cixmini.tgz" -C / --strip-components=0
depmod -a "$KVER"

# Remove Debian's default linux-image-arm64 — we ship our own.
# Use --force-no-remove-essential because some Debian stuff considers
# linux-image essential. We're replacing it, not deleting.
apt-get remove -y --purge "linux-image-arm64" || true
apt-get autoremove -y --purge || true

echo ""
echo "Kernel binary + modules:"
ls -lh "/boot/vmlinuz-$KVER"
ls "/lib/modules/$KVER" | head -10
