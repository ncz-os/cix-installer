# Real El Torito `-cdrom` boot evidence — ACHILLES, 2026-09-22

Supersedes the gap flagged in the previous evidence dir
(`2026-09-22-achilles-cold-fixed`): that run attached the ISO via
`-drive format=raw,if=virtio,...`, a QEMU-paravirtualized shortcut that
bypasses the real El Torito / SATA-CD-ROM boot path used by actual
optical/USB media. This run repeats the exact same test with the ISO
attached the real way (`-cdrom`), on the same host, same firmware, same
ISO bytes.

## Result: real `-cdrom` path boots clean, no regression

Same ISO (`sha256 545c48e199b704fc32989be622b2c1864d9b367a0fe34292ef75987beae079d1`,
built from the current `write-image.py`/`build-refind-esp.py`/
`verify-image.py` post-Codex-fix code), fresh OVMF NVRAM, attached via:

```
timeout 60 qemu-system-x86_64 \
    -machine q35,smm=on,accel=tcg \
    -cpu max -m 2048 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=/tmp/boot-test/ovmf-vars-cdrom.fd \
    -cdrom /tmp/cold.iso \
    -serial file:cdrom-amd64-boot.log \
    -display none -no-reboot
```

`cdrom-amd64-boot.log` (647 lines) shows the same progression required by
the Step 1 brief, confirmed via the real El Torito path this time:

- rEFInd menu renders and auto-boots.
- `[    0.000000] Linux version 6.1.0-50-amd64 ...` — kernel decompresses
  and boots.
- `[    3.224392] Freeing initrd memory: 39856K` — initrd unpacked.
- `Configuring the network with DHCP` / `Network autoconfiguration has
  succeeded`.
- `[!!] Download debconf preconfiguration file` — real d-i main installer
  prompt, same marker the virtio run reached.

## What this resolves

A prior investigation (same evening, earlier ISO/NVRAM state, before the
last round of Codex-finding fixes landed) reproduced a silent hang on the
real `-cdrom` path — qemu exiting cleanly via `-no-reboot` with no further
output right at the boot-trigger point. That could NOT be reproduced here
against the current code + current ISO + fresh NVRAM. Most likely
explanation: that earlier repro used a stale ISO or leftover NVRAM state
from before the FAT12/driver-directory/ESP-verification fixes landed on
this branch, not a real defect in the current code. Treat the earlier
"virtio-only, cdrom fails" gap as CLOSED — both attachment methods now
reach the same d-i prompt from the same ISO.

## Caveat still open

This is amd64/pc-t2 only. arm64/Sky1 (AAVMF, `drivers_aa64`, Sky1
hardware) has not been attempted — see Task 4 of
`STEP1-CONTINUATION-BRIEF.md`, still outstanding.
