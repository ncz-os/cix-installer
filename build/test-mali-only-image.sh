#!/bin/bash
# test-mali-only-image.sh -- one GPU driver (vendor Mali) on desktop and server, operator 2026-11-14.
# Panthor is not a bootable option, is not built or registered by default, and the vendor Mali userland has
# the libraries it needs on every variant. Revisit Panthor after Linux 7.4 ships.
set -u
cd "$(dirname "$0")/.."
fail=0; bad() { echo "FAIL: $*"; fail=1; }; ok() { echo "ok:   $*"; }
g=assets/refind/ncz-refind-refresh.sh
if grep -Eq '^[[:space:]]*echo "menuentry.*[Pp]anthor' "$g"; then bad "generator still generates a Panthor entry (operator 2026-11-16)"; else ok "generator has no Panthor entry"; fi
if grep -Eq '^[[:space:]]*[^#]*sky1\.gpu=mesa' "$g"; then bad "generator still emits sky1.gpu=mesa (operator 2026-11-16)"; else ok "generator emits no sky1.gpu=mesa"; fi
if grep -Eq 'ncz_panthor_module_present\(\)' "$g" || grep -Eq 'ncz_panthor_module_present "\$KVER_NEXT"' "$g"; then bad "generator still gates a Panthor entry on a module"; else ok "no module-gated Panthor entry"; fi
for f in build/build-dkms-debs.sh build/build-accel-overlays.sh; do
    grep -q 'DRIVERS=(mali vpu npu)' $f && ok "$f default drivers exclude panthor" || bad "$f still builds panthor by default"
done
grep -q 'panthor-cix not shipped' post-install/83-panthor-gpu.sh && ok "hook 83 does not register panthor-cix" || bad "hook 83 registers panthor-cix"
awk '/panthor-cix not shipped/{f=1} f&&/^exit 0/{print "exit-before-dkms"; exit}' post-install/83-panthor-gpu.sh | grep -q exit-before-dkms && ok "hook 83 exits before the DKMS section" || bad "hook 83 does not exit before DKMS"
grep -q 'apt-get install -y --no-install-recommends libwayland-server0' post-install/82-mali-gpu.sh && ok "hook 82 installs libwayland-server0 (libmali dependency) on arm64" || bad "hook 82 lacks libwayland-server0"
grep -q 'apt-mark manual libwayland-server0' post-install/82-mali-gpu.sh && ok "libwayland-server0 pinned manual" || bad "libwayland-server0 not pinned"
grep -q 'apt-get install -y --no-install-recommends libpam-systemd' post-install/48-server-variant.sh && ok "hook 48 installs libpam-systemd on servers" || bad "hook 48 lacks libpam-systemd"

# --- NO PANTHOR ANYWHERE (order 01:35Z 2026-11-15, item 1) -------------------
grep -q 'panthor-cix-dkms_\*.deb)' post-install/25-cix-proprietary.sh && ok "hook 25 refuses panthor-cix-dkms" || bad "hook 25 does not skip panthor-cix-dkms"
grep -q 'panthor-cix not shipped' post-install/83-panthor-gpu.sh && ok "hook 83 keeps the panthor purge" || bad "hook 83 lost the panthor purge"
if grep -Eq '^[^#]*dkms add' post-install/83-panthor-gpu.sh; then bad "hook 83 still has a DKMS registration path"; else ok "hook 83 has no DKMS registration path"; fi
grep -q 'panthor-cix-dkms' manifests/ncz-packages.tsv && bad "ledger still carries panthor-cix-dkms" || ok "ledger has no panthor-cix-dkms row"
grep -q 'EXPECTED_DKMS=.*panthor' build/stage-canonical-assets.sh && bad "stage still expects the panthor deb" || ok "stage does not expect the panthor deb"
grep -q 'rm -f "\$ASSETS/cix-debs"/panthor-cix-dkms_' build/stage-canonical-assets.sh && ok "stage removes stale panthor debs" || bad "stage does not remove stale panthor debs"
grep -q 'panthor-cix-dkms_' build/verify-arm64-inputs.sh && bad "verify-arm64-inputs still requires the panthor deb" || ok "verify-arm64-inputs does not require the panthor deb"
python3 - <<'PY'
import re
src = open('build/verify-dkms-deb-sources.py').read()
m = re.search(r'BOM_DKMS_DEBS = \((.*?)\)', src, re.S)
assert m and 'panthor' not in m.group(1), "BOM_DKMS_DEBS still lists panthor"
print("ok   BOM_DKMS_DEBS excludes panthor")
PY
grep -q 'panthor-cix-dkms_' build/test-arm64-gates.sh && bad "arm64 gate fixture still stubs the panthor deb" || ok "arm64 gate fixture has no panthor stub"

# --- Mali GPU compute on desktop AND server (item 2) -------------------------
for f in manifests/desktop.pkgs manifests/install-extra.pkgs; do
    for pkg in ocl-icd-libopencl1 clinfo; do
        grep -q "^$pkg\$" "$f" && ok "$f lists $pkg" || bad "$f lacks $pkg"
    done
done
for pkg in mesa-vulkan-drivers vulkan-tools; do
    grep -q "^$pkg\$" manifests/install-extra.pkgs && ok "install-extra.pkgs lists $pkg" || bad "install-extra.pkgs lacks $pkg"
done
grep -q '^mesa-opencl-icd$' manifests/desktop.pkgs && bad "arm64 desktop still pulls mesa-opencl-icd (rusticl/panfrost path)" || ok "arm64 desktop has no mesa-opencl-icd"
grep -q 'ocl-icd-libopencl1' post-install/47-llm-stack.sh && ok "hook 47 installs ocl-icd-libopencl1 (server runtime)" || bad "hook 47 lacks ocl-icd-libopencl1"
grep -q 'VK_DRIVER_FILES /etc/vulkan/icd.d/mali.json' post-install/16-mesa-gpu-2613.sh && ok "hook 16 pins the blob ICD system-wide" || bad "hook 16 does not pin the blob ICD"
grep -q 'rusticl.icd' post-install/16-mesa-gpu-2613.sh && bad "hook 16 still registers the rusticl ICD" || ok "hook 16 registers no rusticl ICD"
grep -q '"name": "cix-gpu-umd"' build/gen-components-registry.py && ok "registry carries the cix-gpu-umd row" || bad "registry lacks cix-gpu-umd"
exit $fail
