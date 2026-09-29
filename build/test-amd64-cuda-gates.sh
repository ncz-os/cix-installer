#!/bin/bash
# test-amd64-cuda-gates.sh -- positive AND negative tests for the AMD64 CUDA 13.4
# gates: the Turing+ hardware gate, the mirror-closure gate, the installed-target
# gate, and the toolkit install step of post-install/54-gpu-accel.sh (run under
# stubbed apt-get/dpkg with its absolute paths redirected into a scratch root).
#
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
expect_rc() {   # expect_rc WANT DESC cmd...
    local want="$1" desc="$2"; shift 2
    "$@" >"$W/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" != 0 ] && [ $rc -ne 0 ]; }; then ok "$desc"
    else nok "$desc (rc=$rc)"; sed 's/^/     /' "$W/out" | tail -5; fi
}

# ---------------------------------------------------------------- Turing+ gate
# shellcheck source=../post-install/lib/hw-detect.sh
. "$ROOT/post-install/lib/hw-detect.sh"
lsp() { printf '%s\n' "$1" > "$W/lspci"; nvidia_turing_plus_present "$W/lspci"; }
IGPU='00:02.0 VGA compatible controller [0300]: Intel Corporation CometLake-S GT2 [UHD Graphics 630] [8086:9bc4]'
expect_rc 0 "turing: RTX 2060 (10de:1f08) + iGPU"   lsp "$IGPU
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU106 [GeForce RTX 2060] [10de:1f08] (rev a1)"
expect_rc 0 "turing: first Turing id 10de:1e02 as 3D controller [0302]" lsp "01:00.0 3D controller [0302]: NVIDIA Corporation TU102 [10de:1e02]"
expect_rc 0 "ada: RTX 4090 (10de:2684)"              lsp "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [10de:2684]"
expect_rc 0 "boundary: 10de:1e00 counts"             lsp "01:00.0 VGA compatible controller [0300]: NVIDIA [10de:1e00]"
expect_rc 1 "pascal: GTX 1060 (10de:1c03) rejected"  lsp "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP106 [10de:1c03]"
expect_rc 1 "volta: TITAN V (10de:1d81) rejected"    lsp "01:00.0 3D controller [0302]: NVIDIA Corporation GV100 [10de:1d81]"
expect_rc 1 "boundary: 10de:1dff rejected"           lsp "01:00.0 VGA compatible controller [0300]: NVIDIA [10de:1dff]"
expect_rc 1 "maxwell: GTX 970 (10de:13c2) rejected"  lsp "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GM204 [10de:13c2]"
expect_rc 1 "no NVIDIA at all (Intel iGPU only)"     lsp "$IGPU"
expect_rc 1 "HDMI audio function of an NVIDIA card is not a GPU" lsp "01:00.1 Audio device [0403]: NVIDIA Corporation TU106 High Definition Audio [10de:10f9]"
expect_rc 1 "non-display NVIDIA line with a Turing id is ignored" lsp "01:00.2 USB controller [0c03]: NVIDIA Corporation TU106 USB 3.1 [10de:1ada]"
expect_rc 1 "unreadable fixture fails closed"        nvidia_turing_plus_present "$W/does-not-exist"

# ------------------------------------------------------------ mirror-closure gate
mkmirror() {   # mkmirror DIR ; emits a good mirror; callers then break it
    local d="$1" suite="forky"
    rm -rf "$d"; mkdir -p "$d/pool/main" "$d/dists/$suite/main/binary-amd64"
    : > "$d/dists/$suite/main/binary-amd64/Packages"
    addpkg "$d" cuda-nvcc-13-4 13.4.92-1
    addpkg "$d" cuda-compiler-13-4 13.4.2-1
    addpkg "$d" cuda-cudart-dev-13-4 13.4.92-1
    addpkg "$d" cuda-libraries-13-4 13.4.2-1
    addpkg "$d" nvidia-open 615.71.09-2
    addpkg "$d" nvidia-kernel-open-dkms 615.71.09-2
    addpkg "$d" libcuda1 615.71.09-2
    addpkg "$d" nvidia-detect 615.71.09-1
}
addpkg() {     # addpkg DIR PKG VER [nofile]
    local d="$1" p="$2" v="$3" f="pool/main/$2_$3_amd64.deb"
    [ "${4:-}" = nofile ] || : > "$d/$f"
    printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nFilename: %s\n\n' "$p" "$v" "$f" \
        >> "$d/dists/forky/main/binary-amd64/Packages"
}
delpkg() {     # delpkg DIR PKG
    awk -v p="$2" 'BEGIN{RS="";ORS="\n\n";FS="\n"} $1!="Package: "p' "$1/dists/forky/main/binary-amd64/Packages" > "$1/idx.new"
    mv "$1/idx.new" "$1/dists/forky/main/binary-amd64/Packages"
}
GATE="$ROOT/build/verify-cuda-mirror.sh"
M="$W/mirror"
mkmirror "$M";                                  expect_rc 0 "mirror: complete R615 + CUDA 13.4 closure passes" "$GATE" --mirror "$M"
mkmirror "$M"; delpkg "$M" cuda-nvcc-13-4;      expect_rc 1 "mirror: missing nvcc is rejected" "$GATE" --mirror "$M"
mkmirror "$M"; delpkg "$M" nvidia-open; addpkg "$M" nvidia-open 550.163.01-5.1
                                                expect_rc 1 "mirror: Debian's old 550 driver is rejected" "$GATE" --mirror "$M"
mkmirror "$M"; delpkg "$M" cuda-compiler-13-4; addpkg "$M" cuda-compiler-13-4 13.3.1-1
                                                expect_rc 1 "mirror: wrong CUDA branch (13.3) is rejected" "$GATE" --mirror "$M"
mkmirror "$M"; delpkg "$M" libcuda1; rm -f "$M/pool/main/libcuda1_615.71.09-2_amd64.deb"; addpkg "$M" libcuda1 615.71.09-2 nofile
                                                expect_rc 1 "mirror: indexed but .deb missing from pool is rejected" "$GATE" --mirror "$M"
mkmirror "$M"; addpkg "$M" nvidia-kernel-dkms 615.71.09-2
                                                expect_rc 1 "mirror: proprietary nvidia-kernel-dkms is rejected" "$GATE" --mirror "$M"
expect_rc 1 "mirror: nonexistent directory is rejected" "$GATE" --mirror "$W/nope"

# ------------------------------------------------------- installed-target gate
TG="$ROOT/build/verify-cuda-installed-target.sh"
mktarget() {   # mktarget DIR STATUS [withnvcc]
    local d="$1"
    rm -rf "$d"; mkdir -p "$d/var/lib/ncz" "$d/var/lib/dpkg" "$d/etc/profile.d" "$d/etc/apt/preferences.d"
    [ -n "${2:-}" ] && echo "$2" > "$d/var/lib/ncz/cuda-toolkit.status"
    if [ "${3:-}" = withnvcc ]; then
        mkdir -p "$d/usr/local/cuda-13.4/bin"; printf '#!/bin/sh\n' > "$d/usr/local/cuda-13.4/bin/nvcc"; chmod +x "$d/usr/local/cuda-13.4/bin/nvcc"
        : > "$d/etc/profile.d/ncz-cuda.sh"; : > "$d/etc/apt/preferences.d/ncz-nvidia-cuda.pref"
        printf 'Package: cuda-nvcc-13-4\nStatus: install ok installed\nVersion: 13.4.92-1\n\n' > "$d/var/lib/dpkg/status"
    fi
}
T="$W/target"
mktarget "$T" "installed:13.4.92-1" withnvcc; expect_rc 0 "target: NVIDIA install with nvcc passes (expect installed)" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" withnvcc; expect_rc 0 "target: auto derives installed" "$TG" --root "$T"
mktarget "$T" "installed:13.4.92-1";          expect_rc 1 "target: status installed but nvcc missing is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" withnvcc; rm "$T/etc/apt/preferences.d/ncz-nvidia-cuda.pref"
                                              expect_rc 1 "target: missing R615 pin is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "installed:13.4.92-1" withnvcc; : > "$T/var/lib/dpkg/status"
                                              expect_rc 1 "target: dpkg does not list cuda-nvcc-13-4 is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "skipped:no-nvidia-gpu";        expect_rc 0 "target: non-NVIDIA skip is logged and passes (expect skipped)" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped:no-nvidia-gpu";        expect_rc 0 "target: auto derives skipped" "$TG" --root "$T"
mktarget "$T" "skipped:no-turing-plus-gpu";   expect_rc 1 "target: skip when installed was expected is rejected" "$TG" --root "$T" --expect installed
mktarget "$T" "skipped:no-nvidia-gpu" withnvcc; expect_rc 1 "target: skipped but nvcc exists is rejected" "$TG" --root "$T" --expect skipped
mktarget "$T" "skipped:";                     expect_rc 1 "target: skip without a reason is rejected" "$TG" --root "$T" --expect skipped
mktarget "$T" "failed:not-installable";       expect_rc 1 "target: recorded failure is always rejected (auto)" "$TG" --root "$T"
mktarget "$T" "failed:not-installable";       expect_rc 1 "target: recorded failure is rejected (expect skipped)" "$TG" --root "$T" --expect skipped
mktarget "$T" "";                             expect_rc 1 "target: no status file is rejected (silent hook)" "$TG" --root "$T"
mktarget "$T" "bogus";                        expect_rc 1 "target: unrecognized status is rejected" "$TG" --root "$T"

# ------------------------------------------- 54-gpu-accel.sh toolkit step, stubbed
# Extract the CUDA function block from the real hook and redirect its absolute
# paths into a scratch root, so the tested code IS the shipped code.
SB="$W/sb"; mkdir -p "$SB/bin"
extract() {
    awk '/^# --- CUDA 13.4 toolkit \(NVIDIA route only\)/{f=1} /^echo "\[54\] AMD64 GPU\/accelerator vendor detection/{f=0} f' \
        "$ROOT/post-install/54-gpu-accel.sh" \
      | sed -e "s#/var/lib/ncz#$SB/var/lib/ncz#g" -e "s#/etc/profile.d#$SB/etc/profile.d#g" \
            -e "s#/usr/local/cuda-13.4#$SB/usr/local/cuda-13.4#g" -e "s#/usr/local/cuda/#$SB/usr/local/cuda/#g" \
            -e "s#/var/log/ncz-cuda-install.log#$SB/install.log#g"
}
extract > "$SB/func.sh"
[ -s "$SB/func.sh" ] && ok "54: CUDA function block extracted from the real hook" || nok "54: could not extract the CUDA block"
cat > "$SB/bin/apt-get" <<EOF
#!/bin/bash
# stub: behavior chosen by \$STUB_APT
case "\$*" in
  *" -s "*|"-s "*|*install\ -s*)
     case "\${STUB_APT:-ok}" in
        unsat)  echo "E: Unable to satisfy dependencies" >&2; exit 100 ;;
        remove) echo "Remv libfoo [1.0]"; exit 0 ;;
        *)      echo "Inst cuda-nvcc-13-4 (13.4.92-1 NVIDIA)"; exit 0 ;;
     esac ;;
  *) case "\${STUB_APT:-ok}" in
        nonvcc) exit 0 ;;
        *) mkdir -p "$SB/usr/local/cuda-13.4/bin"; printf '#!/bin/sh\necho "Cuda compilation tools, release 13.4"\n' > "$SB/usr/local/cuda-13.4/bin/nvcc"; chmod +x "$SB/usr/local/cuda-13.4/bin/nvcc"; exit 0 ;;
     esac ;;
esac
EOF
cat > "$SB/bin/dpkg" <<'EOF'
#!/bin/bash
[ "${STUB_APT:-ok}" = nonvcc ] && exit 1
exit 0
EOF
cat > "$SB/bin/dpkg-query" <<'EOF'
#!/bin/bash
printf '13.4.92-1'
EOF
cat > "$SB/bin/ldconfig" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SB/bin/"*
run54() {   # run54 <lspci fixture text or ""> <STUB_APT> [NCZ_SKIP_CUDA]
    rm -rf "$SB/var" "$SB/etc" "$SB/usr"
    printf '%s\n' "$1" > "$SB/lspci"
    (   export PATH="$SB/bin:$PATH" STUB_APT="$2" NCZ_SKIP_CUDA="${3:-0}"
        . "$ROOT/post-install/lib/hw-detect.sh"
        lspci() { cat "$SB/lspci"; }
        # shellcheck disable=SC1090
        . "$SB/func.sh"
        ncz_cuda_toolkit_install ) > "$SB/log" 2>&1
    head -n1 "$SB/var/lib/ncz/cuda-toolkit.status" 2>/dev/null
}
RTX='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU106 [GeForce RTX 2060] [10de:1f08]'
got="$(run54 "$RTX" ok)";                                case "$got" in installed:13.4.92-1) ok "54: Turing+ GPU installs the toolkit ($got)";; *) nok "54: expected installed, got '$got'"; cat "$SB/log";; esac
[ -f "$SB/etc/profile.d/ncz-cuda.sh" ] && ok "54: PATH profile.d snippet written" || nok "54: profile.d snippet missing"
got="$(run54 "$RTX" ok 1)";                              [ "$got" = "skipped:operator-disabled" ] && ok "54: NCZ_SKIP_CUDA=1 skips ($got)" || nok "54: NCZ_SKIP_CUDA got '$got'"
got="$(run54 '01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP106 [10de:1c03]' ok)"
                                                          [ "$got" = "skipped:no-turing-plus-gpu" ] && ok "54: Pascal GPU is skipped and logged ($got)" || nok "54: Pascal got '$got'"
[ ! -e "$SB/usr/local/cuda-13.4/bin/nvcc" ] && ok "54: skip path installed nothing" || nok "54: skip path still ran apt install"
got="$(run54 "$RTX" unsat)";                             [ "$got" = "failed:not-installable" ] && ok "54: unsatisfiable set is a logged failure ($got)" || nok "54: unsat got '$got'"
grep -q 'ERROR: CUDA toolkit set is not installable' "$SB/log" && ok "54: failure is logged loudly" || nok "54: failure not logged"
got="$(run54 "$RTX" remove)";                            [ "$got" = "failed:would-remove-packages" ] && ok "54: any removal is refused ($got)" || nok "54: removal got '$got'"
got="$(run54 "$RTX" nonvcc)";                            [ "$got" = "failed:nvcc-missing" ] && ok "54: install that yields no nvcc is a failure ($got)" || nok "54: nonvcc got '$got'"
# failure must not abort the caller: the function returns 0 in every case above
(   export PATH="$SB/bin:$PATH" STUB_APT=unsat
    . "$ROOT/post-install/lib/hw-detect.sh"
    lspci() { cat "$SB/lspci"; }
    . "$SB/func.sh" >/dev/null 2>&1
    ncz_cuda_toolkit_install >/dev/null 2>&1 ) \
    && ok "54: a toolkit failure returns 0 (does not abort post-install)" || nok "54: toolkit failure returned non-zero"

# 54 and the pin file agree with the manifest
grep -q '^cuda-compiler-13-4$' "$ROOT/manifests/nvidia-cuda-amd64.pkgs" && \
grep -q '^cuda-cudart-dev-13-4$' "$ROOT/manifests/nvidia-cuda-amd64.pkgs" && \
grep -q '^cuda-libraries-13-4$' "$ROOT/manifests/nvidia-cuda-amd64.pkgs" \
    && ok "manifest lists the slim CUDA 13.4 set" || nok "manifest is missing part of the CUDA set"
pk="$(sed -n 's/^NCZ_CUDA_PKGS="\(.*\)"$/\1/p' "$ROOT/post-install/54-gpu-accel.sh")"
miss=""; for p in $pk; do grep -q "^$p\$" "$ROOT/manifests/nvidia-cuda-amd64.pkgs" || miss="$miss $p"; done
[ -z "$miss" ] && ok "54 NCZ_CUDA_PKGS are all seeded in the mirror manifest" || nok "54 installs packages the mirror does not carry:$miss"
grep -q 'Pin: version 615\.\*' "$ROOT/assets/nvidia/ncz-nvidia-cuda.pref" && ok "pin keeps the driver on 615.*" || nok "pin file does not pin 615.*"

echo "----"
echo "PASS=$PASS FAIL=$FAILS"
exit "$FAILS"
