# Step 1: qualify the incremental xorriso/rEFInd writer

## Context

This repo is `cix-installer` (NCZ-OS build system). Full design doc is at
`docs/superpowers/specs/2026-09-21-incremental-di-iso-assembly-design.md`
in this checkout — **read it in full before writing any code**. It is the
authoritative spec for this task; this brief only scopes down to its
Step 1 (Section 11, "Delivery sequence").

The design replaces `build/build-iso-di.sh` (a monolithic full-rebuild
ISO assembler) with a content-addressed assembly graph plus a
transactional xorriso ISO writer: cold composition for a full rebuild,
warm/reflink-based incremental growth for a ready hotfix. **This task is
ONLY the first delivery step**: qualify the warm writer and rEFInd boot
layout, in isolation, before touching any of the existing
`build-iso-di.sh` logic. Do not attempt Sections 4-11's full component
list in this pass.

## What "done" means for this task

Per the design doc's own Section 11, step 1, and Section 8 ("Media
layout and the incremental writer"):

1. A minimal, REAL (not synthetic-file) rEFInd + Debian Installer ISO for
   at least ONE architecture (pick arm64/sky1 OR amd64/pc-t2 — state
   which and why if you have to choose one to fit the time budget).
2. A prototype `write-image.py` (or shell equivalent) implementing the
   **warm writer transaction** exactly as specified in Section 8: reflink
   clone of a parent ISO, explicit external `-append_partition` for the
   ESP on every growth (never `keep` unless the EFI image is byte-for-byte
   unchanged), explicit changed-file mapping via native xorriso commands,
   and independent GPT/El Torito verification after every write (do not
   trust xorriso's exit status alone — the design doc is explicit about
   this).
3. Test sequence, run for real and reported with real numbers:
   - Cold-compose an initial real ISO.
   - Apply 2-3 successive "hotfix-shaped" changes (a changed file at a
     realistic size, e.g. simulate a changed squashfs or `.deb`) via warm
     growth, and verify after EACH growth: unchanged files keep their
     original LBA/extent, the ESP is exactly what was appended, GPT
     primary+backup headers and entry-array CRCs are valid, and El Torito
     catalog still resolves.
   - Boot the result in QEMU/OVMF (or AAVMF for arm64) from fresh NVRAM,
     through rEFInd, far enough to reach the d-i start / media-discovery
     marker. This is the actual boot-chain qualification the design doc
     calls for in Section 10 ("New media boot smoke") — a `-kernel` boot
     or file extraction does NOT count as testing this.
4. Report the SAME categories of finding the design doc's own local
   experiment surfaced (Section 8, "Local experiment and what it did not
   prove") — in particular: does trailing padding beyond the backup GPT
   appear after growth (it did in Astra's toy test), does the primary/
   backup GPT CRC actually validate after each growth, does reflink
   (`cp --reflink=always`) actually work on the filesystem you're
   building on (don't assume Btrfs === reflink-capable, test it).

## Hard constraints (from the design doc, carried forward — do not violate)

- No `tar -C /` anywhere. No writes through hardlinks into shared cache
  objects. Assembly consumes files/immutable trees, never a live host
  root.
- Never claim a "seconds-scale" result without measuring it for real and
  reporting the actual number, cold-cache and warm-cache.
- Do not silently fall back to GRUB or drop rEFInd/d-i if the ISO9660+EFI
  layout doesn't qualify — report the failure and the constraint it hit,
  per Section 8's fallback guidance (larger FAT ESP with kernel/initrd
  inside it, rewritten on every growth — report that cost honestly rather
  than picking a different bootloader).
- Do not touch `build/build-iso-di.sh`, `preseed/`, or `post-install/` in
  this pass. This is an isolated prototype under a new path (propose
  `build/iso/write-image.py` per the design doc's own Section 4 component
  table, or a `prototype/` subdir if you want to keep it more clearly
  separate until qualified).
- Real d-i substrate for the test ISO: use whatever is already staged/
  buildable in this repo (check `build/build-iso-di.sh` and
  `release.conf` for where the current substrate ISO comes from) — do NOT
  invent a synthetic ISO like the design doc's own toy experiment did.
  This task's whole point is to go further than that toy experiment with
  a real substrate.

## What to hand back

- The prototype code, committed to this branch
  (`wip/incremental-iso-writer-2026-09-21`) as you go — commit each real
  milestone separately, don't batch everything into one commit at the
  end.
- A findings doc (`docs/superpowers/specs/2026-09-21-step1-xorriso-writer-findings.md`)
  covering: what was tested, the real numbers (timings, byte counts,
  extent reuse confirmed or not), every one of the "what it did not
  prove" categories from the design doc's own list, and an explicit
  answer to open question #5 from the design doc's Section 12 ("Can
  explicit-ESP xorriso growth be finalized into consistently accepted
  media geometry?").
- If you hit a wall the design doc didn't anticipate, say so explicitly
  in the findings doc rather than working around it silently — this is
  exactly the kind of thing Section 12's open-questions list exists for.

## Review

Adversarial review this yourself (zoder review loop) before considering
it done. This is infrastructure code that writes bootable disk images —
get it actually right, not just running without errors. Push to the
ARGONAS remote when done (`git push origin wip/incremental-iso-writer-2026-09-21`).
