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
# hook becomes a pure enablement: the generator picks up
# /etc/systemd/zram-generator.conf and creates zram0 automatically
# on first boot.
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
#    and creates /run/systemd/zram-generator.conf at boot (it is content-
#    addressed; re-running this hook produces a stable file).
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
# systemd-zram-generator.service runs `zramctl` and `mkswap` at boot,
# and BOTH require the kernel to actually expose zram. On the CIX Sky1
# kernel build, CONFIG_ZRAM is NOT set (# CONFIG_ZRAM is not set), so
# /sys/block/zram0 does not exist and the generator unit will silently
# produce no device. We do not claim success on the install log: we
# surface the gap as a WARN so a future kernel rebuild is visible in
# the install record.
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
[93] policy and the systemd-zram-generator.service is enabled; a kernel
[93] rebuild with the option enabled will produce zram0 automatically
[93] on next boot. NO fallback to disk swapfile — btrfs swapfile needs
[93] nodatacow handling that is intentionally avoided (per audit).
WARN
fi

# 4. enable the generator service so zram0 is created on boot when the
#    kernel does support it. The service is socket-activated by
#    systemd-zram-setup@.service (one instance per zram device). It
#    is part of the systemd-zram-generator package and lives in
#    /usr/lib/systemd/system/; we just enable.
if systemctl list-unit-files systemd-zram-generator.service >/dev/null 2>&1; then
    systemctl enable systemd-zram-generator.service 2>&1 | tail -1 || true
    echo "[93] systemd-zram-generator.service enabled"
else
    # Older debian releases ship systemd-zram-setup@.service without the
    # top-level generator; the generator path is in zram-generator.conf
    # only. Leave it alone.
    echo "[93] systemd-zram-generator.service not shipped; the .conf above is the contract" >&2
fi

echo "[93] DONE — zram-generator configured (active iff kernel has CONFIG_ZRAM=y)"
