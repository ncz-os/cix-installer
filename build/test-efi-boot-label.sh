#!/bin/bash
# test-efi-boot-label.sh -- the rEFInd NVRAM boot entry is labelled "NCZ-OS",
# and the refresh deletes rows with the new AND the pre-2026-10-26 label
# ("nclawzero (rEFInd)") before creating one, so an upgraded machine ends with
# exactly one entry. Other OS rows (and labels that merely contain the text)
# are never touched.
#
# The NCZ-EFI-BOOTENTRY block of both refresh scripts is extracted byte-exact
# and run against a stubbed efibootmgr that prints a fixture listing and logs
# every delete/create call.
# Run: bash build/test-efi-boot-label.sh   Exit 0 = pass, 1 = fail, 2 = extract failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

mkdir -p "$W/bin"
cat > "$W/bin/efibootmgr" <<'STUB'
#!/bin/sh
if [ $# -eq 0 ]; then cat "$NCZ_TEST_EFI_LIST"; exit 0; fi
printf '%s\n' "$*" >> "$NCZ_TEST_EFI_LOG"
STUB
chmod +x "$W/bin/efibootmgr"

TAB="$(printf '\t')"
# Real efibootmgr 18 output shape (Chimera, MacBookPro16,1): "Boot0000* <label><TAB><path>".
cat > "$W/upgraded.txt" <<EOF
BootCurrent: 0000
BootOrder: 0000,0080,0003,0005
Boot0000* nclawzero (rEFInd)${TAB}HD(1,GPT,05709464-9f3a-4d97-bb5f-23dd095f25ff,0x100,0x7a000)/\\EFI\\BOOT\\BOOTX64.EFI
Boot0003* NCZ-OS${TAB}HD(1,GPT,05709464-9f3a-4d97-bb5f-23dd095f25ff,0x100,0x7a000)/\\EFI\\BOOT\\BOOTX64.EFI
Boot0005  nclawzero (rEFInd)${TAB}HD(1,GPT,aaaa,0x100,0x7a000)/\\EFI\\BOOT\\BOOTX64.EFI
Boot0006* NCZ-OS Rescue USB${TAB}PciRoot(0x0)/USB(0x1,0x0)
Boot0007* nclawzero${TAB}HD(1,GPT,bbbb)/\\EFI\\systemd\\systemd-bootaa64.efi
Boot0080* Mac OS X${TAB}PciRoot(0x0)/Pci(0x1b,0x0)/Pci(0x0,0x0)//HD(2,GPT,ec02af44)/\\System\\Library\\CoreServices\\boot.efi
Boot0082* ${TAB}PciRoot(0x0)/Pci(0x1b,0x0)
EOF
# Older efibootmgr without the device path column.
cat > "$W/nopath.txt" <<'EOF'
BootOrder: 0001,0002
Boot0001* nclawzero (rEFInd)
Boot0002* debian
EOF
: > "$W/empty.txt"

for spec in "ncz-refind-refresh-amd64.sh:BOOTX64.EFI" "ncz-refind-refresh.sh:BOOTAA64.EFI"; do
    src="$ROOT/assets/refind/${spec%%:*}"; loader="${spec#*:}"; name="${spec%%:*}"
    blk="$W/$name.block"
    awk '/NCZ-EFI-BOOTENTRY-BEGIN/ {f=1; next} /NCZ-EFI-BOOTENTRY-END/ {f=0} f' "$src" > "$blk"
    [ -s "$blk" ] || { echo "EXTRACT FAILED: $name has no NCZ-EFI-BOOTENTRY block"; exit 2; }
    echo "== $name"
    grep -q 'nclawzero (rEFInd)"' "$src" && ! grep -q -- '-L "nclawzero (rEFInd)"' "$src" \
        && ok "$name: never creates an entry with the old label" || nok "$name: still creates the old label"
    run() {   # fixture -> writes $W/log
        : > "$W/log"
        # shellcheck disable=SC2034  # EFI_DISK/EFI_PART are read by the sourced block
        ( PATH="$W/bin:$PATH"; NCZ_TEST_EFI_LIST="$1"; NCZ_TEST_EFI_LOG="$W/log"; export NCZ_TEST_EFI_LIST NCZ_TEST_EFI_LOG
          EFI_DISK=nvme0n1; EFI_PART=1
          # shellcheck source=/dev/null
          . "$blk" ) >/dev/null 2>&1
    }
    run "$W/upgraded.txt"
    dels=$(sed -n 's/^-b \([0-9A-Fa-f]*\) -B$/\1/p' "$W/log" | sort | tr '\n' ' ')
    [ "$dels" = "0000 0003 0005 " ] && ok "$name: deletes old-label (active + inactive) and new-label rows: $dels" \
        || nok "$name: deleted '$dels', want '0000 0003 0005 '" "$(cat "$W/log")"
    grep -qE -- '-b (0006|0007|0080|0082) -B' "$W/log" && nok "$name: touched a row it does not own" "$(cat "$W/log")" \
        || ok "$name: leaves NCZ-OS Rescue USB, the systemd-boot 'nclawzero' row, Mac OS X and the unlabelled row alone"
    want="-c -d /dev/nvme0n1 -p 1 -L NCZ-OS -l \\EFI\\BOOT\\$loader"
    [ "$(grep -c -- '^-c ' "$W/log")" = 1 ] && grep -qxF -- "$want" "$W/log" \
        && ok "$name: creates exactly one row: $want" || nok "$name: create call wrong" "$(cat "$W/log")"
    [ "$(tail -1 "$W/log")" = "$want" ] && ok "$name: deletes before it creates" || nok "$name: create is not the last call"
    run "$W/nopath.txt"
    [ "$(sed -n 's/^-b \([0-9A-Fa-f]*\) -B$/\1/p' "$W/log" | tr '\n' ' ')" = "0001 " ] \
        && ok "$name: old efibootmgr listing without a path column: deletes only the NCZ row" || nok "$name: no-path listing" "$(cat "$W/log")"
    run "$W/empty.txt"
    [ "$(grep -c -- '-B' "$W/log")" = 0 ] && grep -qxF -- "$want" "$W/log" \
        && ok "$name: empty NVRAM: nothing deleted, one row created" || nok "$name: empty NVRAM" "$(cat "$W/log")"
done

echo
echo "test-efi-boot-label: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
