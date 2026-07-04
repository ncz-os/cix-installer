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
# SAFETY DOCTRINE (this is a DISK-ERASING path): err toward ABORT. Any failure —
# missing template, cancelled/backed-out prompt, empty answer, an override that
# is not a whole disk in the enumerated candidate set, or a partman debconf pin
# that will not verify — makes this script exit NONZERO and wipe NOTHING. The
# disk is zeroed ONLY after (a) it is proven to be a valid, non-media whole-disk
# target AND (b) partman-auto/disk + expert_recipe + choose_recipe are pinned
# AND verified to it. We never auto-pick a disk to "recover" from a failed
# prompt, and partman/early_command turns our nonzero exit into a hard stop.
#
# TEST/UNATTENDED override: if the kernel cmdline carries `ncz_disk=<dev>` and
# optionally `ncz_fs=<ext4|btrfs>`, the disk prompt is skipped — but the override
# MUST canonicalize to one of the `list-devices disk` whole-disk candidates
# (partitions / arbitrary nodes / the install medium are rejected).
set +e

. /usr/share/debconf/confmodule 2>/dev/null || true

log() { echo "[ncz chooser] $*"; echo "[ncz chooser] $*" > /dev/tty3 2>/dev/null || true; }
abort() { log "ABORT: $* — wiping NOTHING, stopping install."; exit 1; }

# ----------------------------------------------------------------------------
# parent_disk_of_dev <path> -> echoes the whole-disk /dev node backing <path>
# Canonicalizes symlinks (/dev/disk/by-*, /dev/mapper/*), resolves loop backing
# files, dm/mapper/mdraid slaves, and partition -> parent-disk via sysfs.
# Best-effort; echoes nothing if it cannot resolve.
# ----------------------------------------------------------------------------
parent_disk_of_dev() {
    _d=$(readlink -f "$1" 2>/dev/null); [ -n "$_d" ] || _d="$1"
    _n=${_d##*/}; [ -n "$_n" ] || return 0
    # loop device -> resolve the backing file's disk
    if [ -f "/sys/class/block/$_n/loop/backing_file" ]; then
        _bf=$(cat "/sys/class/block/$_n/loop/backing_file" 2>/dev/null)
        if [ -n "$_bf" ]; then
            _src=$(df "$_bf" 2>/dev/null | awk 'NR>1{print $1; exit}')
            if [ -n "$_src" ] && [ "$_src" != "$_d" ]; then parent_disk_of_dev "$_src"; return 0; fi
        fi
    fi
    # device-mapper / mdraid -> first backing slave
    if [ -d "/sys/class/block/$_n/slaves" ]; then
        _sl=$(ls "/sys/class/block/$_n/slaves" 2>/dev/null | head -1)
        if [ -n "$_sl" ]; then parent_disk_of_dev "/dev/$_sl"; return 0; fi
    fi
    # partition -> parent disk is the sysfs dir that holds it
    if [ -f "/sys/class/block/$_n/partition" ]; then
        _pp=$(readlink -f "/sys/class/block/$_n" 2>/dev/null)
        _parent=$(basename "$(dirname "$_pp")" 2>/dev/null)
        if [ -n "$_parent" ] && [ "$_parent" != "block" ]; then echo "/dev/$_parent"; return 0; fi
    fi
    echo "/dev/$_n"
}

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
# list-devices disk yields whole disks only: /dev/nvme0n1, /dev/sda, ...
DISK_LIST=$(list-devices disk 2>/dev/null | sort -u)
[ -z "$DISK_LIST" ] && abort "no disks found by list-devices"

# The disk that holds the install media must never be a target. Resolve the
# media mount source robustly back to its parent whole disk (handles by-*,
# mapper, loop/Ventoy, plain partitions).
MEDIA_PART=$(awk '$2=="/cdrom"||$2=="/hd-media"||$2=="/run/live/medium"||$2=="/media/cdrom"{print $1; exit}' /proc/mounts 2>/dev/null)
MEDIA_DISK=""
[ -n "$MEDIA_PART" ] && MEDIA_DISK=$(parent_disk_of_dev "$MEDIA_PART")
[ -n "$MEDIA_DISK" ] && log "install media parent disk: $MEDIA_DISK (never a target)"

disk_size_h() {
    b=$(cat "/sys/block/${1##*/}/size" 2>/dev/null)
    [ -n "$b" ] && awk -v s="$b" 'BEGIN{printf "%.0fGB", s*512/1e9}' || echo "?"
}
disk_model() { cat "/sys/block/${1##*/}/device/model" 2>/dev/null | tr -d '\t\r\n' | sed 's/  */ /g; s/^ //; s/ $//; s/,/ /g' ; }

# Build the candidate list (whole disks, excluding the install medium).
CANDIDATES=""
NDISK=0
for d in $DISK_LIST; do
    [ -n "$MEDIA_DISK" ] && [ "$d" = "$MEDIA_DISK" ] && continue
    CANDIDATES="$CANDIDATES $d"
    NDISK=$((NDISK+1))
done
[ "$NDISK" -eq 0 ] && abort "no installable disk (only the install medium is present)"

# --- choose the target disk -------------------------------------------------
CHOSEN_DISK=""
if [ -n "$OVR_DISK" ]; then
    # Override MUST canonicalize to one of the enumerated whole-disk candidates.
    # This rejects partitions (/dev/sda1), arbitrary nodes, symlinks that don't
    # resolve to a candidate, and the install medium (excluded from CANDIDATES).
    _ov=$(readlink -f "$OVR_DISK" 2>/dev/null); [ -n "$_ov" ] || _ov="$OVR_DISK"
    _match=""
    for d in $CANDIDATES; do [ "$d" = "$_ov" ] && _match="$d" && break; done
    [ -n "$_match" ] || abort "ncz_disk=$OVR_DISK ($_ov) is not one of the whole-disk candidates:$CANDIDATES"
    CHOSEN_DISK="$_match"
    log "cmdline override: target disk = $CHOSEN_DISK (validated against candidate list)"
elif [ "$NDISK" -eq 1 ]; then
    # Exactly one candidate: no disk ambiguity. The fs prompt below still runs.
    CHOSEN_DISK=$(echo $CANDIDATES | awk '{print $1}')
    log "single installable disk present -> $CHOSEN_DISK"
else
    # Register a cdebconf select with the candidate /dev nodes as Choices, then
    # db_input at CRITICAL so it shows even under priority=critical. A cancel /
    # go-back / template failure ABORTS — we never auto-pick a disk to erase.
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
    debconf-loadtemplate ncz /tmp/ncz-disk.templates 2>/dev/null \
        || abort "could not load disk-selection template (no auto-pick on a destructive choice)"
    db_subst ncz/target-disk CHOICES "$CHOICES" 2>/dev/null
    db_fset  ncz/target-disk seen false 2>/dev/null
    db_settitle ncz/target-disk 2>/dev/null
    db_input critical ncz/target-disk 2>/dev/null
    if ! db_go; then
        abort "disk selection cancelled / backed out"
    fi
    db_get ncz/target-disk 2>/dev/null
    CHOSEN_DISK="$RET"
    [ -n "$CHOSEN_DISK" ] || abort "empty disk selection"
    # Defence in depth: the answer must still be one of the offered candidates.
    _ok=0; for d in $CANDIDATES; do [ "$d" = "$CHOSEN_DISK" ] && _ok=1 && break; done
    [ "$_ok" = 1 ] || abort "selected disk $CHOSEN_DISK is not in the candidate set"
fi
[ -b "$CHOSEN_DISK" ] || abort "chosen disk $CHOSEN_DISK is not a block device"
# It must be a WHOLE disk, not a partition (defence in depth vs override/answer).
[ -f "/sys/class/block/${CHOSEN_DISK##*/}/partition" ] && abort "chosen $CHOSEN_DISK is a partition, not a whole disk"
# Hard safety: refuse if the install media lives on the chosen disk.
if [ -n "$MEDIA_DISK" ] && [ "$MEDIA_DISK" = "$CHOSEN_DISK" ]; then
    abort "install media is on the target disk $CHOSEN_DISK"
fi

# --- choose the root filesystem --------------------------------------------
CHOSEN_FS=""
case "$OVR_FS" in
    ext4|btrfs) CHOSEN_FS="$OVR_FS"; log "cmdline override: root fs = $CHOSEN_FS" ;;
    "") : ;;
    *) abort "ncz_fs=$OVR_FS is not ext4 or btrfs" ;;
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
    debconf-loadtemplate ncz /tmp/ncz-fs.templates 2>/dev/null \
        || abort "could not load root-fs template"
    db_fset  ncz/root-fs seen false 2>/dev/null
    db_settitle ncz/root-fs 2>/dev/null
    db_input critical ncz/root-fs 2>/dev/null
    db_go || abort "root-fs selection cancelled / backed out"
    db_get ncz/root-fs 2>/dev/null
    CHOSEN_FS="$RET"
fi
case "$CHOSEN_FS" in ext4|btrfs) : ;; *) abort "invalid root fs '$CHOSEN_FS'" ;; esac
log "TARGET DISK = $CHOSEN_DISK   ROOT FS = $CHOSEN_FS"

# --- pin + VERIFY partman FIRST, then wipe (never wipe on an unproven pin) ---
# Root partition uses CHOSEN_FS; ESP (fat32) + rescue (ext4) are fixed, matching
# the static preseed recipe byte-for-byte.
RECIPE="cixmini :: \
  2048 2048 2048 fat32 \$primary{ } \$bootable{ } method{ efi } format{ } . \
  4096 4096 4096 ext4 \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } label{ NCZRESCUE } . \
  4096 8192 -1 $CHOSEN_FS \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ $CHOSEN_FS } mountpoint{ / } ."

db_set partman-auto/disk "$CHOSEN_DISK"      2>/dev/null || abort "db_set partman-auto/disk failed"
db_set partman-auto/expert_recipe "$RECIPE"  2>/dev/null || abort "db_set partman-auto/expert_recipe failed"
db_set partman-auto/choose_recipe cixmini    2>/dev/null || abort "db_set partman-auto/choose_recipe failed"
db_fset partman-auto/disk seen true          2>/dev/null || true
db_fset partman-auto/expert_recipe seen true 2>/dev/null || true
db_fset partman-auto/choose_recipe seen true 2>/dev/null || true

# VERIFY the pins actually stuck before we zero anything. A debconf hiccup must
# not leave a stale fallback recipe/disk in place while we erase the chosen disk.
db_get partman-auto/disk 2>/dev/null;          [ "$RET" = "$CHOSEN_DISK" ] || abort "partman-auto/disk did not pin to $CHOSEN_DISK (got '$RET')"
db_get partman-auto/choose_recipe 2>/dev/null; [ "$RET" = "cixmini" ]      || abort "partman-auto/choose_recipe did not pin to cixmini (got '$RET')"
db_get partman-auto/expert_recipe 2>/dev/null
case "$RET" in
    *"filesystem{ $CHOSEN_FS }"*"mountpoint{ / }"*) : ;;
    *) abort "partman-auto/expert_recipe did not pin the chosen root fs ($CHOSEN_FS)" ;;
esac
log "partman pins VERIFIED: disk=$CHOSEN_DISK recipe=cixmini root-fs=$CHOSEN_FS"

# --- ONLY NOW: prep the chosen disk (swapoff / unmount / wipe stale GPT) -----
# Replaces the OLD hardcoded /dev/nvme0n1 dd-zap. We wipe only the OPERATOR-
# CHOSEN, verified, pinned whole disk.
D="$CHOSEN_DISK"; base="${D##*/}"
awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep "^${D}" | while read _s; do swapoff "$_s" 2>/dev/null || true; done
awk -v dd="$D" '$1 ~ dd {print $2}' /proc/mounts 2>/dev/null | sort -r | while read _mp; do sync; umount "$_mp" 2>/dev/null || { sleep 1; umount "$_mp" 2>/dev/null || true; }; done
SZ=$(cat "/sys/block/$base/size" 2>/dev/null)
dd if=/dev/zero of="$D" bs=1M count=16 2>/dev/null
[ -n "$SZ" ] && dd if=/dev/zero of="$D" bs=512 seek=$((SZ-2048)) count=2048 2>/dev/null
sync; blockdev --rereadpt "$D" 2>/dev/null || true; udevadm settle 2>/dev/null || true
log "cleared stale GPT on $D (partman pins already verified)"

# stash the choices for later hooks / diagnostics
echo "$CHOSEN_DISK" > /tmp/ncz-target-disk 2>/dev/null || true
echo "$CHOSEN_FS"   > /tmp/ncz-root-fs 2>/dev/null || true
mkdir -p /target 2>/dev/null || true
log "chooser complete: disk=$CHOSEN_DISK root-fs=$CHOSEN_FS"
exit 0
