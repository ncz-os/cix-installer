#!/bin/bash
# Install the firmware BOM that manifests/firmware.pkgs already puts in the
# offline mirror.
#
# THE GAP THIS CLOSES. firmware.pkgs was consumed only by build-forky-mirror.sh
# and the two verifiers. Nothing ever INSTALLED from it, so a firmware package
# reached the installed system only if some other package happened to depend on
# it. Measured on T2 Mac B (MacBookPro16,1) 2026-09-28: firmware-amd-graphics and
# firmware-brcm80211 were present (pulled in as dependencies) while
# firmware-intel-graphics was NOT, /lib/firmware/i915 was EMPTY, and i915
# reported:
#     Direct firmware load for i915/kbl_dmc_ver1_04.bin failed with error -2
# Installing the package supplied 61 i915 files and the kernel then logged
#     Finished loading DMC firmware i915/kbl_dmc_ver1_04.bin (v1.4)
# DMC is the display microcontroller: without it the iGPU cannot enter its
# deep display power states, so this is a real power and thermal cost, not
# cosmetic.
#
# The BOM we install is the arch-scoped one. amd64 installs the complete,
# architecture-neutral manifests/firmware.pkgs (an installer that must work on
# hardware we have not seen should not guess which blobs it needs). sky1-arm64
# installs manifests/firmware-arm64.pkgs -- the subset a Sky1 system can load,
# with the dropped published packages recorded in manifests/firmware-bom-arm64.allow
# and justified in docs/ARM64-FIRMWARE-TRIM-2026-10-11.md. The mirror is seeded
# from the same arch-scoped file, so every package named here is present by
# construction. Exclusions belong in the allow-list, not here.
set -u
# Optional install feedback + hard deadline (lib/progress-msg.sh, lib/bounded-run.sh).
_pm="$(dirname "$0")/lib/progress-msg.sh"; [ -r "$_pm" ] || _pm=/usr/local/lib/cix-installer/post-install/lib/progress-msg.sh
[ -r "$_pm" ] && . "$_pm"
_bd="$(dirname "$0")/lib/bounded-run.sh"; [ -r "$_bd" ] || _bd=/usr/local/lib/cix-installer/post-install/lib/bounded-run.sh
[ -r "$_bd" ] && . "$_bd"
# ARCH-SCOPED BOM. The staged medium carries both manifests/firmware.pkgs
# (the complete, architecture-neutral published set) and, on sky1-arm64,
# manifests/firmware-arm64.pkgs (the trimmed Sky1 subset). Select the
# arch-scoped file when present and fall back to the complete one, the same
# preference build/build-forky-mirror.sh and build/verify-firmware-bom.sh use.
# NCZ_FW_BOM always wins (tests and operators set it explicitly). Arch
# detection order matches post-install/12-sky1-firmware.sh: env, then the
# late.sh-stamped BUILD_ARCH, then dpkg.
_fw_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_fw_arch" ] || _fw_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_fw_arch" ] || _fw_arch=$(dpkg --print-architecture 2>/dev/null || true)
BOM=${NCZ_FW_BOM:-}
if [ -z "$BOM" ]; then
    # NCZ_FW_MANIFEST_DIR overrides the search dirs (space-separated); it exists
    # so the unit test can exercise the arch-scoped selection without root.
    for _fw_dir in ${NCZ_FW_MANIFEST_DIR:-/usr/local/lib/cix-installer/manifests /cdrom/manifests}; do
        if [ -n "$_fw_arch" ] && [ -f "$_fw_dir/firmware-$_fw_arch.pkgs" ]; then
            BOM="$_fw_dir/firmware-$_fw_arch.pkgs"; break
        fi
        [ -f "$_fw_dir/firmware.pkgs" ] && { BOM="$_fw_dir/firmware.pkgs"; break; }
    done
fi
if [ -z "$BOM" ] || [ ! -f "$BOM" ]; then
    echo "[13] firmware BOM not found; skipping"
    command -v ncz_msg >/dev/null 2>&1 && ncz_msg "Firmware: BOM not found on the medium, skipping (log: /var/log/cix-install/13-firmware-bom.log)"
    exit 0
fi
echo "[13] firmware BOM: $BOM (arch=${_fw_arch:-unknown})"
mapfile -t PKGS < <(grep -hvE '^[[:space:]]*(#|$)' "$BOM" | awk '{print $1}')
[ "${#PKGS[@]}" -gt 0 ] || { echo "[13] firmware BOM empty; skipping"; exit 0; }
echo "[13] installing ${#PKGS[@]} firmware packages from the BOM"
command -v ncz_msg >/dev/null 2>&1 && ncz_msg "Firmware: installing ${#PKGS[@]} packages from the offline mirror (about 1 minute)"
export DEBIAN_FRONTEND=noninteractive

# LICENCE ACCEPTANCE (r201 defect). firmware-ipw2x00 and firmware-ivtv ask a
# critical-priority "do you accept the licence" debconf question in their
# preinst. Under DEBIAN_FRONTEND=noninteractive it cannot be asked, the preinst
# exits 2 and dpkg leaves the package "install ok not-installed" (r201 gate:
# "firmware-ipw2x00 agree question could not be asked"). The firmware is
# redistributable non-free-firmware that the operator already ships, so the
# acceptance is preseeded before apt runs. Template names were read from the
# 20260916-1 debs (firmware-*/license/accepted, boolean). Any future
# licence-gated package shows up as MISSING below and fails the hook.
if command -v debconf-set-selections >/dev/null 2>&1; then
    printf '%s\n' \
        'firmware-ipw2x00 firmware-ipw2x00/license/accepted boolean true' \
        'firmware-ivtv firmware-ivtv/license/accepted boolean true' \
        | debconf-set-selections \
        || echo "[13] WARNING: could not preseed firmware licence acceptance" >&2
else
    echo "[13] WARNING: debconf-set-selections missing; licence-gated firmware will fail" >&2
fi

# Real install state. `dpkg -s` exits 0 for "install ok not-installed" (a package
# whose preinst failed), which made the old check report "0 of 40 missing" while
# two packages were absent. Only "install ok installed" counts.
fw_installed() {
    case "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" in
        *"install ok installed"*) return 0 ;;
        *) return 1 ;;
    esac
}

# --no-install-recommends: firmware packages must not drag in extras.
# BOUNDED (2026-10-10 wall-clock audit): this was the single longest post-install
# step in the amd64 KVM gate (28s) and had no deadline, so a stuck mirror or dpkg
# lock could stall the install indefinitely. Bound it; on timeout we fall through
# to the per-package check, which reports exactly what is missing and fails.
BOM_TIMEOUT=${NCZ_FW_BOM_TIMEOUT:-900}
_apt_rc=0
if command -v ncz_bounded_run >/dev/null 2>&1; then
    ncz_bounded_run "$BOM_TIMEOUT" "13-firmware-bom" "${NCZ_LOGDIR:-/var/log/cix-install}/13-firmware-bom-apt.log" \
        apt-get install -y --no-install-recommends "${PKGS[@]}" || _apt_rc=$?
else
    apt-get install -y --no-install-recommends "${PKGS[@]}" || _apt_rc=$?
fi
if [ "$_apt_rc" -ne 0 ]; then
    echo "[13] WARNING: apt-get install of the firmware BOM failed (rc=$_apt_rc); checking each package" >&2
    command -v ncz_msg >/dev/null 2>&1 && ncz_msg "Firmware: package install returned rc=$_apt_rc - verifying each package (log: /var/log/cix-install/13-firmware-bom.log)"
fi
MISSING=()
for p in "${PKGS[@]}"; do
    fw_installed "$p" || MISSING+=("$p")
done
echo "[13] /lib/firmware/i915: $(ls /lib/firmware/i915 2>/dev/null | wc -l) files"
if [ "${#MISSING[@]}" -gt 0 ]; then
    for p in "${MISSING[@]}"; do echo "[13]   MISSING: $p" >&2; done
    echo "[13] FAILED: ${#MISSING[@]} of ${#PKGS[@]} firmware packages are not installed" >&2
    exit 1
fi
echo "[13] firmware BOM installed: all ${#PKGS[@]} packages are 'install ok installed'"
