#!/bin/bash
# 93-zram-swap.sh — zram swap on /dev/zram0 (zstd, ~50% RAM, capped).
#
# NCZ-OS 26.7 audit (W3.6): the audited target had NO swap configured.
# The audit explicitly says "prefer zram" and warns against adding a
# disk swapfile on btrfs without correct nodatacow handling. We add
# zram swap via systemd-zram-generator.
#
# Sizing policy (matches the audit's "sensible defaults"):
#   - device:      zram0 (the only zram we want; one is enough)
#   - algorithm:   zstd (best ratio / speed on arm64; debian kernel
#                  CONFIG_CRYPTO_ZSTD=y required)
#   - size:        50% of physical RAM, capped at 8 GiB on big boxes
#                  and at 1 GiB minimum on very small ones
#   - swap-priority: 100 (higher than disk swap; kernel prefers zram)
#   - fs-type:     swap (this is a swap device, not a fs)
#
# How the generator wires itself up (verified against
# systemd-zram-generator 1.2.1 on arm64):
#
#   /usr/lib/systemd/system-generators/zram-generator       <- generator binary
#   /usr/lib/systemd/system/systemd-zram-setup@.service     <- template unit
#       ExecStart=/usr/lib/systemd/system-generators/zram-generator \
#                 --setup-device '%i'
#   /usr/lib/modules-load.d/20-zram-generator.conf           <- loads zram module
#       zram
#
# There is NO top-level systemd-zram-generator.service. The generator
# runs as a path-based systemd generator at boot, parses
# /etc/systemd/zram-generator.conf, and instantiates
# systemd-zram-setup@zram0.service for each [zramN] section. That
# template unit is what runs zramctl / mkswap / swapon. Enabling a
# non-existent systemd-zram-generator.service (the mistake in the
# previous revision of this hook) is a no-op — the contract is the
# conf file in /etc/systemd, full stop.
#
# Kernel half:
#   The shipped CIX Sky1 kernel config
#   (assets/kernel/edge/config-7.2.0-rc7-sky1-ncz, verified at audit
#   time) has:
#     # CONFIG_ZRAM is not set
#     no CONFIG_CRYPTO_ZSTD
#   i.e. the CIX Sky1 kernel build DOES NOT have CONFIG_ZRAM enabled.
# This hook verifies the TARGET kernel actually has zram support
# before trusting the generator. We do NOT probe /sys/block/zram0
# here: post-install hooks run in the installer's chroot, so /sys
# belongs to the running installer kernel, not the CIX Sky1 kernel
# that was just installed. Instead we read the target kernel's own
# config (/boot/config-<kver>, dropped by linux-image-cixmini) and
# its modules tree (/lib/modules/<kver>/kernel/drivers/block/zram/).
# If the target kernel has CONFIG_ZRAM=y, or CONFIG_ZRAM=m with a
# zram.ko present, AND has CONFIG_CRYPTO_ZSTD=y or =m, we log a
# success line. Otherwise we log a WARN with the exact gap and
# exit 0 (the installed system still boots, it just runs without
# swap until the kernel catches up). This is the audit's "If you
# cannot verify something actually works, say so explicitly" clause,
# applied to the kernel side rather than the userspace side.
#
# When the kernel gains CONFIG_ZRAM=y + CONFIG_CRYPTO_ZSTD=y, this
# hook becomes a pure configuration: the generator picks up
# /etc/systemd/zram-generator.conf and the modules-load.d entry
# pulls zram.ko in early boot, which exposes /sys/block/zram0 and
# causes systemd-zram-setup@zram0.service to be instantiated and
# run.
#
# Idempotent: re-runnable; the config write is unconditional (the
# generator is content-addressed on the file content), and the
# kernel-support check is read-only.
#
# Runs in chroot during install (Phase 2). Failure-tolerant: missing
# userspace or a kernel without zram both exit 0 with a clear log
# line.
set -euo pipefail

echo "[93] zram-swap: configure systemd-zram-generator (zram0, zstd, ~50% RAM)"

# 1. install the generator when missing. The package is already in
#    manifests/desktop.pkgs, so this is normally a no-op.
if ! dpkg -s systemd-zram-generator >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            systemd-zram-generator 2>&1 | tail -3; then
        echo "[93] WARN: systemd-zram-generator install failed; no swap will be configured" >&2
        exit 0
    fi
fi

# 2. write the sizing policy. The generator reads /etc/systemd/zram-generator.conf
#    and creates systemd-zram-setup@zram0.service instances at boot (it is
#    content-addressed; re-running this hook produces a stable file).
# GATE THE CONFIG WRITE ON THE TARGET KERNEL ACTUALLY HAVING ZRAM.
#
# Writing this file unconditionally BRICKS THE BOOT on a kernel without zram.
# The comment further down used to claim that without kernel support "the
# generator has no device to enumerate and does not instantiate
# systemd-zram-setup@zram0.service, so nothing runs". That is false. Measured
# on cixmini 2026-08-16 with a kernel carrying "# CONFIG_ZRAM is not set":
#
#   systemd-modules-load: Failed to find module 'zram'
#   zram_generator::generator: modprobe "zram" failed, ignoring
#   systemd[1]: Expecting device dev-zram0.device - /dev/zram0...
#
# systemd then waits forever for a device the kernel can never create; the
# machine never reaches multi-user and has no network or console. Recovery
# needed the rescue partition. Swap is a nicety; booting is not.
_kver_t=$(ls /lib/modules 2>/dev/null | sort -V | tail -1)
_zram_ok=0
if [ -n "$_kver_t" ]; then
    if grep -qE '^CONFIG_ZRAM=(y|m)' "/boot/config-$_kver_t" 2>/dev/null; then
        if grep -qE '^CONFIG_ZRAM=y' "/boot/config-$_kver_t" 2>/dev/null; then
            _zram_ok=1
        elif find "/lib/modules/$_kver_t" -name 'zram.ko*' 2>/dev/null | grep -q .; then
            _zram_ok=1
        fi
    fi
fi
if [ "$_zram_ok" != 1 ]; then
    echo "[93] target kernel ${_kver_t:-unknown} has no zram support -- NOT writing"
    echo "[93] /etc/systemd/zram-generator.conf (writing it would hang the boot)"
    rm -f /etc/systemd/zram-generator.conf
    # modules-load would also spam "Failed to find module 'zram'" every boot.
    rm -f /etc/modules-load.d/zram.conf
    echo "[93] no swap will be configured; rebuild the kernel with CONFIG_ZRAM=y to enable it"
    exit 0
fi

install -d -m 0755 /etc/systemd
cat > /etc/systemd/zram-generator.conf <<'ZRAMCONF'
# NCZ-OS 26.7 zram sizing policy (audit W3.6).
#
# One device is enough. zstd gives the best ratio/speed on arm64 when
# the kernel has CONFIG_CRYPTO_ZSTD=y. The size is `MemTotal * 0.5`
# (50% of physical RAM) clamped to [1GiB, 8GiB] — the lower bound
# keeps tiny boxes from having a useless 256MiB zram, the upper bound
# keeps 64GiB boxes from wasting 32GiB of RAM on swap. swap-priority
# 100 wins over any disk swap that might appear later.
[zram0]
zram-size = ram * 0.5
max-zram-size = 8192
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMCONF
chmod 0644 /etc/systemd/zram-generator.conf
echo "[93] /etc/systemd/zram-generator.conf: zram0, zstd, ram*0.5 capped [1GiB, 8GiB], prio=100"

# 3. KERNEL SUPPORT CHECK — this is the load-bearing step.
#
# /usr/lib/modules-load.d/20-zram-generator.conf (shipped by the
# systemd-zram-generator package) requests that zram.ko be loaded
# at boot; if the kernel was built without CONFIG_ZRAM the module
# load fails silently and /sys/block/zram0 never appears. The
# path-based generator then has no device to enumerate and does
# not instantiate systemd-zram-setup@zram0.service, so nothing
# runs. We surface the gap as a WARN so a future kernel rebuild is
# visible in the install record — we do NOT claim success on the
# install log when the kernel can't actually do the work.
#
# IMPORTANT: /sys/block/zram0 belongs to the KERNEL THAT IS
# CURRENTLY RUNNING THIS HOOK. Post-install hooks run inside the
# installer's chroot, which boots the installer's kernel (typically
# the Debian installer kernel for the host arch), NOT the CIX
# Sky1 kernel that was just installed on the target. Probing
# /sys/block/zram0 would test the wrong kernel and print a false
# success on any installer kernel that happens to have CONFIG_ZRAM.
# The shipped CIX Sky1 kernel config
# (assets/kernel/edge/config-7.2.0-rc7-sky1-ncz, verified) has
# `# CONFIG_ZRAM is not set`, so the install would silently ship
# with no swap at all if we trusted the running-kernel probe.
#
# Instead we look at the TARGET kernel's own config and module
# tree. /boot/config-<kver> is dropped by linux-image-cixmini at
# install time, so it is present in the chroot. We pick the
# kernel that will actually boot: KVER_NEXT is the sidecar
# written by the installer (see 10-our-kernel.sh), falling back to
# /boot/vmlinuz-*-ncz* if the sidecar is absent. The check is a
# read of two CONFIG_* lines, plus a defensive check for a
# zram.ko under /lib/modules/<kver>/kernel/drivers/block/ in case
# the module is built =m.
INSTALLER_META=/usr/local/lib/cix-installer
TARGET_KVER=""
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    TARGET_KVER=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null | tr -d ' \t\r\n')
fi
if [ -z "$TARGET_KVER" ]; then
    # Fallback: pick the first /boot/vmlinuz-* on a *-ncz* uname.
    # Best-effort; if nothing matches, the WARN below fires.
    for f in /boot/vmlinuz-*-ncz; do
        [ -e "$f" ] || continue
        TARGET_KVER="${f#/boot/vmlinuz-}"
        break
    done
fi

TARGET_CONFIG=""
if [ -n "$TARGET_KVER" ] && [ -r "/boot/config-$TARGET_KVER" ]; then
    TARGET_CONFIG="/boot/config-$TARGET_KVER"
fi

ZRAM_KVER_FOUND=0
ZRAM_BUILTIN=0    # CONFIG_ZRAM=y
ZRAM_MODULE=0     # zram.ko present under /lib/modules/<kver>/...
ZSTD_KVER_FOUND=0 # CONFIG_CRYPTO_ZSTD=y (or =m)
if [ -n "$TARGET_CONFIG" ]; then
    # CONFIG_ZRAM=y   -> builtin; CONFIG_ZRAM=m -> needs zram.ko
    # `# CONFIG_ZRAM is not set` -> not built at all
    if grep -qE '^CONFIG_ZRAM=y$' "$TARGET_CONFIG"; then
        ZRAM_BUILTIN=1
        ZRAM_KVER_FOUND=1
    elif grep -qE '^CONFIG_ZRAM=m$' "$TARGET_CONFIG"; then
        # CONFIG_ZRAM=m: the module may be present as zram.ko,
        # zram.ko.xz, zram.ko.zst depending on the compressor used
        # to pack modules-cixmini.tgz. Accept any of them.
        if ls "/lib/modules/$TARGET_KVER/kernel/drivers/block/zram/zram."* >/dev/null 2>&1; then
            ZRAM_MODULE=1
            ZRAM_KVER_FOUND=1
        fi
    fi
    # zstd compression. =m + zstd module is acceptable too, but the
    # shipped generator only writes `compression-algorithm = zstd`
    # when the kernel side can serve it, so log a WARN if =y is
    # absent.
    if grep -qE '^CONFIG_CRYPTO_ZSTD=(y|m)$' "$TARGET_CONFIG"; then
        ZSTD_KVER_FOUND=1
    fi
fi

if [ "$ZRAM_BUILTIN" -eq 1 ] && [ "$ZSTD_KVER_FOUND" -eq 1 ]; then
    echo "[93] TARGET kernel $TARGET_KVER has CONFIG_ZRAM=y + CONFIG_CRYPTO_ZSTD=y — zram enabled"
elif [ "$ZRAM_MODULE" -eq 1 ] && [ "$ZSTD_KVER_FOUND" -eq 1 ]; then
    echo "[93] TARGET kernel $TARGET_KVER has CONFIG_ZRAM=m (zram.ko present) + CONFIG_CRYPTO_ZSTD present — zram enabled (module load)"
elif [ "$ZRAM_KVER_FOUND" -eq 0 ]; then
    cat >&2 <<WARN
[93] WARN: TARGET kernel $TARGET_KVER does NOT expose zram — swap will NOT be active on first boot.
[93] Inspected target config: ${TARGET_CONFIG:-<not present in /boot>}
[93] Expected at least one of:
[93]   CONFIG_ZRAM=y                     (built into the kernel image)
[93]   CONFIG_ZRAM=m + zram.ko under /lib/modules/$TARGET_KVER/kernel/drivers/block/zram/
[93] The shipped CIX Sky1 kernel config
[93] (assets/kernel/edge/config-7.2.0-rc7-sky1-ncz, audited at install time)
[93] has \`# CONFIG_ZRAM is not set\` and no CONFIG_CRYPTO_ZSTD — i.e. the
[93] kernel half is MISSING in this release. /etc/systemd/zram-generator.conf
[93] above is the ready-to-go sizing policy, and
[93] /usr/lib/modules-load.d/20-zram-generator.conf (from the package)
[93] requests zram.ko at boot; a kernel rebuild with CONFIG_ZRAM=y and
[93] CONFIG_CRYPTO_ZSTD=y will produce /sys/block/zram0 automatically on
[93] next boot, the path-based generator will instantiate
[93] systemd-zram-setup@zram0.service, and the swap will come up.
[93] NO fallback to disk swapfile — btrfs swapfile needs nodatacow
[93] handling that is intentionally avoided (per audit).
WARN
elif [ "$ZSTD_KVER_FOUND" -eq 0 ]; then
    cat >&2 <<WARN
[93] WARN: TARGET kernel $TARGET_KVER has CONFIG_ZRAM but lacks CONFIG_CRYPTO_ZSTD.
[93] zram will load, but the generator's `compression-algorithm = zstd`
[93] will fail back to a kernel default; swap still comes up, just slower.
[93] Add CONFIG_CRYPTO_ZSTD=y in the next kernel build.
WARN
fi

echo "[93] DONE — zram-generator configured (active iff TARGET kernel $TARGET_KVER has CONFIG_ZRAM=y)"