#!/bin/bash
# test-installer-disk-labels.sh -- S2-5: the target-disk selector must show a
# HUMAN-READABLE label per disk (model + size, plus BOOT DISK when known) while
# keeping the raw /dev node as the underlying value.
#
# Why: cdebconf's newt frontend renders a `select` from the Choices-C: list when
# present, and from the raw Choices: token (plus an "<ERR>" stub) otherwise. With
# only `Choices: /dev/nvme0n1, /dev/sda` the operator saw bare device nodes and
# could not tell which physical disk each was -- on a disk-ERASING screen.
# See preseed/component-selector.sh:155-178 for the cdebconf/newt evidence.
#
# This suite runs the chooser's real dialog-building block against a file-backed
# stand-in for cdebconf, with /sys/block, /proc/mounts and /proc/cmdline redirected
# into a sandbox (the same path-redirection technique build/test-component-selection.sh
# uses for the same file). It checks:
#   1. Choices: still carries the raw /dev nodes, in candidate order;
#   2. Choices-C: carries one human label per token, ONE-TO-ONE (a missing label
#      makes newt render "<ERR>");
#   3. each label carries the model + the size, and BOOT DISK only on the boot disk;
#   4. the raw device stays the VALUE end to end (the answer round-trips unchanged);
#   5. the no-boot-disk-known case omits the marker rather than guessing.
# Runs under sh and (when present) busybox ash -- the installer's own shell.
#
# Usage: build/test-installer-disk-labels.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHOOSER="$ROOT/preseed/disk-fs-chooser.sh"
SHX="${NCZ_TEST_SH:-sh}"
echo "-- shell: $SHX"
W="$(mktemp -d "${TMPDIR:-/tmp}/disk-labels.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()    { echo "ok   $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL $1"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
checkgrep() { if grep -qE "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 ($2 has no /$3/)"; fi; }
checkngrep(){ if grep -qE "$3" "$2" 2>/dev/null; then bad "$1 ($2 matched /$3/)"; else ok "$1"; fi; }

checkcmd() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
checkcmd "preseed/disk-fs-chooser.sh exists" test -f "$CHOOSER"
checkcmd "parses (sh)" sh -n "$CHOOSER"
if command -v busybox >/dev/null 2>&1; then
    checkcmd "parses (busybox ash)" busybox sh -n "$CHOOSER"
fi

# ------------------------------------------------------------------ fake cdebconf
# $FDB/v/<key> value; $FDB/q/<key> exists = question exists; $FDB/tpl/<file> the
# loaded template (so the test can read exactly what the dialog would render);
# $FDB/ans/<key> the value the operator picks (absent = keep the default).
cat > "$W/confmodule" <<'EOF'
_k() { printf '%s' "$1" | tr '/' '%'; }
db_exists() { [ -e "$FDB/q/$(_k "$1")" ]; }
db_set() { db_exists "$1" || return 10; printf '%s' "$2" > "$FDB/v/$(_k "$1")"; [ "$1" = ncz/target-disk ] && _DEFAULT="$2"; return 0; }
db_get() { RET=""; db_exists "$1" || return 10; RET=$(cat "$FDB/v/$(_k "$1")" 2>/dev/null); [ "$1" = ncz/target-disk ] && RET="${_DEFAULT:-$RET}"; return 0; }
db_fset() { db_exists "$1" || return 10; [ "$2" = seen ] && printf '%s' "$3" > "$FDB/s/$(_k "$1")"; return 0; }
db_fget() { RET=false; db_exists "$1" || return 10; [ "$2" = seen ] && RET=$(cat "$FDB/s/$(_k "$1")" 2>/dev/null || echo false); return 0; }
db_settitle() { return 0; }
db_subst() { return 0; }
db_capb() { return 0; }
db_progress() { return 0; }
db_input() { db_exists "$2" || return 10; [ "$1" = critical ] || return 30; return 0; }
db_go() { return 0; }
EOF
mkdir -p "$W/bin"
cat > "$W/bin/debconf-loadtemplate" <<'EOF'
#!/bin/sh
cp "$2" "$FDB/tpl/$(basename "$2")"
awk '/^Template:/{t=$2} /^Default:/{sub(/^Default:[ ]*/,""); d[t]=$0} /^Template:/{n[++c]=$2} END{for(i=1;i<=c;i++) print n[i] "\t" d[n[i]]}' "$2" |
while IFS="$(printf '\t')" read -r q d; do
    k=$(printf '%s' "$q" | tr '/' '%')
    [ -e "$FDB/q/$k" ] || { : > "$FDB/q/$k"; printf '%s' "$d" > "$FDB/v/$k"; }
done
EOF
chmod +x "$W/bin/"*

STUB="$W/bin"
cat > "$STUB/list-devices" <<'EOF'
#!/bin/sh
[ "$1" = disk ] && echo $T_DISKS
EOF
chmod +x "$STUB/list-devices"

# ------------------------------------------------------------------ sandbox /sys + /proc
# Disk fixtures mirror real sysfs: /sys/block/<name>/{size,device/model} for whole
# disks, and /sys/class/block/<name> as a SYMLINK to ../../block/<parent>/<name> so
# parent_disk_of_dev's `readlink -f` + dirname resolves a partition to its disk.
# /proc/mounts (signal 1) and /proc/cmdline (signal 2) drive the boot-disk detection.
mksys() { # mksys <name> <size-sectors> <model>
    mkdir -p "$SYS/block/$1/device"
    printf '%s\n' "$2" > "$SYS/block/$1/size"
    [ -n "$3" ] && printf '%s\n' "$3" > "$SYS/block/$1/device/model"
    ln -sfn "../../block/$1" "$SYS/class/block/$1"
}
# mkpart <part> <parent-disk> <partnum>: a partition node whose resolved parent is
# the whole disk, exactly like /sys/class/block/nvme0n1p1 -> .../nvme0n1/nvme0n1p1 .
mkpart() {
    mkdir -p "$SYS/block/$2" "$SYS/block/$2/$1"
    printf '%s\n' "$3" > "$SYS/block/$2/$1/partition"
    ln -sfn "../../block/$2/$1" "$SYS/class/block/$1"
}
gbsize() { printf '%s' $(( 1000000000 * $1 / 512 )); }   # ~<n>GB -> sectors (s*512/1e9)
newdb() {
    FDB="$W/db.$1"; rm -rf "$FDB"; mkdir -p "$FDB/q" "$FDB/v" "$FDB/s" "$FDB/ans" "$FDB/tpl"
    SYS="$W/sys.$1"; rm -rf "$SYS"; mkdir -p "$SYS/block" "$SYS/class/block"
    : > "$W/mounts.$1"; printf '%s\n' "quiet" > "$W/cmdline.$1"
    export FDB SYS
}
# Extract the disk chooser from the top of the file through the disk SELECTION
# block (up to the point it has CHOSEN_DISK), then append a dump of the rendered
# template. Paths that d-i would see at / are redirected into the sandbox.
EXTRACT_PY="$W/extract.py"
cat > "$EXTRACT_PY" <<'PY'
import sys, re
src = open(sys.argv[1]).read().splitlines(True)
# from the shebang-adjacent decls through the end of the disk-select `else` block.
start = next(i for i, l in enumerate(src) if l.startswith('set +e'))
end = next(i for i, l in enumerate(src) if l.startswith('# --- choose the root filesystem'))
print(''.join(src[start:end]))
PY
build_script() {
    python3 "$EXTRACT_PY" "$CHOOSER" \
      | sed -e "s#/sys/block#$SYS/block#g" \
            -e "s#/sys/class/block#$SYS/class/block#g" \
            -e "s#/sys/firmware#$SYS/firmware#g" \
            -e "s#/proc/mounts#$W/mounts.$TAG#g" \
            -e "s#/proc/cmdline#$W/cmdline.$TAG#g" \
            -e "s#/dev/disk/by-uuid/#$W/by-uuid/#g" \
            -e "s#/dev/disk/by-partuuid/#$W/by-partuuid/#g" \
            -e "s#/tmp/ncz-nonusb-media#$W/nonusb.$TAG#g" \
            -e "s#/tmp/ncz-disk.templates#$W/tpl.$TAG#g" \
            -e "s#/tmp/ncz-disk-done#$W/done.$TAG#g" \
            -e "s#/tmp/ncz-target-disk#$W/target.$TAG#g" \
      > "$W/chooser.$TAG.sh"
    # stop the extracted block right before it would wipe; dump what the dialog saw
    printf '%s\n' 'cat "$FDB/tpl/ncz-disk.templates" 2>/dev/null' 'echo "CHOSEN=[$CHOSEN_DISK]"' >> "$W/chooser.$TAG.sh"
}
run() { # run <tag> <candidates(with /dev prefix)> <boot-disk>
    TAG="$1"; T_DISKS="$2"; export T_DISKS
    PATH="$STUB:$PATH" NCZ_CONFMODULE="$W/confmodule" NCZ_CMD="$W/cmdline.$TAG" \
        NCZ_CONFMODULE="$W/confmodule" NCZ_TMP="$W" NCZ_MEDIA_DIR="$W/medaddr" \
        NCZ_PROC_MOUNTS="$W/mounts.$TAG" $SHX "$W/chooser.$TAG.sh" 2>"$W/err.$TAG" >"$W/out.$TAG"
}
chosen()   { sed -n 's/^CHOSEN=\[\(.*\)\]$/\1/p' "$W/out.$TAG"; }
tpl()      { sed -n 's/^[A-Za-z-]*: //p' "$W/tpl.$TAG" >/dev/null; cat "$W/tpl.$TAG" 2>/dev/null; }
choices()  { sed -n 's/^Choices: //p' "$W/tpl.$TAG"; }
choices_c(){ sed -n 's/^Choices-C: //p' "$W/tpl.$TAG"; }
ncommas()  { printf '%s' "$1" | tr ',' '\n' | grep -c .; }

# ============================================================================
# 1. two SSDs + a known boot disk: labels carry model + size, boot disk marked
# ============================================================================
echo "== 1. labels carry model + size; BOOT DISK on the running disk"
newdb one
mksys nvme0n1 "$(gbsize 1000)" "Samsung SSD 990 PRO 1TB"
mksys nvme1n1 "$(gbsize 2000)" "WD Black SN850X 2TB"
# nvme0n1p1 = the mounted ESP -> boot disk is nvme0n1 (signal 1)
mkpart nvme0n1p1 nvme0n1 1
printf '%s\n' "/dev/nvme0n1p1 /boot/efi vfat rw 0 0" > "$W/mounts.one"
TAG=one; build_script; run one "/dev/nvme0n1 /dev/nvme1n1"
checkgrep "Choices: keeps the raw /dev nodes"          "$W/tpl.one" '^Choices: /dev/nvme0n1, /dev/nvme1n1$'
checkgrep "Choices-C: is present"                     "$W/tpl.one" '^Choices-C: '
checkgrep "label 1 carries model + size"              "$W/tpl.one" 'Samsung SSD 990 PRO 1TB \(1000GB\)'
checkgrep "label 2 carries model + size"              "$W/tpl.one" 'WD Black SN850X 2TB \(2000GB\)'
checkgrep "the BOOT DISK is marked"                   "$W/tpl.one" 'Samsung SSD 990 PRO 1TB \(1000GB\) - BOOT DISK'
checkngrep "the non-boot disk is NOT marked"          "$W/tpl.one" 'WD Black SN850X 2TB \(2000GB\) - BOOT DISK'
check "Choices and Choices-C: one entry each (no <ERR> stub)" "$(ncommas "$(choices)")" "$(ncommas "$(choices_c)")"
check "exactly two Choices"                           "$(ncommas "$(choices)")" 2
check "exactly two labels"                            "$(ncommas "$(choices_c)")" 2
# one-to-one mapping: same index -> same disk
check "index 1 is nvme0n1 with the Samsung label" \
      "$(printf '%s' "$(choices)" | cut -d, -f1)|$(printf '%s' "$(choices_c)" | cut -d, -f1)" \
      "/dev/nvme0n1|Samsung SSD 990 PRO 1TB (1000GB) - BOOT DISK"
check "index 2 is nvme1n1 with the WD label" \
      "$(printf '%s' "$(choices)" | cut -d, -f2 | sed 's/^ //')|$(printf '%s' "$(choices_c)" | cut -d, -f2 | sed 's/^ //')" \
      "/dev/nvme1n1|WD Black SN850X 2TB (2000GB)"
checkngrep "no template error stub"                   "$W/tpl.one" '<ERR>'
check "the raw device is still the VALUE (default = first candidate)" "$(chosen)" "/dev/nvme0n1"

# ============================================================================
# 2. boot disk from the kernel cmdline (root=) when no ESP is mounted
# ============================================================================
echo "== 2. boot disk resolved from root= when no ESP is mounted"
newdb two
mksys sda "$(gbsize 250)" "Samsung SSD 860 EVO 256GB"
mksys sdb "$(gbsize 1000)" "Crucial MX500 1TB"
# no mounted ESP; signal 2: root=/dev/sda2 (a partition of sda)
mkpart sda2 sda 2
printf '%s\n' "quiet root=/dev/sda2 ro" > "$W/cmdline.two"
TAG=two; build_script; run two "/dev/sda /dev/sdb"
checkgrep "root= marks sda as the boot disk"          "$W/tpl.two" 'Samsung SSD 860 EVO 256GB \(250GB\) - BOOT DISK'
checkngrep "sdb is not marked"                        "$W/tpl.two" 'Crucial MX500 1TB \(1000GB\) - BOOT DISK'

# ============================================================================
# 3. no boot disk provable: the marker is OMITTED (never guessed)
# ============================================================================
echo "== 3. no boot disk provable: no marker, labels still readable"
newdb three
mksys sda "$(gbsize 250)" "Kingston A400 240GB"
: > "$W/mounts.three"; printf '%s\n' "quiet" > "$W/cmdline.three"
TAG=three; build_script; run three "/dev/sda"
checkgrep "the label still carries model + size"      "$W/tpl.three" 'Kingston A400 240GB \(250GB\)'
checkngrep "no BOOT DISK marker is invented"          "$W/tpl.three" 'BOOT DISK'
checkngrep "no BOOT DISK marker is invented anywhere" "$W/tpl.three" 'BOOT'

# ============================================================================
# 4. a disk with no readable model still gets a useful label
# ============================================================================
echo "== 4. missing model degrades to a readable placeholder"
newdb four
mksys sdc "$(gbsize 2000)" ""     # no device/model emitted
TAG=four; build_script; run four "/dev/sdc"
checkgrep "no model: a placeholder, not an empty label" "$W/tpl.four" 'Choices-C: unknown model \(2000GB\)'
checkngrep "no blank label"                             "$W/tpl.four" 'Choices-C: ,'
checkngrep "no double space from a missing model"       "$W/tpl.four" 'Choices-C:  \('

# ============================================================================
# 5. a comma in a model name must not split the Choices-C list
# ============================================================================
echo "== 5. a comma inside a model name never splits Choices-C"
newdb five
mksys sdd "$(gbsize 250)" "ACME, Inc. SSD 240GB"
TAG=five; build_script; run five "/dev/sdd"
check "exactly one label despite the model's comma"  "$(ncommas "$(choices_c)")" 1
checkgrep "the comma is neutralised"                 "$W/tpl.five" 'ACME  Inc. SSD 240GB \(250GB\)'

echo "-- shell: re-run under busybox ash"
if command -v busybox >/dev/null 2>&1; then
    newdb six
    mksys sda "$(gbsize 250)" "Samsung SSD 860 EVO 256GB"
    TAG=six; build_script
    T_DISKS="/dev/sda"
    PATH="$STUB:$PATH" NCZ_CONFMODULE="$W/confmodule" NCZ_TMP="$W" NCZ_MEDIA_DIR="$W/medaddr" \
        busybox sh "$W/chooser.six.sh" 2>"$W/err.six"
    checkgrep "busybox ash: Choices: raw nodes" "$W/tpl.six" '^Choices: /dev/sda$'
    checkgrep "busybox ash: Choices-C: label present" "$W/tpl.six" 'Choices-C: Samsung SSD 860 EVO 256GB \(250GB\)'
fi

# ============================================================================
# 6. source-level guards: the marker can only ever be a LABEL
# ============================================================================
echo "== 6. the boot disk is a label only (no candidate/default change)"
checkgrep "BOOT_DISK is computed from the detector"   "$CHOOSER" '^BOOT_DISK=\$\(boot_disk_of_system\)$'
checkgrep "Choices-C: is emitted into the template"   "$CHOOSER" '^Choices-C: \$\{LABELS\}$'
checkgrep "the label appends the BOOT DISK marker"    "$CHOOSER" 'desc="\$desc - BOOT DISK"'
# BOOT_DISK must never appear in the CANDIDATES filter or the chosen-disk guard
n=$(grep -c 'BOOT_DISK' "$CHOOSER")
check "BOOT_DISK is referenced but never selects/filters a disk ($n refs)" \
      "$(grep -nE 'CANDIDATES=.*BOOT_DISK|continue.*BOOT_DISK|CHOSEN_DISK=.*BOOT_DISK|abort.*BOOT_DISK' "$CHOOSER" | wc -l | tr -d ' ')" 0

echo "disk-labels: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
