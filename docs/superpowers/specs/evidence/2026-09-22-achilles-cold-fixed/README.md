# Real OVMF/qemu boot evidence — ACHILLES, 2026-09-22

This directory contains the full serial log captured from a real
`qemu-system-x86_64` + edk2 OVMF boot of a freshly cold-composed
amd64 ISO built with the post-Codex-fix `build/iso/write-image.py`,
`build/iso/build-refind-esp.py`, and `build/iso/verify-image.py`.

## Setup

* Host: `achilles` (192.168.207.11), x86_64 Linux
  (`Ubuntu 26.04.1 LTS`, kernel `7.0.0-31-generic`).
* Firmware: `/usr/share/OVMF/OVMF_CODE_4M.fd` (edk2 4 MiB variant),
  writable vars at `/tmp/boot-test/ovmf-vars.fd` copied from
  `/usr/share/OVMF/OVMF_VARS_4M.fd`.
* Image: `/tmp/cold.iso` (sha256
  `545c48e199b704fc32989be622b2c1864d9b367a0fe34292ef75987beae079d1`,
  125829120 bytes), produced by
  `python3 build/iso/write-image.py cold --arch amd64 ...`
  on ACHILLES after `git apply /tmp/codex-fixes.patch` (the patch
  generated from the four fix commits on the Mac side).
* qemu command:
  ```
  timeout 90 qemu-system-x86_64 \
      -machine q35,smm=on,accel=tcg \
      -cpu max -m 2048 \
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
      -drive if=pflash,format=raw,file=/tmp/boot-test/ovmf-vars.fd \
      -drive format=raw,if=virtio,readonly=on,file=/tmp/cold.iso \
      -serial file:/tmp/boot-test/cold-fixed.log \
      -display none -no-reboot
  ```

The serial console was redirected to `cold-fixed.log`. The raw log
contains ANSI terminal escapes (rEFInd's TUI uses them); the version
checked into this directory is the raw bytes that landed in the
serial file. `sed -E 's/\\x1B\\[[0-9;?]*[A-Za-z]//g'` would strip
them if a downstream reader wants a plain-text view.

## What the log shows (markers from the brief)

The brief requires "progression PAST rEFInd's own menu into the
actual Linux kernel booting and Debian Installer starting (kernel
decompression, 'Loading, please wait...', or equivalent d-i
early-boot output) — not just 'rEFInd - Main Menu' rendering."

| Marker (exact text)                                                     | Where in log | Status |
|-------------------------------------------------------------------------|--------------|--------|
| `BdsDxe: loading Boot0002 "UEFI Misc Device" ...`                       | line 1       | yes    |
| `rEFInd - Initializing...`                                              | line 5       | yes    |
| `rEFInd - Main Menu`                                                    | line 5       | yes    |
| `Use arrow keys to move cursor; Enter to boot`                          | line 5       | yes    |
| `Automatic boot in 0 seconds`                                           | line 5       | yes    |
| `rEFInd - Booting OS`                                                   | line 6       | yes    |
| `Starting linux`                                                        | line 6       | yes    |
| `Using load options 'auto=true priority=critical ... initrd=\initrd.gz'`| line 6       | yes    |
| `EFI stub: Loaded initrd from command line option`                      | line 6       | yes    |
| `[    0.000000] Linux version 6.1.0-50-amd64 ...` (kernel decompressing)| line 7       | yes    |
| `[    3.230169] Freeing initrd memory: 39856K`                           | line 366     | yes    |
| `Configuring the network with DHCP`                                     | line 630     | yes    |
| `Network autoconfiguration has succeeded`                               | line 630     | yes    |
| `[!!] Download debconf preconfiguration file` (d-i preseed prompt)      | line 652     | yes    |

All the brief's required progression markers are present in the log:
OVMF → rEFInd menu → kernel boot (Decompressing / running initrd)
→ d-i early-boot → d-i main installer prompt. The bar the brief set
(PAST rEFInd's menu, into the kernel and Debian Installer starting)
is cleared.

## Reproducing this on a different host

To reproduce from a checkout of this branch on any Linux host with
`qemu-system-x86_64` and an edk2 OVMF firmware file at hand:

```sh
# 1. Build the cold ISO (substrate + ESP from cache; ~1 second):
python3 build/iso/build-refind-esp.py \
    --arch amd64 \
    --d-i-kernel build/iso-cache/v1/nodes/amd64/substrate/*/extract/d-i/linux \
    --d-i-initrd build/iso-cache/v1/nodes/amd64/substrate/*/extract/d-i/initrd.gz \
    --out-dir prototype/work/esp

python3 build/iso/write-image.py cold \
    --arch amd64 \
    --substrate-node-dir build/iso-cache/v1/nodes/amd64/substrate/*/ \
    --esp-image prototype/work/esp/esp.img \
    --output /tmp/cold.iso

# 2. Boot under qemu + OVMF (90-second timeout is enough for the d-i
# preseed prompt to appear):
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd   # adjust to your host
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/ovmf-vars.fd
timeout 90 qemu-system-x86_64 \
    -machine q35,smm=on,accel=tcg \
    -cpu max -m 2048 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file=/tmp/ovmf-vars.fd \
    -drive format=raw,if=virtio,readonly=on,file=/tmp/cold.iso \
    -serial file:/tmp/cold-fixed.log \
    -display none -no-reboot
```

A passing run produces a `/tmp/cold-fixed.log` of ~76 KiB with the
same markers listed above.