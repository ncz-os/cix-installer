# Dispatch 2b: Forky d-i qualification, amd64/T2+PC, VIRTUAL GATES ONLY

## What this is

Read `docs/superpowers/specs/2026-09-21-multiarch-modernization-bookworm-elimination-review.md`
§3, §4, §10 IN FULL first. Companion dispatch to the arm64 qualification
running in parallel on ULTRA (dispatch 2, same branch) — you are doing the
SAME kind of work for amd64 (T2 Macs + regular PCs), independently. Do NOT
assume the arm64 dispatch's findings apply here — amd64 currently keeps
the substrate's OWN installer kernel (per review §2.1 step 3: "amd64 keeps
the substrate installer kernel" vs arm64 which replaces it with Sky1
artifacts) — this is a real architectural difference, not a gap to unify
away in this dispatch.

Branch `wip/stock-forky-di-2026-09-21` already has dispatch 1's work
(commits `39f4b05`, `f4f96ab`, `699f760` — evidence-baseline fixes + the
new `build/kvm-installed-disk-assert.sh` truthful gate helper). Pull
before starting if this clone is behind.

**IMPORTANT — you are on ACHILLES, an x86_64 build host also used for
production amd64 ISO builds.** A separate production build may be running
concurrently on HYDRA (same silicon family, different host) — this is
fine, do not touch HYDRA, do not touch any process on THIS host you didn't
start. Keep your work entirely inside
`~/Projects/cix-installer-stockdi-2026-09-21`.

ONE deliverable: **amd64 Forky d-i qualification, Stage A + Stage B only
(virtual/QEMU-KVM — this host has real KVM, use it, don't emulate).**
Make your first real edit/experiment within 15 tool calls.

## HARD BOUNDARY

No real physical hardware boot of ANY kind — not MEDUSA, not PEGASUS, not
any T2 Mac, not this build host's own bare metal outside a VM. Everything
here is QEMU/KVM virtual only, and ACHILLES has native KVM so this should
be fast and accurate, not emulated. If the task seems to need booting an
actual physical Mac, STOP — that's out of scope, report it as a follow-up
need instead.

## Task (review §10 Stage A + Stage B, amd64-specific)

1. **Stage A — establish candidates.** Select/pin ONE Forky amd64 d-i
   artifact (record exact hash, package/kernel versions, initrd contents).
   Since amd64 currently keeps the SUBSTRATE's own installer kernel (not a
   Sky1-style kernel replacement), your two candidates differ mainly in
   which HARDWARE WORKAROUNDS are applied, not kernel substitution:
   - **F-stock-userspace**: pinned Forky d-i userspace, no T2-specific or
     other amd64 hardware hand-patches beyond what's strictly required for
     the product preseed/deployment integration to run at all.
   - **F-retained-fixes**: identical artifact + whatever amd64-specific d-i
     hand-patches currently exist in `build/build-iso-di.sh` (grep for
     amd64-conditional blocks — review §4 flags "some amd64 paths still
     require or stage Sky1 inputs," which is itself a defect worth noting
     if you find it, not something to silently preserve).
   Exclude Bookworm-only grafts from both (per dispatch 1, these are
   already dead for non-Bookworm suites — confirm, don't assume).

2. **Stage B — virtual install + installed boot, BOTH candidates, using
   real KVM on this host (not TCG emulation).** Run
   `build/kvm-install-gate-amd64.sh` against both candidates. Use dispatch
   1's `build/kvm-installed-disk-assert.sh` for the installed-result check:
   real GPT, FAT32 ESP with `BOOTX64.EFI`/rEFInd actually mounted (not just
   present in an unmounted tree), installed-kernel banner, root mode 0755,
   rescue entry present.
   - Exercise full/desktop at minimum; full/headless if time allows.
   - Also test the T2-vs-regular-PC unified-kernel claim from
     `~/kernel-build-checklist-reference.md`'s boot-validation-targets
     context if it's checkable in a VM (it likely isn't fully — T2-specific
     ACPI/SMC paths don't exist under QEMU — note explicitly if a check is
     VM-representative vs. requires real hardware, don't claim VM coverage
     you don't have).
   - Record pass/fail per candidate AND the exact failure boundary
     (firmware/kernel startup, controller enumeration, media retrieval,
     d-i component execution, target extraction, partition/ESP layout, or
     installed kernel boot) — not just pass/fail.

3. **Do not conflate with a kernel promotion** — use the exact currently-
   staged amd64 kernel line(s) (`build/stage-amd64-kernel.sh`), don't pick
   up something newer mid-experiment.

## Deliverable

Update `sbom/iso-receipts.txt` with real Stage A/B results for both amd64
candidates. Write findings to
`docs/superpowers/specs/2026-09-21-amd64-forky-qualification-stage-ab.md`:
what Stage A/B found, whether the amd64-specific hand-patches (if any)
proved necessary or removable, and a direct answer on whether amd64's
Bookworm-based d-i can be retired in favor of Forky's own — amd64 has no
Sky1-class hardware quirk history documented in the review, so this may
have a cleaner answer than arm64's.

Commit and push incrementally with the password-auth wrapper:
```
GIT_SSH_COMMAND='sshpass -p "REDACTED-CREDENTIAL" ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10' git push origin wip/stock-forky-di-2026-09-21
```
Fetch/rebase onto the branch tip immediately before each push (the arm64
dispatch is pushing to this SAME branch concurrently on another host —
minimize your clone-to-push window per
`~/kernel-build-checklist-reference.md`'s final section; never force-push
or reset-and-reapply to resolve a rejection, always a real rebase that
preserves the other side's commits).

Report back with real command output, not summary claims.
