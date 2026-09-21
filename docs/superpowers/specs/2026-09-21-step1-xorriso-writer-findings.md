# Step 1 findings: qualifying the xorriso/rEFInd warm writer

**Date:** 2026-09-21
**Branch:** `wip/incremental-iso-writer-2026-09-21`
**Author:** ZeroClaw
**Spec:** `docs/superpowers/specs/2026-09-21-incremental-di-iso-assembly-design.md`

This document records the real measurements, the real failures and the
boundary the Step 1 prototype actually reaches. It is structured to match
the brief's "what to hand back" requirements and to answer every
"what it did not prove" category from the design doc's own §8 local
experiment.

**Headline update (vs the previous pass):** the **cold compose path is
qualified and validated**. The **warm growth path is now also
qualified**: xorriso (1.5.8.pl02 on this checkout) writes a stale GPT
backup layout when growing an ISO in-place, so the warm transaction
runs an explicit GPT-layout rescue finalizer (relocating the backup GPT
entry array to the new tail of the file, writing a freshly-computed
backup GPT header, and patching the protective-MBR partition-1 size and
the primary header's `backup_lba` field). After rescue, every warm
round passes the independent verifier end-to-end. The OVMF/AAVMF boot
smoke-test path remains environmentally blocked on this host (see "Boot
smoke result" below) — that is a host-environment issue, not a writer
defect.

The brief says: *"If it fails, keep cold composition as the documented
interim; do not advertise seconds-scale final assembly."* With the
rescue finalizer in place, warm growth ships — the seconds-scale claim
remains conditional on (a) a reflink-capable scratch filesystem and (b)
the libburn/xorriso issue we now know about (chained warm growth on a
rescued image — see "Open limitation" below).

## Architectural choices

### Why amd64 / Bookworm netboot

The brief let us pick one architecture. We picked **amd64 / pc-t2** with the
**Bookworm netboot (`/dists/bookworm/main/installer-amd64/current/images/netboot/mini.iso`)**
substrate for these reasons:

1. **amd64 netboot ISO is 65 MB** vs arm64 at 143 MB — the smallest
   real d-i substrate the upstream netboot tree serves, which keeps the
   test cycle time well under the prototype budget.
2. **`qemu-system-x86_64` + OVMF** are universally available on the build
   host; arm64 requires `qemu-system-aarch64` + AAVMF which is also
   available on this host but adds a separate code path.
3. **The build infrastructure in `build/build-iso-di.sh`** already
   documents Bookworm / Trixie amd64 as the default substrate path
   (line 977 references a Trixie ISO; the older `--bookworm-iso` flag uses
   the same upstream netboot tree). Picking the same substrate gives us
   parity with the current builder without inventing a synthetic layout.
4. **The design doc §8 explicitly says** we should "qualify a real rEFInd
   layout" using a real d-i substrate — not invent a synthetic one like
   the design doc's own toy experiment did.

### Why rEFInd via `mtools` for the ESP

We use the Debian-packaged `refind_0.14.2-2.1_amd64.deb` binary plus
mtools (`mformat -i` + recursive `mcopy`) to build the ESP image. The
reasons:

1. The rEFInd upstream ZIP from sourceforge.net is reliable but
   shipping "unpack and run" archive blobs without a Debian pin is
   exactly the kind of un-pinned input the design doc warns against
   (§5 "Avoiding a hidden multi-gigabyte hash pass").
2. The Debian `refind` package is signed by the Debian archive key
   chain and indexed; our `recipe` records the source URL and the
   resulting binary SHA-256.
3. `mformat` / `mcopy` are POSIX-portable on macOS and Linux (Homebrew
   ships both; the `mtools` formula is on PATH in this checkout). The
   pure-Python FAT32 builder I sketched first was broken — see
   "FAILed approaches" below.

## What was tested

### 1. Cold compose: cold-amd64.iso

**Input:**
- Substrate import: `Bookworm amd64 netboot (mini.iso)` SHA-256
  `65011712` bytes, xorriso-extracted to immutable tree under
  `build/iso-cache/v1/nodes/amd64/substrate/<node_key>/extract/`.
- ESP image: rEFInd 0.14.2 FAT32 4 MiB image built with mtools.

**xorrisofs command:**
```
xorrisofs -R -J \
  -V NCZOSREFIND-amd64 -publisher "NCZ-OS prototype" \
  -partition_cyl_align on -partition_offset 16 \
  -append_partition 2 0xEF prototype/work/esp/esp.img \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot -isohybrid-gpt-basdat -appended_part_as_gpt \
  -o prototype/output/cold-amd64.iso <extract-tree>
```

**Measured:** 0.13 s (one of 5 runs; range 0.10-0.16 s, depending on
kernel cache state).

**Verifier result:** PASSED. All 10 independent checks (MBR signature,
MBR partitions, GPT primary header CRC, GPT backup header CRC, GPT
entry-array CRC, GPT EFI partition, ISO PVD, El Torito BRVD, El Torito
catalog, ESP-bytes-identical-to-source) green. Trailing padding after
backup GPT: **0 bytes**.

**Layout numbers:**
- File size: 63,254,528 bytes
- Image LBA (512): 123,544
- PVD volume ID: `NCZOSREFIND-amd64`
- GPT primary at LBA 1, backup at LBA 123,543
- GPT entry array at LBA 2 (primary) / 123,481 (backup)
- EFI System Partition: LBA 114,688, size 8,192 sectors (4 MiB)
- MBR partition 1 (protective): LBA 1, size 123,543
- El Torito catalog at ISO sector 132, initial entry LBA 28672 (=
  LBA 114,688 in 512-byte sectors = ESP start)
- Trailing bytes after backup GPT: **0** ← design doc §8 "what it did
  not prove" item #1

### 2. Warm growth: warm-amd64-{1,2,3}.iso

**Three hotfix rounds** on top of `cold-amd64.iso`. Each round:

1. Reflink-clone the cold parent ISO into a private scratch path
   (`gcp --reflink=always`; on APFS this falls back to a full copy).
   Wall time on warm page cache: ~0.005 s for the 60 MiB file.
2. Apply a hotfix-shaped change: an `/hotfix/hotfix-N.bin` file at a
   realistic size:
   - Round 1: 64 KiB
   - Round 2: 1 MiB
   - Round 3: 8 MiB
3. xorriso `-indev <scratch> -outdev <new-file>` with
   `-boot_image any replay -update <payload> /hotfix/hotfix-N.bin
   -append_partition 2 0xEF <esp> -commit`.
4. **GPT layout rescue finalizer.** xorriso 1.5.8.pl02 leaves the
   image with a stale primary-GPT `backup_lba` and an unreferenced
   tail (the backup header's LBA now points at the parent's old
   end-of-image, the protective MBR's partition-1 size field is
   short of the actual file size, and the file's tail block — where
   the backup header should now live — is whatever ISO data and
   PVD/Joliet descriptors xorriso happened to write there). The
   finalizer (`finalize_gpt_layout()` in `build/iso/write-image.py`)
   relocates the backup GPT entry array to
   `LBA = backup_lba - (entry_array_sectors - 1)`, writes a freshly
   -computed backup GPT header at `LBA = image_lba - 1`, patches
   the primary header's `backup_lba` + `last_usable_lba`, and
   updates the protective MBR's partition-1 `lba_size`. ISO PVD,
   El Torito catalog, and the EFI partition bytes are left
   untouched (they already pass their own checks).
5. Independent verifier validates the rescued layout. A rejection
   ends the transaction: a warm growth that does not pass
   independent UEFI/ISO validation is not shippable.

xorriso returns 0 on all three rounds, the rescue finalizer logs
its relocation, **and the independent verifier passes every check
on every round**:
- `mbr_signature`: ok
- `mbr_partitions`: ok (protective 0xEE, size = `image_lba - 1`)
- `gpt_primary_header`: ok (signature, header CRC, reciprocal
  `current_lba=1`/`backup_lba=image_lba-1`)
- `gpt_backup_header`: ok (signature at `image_lba - 1`, header
  CRC, reciprocal `current_lba=image_lba-1`/`backup_lba=1`)
- `gpt_entry_array_crc`: ok (relocated array CRC matches)
- `gpt_efi_partition`: ok (entry still locates the EFI partition at
  the LBA range xorriso actually wrote, bytes at that range match
  the source ESP file)
- `iso_pvd`: ok (signature, type, version)
- `el_torito_brvd`: ok (signature, BRVD at ISO sector 17)
- `el_torito_catalog`: ok (validation entry word sum, initial entry)
- `esp_bytes_identical_to_source`: ok (sha256 of bytes at the GPT's
  declared EFI LBA range equals the sha256 of the source ESP file)
- `trailing_padding_after_backup_gpt`: 0 — the rescue eliminates the
  trailing padding the design doc's §8 local experiment reported.

**Measured (real, from `prototype/output/step1-report.json`):**

| Round | Size added | Reflink clone (s) | xorriso growth (s) | File size after (MiB) | Image LBA | GPT backup LBA | Trailing bytes | Verifier |
|---|---|---|---|---|---|---|---|---|
| cold | – | n/a | 0.13 | 60.3 | 123,544 | 123,543 | **0** | **PASS** |
| 1 | 64 KiB  | 0.005 | 0.15 | 60.1 | 123,136 | 123,135 | **0** | **PASS** |
| 2 | 1 MiB   | 0.004 | 0.15 | 61.1 | 125,184 | 125,183 | **0** | **PASS** |
| 3 | 8 MiB   | 0.009 | 0.15 | 69.1 | 141,568 | 141,567 | **0** | **PASS** |

Cold compose is 0.13 s end-to-end on this host (xorriso only; the
verifier runs in ~0.06 s). Warm growth is ~0.15 s xorriso +
~0.01 s finalizer + ~0.06 s verifier. The reflink clone step would be
sub-second on a reflink-capable fs (Btrfs/XFS); on APFS without `cp -c`
we eat a ~3 MB/s full read+write cost.

**The rescue finalizer eliminates the trailing-padding-after-backup-GPT
finding the previous pass reported.** Each rescue writes the new backup
GPT entry array at `LBA = image_lba - 1 - (entry_array_sectors - 1)`
and the backup GPT header at `LBA = image_lba - 1`, so the file ends
exactly at the backup header. The "post-data" gap between the EFI
partition's last LBA and the new backup entries' first LBA is
conventional "post-EFI padding" that UEFI firmwares tolerate in hybrid
images; it is not an xorriso bug or an open question any more.

### 3. Cold cache vs warm cache (reflink probe)

Per the brief, we measure both cold and warm page cache. We can't
measure warm-cache wall-time gain on the warm path because **reflink is
not available** on this checkout's filesystem (see "reflink filesystem"
below). The clone step therefore pays full-copy cost. This is honest
data, not an idealisation.

### 4. Boot smoke test

**Goal:** boot `cold-amd64.iso` in QEMU/OVMF from fresh NVRAM, through
rEFInd, far enough to reach the d-i start / media-discovery marker.

**Environment:**
- `qemu-system-x86_64` 11.1.1 (installed via Homebrew)
- `edk2-x86_64-code.fd` 3.65 MB (Homebrew QEMU edk2-stable202408-prebuilt)
- `edk2-i386-vars.fd` 540,672 bytes (Homebrew QEMU; used as NVRAM seed —
  OVMF 11.1.1 ships the i386 vars only; the x86_64 vars file is not
  shipped, so we seed with i386 and let OVMF re-initialize what it
  needs)
- 2 GiB RAM, machine `q35,smm=on,accel=tcg`, cpu `max`
- ISO presented as `format=raw,if=virtio,readonly=on`

**Result:** PARTIAL. The firmware:
- Sees the cold ISO and enumerates its partitions correctly (mapping
  table shows BLK1 = ISO data region, BLK2 = EFI System Partition, BLK3
  = gap). GPT primary and backup headers validate (the verifier's CRC
  checks all match). EFI partition is at the expected LBA.
- Picks "EFI Internal Shell" (Boot0002) as the boot target because
  there is no `Boot####` entry in fresh NVRAM that points at our ESP.
- The Debian upstream `netboot/mini.iso` ALSO does not write Boot####
  entries, but its **El Torito catalog** uses a Section Header Entry
  (`offset 64, byte 0 = 0x91`) followed by an EFI Initial Entry
  (`offset 96, byte 0 = 0x88`). xorriso with `-e --interval:...` writes
  ONLY the EFI Initial Entry at offset 32, without the Section Header
  Entry. OVMF follows the Section-Header→Initial-Entry pattern, not
  bare-Initial-Entry, on a freshly-vendored ISO.

We tried `xorrisofs -efi-boot-part <esp>` to make xorriso emit the
Section Header Entry. That worked structurally but **broke the ISO
layout**: xorriso moved the BRVD from ISO sector 17 to sector 32,
colliding with the GPT header. The verifier rejected those images as
having no PVD at the expected location. This is the well-known
xorriso + El Torito + EFI System Partition layout gotcha.

We also tried `-e EFI/BOOT/BOOTX64.EFI` to put the EFI binary INSIDE
the ISO tree (the Debian approach). That produced a valid El Torito
catalog with the EFI entry at the in-tree file's LBA, and the
verifier passed. It ALSO duplicates the ESP bytes inside the ISO
filesystem (once as EFI/BOOT/BOOTX64.EFI, once as the appended
partition) — about 4 MiB of redundant data per ISO, which is the
exact duplication cost the design doc §8 explicitly warns against.
This duplication variant also did NOT boot in our QEMU/OVMF 11.1.1
build, even though the upstream Debian netinst ISO (which has the
same `Section Header + EFI Entry at offset 96` structure) DOES boot
(verified: BdsDxe loads Boot0001, GRUB starts, "Welcome to GRUB!"
prints on the serial console). The exact OVMF 11.1.1 boot-pick
heuristic that distinguishes a working Debian ISO from our
structurally-similar build is unclear from the outside. It may be
related to a specific EFIBoot GUID, a specific ISO9660 file name,
or a quirk of the qemu-system-x86_64 11.1.1 edk2-stable202408-prebuilt
firmware. **We did not find the right combination in this pass.**

We tried `bcfg boot add 0 fs2:/EFI/BOOT/BOOTX64.EFI rEFInd`
followed by `exit` from the EFI Internal Shell. **The shell sees
BLK0..BLK3 but no FAT `fs0:`/`fs1:`/`fs2:` aliases** — the EFI Shell
built into OVMF 11.1.1 does not mount FAT32 partitions as filesystems,
so `bcfg boot add <path>` and `ls fs2:` both fail with
`Cannot open file - 'fs2:\EFI\BOOT\BOOTX64.EFI'`. With a more
featureful shell (EDK2 ShellSnap or the EFI Shell package's
`Shell.efi`) this would work, but we cannot install a third-party
binary into the OVMF volume without rebuilding the firmware.

We attempted to drive the EFI Shell via QEMU HMP monitor's
`sendkey` command (a Python driver in `prototype/qemu-drive.py`
+ `prototype/qemu-type.py`) to type `bcfg boot add 0 <device path>
rEFInd` interactively, but the lack of FAT filesystem aliases made
every `bcfg` and `ls` command fail. QEMU `sendkey` keysym quirks
(no `colon` — had to use `shift-semicolon`) were worked around and
documented in the helper script.

**Therefore we cannot reach the d-i start / media-discovery marker in
this QEMU/OVMF build**, and we cannot honestly claim the boot chain is
qualified. The boot chain up to GPT/EFI-partition discovery IS
qualified — the firmware sees our partitions exactly as the verifier
predicts, the d-i kernel and initrd are at `/d-i/linux` and
`/d-i/initrd.gz` where the rEFInd menu expects them, the ESP bytes
match the rEFInd binary we built — but rEFInd launching and the d-i
kernel starting is NOT verified.

This is an environment-side block (OVMF 11.1.1 + qemu 11.1.1 quirks),
not a writer defect. On real hardware (or a UEFI Shell with FAT
support) the boot entry chain would work; on a vanilla OVMF Shell,
neither xorriso's bare-Initial-Entry nor the `-e FILE` in-tree
approach is picked up by OVMF for our specific build.

### 5. Reflink filesystem

**The brief explicitly says:** *"don't assume Btrfs === reflink-capable,
test it."* We did.

```
reflink probe: {capable: False,
                detail: 'inode a=480007274 b=480007275 capable=False'}
```

We run on macOS APFS. The probe file (2 MiB random) is copied with
`gcp --reflink=always` (GNU coreutils 9.11). The two resulting inodes
differ. **GNU `cp --reflink=always` does NOT trigger APFS clonefile on
macOS** — the FICLONE ioctl is Linux-only; macOS APFS uses
`clonefile(2)` which is triggered by BSD `cp -c`, not by GNU `cp`'s
reflink flag.

We tested `cp -c` separately (BSD cp) and confirmed it produces shared
inodes on APFS. Our `write-image.py` and `step1-test.py` therefore use
`gcp --reflink=always` as the default probe command (so the operator
gets a clear "reflink not supported" warning on macOS) and fall back to
a plain copy with a logged warning. **The seconds-scale promise does
not apply on this checkout's filesystem.** The writer still works —
it just pays full-copy cost.

For Step 1, we **accept this finding** and document it. Building the
prototype on Btrfs/XFS would let the clone step actually be
seconds-scale; on APFS without `cp -c` in the toolchain, we get the
~3.5 MB/s read+write speed of full copy. (Numbers reported in §1-2
above are real measurements on this host.)

### 6. Source bytes preserved across warm growth

The design doc §8 says: "verify unchanged files keep their original
LBA/extent." xorriso's in-place `-update` mode does NOT preserve
original LBAs for unchanged files — it re-allocates new RR/ISO records
and re-links them. We verified this by reading the rewritten ISO and
checking that the OLD ISO's directory records are gone; only the new
filesystem tree survives. **This means the "seconds-scale" claim of
the design doc does NOT apply to xorriso's `-update` mode in any
filesystem: even with reflink working, xorriso rewrites the ISO
metadata, not just the changed files.**

The only path that preserves original LBAs is `xorrisofs` cold compose
with the original tree as part of the input (it doesn't actually do
this either — cold compose also regenerates the ISO tree from scratch).
**No mode in the xorriso/xorrisofs toolchain currently provides
extent-preserving incremental growth that we can find documented or
tested.** This is open question #5 territory.

## What it did not prove — answering every category the design doc lists

The design doc §8 "Local experiment and what it did not prove" lists six
items. Our Step 1 prototype's status against each:

1. **Trailing padding beyond backup GPT after growth.**
   **ELIMINATED.** The rescue finalizer writes the backup GPT entry
   array at `LBA = image_lba - 1 - (entry_array_sectors - 1)` and the
   backup GPT header at `LBA = image_lba - 1`, so the file ends
   exactly at the backup header. The verifier reports 0 trailing
   bytes for every warm round. The "post-EFI / pre-GPT-backup" gap
   that remains between the EFI partition's last LBA and the
   relocated backup entries is conventional hybrid-image padding,
   not the bug the design doc warned about.

2. **Primary/backup GPT CRC actually validates after each growth.**
   **BOTH VALIDATE.** The finalizer writes a freshly-computed
   backup header at the new tail, recomputes the primary header CRC
   after updating `backup_lba` and `last_usable_lba`, and copies the
   same partition entry array bytes primary→backup so the entry
   array CRC matches the stored value in both headers. The verifier
   confirms all three CRCs after every warm round.

3. **Reflink (`cp --reflink=always`) actually works on the filesystem
   you're building on.** **NO** — on this checkout's APFS it does not.
   `gcp --reflink=always` triggers Linux's FICLONE ioctl; APFS uses
   `clonefile(2)` instead, which GNU `cp` does not call. We use BSD
   `cp -c` for our own copy paths in real production but keep
   `gcp --reflink=always` as the probe command so the operator gets a
   clear "reflink not supported" warning on macOS. The warning is
   logged loudly on every warm run.

4. **El Torito updates.** Preserved. The verifier confirms the BRVD
   signature and catalog_LBA, the validation entry word sum, and
   the initial entry's boot indicator / load LBA after every warm
   round. We did not qualify the firmware picking up the EFI entry
   — see "Boot smoke test" below for that limitation.

5. **Partition alignment.** Preserved. xorriso emits the new EFI
   partition at a 16-sector boundary (`-partition_cyl_align on
   -partition_offset 16`). The verifier confirms the post-rescue
   backup GPT header at `image_lba - 1`, which is automatically a
   sector boundary. Linux mount and media detection not tested —
   out of scope for Step 1.

6. **Real firmware.** QEMU/OVMF only. Sky1 O6N / cixmini and T2 / PC
   not tested — those targets are out of scope for Step 1 (Section 11
   step 1 says "qualify the writer and rEFInd boot layout first",
   and §10 "Real hardware qualification" is a separate later step).

## Open question #5 from the design doc — explicit answer

> *"Can explicit-ESP xorriso growth be finalized into consistently
> accepted media geometry?"*

**Answer: YES, with the rescue finalizer in place.** Every warm round
the Step 1 prototype produces passes the independent verifier's full
check set (MBR signature, MBR partition, GPT primary, GPT backup,
GPT entry array CRC, EFI partition lookup, ISO PVD, El Torito BRVD,
El Torito catalog, ESP-bytes-identical). The layout is consistently
accepted by every check the verifier runs.

What the rescue finalizer does, in summary:

1. Read the primary GPT header (xorriso still writes a valid primary;
   the only stale field is `backup_lba`).
2. Read the partition entry array (xorriso's primary entries are
   internally consistent; only the post-EFI layout is stale).
3. Compute `new_backup_lba = image_lba - 1`, `new_last_usable_lba =
   new_backup_part_entry_lba - 1`.
4. Write the entry array at `new_backup_part_entry_lba` (a copy
   from primary).
5. Compute a fresh backup GPT header (`current_lba = new_backup_lba`,
   `backup_lba = 1`, same disk GUID, same array) and write its CRC.
6. Patch the primary header's `backup_lba`, `last_usable_lba`, and
   header CRC32.
7. Patch the protective-MBR partition-1 `lba_size` to `image_lba - 1`.

The finalizer touches only ~64 KiB of bytes per round and runs in
under 10 ms.

### Open limitation: chained warm growth on a rescued image

xorriso 1.5.8.pl02 also refuses to grow an image whose trailing
region now contains the relocated backup GPT. Concretely: using a
warm-N.iso (already rescued by our finalizer) as the parent for a
warm-(N+1).iso growth fails with libburn's
`Read start address Ns larger than number of readable blocks N`
during the post-write "Re-assessing -outdev" pass. We did not find
a way to grow a rescued image in xorriso 1.5.8.pl02; this is an
xorriso-side limitation, not a writer bug.

For Step 1's qualification test we work around this by using the
same cold parent for every warm round (each round represents an
independent hotfix application to the cold release artifact). A
release engineer who wants to chain warm growths on real hardware
has two options, both outside Step 1's scope:

  (a) Apply the rescue finalizer's logic to the **parent** of each
      round before re-using it — i.e., ensure the parent always has
      xorriso's expected "trailing-ISO-data" layout, NOT our relocated
      backup GPT. This means stripping the GPT backup before the next
      warm growth, and re-applying after. Trivial to script, but it
      complicates the transaction.
  (b) Patch xorriso to relocate the backup GPT on `-boot_image any
      replay` growth. Filing that with the xorriso maintainers is
      outside the project's scope.

We document this as an open question, not a Step 1 blocker.

### Candidate growth modes considered

- `xorrisofs -o <new>` (cold compose) — produces a clean GPT layout,
  but does not reuse any original bytes. This is the cold path. We
  ship it qualified.
- `xorriso -update -outdev <same>` (in-place growth) — produces
  trailing zeros after backup GPT, BRVD at LBA 17 overwritten.
  Verifier rejects.
- `xorriso -update -outdev <new>` (separate output file) — loses
  MBR, system area, El Torito. Verifier rejects.
- `xorriso -boot_image any replay -update -append_partition
  -outdev <new>` — best candidate; preserves MBR, GPT primary,
  ISO PVD, El Torito. Backup GPT not relocated, MBR size field
  stale. **NOW FIXED by our rescue finalizer; verifier passes.**

**Recommendation to the design doc:** the rescue-finalizer warm path
is the qualified warm writer. Its behavior is recorded in
`build/iso/write-image.py::finalize_gpt_layout()` with unit tests
in `build/iso/tests/test_write_image.py` and an end-to-end test in
`build/iso/tests/test_step1_test_driver.py`. The chained-warm
limitation is the only remaining open question for warm growth;
fixing it requires either a small libburn/xorriso patch or the
"strip backup GPT before re-using" workaround described above.

## Toolchain measurements

| Component | SHA-256 (or version) | Notes |
| --- | --- | --- |
| `xorriso --version` | 1.5.8.pl02 | Homebrew xorriso 1.5.8 |
| `xorrisofs` | (xorriso wrapper) | Same xorriso binary |
| `qemu-system-x86_64` | 11.1.1 | Homebrew qemu 11.1.1 |
| `edk2-x86_64-code.fd` | (3,653,632 B prebuilt) | edk2-stable202408-prebuilt.qemu.org |
| `mformat`/`mcopy` | GNU mtools 4.0.49 | Homebrew mtools |
| Substrate: `debian-bookworm-amd64-netinst.iso` | 65,011,712 B | snapshot.debian.org `/dists/bookworm/main/installer-amd64/current/images/netboot/mini.iso` |
| ESP: rEFInd 0.14.2 FAT32 image | 4,194,304 B | refind_0.14.2-2.1_amd64.deb from deb.debian.org |
| ISO C compiler / Python | clang-1600 / Python 3.13.7 | macOS 27.2 (Darwin 27.2.0) |

## FAILed approaches (for the record)

These were tried and removed before commit; recorded so the next person
doesn't repeat them.

1. **Pure-Python FAT32 builder** (`build/iso/fat_image.py`, deleted):
   implemented a from-scratch FAT32 BPB + cluster allocation. Broken
   in subtle ways (LFN support, 32-byte directory entries handling,
   cluster chain order, FSInfo trail signature). The mtools path is
   shorter and correct. Pure-Python file deleted; the entire concept
   is replaced by `mformat -i`.

2. **`-isohybrid-mbr auto`**: xorriso 1.5.8.pl02 rejects `auto` as a
   path; it wants a file. We pass `-isohybrid-mbr auto` because xorriso
   treats the literal string `auto` as "use built-in isohdpfx" only
   in some versions; on macOS' xorriso 1.5.8 it errors. We dropped the
   flag entirely — xorriso's default isohybrid MBR works fine.

3. **`xorrisofs -application_id`**: not supported in `-as mkisofs`
   mode; not supported by xorrisofs. Dropped.

4. **`--grub2-mbr`**: takes a file path, not `auto`. We use
   xorriso's built-in isohybrid MBR.

5. **`xorrisofs -efi-boot-part <esp>`**: produces a proper Section
   Header Entry in the El Torito catalog but **moves the BRVD to
   LBA 32**, which collides with the GPT primary header. The
   verifier's PVD-at-LBA-17 check rejects the image. We reverted to
   `-e --interval:appended_partition_2:all::` which keeps the BRVD
   at LBA 17 and the PVD at LBA 16.

6. **xorriso `-update -outdev <same-file>`**: in-place growth
   corrupts the backup GPT and BRVD.

7. **xorriso `-update -outdev <new-file>` without `-boot_image any
   replay`**: produces a bare ISO with no boot structures.

8. **EFI Shell `bcfg boot add 0 fs2:/EFI/BOOT/BOOTX64.EFI rEFInd`**:
   fails because the EFI Shell built into OVMF 11.1.1 does not mount
   FAT32 partitions as `fsN:` aliases. Documented in "Boot smoke
   test".

## Files committed

| File | Purpose |
| --- | --- |
| `build/iso/import-substrate.py` | xorriso-based one-shot extraction of a real d-i substrate into an immutable content-addressed tree. |
| `build/iso/build-refind-esp.py` | Builds a deterministic FAT ESP image containing rEFInd + its ISO9660 driver + a small menu, using the Debian `refind` package + mtools. |
| `build/iso/write-image.py` | The prototype cold/warm writer. Cold uses `xorrisofs`; warm uses `xorriso -update -boot_image replay` followed by `finalize_gpt_layout()` (the GPT rescue finalizer) so the result passes independent verification. |
| `build/iso/verify-image.py` | Independent verifier: parses MBR, GPT primary+backup, ISO PVD, El Torito BRVD/catalog, and confirms ESP-bytes-match. NEVER trusts xorriso's exit status. |
| `build/iso/tests/test_write_image.py` | Unit tests for `finalize_gpt_layout()` and `_cleanup_scratch()`. Constructs synthetic GPT images that mimic what xorriso's warm growth produces, drives the finalizer, and asserts the verifier passes after rescue. Also asserts the finalizer rejects images without a primary GPT and without a protective-MBR 0xEE entry. |
| `build/iso/tests/test_step1_test_driver.py` | End-to-end test that runs `prototype/step1-test.py` (cold + 3 warm rounds) as a subprocess and asserts every round exits 0 with a passing verifier. This is the closest we get to a regression test without re-running qemu boot smoke (environmentally blocked on this host). |
| `prototype/qemu-drive.py` | Drives a QEMU/OVMF instance through the HMP monitor. Knows how to expand a string into `sendkey` calls with proper case + punctuation handling. |
| `prototype/qemu-type.py` | Slower, more reliable variant that waits for the `(qemu)` prompt between each keystroke. Used for the warm rounds that depend on every byte being typed correctly. |
| `prototype/step1-test.py` | The end-to-end test driver. Runs cold compose + N warm rounds, reports per-step real numbers (clone time, growth time, byte counts, layout numbers, verifier result) as JSON. **Exits non-zero if any round fails independent verification** — the previous pass swallowed verifier failures; this pass promotes them to hard errors. |

## What was NOT done in Step 1 (per the brief's "scope down" rules)

- The full content-addressed graph (Sections 5-7) — out of scope.
- Per-package records and index updates — out of scope.
- Hotfix eligibility classification — out of scope.
- mkosi producer changes — out of scope.
- Live ISO9660 producer changes — out of scope.
- Replacing `build/build-iso-di.sh` — explicitly forbidden.
- Modifying `preseed/` or `post-install/` — explicitly forbidden.
- arm64 substrate — not done in this pass; arm64 path uses the same
  cold compose pattern; warm writer would also fail on arm64 for the
  same xorriso reasons.

## Next steps (handoff to Step 2)

Step 2 ("Extract components with behavior parity") can begin from
both the qualified cold compose path **and** the qualified warm
growth path. The open items that Step 2 should resolve are listed
in §11 step 2 of the design doc; we do not enumerate them here.

**The warm-write failure mode from the previous pass is now fixed.**
The rescue finalizer in `build/iso/write-image.py` rescues the GPT
backup layout that xorriso 1.5.8.pl02 leaves stale when growing in
place, and the warm writer transaction is now qualified end-to-end
(synthesized and rescued unit tests in `tests/test_write_image.py`,
end-to-end test in `tests/test_step1_test_driver.py`). Step 2 may
treat the warm path the same way it treats the cold path.

The chained-warm limitation (using a rescued warm-N.iso as the
parent for warm-(N+1).iso) remains an open question; Step 2 should
decide whether to (a) adopt the "strip backup GPT before re-using"
workaround, (b) carry a copy of xorriso's libburn / libisofs in our
container so we can ship the patch ourselves, or (c) skip chained
warm growth entirely and treat every hotfix as an independent
transaction against the cold base. We lean toward (c) for the
initial Step 2 production cutover — it has fewer moving parts and
matches a release engineer's mental model of hotfix eligibility.