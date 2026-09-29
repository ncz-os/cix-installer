#!/bin/bash
# 39-usb-gpt-autofix.sh — auto-heal the GPT backup-header mismatch on NCZ-OS
# INSTALL MEDIA plugged into an NCZ-OS machine.
#
# Our install image's GPT is sized to the image's own span (~4-5GB), not to
# whatever physical USB stick it eventually gets dd'd/Balena'd onto. Writing
# a small image onto a larger drive leaves the backup GPT header sitting at
# the image's own last sector instead of the drive's real last sector —
# sgdisk reports "secondary header's self-pointer indicates that it doesn't
# reside at the end of the disk", and the kernel logs a GPT mismatch warning
# on every boot the stick is plugged in for. This is a structural property
# of raw-imaging a small image onto a big disk (it was equally true of the
# hybrid ISOs this pipeline used before 2026-09-24; confirmed 2026-07-18 on
# O6N that the NVMe install target's own GPT is always clean — only USB
# installer media shows it), not corruption and not caused by improper
# shutdown — but it reads as "distribution is buggy" to anyone who leaves
# the install stick plugged in, so heal it instead of leaving kernel noise.
#
# SCOPE (tightened 2026-09-24). The udev rule fires for every USB whole-disk
# add, which is unavoidable — ID_FS_LABEL is a per-partition property and the
# rule matches the parent disk. So the helper itself must decide, and it now
# repairs ONLY a disk that positively identifies as NCZ install media: our
# own NCZESP and NCZDATA GPT partition names, which build/iso/write-usb-image.py
# sets and nothing else does. Before, any USB disk whose sgdisk -v output
# matched the diagnostic text got rewritten — someone else's drive with the
# same benign geometry quirk included. It also refuses to touch a disk whose
# GPT has problems beyond that one, and it no longer discards the outcome of
# its own repair.
#
# sgdisk -e only relocates the backup header+table to the disk's real end;
# it never touches partition entries or filesystem data, so this is safe
# to run against a live/mounted USB stick.
set +e

mkdir -p /etc/udev/rules.d /usr/local/sbin

cat > /usr/local/sbin/ncz-usb-gpt-autofix.sh << 'EOF'
#!/bin/bash
# Invoked by udev on USB whole-disk add events. $1 = kernel device name (e.g. sdb).
# Repairs ONLY NCZ install media. See post-install/39-usb-gpt-autofix.sh.
DEV="/dev/$1"
[ -b "$DEV" ] || exit 0
command -v sgdisk >/dev/null 2>&1 || exit 0

VERIFY="$(sgdisk -v "$DEV" 2>&1)"
printf '%s' "$VERIFY" | grep -Eqi "secondary header.*(self-pointer|end of the disk)|backup.*(mismatch|relocat)|not.*at.*end" || exit 0

# IDENTITY GATE: our own partition names, set by build/iso/write-usb-image.py.
# Without this, this helper rewrites the GPT of ANY USB disk that happens to
# show the same benign geometry quirk.
TABLE="$(sgdisk -p "$DEV" 2>/dev/null)"
case "$TABLE" in
    *NCZDATA*) ;;
    *) exit 0 ;;
esac
case "$TABLE" in
    *NCZESP*) ;;
    *) logger -t ncz-usb-gpt-autofix "$DEV has NCZDATA but no NCZESP -- not our media layout, leaving it alone"; exit 0 ;;
esac

# GEOMETRY GATE: only the backup-header relocation, nothing else. sgdisk -v
# prints one "Problem:" line per fault; if it found more than the one we
# recognise, this disk needs a human, not an automatic rewrite.
PROBLEMS="$(printf '%s\n' "$VERIFY" | grep -ci '^Problem')"
if [ "$PROBLEMS" -gt 1 ]; then
    logger -t ncz-usb-gpt-autofix "$DEV reports $PROBLEMS GPT problems, not just the backup-header offset -- refusing to auto-repair: $(printf '%s' "$VERIFY" | tr '\n' ' ')"
    exit 0
fi

logger -t ncz-usb-gpt-autofix "relocating backup GPT on NCZ install media $DEV"
if REPAIR="$(sgdisk -e "$DEV" 2>&1)"; then
    partprobe "$DEV" >/dev/null 2>&1
    AFTER="$(sgdisk -v "$DEV" 2>&1)"
    if printf '%s' "$AFTER" | grep -Eqi "secondary header.*(self-pointer|end of the disk)"; then
        logger -t ncz-usb-gpt-autofix "$DEV STILL reports the backup-header offset after sgdisk -e: $(printf '%s' "$AFTER" | tr '\n' ' ')"
    else
        logger -t ncz-usb-gpt-autofix "$DEV repaired"
    fi
else
    logger -t ncz-usb-gpt-autofix "$DEV repair FAILED: $(printf '%s' "$REPAIR" | tr '\n' ' ')"
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
