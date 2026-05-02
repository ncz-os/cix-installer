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

# Ensure kmod (depmod, modprobe, lsmod) is present in the chroot.
# d-i's minimal base install doesn't always include it, and 10-our-
# kernel needs depmod to build the module dependency cache. Without
# this explicit install, run 13 hit '/sbin/depmod: cannot execute:
# required file not found'.
apt-get install -y --no-install-recommends kmod

# Kernel binary
install -D -m 0644 "$ASSETS/Image-cixmini.bin" "/boot/vmlinuz-$KVER"

# Modules
#
# CAREFUL: the tarball has a top-level `lib/` directory entry. On a
# usrmerge target (Debian bookworm and later), `/lib` is a SYMLINK to
# `/usr/lib`. `tar xzf -C /` replaces that symlink with a real dir,
# orphaning `/lib/ld-linux-aarch64.so.1` and breaking every dynamically
# linked binary in `/sbin` (depmod -> /bin/kmod, which loads ld-linux).
# Run 14/15/16 hit this — `depmod` exited "required file not found"
# because its interpreter was suddenly unreachable.
#
# Extract into /usr instead: `lib/` lands at `/usr/lib/` (already a
# directory) and modules end up at `/usr/lib/modules/$KVER/`, which is
# the canonical post-usrmerge location. /lib stays a symlink.
mkdir -p "/usr/lib/modules/$KVER"
tar xzf "$ASSETS/modules-cixmini.tgz" -C /usr --strip-components=0 --keep-directory-symlink
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
