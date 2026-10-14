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
#   6. the first-boot report records what the boot reached.
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
    awk '/^    if \[ -n "\$RESCUEPART_OPTIONS" \]; then$/ {g=1} g && /Rescue Partition/ {print "gated"; exit}' "$s" | grep -q gated \
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
for h in 37-failsafe-access.sh 38-recovery-container.sh; do
    printf '%s\n' "$h" | grep -qE "$mg" && ok "mgmt-container off skips $h" || nok "mgmt-container off does not skip $h"
done
printf '%s\n' 72-rescue-partition.sh | grep -qE "$rs" && ok "rescue-partition off skips 72-rescue-partition.sh" || nok "rescue skip"
printf '%s\n' 36-telemetry.sh 70-bootloader.sh | grep -qE "$mg|$rs" && nok "an option skip drops 36-telemetry or 70-bootloader" || ok "telnet :23 (36) and the bootloader (70) are never option-skipped"

ml=$(grep -n '^cat /proc/sys/kernel/random/boot_id > "\$NCZ_INSTALL_MARK"' "$RUNALL" | head -1 | cut -d: -f1)
p0=$(grep -n '^# Phase 0: diagnostic affordance hooks' "$RUNALL" | head -1 | cut -d: -f1)
[ -n "$ml" ] && [ -n "$p0" ] && [ "$ml" -lt "$p0" ] && ok "run-all.sh writes the install marker before the first hook" || nok "install marker not written before the hooks ($ml vs $p0)"
awk '/^finalize_bootloader\(\) \{/ {f=1} f && /rm -f .*INSTALL_IN_PROGRESS/ {r=NR} f && /bash "\$HOOK_DIR\/70-bootloader.sh"/ {b=NR; exit} END {exit !(r && b && r < b)}' "$RUNALL" \
    && ok "finalize_bootloader removes the marker before 70-bootloader.sh" || nok "marker not removed before 70-bootloader.sh"

echo "=== 5. KVM gate options ==="
between "$GATE" 'NCZ-GATE-COMPONENTS-BEGIN' 'NCZ-GATE-COMPONENTS-END' > "$W/gate-comp.sh"
if [ -s "$W/gate-comp.sh" ]; then
    gc() { ( NCZ_GATE_COMPONENTS="$1"; [ "$1" = UNSET ] && unset NCZ_GATE_COMPONENTS; . "$W/gate-comp.sh" 2>/dev/null; printf '%s|%s|%s%s%s' "$GATE_COMPONENTS_ARG" "$EXPECT_RECORD" "$WANT_DESKTOP" "$WANT_MGMT" "$WANT_RESCUE" ) || echo "rc=$?"; }
    [ "$(gc UNSET)" = "desktop,mgmt-container,rescue-partition|desktop,browsers,wallpaper-rotator,mgmt-container,rescue-partition|111" ] && ok "default: every option" || nok "default: $(gc UNSET)"
    [ "$(gc desktop)" = "desktop|desktop,browsers,wallpaper-rotator|100" ] && ok "desktop only (rescue off + mgmt off)" || nok "desktop: $(gc desktop)"
    [ "$(gc desktop,mgmt-container)" = "desktop,mgmt-container|desktop,browsers,wallpaper-rotator,mgmt-container|110" ] && ok "rescue off + mgmt on" || nok "desktop,mgmt: $(gc desktop,mgmt-container)"
    [ "$(gc none)" = "none|none|000" ] && ok "none: every option off" || nok "none: $(gc none)"
    [ "$(gc 'rescue-partition, mgmt-container')" = "mgmt-container,rescue-partition|mgmt-container,rescue-partition|011" ] && ok "desktop off, in the selector's order" || nok "nodesktop: $(gc 'rescue-partition, mgmt-container')"
    [ "$(gc desktop,bogus)" = "rc=2" ] && ok "an unknown option is refused (exit 2)" || nok "unknown option: $(gc desktop,bogus)"
    # The record shape is the selector's: desktop expands to desktop,browsers,wallpaper-rotator.
    grep -q '\[ "\$WANT_DESKTOP" = 1 \]     && CHOSEN="desktop,browsers,wallpaper-rotator"' "$ROOT/preseed/component-selector.sh" \
        && ok "record shape matches preseed/component-selector.sh" || nok "component-selector.sh record shape changed; update the gate's EXPECT_RECORD"
else
    nok "KVM gate: NCZ-GATE-COMPONENTS markers missing"
fi
grep -q 'ncz_components=\$GATE_COMPONENTS_ARG' "$GATE" && ok "the gate passes the answer on the Install cmdline" || nok "gate cmdline still fixed"
grep -q 'VERIFY_EXPECT_COMPONENTS="\$EXPECT_RECORD"' "$GATE" && ok "the gate hands the expected record to the verifier" || nok "verifier not told the record"
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
    [ "$GATE_DEFAULT_SETS" = "norescue minimal" ] && ok "matrix default sets: rescue off + mgmt off, every option off" || nok "matrix default: $GATE_DEFAULT_SETS"
    grep -q "NCZ_KVM_GATE_VARIANTS:-norescue minimal" "$ROOT/build/build-image.sh" && grep -q 'build/kvm-install-gate-matrix.sh' "$ROOT/build/build-image.sh" \
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

echo
echo "test-install-options: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
