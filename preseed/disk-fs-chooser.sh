#!/bin/sh
# disk-fs-chooser.sh — NCZ installer interactive TARGET-DISK + ROOT-FILESYSTEM
# selection. Invoked from partman/early_command (see preseed-ubuntu.cfg).
#
# WHY a cdebconf menu (NOT whiptail): the ISO boots d-i at `priority=critical`
# so finish-install auto-reboots cleanly (priority=high would drop back to the
# d-i main menu at the end — the "Debian menu at the end" bug). At critical
# priority d-i AUTO-answers its own disk-selection question (picks the first
# disk) and the root filesystem is hard-coded in the expert_recipe — so
# multi-disk systems get no choice and there is no ext4/btrfs choice.
#
# whiptail is NOT shipped in the d-i initrd (verified: only cdebconf-newt is),
# so we register our OWN templates and db_input them at CRITICAL priority. A
# critical-priority question is shown regardless of the global threshold, so the
# operator gets a real disk + fs choice while keeping the clean critical finish.
#
# TEST/UNATTENDED override: if the kernel cmdline carries `ncz_disk=<dev>` and
# optionally `ncz_fs=<ext4|btrfs>`, the prompts are skipped and those values are
# used (used by the KVM harness to validate the flow non-interactively, and for
# scripted installs).
set +e

. /usr/share/debconf/confmodule 2>/dev/null || true

log() { echo "[ncz chooser] $*"; echo "[ncz chooser] $*" > /dev/tty3 2>/dev/null || true; }

# --- read cmdline overrides -------------------------------------------------
CMD=$(cat /proc/cmdline 2>/dev/null)
OVR_DISK=""; OVR_FS=""
for tok in $CMD; do
    case "$tok" in
        ncz_disk=*) OVR_DISK="${tok#ncz_disk=}" ;;
        ncz_fs=*)   OVR_FS="${tok#ncz_fs=}" ;;
    esac
done

# --- enumerate candidate disks ---------------------------------------------
# list-devices disk yields /dev/nvme0n1, /dev/sda, ... — physical disks only.
DISK_LIST=$(list-devices disk 2>/dev/null | sort -u)
[ -z "$DISK_LIST" ] && { log "FATAL: no disks found by list-devices"; exit 1; }

# The disk that holds the install media must never be a target. Strip the
# partition suffix from the media mount source to get its parent disk.
MEDIA_PART=$(awk '$2=="/cdrom"||$2=="/hd-media"||$2=="/run/live/medium"{print $1; exit}' /proc/mounts 2>/dev/null)
MEDIA_DISK=""
if [ -n "$MEDIA_PART" ]; then
    case "$MEDIA_PART" in
        /dev/nvme*|/dev/mmcblk*) MEDIA_DISK=$(echo "$MEDIA_PART" | sed -E 's/p[0-9]+$//') ;;
        /dev/*)                  MEDIA_DISK=$(echo "$MEDIA_PART" | sed -E 's/[0-9]+$//') ;;
    esac
fi
[ -n "$MEDIA_DISK" ] && log "install media parent disk: $MEDIA_DISK (never a target)"

disk_size_h() {  # human size for a /dev node
    b=$(cat "/sys/block/${1##*/}/size" 2>/dev/null)
    [ -n "$b" ] && awk -v s="$b" 'BEGIN{printf "%.0fGB", s*512/1e9}' || echo "?"
}
disk_model() { cat "/sys/block/${1##*/}/device/model" 2>/dev/null | tr -d '\t\r\n' | sed 's/  */ /g; s/^ //; s/ $//; s/,/ /g' ; }

# Build the candidate list (exclude the install medium).
CANDIDATES=""
NDISK=0
for d in $DISK_LIST; do
    [ "$d" = "$MEDIA_DISK" ] && continue
    CANDIDATES="$CANDIDATES $d"
    NDISK=$((NDISK+1))
done
if [ "$NDISK" -eq 0 ]; then
    log "FATAL: no installable disk (only the install medium is present)"; exit 1
fi

# --- choose the target disk -------------------------------------------------
CHOSEN_DISK=""
if [ -n "$OVR_DISK" ]; then
    CHOSEN_DISK="$OVR_DISK"
    log "cmdline override: target disk = $CHOSEN_DISK"
elif [ "$NDISK" -eq 1 ]; then
    # Exactly one candidate: no disk ambiguity. Still confirm-by-showing the fs
    # menu below; auto-select the disk here.
    CHOSEN_DISK=$(echo $CANDIDATES | awk '{print $1}')
    log "single installable disk present -> $CHOSEN_DISK"
else
    # Register a cdebconf select with the candidate /dev nodes as Choices, then
    # db_input at CRITICAL so it shows even under priority=critical.
    CHOICES=""
    LONG=""
    for d in $CANDIDATES; do
        desc="$(disk_model "$d") $(disk_size_h "$d")"
        [ -z "$CHOICES" ] && CHOICES="$d" || CHOICES="$CHOICES, $d"
        LONG="$LONG  $d  —  $desc\\n"
    done
    cat > /tmp/ncz-disk.templates <<TPL
Template: ncz/target-disk
Type: select
Choices: ${CHOICES}
Description: NCZ-OS install — select the TARGET DISK (it will be ERASED)
 The disk you choose will be COMPLETELY ERASED and NCZ-OS installed on it.
 .
 Detected disks:
 ${LONG}
TPL
    if debconf-loadtemplate ncz /tmp/ncz-disk.templates 2>/dev/null; then
        db_subst ncz/target-disk CHOICES "$CHOICES" 2>/dev/null
        db_fset  ncz/target-disk seen false 2>/dev/null
        db_settitle ncz/target-disk 2>/dev/null
        db_input critical ncz/target-disk 2>/dev/null
        db_go 2>/dev/null
        db_get ncz/target-disk 2>/dev/null
        CHOSEN_DISK="$RET"
    fi
    if [ -z "$CHOSEN_DISK" ]; then
        # Fallback: first candidate (never stall the install with no choice).
        CHOSEN_DISK=$(echo $CANDIDATES | awk '{print $1}')
        log "WARN: disk prompt yielded nothing — defaulting to first candidate $CHOSEN_DISK"
    fi
fi
[ -b "$CHOSEN_DISK" ] || { log "FATAL: chosen disk $CHOSEN_DISK is not a block device"; exit 1; }
# Hard safety: refuse if the install media lives on the chosen disk.
if [ -n "$MEDIA_DISK" ] && [ "$MEDIA_DISK" = "$CHOSEN_DISK" ]; then
    log "REFUSE: install media is on the target disk $CHOSEN_DISK"; exit 1
fi

# --- choose the root filesystem --------------------------------------------
CHOSEN_FS=""
case "$OVR_FS" in
    ext4|btrfs) CHOSEN_FS="$OVR_FS"; log "cmdline override: root fs = $CHOSEN_FS" ;;
esac
if [ -z "$CHOSEN_FS" ]; then
    cat > /tmp/ncz-fs.templates <<'TPL'
Template: ncz/root-fs
Type: select
Choices: btrfs, ext4
Default: btrfs
Description: NCZ-OS install — root (/) filesystem
 Choose the filesystem for the root (/) partition.
 .
 btrfs — snapshots + transparent compression (NCZ default).
 ext4  — simple, maximally robust.
TPL
    if debconf-loadtemplate ncz /tmp/ncz-fs.templates 2>/dev/null; then
        db_fset  ncz/root-fs seen false 2>/dev/null
        db_settitle ncz/root-fs 2>/dev/null
        db_input critical ncz/root-fs 2>/dev/null
        db_go 2>/dev/null
        db_get ncz/root-fs 2>/dev/null
        CHOSEN_FS="$RET"
    fi
fi
case "$CHOSEN_FS" in ext4|btrfs) : ;; *) CHOSEN_FS=btrfs ;; esac
log "TARGET DISK = $CHOSEN_DISK   ROOT FS = $CHOSEN_FS"

# --- prep the chosen disk (swapoff / unmount / wipe stale GPT) --------------
# Replaces the OLD hardcoded /dev/nvme0n1 dd-zap in partman/early_command — we
# now wipe only the OPERATOR-CHOSEN disk, never a fixed device.
D="$CHOSEN_DISK"; base="${D##*/}"
awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep "^${D}" | while read _s; do swapoff "$_s" 2>/dev/null || true; done
awk -v dd="$D" '$1 ~ dd {print $2}' /proc/mounts 2>/dev/null | sort -r | while read _mp; do sync; umount "$_mp" 2>/dev/null || { sleep 1; umount "$_mp" 2>/dev/null || true; }; done
SZ=$(cat "/sys/block/$base/size" 2>/dev/null)
dd if=/dev/zero of="$D" bs=1M count=16 2>/dev/null
[ -n "$SZ" ] && dd if=/dev/zero of="$D" bs=512 seek=$((SZ-2048)) count=2048 2>/dev/null
sync; blockdev --rereadpt "$D" 2>/dev/null || true; udevadm settle 2>/dev/null || true
log "cleared stale GPT on $D"

# --- drive partman-auto: pin the disk + build the recipe with the chosen fs -
# Root partition uses CHOSEN_FS; ESP (fat32, 4GiB) + rescue (ext4, 4GiB) fixed.
# Sizes mirror the static preseed recipe (2048 fat32 -> but preseed comment says
# 4GiB; the recipe below uses the same numbers the static preseed used: the ESP
# min/priority/max 2048 and the rescue 4096 — kept byte-for-byte compatible).
RECIPE="cixmini :: \
  2048 2048 2048 fat32 \$primary{ } \$bootable{ } method{ efi } format{ } . \
  4096 4096 4096 ext4 \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } label{ NCZRESCUE } . \
  4096 8192 -1 $CHOSEN_FS \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ $CHOSEN_FS } mountpoint{ / } ."

db_set partman-auto/disk "$CHOSEN_DISK"       2>/dev/null || echo "SET partman-auto/disk $CHOSEN_DISK" | debconf-communicate >/dev/null 2>&1
db_set partman-auto/expert_recipe "$RECIPE"   2>/dev/null || echo "SET partman-auto/expert_recipe $RECIPE" | debconf-communicate >/dev/null 2>&1
db_set partman-auto/choose_recipe cixmini     2>/dev/null || true
db_fset partman-auto/disk seen true           2>/dev/null || true
db_fset partman-auto/expert_recipe seen true  2>/dev/null || true
db_fset partman-auto/choose_recipe seen true  2>/dev/null || true
# stash the choices for later hooks / diagnostics
echo "$CHOSEN_DISK" > /tmp/ncz-target-disk 2>/dev/null || true
echo "$CHOSEN_FS"   > /tmp/ncz-root-fs 2>/dev/null || true
mkdir -p /target 2>/dev/null || true
log "partman pinned: disk=$CHOSEN_DISK recipe-root-fs=$CHOSEN_FS"
exit 0
