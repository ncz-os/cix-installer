#!/bin/bash
# amd64-boot-noise.sh -- boot-log error fixes that apply to EVERY amd64 host,
# not only Apple T2 Macs. Sourced by post-install/55-t2-firmware.sh before its
# T2 and BUILD_VARIANT gates; docs/AMD64-BOOT-NOISE.md has the evidence.
#
# (1) pcspkr / snd_pcsp: both modules register a platform driver named
#     "pcspkr" and both carry MODULE_ALIAS("platform:pcspkr"), so udev loads
#     both for the one PC-speaker platform device and the second one logs
#       Error: Driver 'pcspkr' is already registered, aborting...
#     That is not T2-specific: PEGASUS (ASUS GU502LV) logged it on 2026-11-02.
#     Blacklist the ALSA PCM driver; the input pcspkr driver keeps the beeper.
#     Written whenever an installed kernel ships BOTH drivers (as modules or
#     built in); a kernel with only one of them cannot hit the collision.
#
# (2) ucsi_ccg on an NVIDIA dGPU's USB-C UCSI function: OPT-IN ONLY. See
#     ncz_ucsi_ccg_optin below for why there is no automatic rule.
#
# Test seams (all default to the live system): NCZ_MODULES_ROOT
# (/lib/modules), NCZ_ETC_ROOT (/etc), NCZ_INSTALLER_META
# (/usr/local/lib/cix-installer), NCZ_PCI_DEVICES_ROOT (lib/pci-sysfs.sh).
# Tested by build/test-amd64-boot-noise.sh.

NCZ_BOOT_NOISE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=post-install/lib/pci-sysfs.sh
. "$NCZ_BOOT_NOISE_LIB_DIR/pci-sysfs.sh"

# ncz_kmod_shipped <kernel-tree> <module_name> -- 0 when the kernel tree ships
# the driver, as a loadable module (any compression, '-' or '_' spelling) or
# built in (modules.builtin).
ncz_kmod_shipped() {
    local tree="$1" name="$2" dash
    dash=${name//_/-}
    if [ -r "$tree/modules.builtin" ] \
       && grep -Eq "/(${name}|${dash})\.ko\$" "$tree/modules.builtin" 2>/dev/null; then
        return 0
    fi
    [ -n "$(find "$tree" \( -name "${name}.ko*" -o -name "${dash}.ko*" \) -print -quit 2>/dev/null)" ]
}

# ncz_pcspkr_dup_kernels -- print each installed kernel version that ships
# BOTH pcspkr and snd_pcsp; return 1 when none does.
ncz_pcspkr_dup_kernels() {
    local root="${NCZ_MODULES_ROOT:-/lib/modules}" k n=0
    for k in "$root"/*; do
        [ -d "$k" ] || continue
        if ncz_kmod_shipped "$k" pcspkr && ncz_kmod_shipped "$k" snd_pcsp; then
            printf '%s\n' "${k##*/}"
            n=$((n + 1))
        fi
    done
    [ "$n" -gt 0 ]
}

# ncz_write_modprobe_conf <file-name> -- write stdin to
# $NCZ_ETC_ROOT/modprobe.d/<file-name> only when the content differs, so a
# re-run is a no-op (same bytes, same mtime). Prints "written" or "unchanged".
ncz_write_modprobe_conf() {
    local dir="${NCZ_ETC_ROOT:-/etc}/modprobe.d" new
    install -d -m 0755 "$dir" || return 1
    new=$(mktemp "$dir/.$1.XXXXXX") || return 1
    cat > "$new"
    if cmp -s "$new" "$dir/$1"; then
        rm -f "$new"; echo unchanged; return 0
    fi
    chmod 0644 "$new" && mv -f "$new" "$dir/$1" || { rm -f "$new"; return 1; }
    echo written
}

ncz_pcspkr_conf_text() {
    cat <<'MODEOF'
# NCZ-OS: pcspkr (input) and snd_pcsp (ALSA PCM) both register platform driver
# "pcspkr" (both carry MODULE_ALIAS platform:pcspkr), so whichever loads second
# logs "Driver 'pcspkr' is already registered, aborting..." every boot. Keep the
# input beeper; never load the ALSA one. Written by post-install/55 on every
# amd64 host whose kernel ships both. Undo: rm this file.
blacklist snd_pcsp
install snd_pcsp /bin/true
MODEOF
}

# ncz_ucsi_ccg_optin -- 0 when the operator opted in to the ucsi_ccg blacklist
# with $NCZ_INSTALLER_META/UCSI_CCG_BLACKLIST = yes|on|1|force.
#
# WHY THERE IS NO AUTOMATIC RULE. The blacklist is right on PEGASUS (ASUS
# GU502LV, TU106): the dGPU exposes a USB Type-C UCSI function (01:00.3,
# 10de:1adb) driven by i2c_nvidia_gpu, ucsi_ccg probes a CCGx controller at
# 0x08 on that adapter, nothing answers, and the probe fails with -110 every
# boot ("nvidia-gpu 0000:01:00.3: i2c timeout error e0000000", "ucsi_ccg
# 5-0008: probe with driver ucsi_ccg failed with error -110"). Firmware _UPC
# marks every port of the dGPU xHCI "not used" and the only Type-C port is the
# PCH/Thunderbolt one (ucsi_acpi, USBC000). On boards that DO wire a USB-C
# port to the dGPU (many desktop Turing/Ampere cards with a VirtualLink port),
# the same function and the same driver serve that port, and blacklisting it
# loses USB-C power-delivery/alt-mode handling there. The facts that separate
# the two cases are only observable AFTER a boot of the installed kernel (the
# -110 probe failure; a timeout can also be transient) or need _UPC parsing of
# the dGPU xHCI ports, so an install-time hook cannot decide it safely.
ncz_ucsi_ccg_optin() {
    local f="${NCZ_INSTALLER_META:-/usr/local/lib/cix-installer}/UCSI_CCG_BLACKLIST"
    [ -f "$f" ] || return 1
    case "$(tr -d ' \t\r\n' < "$f" 2>/dev/null)" in
        yes|on|1|force) return 0 ;;
    esac
    return 1
}

# ncz_nvidia_ucsi_bdfs -- print the BDF of every NVIDIA USB Type-C UCSI
# function (vendor 10de, class 0x0c80xx "serial bus controller, other"), from
# the cached sysfs IDs only (never config space; see lib/pci-sysfs.sh).
ncz_nvidia_ucsi_bdfs() {
    local bdf cls ven dev out n=0
    out=$(ncz_pci_devices) || return 1
    while read -r bdf cls ven dev; do
        [ "$ven" = 10de ] || continue
        case "$cls" in 0c80*) printf '%s\n' "$bdf"; n=$((n + 1)) ;; esac
    done <<< "$out"
    [ "$n" -gt 0 ]
}

ncz_ucsi_ccg_conf_text() {
    cat <<'MODEOF'
# NCZ-OS (operator opt-in, UCSI_CCG_BLACKLIST): this host's NVIDIA dGPU exposes
# a USB Type-C UCSI function, but no port is wired to it, so ucsi_ccg times out
# (-110) probing a CCGx controller that is not there, every boot. i2c_nvidia_gpu
# stays bound so the function keeps runtime PM (dGPU D3).
# Do NOT keep this on a card with a working USB-C port (docs/AMD64-BOOT-NOISE.md).
# Undo: rm this file.
blacklist ucsi_ccg
MODEOF
}

# ncz_amd64_boot_noise_apply -- the hook entry point. Never fails the install:
# every step is a log line, and an error is reported, not fatal.
ncz_amd64_boot_noise_apply() {
    local kv r bdfs
    if kv=$(ncz_pcspkr_dup_kernels); then
        r=$(ncz_pcspkr_conf_text | ncz_write_modprobe_conf ncz-pcspkr.conf) || r=failed
        echo "  [55] pcspkr: snd_pcsp blacklisted, ncz-pcspkr.conf $r (kernels shipping both: $(echo "$kv" | tr '\n' ' '))"
    else
        echo "  [55] pcspkr: no installed kernel ships both pcspkr and snd_pcsp -- nothing to do"
    fi

    bdfs=$(ncz_nvidia_ucsi_bdfs 2>/dev/null | tr '\n' ' ') || bdfs=""
    if ncz_ucsi_ccg_optin; then
        r=$(ncz_ucsi_ccg_conf_text | ncz_write_modprobe_conf ncz-nvidia-ucsi-ccg.conf) || r=failed
        echo "  [55] ucsi_ccg: blacklisted by operator opt-in, ncz-nvidia-ucsi-ccg.conf $r (NVIDIA UCSI: ${bdfs:-none})"
    elif [ -n "$bdfs" ]; then
        echo "  [55] ucsi_ccg: NVIDIA USB-C UCSI function at $bdfs left alone (opt-in only, see docs/AMD64-BOOT-NOISE.md)"
    fi
    return 0
}
