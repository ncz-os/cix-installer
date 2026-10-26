#!/bin/bash
# shellcheck disable=SC2034,SC1090  # variables are inputs of the sourced, extracted blocks
# test-install-options.sh -- every install-option combination ends bootable.
#
# 2026-10-14, amd64 install on a MacBookPro16,1 with the optional-components
# dialog answered desktop ON, management container OFF, rescue partition OFF:
# the install failed at "Finish the installation". post-install/70-bootloader.sh
# runs ncz-refind-refresh-amd64, which refused to touch the ESP because
# RESCUE_READY had no PARTUUID -- but 72-rescue-partition.sh, the only writer
# of RESCUE_READY, had been skipped because the partition was not selected. The
# ESP was left without rEFInd and late.sh then printed the arm64 path
# (BOOTAA64.EFI) for an amd64 install. The KVM gate never saw it: it always
# answered the dialog with every option selected.
#
# Contract, each checked against the SHIPPED code (blocks extracted between
# their markers; only absolute paths are redirected into a sandbox):
#   1. both rEFInd refresh scripts carry the SAME rescue preflight, and it
#      requires the rescue partition exactly when it was selected (or when no
#      selection was recorded), refuses before any ESP write when a selected
#      partition is not ready, and reads the record in run-all.sh's order;
#      a package hook calling it mid-install before 72-rescue-partition.sh has
#      run leaves the ESP to 70-bootloader.sh without an ERROR (all options on,
#      arm64: the cixmini wrapper from an initramfs trigger during step 47);
#   2. no rescue-partition menu entry without a rescue partition (amd64 option
#      assembly, arm64 option assembly incl. the typec blacklist merge);
#   3. late.sh's bootability check is per architecture (amd64 BOOTX64.EFI,
#      arm64 BOOTAA64.EFI, plus refind.conf) and names the arch's path;
#   4. run-all.sh drops 37-failsafe-access + 38-recovery-container with the
#      management-container option and 72-rescue-partition with the rescue one;
#   5. the KVM gate turns an options answer into the cmdline value and the
#      record the installer writes, rejects unknown options, finds the root
#      partition for both layouts, and the matrix wrapper names the standard
#      sets that build-image.sh runs;
#   6. the first-boot report records what the boot reached;
#   7. the root PARTUUID (2026-10-14, Macmini5,1 reinstall: an old ext4
#      superblock under the new btrfs root made blkid ambivalent, every normal
#      entry got root=PARTUUID= and the boot hung in the initramfs): the
#      refresh scripts read the GPT when blkid has no answer, fail on an
#      ambivalent probe or an empty value before the ESP, late.sh calls a menu
#      with an empty root= unbootable, and the installer clears the old
#      partitions' signatures before repartitioning.
#
# NCZ_TEST_ROOT=<tree> runs the checks against another checkout (the pre-fix
# tree fails sections 1-3). Exit 0 = pass, 1 = fail.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
W="$(mktemp -d "${TMPDIR:-/tmp}/install-options.XXXXXX")" && [ -d "$W" ] || { echo "cannot create a scratch dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
between() { awk -v b="$2" -v e="$3" 'index($0, b) {f=1; next} index($0, e) {f=0} f' "$1"; }
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

AMD="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
ARM="$ROOT/assets/refind/ncz-refind-refresh.sh"
LATE="$ROOT/preseed/late.sh"
RUNALL="$ROOT/post-install/run-all.sh"
GATE="$ROOT/build/kvm-install-gate-gpt.sh"
MATRIX="$ROOT/build/kvm-install-gate-matrix.sh"

echo "=== 1. rescue preflight in the refresh scripts ==="
between "$AMD" 'NCZ-RESCUE-PREFLIGHT-BEGIN' 'NCZ-RESCUE-PREFLIGHT-END' > "$W/pre-amd64.sh"
between "$ARM" 'NCZ-RESCUE-PREFLIGHT-BEGIN' 'NCZ-RESCUE-PREFLIGHT-END' > "$W/pre-arm64.sh"
if [ -s "$W/pre-amd64.sh" ] && [ -s "$W/pre-arm64.sh" ]; then
    cmp -s "$W/pre-amd64.sh" "$W/pre-arm64.sh" && ok "amd64 and arm64 carry the same preflight block" \
        || nok "the two preflight blocks differ" "$(diff "$W/pre-amd64.sh" "$W/pre-arm64.sh")"
    sed -e "s#/etc/cix-installer#$W/sb/etc/cix-installer#g" -e "s#/var/lib/cix-components#$W/sb/var/lib/cix-components#g" \
        -e "s#/proc/sys/kernel/random/boot_id#$W/boot_id#g" "$W/pre-amd64.sh" > "$W/pre-sb.sh"
    echo boot-A > "$W/boot_id"
    # pre <record-location|-> <record> <marker: uuid|empty|-> -> prints rc and PARTUUID
    pre() {
        rm -rf "$W/sb"; mkdir -p "$W/sb/meta" "$W/sb/etc/cix-installer" "$W/sb/var/lib/cix-components"
        case "$1" in
            meta) printf '%s\n' "$2" > "$W/sb/meta/COMPONENTS" ;;
            etc)  printf '%s\n' "$2" > "$W/sb/etc/cix-installer/COMPONENTS" ;;
            var)  printf '%s\n' "$2" > "$W/sb/var/lib/cix-components/COMPONENTS" ;;
        esac
        case "$3" in
            -) : ;;
            empty) printf 'DEVICE=/dev/x\n' > "$W/sb/meta/RESCUE_READY" ;;
            *) printf 'PARTUUID=%s\n' "$3" > "$W/sb/meta/RESCUE_READY" ;;
        esac
        ( set -euo pipefail; INSTALLER_META="$W/sb/meta"; . "$W/pre-sb.sh" > "$W/pre.out" 2>&1; printf 'P=%s' "$RESCUEPART_PARTUUID" )
        printf ' rc=%s' "$?"
    }
    full=desktop,browsers,wallpaper-rotator,mgmt-container,rescue-partition
    [ "$(pre meta "$full" abcd-1)" = "P=abcd-1 rc=0" ] && ok "rescue selected + marker: PARTUUID taken" || nok "rescue selected + marker: $(pre meta "$full" abcd-1)"
    [ "$(pre meta "$full" -)" = " rc=1" ] && grep -q 'Refusing to modify the ESP' "$W/pre.out" && ok "rescue selected, no marker: refuses (rc 1)" || nok "rescue selected, no marker: $(pre meta "$full" -)"
    [ "$(pre meta "$full" empty)" = " rc=1" ] && ok "rescue selected, marker without PARTUUID: refuses" || nok "marker without PARTUUID: $(pre meta "$full" empty)"
    [ "$(pre meta desktop,browsers,wallpaper-rotator -)" = "P= rc=0" ] && ok "rescue off + mgmt off (the failing install): no partition required" || nok "rescue off: $(pre meta desktop,browsers,wallpaper-rotator -)"
    [ "$(pre meta desktop,browsers,wallpaper-rotator,mgmt-container -)" = "P= rc=0" ] && ok "rescue off + mgmt on: no partition required" || nok "rescue off + mgmt on"
    [ "$(pre meta none -)" = "P= rc=0" ] && ok "every option off (none): no partition required" || nok "none: $(pre meta none -)"
    [ "$(pre meta mgmt-container,rescue-partition abcd-2)" = "P=abcd-2 rc=0" ] && ok "desktop off + rescue on: PARTUUID taken" || nok "desktop off + rescue on"
    [ "$(pre - '' -)" = " rc=1" ] && ok "no record at all: partition still required (old contract)" || nok "no record: $(pre - '' -)"
    [ "$(pre etc none -)" = "P= rc=0" ] && ok "record only in /etc/cix-installer is honoured" || nok "/etc record"
    [ "$(pre var none -)" = "P= rc=0" ] && ok "record only in /var/lib/cix-components is honoured" || nok "/var/lib record"
    [ "$(pre meta none abcd-3)" = "P=abcd-3 rc=0" ] && ok "a ready marker is used even when not recorded as selected" || nok "marker without selection"
    # A package hook calling the refresh mid-install, before 72 ran (all options on: the O6N/.66 log ERROR line).
    inst() { pre meta "$full" - >/dev/null; mkdir -p "$W/sb/meta"; echo "$1" > "$W/sb/meta/INSTALL_IN_PROGRESS"
        ( set -euo pipefail; INSTALLER_META="$W/sb/meta"; . "$W/pre-sb.sh" > "$W/pre.out" 2>&1 ); printf 'rc=%s' "$?"; }
    [ "$(inst boot-A)" = rc=0 ] && grep -q 'ESP left to 70-bootloader' "$W/pre.out" && ! grep -q ERROR "$W/pre.out" \
        && ok "mid-install, rescue selected, marker not written yet: no ERROR, ESP left to 70-bootloader" || nok "mid-install deferral: $(inst boot-A) $(cat "$W/pre.out")"
    [ "$(inst boot-B)" = rc=1 ] && ok "a left-over install marker from another boot does not defer (installed system)" || nok "stale install marker deferred"
    # The record locations and their order are run-all.sh's (COMP_FILE chain).
    ra=$(grep -E '^(COMP_FILE=|\[ -r "\$COMP_FILE" \] \|\| COMP_FILE=)' "$RUNALL" | sed 's/.*COMP_FILE=//' | tr '\n' ' ')
    pf=$(grep -m1 '^for _rcf in ' "$W/pre-amd64.sh" | sed 's/^for _rcf in //; s/; do$//; s#"\$INSTALLER_META/COMPONENTS"#/usr/local/lib/cix-installer/COMPONENTS#')
    [ "$(echo $ra)" = "$(echo $pf)" ] && ok "record lookup order matches run-all.sh ($pf)" || nok "lookup order differs: run-all [$ra] preflight [$pf]"
    for s in "$AMD" "$ARM"; do
        n=$(basename "$s"); pl=$(line_of "$s" 'NCZ-RESCUE-PREFLIGHT-BEGIN')
        first=$(grep -nE '^[^#]*(rm -[rf]+ +/boot/efi|install -m 0644 "\$REFIND_SRC"|^ncz_promote_outgoing_rescue /boot/efi)' "$s" | head -1 | cut -d: -f1)
        [ -n "$pl" ] && [ -n "$first" ] && [ "$pl" -lt "$first" ] && ok "$n: preflight (line $pl) runs before the first ESP write (line $first)" \
            || nok "$n: preflight line ${pl:-?} is not before the first ESP write ${first:-?}"
        # The decision runs under errexit, before the relaxed write section.
        rl=$(grep -n '^set +e +u +o pipefail' "$s" | head -1 | cut -d: -f1)
        [ -n "$rl" ] && [ "$pl" -lt "$rl" ] && ok "$n: preflight runs under set -euo pipefail" || nok "$n: preflight after set +e"
    done
else
    nok "NCZ-RESCUE-PREFLIGHT markers missing in a refresh script"
fi

echo "=== 2. no rescue-partition entry without a rescue partition ==="
between "$AMD" 'NCZ-DEFAULT-OPTIONS-BEGIN' 'NCZ-DEFAULT-OPTIONS-END' > "$W/amd-region.sh"
if [ -s "$W/amd-region.sh" ]; then
    amd_opts() { ( STABLE_AVAILABLE=1 ROOT_OPTS="root=PARTUUID=r rw" SPLASH=quiet RESCUEPART_PARTUUID="$1"
        STABLE_CMDLINE_BASE="console=tty0"; ncz_is_t2_hardware() { return 1; }
        . "$W/amd-region.sh" >/dev/null 2>&1; printf '%s' "$RESCUEPART_OPTIONS" ); }
    [ -z "$(amd_opts '')" ] && ok "amd64: no PARTUUID -> no rescue-partition options" || nok "amd64: options built without a partition: $(amd_opts '')"
    case "$(amd_opts p-1)" in "root=PARTUUID=p-1 "*) ok "amd64: PARTUUID -> rescue-partition entry boots it" ;; *) nok "amd64: $(amd_opts p-1)" ;; esac
else
    nok "amd64: NCZ-DEFAULT-OPTIONS markers missing"
fi
for s in "$AMD" "$ARM"; do
    n=$(basename "$s")
    awk '/^    if \[ -n "\$RESCUEPART_OPTIONS" \]; then$/ {g=1} g && /Rescue Partition/ {print "gated"; exit}' "$s" | grep >/dev/null gated \
        && ok "$n: the Rescue Partition menuentry is written only when its options exist" || nok "$n: Rescue Partition entry not gated on RESCUEPART_OPTIONS"
done
awk '/^RESCUEPART_OPTIONS=""$/ {f=1} f {print} /^# Same-kernel rescue entry/ {exit}' "$ARM" > "$W/arm-region.sh"
if grep -q 'NEXT_CONSOLE_EXISTING_BL' "$W/arm-region.sh"; then
    arm_opts() { ( NEXT_AVAILABLE=1 RESCUEPART_PARTUUID="$1" NEXT_CONSOLE_EXISTING_BL=typec_x
        NEXT_CONSOLE_CMDLINE_NOBL="root=PARTUUID=r console=tty0 sky1.gpu=vendor" RESCUE_ACCEL_BLACKLIST=panthor
        . "$W/arm-region.sh" >/dev/null 2>&1; printf '%s|%s' "$RESCUE_ACCEL_BLACKLIST" "$RESCUEPART_OPTIONS" ); }
    [ "$(arm_opts '')" = "typec_x,panthor|" ] && ok "arm64: no PARTUUID -> no entry, typec blacklist still merged for the same-kernel rescue" || nok "arm64 no partition: $(arm_opts '')"
    case "$(arm_opts p-2)" in "typec_x,panthor|root=PARTUUID=p-2 "*"module_blacklist=typec_x,panthor "*) ok "arm64: PARTUUID -> entry with the merged blacklist" ;; *) nok "arm64 partition: $(arm_opts p-2)" ;; esac
else
    nok "arm64: option-assembly region not found"
fi

echo "=== 3. late.sh bootability is per architecture ==="
between "$LATE" 'NCZ-BOOTABLE-BEGIN' 'NCZ-BOOTABLE-END' > "$W/boot.sh"
if [ -s "$W/boot.sh" ]; then
    sed "s#/target#$W/t#g" "$W/boot.sh" > "$W/boot-sb.sh"
    bootable() {   # bootable <arch> <files...> -> yes|no
        rm -rf "$W/t"; mkdir -p "$W/t/boot/efi/EFI/BOOT"; local a="$1"; shift
        for f in "$@"; do case "$f" in *:empty) : > "$W/t/boot/efi/EFI/BOOT/${f%:empty}" ;; *) echo x > "$W/t/boot/efi/EFI/BOOT/$f" ;; esac; done
        NCZ_DEB_ARCH="$a" sh -c ". '$W/boot-sb.sh'; ncz_bootable" && echo yes || echo no
    }
    [ "$(bootable amd64 BOOTX64.EFI refind.conf)" = yes ] && ok "amd64: BOOTX64.EFI + refind.conf is bootable" || nok "amd64 BOOTX64"
    [ "$(bootable amd64 BOOTAA64.EFI refind.conf)" = no ] && ok "amd64: the arm64 binary does not count" || nok "amd64 accepted BOOTAA64"
    [ "$(bootable amd64 refind.conf)" = no ] && ok "amd64: refind.conf alone is not bootable" || nok "amd64 refind.conf alone"
    [ "$(bootable amd64 BOOTX64.EFI)" = no ] && ok "amd64: binary without refind.conf is not bootable" || nok "amd64 no conf"
    [ "$(bootable amd64 BOOTX64.EFI:empty refind.conf)" = no ] && ok "amd64: empty binary is not bootable" || nok "amd64 empty binary"
    [ "$(bootable arm64 BOOTAA64.EFI refind.conf)" = yes ] && ok "arm64: BOOTAA64.EFI + refind.conf is bootable" || nok "arm64 BOOTAA64"
    [ "$(bootable arm64 BOOTX64.EFI refind.conf)" = no ] && ok "arm64: the amd64 binary does not count" || nok "arm64 accepted BOOTX64"
    [ "$(NCZ_DEB_ARCH=amd64 sh -c ". '$W/boot.sh'; ncz_boot_binary")" = /target/boot/efi/EFI/BOOT/BOOTX64.EFI ] && ok "amd64 message names BOOTX64.EFI" || nok "amd64 message path"
    [ "$(NCZ_DEB_ARCH=arm64 sh -c ". '$W/boot.sh'; ncz_boot_binary")" = /target/boot/efi/EFI/BOOT/BOOTAA64.EFI ] && ok "arm64 message names BOOTAA64.EFI" || nok "arm64 message path"
    grep -q 'no rEFInd at \$(ncz_boot_binary)' "$LATE" && ! grep -q 'no rEFInd at /target/boot/efi/EFI/BOOT/BOOTAA64.EFI' "$LATE" \
        && ok "the NOT-bootable message uses the arch's path" || nok "the NOT-bootable message still hardcodes a path"
    al=$(grep -n '^NCZ_DEB_ARCH=' "$LATE" | head -1 | cut -d: -f1); ul=$(grep -n 'ncz_bootable &&\|ncz_bootable;' "$LATE" | head -1 | cut -d: -f1)
    [ -n "$al" ] && [ -n "$ul" ] && [ "$al" -lt "$ul" ] && ok "NCZ_DEB_ARCH is set (line $al) before the first bootability use (line $ul)" || nok "NCZ_DEB_ARCH set after use ($al vs $ul)"
else
    nok "late.sh: NCZ-BOOTABLE markers missing"
fi

echo "=== 4. run-all.sh option skips ==="
mg=$(sed -n "s/^_SKIP_MGMT_RE='\(.*\)'$/\1/p" "$RUNALL")
rs=$(sed -n "s/^_SKIP_RESCUE_RE='\(.*\)'$/\1/p" "$RUNALL")
[ -n "$mg" ] && [ -n "$rs" ] && ok "skip patterns read from run-all.sh" || nok "could not read _SKIP_MGMT_RE/_SKIP_RESCUE_RE from run-all.sh"
for h in 37-failsafe-access.sh 38-recovery-container.sh; do
    printf '%s\n' "$h" | grep >/dev/null -E "$mg" && ok "mgmt-container off skips $h" || nok "mgmt-container off does not skip $h"
done
printf '%s\n' 72-rescue-partition.sh | grep >/dev/null -E "$rs" && ok "rescue-partition off skips 72-rescue-partition.sh" || nok "rescue skip"
printf '%s\n' 36-telemetry.sh 70-bootloader.sh | grep >/dev/null -E "$mg|$rs" && nok "an option skip drops 36-telemetry or 70-bootloader" || ok "telnet :23 (36) and the bootloader (70) are never option-skipped"

ml=$(grep -n '^cat /proc/sys/kernel/random/boot_id > "\$NCZ_INSTALL_MARK"' "$RUNALL" | head -1 | cut -d: -f1)
p0=$(grep -n '^# Phase 0: diagnostic affordance hooks' "$RUNALL" | head -1 | cut -d: -f1)
[ -n "$ml" ] && [ -n "$p0" ] && [ "$ml" -lt "$p0" ] && ok "run-all.sh writes the install marker before the first hook" || nok "install marker not written before the hooks ($ml vs $p0)"
awk '/^finalize_bootloader\(\) \{/ {f=1} f && /rm -f .*INSTALL_IN_PROGRESS/ {r=NR} f && /bash "\$HOOK_DIR\/70-bootloader.sh"/ {b=NR; exit} END {exit !(r && b && r < b)}' "$RUNALL" \
    && ok "finalize_bootloader removes the marker before 70-bootloader.sh" || nok "marker not removed before 70-bootloader.sh"

echo "=== 5. KVM gate options ==="
between "$GATE" 'NCZ-GATE-COMPONENTS-BEGIN' 'NCZ-GATE-COMPONENTS-END' > "$W/gate-comp.sh"
if [ -s "$W/gate-comp.sh" ]; then
    gc() { ( NCZ_GATE_COMPONENTS="$1"; [ "$1" = UNSET ] && unset NCZ_GATE_COMPONENTS; . "$W/gate-comp.sh" 2>/dev/null; printf '%s|%s|%s%s%s' "$GATE_COMPONENTS_ARG" "$EXPECT_RECORD" "$WANT_DESKTOP" "$WANT_MGMT" "$WANT_RESCUE" ) || echo "rc=$?"; }
    # The selector runs the unattended ncz_components= path (no prompt, no cdebconf
    # needed): an empty sandbox confmodule (a missing one aborts dash before
    # the || true) and a stubbed logger so the sandbox never touches the host syslog.
    mkdir -p "$W/bin"
    : > "$W/confmodule"
    [ -x "$W/bin/logger" ] || { printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"; chmod +x "$W/bin/logger"; }
    selrec() {   # selrec <gate-components-answer> -> the record the selector writes
        st="$W/selst-$1"; rm -rf "$st"; mkdir -p "$st/state" "$st/target"
        printf 'BOOT_IMAGE=/install.amd/vmlinuz ncz_components=%s\n' "$1" > "$st/cmdline"
        PATH="$W/bin:$PATH" NCZ_CONFMODULE="$W/confmodule" NCZ_CMDLINE="$st/cmdline" NCZ_TMP="$st" NCZ_COMP_STATE="$st/state" \
            NCZ_TARGET="$st/target" NCZ_LOGGER="$W/bin/logger" NCZ_UNAME_M=x86_64 NCZ_PCI_DEVICES=/nonexistent NCZ_UI_SH=/nonexistent \
            sh "$ROOT/preseed/component-selector.sh" >"$st/selector.log" 2>&1 || echo "selector-rc=$?"
        cat "$st/state/COMPONENTS" 2>/dev/null
    }
    [ "$(gc UNSET)" = "desktop,mgmt-container,rescue-partition|desktop,browsers,wallpaper-rotator,mgmt-container,rescue-partition|111" ] && ok "default: every option" || nok "default: $(gc UNSET)"
    [ "$(gc desktop)" = "desktop|desktop,browsers,wallpaper-rotator|100" ] && ok "desktop only (rescue off + mgmt off)" || nok "desktop: $(gc desktop)"
    [ "$(gc desktop,mgmt-container)" = "desktop,mgmt-container|desktop,browsers,wallpaper-rotator,mgmt-container|110" ] && ok "rescue off + mgmt on" || nok "desktop,mgmt: $(gc desktop,mgmt-container)"
    [ "$(gc none)" = "none|none|000" ] && ok "none: every option off" || nok "none: $(gc none)"
    [ "$(gc 'rescue-partition, mgmt-container')" = "mgmt-container,rescue-partition|mgmt-container,rescue-partition|011" ] && ok "desktop off, in the selector's order" || nok "nodesktop: $(gc 'rescue-partition, mgmt-container')"
    [ "$(gc desktop,bogus)" = "rc=2" ] && ok "an unknown option is refused (exit 2)" || nok "unknown option: $(gc desktop,bogus)"
    # The record shape is the selector's: drive the REAL selector through its
    # unattended ncz_components= path with the same answers the gate checks
    # above and assert its written record equals the gate's EXPECT_RECORD.
    # (A literal grep here used to pin the selector's line layout; the
    # S1-3 reassembly moved CHOSEN into a function and this broke.)
    # Normalise both sides to a sorted, de-duplicated token set: the record's
    # token ORDER is not the contract here (the selector reassembles desktop's
    # companions in its own layout), only the SET is.
    norm() { printf '%s\n' "$1" | tr ',' '\n' | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//'; }
    for ans in UNSET desktop desktop,mgmt-container none 'rescue-partition, mgmt-container'; do
        case "$ans" in UNSET) label="default (every option)" ;; *) label="$ans" ;; esac
        # gc takes the answer quoted (its NCZ_GATE_COMPONENTS="$1" keeps the
        # space form one word; the gate's own IFS=',' loop then splits it), so
        # the space answer below reaches it exactly as the matrix passes it.
        # Feed the selector the gate's ACTUAL cmdline value (field 1: bare
        # commas, desktop companions stripped). That is what reaches the
        # kernel and comes back as one token; the space form the matrix passes
        # to NCZ_GATE_COMPONENTS is normalised by the gate before the kernel
        # and would not survive the kernel's own word split.
        cmdline_ans="$(gc "$ans" | cut -d'|' -f1)"
        # The gate always puts an explicit value on the cmdline (UNSET -> its
        # full default list), so the selector never sees an empty value here.
        [ -n "$cmdline_ans" ] || nok "gate produced an empty ncz_components= value for $label"
        gotrec="$(norm "$(selrec "$cmdline_ans")")"; exprec="$(norm "$(gc "$ans" | cut -d'|' -f2)")"
        [ "$gotrec" = "$exprec" ] && ok "selector record matches the gate's EXPECT_RECORD for: $label" \
            || nok "selector record differs from the gate's EXPECT_RECORD for $label: selector [$gotrec] gate [$exprec]"
    done
else
    nok "KVM gate: NCZ-GATE-COMPONENTS markers missing"
fi
grep -q 'ncz_components=\$GATE_COMPONENTS_ARG' "$GATE" && ok "the gate passes the answer on the Install cmdline" || nok "gate cmdline still fixed"
grep -q 'VERIFY_EXPECT_COMPONENTS="\$EXPECT_RECORD"' "$GATE" && ok "the gate hands the expected record to the verifier" || nok "verifier not told the record"
grep -q "grep -aE 'Failed to run preseeded command|install is NOT bootable' >/dev/null" "$GATE" && grep -q 'wait "\$QEMU_PID"' "$GATE" \
    && ok "a failed finish stops the install guest instead of waiting out the timeout" || nok "no early stop on a failed finish"
grep -q -- '-i 3 ' "$GATE" && nok "the gate still assumes the root is partition 3" || ok "no fixed partition 3 in the gate"
SGDISK="$(command -v sgdisk || echo /sbin/sgdisk)"
if [ -x "$SGDISK" ]; then
    eval "$(awk '/^ncz_last_partnum\(\) \{/,/^}$/' "$GATE")"
    for n in 2 3; do
        img="$W/disk$n.img"; truncate -s 64M "$img"
        if [ "$n" = 3 ]; then "$SGDISK" -n 1:0:+8M -t 1:ef00 -n 2:0:+8M -n 3:0:0 "$img" >/dev/null 2>&1
        else "$SGDISK" -n 1:0:+8M -t 1:ef00 -n 2:0:0 "$img" >/dev/null 2>&1; fi
        [ "$(ncz_last_partnum "$img")" = "$n" ] && ok "root partition found as p$n on a $n-partition disk" || nok "ncz_last_partnum on $n partitions: $(ncz_last_partnum "$img")"
    done
else
    echo "  SKIP  sgdisk not installed: root-partition detection not exercised"
fi
if [ -s "$MATRIX" ]; then
    eval "$(between "$MATRIX" 'NCZ-GATE-SETS-BEGIN' 'NCZ-GATE-SETS-END')"
    [ "$(gate_set_components norescue)" = desktop ] && [ "$(gate_set_components minimal)" = none ] \
        && [ "$(gate_set_components norescue-mgmt)" = desktop,mgmt-container ] && [ "$(gate_set_components nodesktop)" = mgmt-container,rescue-partition ] \
        && [ "$(gate_set_components full)" = desktop,mgmt-container,rescue-partition ] && ok "matrix sets map to the expected answers" || nok "matrix set table"
    [ "$GATE_DEFAULT_SETS" = "norescue minimal stalefs" ] && ok "matrix default sets: rescue off + mgmt off, every option off, reinstall over old ext4" || nok "matrix default: $GATE_DEFAULT_SETS"
    [ "$(gate_set_disk stalefs)" = "btrfs 1" ] && [ "$(gate_set_disk minimal)" = "ext4 0" ] && ok "stalefs set: btrfs root over a seeded old disk" || nok "matrix disk table"
    grep -q "NCZ_KVM_GATE_VARIANTS:-norescue minimal stalefs" "$ROOT/build/build-image.sh" && grep -q 'build/kvm-install-gate-matrix.sh' "$ROOT/build/build-image.sh" \
        && ok "build-image.sh runs the option sets after the full gate" || nok "build-image.sh does not run the option sets"
    grep -q "NCZ_GATE_UI_CHECK=\"\$_ui\"" "$MATRIX" && ok "the UI check runs only in the full set" || nok "matrix UI check handling"
else
    nok "build/kvm-install-gate-matrix.sh missing"
fi

echo "=== 6. first-boot report records the boot target ==="
for k in default-target greetd getty-tty1; do
    grep -q "echo \"# $k=" "$ROOT/post-install/97-firstboot-report.sh" && ok "97-firstboot-report records $k" || nok "97-firstboot-report lacks $k"
done
grep -q 'FB_TARGET" = graphical.target' "$GATE" && grep -q 'FB_TARGET" = multi-user.target' "$GATE" \
    && ok "the gate checks the boot target against the desktop option" || nok "gate boot-target check missing"

echo "=== 7. root PARTUUID, empty root= and old signatures ==="
between "$AMD" 'NCZ-ROOT-PARTUUID-BEGIN' 'NCZ-ROOT-PARTUUID-END' > "$W/rp-amd64.sh"
between "$ARM" 'NCZ-ROOT-PARTUUID-BEGIN' 'NCZ-ROOT-PARTUUID-END' > "$W/rp-arm64.sh"
if [ -s "$W/rp-amd64.sh" ] && [ -s "$W/rp-arm64.sh" ]; then
    cmp -s "$W/rp-amd64.sh" "$W/rp-arm64.sh" && ok "amd64 and arm64 carry the same root PARTUUID block" || nok "root PARTUUID blocks differ"
    sed "s#/sys/class/block#$W/rp/sys#g; s#\"/dev/\$_disk\"#\"$W/rp/dev/\$_disk\"#g; s#-b \"$W/rp/dev#-e \"$W/rp/dev#" "$W/rp-amd64.sh" > "$W/rp-sb.sh"
    mkdir -p "$W/rp/bin"
    # stubs: BLKID_PARTUUID (blkid -s PARTUUID), BLKID_PROBE (blkid -p -o udev), SFDISK_UUID, SGDISK_UUID
    cat > "$W/rp/bin/findmnt" <<'STUB'
#!/bin/sh
echo /dev/sda3
STUB
    cat > "$W/rp/bin/blkid" <<'STUB'
#!/bin/sh
case "$*" in *"-p -o udev"*) printf '%s\n' "$BLKID_PROBE"; [ -n "$BLKID_AMBI" ] && echo "blkid: /dev/sda3: ambivalent result (probably more filesystems on the device, use wipefs(8) to see more details)" >&2; exit "${BLKID_PROBE_RC:-0}" ;; esac
printf '%s' "$BLKID_PARTUUID"
STUB
    cat > "$W/rp/bin/sfdisk" <<'STUB'
#!/bin/sh
printf '%s\n' "$SFDISK_UUID"
STUB
    cat > "$W/rp/bin/sgdisk" <<'STUB'
#!/bin/sh
[ -n "$SGDISK_UUID" ] && echo "Partition unique GUID: $SGDISK_UUID"
STUB
    chmod +x "$W/rp/bin/"*
    mkdir -p "$W/rp/sys/sda/sda3" "$W/rp/dev"; echo 3 > "$W/rp/sys/sda/sda3/partition"; : > "$W/rp/dev/sda"
    ln -sfn "$W/rp/sys/sda/sda3" "$W/rp/sys/sda3"
    rp() {   # rp BLKID_PARTUUID BLKID_AMBI SFDISK_UUID SGDISK_UUID -> "U=<uuid> rc=<rc>"
        ( export PATH="$W/rp/bin:$PATH" BLKID_PARTUUID="$1" BLKID_AMBI="$2" SFDISK_UUID="$3" SGDISK_UUID="$4" BLKID_PROBE="${5:-}" BLKID_PROBE_RC="${6:-0}"
          . "$W/rp-sb.sh" > "$W/rp.out" 2>&1; printf 'U=%s' "$ROOT_PARTUUID" ); printf ' rc=%s' "$?"; }
    [ "$(rp 11111111-2222-3333-4444-555555555555 '' '' '')" = "U=11111111-2222-3333-4444-555555555555 rc=0" ] && ok "blkid answer used" || nok "blkid answer: $(rp 11111111-2222-3333-4444-555555555555 '' '' '')"
    [ "$(rp '' 1 EAEE905D-57A4-43D0-B926-3607DF73001D '')" = " rc=1" ] && grep -q 'ambivalent' "$W/rp.out" && grep -q 'eaee905d-57a4-43d0-b926-3607df73001d' "$W/rp.out" \
        && ok "ambivalent probe (old ext4 under btrfs): refuses before the ESP and names the GPT GUID" || nok "ambivalent: $(rp '' 1 EAEE905D-57A4-43D0-B926-3607DF73001D '') $(cat "$W/rp.out")"
    for _probe_rc in 2 8; do
        [ "$(rp '' '' EAEE905D-57A4-43D0-B926-3607DF73001D '' '' "$_probe_rc")" = " rc=1" ] \
            && grep -q "blkid rc=$_probe_rc" "$W/rp.out" && ok "probe rc=$_probe_rc without text: refuses GPT fallback" \
            || nok "probe rc=$_probe_rc accepted GPT fallback"
    done
    [ "$(rp '' '' EAEE905D-57A4-43D0-B926-3607DF73001D '' ID_FS_AMBIVALENT=ext4:btrfs 0)" = " rc=1" ] \
        && grep -q ambivalent "$W/rp.out" && ok "uppercase udev ambiguity marker: refuses even with rc=0" \
        || nok "uppercase ambiguity marker accepted GPT fallback"
    [ "$(rp '' '' EAEE905D-57A4-43D0-B926-3607DF73001D '')" = "U=eaee905d-57a4-43d0-b926-3607df73001d rc=0" ] && ok "blkid empty, probe clean: GPT GUID from sfdisk, lower case" || nok "sfdisk fallback: $(rp '' '' EAEE905D-57A4-43D0-B926-3607DF73001D '')"
    [ "$(rp '' '' '' ae16dfe4-3ce5-4da2-b670-96642566dde2)" = "U=ae16dfe4-3ce5-4da2-b670-96642566dde2 rc=0" ] && ok "sfdisk empty: GPT GUID from sgdisk" || nok "sgdisk fallback"
    [ "$(rp '' '' '' '')" = " rc=1" ] && grep -q 'empty root=PARTUUID=' "$W/rp.out" && ok "no PARTUUID anywhere: refuses, never writes root=PARTUUID=" || nok "empty: $(rp '' '' '' '')"
    for sc in "$AMD" "$ARM"; do
        n=$(basename "$sc"); bl=$(line_of "$sc" 'NCZ-ROOT-PARTUUID-BEGIN')
        first=$(grep -nE '^[^#]*(rm -[rf]+ +/boot/efi|install -m 0644 "\$REFIND_SRC"|^ncz_promote_outgoing_rescue /boot/efi)' "$sc" | head -1 | cut -d: -f1)
        [ -n "$bl" ] && [ -n "$first" ] && [ "$bl" -lt "$first" ] && ok "$n: root PARTUUID check (line $bl) before the first ESP write (line $first)" || nok "$n: root PARTUUID check after an ESP write"
        grep -q 'ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_SRC")$' "$sc" && nok "$n: a bare blkid PARTUUID assignment remains" || ok "$n: no bare blkid-only root PARTUUID"
    done
else
    nok "NCZ-ROOT-PARTUUID markers missing in a refresh script"
fi
if [ -s "$W/boot-sb.sh" ]; then
    rm -rf "$W/t"; mkdir -p "$W/t/boot/efi/EFI/BOOT"; echo x > "$W/t/boot/efi/EFI/BOOT/BOOTX64.EFI"
    printf 'menuentry "a" {\n    options "root=PARTUUID= rootwait rootfstype=btrfs rw"\n}\n' > "$W/t/boot/efi/EFI/BOOT/refind.conf"
    NCZ_DEB_ARCH=amd64 sh -c ". '$W/boot-sb.sh'; ncz_bootable" 2>/dev/null && nok "late.sh: an empty root=PARTUUID= entry counted as bootable" || ok "late.sh: a menu with an empty root=PARTUUID= is not bootable"
    printf 'menuentry "a" {\n    options "root=PARTUUID=eaee905d-57a4-43d0-b926-3607df73001d rootwait"\n}\n' > "$W/t/boot/efi/EFI/BOOT/refind.conf"
    NCZ_DEB_ARCH=amd64 sh -c ". '$W/boot-sb.sh'; ncz_bootable" 2>/dev/null && ok "late.sh: a menu with a real root PARTUUID is bootable" || nok "late.sh rejected a good menu"
fi
CHOOSER="$ROOT/preseed/disk-fs-chooser.sh"
between "$CHOOSER" 'NCZ-WIPE-SIGNATURES-BEGIN' 'NCZ-WIPE-SIGNATURES-END' > "$W/wipe.sh"
if [ -s "$W/wipe.sh" ]; then
    rm -rf "$W/wp"; mkdir -p "$W/wp/sys/sdz/sdz1" "$W/wp/sys/sdz/sdz3"
    echo 2048 > "$W/wp/sys/sdz/sdz1/start"; echo 4096 > "$W/wp/sys/sdz/sdz1/size"
    echo 240:0 > "$W/wp/sys/sdz/dev"; echo 240:1 > "$W/wp/sys/sdz/sdz1/dev"; echo 240:3 > "$W/wp/sys/sdz/sdz3/dev"
    : > "$W/wp/mountinfo"; echo 'Filename Type Size Used Priority' > "$W/wp/swaps"
    echo 20480 > "$W/wp/sys/sdz/sdz3/start"; echo 40960 > "$W/wp/sys/sdz/sdz3/size"
    D="$W/wp/disk.img"; head -c $((70000 * 512)) /dev/zero | tr '\0' 'x' > "$D"
    sed "s#/sys/block/#$W/wp/sys/#g; s#/proc/self/mountinfo#$W/wp/mountinfo#g; s#/proc/swaps#$W/wp/swaps#g" "$W/wipe.sh" > "$W/wipe-sb.sh"
    ( base=sdz; log() { :; }; . "$W/wipe-sb.sh" )
    byte() { dd if="$D" bs=1 skip="$1" count=1 2>/dev/null | od -An -c | tr -d ' '; }
    [ "$(byte $((20480 * 512 + 1080)))" = '\0' ] && [ "$(byte $((20480 * 512 + 65536 + 64)))" = '\0' ] \
        && ok "old partition head zeroed (ext4 superblock at 1080, btrfs at 64 KiB)" || nok "old partition head not zeroed"
    [ "$(byte $(((20480 + 40960 - 1) * 512)))" = '\0' ] && ok "old partition tail zeroed" || nok "old partition tail not zeroed"
    [ "$(byte $((20480 * 512 + 8 * 1048576)))" = x ] && ok "data past the head is left alone" || nok "wipe went past 4 MiB"
    [ "$(byte $((2048 * 512 + 100)))" = '\0' ] && ok "small partition zeroed whole" || nok "small partition head"
    [ "$(stat -c %s "$D" 2>/dev/null || stat -f %z "$D")" = $((70000 * 512)) ] && ok "disk size unchanged (conv=notrunc)" || nok "disk truncated"
    before=$(cksum "$D")
    printf '20 1 240:1 / /busy rw - ext4 /dev/alias rw\n' > "$W/wp/mountinfo"
    ( base=sdz; log() { :; }; . "$W/wipe-sb.sh" ) && nok "mounted partition allowed writes" \
        || { [ "$(cksum "$D")" = "$before" ] && ok "mounted partition by device number: refuses before writes" || nok "mounted partition was written"; }
    # Prefix globs include the p separator used by NVMe/MMC and dm partitions.
    for _testbase in nvme0n1 mmcblk0 dm-0; do
        mkdir -p "$W/wp/sys/$_testbase/${_testbase}p1"
        echo 240:0 > "$W/wp/sys/$_testbase/dev"
        echo 240:1 > "$W/wp/sys/$_testbase/${_testbase}p1/dev"
        ( base=$_testbase; log() { :; }; . "$W/wipe-sb.sh" ) && nok "$_testbase mounted partition allowed writes" \
            || { [ "$(cksum "$D")" = "$before" ] && ok "$_testbase p1 partition: guard enumerates and refuses before writes" || nok "$_testbase partition was written"; }
    done
    : > "$W/wp/mountinfo"
    printf '/dev/sdz3 partition 1024 0 -2\n' >> "$W/wp/swaps"
    ( base=sdz; log() { :; }; . "$W/wipe-sb.sh" ) && nok "active swap allowed writes" \
        || { [ "$(cksum "$D")" = "$before" ] && ok "active swap: refuses before writes" || nok "active swap was written"; }
    echo 'Filename Type Size Used Priority' > "$W/wp/swaps"
    mkdir -p "$W/wp/sys/sdz/sdz3/holders/dm-test"
    ( base=sdz; log() { :; }; . "$W/wipe-sb.sh" ) && nok "active holder allowed writes" \
        || { [ "$(cksum "$D")" = "$before" ] && ok "active holder: refuses before writes" || nok "active holder was written"; }
    rmdir "$W/wp/sys/sdz/sdz3/holders/dm-test"
    wl=$(grep -n 'NCZ-WIPE-SIGNATURES-BEGIN' "$CHOOSER" | cut -d: -f1); zl=$(grep -n 'dd if=/dev/zero of="$D" bs=1M count=16' "$CHOOSER" | cut -d: -f1)
    [ -n "$wl" ] && [ -n "$zl" ] && [ "$wl" -lt "$zl" ] && ok "signatures cleared before the old table is zeroed" || nok "wipe runs after the table is gone"
else
    nok "disk-fs-chooser.sh: NCZ-WIPE-SIGNATURES markers missing"
fi
grep -q 'NCZ_GATE_STALE_DISK' "$GATE" && grep -q "is not the root partition's GPT GUID" "$GATE" && grep -q 'has an empty root=' "$GATE" \
    && ok "KVM gate: stale-disk seeding, empty root= and GPT-GUID checks on the installed menu" || nok "KVM gate PARTUUID checks missing"

echo "=== 8. Magnetar server menu vs desktop menus (MEDIUM_VARIANT) ==="
# The server menu (Console + Rescue Partition only) must come from the marker
# late.sh writes for a Magnetar medium -- at install AND on a kernel upgrade
# (the postinst.d hook calls the refresh with no NCZ_VARIANT). A desktop
# medium's no-desktop install records BUILD_VARIANT=server and COMPONENTS
# without desktop, and must keep its full menu.
HOOK="$ROOT/assets/refind/zz1-ncz-refind-refresh-amd64"
GATE_RE='^menuentry .*(\(Default\)|7\.3 Mali|Panthor|Rescue / No Accelerators)'
grep -qF "$GATE_RE" "$GATE" && ok "KVM gate: the server desktop-entry pattern is the one tested here" || nok "KVM gate pattern differs from the test's"
for s in "$AMD" "$ARM"; do
    n=$(basename "$s" .sh)
    between "$s" 'NCZ-MENU-VARIANT-BEGIN' 'NCZ-MENU-VARIANT-END' \
        | sed "s#/usr/local/lib/cix-installer#$W/mv/lib#g" > "$W/mv-$n.sh"
    awk '/^\{$/ {b=NR} /^\} > "\$REFIND_CONF"$/ {e=NR} {l[NR]=$0} END {for (i=b; i<=e; i++) print l[i]}' "$s" > "$W/menu-$n.sh"
    if [ ! -s "$W/mv-$n.sh" ] || ! grep -q 'REFIND_CONF' "$W/menu-$n.sh"; then nok "$n: NCZ-MENU-VARIANT block or menu block not found"; continue; fi
    # menu <marker|-> <BUILD_VARIANT> <components> [NCZ_VARIANT] -> "<variant>|<default>|<entries>|<desktop entries>"
    menu() {
        rm -rf "$W/mv"; mkdir -p "$W/mv/lib"
        [ "$1" = - ] || printf '%s\n' "$1" > "$W/mv/lib/MEDIUM_VARIANT"
        printf '%s\n' "$2" > "$W/mv/lib/BUILD_VARIANT"; printf '%s\n' "$3" > "$W/mv/lib/COMPONENTS"
        ( set +u; unset NCZ_VARIANT; [ -n "${4:-}" ] && NCZ_VARIANT=$4
          STABLE_AVAILABLE=1 NEXT_AVAILABLE=1 PANTHOR_ENTRY=1 KVER_STABLE=7.3.0-t2-ncz KVER_NEXT=7.3.0-sky1-ncz
          NCZ_RELEASE_SHORT="NCZ-OS 26.10 Cygnus" RESCUEPART_OPTIONS="root=PARTUUID=p" REFIND_CONF="$W/mv/refind.conf"
          REFIND_TIMEOUT=5 REFIND_BANNER="" REFIND_THEME="" REFIND_ICON="" BUILD_VERSION=t ROOT_FSTYPE=ext4
          # the default the script computed before this block: console when desktop is off
          case ",$3," in *,desktop,*) DEFAULT_TOKEN=Default ;; *) DEFAULT_TOKEN=Console ;; esac
          . "$W/mv-$n.sh" >/dev/null; . "$W/menu-$n.sh"
          printf '%s|%s|%s|%s' "$NCZ_MENU_VARIANT" "$DEFAULT_TOKEN" "$(grep -c '^menuentry ' "$W/mv/refind.conf")" \
              "$(grep -cE "$GATE_RE" "$W/mv/refind.conf")" )
    }
    case "$n" in *amd64*) full=4 ;; *) full=5 ;; esac
    r=$(menu - server rescue-partition)
    case "$r" in "desktop|Console|$full|"[1-9]*) ok "$n: desktop medium, desktop off (BUILD_VARIANT=server): keeps the full $full-entry menu" ;; *) nok "$n: desktop-medium no-desktop install changed menu: $r" ;; esac
    r=$(menu - desktop desktop,rescue-partition)
    case "$r" in "desktop|Default|$full|"*) ok "$n: desktop medium, desktop on: full menu, default unchanged" ;; *) nok "$n: desktop install: $r" ;; esac
    r=$(menu server server rescue-partition)
    case "$r" in "server|"*"Console"*"|2|0") ok "$n: Magnetar medium: Console + Rescue Partition only, default Console, no desktop entry" ;; *) nok "$n: server menu: $r" ;; esac
    grep -E '^menuentry ' "$W/mv/refind.conf" | grep -q 'Console' && grep -E '^menuentry ' "$W/mv/refind.conf" | grep -q 'Rescue Partition' \
        && ok "$n: the two server entries are Console and Rescue Partition" || nok "$n: server entries: $(grep '^menuentry ' "$W/mv/refind.conf")"
    r=$(menu server server rescue-partition desktop)
    case "$r" in "desktop|"*"|$full|"*) ok "$n: an explicit NCZ_VARIANT=desktop still wins over the marker" ;; *) nok "$n: env override: $r" ;; esac
    r=$(menu junk server rescue-partition)
    case "$r" in "desktop|"*) ok "$n: an unknown marker value is not a server medium" ;; *) nok "$n: junk marker: $r" ;; esac
done
# late.sh writes the marker only from a Magnetar medium (the fetch manifest).
awk '/^# MAGNETAR\(server\): record the MEDIUM/ {f=1} f {print} f && /^fi$/ {exit}' "$LATE" \
    | sed "s#/target/usr/local/lib/cix-installer#$W/lt#g" > "$W/late-mv.sh"
lt() { rm -rf "$W/lt" "$W/src"; mkdir -p "$W/src"; [ "$1" = server ] && : > "$W/src/ncz-fetch-payload.manifest"
    ( SRC="$W/src"; . "$W/late-mv.sh" >/dev/null ); cat "$W/lt/MEDIUM_VARIANT" 2>/dev/null || echo none; }
[ "$(lt server)" = server ] && ok "late.sh: a Magnetar medium records MEDIUM_VARIANT=server" || nok "late.sh server medium: $(lt server)"
[ "$(lt desktop)" = none ] && ok "late.sh: a desktop medium writes no MEDIUM_VARIANT" || nok "late.sh desktop medium: $(lt desktop)"
# Kernel upgrade: run the real amd64 postinst.d hook in a sandbox; its refresh
# (the menu-variant block + the menu writer) must still produce the server menu.
rm -rf "$W/hk"; mkdir -p "$W/hk/boot" "$W/hk/lib"
: > "$W/hk/boot/vmlinuz-7.3.0-t2-ncz"; echo x > "$W/hk/boot/initrd.img-7.3.0-t2-ncz"
cat > "$W/hk/refresh" <<HK
#!/bin/bash
[ -z "\${NCZ_VARIANT:-}" ] || { echo "hook passed NCZ_VARIANT=\$NCZ_VARIANT"; exit 3; }
STABLE_AVAILABLE=1 NCZ_RELEASE_SHORT=N RESCUEPART_OPTIONS=root=PARTUUID=p REFIND_CONF="$W/hk/refind.conf"
REFIND_TIMEOUT=5 REFIND_BANNER="" REFIND_THEME="" REFIND_ICON="" ROOT_FSTYPE=ext4 DEFAULT_TOKEN=Console
. "$W/hk/mv.sh"; . "$W/menu-ncz-refind-refresh-amd64.sh"
HK
chmod +x "$W/hk/refresh"
sed "s#/usr/local/lib/cix-installer#$W/hk/lib#g" "$W/mv-ncz-refind-refresh-amd64.sh" | sed "s#$W/mv/lib#$W/hk/lib#g" > "$W/hk/mv.sh"
sed -e "s#^REFRESH=.*#REFRESH=$W/hk/refresh#" -e "s#/usr/local/lib/cix-installer#$W/hk/lib#g" "$HOOK" > "$W/hk/hook"
hook() { rm -f "$W/hk/refind.conf" "$W/hk/lib/MEDIUM_VARIANT"; [ "$1" = - ] || echo "$1" > "$W/hk/lib/MEDIUM_VARIANT"
    env -u NCZ_VARIANT BOOTDIR="$W/hk/boot" bash "$W/hk/hook" > "$W/hk/out" 2>&1; printf 'rc=%s n=%s' "$?" "$(grep -c '^menuentry ' "$W/hk/refind.conf" 2>/dev/null)"; }
[ "$(hook server)" = "rc=0 n=2" ] && ok "kernel upgrade (amd64 postinst.d hook): a Magnetar install keeps the server menu" || nok "hook server: $(hook server) $(cat "$W/hk/out")"
[ "$(hook -)" = "rc=0 n=4" ] && ok "kernel upgrade (amd64 postinst.d hook): a desktop-medium install keeps the full menu" || nok "hook desktop: $(hook -) $(cat "$W/hk/out")"
# arm64's kernel-upgrade wrapper (11-fix-cixmini-boot.sh) must not pin a variant either.
! grep -q 'NCZ_VARIANT' "$ROOT/post-install/11-fix-cixmini-boot.sh" "$HOOK" \
    && ok "neither kernel-upgrade caller sets NCZ_VARIANT (the refresh decides from the marker)" || nok "a kernel-upgrade caller sets NCZ_VARIANT"

echo "=== 9. late.sh refreshes every boot-control script over a baked base ==="
# A baked base keeps its own assets ("baked wins"), but the rEFInd generators
# and the amd64 kernel hook must come from the medium, or a fix to them never
# reaches an install (2026-10-26: the amd64 server menu stayed the desktop one).
awk '/^        for REFIND_REFRESH in /{f=1} f{print} f && /^        done$/{exit}' "$LATE" > "$W/late-rr.sh"
if grep -q 'zz1-ncz-refind-refresh-amd64' "$W/late-rr.sh"; then
    rr() {  # rr <medium files...> -> rc + which DSTA copies now match the medium
        rm -rf "$W/rr"; mkdir -p "$W/rr/src/assets/refind" "$W/rr/dst/refind"
        for f in ncz-refind-refresh.sh ncz-refind-refresh-amd64.sh zz1-ncz-refind-refresh-amd64; do
            echo baked > "$W/rr/dst/refind/$f"; done
        for f in "$@"; do echo "medium $f" > "$W/rr/src/assets/refind/$f"; done
        ( SRC="$W/rr/src"; DSTA="$W/rr/dst"; . "$W/late-rr.sh" ) > "$W/rr/out" 2>&1; rc=$?
        printf 'rc=%s' "$rc"
        for f in ncz-refind-refresh.sh ncz-refind-refresh-amd64.sh zz1-ncz-refind-refresh-amd64; do
            grep -q medium "$W/rr/dst/refind/$f" && printf ' %s' "$f"; done
    }
    all="ncz-refind-refresh.sh ncz-refind-refresh-amd64.sh zz1-ncz-refind-refresh-amd64"
    [ "$(rr $all)" = "rc=0 $all" ] && ok "all three generators/hooks replace the baked copies" || nok "refresh all: $(rr $all) $(cat "$W/rr/out")"
    [ "$(rr ncz-refind-refresh.sh)" = "rc=0 ncz-refind-refresh.sh" ] && ok "a medium without the amd64 scripts still refreshes the arm64 one" || nok "arm64-only medium: $(rr ncz-refind-refresh.sh)"
    case "$(rr ncz-refind-refresh-amd64.sh zz1-ncz-refind-refresh-amd64)" in "rc=1"*) grep -q 'install media lacks refind/ncz-refind-refresh.sh' "$W/rr/out" \
        && ok "a medium without the arm64 generator is still FATAL" || nok "missing arm64 generator: wrong message" ;; *) nok "missing arm64 generator not fatal" ;; esac
else
    nok "late.sh boot-control refresh loop not found"
fi

echo "=== 10. KVM gate reads the default entry from default_selection ==="
awk '/^ncz_default_entry_root\(\) \{$/{f=1} f{print} f && /^\}$/{exit}' "$GATE" > "$W/defroot.sh"
if [ -s "$W/defroot.sh" ]; then
    . "$W/defroot.sh"
    conf() {  # conf <default_selection> <title=root>...
        { printf 'timeout 5\ndefault_selection "%s"\n' "$1"; shift
          for e in "$@"; do printf 'menuentry "NCZ-OS 26.10 Cygnus  -  %s" {\n    loader  /vmlinuz-k\n    options "root=PARTUUID=%s rootwait rw"\n}\n' "${e%%=*}" "${e#*=}"; done
        } > "$W/defroot.conf"; ncz_default_entry_root "$W/defroot.conf"; }
    [ "$(conf '7.3 (Default)' '7.3 (Default)=AAA' '7.3 Console=BBB' '7.3 Rescue / No Accelerators (Console)=CCC' 'Rescue Partition (Console)=DDD')" = aaa ] \
        && ok "amd64 desktop menu: the (Default) entry" || nok "amd64 desktop default entry"
    [ "$(conf '7.3 Console' '7.3 (Default)=AAA' '7.3 Console=BBB' '7.3 Rescue / No Accelerators (Console)=CCC')" = bbb ] \
        && ok "amd64 desktop off: the Console entry, not the Rescue (Console) one" || nok "amd64 console default entry"
    [ "$(conf '7.3 Mali (Default)' '7.3 Mali (Default)=AAA' '7.3 Panthor (Experimental)=EEE' '7.3 Console (All Accelerators, Mali)=BBB')" = aaa ] \
        && ok "arm64 desktop menu: the Mali (Default) entry" || nok "arm64 desktop default entry"
    [ "$(conf '7.3 Console (All Accelerators, Mali)' '7.3 Console (All Accelerators, Mali)=BBB' '7.3 Rescue Partition (Console)=DDD')" = bbb ] \
        && ok "arm64 Magnetar server menu (no (Default) entry): the Console entry" || nok "arm64 server default entry: '$(conf '7.3 Console (All Accelerators, Mali)' '7.3 Console (All Accelerators, Mali)=BBB' '7.3 Rescue Partition (Console)=DDD')'"
    [ "$(conf '7.3 Console' '7.3 Console=BBB' 'Rescue Partition (Console)=DDD')" = bbb ] \
        && ok "amd64 Magnetar server menu: the Console entry" || nok "amd64 server default entry"
else
    nok "KVM gate: ncz_default_entry_root not found"
fi

echo
echo "test-install-options: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
