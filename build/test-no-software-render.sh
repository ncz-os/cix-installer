#!/bin/bash
# Fixture tests for the never-software-render policy, both directions:
#   ncz-gpu-hw-present, ncz-gpu-status --require-hardware, the ncz-gpu-env software branch (from 20-desktop.sh),
#   the labwc-session overlay patch guard, and build/lint-no-software-render.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
expect() { local n="$1" want="$2"; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc = 0 ]; } || { [ "$want" != 0 ] && [ $rc != 0 ]; }; then PASS=$((PASS+1)); echo "ok   $n"
    else FAILS=$((FAILS+1)); echo "FAIL $n (rc=$rc, wanted $want)"; sed 's/^/     /' "$T/out"; fi; }
HWP="$ROOT/assets/gpu/ncz-gpu-hw-present"; ST="$ROOT/assets/gpu/ncz-gpu-status"

# ---- fake sysroots
mkroot() { rm -rf "$T/$1"; mkdir -p "$T/$1/sys/class/drm" "$T/$1/sys/bus/platform/devices" "$T/$1/dev" "$T/$1/proc" "$T/$1/etc"; : > "$T/$1/proc/modules"; }
render_node() { mkdir -p "$T/$1/sys/class/drm/$2/device" "$T/$1/sys/drivers/$3"; ln -s "$T/$1/sys/drivers/$3" "$T/$1/sys/class/drm/$2/device/driver"; }
mkroot amd;   render_node amd renderD128 amdgpu
mkroot virt;  render_node virt renderD128 virtio_gpu
mkroot sky1d; render_node sky1d renderD128 linlondp                      # display controller only
mkroot mali;  render_node mali renderD128 linlondp; : > "$T/mali/dev/mali0"
mkroot cixgpu; mkdir -p "$T/cixgpu/sys/bus/platform/devices/CIXH5000:00"  # GPU device present, driver unbound
mkroot none
hwp() { NCZ_SYSROOT="$T/$1" sh "$HWP"; }
expect "hw-present: amdgpu render node is a GPU"            0 hwp amd
expect "hw-present: /dev/mali0 is a GPU"                    0 hwp mali
expect "hw-present: unbound CIXH5000 is still a GPU"        0 hwp cixgpu
expect "hw-present: virtio_gpu is not a GPU"                1 hwp virt
expect "hw-present: linlondp display controller is not"     1 hwp sky1d
expect "hw-present: empty machine has no GPU"               1 hwp none

# ---- ncz-gpu-status --require-hardware
st() {   # sysroot [VAR=val ...] -- run the check with stub probes; probe stubs come from EGL_S / EGL_B / VK_*
    local root=$1; shift
    env -i PATH="$PATH" NCZ_SYSROOT="$T/$root" NCZ_GPU_HW_PRESENT="$HWP" NCZ_GPU_HEALTH_LOG="$T/health.log" NCZ_GPU_BANNER="$T/banner" \
        NCZ_PROBE_EGL_SESSION="${EGL_S:-echo renderer: Mali-G720}" NCZ_PROBE_EGL_BARE="${EGL_B:-echo renderer: Mali-G720}" \
        NCZ_PROBE_VK_SESSION="${VK_S:-echo deviceName: Mali-G720}" NCZ_PROBE_VK_BARE="${VK_B:-echo deviceName: Mali-G720}" "$@" sh "$ST" --require-hardware
}
rm -f "$T/health.log" "$T/banner"
expect "status: hardware GPU + hardware renderers passes"             0 st amd
grep -q 'OK hardware GPU' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: health log records OK"; } || { FAILS=$((FAILS+1)); echo "FAIL status: health log has no OK line"; }
EGL_B='echo "renderer: llvmpipe (LLVM 21.1.8, 128 bits)"' expect "status: GPU + llvmpipe in the BARE env FAILS"      1 st amd
grep -q 'EGL (bare environment) renders in SOFTWARE' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: log names the bare-env EGL probe"; } || { FAILS=$((FAILS+1)); echo "FAIL status: log does not name the bare-env probe"; }
[ -s "$T/banner" ] && { PASS=$((PASS+1)); echo "ok   status: failure writes the console banner"; } || { FAILS=$((FAILS+1)); echo "FAIL status: no banner written"; }
EGL_S='echo renderer: softpipe' expect "status: GPU + softpipe in the SESSION env FAILS"           1 st amd
VK_B='echo deviceName: llvmpipe' expect "status: GPU + lavapipe/llvmpipe Vulkan FAILS"              1 st amd
expect "status: GPU + LIBGL_ALWAYS_SOFTWARE=1 FAILS"                  1 st amd LIBGL_ALWAYS_SOFTWARE=1
expect "status: GPU + WLR_RENDERER=pixman FAILS"                      1 st amd WLR_RENDERER=pixman
expect "status: GPU + GSK_RENDERER=cairo FAILS"                       1 st amd GSK_RENDERER=cairo
expect "status: GPU + GALLIUM_DRIVER=llvmpipe FAILS"                  1 st amd GALLIUM_DRIVER=llvmpipe
expect "status: LIBGL_ALWAYS_SOFTWARE=0 is not software"              0 st amd LIBGL_ALWAYS_SOFTWARE=0
mkdir -p "$T/amd/etc/environment.d"; echo 'LIBGL_ALWAYS_SOFTWARE=1' > "$T/amd/etc/environment.d/90-x.conf"
expect "status: GPU + software forced in /etc/environment.d FAILS"    1 st amd
rm -f "$T/amd/etc/environment.d/90-x.conf"
# ---- EGL is scanned per platform (regression: O6N 2026-10-04 false positive).
#      Mesa's Surfaceless/Device platforms always come up llvmpipe on Sky1 and no
#      session uses them; a software renderer on gbm/wayland/x11 must still fail.
cat > "$T/egl_mali_unused_soft.txt" <<'EOF'
MESA: error: ZINK: failed to choose pdev
GBM platform:
EGL vendor string: ARM
OpenGL ES profile renderer: Mali-G720-Immortalis

Wayland platform:
EGL vendor string: ARM
OpenGL ES profile renderer: Mali-G720-Immortalis

X11 platform:
eglinfo: eglInitialize failed

Surfaceless platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 128 bits)

Device platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 128 bits)

Platform Device platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 128 bits)
EOF
EGL_S="cat $T/egl_mali_unused_soft.txt" EGL_B="cat $T/egl_mali_unused_soft.txt" expect "status: Mali gbm/wayland + Surfaceless/Device llvmpipe PASSES" 0 st amd
grep -q 'IGNORED surfaceless platform software renderer' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: log says why the Surfaceless block was ignored"; } || { FAILS=$((FAILS+1)); echo "FAIL status: Surfaceless block ignore not logged"; }
grep -q 'IGNORED device platform software renderer' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: log says why the Device block was ignored"; } || { FAILS=$((FAILS+1)); echo "FAIL status: Device block ignore not logged"; }
grep -q 'IGNORED platform device platform software renderer' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: log says why the Platform Device block was ignored"; } || { FAILS=$((FAILS+1)); echo "FAIL status: Platform Device ignore not logged"; }

cat > "$T/egl_gbm_soft.txt" <<'EOF'
GBM platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 128 bits)

Wayland platform:
EGL vendor string: ARM
OpenGL ES profile renderer: Mali-G720-Immortalis
EOF
EGL_S="cat $T/egl_gbm_soft.txt" EGL_B="cat $T/egl_gbm_soft.txt" expect "status: llvmpipe on the GBM platform FAILS (policy kept)" 1 st amd
grep -q 'EGL (session environment) renders in SOFTWARE (gbm platform)' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: the gbm failure names the platform"; } || { FAILS=$((FAILS+1)); echo "FAIL status: gbm failure not attributed to its platform"; }

cat > "$T/egl_wayland_soft.txt" <<'EOF'
GBM platform:
EGL vendor string: ARM
OpenGL ES profile renderer: Mali-G720-Immortalis

Wayland platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 128 bits)
EOF
EGL_S="cat $T/egl_wayland_soft.txt" EGL_B="cat $T/egl_wayland_soft.txt" expect "status: llvmpipe on the Wayland platform FAILS (policy kept)" 1 st amd

# ---- Enumerated-but-unused llvmpipe must not fail (regression: GU502LV 2026-10-04,
#      Intel UHD + RTX 2060 + mesa-vulkan-drivers). Clients get the FIRST Vulkan
#      device the loader lists and the GBM/Wayland/X11 EGL renderer; the Device
#      platform enumeration is not a session platform. Fixtures (a)-(d) below.
#      (a) real GPU first, llvmpipe listed later -> PASS
cat > "$T/vk_gpu_first.txt" <<'EOF'
deviceName         = NVIDIA GeForce RTX 2060
driverName         = NVIDIA
deviceName         = llvmpipe (LLVM 21.1.8, 256 bits)
driverName         = llvmpipe
EOF
EGL_S='echo renderer: Mesa Intel(R) UHD Graphics (CML GT2)' EGL_B='echo renderer: Mesa Intel(R) UHD Graphics (CML GT2)' \
    VK_S="cat $T/vk_gpu_first.txt" VK_B="cat $T/vk_gpu_first.txt" \
    expect "status: (a) Vulkan GPU first + llvmpipe later PASSES" 0 st amd
#      (b) llvmpipe first and a GPU listed later -> FAIL
cat > "$T/vk_soft_first.txt" <<'EOF'
deviceName         = llvmpipe (LLVM 21.1.8, 256 bits)
driverName         = llvmpipe
deviceName         = NVIDIA GeForce RTX 2060
driverName         = NVIDIA
EOF
VK_S="cat $T/vk_soft_first.txt" VK_B="cat $T/vk_soft_first.txt" \
    expect "status: (b) Vulkan llvmpipe first + GPU later FAILS" 1 st amd
grep -q 'first Vulkan device renders in SOFTWARE' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: (b) failure is attributed to the first Vulkan device"; } || { FAILS=$((FAILS+1)); echo "FAIL status: (b) no first-device reason in the log"; }
#      (b) EGL llvmpipe on the default GBM block, a GPU on Wayland later -> FAIL
cat > "$T/egl_soft_first.txt" <<'EOF'
GBM platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 256 bits)

Wayland platform:
EGL vendor string: NVIDIA
OpenGL ES profile renderer: NVIDIA GeForce RTX 2060/PCIe/SSE2
EOF
EGL_S="cat $T/egl_soft_first.txt" EGL_B="cat $T/egl_soft_first.txt" \
    expect "status: (b) EGL llvmpipe GBM + later GPU Wayland FAILS" 1 st amd
#      (c) llvmpipe only -> FAIL (Vulkan and a headerless EGL probe)
cat > "$T/vk_soft_only.txt" <<'EOF'
deviceName         = llvmpipe (LLVM 21.1.8, 256 bits)
driverName         = llvmpipe
EOF
VK_S="cat $T/vk_soft_only.txt" VK_B="cat $T/vk_soft_only.txt" \
    expect "status: (c) Vulkan llvmpipe only FAILS" 1 st amd
EGL_S='echo "renderer: llvmpipe (LLVM 21.1.8, 256 bits)"' EGL_B='echo "renderer: llvmpipe (LLVM 21.1.8, 256 bits)"' \
    expect "status: (c) EGL llvmpipe only FAILS" 1 st amd
#      (d) the GU502LV enumeration captured 2026-10-04: GBM/Wayland on Mesa Intel,
#          Surfaceless/Device on the RTX 2060, the Device #3 node on llvmpipe.
#          Vulkan lists Intel first, then NVIDIA, then llvmpipe -> PASS.
cat > "$T/egl_gu502lv.txt" <<'EOF'
GBM platform:
EGL API version: 1.5
EGL vendor string: Mesa Project
EGL client APIs: OpenGL OpenGL_ES
OpenGL core profile renderer: Mesa Intel(R) UHD Graphics (CML GT2)

Wayland platform:
EGL API version: 1.5
EGL vendor string: Mesa Project
OpenGL core profile renderer: Mesa Intel(R) UHD Graphics (CML GT2)

X11 platform:
eglinfo: eglInitialize failed

Surfaceless platform:
EGL vendor string: NVIDIA
OpenGL core profile renderer: NVIDIA GeForce RTX 2060/PCIe/SSE2

Device platform:
Device #0:

Platform Device platform:
EGL vendor string: NVIDIA
OpenGL core profile renderer: NVIDIA GeForce RTX 2060/PCIe/SSE2

Device #1:

Platform Device platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: Mesa Intel(R) UHD Graphics (CML GT2)

Device #3:

Platform Device platform:
EGL vendor string: Mesa Project
OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 256 bits)
EOF
cat > "$T/vk_gu502lv.txt" <<'EOF'
deviceName         = Intel(R) UHD Graphics (CML GT2)
driverName         = Intel open-source Mesa driver
deviceName         = NVIDIA GeForce RTX 2060
driverName         = NVIDIA
deviceName         = llvmpipe (LLVM 21.1.8, 256 bits)
driverName         = llvmpipe
EOF
: > "$T/health.log"
EGL_S="cat $T/egl_gu502lv.txt" EGL_B="cat $T/egl_gu502lv.txt" \
    VK_S="cat $T/vk_gu502lv.txt" VK_B="cat $T/vk_gu502lv.txt" \
    expect "status: (d) exact GU502LV Intel+NVIDIA+llvmpipe enumeration PASSES" 0 st amd
grep -q 'IGNORED platform device platform software renderer (no session/compositor uses it): OpenGL core profile renderer: llvmpipe (LLVM 21.1.8, 256 bits)' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: (d) GU502LV Device #3 llvmpipe is ignored, not failed"; } || { FAILS=$((FAILS+1)); echo "FAIL status: (d) GU502LV Device #3 llvmpipe not logged as ignored"; }
grep -q 'OK hardware GPU' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: (d) GU502LV run records an OK verdict"; } || { FAILS=$((FAILS+1)); echo "FAIL status: (d) GU502LV run has no OK line"; }
#      forced software in the new variable forms still FAILS
expect "status: GPU + LP_NUM_THREADS=4 (llvmpipe) FAILS"           1 st amd LP_NUM_THREADS=4
expect "status: GPU + VK_ICD_FILENAMES=lvp ICD FAILS"              1 st amd VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
expect "status: GPU + EGL_PLATFORM=surfaceless FAILS"              1 st amd EGL_PLATFORM=surfaceless
expect "status: GPU + EGL_PLATFORM=device FAILS"                   1 st amd EGL_PLATFORM=device

# no GPU: software is allowed, in every form
rm -f "$T/banner"
EGL_S='echo renderer: llvmpipe' EGL_B='echo renderer: llvmpipe' expect "status: NO GPU + llvmpipe passes (software allowed)"  0 st none
grep -q 'no GPU: software allowed' "$T/health.log" && { PASS=$((PASS+1)); echo "ok   status: log says 'no GPU: software allowed'"; } || { FAILS=$((FAILS+1)); echo "FAIL status: missing 'no GPU: software allowed'"; }
expect "status: NO GPU + LIBGL_ALWAYS_SOFTWARE=1 passes"              0 st none LIBGL_ALWAYS_SOFTWARE=1
expect "status: virtio_gpu-only VM + software passes"                 0 st virt LIBGL_ALWAYS_SOFTWARE=1 WLR_RENDERER=pixman
expect "status: display-controller-only board + software passes"      0 st sky1d LIBGL_ALWAYS_SOFTWARE=1
noprobe() { env -i PATH="$PATH" NCZ_SYSROOT="$T/amd" NCZ_GPU_HW_PRESENT="$T/does-not-exist" NCZ_GPU_HEALTH_LOG="$T/health.log" sh "$ST" --require-hardware; }
expect "status: missing ncz-gpu-hw-present is an ERROR, not a pass"   1 noprobe

# ---- ncz-gpu-env software branch, extracted from 20-desktop.sh
awk '/cat > \/usr\/local\/bin\/ncz-gpu-env <<.GPUENV./{f=1;next} /^GPUENV$/{f=0} f' "$ROOT/post-install/20-desktop.sh" > "$T/ncz-gpu-env"
[ -s "$T/ncz-gpu-env" ] && { PASS=$((PASS+1)); echo "ok   ncz-gpu-env extracted from 20-desktop.sh"; } || { FAILS=$((FAILS+1)); echo "FAIL could not extract ncz-gpu-env"; }
mkdir -p "$T/stub"; printf '#!/bin/sh\nexit 0\n' > "$T/stub/hw-yes"; printf '#!/bin/sh\nexit 1\n' > "$T/stub/hw-no"; chmod +x "$T/stub/"*
envrun() {   # sysroot hwstub [VAR=val ...] -> prints NCZ_GPU_BACKEND and LIBGL_ALWAYS_SOFTWARE after sourcing
    local root=$1 stub=$2; shift 2
    env -i PATH="$PATH" NCZ_SYSROOT="$T/$root" NCZ_GPU_HW_PRESENT_CMD="$T/stub/$stub" NCZ_GPU_HEALTH_LOG="$T/env-health.log" NCZ_GPU_ENV_NO_IMPORT=1 "$@" \
        sh -c ". '$T/ncz-gpu-env' 2>/dev/null; echo backend=\${NCZ_GPU_BACKEND:-} sw=\${LIBGL_ALWAYS_SOFTWARE:-} pixman=\${WLR_RENDERER:-}"
}
r=$(envrun none hw-no);  case "$r" in *"backend=software sw=1 pixman=pixman"*) PASS=$((PASS+1)); echo "ok   env: no GPU -> software branch (KVM keeps working)";; *) FAILS=$((FAILS+1)); echo "FAIL env: no GPU gave: $r";; esac
r=$(envrun none hw-yes); case "$r" in *"backend=failed sw= pixman="*) PASS=$((PASS+1)); echo "ok   env: GPU + no usable stack -> REFUSED, no software variables";; *) FAILS=$((FAILS+1)); echo "FAIL env: GPU present gave: $r";; esac
grep -q 'software rendering REFUSED' "$T/env-health.log" 2>/dev/null && { PASS=$((PASS+1)); echo "ok   env: refusal is written to the health log"; } || { FAILS=$((FAILS+1)); echo "FAIL env: refusal not in the health log"; }
r=$(envrun none hw-yes NCZ_ALLOW_SOFTWARE_FALLBACK=1); case "$r" in *"backend=software sw=1"*) PASS=$((PASS+1)); echo "ok   env: NCZ_ALLOW_SOFTWARE_FALLBACK=1 opts back in";; *) FAILS=$((FAILS+1)); echo "FAIL env: opt-in gave: $r";; esac
mkdir -p "$T/mali2/dev" "$T/mali2/proc"; : > "$T/mali2/dev/mali0"; echo 'mali_kbase 1 0 - Live 0x0' > "$T/mali2/proc/modules"
r=$(envrun mali2 hw-yes); case "$r" in *"backend=mali sw="*) PASS=$((PASS+1)); echo "ok   env: a live Mali stack selects mali (no software)";; *) FAILS=$((FAILS+1)); echo "FAIL env: mali gave: $r";; esac

# ---- labwc-session overlay patch: extract hw_render_device_present and run it against the same sysroots
PATCH="$ROOT/assets/singularity/patches/singularity-session/0001-session-no-software-fallback-with-gpu.patch"
if [ -f "$PATCH" ]; then
    sed -n '/^+hw_render_device_present() {/,/^+}/p' "$PATCH" | sed 's/^+//' > "$T/hwfn.sh"
    [ -s "$T/hwfn.sh" ] && { PASS=$((PASS+1)); echo "ok   session patch: guard function present"; } || { FAILS=$((FAILS+1)); echo "FAIL session patch has no hw_render_device_present"; }
    # the function reads /dev and /sys directly: rewrite the roots for the fixture
    sed "s#/dev/mali0#\$R/dev/mali0#; s#/sys/class/drm#\$R/sys/class/drm#" "$T/hwfn.sh" > "$T/hwfn-root.sh"
    guard() { R="$T/$1" sh -c ". '$T/hwfn-root.sh'; hw_render_device_present"; }
    expect "session guard: amdgpu -> refuse software"        0 guard amd
    expect "session guard: mali -> refuse software"          0 guard mali
    expect "session guard: virtio_gpu VM -> software allowed" 1 guard virt
    expect "session guard: display-only board -> allowed"    1 guard sky1d
    expect "session guard: empty machine -> allowed"         1 guard none
    grep -q 'NCZ_ALLOW_SOFTWARE_FALLBACK' "$PATCH" && { PASS=$((PASS+1)); echo "ok   session patch: opt-in variable present"; } || { FAILS=$((FAILS+1)); echo "FAIL session patch lacks the opt-in"; }
else
    FAILS=$((FAILS+1)); echo "FAIL session overlay patch missing: $PATCH"
fi

# ---- switcher: EGL vendor link only while Mali is selected
sw_src() { sed -n '/^EGL_SRC=/,/^egl_vendor_off/p' "$ROOT/assets/gpu/ncz-gpu-switcher.sh"; }
mkdir -p "$T/opt"; echo '{}' > "$T/opt/40_cix.json"
egl() { NCZ_EGL_VENDOR_SRC="$T/opt/40_cix.json" NCZ_EGL_VENDOR_LINK="$T/etc-glvnd/10_cix.json" sh -c "log() { :; }; $(sw_src); $1"; }
expect "switcher: mali registers the 10_cix vendor"         0 egl 'egl_vendor_on; test -L "$NCZ_EGL_VENDOR_LINK"'
expect "switcher: panthor removes the 10_cix vendor"        0 egl 'egl_vendor_on; egl_vendor_off; test ! -e "$NCZ_EGL_VENDOR_LINK"'
grep -q 'egl_vendor_on$' "$ROOT/assets/gpu/ncz-gpu-switcher.sh" && grep -q 'egl_vendor_off$' "$ROOT/assets/gpu/ncz-gpu-switcher.sh" && { PASS=$((PASS+1)); echo "ok   switcher: userspace_mali/userspace_panthor call them"; } || { FAILS=$((FAILS+1)); echo "FAIL switcher does not wire the EGL vendor"; }

# ---- lint both directions
mkdir -p "$T/lint/build" "$T/lint/post-install"
lint() { LINT_ROOT="$T/lint" LINT_ALLOWLIST="$T/lint/allow.tsv" LINT_FILES="$1" bash "$ROOT/build/lint-no-software-render.sh"; }
echo 'export LIBGL_ALWAYS_SOFTWARE=1' > "$T/lint/post-install/50-bad.sh"; : > "$T/lint/allow.tsv"
expect "lint: LIBGL_ALWAYS_SOFTWARE=1 is denied"           1 lint post-install/50-bad.sh
echo 'WLR_RENDERER=pixman' > "$T/lint/post-install/51-bad.sh"
expect "lint: WLR_RENDERER=pixman is denied"               1 lint post-install/51-bad.sh
echo 'chromium --disable-gpu' > "$T/lint/post-install/52-bad.sh"
expect "lint: --disable-gpu is denied"                     1 lint post-install/52-bad.sh
echo 'mpv --hwdec=no' > "$T/lint/post-install/53-bad.sh"
expect "lint: hwdec=no is denied"                          1 lint post-install/53-bad.sh
printf 'post-install/50-bad.sh\tguarded by ncz-gpu-hw-present\n' > "$T/lint/allow.tsv"
expect "lint: an allowlisted file with a reason passes"    0 lint post-install/50-bad.sh
echo '# LIBGL_ALWAYS_SOFTWARE=1 is what we removed' > "$T/lint/post-install/54-ok.sh"; echo 'unset LIBGL_ALWAYS_SOFTWARE' >> "$T/lint/post-install/54-ok.sh"
expect "lint: comments and unset lines are fine"           0 lint post-install/54-ok.sh
expect "lint: the real tree passes"                        0 bash "$ROOT/build/lint-no-software-render.sh"
echo "no-software-render tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
