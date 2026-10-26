#!/bin/bash
# test-amd64-cuda-gates.sh -- positive AND negative tests for the AMD64 dynamic
# NVIDIA driver + CUDA design:
#   - family selection per PCI id (cuda-select.sh), mixed-GPU rule, plans, pins
#   - static asset gate (verify-cuda-assets.sh): keys, units, no CUDA in manifests
#     or in the offline mirror
#   - installed-target gate (verify-cuda-installed-target.sh)
#   - the real NVIDIA function of post-install/54-gpu-accel.sh run under stubs
#   - the real assets/nvidia/ncz-cuda-setup run under stubs (network down, network
#     up, removals refused, backoff, retry, skip, status, toolkit resolution, the
#     driver fallback ladder, the all-fail path, content-matched DKMS patches with
#     the real shipped patch and the real `patch`, apt hooks)
# Style follows build/test-hostname-suggest.sh: fixtures in a temp dir, every
# check prints ok/FAIL, exit status is the number of failures.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d -t cudagates.XXXXXX)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "ok   $*"; }
nok()  { FAILS=$((FAILS+1)); echo "FAIL $*"; }
expect_rc() {   # expect_rc WANT DESC cmd...   (WANT 0 = success, nonzero = must fail)
    local want="$1" desc="$2"; shift 2
    "$@" >"$W/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" != 0 ] && [ $rc -ne 0 ]; }; then ok "$desc"
    else nok "$desc (rc=$rc)"; sed 's/^/     /' "$W/out" | tail -5; fi
}
eq() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else nok "$1: got '$2' want '$3'"; fi; }

# shellcheck source=../post-install/lib/cuda-select.sh
. "$ROOT/post-install/lib/cuda-select.sh"

# ------------------------------------------------------------ family per PCI id
fam() { ncz_cuda_family_of_id "$1"; }
eq "id 1f08 RTX 2060"            "$(fam 1f08)" turing-plus
eq "id 1e00 boundary (Turing)"   "$(fam 1e00)" turing-plus
eq "id 2684 RTX 4090 (Ada)"      "$(fam 2684)" turing-plus
eq "id 2B85 uppercase Blackwell" "$(fam 2B85)" turing-plus
eq "id 1dff boundary below Turing" "$(fam 1dff)" maxwell-volta
eq "id 1d81 TITAN V (Volta)"     "$(fam 1d81)" maxwell-volta
eq "id 1c03 GTX 1060 (Pascal)"   "$(fam 1c03)" maxwell-volta
eq "id 13c2 GTX 970 (Maxwell)"   "$(fam 13c2)" maxwell-volta
eq "id 1380 GTX 750 Ti (Maxwell)" "$(fam 1380)" maxwell-volta
eq "id 1340 boundary (Maxwell GM108)" "$(fam 1340)" maxwell-volta
eq "id 133f boundary below Maxwell" "$(fam 133f)" kepler-older
eq "id 1180 GTX 680 (Kepler)"    "$(fam 1180)" kepler-older
eq "id 0640 GT 9500 (Tesla)"     "$(fam 0640)" kepler-older
expect_rc 1 "malformed id 'zz' rejected"    ncz_cuda_family_of_id zz
expect_rc 1 "short id '1f0' rejected"       ncz_cuda_family_of_id 1f0
expect_rc 1 "empty id rejected"             ncz_cuda_family_of_id ""

# ------------------------------------------------------------ picking from lspci
IGPU='00:02.0 VGA compatible controller [0300]: Intel Corporation CometLake-S GT2 [UHD Graphics 630] [8086:9bc4]'
pick() { printf '%s\n' "$1" > "$W/lspci"; ncz_cuda_pick_family "$W/lspci"; }
eq "pick: iGPU + RTX 2060"  "$(pick "$IGPU
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU106M [GeForce RTX 2060 Mobile] [10de:1f15] (rev a1)")" "turing-plus 1f15"
eq "pick: Pascal + Turing -> oldest wins (R580 serves both)" "$(pick "01:00.0 VGA compatible controller [0300]: NVIDIA [10de:1c03]
02:00.0 3D controller [0302]: NVIDIA [10de:1f08]")" "maxwell-volta 1c03"
eq "pick: Kepler + Turing -> oldest wins (unsupported)" "$(pick "01:00.0 VGA compatible controller [0300]: NVIDIA [10de:1180]
02:00.0 3D controller [0302]: NVIDIA [10de:1f08]")" "kepler-older 1180"
eq "pick: HDMI audio function is not a GPU (Intel only -> none)" "$(pick "$IGPU
01:00.1 Audio device [0403]: NVIDIA Corporation TU106 High Definition Audio [10de:10f9]" || echo none)" none
eq "pick: non-display NVIDIA line ignored" "$(pick "01:00.2 USB controller [0c03]: NVIDIA Corporation TU106 USB 3.1 [10de:1ada]" || echo none)" none
eq "pick: no NVIDIA at all" "$(pick "$IGPU" || echo none)" none
eq "pick: unreadable fixture fails closed" "$(ncz_cuda_pick_family "$W/nope" || echo none)" none

# ------------------------------------------------------------------- plans + pins
plan() { ncz_cuda_plan "$1" | sed -n "s/^$2=//p" | sed -e "s/^'//" -e "s/'\$//"; }
eq "turing plan: driver pin is any NVIDIA driver series (3-digit), not one branch" "$(plan turing-plus DRIVER_PIN)" '[1-9][0-9][0-9]*'
eq "turing plan: open kernel modules" "$(plan turing-plus KMOD)" open
eq "turing plan: module package" "$(plan turing-plus KMOD_PKG)" nvidia-kernel-open-dkms
eq "turing plan: toolkit series (newest 13.x resolved at run time)" "$(plan turing-plus TOOLKIT_SERIES)" 13
eq "turing plan: toolkit package stems, no version" "$(plan turing-plus TOOLKIT_PKGS)" 'cuda-compiler cuda-libraries cuda-libraries-dev'
eq "turing plan: no fixed toolkit dir" "$(plan turing-plus TOOLKIT_DIR)" ""
case " $(plan turing-plus DRIVER_PKGS) " in *" nvidia-open "*) ok "turing plan: nvidia-open (open modules in every series)";; *) nok "turing plan lacks nvidia-open";; esac
case " $(plan turing-plus DRIVER_PKGS) " in *" cuda-drivers "*) nok "turing plan names cuda-drivers (proprietary module in 610.x and older)";; *) ok "turing plan does not name cuda-drivers";; esac
case "$( { ncz_cuda_plan turing-plus; ncz_cuda_plan maxwell-volta; } | grep -v '^#')" in *13-4*|*13.4*|*12-9*|*12.9*|*615*) nok "plans hard-code a toolkit or driver version";; *) ok "plans name no toolkit minor or driver point version";; esac
eq "turing plan: repo"            "$(plan turing-plus REPO)" debian13
if [[ " $(plan turing-plus DRIVER_PKGS) " == *" nvidia-egl-icd "* ]] &&
   [[ " $(plan turing-plus DRIVER_PKGS) " == *" libegl-nvidia0 "* ]] &&
   [[ " $(plan turing-plus DRIVER_PKGS) " == *" libnvidia-egl-wayland1 "* ]] &&
   [[ " $(plan turing-plus DRIVER_PKGS) " == *" libnvidia-egl-gbm1 "* ]]; then
    ok "turing plan includes NVIDIA EGL ICD, library, Wayland and GBM platforms"
else
    nok "turing plan lacks NVIDIA EGL runtime packages"
fi
eq "maxwell-volta plan: driver pin" "$(plan maxwell-volta DRIVER_PIN)" '580.*'
eq "maxwell-volta plan: PROPRIETARY module (open is Turing+ only)" "$(plan maxwell-volta KMOD)" proprietary
eq "maxwell-volta plan: driver pkg" "$(plan maxwell-volta DRIVER_PKGS)" cuda-drivers-580
eq "maxwell-volta plan: module package" "$(plan maxwell-volta KMOD_PKG)" nvidia-kernel-dkms
eq "maxwell-volta plan: CUDA 12.x series" "$(plan maxwell-volta TOOLKIT_SERIES)" 12
eq "maxwell-volta plan: repo"     "$(plan maxwell-volta REPO)" debian12
eq "maxwell-volta plan: needs sequoia SHA-1 relax" "$(plan maxwell-volta SEQUOIA_RELAX)" 1
eq "turing plan: no sequoia relax" "$(plan turing-plus SEQUOIA_RELAX)" 0
eq "kepler plan: no toolkit"      "$(plan kepler-older TOOLKIT)" none
eq "kepler plan: no driver pkgs"  "$(plan kepler-older DRIVER_PKGS)" ""
expect_rc 1 "unknown family has no plan" ncz_cuda_plan bogus
for f in turing-plus maxwell-volta; do
    case " $(plan $f TOOLKIT_PKGS) " in *" cuda-libraries-dev "*) ok "$f plan includes the -dev headers (cuda-libraries-dev)";; *) nok "$f plan lacks headers";; esac
done
case "$(ncz_cuda_pin_file maxwell-volta)" in *"Pin: version 580.*"*) ok "pascal pin holds the driver family on 580.*";; *) nok "pascal pin wrong";; esac
case "$(ncz_cuda_pin_file maxwell-volta)" in *615*) nok "pascal pin mentions 615";; *) ok "pascal pin never allows 615";; esac
case "$(ncz_cuda_pin_file turing-plus)" in *"Pin: version [1-9][0-9][0-9]*"*) ok "turing family pin: NVIDIA driver versions only (any series)";; *) nok "turing pin wrong";; esac
case "$(ncz_cuda_pin_file turing-plus)" in *"Pin: origin"*) nok "turing pin by origin would force NVIDIA's older EGL platform libraries over Debian's";; *) ok "turing pin is by version, not origin";; esac
pinpkgs_sel=$(ncz_cuda_pin_file turing-plus | sed -n 's/^Package: //p')
pinpkgs_tool=$(sed -n "s/^PIN_PKGS='\(.*\)'\$/\1/p" "$ROOT/assets/nvidia/ncz-cuda-setup")
eq "ncz-cuda-setup pins the same package set as cuda-select.sh" "$pinpkgs_tool" "$pinpkgs_sel"
case "$(ncz_cuda_pin_file turing-plus)" in *libxnvctrl*"cuda-drivers"*|*"cuda-drivers"*libxnvctrl*) ok "pin covers cuda-drivers and libxnvctrl* (measured: without it apt mixes branches)";; *) nok "pin misses cuda-drivers/libxnvctrl";; esac
expect_rc 1 "kepler family has no pin file" ncz_cuda_pin_file kepler-older

# ------------------------------------------------------------- static asset gate
AG="$ROOT/build/verify-cuda-assets.sh"
expect_rc 0 "assets: repo passes the static gate" "$AG"
mkroot() {   # mkroot DIR : a minimal copy of the files the asset gate inspects
    rm -rf "$1"; mkdir -p "$1/assets/nvidia" "$1/manifests" "$1/post-install/lib"
    cp "$ROOT"/assets/nvidia/ncz-cuda-setup* "$ROOT"/assets/nvidia/cuda-archive-keyring-debian12.gpg "$1/assets/nvidia/"
    cp "$ROOT/assets/nvidia/cuda-keyring_1.1-1_all.deb" "$1/assets/nvidia/"
    cp "$ROOT/post-install/lib/cuda-select.sh" "$1/post-install/lib/"
    printf 'vim\nchromium\n' > "$1/manifests/desktop-amd64.pkgs"
}
R="$W/root"
mkroot "$R";                                  expect_rc 0 "assets: clean fixture root passes" "$AG" --root "$R"
mkroot "$R"; rm "$R/assets/nvidia/cuda-keyring_1.1-1_all.deb"
                                              expect_rc 1 "assets: missing debian13 keyring is rejected" "$AG" --root "$R"
mkroot "$R"; rm "$R/assets/nvidia/cuda-archive-keyring-debian12.gpg"
                                              expect_rc 1 "assets: missing debian12 key is rejected" "$AG" --root "$R"
mkroot "$R"; rm "$R/assets/nvidia/ncz-cuda-setup.timer"
                                              expect_rc 1 "assets: missing timer is rejected" "$AG" --root "$R"
mkroot "$R"; sed -i 's/^SuccessExitStatus=75/#/' "$R/assets/nvidia/ncz-cuda-setup.service"
                                              expect_rc 1 "assets: service without SuccessExitStatus=75 is rejected" "$AG" --root "$R"
mkroot "$R"; sed -i 's/^After=.*/After=local-fs.target/' "$R/assets/nvidia/ncz-cuda-setup.service"
                                              expect_rc 1 "assets: service not ordered after network-online is rejected" "$AG" --root "$R"
mkroot "$R"; sed -i '/^ConditionPathExists=!/d' "$R/assets/nvidia/ncz-cuda-setup.service"
                                              expect_rc 1 "assets: non-idempotent service is rejected" "$AG" --root "$R"
mkroot "$R"; printf '\n[Install]\nWantedBy=multi-user.target\n' >> "$R/assets/nvidia/ncz-cuda-setup.service"
                                              expect_rc 1 "assets: service joining the boot transaction is rejected" "$AG" --root "$R"
mkroot "$R"; echo "cuda-compiler-13-4" >> "$R/manifests/desktop-amd64.pkgs"
                                              expect_rc 1 "assets: CUDA seed in a manifest is rejected" "$AG" --root "$R"
mkroot "$R"; echo "nvidia-driver   # legacy" >> "$R/manifests/desktop-amd64.pkgs"
                                              expect_rc 1 "assets: NVIDIA driver seed in a manifest is rejected" "$AG" --root "$R"
mkroot "$R"; sed -i "s/ cuda-libraries-dev'/'/g" "$R/post-install/lib/cuda-select.sh"
                                              expect_rc 1 "assets: toolkit plan without -dev headers is rejected" "$AG" --root "$R"
mkmirror() {   # mkmirror DIR pkg...
    local d="$1"; shift; rm -rf "$d"; mkdir -p "$d/dists/forky/main/binary-amd64"; : > "$d/dists/forky/main/binary-amd64/Packages"
    for p in "$@"; do printf 'Package: %s\nVersion: 1\nArchitecture: amd64\n\n' "$p" >> "$d/dists/forky/main/binary-amd64/Packages"; done
}
mkmirror "$W/mir" vim chromium libc6;         expect_rc 0 "mirror: pool without NVIDIA/CUDA passes" "$AG" --mirror "$W/mir"
mkmirror "$W/mir" vim cuda-nvcc-13-4;         expect_rc 1 "mirror: CUDA package in the pool is rejected" "$AG" --mirror "$W/mir"
mkmirror "$W/mir" vim libnvidia-ml1;          expect_rc 1 "mirror: NVIDIA driver library in the pool is rejected" "$AG" --mirror "$W/mir"
mkmirror "$W/mir" vim libcublas-dev-13-4;     expect_rc 1 "mirror: CUDA math dev library in the pool is rejected" "$AG" --mirror "$W/mir"
mkmirror "$W/mir" vim libcurl4 libcups2;      expect_rc 0 "mirror: libcurl/libcups are not mistaken for CUDA" "$AG" --mirror "$W/mir"

# ------------------------------------------------------- installed-target gate
TG="$ROOT/build/verify-cuda-installed-target.sh"
mktarget() {   # mktarget DIR STATUS [kind: installed|pending|conf-only] [family]
    local d="$1" kind="${3:-}" family="${4:-turing-plus}" tk=13-4 td=/usr/local/cuda-13.4
    [ "$family" = maxwell-volta ] && { tk=12-9; td=/usr/local/cuda-12.9; }
    rm -rf "$d"; mkdir -p "$d/var/lib/ncz" "$d/var/lib/dpkg" "$d/etc/profile.d" "$d/etc/apt/preferences.d" "$d/etc/ncz" "$d/etc/systemd/system/timers.target.wants" "$d/usr/local/sbin"
    [ -n "$2" ] && echo "$2" > "$d/var/lib/ncz/cuda-toolkit.status"
    : > "$d/var/lib/dpkg/status"
    if [ "$kind" = installed ] || [ "$kind" = pending ]; then
        printf "GPU_PCI_ID=10de:1f08\nFAMILY=%s\nDRIVER_BRANCH=615\nTOOLKIT=%s\nTOOLKIT_DIR=%s\n" "$family" "$tk" "$td" > "$d/etc/ncz/cuda-selection.conf"
        : > "$d/etc/apt/preferences.d/ncz-nvidia-cuda.pref"
    fi
    if [ "$kind" = installed ]; then
        mkdir -p "$d$td/bin"; printf '#!/bin/sh\n' > "$d$td/bin/nvcc"; chmod +x "$d$td/bin/nvcc"
        : > "$d/etc/profile.d/ncz-cuda.sh"; date > "$d/var/lib/ncz/cuda-setup.done"
        printf 'Package: cuda-nvcc-%s\nStatus: install ok installed\n\nPackage: cuda-libraries-dev-%s\nStatus: install ok installed\n\n' "$tk" "$tk" > "$d/var/lib/dpkg/status"
        if [ "$family" = turing-plus ]; then
            printf 'Package: nvidia-egl-icd\nStatus: install ok installed\n\nPackage: libegl-nvidia0\nStatus: install ok installed\n\nPackage: libnvidia-egl-wayland1\nStatus: install ok installed\n\nPackage: libnvidia-egl-gbm1\nStatus: install ok installed\n\n' >> "$d/var/lib/dpkg/status"
        fi
    fi
    if [ "$kind" = pending ]; then
        printf '#!/bin/sh\n' > "$d/usr/local/sbin/ncz-cuda-setup"; chmod +x "$d/usr/local/sbin/ncz-cuda-setup"
        : > "$d/etc/systemd/system/ncz-cuda-setup.service"; : > "$d/etc/systemd/system/ncz-cuda-setup.timer"
        ln -s ../ncz-cuda-setup.timer "$d/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer"
    fi
}
T="$W/target"
mktarget "$T" "installed:13.4.92-1" installed turing-plus; expect_rc 0 "target: installed (Turing, CUDA 13.4 + EGL runtime) passes" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed turing-plus; sed -i '/^Package: nvidia-egl-icd$/,+2d' "$T/var/lib/dpkg/status"
                                                 expect_rc 1 "target: missing NVIDIA EGL ICD is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed turing-plus; sed -i '/^Package: libegl-nvidia0$/,+2d' "$T/var/lib/dpkg/status"
                                                 expect_rc 1 "target: missing NVIDIA EGL library is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed turing-plus; sed -i '/^Package: libnvidia-egl-wayland1$/,+2d' "$T/var/lib/dpkg/status"
                                                 expect_rc 1 "target: missing Wayland EGL platform is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed turing-plus; sed -i '/^Package: libnvidia-egl-gbm1$/,+2d' "$T/var/lib/dpkg/status"
                                                 expect_rc 1 "target: missing GBM EGL platform is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed turing-plus; expect_rc 0 "target: auto derives installed" "$TG" --root "$T"
# selection written by the version-agnostic plan: the toolkit is what ncz-cuda-setup recorded (INSTALLED_*)
mktarget "$T" "installed:13.5.10-1" installed turing-plus
sed -i -e 's/^TOOLKIT=.*/TOOLKIT=13.x/' -e '/^TOOLKIT_DIR=/d' -e 's/^DRIVER_BRANCH=.*/DRIVER_BRANCH=newest/' "$T/etc/ncz/cuda-selection.conf"
printf 'TOOLKIT_SERIES=13\nINSTALLED_DRIVER=615.71.09-2\nINSTALLED_TOOLKIT=13-5\nINSTALLED_TOOLKIT_DIR=/usr/local/cuda-13.5\n' >> "$T/etc/ncz/cuda-selection.conf"
mkdir -p "$T/usr/local/cuda-13.5/bin"; mv "$T/usr/local/cuda-13.4/bin/nvcc" "$T/usr/local/cuda-13.5/bin/nvcc"; sed -i 's/13-4/13-5/g' "$T/var/lib/dpkg/status"
                                                 expect_rc 0 "target: version-agnostic selection, installed toolkit taken from INSTALLED_* passes" "$TG" --root "$T" --expect installed
sed -i '/^INSTALLED_TOOLKIT=/d' "$T/etc/ncz/cuda-selection.conf"
                                                 expect_rc 1 "target: version-agnostic selection without INSTALLED_TOOLKIT is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:12.9.86-1" installed maxwell-volta; expect_rc 0 "target: installed (Pascal, CUDA 12.9) passes" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed; rm "$T/usr/local/cuda-13.4/bin/nvcc"
                                                 expect_rc 1 "target: installed but nvcc missing is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed; : > "$T/var/lib/dpkg/status"
                                                 expect_rc 1 "target: dpkg lacks the toolkit is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed; printf 'Package: cuda-nvcc-13-4\nStatus: install ok installed\n\n' > "$T/var/lib/dpkg/status"
                                                 expect_rc 1 "target: headers (-dev) not installed is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed; rm "$T/etc/apt/preferences.d/ncz-nvidia-cuda.pref"
                                                 expect_rc 1 "target: missing driver-branch pin is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed; rm "$T/etc/ncz/cuda-selection.conf"
                                                 expect_rc 1 "target: missing cuda-selection.conf is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed; rm "$T/var/lib/ncz/cuda-setup.done"
                                                 expect_rc 1 "target: installed without the stamp is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "pending:network" pending;         expect_rc 0 "target: deferred install (unit+timer enabled) passes (expect pending)" "$TG" --root "$T" --expect pending
mktarget "$T" "pending:network" pending;         expect_rc 0 "target: auto derives pending" "$TG" --root "$T"
mktarget "$T" "pending:network" pending; rm "$T/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer"
                                                 expect_rc 1 "target: pending but timer NOT enabled is rejected" "$TG" --root "$T" --expect pending
mktarget "$T" "pending:network" pending; rm "$T/etc/systemd/system/ncz-cuda-setup.service"
                                                 expect_rc 1 "target: pending without the service unit is rejected" "$TG" --root "$T" --expect pending
mktarget "$T" "pending:network" pending; rm "$T/usr/local/sbin/ncz-cuda-setup"
                                                 expect_rc 1 "target: pending without ncz-cuda-setup is rejected" "$TG" --root "$T" --expect pending
mktarget "$T" "pending:network" pending; date > "$T/var/lib/ncz/cuda-setup.done"
                                                 expect_rc 1 "target: pending with a done stamp is rejected" "$TG" --root "$T" --expect pending
mktarget "$T" "pending:network" pending;         expect_rc 1 "target: pending when installed was expected is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "skipped:no-nvidia-gpu";           expect_rc 0 "target: non-NVIDIA skip is logged and passes" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped:no-nvidia-gpu";           expect_rc 0 "target: auto derives skipped" "$TG" --root "$T"
mktarget "$T" "skipped:kepler-older-unsupported" conf-only; expect_rc 0 "target: Kepler skip passes" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped:no-nvidia-gpu" installed; expect_rc 1 "target: skipped but nvcc exists is rejected" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped:";                        expect_rc 1 "target: skip without a reason is rejected" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped: ";                    expect_rc 1 "target: whitespace-only skip reason is rejected" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped:no-nvidia-gpu"; printf 'Package: cuda-nvcc-11-8\nStatus: install ok installed\nVersion: 11.8-1\n\n' > "$T/var/lib/dpkg/status"
                                              expect_rc 1 "target: ANY installed cuda-nvcc-* contradicts a skip" "$TG" --root "$T" --expect skipped
mktarget "$T" "failed:would-remove-packages";    expect_rc 1 "target: recorded failure is always rejected (auto)" "$TG" --root "$T"
mktarget "$T" "failed:would-remove-packages";    expect_rc 1 "target: recorded failure is rejected (expect skipped)" "$TG" --root "$T" --expect skipped
mktarget "$T" "";                                expect_rc 1 "target: no status file is rejected (silent hook)" "$TG" --root "$T"
mktarget "$T" "bogus";                           expect_rc 1 "target: unrecognized status is rejected" "$TG" --root "$T"

# ---------------------------------------------- 54-gpu-accel.sh NVIDIA function
# Extract the function block from the real hook and redirect its absolute paths
# into a scratch root, so the tested code IS the shipped code.
SB="$W/sb"; mkdir -p "$SB/bin" "$SB/post-install/lib" "$SB/assets"
cp "$ROOT/post-install/lib/cuda-select.sh" "$ROOT/post-install/lib/pci-sysfs.sh" "$ROOT/post-install/lib/bounded-run.sh" "$SB/post-install/lib/"
# The hook reads the PCI list from sysfs (lib/pci-sysfs.sh), never lspci: turn
# an `lspci -nn` fixture line into a fake /sys/bus/pci/devices tree.
mksysfs() { # mksysfs "<lspci -nn line>"
    rm -rf "$SB/pci"; mkdir -p "$SB/pci"
    local bdf cls ids
    bdf=$(printf '%s' "$1" | awk '{print $1}')
    cls=$(printf '%s' "$1" | grep -oE '\[[0-9a-f]{4}\]:' | head -1 | tr -d '[]:')
    ids=$(printf '%s' "$1" | grep -oiE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tail -1 | tr -d '[]')
    mkdir -p "$SB/pci/0000:$bdf"
    printf '0x%s00\n' "$cls" > "$SB/pci/0000:$bdf/class"
    printf '0x%s\n' "${ids%%:*}" > "$SB/pci/0000:$bdf/vendor"
    printf '0x%s\n' "${ids##*:}" > "$SB/pci/0000:$bdf/device"
}
export NCZ_PCI_DEVICES_ROOT="$SB/pci"
# lspci must never be called: a stub that fails the test if it is
printf '#!/bin/bash\necho called >> "%s/lspci.called"\nexit 99\n' "$SB" > "$SB/bin/lspci"
chmod +x "$SB/bin/lspci"
extract54() {
    awk '/^# --- NVIDIA driver \+ CUDA: selected per GPU family/{f=1} /^echo "\[54\] AMD64 GPU\/accelerator vendor detection/{f=0} f' \
        "$ROOT/post-install/54-gpu-accel.sh" \
      | sed -e "s#/var/lib/ncz#$SB/var/lib/ncz#g" -e "s#/etc/ncz#$SB/etc/ncz#g" \
            -e "s#/etc/cix-installer#$SB/etc/cix-installer#g" -e "s#/usr/local/lib/cix-installer/COMPONENTS#$SB/x/COMPONENTS#g" -e "s#/var/lib/cix-components#$SB/var/lib/cix-components#g" \
            -e "s#NCZ_NV_ASSETS=[^ ]*#NCZ_NV_ASSETS=$SB/assets#" \
            -e "s#/usr/local/sbin#$SB/usr/local/sbin#g" -e "s#/etc/systemd/system#$SB/etc/systemd/system#g" \
            -e "s#/usr/local/lib/ncz#$SB/usr/local/lib/ncz#g" \
            -e "s#/etc/apt/preferences.d#$SB/etc/apt/preferences.d#g" -e "s#/etc/apt/sources.list.d#$SB/etc/apt/sources.list.d#g" \
            -e "s#/etc/apt/apt.conf.d#$SB/etc/apt/apt.conf.d#g" -e "s#/etc/modprobe.d#$SB/etc/modprobe.d#g" \
            -e "s#/etc/kernel/postinst.d#$SB/etc/kernel/postinst.d#g" \
            -e "s#/usr/share/keyrings#$SB/usr/share/keyrings#g" -e "s#/etc/crypto-policies#$SB/etc/crypto-policies#g" \
            -e "s#/usr/share/apt/default-sequoia.config#$SB/default-sequoia.config#g" \
            -e "s#/var/log#$SB/var/log#g"
}
extract54 > "$SB/nvfunc.sh"
[ -s "$SB/nvfunc.sh" ] && ok "54: NVIDIA function block extracted from the real hook" || nok "54: could not extract the NVIDIA block"
cat > "$SB/bin/dpkg" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SB/bin/dpkg"
# stub assets: a fake ncz-cuda-setup whose exit code the test chooses, real units
printf '#!/bin/bash\necho "stub ncz-cuda-setup $*"; echo "installed:13.4.92-1" > "%s/var/lib/ncz/cuda-toolkit.status"; exit "${STUB_SETUP_RC:-0}"\n' "$SB" > "$SB/assets/ncz-cuda-setup"
chmod +x "$SB/assets/ncz-cuda-setup"
cp "$ROOT/assets/nvidia/ncz-cuda-setup.service" "$ROOT/assets/nvidia/ncz-cuda-setup.timer" "$SB/assets/"
: > "$SB/assets/cuda-keyring_1.1-1_all.deb"; : > "$SB/assets/cuda-archive-keyring-debian12.gpg"
printf 'sha1.second_preimage_resistance = 2026-02-01\n' > "$SB/default-sequoia.config"
# The function resolves lib/ via $0; run it through a wrapper script placed in post-install/
run54w() {
    rm -rf "$SB/var" "$SB/etc" "$SB/usr" "$SB/x"; mkdir -p "$SB/etc/cix-installer" "$SB/x" "$SB/var/log"
    mksysfs "$1"
    [ "${3:-none}" != none ] && echo "$3" > "$SB/etc/cix-installer/COMPONENTS_cuda"
    cat > "$SB/post-install/wrap.sh" <<EOF
#!/bin/bash
. "$SB/nvfunc.sh"
ncz_nvidia_dynamic_setup
EOF
    PATH="$SB/bin:$PATH" STUB_SETUP_RC="${2:-0}" NCZ_SKIP_CUDA="${4:-0}" bash "$SB/post-install/wrap.sh" > "$SB/log" 2>&1
    head -n1 "$SB/var/lib/ncz/cuda-toolkit.status" 2>/dev/null
}
RTX='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU106M [GeForce RTX 2060 Mobile] [10de:1f15]'
GTX='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP106 [GeForce GTX 1060] [10de:1c03]'
GTX680='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GK104 [GeForce GTX 680] [10de:1180]'
got="$(run54w "$RTX" 0)";  eq "54: Turing GPU, install succeeds now" "$got" "installed:13.4.92-1"
if grep -qF "$SB/usr/local/lib/ncz/nvidia-dkms" "$SB/nvfunc.sh" && ! grep -oE '[^ "=]*/usr/local/lib/ncz' "$SB/nvfunc.sh" | grep >/dev/null -v "^$SB"; then
    ok "54: extracted block is sandboxed (/usr/local/lib/ncz)"
else nok "54: extracted block writes the real /usr/local/lib/ncz (or does not install the DKMS patches at all)"; fi
grep -q 'dkms not staged: no local NVIDIA DKMS patches' "$SB/log" && ok "54: missing DKMS patch assets are a note, not a failure" || nok "54: no note for missing DKMS patch assets"
mkdir -p "$SB/assets/dkms/nvidia/0001-x"; printf 'p\n' > "$SB/assets/dkms/nvidia/0001-x/ncz-0001-x.patch"
got="$(run54w "$RTX" 0)";  eq "54: with DKMS patch assets the install still succeeds" "$got" "installed:13.4.92-1"
[ -f "$SB/usr/local/lib/ncz/nvidia-dkms/nvidia/0001-x/ncz-0001-x.patch" ] && ok "54: DKMS patch assets installed for ncz-cuda-setup" || nok "54: DKMS patch assets not installed"
rm -rf "$SB/assets/dkms"
DMEM_SET="$ROOT/assets/nvidia/dkms/nvidia/0001-dmem-cgroup-init-linux-7.3"
ls "$DMEM_SET/"*.patch >/dev/null 2>&1 && ok "assets: the dmem (Linux 7.3) DKMS patch set is shipped, keyed by module not by driver version" || nok "assets: dmem DKMS patch set missing"
ls -d "$ROOT"/assets/nvidia/dkms/*-[0-9]* >/dev/null 2>&1 && nok "assets: a version-keyed patch dir is still shipped: $(ls -d "$ROOT"/assets/nvidia/dkms/*-[0-9]*)" || ok "assets: no version-keyed patch dirs"
grep -q '^+.*dmem_cgroup_register_region(&init, "%s", name);' "$DMEM_SET/"*.patch 2>/dev/null \
    && ok "assets: the patch passes the name through \"%s\"" || nok "assets: patch does not use the 7.3 init struct with \"%s\""
grep -q 'NV_DMEM_CGROUP_INIT_PRESENT' "$DMEM_SET/"*.patch 2>/dev/null \
    && ok "assets: the patch is conftest-guarded (builds on pre-7.3 kernels too)" || nok "assets: patch is not conftest-guarded"
nomark=0; for d in "$ROOT"/assets/nvidia/dkms/*/*/; do [ -d "$d" ] || continue; [ -n "$(sed -n 2p "$d/fixed-upstream" 2>/dev/null)" ] || nomark=1; done
[ "$nomark" = 0 ] && ok "assets: every shipped patch set has a fixed-upstream marker" || nok "assets: a patch set lacks its fixed-upstream marker"
dups=$(ls "$ROOT"/assets/nvidia/dkms/*/*/*.patch 2>/dev/null | xargs -n1 basename | sort | uniq -d)
[ -z "$dups" ] && ok "assets: patch file names are unique across sets (they share one DKMS patches/ dir)" || nok "assets: duplicate patch names: $dups"
grep -q '^FAMILY=turing-plus' "$SB/etc/ncz/cuda-selection.conf" && ok "54: cuda-selection.conf records the family" || nok "54: conf missing family"
grep -q '^GPU_PCI_ID=10de:1f15' "$SB/etc/ncz/cuda-selection.conf" && ok "54: cuda-selection.conf records the GPU id" || nok "54: conf missing GPU id"
grep -qF 'Pin: version [1-9][0-9][0-9]*' "$SB/etc/apt/preferences.d/ncz-nvidia-cuda.pref" && ok "54: family pin written (NVIDIA driver versions, any series)" || nok "54: pin missing"
APTH="$SB/etc/apt/apt.conf.d/60ncz-nvidia-dkms"
grep -q '^DPkg::Pre-Install-Pkgs .*ncz-cuda-setup apt-pre-install.*|| true' "$APTH" 2>/dev/null && ok "54: apt pre-install hook stages patches for driver updates (never fails apt)" || nok "54: apt pre-install hook missing"
grep -q '^DPkg::Post-Invoke .*ncz-cuda-setup apt-post-invoke.*|| true' "$APTH" 2>/dev/null && ok "54: apt post-invoke hook re-arms the setup after a failed update" || nok "54: apt post-invoke hook missing"
grep -q 'else cat >/dev/null' "$APTH" 2>/dev/null && ok "54: pre-install hook drains stdin when the tool is gone (no SIGPIPE to apt)" || nok "54: hook may break apt when the tool is missing"
PDROP="$SB/etc/systemd/system/nvidia-persistenced.service.d/ncz-needs-module.conf"
grep -q "^ExecCondition=/bin/sh -c 'exec modinfo -k %v nvidia >/dev/null 2>&1'" "$PDROP" 2>/dev/null && ok "54: nvidia-persistenced is skipped (not failed) without an nvidia module for the running kernel" || nok "54: persistenced drop-in missing"
grep -q '^\[Service\]' "$PDROP" 2>/dev/null && ok "54: ExecCondition sits in [Service]" || nok "54: drop-in lacks [Service]"
KH="$SB/etc/kernel/postinst.d/zz-ncz-nvidia"
[ -x "$KH" ] && grep -q 'ncz-cuda-setup kernel-postinst "\$1"' "$KH" && grep -qx 'exit 0' "$KH" && ok "54: kernel postinst hook (after DKMS's) hands a failed rebuild to ncz-cuda-setup, never fails the kernel install" || nok "54: kernel postinst hook missing"
FBB="$SB/etc/modprobe.d/ncz-nvidia-legacy-fb.conf"
grep -qx 'blacklist nvidiafb' "$FBB" 2>/dev/null && grep -qx 'blacklist rivafb' "$FBB" 2>/dev/null && ok "54: legacy nvidiafb/rivafb blacklisted" || nok "54: legacy fb blacklist missing"
grep -qE 'blacklist (i915|xe|simpledrm|efifb|amdgpu)' "$FBB" 2>/dev/null && nok "54: blacklist touches the integrated/firmware display path" || ok "54: integrated GPU and firmware framebuffer stay untouched"
[ -x "$SB/usr/local/sbin/ncz-cuda-setup" ] && ok "54: ncz-cuda-setup installed" || nok "54: ncz-cuda-setup not installed"
[ -L "$SB/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer" ] && ok "54: deferred timer enabled" || nok "54: timer not enabled"
got="$(run54w "$RTX" 75)"; eq "54: setup rc=75 (offline) leaves the deferred path armed" "$got" "installed:13.4.92-1"
grep -q 'will retry after boot' "$SB/log" && ok "54: offline case logs that the timer will retry" || nok "54: offline case not logged"
[ -L "$SB/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer" ] && ok "54: timer enabled in the offline case" || nok "54: timer missing in offline case"
got="$(run54w "$GTX" 0)";  eq "54: Pascal GPU installs (stub)" "$got" "installed:13.4.92-1"
grep -q '^FAMILY=maxwell-volta' "$SB/etc/ncz/cuda-selection.conf" && ok "54: Pascal family recorded" || nok "54: Pascal family missing"
grep -q '^KMOD=proprietary' "$SB/etc/ncz/cuda-selection.conf" && ok "54: Pascal uses the proprietary module" || nok "54: Pascal KMOD wrong"
grep -q 'Pin: version 580' "$SB/etc/apt/preferences.d/ncz-nvidia-cuda.pref" && ok "54: Pascal pin holds 580.*" || nok "54: Pascal pin wrong"
[ -f "$SB/etc/apt/sources.list.d/ncz-cuda-debian12.list" ] && ok "54: Pascal gets the debian12 NVIDIA source" || nok "54: debian12 source missing"
grep -q 'signed-by=.*ncz-cuda-debian12.gpg' "$SB/etc/apt/sources.list.d/ncz-cuda-debian12.list" && ok "54: debian12 source is signed-by its own key file" || nok "54: debian12 source not signed-by"
grep -q '2027-12-31' "$SB/etc/crypto-policies/back-ends/apt-sequoia.config" 2>/dev/null && ok "54: Pascal machine gets the scoped SHA-1 policy extension" || nok "54: sequoia policy not written"
got="$(run54w "$RTX" 0)"; [ ! -e "$SB/etc/crypto-policies/back-ends/apt-sequoia.config" ] && ok "54: Turing machine does NOT weaken the apt policy" || nok "54: Turing machine got the policy override"
got="$(run54w "$GTX680" 0)"; eq "54: Kepler GPU is skipped and logged" "$got" "skipped:kepler-older-unsupported"
[ ! -x "$SB/usr/local/sbin/ncz-cuda-setup" ] && ok "54: Kepler installs nothing" || nok "54: Kepler installed the setup tool"
[ ! -e "$SB/etc/modprobe.d/ncz-nvidia-legacy-fb.conf" ] && [ ! -e "$SB/etc/apt/apt.conf.d/60ncz-nvidia-dkms" ] && ok "54: Kepler gets no fb blacklist and no apt hook" || nok "54: Kepler got NVIDIA driver plumbing"
got="$(run54w "$IGPU" 0)"; eq "54: no NVIDIA GPU is skipped" "$got" "skipped:no-nvidia-gpu"
got="$( rm -f "$SB/assets/ncz-cuda-setup.timer"; run54w "$RTX" 0 )"; eq "54: a missing deferred asset fails before any pin/selection side effect" "$got" "failed:deferred-asset-missing"
[ ! -e "$SB/etc/apt/preferences.d/ncz-nvidia-cuda.pref" ] && ok "54: no apt pin was written when an asset was missing" || nok "54: pin written despite a missing asset"
cp "$ROOT/assets/nvidia/ncz-cuda-setup.timer" "$SB/assets/"
got="$(run54w "$RTX" 0 0)"; eq "54: component chooser answer 0 skips" "$got" "skipped:component-not-selected"
got="$(run54w "$RTX" 0 1)"; eq "54: component chooser answer 1 installs" "$got" "installed:13.4.92-1"
got="$(run54w "$RTX" 0 none 1)"; eq "54: NCZ_SKIP_CUDA=1 skips" "$got" "skipped:operator-disabled"

# --- the durable COMPONENTS list decides (a decline must survive late.sh's persistence, which never wrote COMPONENTS_cuda)
run54l() {   # run54l "<comma list or NONE>" : COMPONENTS list persisted in the target, no COMPONENTS_cuda file
    rm -rf "$SB/var" "$SB/etc" "$SB/usr" "$SB/x"; mkdir -p "$SB/etc/cix-installer" "$SB/x" "$SB/var/log"
    mksysfs "$RTX"
    [ "$1" != NONE ] && echo "$1" > "$SB/etc/cix-installer/COMPONENTS"
    cat > "$SB/post-install/wrap.sh" <<EOF
#!/bin/bash
. "$SB/nvfunc.sh"
ncz_nvidia_dynamic_setup
EOF
    PATH="$SB/bin:$PATH" STUB_SETUP_RC=0 NCZ_SKIP_CUDA=0 bash "$SB/post-install/wrap.sh" > "$SB/log" 2>&1
    head -n1 "$SB/var/lib/ncz/cuda-toolkit.status" 2>/dev/null
}
got="$(run54l 'desktop,browsers,wallpaper-rotator,mgmt-container')"; eq "54: a COMPONENTS list WITHOUT cuda skips it (no COMPONENTS_cuda file needed)" "$got" "skipped:component-not-selected"
[ ! -x "$SB/usr/local/sbin/ncz-cuda-setup" ] && ok "54: declined CUDA installs nothing" || nok "54: declined CUDA still installed the setup tool"
got="$(run54l 'desktop,browsers,wallpaper-rotator,cuda')"; eq "54: a COMPONENTS list WITH cuda installs" "$got" "installed:13.4.92-1"
got="$(run54l NONE)"; eq "54: no component record at all installs (legacy)" "$got" "installed:13.4.92-1"
# persistence: every place that re-derives the per-toggle bits knows the cuda bit
for f in preseed/late.sh preseed/extract-rootfs.sh; do
    n=$(tr -d '\\\n' < "$ROOT/$f" | grep -o 'for _bit in [a-z -]*wallpaper-rotator[ a-z]*; do' | grep -vc 'cuda')
    [ "$n" = 0 ] && ok "$f persists COMPONENTS_cuda with the other bits" || nok "$f has a component-bit loop without cuda ($n)"
done
# a sed that changed nothing must not leave the debian12 repo unusable and looping silently
printf 'some.other.policy = 1\n' > "$SB/default-sequoia.config"
got="$(run54w "$GTX" 0)"; eq "54: sequoia policy line not found is a visible failure" "$got" "failed:sequoia-policy-not-applied"
printf 'sha1.second_preimage_resistance = 2026-02-01\n' > "$SB/default-sequoia.config"
# a failure in the setup tool must not abort the caller
( PATH="$SB/bin:$PATH" STUB_SETUP_RC=1 bash "$SB/post-install/wrap.sh" >/dev/null 2>&1 ) && ok "54: a hard setup failure returns 0 (never aborts post-install)" || nok "54: hard failure aborted the hook"
# a CUDA installer that never returns must not hold the install (bounded, killed, deferred to the timer)
cp "$SB/assets/ncz-cuda-setup" "$SB/assets/ncz-cuda-setup.real"
printf '#!/bin/bash\necho "stub ncz-cuda-setup hangs"\nsleep 3604 &\nexec sleep 3604\n' > "$SB/assets/ncz-cuda-setup"
_t0=$(date +%s)
got="$(NCZ_CUDA_SETUP_TIMEOUT=2 run54w "$RTX" 0)"
_dt=$(( $(date +%s) - _t0 ))
[ "$_dt" -lt 30 ] && ok "54: a hung ncz-cuda-setup is cut off by its deadline (${_dt}s)" || nok "54: hung ncz-cuda-setup held the hook ${_dt}s"
eq "54: hung setup leaves the deferred install pending" "$got" "pending:install"
grep -q 'timed out after 2s' "$SB/log" && ok "54: the CUDA timeout is logged" || nok "54: CUDA timeout not logged"
grep -q 'will retry after boot' "$SB/log" && ok "54: hung setup logs that the timer will retry" || nok "54: hung setup retry not logged"
_left=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    _left=$(ps -u "$(id -u)" -o args= | awk '$1 ~ /(^|\/)sleep$/ && $2 == "3604" && NF == 2' | wc -l | tr -d ' ')
    [ "$_left" = 0 ] && break
    sleep 0.5
done
[ "$_left" = 0 ] && ok "54: the hung setup's whole process group was killed (no 'sleep 3604' left)" || nok "54: $_left hung-setup processes survived"
mv -f "$SB/assets/ncz-cuda-setup.real" "$SB/assets/ncz-cuda-setup"
[ ! -e "$SB/lspci.called" ] && ok "54: lspci was never called by the NVIDIA path" || nok "54: the NVIDIA path called lspci"

# -------------------------------------------------- ncz-cuda-setup under stubs
# The real tool with every absolute path redirected into $CS; apt-get, apt-cache,
# dpkg-query and friends are stubs that model the NVIDIA repo, dpkg state and a
# DKMS build that fails for chosen driver versions.
CS="$W/cs"; mkdir -p "$CS/bin"
sed -e "s#/etc/ncz#$CS/etc/ncz#g" -e "s#/var/lib/ncz#$CS/var/lib/ncz#g" -e "s#/var/log/ncz-cuda-setup.log#$CS/setup.log#g" \
    -e "s#/run/ncz-cuda-setup.lock#$CS/lock#g" -e "s#/etc/profile.d#$CS/etc/profile.d#g" \
    -e "s#/etc/apt/preferences.d#$CS/etc/apt/preferences.d#g" -e "s#/var/cache/apt/archives#$CS/archives#g" \
    -e "s#/etc/motd.d#$CS/etc/motd.d#g" -e "s#^TOOLKIT_ROOT=/usr/local\$#TOOLKIT_ROOT=$CS#" \
    "$ROOT/assets/nvidia/ncz-cuda-setup" > "$CS/ncz-cuda-setup"
chmod +x "$CS/ncz-cuda-setup"
leak=$(grep -v '^[[:space:]]*#' "$CS/ncz-cuda-setup" | sed "s#$CS/[^ \"']*##g" | grep -oE '(/etc/ncz|/var/lib/ncz|/var/log/ncz|/run/ncz|/etc/profile.d|/etc/apt/preferences.d|/var/cache/apt|/etc/motd.d|TOOLKIT_ROOT=/usr/local)[^ ]*' | head -n3)
[ -z "$leak" ] && ok "setup: every state/apt/motd path of the tool is sandboxed by the test" || nok "setup: unsandboxed path(s): $leak"
export NCZ_NV_DKMS_PATCHES="$CS/patches" NCZ_DKMS_ETC="$CS/etc/dkms" NCZ_DKMS_TREE="$CS/dkms" \
       NCZ_SRC_ROOT="$CS/usr/src" NCZ_MODULES_ROOT="$CS/modules"
for c in systemctl ldconfig logger; do printf '#!/bin/bash\nexit 0\n' > "$CS/bin/$c"; chmod +x "$CS/bin/$c"; done
printf '#!/bin/bash\nif [ "${STUB_NET:-up}" = up ]; then echo "1.2.3.4 $2"; exit 0; fi; exit 2\n' > "$CS/bin/getent"
printf '#!/bin/bash\n[ "${STUB_NET:-up}" = up ] && exit 0; exit 7\n' > "$CS/bin/curl"
KV_A=7.3.0-t2-ncz; KV_B=7.3.1-t2-ncz
printf '#!/bin/bash\n[ "$1" = -r ] && { echo "${STUB_KVER:-%s}"; exit 0; }\nexec /bin/uname "$@"\n' "$KV_A" > "$CS/bin/uname"
# dpkg state: "<package> <version> <db:Status-Abbrev>" lines in $CS/dpkg.state
cat > "$CS/bin/dpkg-query" <<EOF
#!/bin/bash
fmt=""; pkg=""
for a in "\$@"; do case "\$a" in -W) ;; -f=*) fmt=\${a#-f=} ;; *) pkg=\$a ;; esac; done
line=\$(awk -v p="\$pkg" '\$1 == p' "$CS/dpkg.state" 2>/dev/null | tail -n1)
case "\$fmt" in
  *Status-Abbrev*) [ -n "\$line" ] || exit 1; echo "\$line" | awk '{printf "%s ", \$3}' ;;
  *) if [ -n "\$line" ]; then echo "\$line" | awk '{printf "%s", \$2}'; else case "\$pkg" in cuda-nvcc-*) printf '1.0' ;; *) exit 1 ;; esac; fi ;;
esac
EOF
# kernel modules: $CS/mods/<kernel> exists when an nvidia module was built for it
printf '#!/bin/bash\n[ "$1" = -k ] && [ -e "%s/mods/$2" ]\n' "$CS" > "$CS/bin/modinfo"
cat > "$CS/bin/dkms" <<DKMSEOF
#!/bin/bash
# dkms autoinstall -k K: builds the installed module for K (STUB_DKMS_FAIL=1: compile error)
[ "\$1" = autoinstall ] || exit 0
k=\$3; v=\$(awk '\$1 == "nvidia-kernel-open-dkms" {print \$2}' "$CS/dpkg.state" 2>/dev/null); u=\${v%-*}
if [ "\${STUB_DKMS_FAIL:-0}" = 1 ]; then
  mkdir -p "$CS/dkms/nvidia/\$u/build"
  { echo "DKMS (dkms-3.2.2) make.log for nvidia/\$u for kernel \$k (x86_64)"; echo "nvidia/nv.c:9:9: error: new kernel API"; } > "$CS/dkms/nvidia/\$u/build/make.log"
  exit 10
fi
mkdir -p "$CS/mods"; touch "$CS/mods/\$k"
DKMSEOF
# the NVIDIA repo index: STUB_NVVERS (driver versions), STUB_TKS (toolkits N-M), STUB_TK_MISSING (absent packages)
cat > "$CS/bin/apt-cache" <<'EOF'
#!/bin/bash
case "$1" in
  madison)  for v in ${STUB_NVVERS-615.71.09-2}; do echo " $2 | $v | https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64  Packages"; done
            for v in ${STUB_DEBVERS-}; do echo " $2 | $v | https://deb.debian.org/debian forky/contrib amd64 Packages"; done ;;
  pkgnames) for t in ${STUB_TKS-13-4 13-3}; do echo "cuda-compiler-$t"; done | grep "^$2" ;;
  show)     case " ${STUB_TK_MISSING-} " in *" $2 "*) echo "E: No packages found" >&2; exit 100 ;; esac; echo "Package: $2" ;;
  policy)   echo "$2:"; echo "  Installed: (none)"; echo "  Candidate: ${STUB_NVVERS%% *}" ;;
esac
exit 0
EOF
# a .deb carrying a fake driver source (needs dpkg-deb); the source's files are the
# pre-image of the SHIPPED patch, so the real patch applies to it exactly (with offsets)
SHIPPED_SET="$ROOT/assets/nvidia/dkms/nvidia/0001-dmem-cgroup-init-linux-7.3"
mksrc() {   # mksrc DIR UPSTREAM-VERSION defect|fixed|drift
    local d="$1" f="" line; rm -rf "$d"; mkdir -p "$d"
    printf 'PACKAGE_NAME="nvidia"\nPACKAGE_VERSION="%s"\nAUTOINSTALL=yes\n' "$2" > "$d/dkms.conf"
    while IFS= read -r line; do
        case "$line" in
            "+++ b/"*) f="$d/${line#+++ b/}"; f=${f%%[[:space:]]*}; mkdir -p "$(dirname "$f")"; printf '/* top of file */\n' >> "$f" ;;
            "--- "*) ;;
            "@@"*) [ -n "$f" ] && printf '/* unrelated code */\n/* more */\n' >> "$f" ;;
            " "*|"-"*) [ -n "$f" ] && printf '%s\n' "${line:1}" >> "$f" ;;
        esac
    done < "$(ls "$SHIPPED_SET"/*.patch | head -n1)"
    case "$3" in
        fixed) printf '    const struct dmem_cgroup_init init = { .size = size };\n' >> "$d/kernel-open/nvidia/os-interface.c" ;;
        drift) sed -i 's/void \*region = dmem_cgroup_register_region(size, name);/void *region = dmem_cgroup_register_region(size, name, 0);/' "$d/kernel-open/nvidia/os-interface.c" ;;
    esac
}
mkdeb() {   # mkdeb OUT.deb FULL-VERSION defect|fixed|drift
    local t="$W/debroot" u=${2%-*}
    rm -rf "$t"; mkdir -p "$t/DEBIAN" "$t/usr/src"; mksrc "$t/usr/src/nvidia-$u" "$u" "$3"
    printf 'Package: nvidia-kernel-open-dkms\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@t>\nDescription: t\n' "$2" > "$t/DEBIAN/control"
    mkdir -p "$(dirname "$1")"; dpkg-deb --root-owner-group -Zgzip -b "$t" "$1" >/dev/null 2>&1
}
HAVE_DPKG_DEB=0; command -v dpkg-deb >/dev/null 2>&1 && HAVE_DPKG_DEB=1
{ printf 'W=%q\nSHIPPED_SET=%q\n' "$W" "$SHIPPED_SET"; declare -f mksrc mkdeb; } > "$CS/mkdeb.sh"
# apt-get: models the driver-set install at the version the exact pin selects.
#   STUB_FAIL_VERS  upstream versions whose DKMS build fails (make.log with the dmem error, package left iF)
#   STUB_APT        ok | unsat | noindex | remove | drvfail | fetchfail | nonvcc
#   STUB_SIMVER     version the simulation would install for the module (default: the pinned one)
#   STUB_REMV       what `apt-get remove -s <module pkg>` would remove
#   STUB_FIXED_VERS / STUB_DRIFT_VERS  upstream versions whose module .deb carries the fix / a source the patch does not fit
cat > "$CS/bin/apt-get" <<EOF
#!/bin/bash
args="\$*"
pin=\$(sed -n 's/^Pin: version //p' "$CS/etc/apt/preferences.d/ncz-nvidia-cuda.pref" 2>/dev/null | head -n1)
u=\${pin%-*}
setstate() { { grep -v "^\$1 " "$CS/dpkg.state" 2>/dev/null; [ -n "\$2" ] && echo "\$1 \$2 \$3"; } > "$CS/dpkg.state.t"; mv "$CS/dpkg.state.t" "$CS/dpkg.state"; }
case "\$args" in
  *" update"*|update*) exit 0 ;;
  *" remove -s "*) for p in \${STUB_REMV-nvidia-kernel-open-dkms nvidia-driver nvidia-open cuda-drivers}; do echo "Remv \$p [x]"; done; exit 0 ;;
  *" remove "*) echo "remove \$args" >> "$CS/apt.calls"; setstate nvidia-kernel-open-dkms; exit 0 ;;
  *" -s "*|*install\ -s*)
     case "\${STUB_APT:-ok}" in
        unsat)   echo "E: Unable to satisfy dependencies" >&2; exit 100 ;;
        noindex) echo "E: Unable to locate package cuda-compiler-13-4" >&2; exit 100 ;;
        remove)  echo "Remv libfoo [1.0]"; exit 0 ;;
     esac
     case " \${STUB_UNSAT_VERS-} " in *" \$pin "*) echo "E: Unable to satisfy dependencies" >&2; exit 100 ;; esac
     # real apt refuses a downgrade under -y unless --allow-downgrades (measured in a forky container)
     cur=\$(awk '\$1 == "nvidia-kernel-open-dkms" {print \$2}' "$CS/dpkg.state" 2>/dev/null)
     if [ -n "\$cur" ] && [ "\$cur" != "\$pin" ] && [ "\$(printf '%s\n%s\n' "\$cur" "\$pin" | sort -V | tail -n1)" = "\$cur" ]; then
        case "\$args" in *--allow-downgrades*) ;; *) echo "E: Packages were downgraded and -y was used without --allow-downgrades." >&2; exit 100 ;; esac
     fi
     case "\$args" in *nvidia-kernel-open-dkms*) echo "Inst nvidia-kernel-open-dkms (\${STUB_SIMVER:-\$pin} NVIDIA:x [amd64])" ;; esac
     for r in \${STUB_SIM_REMV-}; do echo "Remv \$r [x]"; done
     echo "Inst cuda-nvcc-13-4 (13.4.92-1 NVIDIA)"; exit 0 ;;
  *--download-only*)
     echo "download pin=\$pin" >> "$CS/dl.calls"
     if [ "$HAVE_DPKG_DEB" = 1 ] && [ -n "\$pin" ]; then
        var=defect
        case " \${STUB_FIXED_VERS-} " in *" \$u "*) var=fixed ;; esac
        case " \${STUB_DRIFT_VERS-} " in *" \$u "*) var=drift ;; esac
        ( . "$CS/mkdeb.sh"; mkdeb "$CS/archives/nvidia-kernel-open-dkms_\${pin}_amd64.deb" "\$pin" "\$var" )
     fi
     exit 0 ;;
esac
[ "\${STUB_APT:-ok}" = drvfail ] && case "\$args" in *nvidia-kernel-open-dkms*) echo "E: Sub-process /usr/bin/dpkg returned an error code (1)" >&2; exit 100 ;; esac
[ "\${STUB_APT:-ok}" = fetchfail ] && { echo "E: Failed to fetch https://developer.download.nvidia.com/x  Connection failed" >&2; exit 100; }
echo "\$args pin=\$pin" >> "$CS/apt.calls"
case "\$args" in *nvidia-kernel-open-dkms*)
  [ -f "$CS/etc/dkms/nvidia-\$u.conf" ] && echo yes > "$CS/conf-at-postinst" || echo no > "$CS/conf-at-postinst"
  fail=0; [ "\${STUB_APT:-ok}" = dkmsfail ] && fail=1
  case " \${STUB_FAIL_VERS-} " in *" \$u "*) fail=1 ;; esac
  # a staged local patch "fixes" the stub build only when STUB_PATCH_FIXES=1
  [ "\${STUB_PATCH_FIXES:-0}" = 1 ] && grep -q '^PATCH' "$CS/etc/dkms/nvidia-\$u.conf" 2>/dev/null && fail=0
  if [ "\$fail" = 1 ]; then
    mkdir -p "$CS/dkms/nvidia/\$u/build"
    { echo "DKMS (dkms-3.2.2) make.log for nvidia/\$u for kernel \${STUB_BUILDK:-\${STUB_KVER:-$KV_A}} (x86_64)"
      echo "  CC [M]  nvidia/os-interface.o"
      echo "nvidia/os-interface.c:3031:48: error: passing argument 1 of 'dmem_cgroup_register_region' makes pointer from integer without a cast [-Wint-conversion]"
      echo "nvidia/other.c:1:1: error: a later error"; } > "$CS/dkms/nvidia/\$u/build/make.log"
    setstate nvidia-kernel-open-dkms "\$pin" iF
    echo "Building module(s)......(bad exit status: 2)"; echo "E: Sub-process /usr/bin/dpkg returned an error code (1)" >&2; exit 100
  fi
  setstate nvidia-kernel-open-dkms "\$pin" ii
  [ "\${STUB_NOMOD:-0}" = 1 ] || { mkdir -p "$CS/mods"; touch "$CS/mods/\${STUB_BUILDK:-\${STUB_KVER:-$KV_A}}"; } ;;
esac
tk=\$(printf '%s\n' "\$args" | grep -o 'cuda-compiler-[0-9]*-[0-9]*' | head -n1 | sed 's/^cuda-compiler-//')
if [ -n "\$tk" ] && [ "\${STUB_APT:-ok}" != nonvcc ]; then
  d="$CS/cuda-\${tk/-/.}/bin"; mkdir -p "\$d"; printf '#!/bin/sh\necho "Cuda compilation tools, release \${tk/-/.}"\n' > "\$d/nvcc"; chmod +x "\$d/nvcc"
fi
exit 0
EOF
chmod +x "$CS/bin/"*
csconf() {   # csconf family : fresh selection, empty dpkg state, no patch sets, no records
    rm -rf "$CS/etc" "$CS/var" "$CS/setup.log" "$CS/apt.calls" "$CS/dl.calls" "$CS/cuda-"* "$CS/lock" "$CS/dpkg.state" "$CS/mods" \
           "$CS/dkms" "$CS/patches" "$CS/usr" "$CS/modules" "$CS/conf-at-postinst" "$CS/archives"
    mkdir -p "$CS/etc/ncz" "$CS/var/lib/ncz" "$CS/modules/$KV_A/build/include/generated" "$CS/modules/$KV_B/build/include/generated"
    echo '#define CONFIG_CGROUP_DMEM 1' > "$CS/modules/$KV_A/build/include/generated/autoconf.h"
    echo '#define CONFIG_CGROUP_DMEM 1' > "$CS/modules/$KV_B/build/include/generated/autoconf.h"
    ncz_cuda_plan "$1" > "$CS/etc/ncz/cuda-selection.conf"
}
shipped() { mkdir -p "$CS/patches"; cp -R "$ROOT/assets/nvidia/dkms/nvidia" "$CS/patches/"; }   # the real patch sets
cs() {       # cs <args...>  (env STUB_*)
    PATH="$CS/bin:$PATH" "$CS/ncz-cuda-setup" "$@" >"$CS/out" 2>&1; echo $?
}
st() { head -n1 "$CS/var/lib/ncz/cuda-toolkit.status" 2>/dev/null; }
pinline() { sed -n 's/^Pin: //p' "$CS/etc/apt/preferences.d/ncz-nvidia-cuda.pref" 2>/dev/null | head -n1; }
drvcalls() { cat "$CS/apt.calls" 2>/dev/null | grep -v '^remove ' | grep -c 'nvidia-kernel-open-dkms'; }

csconf turing-plus; eq "setup: network down -> exit 75" "$(STUB_NET=down cs run)" 75
eq "setup: network down -> status pending:network" "$(st)" "pending:network"
[ -s "$CS/var/lib/ncz/cuda-setup.attempts" ] && ok "setup: backoff recorded" || nok "setup: no backoff record"
[ ! -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "setup: no stamp while pending" || nok "setup: stamp written while pending"
eq "setup: scheduled run before the backoff elapsed is a quiet no-op (rc 0)" "$(STUB_NET=up cs run --scheduled)" 0
[ ! -e "$CS/apt.calls" ] && ok "setup: not-yet-due run did not touch apt" || nok "setup: not-due run called apt"
echo "1 0" > "$CS/var/lib/ncz/cuda-setup.attempts"
eq "setup: scheduled run after the backoff elapsed installs (rc 0)" "$(STUB_NET=up cs run --scheduled)" 0
eq "setup: status installed" "$(st)" "installed:1.0"
[ -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "setup: stamp written" || nok "setup: no stamp"
[ -f "$CS/etc/profile.d/ncz-cuda.sh" ] && ok "setup: PATH snippet written" || nok "setup: profile.d missing"
eq "setup: driver and toolkit are separate apt transactions (driver first)" "$(wc -l < "$CS/apt.calls" | tr -d ' ')|$(head -n1 "$CS/apt.calls" | grep -c nvidia-kernel-open-dkms)" "2|1"
eq "setup: second run is idempotent (rc 0)" "$(cs run)" 0
eq "setup: second run made no further apt calls" "$(wc -l < "$CS/apt.calls" | tr -d ' ')" 2
csconf turing-plus; eq "setup: removals refused (rc 1)" "$(STUB_APT=remove cs run)" 1
eq "setup: removals -> failed:would-remove-packages" "$(st)" "failed:would-remove-packages"
[ ! -e "$CS/apt.calls" ] && ok "setup: nothing installed when removals were simulated" || nok "setup: installed despite removals"
csconf turing-plus; eq "setup: unsatisfiable set (rc 1)" "$(STUB_APT=unsat cs run)" 1
eq "setup: unsat -> failed:not-installable" "$(st)" "failed:not-installable"
csconf turing-plus; printf '%s|nvidia|615.60.01|x-1|none|pkg=nvidia-kernel-open-dkms|old.c:1:1: error: old kernel\n' "6.9.0-old" > "$CS/var/lib/ncz/cuda-setup.dkms-failed"
eq "setup: unsat with only an old kernel's build record (rc 1)" "$(STUB_APT=unsat cs run)" 1
eq "setup: ... still failed:not-installable (old kernels' records do not count)" "$(st)" "failed:not-installable"
csconf turing-plus; eq "setup: NVIDIA index not available yet -> retryable (rc 75)" "$(STUB_NVVERS='' cs run)" 75
eq "setup: index unavailable -> pending" "$(st)" "pending:index-unavailable"
csconf turing-plus; eq "setup: a selected package missing from a usable index (renamed) -> hard failure (rc 1)" "$(STUB_APT=noindex cs run)" 1
eq "setup: ... status failed:package-missing" "$(st)" "failed:package-missing"
grep -q 'not in the index: cuda-compiler-13-4' "$CS/setup.log" && ok "setup: ... the missing name is logged" || nok "setup: missing package not named"
csconf turing-plus; eq "setup: download failure -> retryable (rc 75)" "$(STUB_APT=fetchfail cs run)" 75
eq "setup: download failure -> pending:download" "$(st)" "pending:download"
# a stale transient line earlier in the log must not hide a HARD driver failure (was: pending:download forever)
csconf turing-plus; echo "2026-09-28T00:00:00Z E: Failed to fetch https://developer.download.nvidia.com/old Connection failed" > "$CS/setup.log"
eq "setup: hard driver failure after an old fetch error is a hard failure (rc 1)" "$(STUB_APT=drvfail cs run)" 1
eq "setup: ... recorded as failed:driver-install, not pending:download" "$(st)" "failed:driver-install"
# no curl must not mean "network is up"
nc() { sed -n '/^net_up() {/,/^}/p' "$ROOT/assets/nvidia/ncz-cuda-setup" > "$CS/netup.sh"
       ( HOST=nonexistent.invalid; getent() { return 0; }; command() { if [ "$1" = -v ] && [ "$2" = curl ]; then return 1; fi; builtin command "$@"; }; . "$CS/netup.sh"; net_up ); }
expect_rc 1 "setup: without curl an unreachable host is NOT reported as network up" nc
csconf turing-plus; eq "setup: install that yields no nvcc (rc 1)" "$(STUB_APT=nonvcc cs run)" 1
eq "setup: no nvcc -> failed:nvcc-missing" "$(st)" "failed:nvcc-missing"
[ ! -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "setup: no stamp after a failure" || nok "setup: stamp after failure"
# parked after repeated hard failures until an explicit retry
csconf turing-plus; echo "5 0" > "$CS/var/lib/ncz/cuda-setup.attempts"; echo "failed:not-installable" > "$CS/var/lib/ncz/cuda-toolkit.status"
eq "setup: scheduled run is parked after 5 hard failures (rc 0, no apt)" "$(STUB_APT=ok cs run --scheduled)" 0
[ ! -e "$CS/apt.calls" ] && ok "setup: parked run did not call apt" || nok "setup: parked run called apt"
( exec 8>"$CS/lock"; flock -n 8; echo "x|nvidia|1|a|b|pkg=p|e" > "$CS/var/lib/ncz/cuda-setup.dkms-failed"; PATH="$CS/bin:$PATH" "$CS/ncz-cuda-setup" retry >/dev/null 2>&1 )
[ -s "$CS/var/lib/ncz/cuda-setup.dkms-failed" ] && ok "setup: retry clears records only under the lock (a running setup keeps its own)" || nok "setup: retry cleared records outside the lock"
rm -f "$CS/var/lib/ncz/cuda-setup.dkms-failed"
eq "setup: retry clears the park and installs (rc 0)" "$(STUB_APT=ok cs retry)" 0
eq "setup: retry -> installed" "$(st)" "installed:1.0"
csconf kepler-older; eq "setup: Kepler run is a recorded skip (rc 0)" "$(cs run)" 0
eq "setup: Kepler status" "$(st)" "skipped:kepler-older-unsupported"
[ -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "setup: Kepler skip is stamped (no retry loop)" || nok "setup: Kepler skip not stamped"
[ ! -e "$CS/apt.calls" ] && ok "setup: Kepler never calls apt" || nok "setup: Kepler called apt"
rm -rf "$CS/etc" "$CS/var"; mkdir -p "$CS/var/lib/ncz"
eq "setup: no selection conf -> nothing to do (rc 0)" "$(cs run)" 0
csconf maxwell-volta; eq "setup: status works and shows the family" "$(cs status)" 0
grep -q 'FAMILY=maxwell-volta' "$CS/out" && ok "setup: status prints the selection (family)" || nok "setup: status lacks the family"
grep -q 'KMOD=proprietary' "$CS/out" && ok "setup: status prints the kernel module kind" || nok "setup: status lacks KMOD"
eq "setup: bad usage exits 2" "$(cs bogus)" 2

# ------------------------------- ncz-cuda-setup: toolkit chosen from the index, not hard-coded
csconf turing-plus; eq "toolkit: newest complete 13.x is installed (rc 0)" "$(STUB_TKS='13-5 13-4 13-3' cs run)" 0
grep -q 'cuda-compiler-13-5 cuda-libraries-13-5 cuda-libraries-dev-13-5' "$CS/apt.calls" && ok "toolkit: CUDA 13.5 (newest) package set installed" || nok "toolkit: newest toolkit not chosen: $(tail -n1 "$CS/apt.calls")"
grep -qx 'INSTALLED_TOOLKIT=13-5' "$CS/etc/ncz/cuda-selection.conf" && grep -qx "INSTALLED_TOOLKIT_DIR=$CS/cuda-13.5" "$CS/etc/ncz/cuda-selection.conf" \
    && ok "toolkit: what was installed is recorded in the selection (INSTALLED_TOOLKIT/_DIR)" || nok "toolkit: INSTALLED_TOOLKIT not recorded"
csconf turing-plus; eq "toolkit: an incomplete newer set is skipped (rc 0)" "$(STUB_TKS='13-5 13-4' STUB_TK_MISSING='cuda-libraries-dev-13-5' cs run)" 0
grep -q 'cuda-compiler-13-4 cuda-libraries-13-4 cuda-libraries-dev-13-4' "$CS/apt.calls" && ok "toolkit: fell back to the newest COMPLETE set (13.4)" || nok "toolkit: incomplete set not skipped"
grep -q 'CUDA 13.5 is incomplete in the index (missing: cuda-libraries-dev-13-5)' "$CS/setup.log" && ok "toolkit: the incomplete set is logged with what is missing" || nok "toolkit: incomplete set not logged"
csconf turing-plus; eq "toolkit: renamed packages -> hard failure (rc 1)" "$(STUB_TKS='' cs run)" 1
eq "toolkit: ... status failed:toolkit-not-found" "$(st)" "failed:toolkit-not-found"
grep -q 'were the packages renamed' "$CS/setup.log" && ok "toolkit: the failure says what it looked for" || nok "toolkit: no loud message"
[ "$(drvcalls)" -ge 1 ] && ok "toolkit: a toolkit problem never costs the display driver (driver still installed)" || nok "toolkit: driver skipped because of the toolkit"
csconf turing-plus; sed -i -e '/^TOOLKIT_SERIES=/d' -e "s/^TOOLKIT=.*/TOOLKIT=13-4/" -e "s/^TOOLKIT_PKGS=.*/TOOLKIT_PKGS='cuda-compiler-13-4 cuda-libraries-13-4 cuda-libraries-dev-13-4'/" "$CS/etc/ncz/cuda-selection.conf"
echo "TOOLKIT_DIR=$CS/cuda-13.4" >> "$CS/etc/ncz/cuda-selection.conf"
eq "toolkit: a selection written before this change (exact toolkit) still installs (rc 0)" "$(STUB_TKS='13-5 13-4' cs run)" 0
grep -q 'cuda-compiler-13-4 cuda-libraries-13-4 cuda-libraries-dev-13-4' "$CS/apt.calls" && ok "toolkit: ... and keeps its exact toolkit" || nok "toolkit: legacy selection not honoured"

# ------------------------------- ncz-cuda-setup: driver ladder (newest that builds wins)
NV4='615.71.10-1 615.71.09-2 615.71.09-1 610.57.04-1'
csconf turing-plus; eq "ladder: newest builds -> installed (rc 0)" "$(STUB_NVVERS="$NV4" cs run)" 0
eq "ladder: ... recorded driver" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "615.71.10-1"
eq "ladder: ... pin follows its series (point releases may update)" "$(pinline)" "version 615.*"
csconf turing-plus; eq "ladder: newest fails to build, the next older builds (rc 0)" "$(STUB_NVVERS="$NV4" STUB_FAIL_VERS=615.71.10 cs run)" 0
eq "ladder: ... status installed" "$(st)" "installed:1.0"
eq "ladder: ... the version that built is recorded" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "615.71.09-2"
grep -qx 'INSTALLED_DRIVER=615.71.09-2' "$CS/etc/ncz/cuda-selection.conf" && ok "ladder: ... and written to the selection" || nok "ladder: INSTALLED_DRIVER missing"
eq "ladder: ... held at exactly that version (apt upgrade cannot pull the broken one back)" "$(pinline)" "version 615.71.09-2"
eq "ladder: ... the driver set was installed at 615.71.10-1 then 615.71.09-2" "$(grep -v '^remove ' "$CS/apt.calls" | grep nvidia-kernel-open-dkms | sed 's/.*pin=//' | tr '\n' ' ')" "615.71.10-1 615.71.09-2 "
grep -q 'pin=615.71.09-1' "$CS/apt.calls" && nok "ladder: an older packaging revision of the same driver was tried" || ok "ladder: one attempt per upstream version (highest revision)"
eq "ladder: no half-configured module package left" "$(awk '$1=="nvidia-kernel-open-dkms"{print $2" "$3}' "$CS/dpkg.state")" "615.71.09-2 ii"
grep -q 'held at 615.71.09-2 (newest offered: 615.71.10-1)' "$CS/setup.log" && ok "ladder: the hold and its reason are logged" || nok "ladder: hold not logged"
csconf turing-plus; eq "ladder: an incomplete set at a version is skipped (rc 0)" "$(STUB_NVVERS="$NV4" STUB_UNSAT_VERS=615.71.10-1 cs run)" 0
eq "ladder: ... next version installed" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "615.71.09-2"
csconf turing-plus; eq "ladder: apt resolving the module to another version is refused (rc 1, nothing builds)" "$(STUB_NVVERS='615.71.10-1' STUB_SIMVER=615.71.10-9 cs run)" 1
[ "$(drvcalls)" = 0 ] && ok "ladder: ... a mismatched set is never installed" || nok "ladder: mismatched set installed"
csconf turing-plus; eq "ladder: Debian's own driver versions are never candidates" "$(STUB_NVVERS='615.71.10-1' STUB_DEBVERS='999.1.1-1' cs run)" 0
eq "ladder: ... NVIDIA repo version chosen" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "615.71.10-1"
csconf maxwell-volta; sed -i "s#^KMOD_PKG=.*#KMOD_PKG=nvidia-kernel-open-dkms#" "$CS/etc/ncz/cuda-selection.conf"
eq "ladder: the family limit holds (Maxwell..Volta: 580.* only)" "$(STUB_NVVERS='615.71.10-1 580.196.07-1 580.178.04-1' STUB_TKS='12-9' STUB_FAIL_VERS=615.71.10 cs run)" 0
eq "ladder: ... 580 chosen, 615 never tried" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)|$(grep -c 'pin=615' "$CS/apt.calls")" "580.196.07-1|0"

# ------------------------------- ncz-cuda-setup: every driver fails -> clean, visible, retried on change
NV3='615.71.10-1 615.71.09-2 610.57.04-1'
csconf turing-plus; eq "allfail: no offered driver builds (rc 1)" "$(STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10 615.71.09 610.57.04' cs run)" 1
eq "allfail: status failed:no-buildable-driver" "$(st)" "failed:no-buildable-driver"
eq "allfail: every offered version was tried once" "$(drvcalls)" 3
eq "allfail: one build record per version" "$(wc -l < "$CS/var/lib/ncz/cuda-setup.dkms-failed" | tr -d ' ')" 3
grep -q '^remove .*nvidia-kernel-open-dkms' "$CS/apt.calls" && ok "allfail: the unbuildable module package was removed" || nok "allfail: module package not removed"
awk '$1=="nvidia-kernel-open-dkms" && $3 ~ /^i[FUH]/' "$CS/dpkg.state" | grep -q . && nok "allfail: a half-configured module package was left behind" || ok "allfail: no half-configured (iF) module package left"
eq "allfail: the family pin is restored" "$(pinline)" "version [1-9][0-9][0-9]*"
grep -q 'integrated GPU' "$CS/etc/motd.d/ncz-nvidia-driver" 2>/dev/null && ok "allfail: a login notice tells the user (not just a failed unit)" || nok "allfail: no user-visible notice"
cs status >/dev/null; grep -q '615.71.10 for kernel' "$CS/out" && grep -q '610.57.04 for kernel' "$CS/out" && ok "allfail: status lists every failed build with its first error" || nok "allfail: status lacks the build failures"
rm -f "$CS/apt.calls"
eq "allfail: scheduled run with nothing new is a quiet no-op (rc 0)" "$(STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10 615.71.09 610.57.04' cs run --scheduled)" 0
[ ! -e "$CS/apt.calls" ] && ok "allfail: ... no rebuild, no apt (the timer stays cheap)" || nok "allfail: timer rebuilt identical inputs"
eq "allfail: a NEW driver version in the index is tried at once (rc 0)" "$(STUB_NVVERS="615.80.01-1 $NV3" STUB_FAIL_VERS='615.71.10 615.71.09 610.57.04' cs run --scheduled)" 0
eq "allfail: ... only the new version was built" "$(grep -v '^remove ' "$CS/apt.calls" | grep nvidia-kernel-open-dkms | sed 's/.*pin=//' | tr '\n' ' ')" "615.80.01-1 "
[ ! -e "$CS/etc/motd.d/ncz-nvidia-driver" ] && ok "allfail: the notice is removed once a driver works" || nok "allfail: stale notice left"
csconf turing-plus; STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10 615.71.09 610.57.04' cs run >/dev/null; rm -f "$CS/apt.calls"
eq "allfail: a NEW kernel retries every version (rc 0)" "$(STUB_KVER=$KV_B STUB_NVVERS="$NV3" cs run --scheduled)" 0
grep -q 'not yet built with this kernel' "$CS/setup.log" && ok "allfail: retry reason logged" || nok "allfail: retry reason not logged"
csconf turing-plus; STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10 615.71.09 610.57.04' cs run >/dev/null; rm -f "$CS/apt.calls"
echo '/* CONFIG_CGROUP_DMEM is not set */' > "$CS/modules/$KV_A/build/include/generated/autoconf.h"
STUB_NVVERS="$NV3" cs run --scheduled >/dev/null
[ "$(drvcalls)" -ge 1 ] && ok "allfail: changed kernel config (same release) retried" || nok "allfail: changed config not retried"
csconf turing-plus; STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10 615.71.09 610.57.04' cs run >/dev/null; rm -f "$CS/apt.calls"
shipped
STUB_NVVERS="$NV3" cs run --scheduled >/dev/null
[ "$(drvcalls)" -ge 1 ] && ok "allfail: a new local patch set retried" || nok "allfail: new patch set not retried"
csconf turing-plus; eq "ladder: a set that drops an NVIDIA driver package (another series) installs (rc 0)" "$(STUB_NVVERS='595.112.07-1' STUB_SIM_REMV='nvidia-powerd libnvidia-tileiras:amd64' cs run)" 0
grep -q 'drops NVIDIA package(s): nvidia-powerd libnvidia-tileiras:amd64' "$CS/setup.log" && ok "ladder: ... the dropped driver packages are logged" || nok "ladder: dropped driver packages not logged"
csconf turing-plus; eq "ladder: a non-NVIDIA removal is still refused (rc 1)" "$(STUB_NVVERS='595.112.07-1' STUB_SIM_REMV='nvidia-powerd libfoo' cs run)" 1
eq "ladder: ... failed:would-remove-packages" "$(st)" "failed:would-remove-packages"
[ "$(drvcalls)" = 0 ] && ok "ladder: ... nothing installed" || nok "ladder: installed despite a non-NVIDIA removal"
csconf turing-plus; eq "ladder: newest fails, next is not installable next to it (rc 1)" "$(STUB_NVVERS='615.71.10-1 610.57.04-1' STUB_FAIL_VERS=615.71.10 STUB_UNSAT_VERS=610.57.04-1 cs run)" 1
eq "ladder: ... after the cleanup removed the half-configured set, the not-installable version is tried again" "$(st)|$(grep -c '|-|' "$CS/var/lib/ncz/cuda-setup.dkms-failed")" "failed:dkms-build|0"
eq "ladder: ... and installs on the next timer run (rc 0)" "$(STUB_NVVERS='615.71.10-1 610.57.04-1' STUB_FAIL_VERS=615.71.10 cs run --scheduled)" 0
eq "ladder: ... 610.57.04-1 installed" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "610.57.04-1"
csconf turing-plus; eq "allfail: removal that would take other packages is refused" "$(STUB_NVVERS='615.71.10-1' STUB_FAIL_VERS=615.71.10 STUB_REMV='nvidia-kernel-open-dkms libfoo' cs run)" 1
grep -q 'NOT removing the unconfigured nvidia-kernel-open-dkms: it would also remove: libfoo' "$CS/setup.log" && ok "allfail: ... logged, nothing removed" || nok "allfail: unsafe removal not refused"
csconf turing-plus; eq "allfail: explicit retry rebuilds and installs (rc 0)" "$(STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10' cs retry)" 0
[ ! -e "$CS/var/lib/ncz/cuda-setup.dkms-failed" ] && ok "allfail: success clears the build records" || nok "allfail: build records survive success"
csconf turing-plus; eq "ladder: at most NCZ_CUDA_DRIVER_TRIES versions per run (rc 1)" "$(NCZ_CUDA_DRIVER_TRIES=1 STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10' cs run)" 1
eq "ladder: ... status says builds are still being tried" "$(st)" "failed:dkms-build"
eq "ladder: ... the timer continues with the next version (rc 0)" "$(NCZ_CUDA_DRIVER_TRIES=1 STUB_NVVERS="$NV3" STUB_FAIL_VERS='615.71.10' cs run --scheduled)" 0
eq "ladder: ... 615.71.09-2 installed on the second run" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "615.71.09-2"

# patch(1) missing (dkms not installed yet): installed before the content check
mkdir -p "$CS/nopatch"; for t in bash sh cat sed awk grep sort head tail tr cut cksum find mktemp install mv rm cp mkdir ls date tee wc basename dirname touch flock uname rmdir getent curl chmod ln readlink env dpkg-deb tar gzip xz zstd; do
    p=$(PATH="$CS/bin:$PATH" command -v "$t" 2>/dev/null) && ln -sf "$p" "$CS/nopatch/$t"; done
for t in "$CS/bin/"*; do ln -sf "$t" "$CS/nopatch/$(basename "$t")"; done
csconf turing-plus; shipped
PATH="$CS/nopatch" "$CS/ncz-cuda-setup" run >"$CS/out" 2>&1
grep -q -- '--no-remove patch' "$CS/apt.calls" && ok "patch: patch(1) is installed before the local patches are checked" || nok "patch: patch(1) missing -> patches refused without trying to install it"

# ------------------------------- ncz-cuda-setup: the module must exist for the kernel; kernel updates
csconf turing-plus; eq "kmod: apt installed the set but no module exists for the kernel -> dkms autoinstall builds it (rc 0)" "$(STUB_NVVERS='615.71.10-1' STUB_NOMOD=1 cs run)" 0
grep -q 'no nvidia module for kernel 7.3.0-t2-ncz; running dkms autoinstall' "$CS/setup.log" && ok "kmod: ... the missing module is noticed and logged" || nok "kmod: missing module not noticed"
csconf turing-plus; eq "kmod: no module and dkms autoinstall fails for every version (rc 1)" "$(STUB_NVVERS='615.71.10-1 615.71.09-2' STUB_NOMOD=1 STUB_DKMS_FAIL=1 cs run)" 1
grep -q 'nv.c:9:9: error: new kernel API' "$CS/var/lib/ncz/cuda-setup.dkms-failed" && ok "kmod: ... recorded as a DKMS build failure with its first error" || nok "kmod: autoinstall failure not recorded"
eq "kmod: ... both versions tried" "$(drvcalls)" 2
csconf turing-plus; STUB_NVVERS='615.71.10-1' cs run >/dev/null
mkdir -p "$CS/modules/$KV_B/build"
eq "kernel: the hook exits 0" "$(cs kernel-postinst "$KV_B")" 0
[ ! -e "$CS/var/lib/ncz/cuda-setup.done" ] && eq "kernel: a new kernel without an nvidia module re-arms the setup" "$(st)" "pending:driver-repair" || nok "kernel: missing module for a new kernel left silent"
eq "kernel: ... and remembers which kernel" "$(cat "$CS/var/lib/ncz/cuda-setup.repair-kernel" 2>/dev/null)" "$KV_B"
rm -f "$CS/apt.calls"
eq "kernel: still running the old kernel -> the timer waits (rc 0)" "$(STUB_NVVERS='615.71.10-1' cs run --scheduled)" 0
[ ! -e "$CS/apt.calls" ] && ok "kernel: ... and does nothing until the new kernel runs" || nok "kernel: repaired for the wrong kernel"
eq "kernel: after booting it, the timer builds the module for it (rc 0)" "$(STUB_KVER=$KV_B STUB_NOMOD=1 STUB_NVVERS='615.71.10-1' cs run --scheduled)" 0
[ -e "$CS/mods/$KV_B" ] && [ ! -e "$CS/var/lib/ncz/cuda-setup.repair-kernel" ] && ok "kernel: ... module built for the new kernel, repair record cleared" || nok "kernel: not repaired"
# a second new kernel before the reboot: the pending repair follows it
csconf turing-plus; STUB_NVVERS='615.71.10-1' cs run >/dev/null; mkdir -p "$CS/modules/$KV_B/build" "$CS/modules/7.3.3-t2-ncz/build"
cs kernel-postinst "$KV_B" >/dev/null; cs kernel-postinst 7.3.3-t2-ncz >/dev/null
eq "kernel: a second kernel while a repair is pending updates the record" "$(cat "$CS/var/lib/ncz/cuda-setup.repair-kernel" 2>/dev/null)" "7.3.3-t2-ncz"
# a third kernel booted instead, also without a module: repaired now, not after booting the recorded one
csconf turing-plus; STUB_NVVERS='615.71.10-1' cs run >/dev/null; mkdir -p "$CS/modules/$KV_B/build" "$CS/modules/7.3.2-t2-ncz/build/include/generated"
cs kernel-postinst "$KV_B" >/dev/null
eq "kernel: another kernel without a module is running -> repaired now (rc 0)" "$(STUB_KVER=7.3.2-t2-ncz STUB_NOMOD=1 STUB_NVVERS='615.71.10-1' cs run --scheduled)" 0
[ -e "$CS/mods/7.3.2-t2-ncz" ] && ok "kernel: ... module built for the running kernel" || nok "kernel: running kernel left without a module"
# the recorded kernel was removed: the record is dropped instead of waiting forever
csconf turing-plus; STUB_NVVERS='615.71.10-1' cs run >/dev/null; mkdir -p "$CS/modules/$KV_B/build"
cs kernel-postinst "$KV_B" >/dev/null; rm -rf "$CS/modules/$KV_B"
STUB_NVVERS='615.71.10-1' cs run --scheduled >/dev/null
[ ! -e "$CS/var/lib/ncz/cuda-setup.repair-kernel" ] && [ -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "kernel: a removed kernel's repair record is dropped (no endless pending)" || nok "kernel: stuck waiting for a removed kernel"
csconf turing-plus; STUB_NVVERS='615.71.10-1' cs run >/dev/null; mkdir -p "$CS/modules/$KV_B/build" "$CS/mods"; touch "$CS/mods/$KV_B"
cs kernel-postinst "$KV_B" >/dev/null
[ -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "kernel: a new kernel the driver built for is left alone" || nok "kernel: healthy kernel update re-armed"
cs kernel-postinst 9.9.9-nohdr >/dev/null
[ -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "kernel: a kernel without headers is ignored" || nok "kernel: headerless kernel re-armed"
csconf turing-plus; rm -rf "$CS/modules/$KV_A"
eq "kmod: in a chroot whose running kernel has no headers, the target is the newest kernel with headers" "$(STUB_KVER=6.1.0-installer STUB_BUILDK=$KV_B STUB_NVVERS='615.71.10-1' STUB_FAIL_VERS=615.71.10 cs run)" 1
eq "kmod: ... the build record names that kernel" "$(cut -d'|' -f1 "$CS/var/lib/ncz/cuda-setup.dkms-failed" 2>/dev/null)" "$KV_B"
rm -f "$CS/apt.calls"; STUB_KVER=6.1.0-installer STUB_NVVERS='615.71.10-1' cs run --scheduled >/dev/null
[ ! -e "$CS/apt.calls" ] && ok "kmod: ... and the record matches later runs (no rebuild loop)" || nok "kmod: chroot record never matches; rebuild loop"

# ------------------------------- ncz-cuda-setup: DKMS failure record
csconf turing-plus; STUB_NVVERS='615.71.10-1' STUB_FAIL_VERS=615.71.10 cs run >/dev/null
grep -q "os-interface.c:3031:48: error: passing argument 1 of 'dmem_cgroup_register_region'" "$CS/setup.log" \
    && ok "dkms: the FIRST compiler error is logged" || nok "dkms: first compiler error not logged"
grep -q "a later error" "$CS/setup.log" && nok "dkms: later compiler errors are logged too (only the first should be)" || ok "dkms: only the first compiler error is logged"
grep -q "for kernel $KV_A" "$CS/setup.log" && ok "dkms: log names the kernel the build failed for" || nok "dkms: log does not name the kernel"
# a stale make.log from an older attempt must not turn a generic dpkg failure into a DKMS record
csconf turing-plus; mkdir -p "$CS/dkms/nvidia/615.71.09/build"
printf 'DKMS make.log for nvidia/615.71.09 for kernel old (x86_64)\nx.c:1:1: error: stale\n' > "$CS/dkms/nvidia/615.71.09/build/make.log"
touch -d '2026-01-01 00:00:00' "$CS/dkms/nvidia/615.71.09/build/make.log"
eq "dkms: generic driver failure with a stale make.log (rc 1)" "$(STUB_APT=drvfail cs run)" 1
eq "dkms: ... is failed:driver-install, not a DKMS failure" "$(st)" "failed:driver-install"
[ ! -s "$CS/var/lib/ncz/cuda-setup.dkms-failed" ] && ok "dkms: no DKMS record from a stale log" || nok "dkms: stale log recorded as a DKMS failure"

# ------------------------------- ncz-cuda-setup: local patches matched by CONTENT, never by version
# made-up driver versions; the shipped patch set; the real `patch`
csconf turing-plus; shipped
mksrc "$CS/usr/src/nvidia-615.80.01" 615.80.01 defect
sum_before=$(cat "$CS/usr/src/nvidia-615.80.01/kernel-open/nvidia/os-interface.c" | cksum)
eq "content: dkms-stage on a new point release with the same defect (rc 0)" "$(cs dkms-stage "$CS/usr/src/nvidia-615.80.01")" 0
want_line='PATCH[${#PATCH[@]}]="ncz-0001-dmem-cgroup-init-linux-7.3.patch"'
grep -qxF -- "$want_line" "$CS/etc/dkms/nvidia-615.80.01.conf" 2>/dev/null && ok "content: ... gets the patch (conf lists it)" || nok "content: defect source not patched: $(tail -n3 "$CS/setup.log")"
[ -f "$CS/usr/src/nvidia-615.80.01/patches/ncz-0001-dmem-cgroup-init-linux-7.3.patch" ] && ok "content: ... patch staged in the DKMS source dir" || nok "content: patch not staged"
grep -q 'applies to nvidia 615.80.01 exactly' "$CS/setup.log" && ok "content: ... the exact (fuzz 0) apply is logged" || nok "content: apply not logged"
eq "content: the driver source itself is never modified" "$(cat "$CS/usr/src/nvidia-615.80.01/kernel-open/nvidia/os-interface.c" | cksum)" "$sum_before"
( set +u; unset PATCH; . "$CS/etc/dkms/nvidia-615.80.01.conf"; [ "${PATCH[0]:-}" = ncz-0001-dmem-cgroup-init-linux-7.3.patch ] ) \
    && ok "content: the conf sources as bash and sets PATCH[0] when dkms.conf has no patches" || nok "content: conf does not source to PATCH[0]"
( set +u; PATCH=(vendor.patch); . "$CS/etc/dkms/nvidia-615.80.01.conf"; [ "${PATCH[0]}|${PATCH[1]:-}" = "vendor.patch|ncz-0001-dmem-cgroup-init-linux-7.3.patch" ] ) \
    && ok "content: the conf appends after a dkms.conf PATCH[0]" || nok "content: the conf overwrote an existing PATCH[0]"
mksrc "$CS/usr/src/nvidia-615.80.02" 615.80.02 fixed
eq "content: dkms-stage on a release that carries the fix upstream (rc 0)" "$(cs dkms-stage "$CS/usr/src/nvidia-615.80.02")" 0
[ ! -e "$CS/etc/dkms/nvidia-615.80.02.conf" ] && ok "content: ... gets NO patch" || nok "content: patch staged although the fix is upstream"
grep -q 'not needed, nvidia 615.80.02 already carries the fix' "$CS/setup.log" && ok "content: ... and says why" || nok "content: fixed-upstream not logged"
mksrc "$CS/usr/src/nvidia-615.80.03" 615.80.03 drift
eq "content: dkms-stage on a release where the patch does not apply cleanly (rc 0)" "$(cs dkms-stage "$CS/usr/src/nvidia-615.80.03")" 0
[ ! -e "$CS/etc/dkms/nvidia-615.80.03.conf" ] && ok "content: ... the patch is REFUSED (never force-applied)" || nok "content: patch staged on a source it does not fit"
grep -q 'REFUSED for nvidia 615.80.03: ncz-0001-dmem-cgroup-init-linux-7.3.patch does not apply exactly' "$CS/setup.log" && ok "content: ... refusal logged" || nok "content: refusal not logged"
# a source that gains the fix later -> the staged patch is withdrawn
mksrc "$CS/usr/src/nvidia-615.80.01" 615.80.01 fixed; mkdir -p "$CS/usr/src/nvidia-615.80.01/patches"
cp "$SHIPPED_SET/"*.patch "$CS/usr/src/nvidia-615.80.01/patches/"
cs dkms-stage "$CS/usr/src/nvidia-615.80.01" >/dev/null
[ ! -e "$CS/etc/dkms/nvidia-615.80.01.conf" ] && [ ! -e "$CS/usr/src/nvidia-615.80.01/patches/ncz-0001-dmem-cgroup-init-linux-7.3.patch" ] \
    && ok "content: conf and staged patch withdrawn once the source has the fix" || nok "content: stale local patch left behind"
# dkms.conf with a trailing comment still names the module and version
mksrc "$CS/usr/src/nvidia-615.80.05" 615.80.05 defect; sed -i 's/^PACKAGE_VERSION=.*/PACKAGE_VERSION="615.80.05"   # point release/' "$CS/usr/src/nvidia-615.80.05/dkms.conf"
cs dkms-stage "$CS/usr/src/nvidia-615.80.05" >/dev/null
[ -e "$CS/etc/dkms/nvidia-615.80.05.conf" ] && ok "content: dkms.conf values with a trailing comment are parsed" || nok "content: trailing comment broke dkms.conf parsing"
# two sets on the same file are checked in order, cumulatively, as DKMS applies them
rm -rf "$CS/patches"; shipped; mkdir -p "$CS/patches/nvidia/0002-on-top"
printf 'kernel-open/nvidia/os-interface.c\nNCZ_SECOND_SET_MARKER\n' > "$CS/patches/nvidia/0002-on-top/fixed-upstream"
cat > "$CS/patches/nvidia/0002-on-top/ncz-0002-on-top.patch" <<'P2EOF'
--- a/kernel-open/nvidia/os-interface.c
+++ b/kernel-open/nvidia/os-interface.c
@@ -10,4 +10,5 @@
 #if defined(NV_DMEM_CGROUP_INIT_PRESENT)
     struct dmem_cgroup_init init = { .size = size };
+    /* NCZ_SECOND_SET_MARKER */
     void *region = dmem_cgroup_register_region(&init, "%s", name);
 #else
P2EOF
mksrc "$CS/usr/src/nvidia-615.80.06" 615.80.06 defect
cs dkms-stage "$CS/usr/src/nvidia-615.80.06" >/dev/null
eq "content: a set that applies on top of an earlier set is accepted, in DKMS order" "$(sed -n 's/^PATCH\[.*\]="\(.*\)"$/\1/p' "$CS/etc/dkms/nvidia-615.80.06.conf" 2>/dev/null | tr '\n' ' ')" "ncz-0001-dmem-cgroup-init-linux-7.3.patch ncz-0002-on-top.patch "
rm -rf "$CS/patches/nvidia/0001-dmem-cgroup-init-linux-7.3"
cs dkms-stage "$CS/usr/src/nvidia-615.80.06" >/dev/null
[ ! -e "$CS/etc/dkms/nvidia-615.80.06.conf" ] && ok "content: ... and refused when the set it depends on is not applied" || nok "content: dependent set accepted on its own"
rm -rf "$CS/patches"; shipped
mkdir -p "$CS/usr/src/not-a-dkms-tree"
eq "content: dkms-stage on a directory without a usable dkms.conf exits 1" "$(cs dkms-stage "$CS/usr/src/not-a-dkms-tree")" 1
# guards: no marker, unsafe marker, vendor patches already in dkms.conf
mksrc "$CS/usr/src/nvidia-615.80.04" 615.80.04 defect
rm -f "$CS/patches/nvidia/"*/fixed-upstream
cs dkms-stage "$CS/usr/src/nvidia-615.80.04" >/dev/null
[ ! -e "$CS/etc/dkms/nvidia-615.80.04.conf" ] && grep -q 'no usable fixed-upstream marker' "$CS/setup.log" && ok "content: a set without a fixed-upstream marker is refused" || nok "content: marker-less set applied"
shipped; printf '../../etc/passwd\nroot\n' > "$CS/patches/nvidia/$(basename "$SHIPPED_SET")/fixed-upstream"
cs dkms-stage "$CS/usr/src/nvidia-615.80.04" >/dev/null
grep -q "ignoring unsafe fixed-upstream path" "$CS/setup.log" && [ ! -e "$CS/etc/dkms/nvidia-615.80.04.conf" ] && ok "content: an unsafe marker path is refused and logged" || nok "content: unsafe marker path not rejected"
rm -rf "$CS/patches"; shipped; echo 'PATCH[0]="vendor.patch"' >> "$CS/usr/src/nvidia-615.80.04/dkms.conf"
cs dkms-stage "$CS/usr/src/nvidia-615.80.04" >/dev/null
[ ! -e "$CS/etc/dkms/nvidia-615.80.04.conf" ] && ok "content: not combined with patches the package already lists" || nok "content: combined with vendor patches unverified"
# the install path: the module .deb is checked BEFORE dpkg runs its postinst
if [ "$HAVE_DPKG_DEB" = 1 ]; then
    csconf turing-plus; shipped
    eq "content: install of a new point release with the defect (rc 0)" "$(STUB_NVVERS='615.80.01-1' STUB_PATCH_FIXES=1 STUB_FAIL_VERS=615.80.01 cs run)" 0
    eq "content: ... the patch conf existed when the postinst built the module" "$(cat "$CS/conf-at-postinst" 2>/dev/null)" yes
    eq "content: ... and that build succeeded" "$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "615.80.01-1"
    csconf turing-plus; shipped
    eq "content: install of a release with the fix upstream (rc 0)" "$(STUB_NVVERS='615.80.02-1' STUB_FIXED_VERS=615.80.02 cs run)" 0
    eq "content: ... no patch conf at postinst time" "$(cat "$CS/conf-at-postinst" 2>/dev/null)" no
    csconf turing-plus; shipped
    eq "content: patch does not fit the newest, so the ladder falls back (rc 0)" "$(STUB_NVVERS='615.80.03-1 615.71.09-2' STUB_PATCH_FIXES=1 STUB_FAIL_VERS='615.80.03 615.71.09' STUB_DRIFT_VERS=615.80.03 cs run)" 0
    eq "content: ... 615.80.03 refused the patch and failed; ladder result" "$(grep -c 'REFUSED for nvidia 615.80.03' "$CS/setup.log")|$(cat "$CS/var/lib/ncz/cuda-setup.driver" 2>/dev/null)" "1|615.71.09-2"
    # apt hook: a plain `apt upgrade` to a new point release gets the same check
    csconf turing-plus; shipped; mkdeb "$CS/archives/nvidia-kernel-open-dkms_615.80.05-1_amd64.deb" 615.80.05-1 defect
    mkdir -p "$CS/archives/other"; printf 'Package: hello\nVersion: 1\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' > "$CS/archives/other/c"
    eq "hook: apt-pre-install always exits 0" "$(printf '%s\n%s\n' "$CS/archives/nvidia-kernel-open-dkms_615.80.05-1_amd64.deb" /nonexistent.deb | cs apt-pre-install)" 0
    grep -qxF -- "$want_line" "$CS/etc/dkms/nvidia-615.80.05.conf" 2>/dev/null && ok "hook: a driver update through apt gets the content-matched patch" || nok "hook: patch not staged by the apt hook"
    rm -f "$CS/etc/dkms/nvidia-615.80.05.conf"
    printf '%s\n' "$CS/archives/nvidia-kernel-open-dkms_615.80.05-1_amd64.deb" | NCZ_CUDA_SETUP_TXN=1 PATH="$CS/bin:$PATH" "$CS/ncz-cuda-setup" apt-pre-install >/dev/null 2>&1
    [ ! -e "$CS/etc/dkms/nvidia-615.80.05.conf" ] && ok "hook: skipped inside ncz-cuda-setup's own apt transaction (it stages)" || nok "hook: ran inside a ncz-cuda-setup transaction"
    ( exec 8>"$CS/lock"; flock -n 8; printf '%s\n' "$CS/archives/nvidia-kernel-open-dkms_615.80.05-1_amd64.deb" | PATH="$CS/bin:$PATH" "$CS/ncz-cuda-setup" apt-pre-install >/dev/null 2>&1 )
    [ -e "$CS/etc/dkms/nvidia-615.80.05.conf" ] && ok "hook: a user's apt while a setup run holds the lock still gets the patch" || nok "hook: skipped a foreign apt transaction because the run lock was held"
    grep -q 'NCZ_CUDA_SETUP_TXN=1 apt-get' "$ROOT/assets/nvidia/ncz-cuda-setup" && ok "hook: every apt call of the tool carries the transaction marker" || nok "hook: apt_run lacks the marker"
else
    echo "SKIP content/hook .deb tests: no dpkg-deb on this host"
fi
eq "hook: apt-pre-install with no patch sets drains stdin and exits 0" "$(rm -rf "$CS/patches"; printf 'x.deb\n' | cs apt-pre-install)" 0
# post-invoke: a later apt upgrade whose module build failed re-arms the setup
csconf turing-plus; date > "$CS/var/lib/ncz/cuda-setup.done"; echo "nvidia-kernel-open-dkms 615.80.06-1 iF" > "$CS/dpkg.state"
eq "hook: apt-post-invoke always exits 0" "$(cs apt-post-invoke)" 0
[ ! -e "$CS/var/lib/ncz/cuda-setup.done" ] && eq "hook: a half-configured driver after apt re-arms the setup" "$(st)" "pending:driver-repair" || nok "hook: failed driver update not handed back"
date > "$CS/var/lib/ncz/cuda-setup.done"; echo "nvidia-kernel-open-dkms 615.80.06-1 ii" > "$CS/dpkg.state"; echo installed:1.0 > "$CS/var/lib/ncz/cuda-toolkit.status"
cs apt-post-invoke >/dev/null
[ -e "$CS/var/lib/ncz/cuda-setup.done" ] && eq "hook: a healthy driver is left alone" "$(st)" "installed:1.0" || nok "hook: healthy install re-armed"
unset NCZ_NV_DKMS_PATCHES NCZ_DKMS_ETC NCZ_DKMS_TREE NCZ_SRC_ROOT NCZ_MODULES_ROOT

# first-boot notice for the all-fail case
NR="$W/notice"; rm -rf "$NR"; mkdir -p "$NR/var/lib/ncz" "$NR/var/lib/dpkg" "$NR/etc/ncz" "$NR/etc/systemd/system/timers.target.wants"
: > "$NR/var/lib/dpkg/status"; echo FAMILY=turing-plus > "$NR/etc/ncz/cuda-selection.conf"; : > "$NR/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer"
echo failed:no-buildable-driver > "$NR/var/lib/ncz/cuda-toolkit.status"
( . "$ROOT/post-install/lib/dkms-pending.sh"; ncz_firstboot_gpu_notice "$NR" ) | grep -q 'integrated GPU' \
    && ok "notice: first boot explains that no NVIDIA driver builds and the iGPU is used" || nok "notice: no first-boot explanation for failed:no-buildable-driver"

# ------------------------------------------- component chooser: "cuda" visibility
# Run the real detection block of preseed/component-selector.sh against a fake
# sysfs PCI tree: the option is offered only when an NVIDIA display controller exists.
mkpci() {   # mkpci DIR vendor class ...
    rm -rf "$1"; mkdir -p "$1"; local d="$1" n=0; shift
    while [ $# -ge 2 ]; do mkdir -p "$d/0000:0$n:00.0"; echo "$1" > "$d/0000:0$n:00.0/vendor"; echo "$2" > "$d/0000:0$n:00.0/class"; n=$((n+1)); shift 2; done
}
chooser_components() {   # prints the COMPONENTS string the selector would offer
    sed -n '/^COMPONENTS="\\$/,/^INTERNAL_COMPONENTS=/p' "$ROOT/preseed/component-selector.sh" \
      | sed "s#/sys/bus/pci/devices#$1#g" | sed '$d' > "$W/chooser.sh"
    ( NCZ_UNAME_M=x86_64; . "$W/chooser.sh"; printf '%s' "$COMPONENTS" )
}
mkpci "$W/pci1" 0x8086 0x030000 0x10de 0x030000
case "$(chooser_components "$W/pci1")" in *"|cuda:"*) ok "chooser: cuda offered when an NVIDIA GPU is present";; *) nok "chooser: cuda not offered with an NVIDIA GPU";; esac
mkpci "$W/pci2" 0x8086 0x030000 0x1002 0x030000
case "$(chooser_components "$W/pci2")" in *cuda*) nok "chooser: cuda offered without an NVIDIA GPU";; *) ok "chooser: cuda hidden without an NVIDIA GPU";; esac
mkpci "$W/pci3" 0x10de 0x040300
case "$(chooser_components "$W/pci3")" in *cuda*) nok "chooser: cuda offered for an NVIDIA audio function only";; *) ok "chooser: cuda hidden for an NVIDIA audio-only function";; esac
mkpci "$W/pci4" 0x10de 0x030200
case "$(chooser_components "$W/pci4")" in *"|cuda:"*) ok "chooser: cuda offered for an NVIDIA 3D controller (0302)";; *) nok "chooser: 3D controller not offered";; esac
chooser_components_arch() { sed -n '/^COMPONENTS="\\$/,/^INTERNAL_COMPONENTS=/p' "$ROOT/preseed/component-selector.sh" | sed "s#/sys/bus/pci/devices#$1#g" | sed '$d' > "$W/chooser2.sh"; ( NCZ_UNAME_M="$2"; . "$W/chooser2.sh"; printf '%s' "$COMPONENTS" ); }
case "$(chooser_components_arch "$W/pci1" aarch64)" in *cuda*) nok "chooser: cuda offered on an arm64 machine with an NVIDIA card";; *) ok "chooser: cuda is never offered on arm64 (54 is amd64-only)";; esac
case "$(chooser_components_arch "$W/pci1" x86_64)" in *"|cuda:"*) ok "chooser: cuda offered on x86_64 with an NVIDIA GPU";; *) nok "chooser: cuda not offered on x86_64";; esac
grep -q '^INTERNAL_COMPONENTS=.*cuda' "$ROOT/preseed/component-selector.sh" && ok "chooser: cuda is a valid ncz_components= token even when hidden" || nok "chooser: cuda not a valid token"
grep -q 'cuda-selection\|COMPONENTS_\$_bit\|for _bit in .* cuda' "$ROOT/preseed/component-selector.sh" && ok "chooser: writes COMPONENTS_cuda for 54-gpu-accel.sh" || nok "chooser: COMPONENTS_cuda not written"

echo "----"
echo "PASS=$PASS FAIL=$FAILS"
exit "$FAILS"
