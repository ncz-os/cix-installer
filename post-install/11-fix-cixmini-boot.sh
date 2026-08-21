#!/bin/bash
# 11-fix-cixmini-boot.sh — redirect cixmini-boot's kernel-postinst hook to
# rEFInd instead of (inert) systemd-boot.
#
# 10-our-kernel.sh (the previous hook, this one runs right after) installs
# the kernel via apt, which pulls in the `cixmini-boot` package as a
# dependency. The linux-image-cixmini package's own postinst scripts
# directly call /usr/lib/cixmini/cixmini-update-bootloader on every install
# or upgrade -- confirmed live on .66 (2026-07-06), this is the ONLY
# mechanism that actually fires automatically; the conventional
# /etc/kernel/postinst.d/ run-parts hook directory is NOT invoked by
# anything on this system despite cixmini-boot shipping a file there too.
#
# The shipped cixmini-update-bootloader writes systemd-boot loader
# entries. That's dead code: this distro has booted rEFInd since r118.
# Left as-is, every kernel install/upgrade via apt would silently update
# an inert systemd-boot config while the real rEFInd menu (refind.conf)
# goes stale -- defeating the whole point of making the kernel apt-managed
# (10-our-kernel.sh) in the first place.
#
# Fix: overwrite cixmini-update-bootloader with a thin wrapper that
# discovers the installed LTS/NEXT kernel from /boot/vmlinuz-* and calls
# the real rEFInd refresh (ncz-refind-refresh, installed by
# 70-bootloader.sh to /usr/local/sbin/). Not a dpkg conffile, so a future
# `apt upgrade cixmini-boot` would silently restore the original
# systemd-boot version -- an apt DPkg::Post-Invoke hook (installed below)
# re-applies our override any time cixmini-boot itself changes, so the
# fix survives. The wrapper's own source is kept at a stable path under
# /usr/local/sbin (NOT /usr/local/lib/cix-installer/, which is
# install-time metadata not guaranteed to persist) so the self-healing
# hook has something to re-apply from indefinitely.
set -euo pipefail

WRAPPER_STABLE=/usr/local/sbin/.ncz-cixmini-update-bootloader
WRAPPER_DST=/usr/lib/cixmini/cixmini-update-bootloader

if [ ! -d /usr/lib/cixmini ]; then
    echo "[11] /usr/lib/cixmini not present (cixmini-boot not installed?) — skipping"
    exit 0
fi

install -d -m 0755 /usr/local/sbin
cat > "$WRAPPER_STABLE" <<'WRAPEOF'
#!/bin/bash
# cixmini-update-bootloader — replaced by cix-installer (r193) to call the
# real rEFInd refresh instead of writing (inert) systemd-boot entries.
# This distro boots rEFInd, not systemd-boot (switched at r118). See
# post-install/11-fix-cixmini-boot.sh in cix-installer.
set -uo pipefail
REFRESH=/usr/local/sbin/ncz-refind-refresh
[ -x "$REFRESH" ] || { echo "cixmini-update-bootloader: ncz-refind-refresh not present, skipping"; exit 0; }

KVER_NEXT=""
NCZ_KVERS=""   # collected candidates; must exist for set -u
for f in /boot/vmlinuz-*; do
    [ -e "$f" ] || continue
    kver="${f#/boot/vmlinuz-}"
    case "$kver" in
        *-rescue) continue ;;
        *-next|*-ncz|*-sky1-ncz)
            # Skip a kernel mid-unpack: if a kernel is being upgraded in the
            # same apt transaction, this hook can fire (from the first
            # kernel's own postinst) before the second kernel's postinst
            # has generated its initrd yet. Passing an incomplete kernel
            # through makes ncz-refind-refresh hard-fail on a missing initrd.
            if [ ! -s "/boot/initrd.img-$kver" ]; then
                echo "cixmini-update-bootloader: $kver has no initrd yet (mid-transaction?) -- skipping this kernel for now"
                continue
            fi
            NCZ_KVERS="$NCZ_KVERS $kver"
            ;;
    esac
done
# Single shipping kernel (operator 2026-08-21): the legacy 7.0.12 line is
# retired. Take the highest-versioned NCZ kernel present and ship only
# that.
#
# sort -V ranks these correctly (verified):
#   7.2.0-rc1 < 7.2.0-rc7 < 7.2.0 < 7.2.1        (release beats its own rc)
#   7.2.0 < 7.2.1 < 7.3.0-rc1 < 7.10.0           (numeric, not lexical)
if [ -n "$(printf '%s' "$NCZ_KVERS" | tr -d ' ')" ]; then
    KVER_NEXT=$(printf '%s\n' $NCZ_KVERS | sort -V | tail -1)
    echo "cixmini-update-bootloader: shipping kernel = $KVER_NEXT (edge-only)"
fi

if [ -z "$KVER_NEXT" ]; then
    echo "cixmini-update-bootloader: no edge kernel with a ready initrd found, skipping"
    exit 0
fi

BUILD_VERSION="(unknown)"
[ -f /usr/local/lib/cix-installer/BUILD_VERSION ] && \
    BUILD_VERSION=$(cat /usr/local/lib/cix-installer/BUILD_VERSION 2>/dev/null || true)

KVER_NEXT="$KVER_NEXT" BUILD_VERSION="$BUILD_VERSION" "$REFRESH"
WRAPEOF
chmod 0755 "$WRAPPER_STABLE"
echo "[11] wrote stable wrapper source -> $WRAPPER_STABLE"

install -m 0755 "$WRAPPER_STABLE" "$WRAPPER_DST"
echo "[11] redirected $WRAPPER_DST -> ncz-refind-refresh (was: systemd-boot)"

# Self-healing: re-apply the override whenever cixmini-boot itself is
# installed/upgraded/reinstalled (which would otherwise restore dpkg's
# packaged systemd-boot version, since this path isn't a conffile). Also
# re-RUNS the wrapper (not just restores it) as a catch-all: if a single
# apt transaction upgrades cixmini-boot AND a kernel together, dpkg runs
# cixmini-boot's postinst (restoring the ORIGINAL systemd-boot version)
# before the kernel's own postinst calls it -- so the kernel that just
# installed would get refreshed against the wrong (stale) wrapper. This
# Post-Invoke re-applies our override AND immediately runs it once more
# at the end of the transaction, so refind.conf still ends up correct.
APT_HOOK=/etc/apt/apt.conf.d/91-ncz-fix-cixmini-boot
cat > "$APT_HOOK" <<HOOKEOF
// Re-apply the rEFInd redirect for cixmini-update-bootloader after any
// transaction touching cixmini-boot -- see post-install/11-fix-cixmini-boot.sh
// in cix-installer for why this file gets overwritten instead of upstream-fixed.
DPkg::Post-Invoke {
    "if dpkg -s cixmini-boot >/dev/null 2>&1 && [ -s $WRAPPER_STABLE ]; then install -m 0755 $WRAPPER_STABLE $WRAPPER_DST && $WRAPPER_DST || true; fi";
}
HOOKEOF
echo "[11] installed apt self-healing hook -> $APT_HOOK"
