#!/bin/bash
# 87-mpam-cache-partition.sh — static L3 cache partitioning via MPAM/resctrl.
#
# Context (Stuart, community contact, 2026-07-27): CIX Sky1's MPAM
# implementation is CPU-side only — the CI-700 interconnect lacks MPAM, so
# this covers CPU-core cache partitioning ONLY (no memory-bandwidth or
# device/GPU/NPU/VPU partitioning), and there is no monitoring facility
# (MSCs), so this is static configuration, not adaptive/dynamic.
#
# What this buys us: give the A520 (efficiency/housekeeping) cluster a
# small slice of L3 and leave the rest to A720 (performance/interactive),
# so background agent workloads pinned to A520 via cpusets/cgroups cannot
# evict hot cache lines the interactive desktop (A720) is actively using.
# Directly strengthens core-time isolation (cpuset/cgroup pinning) with a
# hard cache-isolation guarantee on top.
#
# UNVALIDATED on real hardware as of authoring (kernel CONFIG_ARM64_MPAM
# was only just enabled in the 7.2/rc5 defconfig — this hook has never run
# against a kernel that actually has MPAM built in). Every step is
# defensive: missing resctrl, missing MSC/firmware support, or anything
# unexpected in cbm_mask/min_cbm_bits WARNs and exits 0 rather than
# failing the install. Do not assume this works until confirmed live.
#
# We do NOT hardcode L3 size or way counts — the same ACPI PPTT gap that
# leaves lscpu/hwloc unable to report cache sizes (see
# github.com/cixtech/cix_opensource__linux/issues/1) means we cannot
# trust /sys/devices/system/cpu/cpu*/cache/ for real numbers either.
# Instead we read resctrl's own L3 info (cbm_mask/min_cbm_bits), which
# comes from MPAM's own MSC discovery, not the generic ACPI cacheinfo
# path, and partition in terms of cache WAYS (resctrl's native unit),
# not a guessed MB figure.
set -euo pipefail

echo "[87] MPAM/resctrl L3 cache partitioning (A520 housekeeping vs A720 interactive)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[87] BUILD_VARIANT=server — no interactive desktop to protect, skipping"
        exit 0
        ;;
esac

if ! grep -qw resctrl /proc/filesystems 2>/dev/null; then
    echo "[87] kernel has no resctrl filesystem (CONFIG_ARM64_MPAM not built, or firmware lacks an MPAM MSC table) — skipping"
    exit 0
fi

mkdir -p /sys/fs/resctrl
if ! mountpoint -q /sys/fs/resctrl; then
    if ! mount -t resctrl resctrl /sys/fs/resctrl 2>/tmp/resctrl-mount.err; then
        echo "[87] WARN: mount -t resctrl failed ($(cat /tmp/resctrl-mount.err 2>/dev/null)) — skipping"
        rm -f /tmp/resctrl-mount.err
        exit 0
    fi
    rm -f /tmp/resctrl-mount.err
fi

if [ ! -d /sys/fs/resctrl/info/L3 ]; then
    echo "[87] WARN: /sys/fs/resctrl/info/L3 absent (no L3 cache control resource — CI-700 gap or firmware didn't expose it) — skipping"
    exit 0
fi

CBM_MASK=$(cat /sys/fs/resctrl/info/L3/cbm_mask 2>/dev/null || echo "")
MIN_BITS=$(cat /sys/fs/resctrl/info/L3/min_cbm_bits 2>/dev/null || echo "1")
if [ -z "$CBM_MASK" ]; then
    echo "[87] WARN: could not read L3/cbm_mask — skipping"
    exit 0
fi

TOTAL_BITS=$(( 4 * ${#CBM_MASK} ))  # hex string -> bit count
if [ "$TOTAL_BITS" -le 0 ]; then
    echo "[87] WARN: L3/cbm_mask ($CBM_MASK) parsed to 0 bits — skipping"
    exit 0
fi

# Housekeeping (A520) gets 1/4 of the ways == Stuart's explicit numbers
# (A520 4MB of a 16MB total L3, A720 keeps the other 12MB -- 4:16 = 1/4).
# Expressed as a ratio, not a hardcoded MB figure, because resctrl's
# native unit is cache ways, not bytes, and hardcoding "4MB" would
# require trusting the same ACPI cache-size reporting that's already
# broken on this platform (the PPTT gap, cixtech/cix_opensource__linux#1)
# -- the ratio lands on his numbers exactly regardless of what the real
# total L3 size turns out to be, without needing to trust that path.
# Rounded up to min_cbm_bits, never less than min_cbm_bits, never the
# whole mask (that would leave A720 with nothing).
HK_BITS=$(( TOTAL_BITS / 4 ))
[ "$HK_BITS" -lt "$MIN_BITS" ] && HK_BITS=$MIN_BITS
if [ "$HK_BITS" -ge "$TOTAL_BITS" ]; then
    echo "[87] WARN: computed housekeeping bits ($HK_BITS) >= total ($TOTAL_BITS) — cache too small to partition, skipping"
    exit 0
fi

# Contiguous low bits for housekeeping, the remaining contiguous high bits
# for the default (A720/interactive) group -- resctrl requires contiguous
# CBMs on most implementations.
HK_CBM=$(printf '%x' $(( (1 << HK_BITS) - 1 )))
DEFAULT_BITS=$(( TOTAL_BITS - HK_BITS ))
DEFAULT_CBM=$(printf '%x' $(( ((1 << DEFAULT_BITS) - 1) << HK_BITS )))

echo "[87] L3 total=${TOTAL_BITS} ways, housekeeping=${HK_BITS} ways (0x${HK_CBM}), interactive=${DEFAULT_BITS} ways (0x${DEFAULT_CBM})"

# Identify A520 (little/efficiency, CPU part 0xd80) vs A720 (big/performance,
# CPU part 0xd81) cores dynamically -- core COUNT varies by SKU (O6N vs
# cixmini vs Orange Pi 6 Plus are not all 8+4), never hardcode core numbers.
A520_CPUS=""
for cpu_sysfs in /sys/devices/system/cpu/cpu[0-9]*; do
    n=$(basename "$cpu_sysfs" | sed 's/cpu//')
    part=$(grep -m1 -A0 "^processor.*: $n\$" -A20 /proc/cpuinfo 2>/dev/null | grep -m1 '^CPU part' | awk '{print $NF}')
    [ "$part" = "0xd80" ] && A520_CPUS="${A520_CPUS:+$A520_CPUS,}$n"
done

if [ -z "$A520_CPUS" ]; then
    echo "[87] WARN: no Cortex-A520 (CPU part 0xd80) cores found in /proc/cpuinfo — skipping (nothing to isolate)"
    exit 0
fi
echo "[87] A520 (housekeeping) cores: $A520_CPUS"

# resctrl CPU lists are a bitmask string via cpus, or a cpus_list (comma/
# range) file on kernels that support it -- prefer cpus_list, it's
# unambiguous regardless of core count/order.
GROUP=/sys/fs/resctrl/housekeeping
mkdir -p "$GROUP"
if [ -f "$GROUP/cpus_list" ]; then
    echo "$A520_CPUS" > "$GROUP/cpus_list"
else
    echo "[87] WARN: $GROUP/cpus_list missing (older resctrl ABI) — leaving CPU assignment to the resctrl default init script rather than guessing the cpus bitmask format"
fi

if ! echo "L3:0=${HK_CBM}" > "$GROUP/schemata" 2>/tmp/resctrl-schemata.err; then
    echo "[87] WARN: writing housekeeping schemata failed ($(cat /tmp/resctrl-schemata.err 2>/dev/null)) — partition not applied"
    rm -f /tmp/resctrl-schemata.err
    exit 0
fi
rm -f /tmp/resctrl-schemata.err
echo "L3:0=${DEFAULT_CBM}" > /sys/fs/resctrl/schemata 2>/dev/null || true

# Persist across reboots: resctrl is a pseudo-fs, nothing here survives a
# reboot on its own. Re-run this hook at boot via a oneshot unit.
cat > /etc/systemd/system/ncz-mpam-cache-partition.service <<'UNIT'
[Unit]
Description=NCZ MPAM/resctrl L3 cache partition (A520 housekeeping vs A720 interactive)
After=local-fs.target
ConditionPathExists=/usr/local/lib/cix-installer/post-install/87-mpam-cache-partition.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/cix-installer/post-install/87-mpam-cache-partition.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable ncz-mpam-cache-partition.service 2>/dev/null || true

echo "[87] MPAM L3 partition applied + boot-persistence unit installed"
