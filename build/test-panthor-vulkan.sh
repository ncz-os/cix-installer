#!/bin/bash
# shellcheck disable=SC2015,SC2016,SC1091  # ok/bad return 0; literal $ in patch/regex matches; generated temp sources
# Regression test for the Panthor Vulkan gap (O6N 2026-10-04).
#
# On a sky1.gpu=mesa (Panthor) boot there was no Vulkan device: the Mali ICD
# mali.json is disabled by the switcher and the Mesa PanVK ICD was missing
# because post-install/47-llm-stack.sh purged mesa-vulkan-drivers on arm64.
# manifests/desktop.pkgs already ships mesa-vulkan-drivers precisely to give
# Panthor panvk, so the purge must not remove it. ncz-gpu-status must also say
# honestly when there is no ICD instead of printing a blank line (and must never
# fail the never-software-render health check because Vulkan is absent).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAILS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1"; }
M="$ROOT/manifests/desktop.pkgs"
L="$ROOT/post-install/47-llm-stack.sh"
S="$ROOT/assets/gpu/ncz-gpu-status"

# ---- the manifest ships the Panthor Vulkan ICD
grep -qE '^[[:space:]]*mesa-vulkan-drivers([[:space:]]|$)' "$M" \
    && ok "desktop.pkgs ships mesa-vulkan-drivers" || bad "desktop.pkgs does not ship mesa-vulkan-drivers"
grep -qE '^[[:space:]]*mesa-opencl-icd([[:space:]]|$)' "$M" \
    && ok "desktop.pkgs ships mesa-opencl-icd (rusticl)" || bad "desktop.pkgs lost mesa-opencl-icd"

# ---- the arm64 purge keeps mesa-vulkan-drivers
purge_loop="$(sed -n '/^    for p in libvulkan-dev/,/^    done/p' "$L")"
if [ -n "$purge_loop" ]; then
    printf '%s\n' "$purge_loop" | grep >/dev/null 'mesa-vulkan-drivers' \
        && bad "arm64 purge still removes mesa-vulkan-drivers" \
        || ok "arm64 purge no longer removes mesa-vulkan-drivers"
    printf '%s\n' "$purge_loop" | grep >/dev/null 'libvulkan-dev' \
        && ok "arm64 purge still removes the Vulkan dev headers" || bad "purge loop looks wrong"
else
    bad "could not find the arm64 purge loop in 47-llm-stack.sh"
fi
arm64_block="$(awk '/^if \[ "\$TARGET_ARCH" = "arm64" \]; then/{f=1} f && /^else$/{exit} f{print}' "$L")"
if printf '%s\n' "$arm64_block" | grep >/dev/null 'apt-get install -y --no-install-recommends mesa-vulkan-drivers'; then
    ok "arm64 branch installs mesa-vulkan-drivers (idempotent)"
else
    bad "arm64 branch does not install mesa-vulkan-drivers"
fi

# ---- ncz-gpu-status is honest about a missing ICD
grep -q 'vulkan ICDs   : ${_vk_icds:-(none)}' "$S" \
    && ok "status prints (none) when there is no ICD" || bad "status still prints a blank ICD line"
grep -q 'no Vulkan on Panthor: install mesa-vulkan-drivers' "$S" \
    && ok "status names the Panthor/no-Vulkan case" || bad "status has no Panthor/no-Vulkan text"
# the missing ICD must not be turned into a health failure
if sed -n '/no Vulkan on Panthor/,+2p' "$S" | grep >/dev/null 'add '; then
    bad "missing Vulkan ICD is treated as a health failure"
else
    ok "missing Vulkan ICD never fails health"
fi

echo "panthor vulkan test: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
