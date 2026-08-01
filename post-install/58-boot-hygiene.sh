#!/bin/bash
# 58-boot-hygiene.sh — a clean boot: zero failed systemd units (no plymouth
# reds/oranges), zero avoidable log spam. Idempotent; Phase-2 optional; runs in
# the chroot at build/install time and is safe to re-run on a live system.
#
# WHAT THIS FIXES (all verified on O6N, NCZ-OS 26.7 / kernel 7.2.0-rc5-sky1-ncz;
# these are userspace/systemd fixes, not kernel-version-specific):
#
#   Failed units that painted RED on the plymouth splash (is-system-running
#   went 'degraded'):
#     - apport.service      Ubuntu crash reporter — unwanted on an appliance.
#     - iscsid.service/.socket   no iSCSI on this box.
#     - multipathd.service/.socket   single NVMe, no multipath.
#     - cix_resume_prepare.service   FAILED because its helper
#       /usr/bin/cix_resume_prepare.sh (from the cix-debian-misc pkg) remounts
#       the rootfs with `nodelalloc` — an ext4-only option that btrfs rejects
#       ("btrfs: Unknown parameter 'nodelalloc'"), so the remount errored and
#       the oneshot failed. This is a REAL failure with a REAL root cause, not
#       something to mask: we drop the ext4-only option so the remount (rootfs
#       is already rw) succeeds. Fixing the script ALSO clears the recurring
#       "btrfs: Unknown parameter 'nodelalloc'" dmesg warning (4x/boot).
#
#   Log spam:
#     - rsyslog "omfwd: Network is unreachable" (~26x/boot): defensively drop
#       any stale /etc/rsyslog.d/90-loghost.conf (the always-on fleet-IP forward
#       is now opt-in — see 36-telemetry.sh).
#     - wireplumber/pipewire "RTKit error org.freedesktop.DBus.Error.Service-
#       Unknown": the rtkit daemon was absent, so PipeWire/WirePlumber could not
#       get RT scheduling. Install rtkit (fixes the spam AND audio RT latency).
#     - systemd "Configuration file ... is marked executable": the CIX vendor
#       unit files ship with the +x bit; chmod 0644 silences the warning.
#     - Runtime kernel messages leaking onto the graphical VT during the
#       greetd<->session handoff: pin the console loglevel to 3 (KERN_ERR-)
#       via sysctl so a runtime driver message (e.g. "Module panthor is
#       blacklisted") can't paint on the transition VT.
#
# WARNINGS DELIBERATELY LEFT IN dmesg (vendor kernel / firmware ACPI; genuinely
# benign, hidden behind `quiet splash` so they never reach plymouth; the proper
# fix is a CIX BSP kernel/ACPI change tracked for a future 7.2 kernel build, NOT
# a runtime kludge):
#   - sky1-pinctrl "does not have pin group cam_pwren/cam_5v_pwren/pinctrl_usbN/
#     fch_pwm0/..._i2sN_dbg": the platform ACPI (DSDT/SSDT, patch 0039 consumer)
#     references pinmux groups for peripherals not wired on this board (no
#     camera, debug I2S). The pins simply aren't configured — harmless.
#   - regulator "IC does not support requested over-current/voltage/temperature
#     limits": ACPI over-declares protection constraints the fixed/gpio
#     regulators can't enforce (patch 0028). Cosmetic.
#   - cdns-usbssp "runtime PM trying to activate child ... parent not active" /
#     "Enabling runtime PM for inactive device with active children": a probe-
#     order PM note in the CIX USB controller driver. USB works.
#   - hdmi-audio-codec "ASoC: sink/source widget overwritten": the 3 DP-audio
#     links share codec DAPM widget names. Audio routes correctly.
#   - mali_kbase "Mali reset workqueue ... Setting WQ_PERCPU" WARN: the GPU DKMS
#     driver calls alloc_workqueue() without a WQ flag on 7.2 — a DKMS-source
#     nit, GPU is functional; owned by the GPU/DKMS workstream.
#   - usb_submit_urb "URB submitted while active" WARN from ncz-usb2-rescan: a
#     cosmetic side-effect of the (load-bearing) 41-usb2-rescan keyboard-enum
#     recovery rebind. Left intact so the dead-keyboard fix is not regressed.
set +e

echo "[58] boot hygiene — clear failed units + avoidable log spam"

# --- 1. Mask appliance-noise units (the plymouth reds) ---------------------
for u in iscsid.service iscsid.socket \
         multipathd.service multipathd.socket \
         apport.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then
        systemctl disable "$u" >/dev/null 2>&1
        systemctl mask "$u"    >/dev/null 2>&1
        echo "  masked $u"
    fi
done
systemctl reset-failed >/dev/null 2>&1 || true

# Sky1 kernels do not enable CONFIG_AUTOFS_FS, so systemd's generated
# binfmt_misc automount cannot be created and paints an avoidable
# "automount unsupported" boot warning. Mount binfmt_misc directly instead;
# this preserves systemd-binfmt/container support without requiring autofs.
systemctl mask proc-sys-fs-binfmt_misc.automount >/dev/null 2>&1 || true
install -d -m0755 /etc/systemd/system/sysinit.target.wants
ln -sf /usr/lib/systemd/system/proc-sys-fs-binfmt_misc.mount \
    /etc/systemd/system/sysinit.target.wants/proc-sys-fs-binfmt_misc.mount
echo "  masked unsupported binfmt_misc automount; enabled direct mount"

# --- 2. cix_resume_prepare: drop ext4-only nodelalloc (btrfs rejects it) ----
# Root-cause fix for BOTH the failed service AND the btrfs 'nodelalloc' dmesg
# warning. The rootfs is already mounted rw (cmdline `rw`), so `remount,rw` is a
# harmless success on btrfs and ext4 alike.
CRP=/usr/bin/cix_resume_prepare.sh
if [ -f "$CRP" ] && grep -q 'nodelalloc' "$CRP"; then
    sed -i 's/remount,nodelalloc,rw/remount,rw/' "$CRP"
    echo "  patched $CRP (removed ext4-only nodelalloc)"
fi

# --- 3. chmod 0644 exec-bit vendor unit files ------------------------------
for f in /usr/lib/systemd/system/cix_resume_prepare.service \
         /usr/lib/systemd/system/cix_resume.service \
         /etc/systemd/system/S30tee-supplicant.service \
         /etc/systemd/system/load-modules.service; do
    if [ -f "$f" ] && [ -x "$f" ]; then chmod 0644 "$f"; echo "  chmod 0644 $f"; fi
done
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed cix_resume_prepare.service >/dev/null 2>&1 || true

# --- 4. Defensive: drop any stale always-on rsyslog loghost forward --------
if [ -f /etc/rsyslog.d/90-loghost.conf ] && grep -qE '^\*\.\*[[:space:]]+@[0-9]' /etc/rsyslog.d/90-loghost.conf 2>/dev/null; then
    rm -f /etc/rsyslog.d/90-loghost.conf
    systemctl try-restart rsyslog >/dev/null 2>&1 || true
    echo "  removed stale always-on 90-loghost.conf (forward is opt-in now)"
fi

# --- 5. rtkit for PipeWire/WirePlumber RT scheduling -----------------------
# rtkit is part of the mandatory desktop closure (20-desktop.sh).  Do not
# initiate a new network-backed apt transaction from this late, clean-up hook:
# that made otherwise successful offline installs report rc=100 here and left
# the audio RT policy dependent on transient mirror state.
if dpkg -s rtkit >/dev/null 2>&1; then
    echo "  rtkit present"
else
    echo "  WARN: rtkit missing from desktop closure"
fi

# --- 6. Keep runtime kernel messages off the graphical transition VT -------
# NB: numbered 99- ON PURPOSE — /usr/lib/sysctl.d/55-console-messages.conf sets
# `kernel.printk = 4 4 1 7`, and sysctl.d applies in lexical order (last wins),
# so a lower number than 55 would be overridden and the console would sit at 4
# (KERN_ERR prints) at runtime.
install -d -m0755 /etc/sysctl.d
rm -f /etc/sysctl.d/10-ncz-quiet-console.conf   # drop the old (losing) name
cat > /etc/sysctl.d/99-ncz-quiet-console.conf <<'SYS'
# NCZ: hold the console loglevel at 3 (only < KERN_ERR reaches the console) at
# runtime so a stray driver/module message can't paint on the greetd<->session
# handoff VT. (boot uses loglevel=3; 55-console-messages.conf would raise it to
# 4 — this file, sorting after 55, keeps it at 3.)
kernel.printk = 3 4 1 3
SYS
if [ -w /proc/sys/kernel/printk ] 2>/dev/null; then
    sysctl -q -w kernel.printk="3 4 1 3" 2>/dev/null || true
fi
echo "  console loglevel pinned to 3 (/etc/sysctl.d/99-ncz-quiet-console.conf)"

# --- 7. Do not mount efivarfs when EFI runtime was deliberately disabled ----
# The Sky1 platform requires efi=noruntime for stable boot.  Ubuntu's mdadm
# initramfs script otherwise emits a visible, inevitable efivarfs mount error
# before systemd/loglevel policy is active. Preserve normal EFI-runtime boots
# by delegating to the package script unless that explicit cmdline is present.
EFI_HOOK=/usr/share/initramfs-tools/scripts/init-top/00_mount_efivarfs
if [ -f "$EFI_HOOK" ]; then
    if ! dpkg-divert --list "$EFI_HOOK" 2>/dev/null | grep -Fqx "local diversion of $EFI_HOOK to ${EFI_HOOK}.distrib"; then
        dpkg-divert --local --rename --add "$EFI_HOOK" >/dev/null 2>&1 || true
    fi
    if [ -f "${EFI_HOOK}.distrib" ]; then
        cat > "$EFI_HOOK" <<'EFIHOOK'
#!/bin/sh
case "${1:-}" in
    prereqs) exec /bin/sh "${0}.distrib" prereqs ;;
esac
if grep -qw 'efi=noruntime' /proc/cmdline 2>/dev/null; then
    exit 0
fi
exec /bin/sh "${0}.distrib" "$@"
EFIHOOK
        chmod 0755 "$EFI_HOOK"
        # initramfs-tools executes every executable script it finds in
        # init-top.  A dpkg-divert alone leaves *.distrib executable, so both
        # this guard AND the original mount script were run.  Keep the original
        # readable for normal EFI-runtime delegation, but non-executable so it
        # cannot be independently added to ORDER.
        chmod 0644 "${EFI_HOOK}.distrib"

        # rEFInd loads kernel/initrd payloads from the ESP root, not /boot.
        # update-initramfs updates only /boot, which previously let a repaired
        # root initrd coexist with an older, still-broken ESP copy.  Sync only
        # versions currently referenced by rEFInd, after every successful
        # update-initramfs run.  If a board needs an NPU ACPI prepend, its
        # canonical /boot initrd already contains that prepend before this hook
        # copies it, so the boot contract stays identical on both filesystems.
        install -d -m0755 /etc/initramfs/post-update.d
        cat > /etc/initramfs/post-update.d/90-ncz-refind-esp-sync <<'ESPSYNC'
#!/bin/sh
set -eu
version=${1:-}
initrd=${2:-}
[ -n "$version" ] && [ -r "$initrd" ] || exit 0
[ -r /boot/efi/EFI/BOOT/refind.conf ] || exit 0
grep -Fq "/initrd.img-$version" /boot/efi/EFI/BOOT/refind.conf || exit 0
findmnt -no FSTYPE /boot/efi 2>/dev/null | grep -qx vfat || exit 0
dest="/boot/efi/initrd.img-$version"
if [ -r "$dest" ] && cmp -s "$initrd" "$dest"; then exit 0; fi
install -m0644 "$initrd" "$dest"
sync
cmp -s "$initrd" "$dest" || {
    echo "ncz-refind-esp-sync: verification failed for $dest" >&2
    exit 1
}
ESPSYNC
        chmod 0755 /etc/initramfs/post-update.d/90-ncz-refind-esp-sync
        update-initramfs -u -k all >/dev/null 2>&1 || true
        echo "  guarded efivarfs initramfs mount for efi=noruntime"
    fi
fi

# --- 8. update-motd.d: remove overlayfs-whiteout char-device artifacts ------
# 50-brand.sh does `rm -f /etc/update-motd.d/00-header` at build time; in the
# layered-squashfs build that deletion flattens to an overlayfs WHITEOUT — a
# char device (0,0) — which ships in the image and makes run-parts error
# "/etc/update-motd.d/00-header: not an executable plain file" on EVERY login.
# The NCZ header is 00-ncz-banner (created by 50-brand), so 00-header is meant to
# be gone: delete any char-device entry here to complete that intent cleanly.
if [ -d /etc/update-motd.d ]; then
    find /etc/update-motd.d -maxdepth 1 -type c -print -delete 2>/dev/null \
        | sed 's/^/  removed motd char-device: /'
fi

echo "[58] boot hygiene done"
