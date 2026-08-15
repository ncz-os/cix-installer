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
#   Verified against assets/kernel/edge/config-7.2.0-rc7-sky1-ncz:
#     # CONFIG_ZRAM is not set
#     no CONFIG_CRYPTO_ZSTD
#   i.e. the CIX Sky1 kernel build DOES NOT have CONFIG_ZRAM enabled.
# This hook verifies the kernel actually has zram support before
# trusting the generator; if /sys/block/zram0 is unreachable, we
# write a clear WARN log line and exit 0 (the installed system still
# boots, it just runs without swap until the kernel catches up).
# This is the audit's "If you cannot verify something actually works,
# say so explicitly" clause, applied to the kernel side rather than
# the userspace side.
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
min-zram-size = 1024
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
if [ -r /sys/block/zram0 ]; then
    echo "[93] kernel exposes /sys/block/zram0 — zram enabled"
else
    cat >&2 <<WARN
[93] WARN: kernel does NOT expose /sys/block/zram0 — zram swap will NOT be active.
[93] The shipped CIX Sky1 kernel config (config-7.2.0-rc7-sky1-ncz) has:
[93]   # CONFIG_ZRAM is not set
[93]   no CONFIG_CRYPTO_ZSTD
[93] Required: enable CONFIG_ZRAM=y (or =m with zram module loaded early)
[93] and CONFIG_CRYPTO_ZSTD=y in the next kernel build. Until then,
[93] /etc/systemd/zram-generator.conf above is the ready-to-go sizing
[93] policy and /usr/lib/modules-load.d/20-zram-generator.conf (from
[93] the package) requests zram.ko at boot; a kernel rebuild with
[93] CONFIG_ZRAM enabled will produce /sys/block/zram0 automatically
[93] on next boot, the path-based generator will instantiate
[93] systemd-zram-setup@zram0.service, and the swap will come up.
[93] NO fallback to disk swapfile — btrfs swapfile needs nodatacow
[93] handling that is intentionally avoided (per audit).
WARN
fi

echo "[93] DONE — zram-generator configured (active iff kernel has CONFIG_ZRAM=y)"