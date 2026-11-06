#!/bin/bash
# test-guest-ext4-recover.sh -- the KVM gate reads the first-boot report off a guest root
# that was stopped by timeout, so it must repair a scratch copy before debugfs can open it.
#
# Regression (2026-10-26, Preview4 arm64): the phase-2 guest wrote
# /var/log/ncz-first-boot-failed.txt (now ncz-first-boot-report.txt), qemu was stopped at the boot timeout, the root
# was left needs_recovery, and debugfs refused it with "Inode bitmap checksum does
# not match bitmap while reading allocation bitmaps". The gate swallowed that and
# failed with "no first-boot report".
#
# Fixture: a small ext4 made by mke2fs -d holding the report, with the inode bitmap
# checksum of group 0 corrupted the same way (debugfs set_bg). Proves:
#   1. debugfs cannot read the report from the damaged copy (the incident);
#   2. ncz_guest_ext4_recover repairs it and returns 0, and the report reads back;
#   3. a file that is not an ext4 filesystem makes it return non-zero;
#   4. the gate sources lib/guest-ext4.sh and recovers before its first-boot dump;
#   5. the gate reads the path 97-firstboot-report writes (ncz-first-boot-report.txt)
#      and falls back to the pre-2026-10-26 name for older images.
#
# Linux only (e2fsprogs). Run: bash build/test-guest-ext4-recover.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GATE="$HERE/kvm-install-gate-gpt.sh"
# shellcheck source=lib/guest-ext4.sh
. "$HERE/lib/guest-ext4.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

if [ "$(uname -s)" != Linux ]; then
    echo "test-guest-ext4-recover: SKIP (Linux only)"; exit 0
fi
MKE2FS="$(command -v mke2fs || echo /sbin/mke2fs)"
DEBUGFS="$(command -v debugfs || echo /sbin/debugfs)"
if [ ! -x "$MKE2FS" ] || [ ! -x "$DEBUGFS" ]; then
    echo "test-guest-ext4-recover: SKIP (e2fsprogs not installed)"; exit 0
fi
T="$(mktemp -d "${TMPDIR:-/tmp}/guest-ext4.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/root/var/log"
printf '# first boot report 2026-10-26T03:51:37Z\n# end\n' > "$T/root/var/log/ncz-first-boot-report.txt"
truncate -s 64M "$T/root.raw"
"$MKE2FS" -q -t ext4 -d "$T/root" "$T/root.raw" || { echo "FATAL: mke2fs failed" >&2; exit 2; }
"$DEBUGFS" -w -R "set_bg 0 inode_bitmap_csum 0x1234" "$T/root.raw" >/dev/null 2>&1

# 1. the incident: debugfs refuses the damaged copy
out="$("$DEBUGFS" -R "cat /var/log/ncz-first-boot-report.txt" "$T/root.raw" 2>&1)"
if grep -q "first boot report" <<<"$out"; then
    bad "fixture is not damaged: debugfs read it directly"
else
    ok "damaged copy: debugfs cannot read the report ($(grep -m1 -o 'checksum does not match[^.]*' <<<"$out" || echo refused))"
fi

# 2. recovery repairs it
if ncz_guest_ext4_recover "$T/root.raw" "$T/e2fsck.log"; then
    ok "ncz_guest_ext4_recover returns 0 on a repairable copy ($(tail -1 "$T/e2fsck.log"))"
else
    bad "ncz_guest_ext4_recover failed: $(tail -3 "$T/e2fsck.log")"
fi
"$DEBUGFS" -R "dump /var/log/ncz-first-boot-report.txt $T/report" "$T/root.raw" >/dev/null 2>&1
grep -q "^# first boot report" "$T/report" 2>/dev/null \
    && ok "after recovery the first-boot report reads back" || bad "report still unreadable after recovery"

# 3. not a filesystem at all
head -c 1048576 /dev/zero > "$T/zero.raw"
if ncz_guest_ext4_recover "$T/zero.raw" "$T/e2fsck-zero.log"; then
    bad "ncz_guest_ext4_recover returned 0 for a non-ext4 file"
else
    ok "a non-ext4 file is reported as unrecoverable"
fi

# 4. the gate uses it before reading the first-boot report
grep -q '^\. "\$SCRIPT_DIR/lib/guest-ext4.sh"' "$GATE" && ok "gate sources lib/guest-ext4.sh" || bad "gate does not source lib/guest-ext4.sh"
rec=$(grep -n 'ncz_guest_ext4_recover "\$FB_ROOT"' "$GATE" | head -1 | cut -d: -f1)
dmp=$(grep -n 'dump /var/log/ncz-first-boot-report.txt' "$GATE" | head -1 | cut -d: -f1)
if [ -n "$rec" ] && [ -n "$dmp" ] && [ "$rec" -lt "$dmp" ]; then
    ok "gate recovers the scratch root (line $rec) before the first-boot dump (line $dmp)"
else
    bad "gate does not recover the scratch root before the first-boot dump (recover=${rec:-none} dump=${dmp:-none})"
fi

# 5. one name end to end: 97 writes it, its unit is conditioned on it, the gate dumps it
HOOK="$HERE/../post-install/97-firstboot-report.sh"
grep -q '} > /var/log/ncz-first-boot-report.txt' "$HOOK" && grep -q '^ConditionPathExists=!/var/log/ncz-first-boot-report.txt$' "$HOOK" \
    && ok "97-firstboot-report writes and conditions on /var/log/ncz-first-boot-report.txt" || bad "97-firstboot-report path mismatch"
grep -v '^#' "$HOOK" | grep -q 'ncz-first-boot-failed.txt' && bad "97-firstboot-report still names ncz-first-boot-failed.txt outside a comment" || ok "97-firstboot-report no longer writes the old name"
leg=$(grep -n 'dump /var/log/ncz-first-boot-failed.txt' "$GATE" | head -1 | cut -d: -f1)
if [ -n "$leg" ] && [ -n "$dmp" ] && [ "$leg" -gt "$dmp" ] && sed -n "${leg}p" "$GATE" | grep -q '\[ -s "\$FBR" \] ||'; then
    ok "gate falls back to the old ncz-first-boot-failed.txt only when the new report is absent (line $leg)"
else
    bad "gate has no legacy-name fallback after the new-name dump (legacy=${leg:-none})"
fi

echo "guest-ext4-recover tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
