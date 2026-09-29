# Fix Codex's real findings on the last iso-writer commits

Codex (gpt-5.6-sol) did a real adversarial review of commits `1115504`,
`be87f9c`, `72442b6` on this branch and found real, specific defects, cited
by line number. Fix ALL of these, not a subset. Independent live boot
testing (a fresh cold-compose + real OVMF/qemu boot on a real Linux host)
also confirmed the current code does NOT actually reach rEFInd's menu —
it lands in the raw UEFI Internal Shell instead. So this is a real,
confirmed regression/incompleteness, not a nitpick review.

## Fix list (from Codex's review, verbatim findings)

1. **High**: when kernel/initrd are absent, `build-refind-esp.py` still
   generates a config with 3 enabled menu entries that cannot resolve
   their loader, AND the ISO9660 driver has been removed entirely — so
   there is no fallback route to a kernel at all. Kernel and initrd must
   be REQUIRED inputs (fail loudly if missing), not silently optional
   with a broken fallback. The docstring's claim that missing-kernel
   paths "would have to point" at ISO9660 is false — the ISO9660 driver
   code path was removed; fix the docstring or restore a real fallback,
   don't leave a lie in the comment.

2. **High**: `verify-image.py` only checks embedded ESP bytes when
   `--esp-image` is supplied. The warm writer supplies it; the COLD
   writer does not. So cold-compose can print `verifier: OK` without
   ever proving the El Torito entry points at the bytes actually in the
   ESP. Fix `write-image.py`'s cold path to pass `--esp-image` to the
   verifier the same way the warm path does, and confirm the verifier
   genuinely catches a deliberately-corrupted ESP (write a real negative
   test: corrupt one byte of the ESP after cold-compose, confirm the
   verifier REJECTS it).

3. **Medium**: the 2048-byte Load RBA fix is CORRECT (Codex confirmed
   this) but the code comment explaining it is wrong — it claims "the El
   Torito spec text says 512-byte sectors and xorriso does NOT honor
   that," which is incorrect. Load RBA is in 2048-byte CD logical
   blocks; Sector Count (a different field) is in 512-byte units. Fix
   the comment to say what's actually true, don't leave a plausible-but-
   wrong explanation in the code.

4. **Medium**: the "source ESP size" fallback logic in `verify-image.py`
   is incoherent — its own comment calls it a "legacy (hybrid) layout
   path" but the surrounding branch is restricted to
   `iso9660_efi_in_tree`, and it reintroduces the same wrong 512-byte
   Load RBA unit the rest of the fix corrected. Either remove this dead
   fallback branch entirely (simpler, and Codex's review leans this way
   since it "probably fails rather than masking a bad image" — meaning
   it's not even doing useful work) or fix it to be coherent and explain
   in a comment exactly when it's meant to trigger and why.

5. **Medium**: the module docs claim `check_el_torito_catalog` validates
   the Section Header Entry (offset 64) and EFI Initial Entry (offset
   96), but the actual function only validates the validation entry and
   default entry at offsets 0/32. The new code then blindly trusts bytes
   96-127 as the EFI entry without validating: header indicator, EFI
   platform ID, number of following entries, final-section status. Add
   real validation of those fields — this is exactly the kind of gap
   that lets a broken catalog pass verification by accident.

6. **Medium**: code comments overclaim causal certainty not established
   by the cited evidence — e.g. asserting the ISO9660 driver "claims the
   disc and causes the firmware SFS protocol to be lost," generalizing
   this to ext4 and "any other BlockIo-claiming driver," and describing
   embedding kernel/initrd as upstream rEFInd's "official
   recommendation." The underlying design decision (embed kernel/initrd
   in FAT, drop the ISO9660 driver for boot) is sound and doesn't need
   to be oversold — rewrite these comments to state only what's actually
   verified (the practical limitation observed), not a protocol-level
   story that isn't established.

7. **Low**: several stale/contradictory comments and dead code:
   - Module header still describes a 4 MiB ESP with ISO9660/ext4 drivers
     loading from ISO9660 (build-refind-esp.py:3) — update to match the
     current embedded-FAT design.
   - `make_fat_image_mtools`'s docstring still says "Build a FAT32
     image" while the code deliberately omits `-F` to allow FAT12/16 —
     fix the docstring.
   - The removed ext4 driver is still located/hashed in the receipt —
     either genuinely remove it or explain in a comment why it's kept.
   - Config constants still reference `/d-i/` normalization even though
     both arch configs now point at ESP-root `/linux` and `/initrd.gz`
     — clean this up.
   - `write-image.py`'s cold-writer prose still says kernel/initrd live
     outside the ESP and are reached via rEFInd's ISO9660 driver — that
     is no longer true, fix it.

## THE REAL BAR — do not skip this

After all fixes above, run a REAL boot test yourself:
1. Cold-compose a real ISO from the real substrate (same commands already
   used earlier in this branch's history — check `git log -p` on the
   earlier commits for the exact invocation).
2. Boot it under real OVMF + qemu on a REAL Linux host (not a Mac; the
   fixes so far were verified on ACHILLES, `jasonperlow@192.168.207.11`,
   `<redacted>` — use it again, don't switch hosts).
3. Capture the FULL serial log to a file, and COMMIT that log file into
   the repo as real, checked-in evidence — not a claim referencing a
   `/tmp` path that gets deleted, and not a hand-wave that a different
   host is "the same setup" as another host. If you genuinely cannot run
   this on ACHILLES for some reason, say so explicitly and clearly in
   your report — do not substitute a different environment and claim
   equivalence without direct verification.
4. The bar to clear: the serial log must show progression PAST rEFInd's
   own menu into the actual Linux kernel booting and Debian Installer
   starting (kernel decompression, "Loading, please wait...", or
   equivalent d-i early-boot output) — not just "rEFInd - Main Menu"
   rendering. rEFInd loading is necessary but not sufficient.

## Verification setup for THIS run — use TYDEUS, not just MiniMax alone

Author with MiniMax-M3 as before, but the loop needs a real adversarial
reviewer this time, not just an LLM approving its own work with no
--check gate. Wire BOTH:

- `--reviewer reviewer` (routes to TYDEUS's local reviewer slot, model
  qwen38 as of this session — the zoder config already has
  `serves = ["reviewer", "qwen38"]` so the alias resolves correctly;
  re-probe `http://192.168.207.73:8006/v1/models` yourself if you have
  any doubt it's still live before trusting the alias).
- `--check "python3 -m py_compile build/iso/write-image.py build/iso/verify-image.py build/iso/build-refind-esp.py"`
  at minimum (a real, cheap, automated gate — better than the "no
  --check configured" pattern that let two prior broken/overclaimed
  results through review).

This does not replace the manual real-hardware boot test in the section
above — `--check` only proves the Python parses; the boot test is the
thing that actually proves the fix works.

## Commit discipline

Same as always on this branch: commit each real fix immediately, before
any other git operation on this tree. Push to
`root@192.168.207.101:/mnt/datapool/git/cix-installer.git` (the
`jasonperlow@` form of that URL will fail with pubkey-only auth) after
each meaningful milestone.
