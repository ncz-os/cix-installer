#!/bin/bash
# test-amd64-cuda-gates.sh -- positive AND negative tests for the AMD64 dynamic
# NVIDIA driver + CUDA design:
#   - family selection per PCI id (cuda-select.sh), mixed-GPU rule, plans, pins
#   - static asset gate (verify-cuda-assets.sh): keys, units, no CUDA in manifests
#     or in the offline mirror
#   - installed-target gate (verify-cuda-installed-target.sh)
#   - the real NVIDIA function of post-install/54-gpu-accel.sh run under stubs
#   - the real assets/nvidia/ncz-cuda-setup run under stubs (network down, network
#     up, removals refused, backoff, retry, skip, status)
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
eq "turing plan: driver pin"      "$(plan turing-plus DRIVER_PIN)" '615.*'
eq "turing plan: open kernel modules" "$(plan turing-plus KMOD)" open
eq "turing plan: toolkit"         "$(plan turing-plus TOOLKIT)" 13-4
eq "turing plan: repo"            "$(plan turing-plus REPO)" debian13
eq "maxwell-volta plan: driver pin" "$(plan maxwell-volta DRIVER_PIN)" '580.*'
eq "maxwell-volta plan: PROPRIETARY module (open is Turing+ only)" "$(plan maxwell-volta KMOD)" proprietary
eq "maxwell-volta plan: driver pkg" "$(plan maxwell-volta DRIVER_PKGS)" cuda-drivers-580
eq "maxwell-volta plan: CUDA 12.9" "$(plan maxwell-volta TOOLKIT)" 12-9
eq "maxwell-volta plan: repo"     "$(plan maxwell-volta REPO)" debian12
eq "maxwell-volta plan: needs sequoia SHA-1 relax" "$(plan maxwell-volta SEQUOIA_RELAX)" 1
eq "turing plan: no sequoia relax" "$(plan turing-plus SEQUOIA_RELAX)" 0
eq "kepler plan: no toolkit"      "$(plan kepler-older TOOLKIT)" none
eq "kepler plan: no driver pkgs"  "$(plan kepler-older DRIVER_PKGS)" ""
expect_rc 1 "unknown family has no plan" ncz_cuda_plan bogus
for f in turing-plus maxwell-volta; do
    case "$(plan $f TOOLKIT_PKGS)" in *cuda-libraries-dev-*) ok "$f plan includes the -dev headers (cuda-libraries-dev)";; *) nok "$f plan lacks headers";; esac
done
case "$(ncz_cuda_pin_file maxwell-volta)" in *"Pin: version 580.*"*) ok "pascal pin holds the driver family on 580.*";; *) nok "pascal pin wrong";; esac
case "$(ncz_cuda_pin_file maxwell-volta)" in *615*) nok "pascal pin mentions 615";; *) ok "pascal pin never allows 615";; esac
case "$(ncz_cuda_pin_file turing-plus)" in *"Pin: version 615.*"*) ok "turing pin holds the driver family on 615.*";; *) nok "turing pin wrong";; esac
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
mkroot "$R"; sed -i "s/cuda-libraries-dev-/cuda-libraries-/g" "$R/post-install/lib/cuda-select.sh"
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
    fi
    if [ "$kind" = pending ]; then
        printf '#!/bin/sh\n' > "$d/usr/local/sbin/ncz-cuda-setup"; chmod +x "$d/usr/local/sbin/ncz-cuda-setup"
        : > "$d/etc/systemd/system/ncz-cuda-setup.service"; : > "$d/etc/systemd/system/ncz-cuda-setup.timer"
        ln -s ../ncz-cuda-setup.timer "$d/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer"
    fi
}
T="$W/target"
mktarget "$T" "installed:13.4.92-1" installed;   expect_rc 0 "target: installed (Turing, CUDA 13.4) passes" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" installed;   expect_rc 0 "target: auto derives installed" "$TG" --root "$T"
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
mktarget "$T" "failed:would-remove-packages";    expect_rc 1 "target: recorded failure is always rejected (auto)" "$TG" --root "$T"
mktarget "$T" "failed:would-remove-packages";    expect_rc 1 "target: recorded failure is rejected (expect skipped)" "$TG" --root "$T" --expect skipped
mktarget "$T" "";                                expect_rc 1 "target: no status file is rejected (silent hook)" "$TG" --root "$T"
mktarget "$T" "bogus";                           expect_rc 1 "target: unrecognized status is rejected" "$TG" --root "$T"

# ---------------------------------------------- 54-gpu-accel.sh NVIDIA function
# Extract the function block from the real hook and redirect its absolute paths
# into a scratch root, so the tested code IS the shipped code.
SB="$W/sb"; mkdir -p "$SB/bin" "$SB/post-install/lib" "$SB/assets"
cp "$ROOT/post-install/lib/cuda-select.sh" "$SB/post-install/lib/"
extract54() {
    awk '/^# --- NVIDIA driver \+ CUDA: selected per GPU family/{f=1} /^echo "\[54\] AMD64 GPU\/accelerator vendor detection/{f=0} f' \
        "$ROOT/post-install/54-gpu-accel.sh" \
      | sed -e "s#/var/lib/ncz#$SB/var/lib/ncz#g" -e "s#/etc/ncz#$SB/etc/ncz#g" \
            -e "s#/etc/cix-installer#$SB/etc/cix-installer#g" -e "s#/usr/local/lib/cix-installer/COMPONENTS#$SB/x/COMPONENTS#g" \
            -e "s#NCZ_NV_ASSETS=[^ ]*#NCZ_NV_ASSETS=$SB/assets#" \
            -e "s#/usr/local/sbin#$SB/usr/local/sbin#g" -e "s#/etc/systemd/system#$SB/etc/systemd/system#g" \
            -e "s#/etc/apt/preferences.d#$SB/etc/apt/preferences.d#g" -e "s#/etc/apt/sources.list.d#$SB/etc/apt/sources.list.d#g" \
            -e "s#/usr/share/keyrings#$SB/usr/share/keyrings#g" -e "s#/etc/crypto-policies#$SB/etc/crypto-policies#g" \
            -e "s#/usr/share/apt/default-sequoia.config#$SB/default-sequoia.config#g"
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
    rm -rf "$SB/var" "$SB/etc" "$SB/usr" "$SB/x"; mkdir -p "$SB/etc/cix-installer" "$SB/x"
    printf '%s\n' "$1" > "$SB/lspci"
    [ "${3:-none}" != none ] && echo "$3" > "$SB/etc/cix-installer/COMPONENTS_cuda"
    cat > "$SB/post-install/wrap.sh" <<EOF
#!/bin/bash
lspci() { cat "$SB/lspci"; }
export -f lspci 2>/dev/null
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
grep -q '^FAMILY=turing-plus' "$SB/etc/ncz/cuda-selection.conf" && ok "54: cuda-selection.conf records the family" || nok "54: conf missing family"
grep -q '^GPU_PCI_ID=10de:1f15' "$SB/etc/ncz/cuda-selection.conf" && ok "54: cuda-selection.conf records the GPU id" || nok "54: conf missing GPU id"
grep -q 'Pin: version 615' "$SB/etc/apt/preferences.d/ncz-nvidia-cuda.pref" && ok "54: driver-branch pin written (615.*)" || nok "54: pin missing"
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
got="$(run54w "$IGPU" 0)"; eq "54: no NVIDIA GPU is skipped" "$got" "skipped:no-nvidia-gpu"
got="$(run54w "$RTX" 0 0)"; eq "54: component chooser answer 0 skips" "$got" "skipped:component-not-selected"
got="$(run54w "$RTX" 0 1)"; eq "54: component chooser answer 1 installs" "$got" "installed:13.4.92-1"
got="$(run54w "$RTX" 0 none 1)"; eq "54: NCZ_SKIP_CUDA=1 skips" "$got" "skipped:operator-disabled"
# a failure in the setup tool must not abort the caller
( PATH="$SB/bin:$PATH" STUB_SETUP_RC=1 bash "$SB/post-install/wrap.sh" >/dev/null 2>&1 ) && ok "54: a hard setup failure returns 0 (never aborts post-install)" || nok "54: hard failure aborted the hook"

# -------------------------------------------------- ncz-cuda-setup under stubs
CS="$W/cs"; mkdir -p "$CS/bin"
sed -e "s#/etc/ncz#$CS/etc/ncz#g" -e "s#/var/lib/ncz#$CS/var/lib/ncz#g" -e "s#/var/log/ncz-cuda-setup.log#$CS/setup.log#g" \
    -e "s#/run/ncz-cuda-setup.lock#$CS/lock#g" -e "s#/etc/profile.d#$CS/etc/profile.d#g" \
    "$ROOT/assets/nvidia/ncz-cuda-setup" > "$CS/ncz-cuda-setup"
chmod +x "$CS/ncz-cuda-setup"
for c in systemctl ldconfig; do printf '#!/bin/bash\nexit 0\n' > "$CS/bin/$c"; chmod +x "$CS/bin/$c"; done
printf '#!/bin/bash\nif [ "${STUB_NET:-up}" = up ]; then echo "1.2.3.4 $2"; exit 0; fi; exit 2\n' > "$CS/bin/getent"
printf '#!/bin/bash\n[ "${STUB_NET:-up}" = up ] && exit 0; exit 7\n' > "$CS/bin/curl"
printf '#!/bin/bash\necho "1.0"\n' > "$CS/bin/dpkg-query"
cat > "$CS/bin/apt-get" <<EOF
#!/bin/bash
case "\$*" in
  *" update"*|update*) exit 0 ;;
  *" -s "*|*install\ -s*)
     case "\${STUB_APT:-ok}" in
        unsat)  echo "E: Unable to satisfy dependencies" >&2; exit 100 ;;
        noindex) echo "E: Unable to locate package cuda-compiler-13-4" >&2; exit 100 ;;
        remove) echo "Remv libfoo [1.0]"; exit 0 ;;
        *)      echo "Inst cuda-nvcc-13-4 (13.4.92-1 NVIDIA)"; exit 0 ;;
     esac ;;
  *) [ "\${STUB_APT:-ok}" = fetchfail ] && { echo "E: Failed to fetch https://developer.download.nvidia.com/x  Connection failed" >&2; exit 100; }
     echo "\$*" >> "$CS/apt.calls"
     [ "\${STUB_APT:-ok}" = nonvcc ] || { mkdir -p "$CS/cuda/bin"; printf '#!/bin/sh\necho "Cuda compilation tools, release 13.4"\n' > "$CS/cuda/bin/nvcc"; chmod +x "$CS/cuda/bin/nvcc"; }
     exit 0 ;;
esac
EOF
chmod +x "$CS/bin/"*
csconf() {   # csconf family
    rm -rf "$CS/etc" "$CS/var" "$CS/setup.log" "$CS/apt.calls" "$CS/cuda" "$CS/lock"; mkdir -p "$CS/etc/ncz" "$CS/var/lib/ncz"
    ncz_cuda_plan "$1" | sed -e "s#^TOOLKIT_DIR=.*#TOOLKIT_DIR=$CS/cuda#" > "$CS/etc/ncz/cuda-selection.conf"
}
cs() {       # cs <args...>  (env STUB_NET / STUB_APT)
    PATH="$CS/bin:$PATH" "$CS/ncz-cuda-setup" "$@" >"$CS/out" 2>&1; echo $?
}
st() { head -n1 "$CS/var/lib/ncz/cuda-toolkit.status" 2>/dev/null; }
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
n1=$(wc -l < "$CS/apt.calls"); eq "setup: driver and toolkit are separate apt transactions (driver first)" "$n1" 2
eq "setup: second run is idempotent (rc 0)" "$(cs run)" 0
eq "setup: second run made no further apt calls" "$(wc -l < "$CS/apt.calls")" 2
csconf turing-plus; eq "setup: removals refused (rc 1)" "$(STUB_APT=remove cs run)" 1
eq "setup: removals -> failed:would-remove-packages" "$(st)" "failed:would-remove-packages"
[ ! -e "$CS/apt.calls" ] && ok "setup: nothing installed when removals were simulated" || nok "setup: installed despite removals"
csconf turing-plus; eq "setup: unsatisfiable set (rc 1)" "$(STUB_APT=unsat cs run)" 1
eq "setup: unsat -> failed:not-installable" "$(st)" "failed:not-installable"
csconf turing-plus; eq "setup: index unavailable -> retryable (rc 75)" "$(STUB_APT=noindex cs run)" 75
eq "setup: index unavailable -> pending" "$(st)" "pending:index-unavailable"
csconf turing-plus; eq "setup: download failure -> retryable (rc 75)" "$(STUB_APT=fetchfail cs run)" 75
eq "setup: download failure -> pending:download" "$(st)" "pending:download"
csconf turing-plus; eq "setup: install that yields no nvcc (rc 1)" "$(STUB_APT=nonvcc cs run)" 1
eq "setup: no nvcc -> failed:nvcc-missing" "$(st)" "failed:nvcc-missing"
[ ! -e "$CS/var/lib/ncz/cuda-setup.done" ] && ok "setup: no stamp after a failure" || nok "setup: stamp after failure"
# parked after repeated hard failures until an explicit retry
csconf turing-plus; echo "5 0" > "$CS/var/lib/ncz/cuda-setup.attempts"; echo "failed:not-installable" > "$CS/var/lib/ncz/cuda-toolkit.status"
eq "setup: scheduled run is parked after 5 hard failures (rc 0, no apt)" "$(STUB_APT=ok cs run --scheduled)" 0
[ ! -e "$CS/apt.calls" ] && ok "setup: parked run did not call apt" || nok "setup: parked run called apt"
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
    ( . "$W/chooser.sh"; printf '%s' "$COMPONENTS" )
}
mkpci "$W/pci1" 0x8086 0x030000 0x10de 0x030000
case "$(chooser_components "$W/pci1")" in *"|cuda:"*) ok "chooser: cuda offered when an NVIDIA GPU is present";; *) nok "chooser: cuda not offered with an NVIDIA GPU";; esac
mkpci "$W/pci2" 0x8086 0x030000 0x1002 0x030000
case "$(chooser_components "$W/pci2")" in *cuda*) nok "chooser: cuda offered without an NVIDIA GPU";; *) ok "chooser: cuda hidden without an NVIDIA GPU";; esac
mkpci "$W/pci3" 0x10de 0x040300
case "$(chooser_components "$W/pci3")" in *cuda*) nok "chooser: cuda offered for an NVIDIA audio function only";; *) ok "chooser: cuda hidden for an NVIDIA audio-only function";; esac
mkpci "$W/pci4" 0x10de 0x030200
case "$(chooser_components "$W/pci4")" in *"|cuda:"*) ok "chooser: cuda offered for an NVIDIA 3D controller (0302)";; *) nok "chooser: 3D controller not offered";; esac
grep -q '^INTERNAL_COMPONENTS=.*cuda' "$ROOT/preseed/component-selector.sh" && ok "chooser: cuda is a valid ncz_components= token even when hidden" || nok "chooser: cuda not a valid token"
grep -q 'cuda-selection\|COMPONENTS_\$_bit\|for _bit in .* cuda' "$ROOT/preseed/component-selector.sh" && ok "chooser: writes COMPONENTS_cuda for 54-gpu-accel.sh" || nok "chooser: COMPONENTS_cuda not written"

echo "----"
echo "PASS=$PASS FAIL=$FAILS"
exit "$FAILS"
