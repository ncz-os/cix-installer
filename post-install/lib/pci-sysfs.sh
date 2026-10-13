#!/bin/bash
# pci-sysfs.sh -- PCI device enumeration for post-install hooks WITHOUT lspci.
#
# SOURCE this file. Never call `lspci` (or read a device's sysfs `config`
# file) from an install-time hook: both read PCI configuration space, and a
# config-space read of a device whose runtime-PM transition never completed
# blocks in uninterruptible sleep (D state) forever.
#
# Measured 2026-10-06 on the GU502LV laptop (ASUS GU502LV, RTX 2060 Mobile TU106
# 10de:1f15, Optimus) with the r199 amd64 installer: nouveau's runtime
# suspend oopsed in nvkm_gsp_gcx_ready() (NULL gsp->rm, no GSP-RM firmware),
# the pm_runtime worker died with the device left in runtime_status
# "suspending", and `lspci -nn` in 54-gpu-accel.sh then sat in D state in
# pci_config_pm_runtime_get() -> __pm_runtime_barrier() reading
# .../0000:01:00.0/config. The install never progressed. SIGKILL cannot end a
# D-state process, so `timeout lspci` would not have helped either.
#
# The sysfs `vendor`, `device` and `class` attributes are served from the
# values the PCI core cached at enumeration (struct pci_dev); reading them
# never touches the device, so they are safe on a wedged GPU.
#
# NCZ_PCI_DEVICES_ROOT overrides /sys/bus/pci/devices for tests (same knob as
# assets/refind/ncz-t2-detect.sh).

# ncz_pci_hex <file> -- print the attribute without 0x, lower-case; return 1
# when it is missing or empty.
ncz_pci_hex() {
    local v
    [ -r "$1" ] || return 1
    IFS= read -r v < "$1" 2>/dev/null || [ -n "$v" ] || return 1
    v=${v#0x}; v=${v#0X}
    [ -n "$v" ] || return 1
    printf '%s' "$v" | tr 'A-F' 'a-f'
}

# ncz_pci_available -- 0 when the sysfs PCI device list exists and is not
# empty (a chroot without /sys mounted has none).
ncz_pci_available() {
    local root="${NCZ_PCI_DEVICES_ROOT:-/sys/bus/pci/devices}" d
    for d in "$root"/*; do
        [ -e "$d/vendor" ] && return 0
    done
    return 1
}

# ncz_pci_devices -- one line per device: "<bdf> <class 6 hex> <vendor 4 hex> <device 4 hex>".
# Returns 1 when sysfs has no PCI devices.
ncz_pci_devices() {
    local root="${NCZ_PCI_DEVICES_ROOT:-/sys/bus/pci/devices}" d cls ven dev n=0
    for d in "$root"/*; do
        cls=$(ncz_pci_hex "$d/class") || continue
        ven=$(ncz_pci_hex "$d/vendor") || continue
        dev=$(ncz_pci_hex "$d/device") || continue
        printf '%s %06x %04x %04x\n' "${d##*/}" "$((16#$cls))" "$((16#$ven))" "$((16#$dev))"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ]
}

# ncz_pci_lspci_nn -- the same devices in the line shape `lspci -nn` prints
# ("0000:01:00.0 Class [0300]: Device [10de:1f15]"), so existing grep
# consumers keep working unchanged: [cccc] is the base class + subclass,
# [vvvv:dddd] the vendor and device IDs. There are no names (that needs
# pci.ids); match on the bracketed IDs only.
ncz_pci_lspci_nn() {
    local bdf cls ven dev out
    out=$(ncz_pci_devices) || return 1
    printf '%s\n' "$out" | while read -r bdf cls ven dev; do
        printf '%s Class [%s]: Device [%s:%s]\n' "$bdf" "${cls:0:4}" "$ven" "$dev"
    done
}
