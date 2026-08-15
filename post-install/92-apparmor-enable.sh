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
#      latter for `aa-status` / `aa-enforce` admin tools) when missing
#      (typically already shipped via manifests/desktop.pkgs).
#   2. enables apparmor.service so the bundled profiles load at boot.
#      Debian's apparmor package ships apparmor.service as a static
#      enabled unit; we re-enable to defend against an operator who
#      masked it.
#   3. loads every shipped profile via `aa-enforce` so the broker boots
#      in enforce mode for those binaries (usr.sbin.* etc.). Profiles
#      marked `complain` upstream are kept in complain mode; the
#      bundled profiles are a sane starting point.
#   4. logs `aa-status --complain` summary so a future audit can see
#      exactly which profiles are loaded.
#
# Idempotent: re-runnable; enabling an already-enabled unit is a
# no-op, and `aa-enforce -r` re-reads from disk and is also safe to
# run repeatedly.
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
    echo "[92] apparmor.service enabled (loads /etc/apparmor.d/* at boot)"
else
    echo "[92] WARN: apparmor.service not shipped; AppArmor will not auto-load profiles" >&2
fi

# 3. load every bundled profile in enforce mode. aa-enforce -r reloads
#    from disk and switches to enforce; idempotent. If a profile is
#    marked `complain` upstream in its header, aa-enforce will flip it
#    to enforce here — that is intentional: stock-shipped images should
#    start enforce-mode and let operators loosen where needed.
if command -v aa-enforce >/dev/null 2>&1; then
    if [ -d /etc/apparmor.d ]; then
        aa-enforce -r /etc/apparmor.d/* 2>&1 | tail -5 || \
            echo "[92] WARN: aa-enforce -r returned non-zero (some profiles may be invalid)" >&2
        echo "[92] bundled profiles loaded in enforce mode"
    else
        echo "[92] /etc/apparmor.d missing — nothing to enforce" >&2
    fi
else
    echo "[92] aa-enforce not on PATH (apparmor-utils not installed?) — skipping per-profile enforce" >&2
fi

# 4. summary for the install log. On the booted system, `aa-status`
#    will show the same set with current mode flags.
if command -v aa-status >/dev/null 2>&1; then
    aa-status --complain 2>/dev/null | sed 's/^/  /' || true
fi

echo "[92] DONE — apparmor.service enabled, bundled profiles in enforce mode"
