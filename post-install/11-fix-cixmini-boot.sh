#!/bin/bash
# 11-fix-cixmini-boot.sh — redirect cixmini-boot's kernel-postinst hook to
# rEFInd instead of (inert) systemd-boot.
#
# 10-our-kernel.sh (the previous hook, this one runs right after) installs
# the kernel via apt, which pulls in the `cixmini-boot` package as a
# dependency. The linux-image-cixmini package's own postinst scripts
# directly call /usr/lib/cixmini/cixmini-update-bootloader on every install
# or upgrade -- confirmed live on the MS-R1 test board (2026-07-06), this is the ONLY
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
# ARCH GATE (dual-arch parity): Sky1-only hook. run-all.sh runs every hook on every architecture, so
# log and no-op anywhere else (build/lint-hook-arch-gates.sh enforces this).
_ncz_a="${NCZ_TARGET_ARCH:-$(tr -d '[:space:]' < /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null)}"
[ -n "$_ncz_a" ] || _ncz_a="$(dpkg --print-architecture 2>/dev/null || true)"
if [ "$_ncz_a" != arm64 ]; then echo "[11] Sky1-only hook; target architecture is '${_ncz_a:-unknown}' -- skipping"; exit 0; fi
unset _ncz_a
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
# mtime, not `sort -V`, to pick the newest of a set (operator 2026-08-21 /
# CORRECTED 2026-09-12 -- O6N boot-break root cause): `sort -V | tail -1`
# assumes an upgrade (higher version == the one just installed), which is
# FALSE for an explicit downgrade. This wrapper is invoked from
# linux-image-cix-sky1-ncz's own postinst, which runs BEFORE dpkg removes
# the files the OLD package version owned but the new one does not -- so
# during a same-transaction downgrade (e.g. 7.3.0-rc2 -> 7.2.5) BOTH
# kernels' vmlinuz/initrd are still on disk when this scans them, and
# `sort -V` picked the numerically-higher kernel that was just replaced.
# dpkg always rewrites the vmlinuz it installs NOW with a fresh mtime,
# regardless of version number, so mtime doesn't have that blind spot.
_newest_of() {
    local _best="" _best_mt=-1 _k _f _mt
    for _k in $1; do
        _f="/boot/vmlinuz-$_k"
        [ -e "$_f" ] || continue
        _mt=$(stat -c '%Y' "$_f" 2>/dev/null || echo -1)
        if [ "$_mt" -gt "$_best_mt" ]; then
            _best_mt=$_mt
            _best="$_k"
        fi
    done
    printf '%s' "$_best"
}

# Unified 7.3 (operator 2026-10-05): one shipping kernel. The 2026-09-16
# fix bucketed *-rcN-* kernels into KVER_EDGE so an apt install of the
# then-test edge line could not displace the 7.2 stable default. That
# bucket is now wrong: the shipping kernel IS 7.3.0-rc6-sky1-ncz, and
# ncz-refind-refresh.sh ignores KVER_EDGE. Leaving the bucket in place
# puts the only installed kernel in KVER_EDGE, then the fallback below
# promotes it -- which works only while no non-rc kernel is also installed.
# Pick the newest installed NCZ kernel directly. KVER_EDGE stays empty so
# the refresh script does not warn about a retired second channel.
KVER_NEXT="$(_newest_of "$NCZ_KVERS")"
KVER_EDGE=""

echo "cixmini-update-bootloader: shipping=${KVER_NEXT:-<none>}"

if [ -z "$KVER_NEXT" ]; then
    echo "cixmini-update-bootloader: no shipping kernel with a ready initrd found, skipping"
    exit 0
fi

BUILD_VERSION="(unknown)"
[ -f /usr/local/lib/cix-installer/BUILD_VERSION ] && \
    BUILD_VERSION=$(cat /usr/local/lib/cix-installer/BUILD_VERSION 2>/dev/null || true)

KVER_NEXT="$KVER_NEXT" KVER_EDGE="$KVER_EDGE" BUILD_VERSION="$BUILD_VERSION" "$REFRESH"
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
