#!/bin/bash
# kvm-install-gate-amd64-fixed.sh -- F-retained-fixes (dispatch 2b) analogue
# of build/kvm-install-gate-amd64.sh. Same 2-phase design, but the input is
# the upstream Debian Forky amd64 netinst *after* the same d-i hand-patches
# build-iso-di.sh applies to the substrate's udeb pool + initrd. This is the
# "identical artifact + whatever amd64-specific d-i hand-patches currently
# exist in build-iso-di.sh" candidate from the dispatch brief.
#
# What we replicate from build/build-iso-di.sh (the GENERIC d-i patches, all
# arch-agnostic — there are NO amd64-specific initrd/kernel hand-patches in
# build-iso-di.sh per review §4 / §2.1):
#
#   * neutralize_udeb_postinst on flash-kernel-installer, grub-installer,
#     nobootloader (lines 1996–2045 of build-iso-di.sh) -- rEFInd installs
#     via post-install/70-bootloader.sh from late_command, not via the
#     d-i "Make the system bootable" menu step
#   * brand_udeb_templates on main-menu, finish-install, choose-mirror
#     (lines 2055–2103) -- "Debian installer main menu" → "NCZ-OS
#     installer main menu" etc.
#   * patch_disk_detect_wait on hw-detect/disk-detect (lines 2106–2273) --
#     extends the stock 15×2s wait to 90 settled attempts and adds nvme
#     module listing + prime_storage_detection call
#   * prime_storage_detection (inside the disk-detect patch above) --
#     early modprobe of nvme/nvme-core/virtio_blk/sd_mod/ahci
#   * patch_finish_install_progress_owner (lines 2297–2395) -- allocates
#     100 owned progress units to 07preseed/late_command
#   * Generic firmware overlay (lines 2947–2985) -- iwlwifi + rtl_nic
#     cpio-appended onto install.amd/initrd.gz (added 2026-09-20 to fix
#     the PEGASUS/ASUS ROG Zephyrus hw-detect-stall-on-AX201 issue that
#     was specifically AMD64-affecting)
#   * rEFInd-on-both-arches (added post-install/70-bootloader.sh flow)
#     is post-install, NOT installer, so it does NOT apply to the install
#     gate; but the installed-disk-assert.sh rescue-entry check IS what
#     makes the rEFInd install visible in phase 2.
#
# What we DELIBERATELY omit (the things that build-iso-di.sh does that are
# NOT d-i hand-patches, and would require the full NCZ pipeline assets
# not present in this clone):
#
#   * The full NCZ post-install layer (post-install/*.sh) -- no
#     rescue-rootfs, no base.squashfs, no desktop.squashfs, no 10-our-kernel
#     / 70-bootloader etc. These are post-install hooks and would require
#     the full NCZ target to be installed, not just the d-i environment.
#   * The bookworm→trixie debootstrap/libzstd/liblzma graft (already
#     gated on DI_CODENAME=bookworm; this substrate is Forky so the graft
#     doesn't run anyway, per the existing build-iso-di.sh line 1021 check).
#   * The Sky1/arm64 installer-kernel swap (per review §2.1: amd64 KEEPS
#     the substrate installer kernel; arm64 replaces it with Sky1
#     artifacts. This IS the architectural difference the dispatch brief
#     explicitly flagged.)
#
# In short: F-retained-fixes = upstream Forky d-i + the GENERIC
# d-i hand-patches build-iso-di.sh applies, applied directly. There are no
# amd64-specific initrd/kernel hand-patches to retain or remove.
set -euo pipefail

ISO="${1:?usage: kvm-install-gate-amd64-fixed.sh STOCK_FORKY_AMD64_ISO [WORKDIR]}"
WORK="${2:-$HOME/kvm-install-amd64-fixed}"
DISK_GB="${DISK_GB:-30}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-5400}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
MEM="${MEM:-4096}"
SMP="${SMP:-4}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$WORK"
DISK="$WORK/target.qcow2"
VARS="$WORK/OVMF_VARS.fd"
CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[ -f "$CODE" ] || CODE=/usr/share/OVMF/OVMF_CODE.fd
SRCVARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -f "$SRCVARS" ] || SRCVARS=/usr/share/OVMF/OVMF_VARS.fd

ACCEL="tcg"; CPU="qemu64"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; CPU="host"; fi
sudo -n chmod a+rw /dev/kvm 2>/dev/null || true

QEMU_ISO="${ISO%.iso}-fixed-qemutest.iso"
QEMU_STAGE="$WORK/iso-patch"
rm -rf "$QEMU_STAGE" "$QEMU_ISO"
mkdir -p "$QEMU_STAGE/staging"

echo "[1/6] extracting $ISO -> $QEMU_STAGE/staging"
xorriso -osirrox on -indev "$ISO" -extract . "$QEMU_STAGE/staging" >/dev/null 2>&1 \
  || { echo "GATE FAIL: xorriso extract of $ISO failed"; exit 2; }
chmod -R u+w "$QEMU_STAGE/staging"

STAGING="$QEMU_STAGE/staging"

# Run the same generic d-i patches build-iso-di.sh would run for the
# substrate's udeb pool + initrd. These are arch-agnostic; we just
# invoke build/build-iso-di.sh's logic directly.
echo "[2/6] applying generic d-i hand-patches (udeb pool + initrd)"

# A. neutralize_udeb_postinst — stub the bootloader postinsts so d-i's
# "Make the system bootable" menu step is a no-op (rEFInd installs via
# post-install/70-bootloader.sh in late_command instead).
for label_pair in \
    "f/flash-kernel:flash-kernel-installer" \
    "g/grub-installer:grub-installer" \
    "n/nobootloader:nobootloader"; do
    dir="${label_pair%%:*}"
    label="${label_pair##*:}"
    matches=( $STAGING/pool/main/$dir/${label}_*.udeb )
    udeb="${matches[0]:-}"
    [ -n "$udeb" ] && [ -e "$udeb" ] || { echo "    NOTE: $label udeb not in pool — nothing to neutralize"; continue; }
    _tmp="$STAGING/.tmp-neutralize-$label"
    _ar="$_tmp/ar" _ctl="$_tmp/ctl"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_ctl"
    ( cd "$_ar" && ar x "$(readlink -f "$udeb")" )
    ctl_members=( "$_ar"/control.tar* )
    data_members=( "$_ar"/data.tar* )
    ctl_member="$(basename "${ctl_members[0]}")"
    data_member="$(basename "${data_members[0]}")"
    tar -xf "$_ar/$ctl_member" -C "$_ctl"
    [ -f "$_ctl/postinst" ] || { echo "    NOTE: $label udeb has no postinst"; rm -rf "$_tmp"; continue; }
    cat > "$_ctl/postinst" <<GIPOST
#! /bin/sh -e
# dispatch 2b F-retained-fixes stub $label postinst — d-i "Make the system
# bootable" no-op. rEFInd is installed by post-install/70-bootloader.sh
# from late_command. Always succeed so the install completes.
logger -t $label "ncz stub: skipping bootable step — rEFInd installed by 70-bootloader.sh" 2>/dev/null || true
exit 0
GIPOST
    chmod 0755 "$_ctl/postinst"
    bash -n "$_ctl/postinst"
    rm -f "$_ar/$ctl_member"
    ( cd "$_ctl" && tar --numeric-owner --owner=0 --group=0 -cf - . ) | gzip -9n > "$_ar/control.tar.gz"
    new_udeb="$_tmp/$(basename "$udeb")"
    ( cd "$_ar" && ar rc "$new_udeb" debian-binary control.tar.gz "$data_member" )
    mv "$new_udeb" "$udeb"
    rm -rf "$_tmp"
    echo "    $label neutralized"
done

# B. brand_udeb_templates — substitute "Debian installer" → "NCZ-OS installer"
# in the udeb templates files.
for label_pair in \
    "m/main-menu:main-menu" \
    "f/finish-install:finish-install" \
    "c/choose-mirror:choose-mirror"; do
    dir="${label_pair%%:*}"
    label="${label_pair##*:}"
    matches=( $STAGING/pool/main/$dir/${label}_*.udeb )
    udeb="${matches[0]:-}"
    [ -n "$udeb" ] && [ -e "$udeb" ] || { echo "    NOTE: $label udeb not in pool — nothing to brand"; continue; }
    _tmp="$STAGING/.tmp-brand-$label"
    _ar="$_tmp/ar" _ctl="$_tmp/ctl"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_ctl"
    ( cd "$_ar" && ar x "$(readlink -f "$udeb")" )
    ctl_members=( "$_ar"/control.tar* )
    data_members=( "$_ar"/data.tar* )
    ctl_member="$(basename "${ctl_members[0]}")"
    data_member="$(basename "${data_members[0]}")"
    tar -xf "$_ar/$ctl_member" -C "$_ctl"
    [ -f "$_ctl/templates" ] || { echo "    NOTE: $label udeb has no templates — skipping brand"; rm -rf "$_tmp"; continue; }
    sed -i \
        -e 's/Debian installer main menu/NCZ-OS installer main menu/g' \
        -e 's/Debian GNU\/Linux Installer menu/NCZ-OS installer menu/g' \
        -e 's/Debian GNU\/Linux installer main menu/NCZ-OS installer main menu/g' \
        -e 's/Debian GNU\/Linux/NCZ-OS/g' \
        -e 's/the Debian installer/the NCZ-OS installer/g' \
        -e 's/Debian installer/NCZ-OS installer/g' \
        "$_ctl/templates"
    rm -f "$_ar/$ctl_member"
    ( cd "$_ctl" && tar --numeric-owner --owner=0 --group=0 -cf - . ) | gzip -9n > "$_ar/control.tar.gz"
    new_udeb="$_tmp/$(basename "$udeb")"
    ( cd "$_ar" && ar rc "$new_udeb" debian-binary control.tar.gz "$data_member" )
    mv "$new_udeb" "$udeb"
    rm -rf "$_tmp"
    echo "    $label udeb templates NCZ-branded"
done

# C. patch_disk_detect_wait — the verbatim python heredoc from
# build-iso-di.sh lines 2106–2273. Replicated here to avoid the full
# build-iso-di.sh orchestration (mirror, kernel-swap, etc.). Apply via
# a temp python script.
TMP_PY="$WORK/.dispatch2b-disk-detect-patch.py"
cat > "$TMP_PY" <<'PYDISK'
import sys, os, re
path = sys.argv[1]
src = open(path).read()

old = '''disk_found() {
\tfor try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
\t\tif search-path parted_devices; then
\t\t\t# Use partman's parted_devices if available.
\t\t\tif [ -n "$(parted_devices)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\telse
\t\t\t# Essentially the same approach used by partitioner and
\t\t\t# autopartkit to find their disks.
\t\t\tif [ -n "$(list-devices disk)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\tfi

\t\t# Wait for disk to be activated.
\t\tif [ "$try" != 15 ]; then
\t\t\tsleep 2
\t\tfi
\tdone

\treturn 1
}'''

new = '''disk_found() {
\tmax_tries="${NCZ_DISK_DETECT_TRIES:-90}"
\tcase "$max_tries" in *[!0-9]*|'') max_tries=90 ;; esac
\t[ "$max_tries" -lt 15 ] && max_tries=15

\ttry=1
\twhile [ "$try" -le "$max_tries" ]; do
\t\t# Give udev a chance to publish slow storage devices before asking
\t\t# partman/list-devices. update-dev is the d-i wrapper used elsewhere
\t\t# in hw-detect before probing for newly-created device nodes.
\t\tudevadm settle --timeout=10 >/dev/null 2>&1 || true
\t\tupdate-dev >/dev/null 2>&1 || true

\t\tif search-path parted_devices; then
\t\t\t# Use partman's parted_devices if available.
\t\t\tif [ -n "$(parted_devices)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\telse
\t\t\t# Essentially the same approach used by partitioner and
\t\t\t# autopartkit to find their disks.
\t\t\tif [ -n "$(list-devices disk)" ]; then
\t\t\t\treturn 0
\t\t\tfi
\t\tfi

\t\t# Wait for disk to be activated. Stock d-i only waited ~30s
\t\t# (15 attempts * 2s); Sky1 NVMe enumeration can exceed that.
\t\tif [ "$try" != "$max_tries" ]; then
\t\t\tlogger -t disk-detect "no disk yet after attempt $try/$max_tries; waiting for storage enumeration"
\t\t\tsleep 2
\t\tfi
\t\ttry=$((try + 1))
\tdone

\treturn 1
}'''

if src.count(old) != 1:
    print(f"disk-detect patch drift: expected one disk_found anchor, found {src.count(old)}", file=sys.stderr)
    sys.exit(1)
src = src.replace(old, new)

if src.count('list_modules_dir /lib/modules/*/kernel/drivers/nvme/host') != 0:
    print("disk-detect patch drift: nvme module directory already present", file=sys.stderr)
    sys.exit(1)
src = src.replace(
'''\tlist_modules_dir /lib/modules/*/kernel/drivers/block
\tlist_modules_dir /lib/modules/*/kernel/drivers/message/fusion''',
'''\tlist_modules_dir /lib/modules/*/kernel/drivers/block
\tlist_modules_dir /lib/modules/*/kernel/drivers/nvme/host
\tlist_modules_dir /lib/modules/*/kernel/drivers/message/fusion''',
1,
)
if src.count('list_modules_dir /lib/modules/*/kernel/drivers/nvme/host') != 1:
    print("disk-detect patch drift: failed to add nvme module directory", file=sys.stderr)
    sys.exit(1)

if src.count('prime_storage_detection') != 0:
    print("disk-detect patch drift: storage priming already present", file=sys.stderr)
    sys.exit(1)
src = src.replace(
'''multipath_probe() {
\tMP_VERBOSE=2
\t# Look for multipaths...
\tif [ ! -f /etc/multipath.conf ]; then
\t\tcat <<EOF >/etc/multipath.conf
defaults {
    user_friendly_names yes
}
EOF
\tfi
\tlog-output -t disk-detect /usr/sbin/multipath -v$MP_VERBOSE

\tif multipath -l 2>/dev/null | grep -q '^mpath[a-z]\\+ '; then
\t\treturn 0
\telse
\t\treturn 1
\tfi
}

if ! hw-detect disk-detect/detect_progress_title; then''',
'''multipath_probe() {
\tMP_VERBOSE=2
\t# Look for multipaths...
\tif [ ! -f /etc/multipath.conf ]; then
\t\tcat <<EOF >/etc/multipath.conf
defaults {
    user_friendly_names yes
}
EOF
\tfi
\tlog-output -t disk-detect /usr/sbin/multipath -v$MP_VERBOSE

\tif multipath -l 2>/dev/null | grep -q '^mpath[a-z]\\+ '; then
\t\treturn 0
\telse
\t\treturn 1
\tfi
}

prime_storage_detection() {
\tfor module in nvme nvme-core virtio_blk sd_mod ahci; do
\t\tif is_not_loaded "$module"; then
\t\t\tlog "preloading storage module $module before hw-detect"
\t\t\tlog-output -t disk-detect modprobe -v "$module" || true
\t\tfi
\tdone
\tudevadm trigger --subsystem-match=block --action=add >/dev/null 2>&1 || true
\tudevadm settle --timeout=10 >/dev/null 2>&1 || true
\tupdate-dev >/dev/null 2>&1 || true
}

\tprime_storage_detection
\tif ! hw-detect disk-detect/detect_progress_title; then''',
1,
)
if src.count('prime_storage_detection') != 2:
    print("disk-detect patch drift: failed to add storage priming", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(src)
PYDISK

matches=( $STAGING/pool/main/h/hw-detect/disk-detect_*.udeb )
dd_udeb="${matches[0]:-}"
if [ -n "$dd_udeb" ] && [ -e "$dd_udeb" ]; then
    _tmp="$STAGING/.tmp-disk-detect-udeb"
    _ar="$_tmp/ar" _data="$_tmp/data"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_data"
    ( cd "$_ar" && ar x "$(readlink -f "$dd_udeb")" )
    ctl_members=( "$_ar"/control.tar* )
    data_members=( "$_ar"/data.tar* )
    ctl_member="$(basename "${ctl_members[0]}")"
    data_member="$(basename "${data_members[0]}")"
    tar -xf "$_ar/$data_member" -C "$_data"
    [ -f "$_data/usr/bin/disk-detect" ] || { echo "ERROR: disk-detect udeb missing usr/bin/disk-detect" >&2; exit 1; }
    python3 "$TMP_PY" "$_data/usr/bin/disk-detect"
    chmod 0755 "$_data/usr/bin/disk-detect"
    sh -n "$_data/usr/bin/disk-detect"
    rm -f "$_ar/$data_member"
    ( cd "$_data" && tar --numeric-owner --owner=0 --group=0 -cf - . ) | gzip -9n > "$_ar/data.tar.gz"
    new_udeb="$_tmp/$(basename "$dd_udeb")"
    ( cd "$_ar" && ar rc "$new_udeb" debian-binary "$ctl_member" data.tar.gz )
    mv "$new_udeb" "$dd_udeb"
    rm -rf "$_tmp"
    echo "    disk-detect udeb: preloads storage modules and extends disk_found wait to 90 settled attempts"
else
    echo "    WARN: disk-detect udeb not in pool -- skipped (this would be a hard fail in build-iso-di.sh)"
fi
rm -f "$TMP_PY"

# D. patch_finish_install_progress_owner — verbatim from build-iso-di.sh
# lines 2297–2395. Same approach: extract udeb, run a python heredoc,
#repack.
TMP_PY2="$WORK/.dispatch2b-finish-progress-patch.py"
cat > "$TMP_PY2" <<'PYFINISH'
import sys
path = sys.argv[1]
src = open(path).read()

old_count = 'scriptcount=$(ls "$partsdir"/* | wc -l)'
new_count = '''scriptcount=$(ls "$partsdir"/* | wc -l)
ncz_preseed_script="$partsdir/07preseed"
ncz_progress_units=100
if [ -x "$ncz_preseed_script" ]; then
\tscriptcount=$((scriptcount + ncz_progress_units - 1))
fi'''

old_loop = '''for script in "$partsdir"/*; do
\tbase=$(basename $script | sed 's/[0-9]*//')'''
new_loop = '''for script in "$partsdir"/*; do
\tncz_progress_child=0
\tif [ "$script" = "$ncz_preseed_script" ]; then
\t\tncz_progress_child=1
\t\tNCZ_PROGRESS_UNITS=$ncz_progress_units
\t\tNCZ_PROGRESS_CONSUMED_FILE="/tmp/ncz-finish-progress.$$"
\t\tprintf '0\\n' > "$NCZ_PROGRESS_CONSUMED_FILE"
\t\texport NCZ_PROGRESS_UNITS NCZ_PROGRESS_CONSUMED_FILE
\tfi
\tbase=$(basename $script | sed 's/[0-9]*//')'''

old_step = '''\tdb_progress STEP 1
done'''
new_step = '''\tif [ "$ncz_progress_child" = 1 ]; then
\t\tncz_consumed=$(cat "$NCZ_PROGRESS_CONSUMED_FILE" 2>/dev/null || echo 0)
\t\tcase "$ncz_consumed" in *[!0-9]*|'') ncz_consumed=0 ;; esac
\t\t[ "$ncz_consumed" -gt "$ncz_progress_units" ] && ncz_consumed=$ncz_progress_units
\t\tncz_remaining=$((ncz_progress_units - ncz_consumed))
\t\t[ "$ncz_remaining" -gt 0 ] && db_progress STEP "$ncz_remaining"
\t\trm -f "$NCZ_PROGRESS_CONSUMED_FILE"
\t\tunset NCZ_PROGRESS_UNITS NCZ_PROGRESS_CONSUMED_FILE
\telse
\t\tdb_progress STEP 1
\tfi
done'''

for name, old, new in (
    ("script count", old_count, new_count),
    ("07preseed allocation", old_loop, new_loop),
    ("owned step completion", old_step, new_step),
):
    if src.count(old) != 1:
        print(f"finish-install patch drift: expected one {name} anchor, found {src.count(old)}", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old, new)
open(path, "w").write(src)
PYFINISH

matches=( $STAGING/pool/main/f/finish-install/finish-install_*.udeb )
fi_udeb="${matches[0]:-}"
if [ -n "$fi_udeb" ] && [ -e "$fi_udeb" ]; then
    _tmp="$STAGING/.tmp-finish-progress-udeb"
    _ar="$_tmp/ar" _ctl="$_tmp/ctl"
    rm -rf "$_tmp"; mkdir -p "$_ar" "$_ctl"
    ( cd "$_ar" && ar x "$(readlink -f "$fi_udeb")" )
    ctl_members=( "$_ar"/control.tar* )
    data_members=( "$_ar"/data.tar* )
    ctl_member="$(basename "${ctl_members[0]}")"
    data_member="$(basename "${data_members[0]}")"
    tar -xf "$_ar/$ctl_member" -C "$_ctl"
    [ -f "$_ctl/postinst" ] || { echo "ERROR: finish-install udeb missing postinst" >&2; exit 1; }
    python3 "$TMP_PY2" "$_ctl/postinst"
    chmod 0755 "$_ctl/postinst"
    sh -n "$_ctl/postinst"
    rm -f "$_ar/$ctl_member"
    ( cd "$_ctl" && tar --numeric-owner --owner=0 --group=0 -cf - . ) | gzip -9n > "$_ar/control.tar.gz"
    new_udeb="$_tmp/$(basename "$fi_udeb")"
    ( cd "$_ar" && ar rc "$new_udeb" debian-binary control.tar.gz "$data_member" )
    mv "$new_udeb" "$fi_udeb"
    rm -rf "$_tmp"
    echo "    finish-install udeb: 100 owned progress units allocated to 07preseed"
else
    echo "    WARN: finish-install udeb not in pool -- skipped"
fi
rm -f "$TMP_PY2"

# E. Regenerate udeb Packages index (build-iso-di.sh lines 2402–2419).
mkdir -p "$STAGING/dists/forky/main/debian-installer/binary-amd64"
( cd "$STAGING" && dpkg-scanpackages --type udeb --multiversion pool/main /dev/null 2>/dev/null \
    > dists/forky/main/debian-installer/binary-amd64/Packages )
gzip -9cn "$STAGING/dists/forky/main/debian-installer/binary-amd64/Packages" \
    > "$STAGING/dists/forky/main/debian-installer/binary-amd64/Packages.gz"
echo "    udeb Packages: $(grep -c '^Package: ' "$STAGING/dists/forky/main/debian-installer/binary-amd64/Packages") entries"

# F. Generic firmware overlay (lines 2947–2985) — iwlwifi + rtl_nic.
# This is the AMD64-specific bugfix from 2026-09-20: hw-detect looping on
# missing Intel AX201 firmware on PEGASUS. The initrd already has these in
# many recent images; we add them anyway (cpio-append is harmless).
FW_OVERLAY="$STAGING/.installer-firmware-overlay"
rm -rf "$FW_OVERLAY"
mkdir -p "$FW_OVERLAY/usr/lib/firmware"
for fwdir in iwlwifi rtl_nic; do
    if [ -d "$ROOT/assets/firmware/$fwdir" ]; then
        mkdir -p "$FW_OVERLAY/usr/lib/firmware/$fwdir"
        cp -L "$ROOT/assets/firmware/$fwdir/"* "$FW_OVERLAY/usr/lib/firmware/$fwdir/" 2>/dev/null || true
    fi
done
if [ -d "$FW_OVERLAY/usr/lib/firmware/iwlwifi" ]; then
    cp -L "$FW_OVERLAY/usr/lib/firmware/iwlwifi/"*.ucode "$FW_OVERLAY/usr/lib/firmware/" 2>/dev/null || true
fi
FW_FILE_COUNT=$(find "$FW_OVERLAY/usr/lib/firmware" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$FW_FILE_COUNT" -gt 0 ]; then
    FW_GZ="$STAGING/.r80-firmware-overlay.cpio.gz"
    ( cd "$FW_OVERLAY" && find . -mindepth 1 -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$FW_GZ"
    gzip -t "$FW_GZ"
    cat "$FW_GZ" >> "$STAGING/install.amd/initrd.gz"
    rm -f "$FW_GZ"
    echo "    installer firmware overlay: $FW_FILE_COUNT file(s) (iwlwifi + rtl_nic)"
else
    echo "    WARN: no installer-time firmware staged -- assets/firmware/{iwlwifi,rtl_nic} both empty/absent"
fi
rm -rf "$FW_OVERLAY"
echo "    initrd.gz now: $(du -h "$STAGING/install.amd/initrd.gz" | cut -f1)"

# G. Patch grub.cfg for unattended install + add a cixmini/preseed.cfg.
echo "[3/6] patching kernel cmdlines for unattended install + creating cixmini/preseed.cfg"
CFG="$STAGING/boot/grub/grub.cfg"
patch_line() {
  local add="$1"
  sed -i -E "s|(linux[[:space:]]+/install\\.amd/vmlinuz[^[:space:]]*[^[:space:]]+[[:space:]]+quiet)([[:space:]]+---[[:space:]]+quiet)?|\\1 ${add}\\2|" "$CFG"
}
patch_line "auto=true priority=critical"
patch_line "console=ttyS0,115200"
patch_line "preseed/file=/cdrom/cixmini/preseed.cfg"
patch_line "ncz_unattended=1"

PSEED_DIR="$STAGING/cixmini"
mkdir -p "$PSEED_DIR"
cat > "$PSEED_DIR/preseed.cfg" <<'EOF'
d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/locale seen true
d-i keyboard-configuration/xkb-keymap select us
d-i keyboard-configuration/xkb-keymap seen true
d-i clock-setup/utc boolean true
d-i clock-setup/utc seen true
d-i time/zone string UTC
d-i time/zone seen true
d-i clock-setup/ntp boolean false
d-i clock-setup/ntp seen true
d-i clock-setup/ntp-server string
d-i clock-setup/ntp-server seen true
d-i passwd/user-fullname string NCZTestUser
d-i passwd/user-fullname seen true
d-i passwd/username string nczuser
d-i passwd/username seen true
d-i passwd/user-password password nczpassword123
d-i passwd/user-password seen true
d-i passwd/user-password-again seen true
EOF

echo "[4/6] repacking -> $QEMU_ISO"
EFI_IMG_REL="boot/grub/efi.img"
[ -f "$STAGING/$EFI_IMG_REL" ] || { echo "GATE FAIL: $EFI_IMG_REL missing from extracted ISO"; exit 2; }
rm -f "$QEMU_ISO"
xorriso -as mkisofs \
    -r -V "NCZ_MAXIMILIAN_FORKY_AMD64_FIXED" \
    -J -joliet-long \
    -cache-inodes \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -append_partition 2 0xef "$STAGING/$EFI_IMG_REL" \
    -appended_part_as_gpt \
    -partition_cyl_align all \
    -o "$QEMU_ISO" \
    "$STAGING" >/dev/null
echo "    fixed-qemutest ISO: $(ls -lh "$QEMU_ISO" | awk '{print $5}')"
ISO="$QEMU_ISO"

echo "=== KVM INSTALL GATE (AMD64/Forky-d-i-with-NCZ-hand-patches, F-retained-fixes) ==="
echo "  iso    : $ISO"
echo "  accel  : $ACCEL cpu=$CPU mem=${MEM}M smp=$SMP"
echo "  target : $DISK (${DISK_GB}G)"

rm -f "$DISK" "$VARS"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null || { echo "GATE FAIL: qemu-img"; exit 2; }
cp "$SRCVARS" "$VARS" || { echo "GATE FAIL: no OVMF vars"; exit 2; }

S0="$WORK/serial0.log"
ILOG="$WORK/install.log"
BLOG="$WORK/boot.log"
rm -f "$S0" "$ILOG" "$BLOG"

fail() { echo; echo "GATE FAIL: $*" >&2; exit 1; }

echo
echo "--- phase 1: install (timeout ${INSTALL_TIMEOUT}s) ---"
date -u +"  started %H:%M:%SZ"
set +e
timeout "$INSTALL_TIMEOUT" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$ISO",if=none,id=usbstick,format=raw,readonly=on \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=1 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$S0" \
  -display none -no-reboot \
  > "$ILOG" 2>&1
irc=$?
set -e
cat "$S0" >> "$ILOG" 2>/dev/null
date -u +"  ended   %H:%M:%SZ  (qemu rc=$irc)"

grep -qE "Debian installer|main-menu\[10\]" "$ILOG" \
  || fail "installer never started (qemu rc=$irc) — see $ILOG"

if grep -qE "Kernel panic - not syncing" "$ILOG"; then
  grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
  fail "kernel panic during install"
fi

grep -qE "Installation complete|finish-install|main-menu.*Finish|Menu finished" "$ILOG" \
  || fail "install did not reach finish stage (timeout at ${INSTALL_TIMEOUT}s?) — see $ILOG"
echo "  install reached finish stage"

echo
echo "--- phase 2: boot installed system (timeout ${BOOT_TIMEOUT}s) ---"
set +e
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -vga std \
  -netdev user,id=n0,hostfwd=tcp::2225-:22 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$WORK/boot-serial0.log" \
  -display none -no-reboot \
  > "$BLOG" 2>&1
brc=$?
set -e
cat "$WORK"/boot-serial0.log >> "$BLOG" 2>/dev/null
echo "  qemu rc=$brc"

grep -qE "Linux version|Booting Linux" "$BLOG" \
  || fail "installed system produced no kernel banner — bootloader did not hand off (see $BLOG)"
if grep -qE "Kernel panic - not syncing" "$BLOG"; then
  grep -nE -A12 "Kernel panic" "$BLOG" | head -30 >&2
  fail "installed system panicked on boot"
fi
if grep -qE "Welcome to|systemd\[1\]|Reached target|login:|Started .*getty" "$BLOG"; then
  echo "  installed system reached userspace"
else
  fail "installed system booted a kernel but never reached userspace (see $BLOG)"
fi

DEFAULT_KVER=$(grep -aoE 'Linux version [^ ]+' "$BLOG" \
  | tail -1 | sed -E 's/^Linux version //' || true)
echo "  default-boot kernel: ${DEFAULT_KVER:-<unknown>}"

# On-disk assertions per review §10 Stage B. NOTE: F-retained-fixes
# neutralized grub-installer + flash-kernel-installer, so the installed
# system's bootloader is whatever the upstream udeb defaults wrote —
# upstream Forky amd64 with EFI auto-installer uses systemd-boot, NOT
# rEFInd. The rescue-entry check (#5) is therefore expected to FAIL
# in this candidate, which is itself a finding about whether the
# rEFInd rescue contract carries through.
if [ "${SKIP_DISK_ASSERT:-0}" != "1" ]; then
  echo
  echo "--- post-boot on-disk assertions (GPT, ESP, root mode, rescue) ---"
  _IDA_HELPER="$(cd "$(dirname "$0")" && pwd)/../kvm-installed-disk-assert.sh"
  bash "$_IDA_HELPER" "$DISK" "$BLOG" amd64 \
    || fail "installed-disk-assert helper failed (see output above) — this is the on-disk layout / ESP / rescue check, NOT a generic timeout"
fi

echo
echo "GATE PASS (F-retained-fixes phase 1+2): $(basename "$ISO") installs and boots default kernel"
echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"