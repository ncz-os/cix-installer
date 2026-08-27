#!/bin/bash
# 92-apparmor-enable.sh — enable AppArmor at boot.
#
# NCZ-OS 26.7 audit (W3.5): AppArmor was not installed at all on the
# audited target, despite the CIX Sky1 kernel being built with
#   CONFIG_SECURITY_APPARMOR=y
#   CONFIG_DEFAULT_SECURITY_APPARMOR=y
#   CONFIG_LSM="...apparmor..."
# i.e. AppArmor is BUILT-IN and is the default LSM — no kernel change
# is required. We just have to install the userspace and turn it on.
#
# This hook:
#   1. apt-installs apparmor + apparmor-profiles + apparmor-utils (the
#      latter for `aa-status` admin tools) when missing (typically
#      already shipped via manifests/desktop.pkgs).
#   2. enables apparmor.service so the bundled profiles load at boot.
#      Debian's apparmor package ships apparmor.service as a static
#      enabled unit; we re-enable to defend against an operator who
#      masked it.
#   3. logs `aa-status` summary so a future audit can see exactly
#      which profiles are loaded and in what mode.
#
# DELIBERATELY does NOT flip profiles to enforce mode.
# Debian's apparmor-profiles package description is explicit:
#   "These profiles are not mature enough to be shipped in enforce
#    mode by default on Debian. They are shipped in complain mode so
#    that users can test them, choose which are desired, and help
#    improve them upstream if needed."
# This image ships labwc, greetd, chromium, sinty-nm, sshd and other
# services with bundled profiles. Flipping every bundled profile to
# enforce on first boot can break the desktop or lock out remote
# access. We leave Debian's complain-mode default in place.
#
# We author no AppArmor profiles of our own for binaries we ship, so
# there is nothing here to enforce. If future work adds custom
# profiles, they should be loaded with `aa-enforce` per-profile, not
# via blanket `aa-enforce -r /etc/apparmor.d/*`.
#
# Idempotent: re-runnable; enabling an already-enabled unit is a
# no-op.
#
# NOT a hardening guarantee: this is the DEFAULT enable. Per-service
# tightening (custom Singularity-shell profiles, etc.) is owned by
# future work — see docs/upstream-patches for the open task list.
#
# Runs in chroot during install (Phase 2). Failure-tolerant: if the
# mirror is unreachable and apparmor is not pre-staged, the hook
# logs and continues — a missing AppArmor userspace leaves the box
# unconfined but bootable.
set -euo pipefail

echo "[92] apparmor: enable AppArmor at boot (kernel already has CONFIG_SECURITY_APPARMOR=y)"

# 1. install userspace. The packages are already in the desktop
#    closure (manifests/desktop.pkgs), so this is normally a no-op.
if ! dpkg -s apparmor >/dev/null 2>&1 || ! dpkg -s apparmor-profiles >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            apparmor apparmor-profiles apparmor-utils 2>&1 | tail -3; then
        echo "[92] WARN: apparmor userspace install failed; LSM is built into the kernel but unconfined" >&2
        exit 0
    fi
fi

# 2. enable the systemd unit so profiles load at boot.
if systemctl list-unit-files apparmor.service >/dev/null 2>&1; then
    systemctl unmask apparmor.service 2>/dev/null || true
    systemctl enable apparmor.service 2>&1 | tail -1 || true
    echo "[92] apparmor.service enabled (loads /etc/apparmor.d/* at boot in complain mode by default)"
else
    echo "[92] WARN: apparmor.service not shipped; AppArmor will not auto-load profiles" >&2
fi

# 3. summary for the install log. We do NOT call `aa-enforce` —
#    bundled Debian profiles stay in complain mode (see comment block
#    at top). On the booted system, `aa-status` will show the same set
#    with current mode flags so an operator can promote individual
#    profiles with `aa-enforce <profile>` if they have tested them.
if command -v aa-status >/dev/null 2>&1; then
    aa-status 2>/dev/null | sed 's/^/  /' || true
fi

echo "[92] DONE — apparmor.service enabled, bundled profiles left in Debian's default mode (complain)"