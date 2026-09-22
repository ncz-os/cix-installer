# Step 1 continuation: fix the rEFInd volume-reopen error, finish the boot chain

## Context — read this whole file, plus git log on this branch

This branch (`wip/incremental-iso-writer-2026-09-21`) already has REAL,
independently-verified progress. Read the commit messages of the last two
commits (`git log -3`) before touching anything — they document two real
root causes found and fixed via live testing on real OVMF/qemu:

1. `e1ece8e` — the rEFInd ESP image was force-formatted FAT32 at 4 MiB
   (far below FAT32's practical minimum). Debian's own working El Torito
   EFI image is FAT12 at a similar size. Removing the forced `-F` flag in
   `build/iso/build-refind-esp.py` fixed OVMF's `BdsDxe` from failing to
   load any bootable entry at all.
2. `a78eb84` — rEFInd's filesystem drivers (ISO9660/ext4) were placed at
   `EFI/REFIND/DRIVERS` (wrong case, wrong location). rEFInd actually
   auto-loads drivers from a `drivers_x64`/`drivers_aa64` subdirectory of
   wherever the CURRENTLY RUNNING binary lives — our El Torito EFI entry
   launches `EFI/BOOT/BOOTX64.EFI`, so drivers now live at
   `EFI/BOOT/drivers_x64/`. This fixed the previous symptom (rEFInd's
   Main Menu showed only its own built-in tools, real OS entries from
   `refind.conf` silently never appeared, no error printed).

**Current blocker, confirmed live on real OVMF (edk2 via Ubuntu's `ovmf`
package) + `qemu-system-x86_64` on ACHILLES**: rEFInd now gets further
and fails with:

    Error: Load Error while (re)opening our installation volume

This is an rEFInd-internal error about re-mounting its own boot volume
(the FAT12 ESP, loaded via the El Torito no-emulation EFI entry) after
driver load. It is NOT the same failure as before — it's real forward
progress, not a regression.

## Task 1 (primary): fix the volume-reopen error

Approach it empirically, the same way the last two fixes were found —
control experiments and real boot tests, not guessing at flag
combinations:

1. **Search rEFInd's own source and issue tracker for this exact string**
   (`"Load Error while (re)opening our installation volume"` or the
   nearby source context) — this is very likely a documented, known
   rEFInd behavior with a known trigger. rEFInd is at
   https://github.com/rhboot/refind (or check `apt-cache show refind` for
   the exact upstream project URL this Ubuntu package tracks). Read the
   relevant source (likely `refind/lib.c`'s `ReinitVolumes()` or similar)
   to understand exactly what condition trips this message before
   guessing at a fix.
2. **Try FAT16** as a middle ground between the broken FAT32-at-4MiB and
   the FAT12 that got us this far — `mformat`'s `-F 16` flag forces it
   explicitly. Test whether FAT16 avoids whatever FAT12-specific
   assumption is tripping the reopen.
3. **Try a slightly larger ESP** (e.g. 8 MiB, 16 MiB) with FAT12/FAT16 —
   the current 4 MiB size was chosen somewhat arbitrarily; a size that
   more closely matches what typical rEFInd USB-install guides recommend
   (rEFInd's own `refind-install` script targets real USB sticks, usually
   far larger) might avoid a geometry edge case.
4. **Get a THIRD real reference point.** So far we've only compared
   against Debian's own GRUB-based El Torito image. Find or build a
   MINIMAL real rEFInd USB/CD image using rEFInd's OWN documented
   installation method (e.g. via `refind-install` targeting a loopback
   FAT image, or find an existing known-working rEFInd ISO/USB image
   example online) and compare ITS El Torito catalog + FAT filesystem
   parameters against ours. This is the same byte-diff-against-known-good
   method that found both previous root causes — don't abandon it now
   just because the previous target (Debian's GRUB approach) doesn't use
   rEFInd at all.
5. **Instrument, don't just guess.** rEFInd has verbose/debug logging
   options (check `refind.conf`'s documented `log_level` setting, or
   build/run a debug build if the shipped binary's default logging isn't
   enough). Get more detail on WHICH volume-reopen call is failing and
   why before trying blind fixes.

## Task 2: confirm the actual Step 1 bar is met

Once Task 1's error is resolved, the design doc's real bar (see
`docs/superpowers/specs/2026-09-21-incremental-di-iso-assembly-design.md`
§10, "New media boot smoke") is: boot reaches the actual **d-i
start/media-discovery marker** — not just rEFInd's own menu rendering.
Select the "Install (graphical)" entry (or drive it automatically via
`prototype/qemu-drive.py`, following the existing pattern in this repo)
and confirm the kernel actually loads, the initrd unpacks, and Debian
Installer itself starts probing for its installation media. Capture the
full serial log as evidence — do not just note "believed to work."

## Task 3: reconcile the warm-growth path with the new cold layout

`prototype/step1-test.py`'s warm rounds currently fail verification
(exit=1, 3/3 rounds) because they were written against the OLD
`-append_partition`/GPT cold layout, which the fixes above have moved
away from (current cold layout has no GPT at all — see
`write-image.py`'s `cold_image()` docstring for the full explanation of
why). Update the warm-growth logic in `write-image.py` and the verifier
in `verify-image.py` to work against the current no-GPT,
isolinux+efi-boot-in-tree layout: growth needs to replace files inside
the ISO9660 tree (not manipulate a GPT-appended partition that no longer
exists) while still tracking real extent reuse for unchanged files. Get
this passing `step1-test.py`'s own verification for real, with real
numbers, the same way the cold path was validated.

## Task 4 (if time permits): arm64/Sky1 side

Everything above has only been done for amd64/pc-t2. Do NOT assume the
FAT12 fix or driver-directory fix trivially carries over to arm64 without
verifying:

- Confirm AAVMF firmware availability on whatever build host you use
  (`dpkg -l | grep -i aavmf`, or find the equivalent for arm64 UEFI
  firmware).
- Confirm `driver_dir = "drivers_aa64"` and the AA64 rEFInd binary/driver
  files actually exist in the rEFInd .deb the same way the x64 ones did
  (verify, don't assume symmetry).
- Run the same real substrate-import → ESP-build → cold-compose →
  qemu+AAVMF boot test sequence used for amd64 in this session.

## Verification discipline (read this — it matters)

The PREVIOUS session's zoder loop on this exact task resolved after 3
iterations with **no `--check` configured**, meaning resolution rested on
LLM review opinion alone. That let a real gap through: the required
boot-smoke test never actually ran (the test host had no OVMF firmware at
all), and the "findings doc" that got produced made claims not fully
supported by what was actually tested. Both real root causes found in
this session were found by a human (well, by Claude, operating directly,
not trusting the loop's own verdict) re-running everything independently
on a real Linux host with real OVMF, and by doing control experiments
against known-good references.

**Do not repeat that mistake.** For every claim in whatever findings
report you produce:
- If you say something "boots," paste the actual serial log lines
  proving it, not just "verifier: OK" from a script that only checks
  filesystem structure.
- If you say a comparison was made against a "known-good" reference,
  name the exact reference and how you obtained/verified IT was actually
  known-good (not assumed).
- Use `zoder`'s `--check` mechanism if you have a way to wire an
  automated test into the loop; if not, say explicitly in your final
  report that no automated check gate was available and that a human
  should independently re-verify before trusting this as done — the same
  disclosure this session's own report gave you.

## Commit discipline

Commit each real fix or finding to this branch IMMEDIATELY after making
it — before any other git operation (checkout, reset, rebase) on this
same working tree. Push to
`ssh://root@192.168.207.101/mnt/datapool/git/cix-installer.git` (NOT the
`jasonperlow@` form of that URL — that one only offers pubkey auth and
will fail; use `root@` or the bare hostname with a forced
`GIT_SSH_COMMAND` password override) after each push-worthy milestone,
not just once at the end.
