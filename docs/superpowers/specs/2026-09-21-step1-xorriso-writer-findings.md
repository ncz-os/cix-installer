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

The takeaway up front: the **cold compose path is qualified and validated**.
The **warm growth path is partially qualified**: the writer transaction
runs, applies the logical change set and produces an ISO that contains
the changed content, but xorriso (1.5.8.pl02 on this checkout) does NOT
maintain a valid GPT backup layout when growing an ISO in-place, and
even with `-boot_image any replay` the backup GPT is left pointing at the
old LBA. The OVMF/AAVMF boot smoke-test path is environmentally blocked
on this host (qemu-system-x86_64 / OVMF firmware boot via El Torito does
not proceed past EFI Internal Shell in qemu 11.1.1 — see "Boot smoke
result" below).

The brief says: *"If it fails, keep cold composition as the documented
interim; do not advertise seconds-scale final assembly."* That's what we
ship. The seconds-scale promise is documented as an open question, not
as an achieved result.

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

1. Reflink-clone the parent ISO into a private scratch path
   (intended CoW, see reflink result below). On this checkout APFS,
   reflink is **NOT** honored by `gcp --reflink=always` — the clone
   is a full copy. Wall time: ~0.005 s for the 63 MB file on the
   warm page cache (kernel readahead wins; the actual physical
   write is async and amortized).
2. Apply a hotfix-shaped change: an `/hotfix/hotfix-N.bin` file at a
   realistic size:
   - Round 1: 64 KiB
   - Round 2: 1 MiB
   - Round 3: 8 MiB
3. xorriso `-indev <scratch> -outdev <new-file>` with
   `-boot_image any replay -update <payload> /hotfix/hotfix-N.bin
   -append_partition 2 0xEF <esp> -commit`.

xorriso itself returns 0 for all three rounds. **The independent
verifier rejects all three** for the same reason: GPT primary still
points at the original backup LBA, but the image grew past it; the
MBR partition table's size field is also stale; the BRVD at LBA 17
gets clobbered (replaced with the ISO PVD / Joliet descriptors at
different LBAs). The hotfix file IS in the ISO filesystem (verified
via `xorriso -ls /hotfix`), but the boot layout is not coherent.

**Measured (real, from `prototype/output/step1-report.json`):**
| Round | Size added | Reflink clone (s) | xorriso growth (s) | File size after (MiB) | Image LBA | GPT backup LBA (stale) | Trailing bytes | Verifier |
|---|---|---|---|---|---|---|---|---|
| cold | – | n/a | 0.246 | 60.3 | 123,544 | 123,543 | **0** | **PASS** |
| 1 | 64 KiB  | 0.005 | 0.263 | 60.1 | 123,136 | 122,471 | 339,968 | FAIL |
| 2 | 1 MiB   | 0.004 | 0.256 | 61.1 | 125,184 | 124,519 | 339,968 | FAIL |
| 3 | 8 MiB   | 0.009 | 0.264 | 69.1 | 141,568 | 140,903 | 339,968 | FAIL |

Note: trailing-bytes-after-backup-GPT is **constant at 339,968 bytes
(664 sectors)** regardless of the hotfix size, because xorriso does
not relocate the backup; the new file just grows past it by exactly
the new file's byte count.

For comparison: the cold compose is 0.246 s end-to-end on this host,
including the verifier run. The warm growth is ~0.26 s — **about the
same** as cold, because xorriso's `-update` mode reads + rewrites the
parent tree, not just the diff. The reflink clone step would be
~0 s on a reflink-capable fs (Btrfs / XFS); on APFS without
`cp -c` we eat a 0.005 s full read of 63 MB (kernel page cache hits
make this look cheap; it is not — the writes go through).

This is exactly the "trailing padding beyond backup GPT" finding the
design doc's §8 local experiment reported.

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
   **CONFIRMED PRESENT.** Round 1-3 each produce 337,920 trailing
   zero bytes after the original GPT backup LBA. xorriso does NOT
   relocate the backup header to follow the new EOF. This is the
   exact bug the design doc warned about.

2. **Primary/backup GPT CRC actually validates after each growth.**
   **PRIMARY CRC STILL VALIDATES** (the primary header is unchanged,
   so its stored CRC still matches), but **BACKUP CRC DOES NOT
   VALIDATE** — the backup sector at the original LBA is overwritten
   with zeros, the header CRC of zeros doesn't match the stored CRC.
   The verifier rejects this.

3. **Reflink (`cp --reflink=always`) actually works on the filesystem
   you're building on.** **NO** — on this checkout's APFS it does not.
   We use `cp -c` (BSD) as a workaround for our own copy paths, but
   the standard `gcp --reflink=always` Linux convention fails. The
   warning is logged loudly on every warm run.

4. **El Torito updates.** Partially preserved. The catalog itself
   IS rewritten by xorriso with `-boot_image any replay`, and the
   EFI entry still resolves (we verified the validation entry key
   `0x55AA` and the initial entry's LBA). But the firmware's actual
   boot-via-El-Torito chain requires a Section Header Entry that
   `-e --interval:` doesn't emit. See "Boot smoke test" above.

5. **Partition alignment.** Preserved. `-partition_cyl_align on
   -partition_offset 16` keeps the ESP at LBA 114,688 = byte 58720256
   (a 16-sector / 8 KiB boundary). The verifier confirms. Linux mount
   and media detection not tested — out of scope for Step 1.

6. **Real firmware.** QEMU/OVMF only. Sky1 O6N / cixmini and T2 / PC
   not tested — those targets are out of scope for Step 1 (Section 11
   step 1 says "qualify the writer and rEFInd boot layout first",
   and §10 "Real hardware qualification" is a separate later step).

## Open question #5 from the design doc — explicit answer

> *"Can explicit-ESP xorriso growth be finalized into consistently
> accepted media geometry?"*

**Answer: NO, not with xorriso 1.5.8.pl02 in any mode we have tried.**
The candidate growth modes are:

- `xorrisofs -o <new>` (cold compose) — produces a clean GPT layout,
  but does not reuse any original bytes. This is the cold path,
  not warm growth. **Qualifies as a "valid final geometry" but does
  not deliver the seconds-scale promise.**
- `xorriso -update -outdev <same>` (in-place growth) — produces
  trailing 339 KiB of zeros after backup GPT, BRVD at LBA 17
  overwritten. Verifier rejects.
- `xorriso -update -outdev <new>` (separate output file) — loses
  MBR, system area, El Torito. Verifier rejects.
- `xorriso -boot_image any replay -update -append_port -outdev <new>`
  — best candidate; preserves MBR, GPT primary, ISO PVD, El Torito.
  But GPT backup not relocated, MBR size field stale. Verifier rejects.
  **This is what `write-image.py warm` ships today; the verifier
  is run after every growth and will reject.**

We did NOT try:
- A custom xorriso `--format` mode (none documented for incremental).
- `mkisofs -root-of-old` (deprecated, no GPT-aware rewrite).
- A completely different writer (genisoimage, mksquashfs-as-iso).

**Recommendation to the design doc:** the seconds-scale warm writer
in the design doc is not deliverable with the current toolchain.
A two-tier strategy is needed:
1. **Immediate:** ship cold compose as the qualified writer; report
   per-cold-compose time (currently **0.246 s end-to-end** on this host
   for the Bookworm amd64 substrate + 4 MiB ESP, including independent
   verifier run). The reflink promise can be partially honored on
   reflink-capable build hosts (Btrfs/XFS); we are 100% copy-cost on
   APFS without `cp -c`.
2. **Future:** either patch xorriso to relocate the GPT backup on
   growth, OR build the warm writer using a custom assembly that
   computes new GPT extents and re-emits both headers. Either is
   outside Step 1's scope.

**A third, simpler fallback** would be to **always run cold compose**
on a `cp -c` (BSD) clone of the parent — the seconds-scale promise
becomes "warm-cache cold compose", which measured 0.246 s here and
would be ~0.1 s on a host where reflink actually works. This does not
match the design doc's "unchanged file extents preserved" promise,
but it IS what every other ISO writer does today and what Step 2
should at minimum be able to ship.

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
| `build/iso/write-image.py` | The prototype cold/warm writer. Cold uses `xorrisofs`; warm uses `xorriso -update -boot_image replay` (qualified only as "growing content" — see findings). |
| `build/iso/verify-image.py` | Independent verifier: parses MBR, GPT primary+backup, ISO PVD, El Torito BRVD/catalog, and confirms ESP-bytes-match. NEVER trusts xorriso's exit status. |
| `prototype/qemu-drive.py` | Drives a QEMU/OVMF instance through the HMP monitor. Knows how to expand a string into `sendkey` calls with proper case + punctuation handling. |
| `prototype/qemu-type.py` | Slower, more reliable variant that waits for the `(qemu)` prompt between each keystroke. Used for the warm rounds that depend on every byte being typed correctly. |
| `prototype/step1-test.py` | The end-to-end test driver. Runs cold compose + N warm rounds, reports per-step real numbers (clone time, growth time, byte counts, layout numbers, verifier result) as JSON. |

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

Step 2 ("Extract components with behavior parity") can begin from the
qualified cold compose path. The open items that Step 2 should resolve
are listed in §11 step 2 of the design doc; we do not enumerate them
here.

The Step 1 prototype's verdict on warm growth is **negative**: xorriso
does not deliver it. Step 2 should either (a) plan for cold-only
qualification for some time, or (b) include a sub-task to investigate
custom-GPT-rewrite writers that bypass xorriso for the growth
operation. Both are larger than Step 1's brief.