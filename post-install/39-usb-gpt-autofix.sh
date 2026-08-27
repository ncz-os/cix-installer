#!/bin/bash
# 39-usb-gpt-autofix.sh — auto-heal hybrid-ISO GPT backup-header mismatch on
# any USB stick plugged into an NCZ-OS machine.
#
# Every NCZ-OS install ISO is a xorriso isohybrid image: the GPT baked into
# the ISO is sized to the ISO's own data span (~4-5GB), not to whatever
# physical USB stick it eventually gets dd'd/Balena'd onto. Raw-imaging a
# small hybrid ISO onto a larger USB drive leaves the backup GPT header
# sitting at the ISO's own last sector instead of the drive's real last
# sector — sgdisk reports "secondary header's self-pointer indicates that
# it doesn't reside at the end of the disk", and the kernel logs it as a
# GPT mismatch warning on every boot the stick is plugged in for. This is
# a structural property of hybrid ISOs (confirmed 2026-07-18 on O6N: the
# NVMe install target's own GPT is always clean — only USB installer media
# shows this), not corruption and not caused by improper shutdown — but it
# reads as "distribution is buggy" to anyone who leaves the install stick
# plugged in, so heal it automatically instead of leaving kernel noise.
#
# Scope is intentionally narrow: ID_BUS=="usb" whole-disk devices only.
# sgdisk -e only relocates the backup header+table to the disk's real end;
# it never touches partition entries or filesystem data, so this is safe
# to run against a live/mounted USB stick.
set +e

mkdir -p /etc/udev/rules.d /usr/local/sbin

cat > /usr/local/sbin/ncz-usb-gpt-autofix.sh << 'EOF'
#!/bin/bash
# Invoked by udev on USB whole-disk add events. $1 = kernel device name (e.g. sdb).
DEV="/dev/$1"
[ -b "$DEV" ] || exit 0
command -v sgdisk >/dev/null 2>&1 || exit 0

OUT="$(sgdisk -v "$DEV" 2>&1)"
if printf '%s' "$OUT" | grep -Eqi "secondary header.*(self-pointer|end of the disk)|backup.*(mismatch|relocat)|not.*at.*end"; then
    logger -t ncz-usb-gpt-autofix "relocating backup GPT on $DEV (hybrid-ISO artifact)"
    sgdisk -e "$DEV" >/dev/null 2>&1
    partprobe "$DEV" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x /usr/local/sbin/ncz-usb-gpt-autofix.sh

cat > /etc/udev/rules.d/99-ncz-usb-gpt-autofix.rules << 'EOF'
# NCZ-OS: auto-relocate a USB stick's backup GPT header when it shows the
# hybrid-ISO-on-oversized-media mismatch. See 39-usb-gpt-autofix.sh.
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_BUS}=="usb", RUN+="/usr/local/sbin/ncz-usb-gpt-autofix.sh $kernel"
EOF

udevadm control --reload-rules 2>&1 | tail -1
echo "[39] USB GPT auto-heal installed (udev rule + /usr/local/sbin/ncz-usb-gpt-autofix.sh)"
