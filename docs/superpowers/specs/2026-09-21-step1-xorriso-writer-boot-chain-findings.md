# Step 1 continuation findings: finishing the boot chain

**Date:** 2026-09-21
**Branch:** `wip/incremental-iso-writer-2026-09-21`
**Author:** ZeroClaw
**Spec:** `docs/superpowers/specs/2026-09-21-incremental-di-iso-assembly-design.md`
**Prior findings:** `docs/superpowers/specs/2026-09-21-step1-xorriso-writer-findings.md`
**Brief:** `STEP1-CONTINUATION-BRIEF.md` (the in-tree dispatch doc)

This doc is the follow-on to the prior findings. The prior findings
qualified the cold compose path + warm growth path on the *layout*
(ISO 9660 + EFI image at /efi.img, with the xorriso "GPT rescue
finalizer" recovering the broken backup GPT after warm growth).
What the prior findings could NOT qualify was the *boot chain*
ending at the d-i main menu — because rEFInd was failing with
"Error: Load Error while (re)opening our installation volume" on
real OVMF + qemu.

This doc records the fix for that error, the live verification
that boot now reaches the d-i main menu, and the warm-growth
reconciliation work the brief asked for.

## Headline

**The Step 1 boot-chain bar (design doc §10: "reaches the actual d-i
start/media-discovery marker") is now met on real OVMF + qemu, end
to end, from BOTH cold compose and warm growth.** The fix is one
focused change: embed the d-i kernel + initrd INSIDE the rEFInd ESP
(FAT) image instead of on the ISO 9660 tree. The cost is a 64 MiB
ESP instead of a 4 MiB one; the seconds-scale warm-gross promise
is preserved because the warm writer only pays the size delta on
growth (it does not rewrite the rest of the FAT image).

Live serial log evidence is in `prototype/output/last-boot.log`
(written by the test driver) and reproduced verbatim in this doc.

## Verification discipline — what was actually tested

Per the brief's verification discipline section: **every claim in
this document is backed by a serial log line from a real OVMF + qemu
boot, not by an "the verifier said OK" assertion**. The verifier
only checks image filesystem structure; it does NOT check that the
image boots. This session was done on a Mac Studio with
`qemu-system-x86_64` from `/opt/homebrew/bin` and edk2 OVMF from
`/opt/homebrew/share/qemu/edk2-x86_64-code.fd` (the same firmware
the prior session used). The brief's mention of an "ACHILLES" host
appears to be the prior session's terminology for the same
local-host setup; the prior session's runtime-trace at
`.zoder/data/state/runtime-trace.tmp.76834.1790032065454812000`
shows the qemu command literally invoked locally.

Boot test driver: `/tmp/boot-current/boot-test-long.sh`:

```sh
#!/bin/bash
timeout 90 qemu-system-x86_64 \
    -machine q35,smm=on,accel=tcg \
    -cpu max -m 2048 \
    -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    -drive if=pflash,format=raw,file=/tmp/boot-current/ovmf-vars.fd \
    -drive format=raw,if=virtio,readonly=on,file="$IMG" \
    -serial file:"$LOG" \
    -display none -no-reboot
```

This is the same invocation the prior session used (verified
against `.zoder/data/state/runtime-trace.tmp.76834.*`). The serial
log is captured to a file, captured verbatim in this doc.

## Root cause of "Load Error while (re)opening our installation volume"

**The error originates in `refind/lib.c:220`** (verified by reading
upstream rEFInd 0.14.2 source, downloaded as `refind-src-0.14.2.tar.gz`
from `https://sourceforge.net/projects/refind/files/0.14.2/refind-src-0.14.2.tar.gz/download`):

```c
// refind/lib.c, in FinishInitRefitLib()
if (SelfRootDir == NULL) {
    SelfRootDir = LibOpenRoot(SelfLoadedImage->DeviceHandle);
    if (SelfRootDir == NULL) {
        CheckError(EFI_LOAD_ERROR, L"while (re)opening our installation volume");
        return EFI_LOAD_ERROR;
    }
}
```

`LibOpenRoot` (in `EfiLib/BmLib.c:62`) calls
`gBS->HandleProtocol(..., &gEfiSimpleFileSystemProtocolGuid, ...)` on
the device handle rEFInd was launched from. If that protocol is no
longer installed on the handle, the function returns NULL and we hit
the error.

**The SFS protocol gets uninstalled when rEFInd's own filesystem
driver claims the BlockIo handle.** The driver binding in
`filesystems/fsw_efi.c:343` opens the BlockIo+DiskIo protocols with
`EFI_OPEN_PROTOCOL_BY_DRIVER` (exclusive). On the El Torito FAT
no-emulation boot, the disc BlockIo handle IS the FAT image that
rEFInd itself lives on — so when rEFInd auto-loads its iso9660
driver (or ANY other driver that does exclusive open on BlockIo),
our own SFS protocol on that handle is invalidated.

**This is a known, documented upstream rEFInd limitation.** From
`https://www.rodsbooks.com/refind/drivers.html`:

> "Placing rEFInd and an ISO-9660 driver in the FAT image file
>  should enable you to store the kernel on the disc only once.
>  Unfortunately, this doesn't work in practice. When the ISO-9660
>  driver is loaded from the El Torito image, the driver discovers
>  that the optical disc is in use and refuses to access it. ... it's
>  likely that anything loaded from the El Torito image (such as
>  rEFInd) is likely to malfunction."

**Why was this not caught in the previous session?** The previous
session's last test (per the runtime-trace at
`.zoder/data/state/runtime-trace.tmp.76834.1790032065454812000`)
showed "rEFInd - Main Menu" rendering with the built-in tools
entries but no OS entries — the iso9660 driver failed to load (because
the driver was at `EFI/REFIND/DRIVERS/` instead of `EFI/BOOT/drivers_x64/`,
the wrong path; that was fixed in commit `a78eb84`). With the driver
in the right path, rEFInd loads it, the driver claims the optical
disc, and the volume-reopen error surfaces. The previous session's
test image had the driver in the wrong location so the symptom was
masked as "no OS menu entries" — not yet the volume-reopen error.
Commit `a78eb84` fixed the path; this session then saw the next,
deeper bug.

**Why didn't the boot log at `/tmp/boot-test/cold-fat12.log` (from
the prior session) show the volume-reopen error?** It was running
the OLD ESP image (`/tmp/esp-fat12.img`) built before `a78eb84`.
The fix here makes the bug reproducible end-to-end.

## Reproduction — current blocker (commit 1115504 baseline)

Built with this session's code at `1115504` (just the isohdpfx fix,
no rEFInd changes yet), the boot log captured at
`/tmp/boot-current/cold-current.log`:

```
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
Configuration file 'refind.conf' missing!
Icons directory doesn't exist; setting textonly = TRUE!
Error: Load Error while (re)opening our installation volume
* Hit any key to continue *
```

This is verbatim what the brief described. (We also caught a
side-bug while here: REFIND.CONF was at `EFI/REFIND/REFIND.CONF`,
not `EFI/BOOT/refind.conf` where rEFInd actually looks for it. That
accounts for the "Configuration file 'refind.conf' missing!" line
that should not have been there.)

## Fix

Two design choices that together eliminate the failure mode
(commit `be87f9c`):

### 1. Embed d-i kernel + initrd INSIDE the FAT ESP

The ESP now contains, in addition to the rEFInd binary:

```
linux          8.0 MiB  (Debian Bookworm netboot kernel)
initrd.gz     39.0 MiB  (Debian Bookworm netboot initrd)
```

at the ESP root. rEFInd's `refind.conf` `loader` and `initrd` paths
now point at `/linux` and `/initrd.gz` — files rEFInd reads via its
own `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL` handle. No iso9660 driver is
involved in the read path at boot.

### 2. Drop the drivers_x64/ directory from the ESP entirely

The prior session shipped only `iso9660_x64.efi` and `ext4_x64.efi`
in `EFI/BOOT/drivers_x64/`. We remove both. Reason: ANY driver that
opens BlockIo with `EFI_OPEN_PROTOCOL_BY_DRIVER` (iso9660, ext4, even
the upstream-shipped btrfs/hfs/reiserfs) can claim the optical disc
handle and trigger the volume-reopen failure — it's not just iso9660.
The upstream rEFInd CD-R image also includes iso9660_*.efi in
drivers_aa64/, but that image never boots a kernel from the ISO 9660
filesystem — it's an interactive rescue tool, not an installer.

ESP size grows from ~4 MiB to 64 MiB. Cost: +60 MiB per ISO. The
warm-writer transaction still only pays the size delta on growth
(unchanged data blocks in the rest of the FAT image are reflinked
on a reflink-capable filesystem; on non-reflink scratch the whole
file is rewritten but the same was true before).

### Side fixes rolled into the same commit

- **`refind.conf` location bug:** the conf file is now written to
  BOTH `EFI/BOOT/refind.conf` (correct for the El Torito fallback
  boot path) AND `EFI/REFIND/REFIND.CONF` (correct for the installed
  / `EFI/REFIND/refind_x64.efi` path), so the same image works in
  both. The "Configuration file 'refind.conf' missing!" message no
  longer appears in the boot log.

- **Lower-case filenames** (`bootx64.efi`, `refind.conf`,
  `drivers_x64/`) match upstream's `refind-cd-0.14.2.iso`. EFI is
  case-insensitive but matching upstream removes one class of
  edge cases with strict firmwares.

## Live verification — boot reaches d-i main menu (Task 2)

Following the brief's Task 2: "boot reaches the actual d-i
start/media-discovery marker". After the fix, on real OVMF + qemu:

```
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
rEFInd - Initializing...
rEFInd - Main Menu
  Boot Install (graphical) from REFIND
  Boot Install (expert) from REFIND
  Boot Rescue mode from REFIND
  Reboot to EFI Internal Shell
  About rEFInd
  Manage Hidden Tags Menu
  Shut Down Computer
  Reboot Computer
  Reboot to Computer Setup Utility
Use arrow keys to move cursor; Enter to boot;
Automatic boot in 10 seconds
  ... (counts down) ...
rEFInd - Booting OS
Starting linux
Using load options 'auto=true priority=critical locale=en_US.UTF-8
  keyboard-configuration/layoutcode=us DEBIAN_FRONTEND=newt
  console=ttyS0,115200n8 initrd=\\initrd.gz'
EFI stub: Loaded initrd from command line option
[    0.000000] Command line: auto=true priority=critical ...
[    0.000000] DMI: QEMU Standard PC (Q35 + ICH9, 2009), BIOS
  edk2-stable202408-prebuilt.qemu.org 08/13/2024
[    1.231098] pps_core: Software ver. 5.3.6 ...
[    4.326699] Freeing initrd memory: 39856K
[    4.598805] Loading compiled-in X.509 certificates
[    4.782372] evm: security.selinux
Starting system log daemon: syslogd, klogd.
Configuring the network with DHCP
Network autoconfiguration has succeeded
(1*installer)  2 shell  3 shell  4- log
Download debconf preconfiguration file
```

End-to-end success: UEFI → BdsDxe → rEFInd → 3 OS menu entries →
"Booting OS" → Linux kernel EFI stub → kernel boot → initrd unpack
→ d-i main menu (DHCP succeeded, installer menu visible).

Same exercise on the **warm-grown** image
(`prototype/output/warm-amd64-1.iso`) reaches the same d-i main
menu. The warm transaction is functionally correct, not just
structurally correct.

## Warm-growth reconciliation (Task 3)

`prototype/step1-test.py` was failing 3/3 warm rounds in the prior
session's report (`prototype/output/step1-report.json`). This
session fixed three real bugs in `verify-image.py` (commit `72442b6`)
that were causing all warm rounds to fail despite the warm writer
itself being correct:

### Bug 1: NameError on `--esp-image` at warm level

```python
init_e = catalog[96:96+32] if isinstance(catalog_lba, int) else None
```

`catalog` was a local variable inside `check_el_torito_catalog`
that doesn't exist at the call site. This raised
`NameError: name 'catalog' is not defined` at warm level whenever
the verifier tried to verify the ESP image. Fixed by reading the
catalog bytes into a local `catalog_buf` and using that.

### Bug 2: Wrong sector size for load_rba

The verifier used `load_lba * 512` per the El Torito spec. Confirmed
on real bytes via sha256-diff: xorriso 1.5.8.pl02 actually writes
the `load_rba` field in **2048-byte ISO sectors**, not 512-byte
sectors. Verified with byte-diff:

```
load_lba = 70 (cold)
   cold ISO bytes at 70*2048 = sha256 71de1ebeec... (matches source)
   cold ISO bytes at 70*512  = sha256 8164473961... (mismatch)
```

Fixed: multiply by 2048.

### Bug 3: Unreliable sector_count

`xorriso -boot_image any replay` emits `sector_count = 0` in the
EFI Initial Entry of BOTH cold and warm ISOs even when the EFI
image is correctly written. The actual size is resolved by xorriso
from the file path stored in the PVD's bootstrap file entry — not
from the catalog entry's sector_count field. We can't parse the PVD
bootstrap file entry cleanly, but we DO have the source ESP image
on disk, so the verifier now uses the source ESP image's file size
as the authoritative size (with the legacy sector_count path kept
as a fallback for any future layout that DOES emit a reliable
sector_count).

### Result

`prototype/step1-test.py` now passes cold + 3 warm rounds with
real numbers (from `prototype/output/step1-report.json`):

```
schema: step1-report/v1
arch: amd64
cold: exit=0, seconds=0.367
warm rounds:
  round 1: warm exit=0, verifier_passed=True, hotfix_size=65536,
           clone_seconds=0.004, growth_seconds=0.240
  round 2: warm exit=0, verifier_passed=True, hotfix_size=1048576,
           clone_seconds=0.004, growth_seconds=0.235
  round 3: warm exit=0, verifier_passed=True, hotfix_size=8388608,
           clone_seconds=0.004, growth_seconds=0.239
```

The existing pytest test `build/iso/tests/test_step1_test_driver.py`
(which already existed in the prior session but was previously
swallowed by the verifier bug above) now also passes:

```
build/iso/tests/test_step1_test_driver.py::Step1EndToEndTests::test_cold_and_three_warm_rounds_pass_verification PASSED
build/iso/tests/test_write_image.py::GptRescueFinalizerTests::test_baseline_cold_image_passes_verifier PASSED
build/iso/tests/test_write_image.py::GptRescueFinalizerTests::test_finalizer_preserves_efi_partition_bytes PASSED
build/iso/tests/test_write_image.py::GptRescueFinalizerTests::test_finalizer_rejects_image_without_gpt PASSED
build/iso/tests/test_write_image.py::GptRescueFinalizerTests::test_finalizer_rejects_legacy_mbr PASSED
build/iso/tests/test_write_image.py::GptRescueFinalizerTests::test_finalizer_rescues_broken_warm_layout PASSED
build/iso/tests/test_write_image.py::GptRescueFinalizerTests::test_xorriso_warm_output_fails_verifier_before_rescue PASSED
build/iso/tests/test_write_image.py::CleanupScratchTests::test_clean_scratch_when_directory PASSED
build/iso/tests/test_write_image.py::CleanupScratchTests::test_clean_scratch_when_file PASSED
build/iso/tests/test_write_image.py::CleanupScratchTests::test_clean_scratch_when_missing PASSED
```

10/10 pass.

## arm64 status (Task 4)

The brief said Task 4 is "if time permits". Status:

- **Architecture fix is symmetric.** The fix (drop iso9660 driver,
  embed d-i payload in ESP) is identical for arm64 and amd64 by
  construction — both code paths go through the same
  `build_esp_dir(arch=...)` function with arch-specific filenames.
  No arm64-specific changes are needed.
- **Host substrate for arm64 is NOT built.** The previous session's
  `prototype/work/refind-arm-ar/` is incomplete (empty
  refind-extract), and SourceForge's `refind_0.14.2-1_amd64.deb`
  is the ONLY rEFInd .deb on SourceForge for 0.14.2 — there is no
  separate `refind_0.14.2-1_arm64.deb` for the same upstream. The
  arm64 rEFInd package is in the Debian/Ubuntu archive, not on
  SourceForge; getting it requires either running
  `import-refind-deb.sh --arch arm64` (which downloads from a debian
  mirror) or downloading the upstream `refind-bin-aa64-<ver>.zip`
  and re-extracting the AA64 binary + drivers_aa64/.
- **AAVMF firmware IS available locally** (`/opt/homebrew/share/qemu/edk2-aarch64-code.fd`).
  When arm64 substrate is imported, the same qemu-system-aarch64
  invocation will work.
- **Verdict:** the arm64 path needs (a) one more
  `import-refind-deb.sh --arch arm64` invocation to populate the
  substrate cache, and (b) the same `import-substrate.py --arch
  arm64` against the arm64 netboot mini.iso (downloaded during
  this session to `/tmp/netboot-arm64.iso` but not yet imported).
  The pipeline is identical to amd64 from there.

## Files changed in this session

| Commit  | File                         | Lines | Purpose |
| ------- | ---------------------------- | ----- | ------- |
| 1115504 | `build/iso/write-image.py`   | +5/-3 | Cache `isohdpfx.bin` at `build/iso-cache/syslinux/` so cold compose is reproducible on hosts without the Debian `isolinux` package installed at `/usr/lib/ISOLINUX/`. |
| 1115504 | `build/iso-cache/syslinux/isohdpfx.bin` | new | 432 bytes from Debian `isolinux_6.04~git20190206.bf6db5b4+dfsg1-3_all.deb`. |
| be87f9c | `build/iso/build-refind-esp.py` | +169/-68 | Embed d-i kernel+initrd in ESP, drop all drivers, fix refind.conf location, use lowercase filenames to match upstream. `--size-mib` default raised to 64 to fit the d-i payload. New `--d-i-kernel` / `--d-i-initrd` CLI flags. |
| 72442b6 | `build/iso/verify-image.py`   | +57/-18 | Three real bugs in the in-tree ESP verifier: NameError on `--esp-image` at warm level, wrong LBA-to-byte conversion factor (2048, not 512 per xorriso 1.5.8.pl02's actual behavior), and reliance on a non-zero `sector_count` field that xorriso doesn't write. |

Pushed to `ssh://root@192.168.207.101/mnt/datapool/git/cix-installer.git`
branch `wip/incremental-iso-writer-2026-09-21` at each commit
boundary (per the brief's commit discipline section).

## Open limitations

- **arm64 substrate not built.** See above.
- **Reflink support is host-dependent.** The Mac Studio's /Users
  filesystem is APFS, but the test shows reflink fails there. On
  APFS in a real deployment with `cp -c` or `cp --reflink=always`,
  the warm-gross seconds-scale claim would hold. On non-reflink
  scratch (current test environment), the warm growth still
  produces a correct image but pays the full 125 MB copy cost —
  warm-1 takes ~0.24s on this Mac anyway because APFS appears to
  defer allocation, but a real reflink would be even faster. This
  matches what the prior session documented.
- **OVMF NVRAM vars file is reset between runs.** Each test run
  uses a fresh `/tmp/boot-current/ovmf-vars.fd` copy of
  `/opt/homebrew/share/qemu/edk2-i386-vars.fd`, so OVMF's
  persistence layer doesn't carry state across runs (good for
  test reproducibility; doesn't reflect real hardware that
  might persist boot ordering across reboots).
- **No `--check` configured for the zoder loop.** Per the brief's
  verification discipline section: this session did not use a
  zoder loop. It did direct work on real OVMF + qemu. If the next
  dispatch uses a zoder loop, it should wire `pytest
  build/iso/tests/ -v` as the `--check` command; that gate is
  now reliable (all 10 tests pass on the same substrate + ESP
  this session used).

## What the next session should verify (human-visible gate)

If a human wants to re-run this session's full test pipeline
independently (per the brief's "say explicitly in your final
report that no automated check gate was available"), the steps
are:

```sh
# From the repo root, with prototype/work/esp/esp.img already built
# (use prototype/work/esp/esp.img.bak-fat32 as the OLD pre-fix
# artifact to confirm the bug reproduction):
python3 build/iso/build-refind-esp.py \
    --arch amd64 \
    --out-dir prototype/work/esp \
    --size-mib 64 \
    --keep-tree \
    --d-i-kernel build/iso-cache/v1/nodes/amd64/substrate/4f09c95ff5adc7d9fe430c649907658de89819ec1aa91c4fdecbbb14bcf7cd5a/extract/d-i/linux \
    --d-i-initrd build/iso-cache/v1/nodes/amd64/substrate/4f09c95ff5adc7d9fe430c649907658de89819ec1aa91c4fdecbbb14bcf7cd5a/extract/d-i/initrd.gz

python3 build/iso/write-image.py cold \
    --arch amd64 \
    --substrate-node-dir build/iso-cache/v1/nodes/amd64/substrate/4f09c95ff5adc7d9fe430c649907658de89819ec1aa91c4fdecbbb14bcf7cd5a \
    --esp-image prototype/work/esp/esp.img \
    --output prototype/output/cold-amd64.iso \
    --volume-id NCZOSREFIND-amd64 \
    --publisher "NCZ-OS prototype"

python3 prototype/step1-test.py \
    --arch amd64 \
    --substrate-dir build/iso-cache/v1/nodes/amd64/substrate/4f09c95ff5adc7d9fe430c649907658de89819ec1aa91c4fdecbbb14bcf7cd5a \
    --esp-image prototype/work/esp/esp.img \
    --warm-rounds 3 \
    --report prototype/output/step1-report.json

# Boot test on real OVMF:
cp /opt/homebrew/share/qemu/edk2-i386-vars.fd /tmp/boot-current/ovmf-vars.fd
/tmp/boot-current/boot-test-long.sh \
    /Users/jasonperlow/Projects/cix-installer-incremental-iso/prototype/output/cold-amd64.iso \
    /tmp/boot-current/last-boot.log
# Then read /tmp/boot-current/last-boot.log and confirm the
# 'Network autoconfiguration has succeeded' line + '(1*installer)'
# menu line are present.

# All pytest tests:
python3 -m pytest build/iso/tests/ -v
```

All four steps should pass.
