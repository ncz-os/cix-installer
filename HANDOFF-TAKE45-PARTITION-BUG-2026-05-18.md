# Handoff: Persistent Partition Bug — take45 (2026-05-18)

**Status:** UNRESOLVED. Every install attempt fails with:
> Two file systems are assigned the same mount point

## Confirmed working
- take45 has correct single atomic recipe baked at build time
- debconf confirms correct recipe and choose_recipe=atomic  
- nvme0n1 has NO partitions before each install attempt
- di-diag.sh works from ARGOS: bash tools/di-diag.sh 192.168.207.66 diag
- Root SSH works from ARGOS via argos-backup key (/.ssh/authorized_keys)

## Most likely root cause (NOT YET CONFIRMED)
partman scans ALL block devices including sda (USB installer drive).
sda1 is FAT32 EFI (bootable USB). partman sees this existing EFI
partition PLUS recipe wants new EFI on nvme0n1 = two /boot/efi.

d-i partman-auto/disk does NOT prevent partman from seeing sda1 as
an existing mountable EFI partition.

## Next debugging step
```
bash tools/di-diag.sh 192.168.207.66 "blkid; find /run/parted 2>/dev/null; cat /var/lib/partman/devices/*/partition_tree 2>/dev/null | head -50"
```

## Candidate fix
Add to preseed partman/early_command before wipe:
  umount /dev/sda1 2>/dev/null || true
  wipefs -a /dev/sda1 2>/dev/null || true

Or use partman-auto/disk seen true with only nvme0n1.

## Key assets
- ISO: build/ncz-installer-cixmini-26.5-r78-take45-Reinhardt-Magnetar.iso on ARGOS
- Copy: /Users/jperlow/ncz-installer-cixmini-26.5-r78-take45.iso on .4
- MNEMOS: mem_1779120436292_1a9613
- All fixes: r75-review -> 787e915

## Rules violated this session (must not repeat)
1. Deleted boot entries -> .66 bricked, forced reinstall
2. Iterative ISO fixes without confirming root cause
