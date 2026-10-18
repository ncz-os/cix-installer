#!/bin/sh
# disk-fs-chooser.sh — NCZ installer interactive TARGET-DISK + ROOT-FILESYSTEM
# selection. Invoked from partman/early_command (see preseed.cfg).
#
# WHY a cdebconf menu (NOT whiptail): the install medium boots d-i at `priority=critical`
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
#
# ONCE PER BOOT: a completed run leaves $NCZ_TMP/.ncz-disk-done next to
# /tmp/ncz-target-disk + /tmp/ncz-root-fs. A later run (partman restarted,
# partman/early_command replayed) treats the saved, already-confirmed answers
# exactly like ncz_disk=/ncz_fs= presets: no dialog, but the same candidate
# validation, pin verification and wipe of that same disk. An aborted run
# leaves no marker, so backing out of the disk dialog still asks again.
set +e
NCZ_TMP="${NCZ_TMP:-/tmp}"
DONE="$NCZ_TMP/.ncz-disk-done"

. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || true
# shared NCZ dialog look (brand in the frame title, arch + build on the last body line); optional, never fatal
for _ncz_u in "${NCZ_UI_SH:-}" /ncz/ncz-ui.sh /cdrom/ncz-payload/ncz-ui.sh "$(dirname "$0")/ncz-ui.sh"; do
    [ -n "$_ncz_u" ] && [ -r "$_ncz_u" ] && . "$_ncz_u" && break
done
command -v ncz_ui_brand >/dev/null 2>&1 || { ncz_ui_brand() { echo "NCZ-OS"; }; ncz_ui_id() { echo ""; }; ncz_ui_step() { echo "[${1}/8] "; }; }

log() {
    echo "[ncz chooser] $*"
    # Progress chatter goes to VT3 (and the serial diag console); VT1/console is the
    # newt UI and raw lines written over it corrupt the screen. Failures stay visible.
    case "$*" in
        ABORT*|FATAL*|ERROR*) _vs="/dev/console /dev/tty1 /dev/tty3" ;;
        *) _vs="/dev/tty3" ;;
    esac
    for _v in $_vs; do
        echo "[ncz chooser] $*" > "$_v" 2>/dev/null || true
    done
}
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
CMD=$(cat "${NCZ_CMDLINE:-/proc/cmdline}" 2>/dev/null)
OVR_DISK=""; OVR_FS=""
for tok in $CMD; do
    case "$tok" in
        ncz_disk=*) OVR_DISK="${tok#ncz_disk=}" ;;
        ncz_fs=*)   OVR_FS="${tok#ncz_fs=}" ;;
    esac
done
REAPPLY=0
if [ -e "$DONE" ] && [ -s "$NCZ_TMP/ncz-target-disk" ] && [ -s "$NCZ_TMP/ncz-root-fs" ]; then
    OVR_DISK=$(cat "$NCZ_TMP/ncz-target-disk"); OVR_FS=$(cat "$NCZ_TMP/ncz-root-fs"); REAPPLY=1
    log "already answered this boot: re-applying disk=$OVR_DISK root-fs=$OVR_FS (no dialog)"
fi

# --- enumerate candidate disks ---------------------------------------------
# list-devices disk yields whole disks only: /dev/nvme0n1, /dev/sda, ...
DISK_LIST=$(list-devices disk 2>/dev/null | sort -u)
[ -z "$DISK_LIST" ] && abort "no disks found by list-devices"

# The disk that holds the install media must never be a target. Resolve the
# media mount source robustly back to its parent whole disk (handles by-*,
# mapper, loop/Ventoy, plain partitions).
#
# 2026-09-24: this used to take the FIRST of four conventional mountpoints
# that appeared in /proc/mounts, which is not the same question as "where is
# the payload". partman/early_command's own device search mounts candidate
# devices at /cdrom while hunting for this script, so /cdrom can easily be
# something unrelated while the real payload lives under /hd-media -- and then
# the disk protected from wiping is the wrong one, and the real install medium
# is offered as a target. Use the directory this script was actually FOUND in
# (NCZ_MEDIA_DIR, exported by partman/early_command; $0's own directory as a
# fallback) and resolve THAT to its mountpoint by longest-prefix match.
NCZ_MEDIA_DIR="${NCZ_MEDIA_DIR:-}"
if [ -z "$NCZ_MEDIA_DIR" ]; then
    case "$0" in
        */*) NCZ_MEDIA_DIR=$(dirname "$0") ;;
    esac
fi

MEDIA_PART=""
if [ -n "$NCZ_MEDIA_DIR" ] && [ -d "$NCZ_MEDIA_DIR" ]; then
    _mdir=$(readlink -f "$NCZ_MEDIA_DIR" 2>/dev/null); [ -n "$_mdir" ] || _mdir="$NCZ_MEDIA_DIR"
    _best=""; _bestlen=0
    while read -r _mdev _mmp _mrest; do
        [ "$_mmp" = "/" ] && continue
        case "$_mdir/" in
            "$_mmp"/*)
                _l=${#_mmp}
                if [ "$_l" -gt "$_bestlen" ]; then _bestlen=$_l; _best=$_mdev; fi
                ;;
        esac
    done < /proc/mounts
    MEDIA_PART="$_best"
    [ -n "$MEDIA_PART" ] && \
        log "install media resolved from the payload dir actually in use: $_mdir -> $MEDIA_PART"
fi
if [ -z "$MEDIA_PART" ]; then
    MEDIA_PART=$(awk '$2=="/cdrom"||$2=="/hd-media"||$2=="/run/live/medium"||$2=="/media/cdrom"{print $1; exit}' /proc/mounts 2>/dev/null)
    [ -n "$MEDIA_PART" ] && \
        log "WARNING: payload dir unknown; fell back to the first conventional media mountpoint -> $MEDIA_PART"
fi
MEDIA_DISK=""
if [ -n "$MEDIA_PART" ]; then
    MEDIA_DISK=$(parent_disk_of_dev "$MEDIA_PART")
    # FAIL-CLOSED: the install-media parent MUST resolve to one of the enumerated
    # whole-disk candidates (DISK_LIST). Anything else — empty, a loop/dm/md node
    # with no physical backing (Ventoy), /dev/root, or any pseudo/non-sysfs
    # source — means we cannot prove WHICH physical disk holds the medium, so we
    # refuse to offer ANY disk rather than risk offering the install/backing disk
    # as a wipe target. parent_disk_of_dev is best-effort; this DISK_LIST gate is
    # the authoritative fail-closed check.
    _mok=0
    for d in $DISK_LIST; do [ "$d" = "$MEDIA_DISK" ] && _mok=1 && break; done
    [ "$_mok" = 1 ] || abort "install media ($MEDIA_PART -> '${MEDIA_DISK:-unresolved}') did not resolve to an enumerated whole disk (fail-closed: refusing to offer any disk)"
    log "install media parent disk: $MEDIA_DISK (never a target)"
fi

disk_size_h() {
    b=$(cat "/sys/block/${1##*/}/size" 2>/dev/null)
    [ -n "$b" ] && awk -v s="$b" 'BEGIN{printf "%.0fGB", s*512/1e9}' || echo "?"
}
disk_model() { cat "/sys/block/${1##*/}/device/model" 2>/dev/null | tr -d '\t\r\n' | sed 's/  */ /g; s/^ //; s/ $//; s/,/ /g' ; }

# Disks holding an NCZ-OS image on a non-USB device (written by
# media-usb-only.sh when no USB installation drive was found). Such a disk is
# the disk the board may have booted from; it is never offered and never wiped.
NONUSB_MEDIA_FILE="${NCZ_NONUSB_MEDIA:-/tmp/ncz-nonusb-media}"
NONUSB_MEDIA_DISKS=""
[ -s "$NONUSB_MEDIA_FILE" ] && NONUSB_MEDIA_DISKS=$(cat "$NONUSB_MEDIA_FILE" 2>/dev/null)
is_nonusb_media_disk() {
    for _nm in $NONUSB_MEDIA_DISKS; do [ "$_nm" = "$1" ] && return 0; done
    return 1
}
[ -n "$NONUSB_MEDIA_DISKS" ] && log "disks holding an NCZ-OS image on a non-USB device (never a target): $NONUSB_MEDIA_DISKS"

# Build the candidate list (whole disks, excluding the install medium).
CANDIDATES=""
NDISK=0
for d in $DISK_LIST; do
    [ -n "$MEDIA_DISK" ] && [ "$d" = "$MEDIA_DISK" ] && continue
    is_nonusb_media_disk "$d" && continue
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
else
    # ALWAYS present the disk-selection screen (operator requirement 2026-07-04):
    # even with a SINGLE installable disk, show the target-disk chooser so the
    # operator sees + confirms the disk that will be ERASED *before* the fs
    # chooser. The old `elif NDISK==1` branch silently auto-picked the one disk
    # and skipped this db_input, so on metal (single nvme) only the root-fs
    # screen appeared and the operator never saw which disk was targeted. The
    # one disk is preselected as the default (so Enter accepts it); with several
    # disks the first is preselected and the operator must still confirm/pick.
    #
    # Register a cdebconf select with the candidate /dev nodes as Choices, then
    # db_input at CRITICAL so it shows even under priority=critical. A cancel /
    # go-back / template failure ABORTS — we never auto-pick a disk to erase.
    CHOICES=""
    LONG=""
    for d in $CANDIDATES; do
        desc="$(disk_model "$d") $(disk_size_h "$d")"
        [ -z "$CHOICES" ] && CHOICES="$d" || CHOICES="$CHOICES, $d"
        LONG="${LONG:+$LONG
 }  $d - $desc"   # continuation lines need their leading space; no trailing newline (a blank line ends a template stanza)
    done
    _first=$(echo $CANDIDATES | awk '{print $1}')
    cat > /tmp/ncz-disk.templates <<TPL
Template: ncz/target-disk
Type: select
Choices: ${CHOICES}
Description: $(ncz_ui_step 6)$(ncz_ui_brand) - select the TARGET DISK (it will be ERASED)
 The disk you choose will be COMPLETELY ERASED and NCZ-OS installed on it.
 .
 Detected disks:
 ${LONG}
 .
 $(ncz_ui_id)
TPL
    debconf-loadtemplate ncz /tmp/ncz-disk.templates 2>/dev/null \
        || abort "could not load disk-selection template (no auto-pick on a destructive choice)"
    # Every db_* on the pre-wipe path is checked; any failure ABORTS. In
    # particular db_input!=0 means the prompt would NOT be displayed (skipped) —
    # a destructive choice must never proceed on a prompt the operator never saw.
    db_subst ncz/target-disk CHOICES "$CHOICES" || abort "db_subst target-disk failed"
    # Preselect the first candidate as the current value so the select opens on
    # it (the ONLY choice when NDISK==1; the top choice when NDISK>1). db_set
    # does NOT flip `seen`, so the question is still SHOWN.
    db_set   ncz/target-disk "$_first" 2>/dev/null || true
    db_fset  ncz/target-disk seen false        || abort "db_fset target-disk seen failed"
    db_settitle ncz/target-disk 2>/dev/null
    db_input critical ncz/target-disk          || abort "disk-selection prompt could not be displayed (db_input rc=$?)"
    db_go || abort "disk selection cancelled / backed out"
    db_get ncz/target-disk || abort "db_get target-disk failed"
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
if is_nonusb_media_disk "$CHOSEN_DISK"; then
    abort "the target disk $CHOSEN_DISK holds the NCZ-OS installer image; install from a USB drive instead"
fi

# --- choose the root filesystem --------------------------------------------
CHOSEN_FS=""
case "$OVR_FS" in
    ext4|btrfs) CHOSEN_FS="$OVR_FS"; log "cmdline override: root fs = $CHOSEN_FS" ;;
    "") : ;;
    *) abort "ncz_fs=$OVR_FS is not ext4 or btrfs" ;;
esac
if [ -z "$CHOSEN_FS" ]; then
    cat > /tmp/ncz-fs.templates <<TPL
Template: ncz/root-fs
Type: select
Choices: btrfs, ext4
Default: btrfs
Description: $(ncz_ui_step 7)$(ncz_ui_brand) - root (/) filesystem
 Choose the filesystem for the root (/) partition.
 .
 btrfs - snapshots + transparent compression (NCZ default).
 ext4  - simple, maximally robust.
 .
 $(ncz_ui_id)
TPL
    debconf-loadtemplate ncz /tmp/ncz-fs.templates 2>/dev/null \
        || abort "could not load root-fs template"
    db_fset  ncz/root-fs seen false || abort "db_fset root-fs seen failed"
    db_settitle ncz/root-fs 2>/dev/null
    db_input critical ncz/root-fs   || abort "root-fs prompt could not be displayed (db_input rc=$?)"
    db_go || abort "root-fs selection cancelled / backed out"
    db_get ncz/root-fs || abort "db_get root-fs failed"
    CHOSEN_FS="$RET"
fi
case "$CHOSEN_FS" in ext4|btrfs) : ;; *) abort "invalid root fs '$CHOSEN_FS'" ;; esac
log "TARGET DISK = $CHOSEN_DISK   ROOT FS = $CHOSEN_FS"

# --- interactive only: an unmistakable review + confirmation before ANYTHING is erased -----------------------------
# The operator picked a disk and/or filesystem in a dialog (no ncz_disk=/ncz_fs= preset), so show what is about to
# happen and require an explicit Yes; declining stops the install with nothing touched. Presets (unattended runs, the
# KVM gate) skip this and only log.
if [ -z "$OVR_DISK" ] || [ -z "$OVR_FS" ]; then
    _ncz_sel=$(tr -d ' \t\r\n' < /tmp/ncz-components 2>/dev/null || true)
    # Same rule as the recipe below (a readable record decides; only a missing one means "yes"), so this screen never
    # promises a rescue partition the recipe drops, or the reverse.
    if [ -r /tmp/ncz-components ]; then
        case ",$_ncz_sel," in *",rescue-partition,"*) _ncz_resc=yes ;; *) _ncz_resc=no ;; esac
    else
        _ncz_resc=yes
    fi
    cat > /tmp/ncz-confirm.templates <<TPL
Template: ncz/confirm-erase
Type: boolean
Default: false
Description: $(ncz_ui_step 8)$(ncz_ui_brand) - ERASE ${CHOSEN_DISK} and install?
 Please review your choices:
 .
   Target disk:       ${CHOSEN_DISK}
   Root filesystem:   ${CHOSEN_FS}
   Rescue partition:  ${_ncz_resc}
   Components:        ${_ncz_sel:-all}
 .
 CONTINUING ERASES EVERYTHING ON ${CHOSEN_DISK}. This cannot be undone.
 .
 $(ncz_ui_id)
TPL
    debconf-loadtemplate ncz /tmp/ncz-confirm.templates 2>/dev/null || abort "could not load the erase-confirmation template (never erase without asking)"
    db_set   ncz/confirm-erase false 2>/dev/null || true
    db_fset  ncz/confirm-erase seen false || abort "db_fset confirm-erase seen failed"
    db_settitle ncz/confirm-erase 2>/dev/null
    db_input critical ncz/confirm-erase || abort "erase confirmation could not be displayed (db_input rc=$?)"
    db_go || abort "erase confirmation cancelled / backed out"
    db_get ncz/confirm-erase || abort "db_get confirm-erase failed"
    [ "$RET" = true ] || abort "the operator did not confirm erasing $CHOSEN_DISK"
    log "operator CONFIRMED erasing $CHOSEN_DISK"
elif [ "$REAPPLY" = 1 ]; then
    log "re-run: erasing $CHOSEN_DISK again (confirmed by the operator earlier this boot)"
else
    log "unattended: erasing $CHOSEN_DISK (ncz_disk=/ncz_fs= preset)"
fi

# --- pin + VERIFY partman FIRST, then wipe (never wipe on an unproven pin) ---
# Root partition uses CHOSEN_FS; ESP (fat32) + rescue (ext4) are fixed, matching
# the static preseed recipe byte-for-byte.
#
# r303: install-time component toggle (see preseed/component-selector.sh) —
# the operator may have opted out of the NCZRESCUE partition. When that's the
# case we build a 2-stanza recipe (ESP + root) instead of the 3-stanza one. The
# fail-closed verification (root-stanza check, byte-identical round-trip) is
# UNCHANGED for both paths — only the recipe string we build differs.
WANT_RESCUE_PART=1
if [ -r /tmp/ncz-components ]; then
    _ck=$(tr -d ' \t\r\n' < /tmp/ncz-components 2>/dev/null || true)
    case ",$_ck," in
        *",rescue-partition,"*) WANT_RESCUE_PART=1 ;;
        *)                       WANT_RESCUE_PART=0 ;;
    esac
fi
if [ "$WANT_RESCUE_PART" = 1 ]; then
    RECIPE="cixmini :: \
  2048 2048 2048 fat32 \$primary{ } \$bootable{ } method{ efi } format{ } . \
  4096 4096 4096 ext4 \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } label{ NCZRESCUE } . \
  4096 8192 -1 $CHOSEN_FS \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ $CHOSEN_FS } mountpoint{ / } ."
    log "recipe: 3-stanza (ESP + NCZRESCUE + root) — rescue-partition toggle ON"
else
    RECIPE="cixmini :: \
  2048 2048 2048 fat32 \$primary{ } \$bootable{ } method{ efi } format{ } . \
  4096 8192 -1 $CHOSEN_FS \$primary{ } method{ format } format{ } use_filesystem{ } filesystem{ $CHOSEN_FS } mountpoint{ / } ."
    log "recipe: 2-stanza (ESP + root) — rescue-partition toggle OFF (component-selector)"
fi

# Every db_* here is checked; any failure ABORTS before the dd.
db_set  partman-auto/disk "$CHOSEN_DISK"      || abort "db_set partman-auto/disk failed"
db_set  partman-auto/expert_recipe "$RECIPE"  || abort "db_set partman-auto/expert_recipe failed"
db_set  partman-auto/choose_recipe cixmini    || abort "db_set partman-auto/choose_recipe failed"
db_fset partman-auto/disk seen true           || abort "db_fset partman-auto/disk seen failed"
db_fset partman-auto/expert_recipe seen true  || abort "db_fset partman-auto/expert_recipe seen failed"
db_fset partman-auto/choose_recipe seen true  || abort "db_fset partman-auto/choose_recipe seen failed"

# VERIFY the pins actually stuck before we zero anything. A debconf hiccup must
# not leave a stale fallback recipe/disk in place while we erase the chosen disk.
db_get partman-auto/disk || abort "db_get partman-auto/disk failed"
[ "$RET" = "$CHOSEN_DISK" ] || abort "partman-auto/disk did not pin to $CHOSEN_DISK (got '$RET')"
db_get partman-auto/choose_recipe || abort "db_get partman-auto/choose_recipe failed"
[ "$RET" = "cixmini" ] || abort "partman-auto/choose_recipe did not pin to cixmini (got '$RET')"
db_get partman-auto/expert_recipe || abort "db_get partman-auto/expert_recipe failed"
_pinned_recipe="$RET"
[ -n "$_pinned_recipe" ] || abort "partman-auto/expert_recipe read back EMPTY"
# ROOT-STANZA-SPECIFIC verification (review #5): a plain substring test for
# `filesystem{ $CHOSEN_FS }` is UNSAFE — the RESCUE partition stanza always
# carries `filesystem{ ext4 }`, so with CHOSEN_FS=ext4 a stale/failed pin (e.g.
# the static btrfs-root fallback recipe) would falsely pass. Isolate the
# ` . `-delimited stanza that mounts / (the ONLY partition dots in the recipe
# are the ` . ` separators) and require ITS filesystem to be exactly CHOSEN_FS.
_root_stanza=""
_oldifs=$IFS; IFS='.'
for _st in $_pinned_recipe; do
    case "$_st" in *"mountpoint{ / }"*) _root_stanza="$_st" ;; esac
done
IFS=$_oldifs
[ -n "$_root_stanza" ] || abort "pinned expert_recipe has no root (mountpoint / ) stanza"
case "$_root_stanza" in
    *"filesystem{ $CHOSEN_FS }"*) : ;;
    *) abort "pinned ROOT stanza filesystem is not $CHOSEN_FS — refusing to wipe (root stanza: [$_root_stanza])" ;;
esac
# STRICT EXACT COMPARE (review round-3 #1): the pinned recipe must be
# byte-identical to the recipe WE set. The root-stanza check above proves the
# root fs, but a stale `cixmini` recipe with the SAME root fs (e.g. differing
# only in the ESP/rescue stanzas) would still pass it; exact equality is the real
# guarantee that partman will use OUR recipe and nothing else. If this fails we
# abort and wipe nothing.
[ "$_pinned_recipe" = "$RECIPE" ] || abort "pinned expert_recipe is not byte-identical to the recipe we set (stale/failed pin) — refusing to wipe"
log "partman pins VERIFIED (exact recipe match): disk=$CHOSEN_DISK recipe=cixmini root-fs=$CHOSEN_FS"

# --- ONLY NOW: prep the chosen disk (swapoff / unmount / wipe stale GPT) -----
# Replaces the OLD hardcoded /dev/nvme0n1 dd-zap. We wipe only the OPERATOR-
# CHOSEN, verified, pinned whole disk.
# A visible step: the erase is destructive and used to happen with a blank screen. A debconf progress bar names the disk.
_ncz_prog=0
cat > /tmp/ncz-erase.templates <<TPL
Template: ncz/erase-title
Type: text
Description: $(ncz_ui_brand) - erasing ${CHOSEN_DISK}

Template: ncz/erase-info
Type: text
Description: \${STEP}
TPL
if debconf-loadtemplate ncz /tmp/ncz-erase.templates 2>/dev/null && db_progress START 0 3 ncz/erase-title 2>/dev/null; then
    _ncz_prog=1
fi
ncz_step() {   # n text
    [ "$_ncz_prog" = 1 ] || return 0
    db_subst ncz/erase-info STEP "$2" 2>/dev/null || true
    db_progress INFO ncz/erase-info 2>/dev/null || true
    db_progress SET "$1" 2>/dev/null || true
}
ncz_step 0 "ERASING $CHOSEN_DISK: stopping swap and unmounting"
D="$CHOSEN_DISK"; base="${D##*/}"
awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep "^${D}" | while read _s; do swapoff "$_s" 2>/dev/null || true; done
awk -v dd="$D" '$1 ~ dd {print $2}' /proc/mounts 2>/dev/null | sort -r | while read _mp; do sync; umount "$_mp" 2>/dev/null || { sleep 1; umount "$_mp" 2>/dev/null || true; }; done
ncz_step 1 "ERASING $CHOSEN_DISK: clearing the old partition table"
SZ=$(cat "/sys/block/$base/size" 2>/dev/null)
dd if=/dev/zero of="$D" bs=1M count=16 2>/dev/null
[ -n "$SZ" ] && dd if=/dev/zero of="$D" bs=512 seek=$((SZ-2048)) count=2048 2>/dev/null
sync; blockdev --rereadpt "$D" 2>/dev/null || true; udevadm settle 2>/dev/null || true
log "cleared stale GPT on $D (partman pins already verified)"
ncz_step 3 "$CHOSEN_DISK erased; the installer continues"
[ "$_ncz_prog" = 1 ] && db_progress STOP 2>/dev/null

# stash the choices for later hooks / diagnostics
echo "$CHOSEN_DISK" > "$NCZ_TMP/ncz-target-disk" 2>/dev/null || true
echo "$CHOSEN_FS"   > "$NCZ_TMP/ncz-root-fs" 2>/dev/null || true
echo "$WANT_RESCUE_PART" > "$NCZ_TMP/ncz-want-rescue-partition" 2>/dev/null || true
: > "$DONE"
mkdir -p /target 2>/dev/null || true
log "chooser complete: disk=$CHOSEN_DISK root-fs=$CHOSEN_FS rescue-partition=$WANT_RESCUE_PART"
exit 0
