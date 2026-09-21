# Dispatch 2 of N: Forky d-i qualification, arm64/Sky1, VIRTUAL GATES ONLY

## What this is

Read `docs/superpowers/specs/2026-09-21-multiarch-modernization-bookworm-elimination-review.md`
§3 and §10 (Stages A/B/C) IN FULL first — it is the authority for this
dispatch. This is dispatch 2 on branch `wip/stock-forky-di-2026-09-21`;
dispatch 1 (commits `39f4b05`, `f4f96ab`) landed the evidence-baseline
correction and the truthful install/boot/ESP gate hardening — pull that
work, it's already on this branch. Use the new `build/kvm-installed-disk-assert.sh`
helper from dispatch 1 as your acceptance gate for everything below.

ONE deliverable: **arm64/Sky1 Forky d-i qualification, Stage A + Stage B
only (virtual/QEMU), never Stage C.** amd64 is a separate dispatch on an
x86 host. Make your first real edit/experiment within 15 tool calls.

## HARD BOUNDARY — read this twice

**You may NEVER attempt a real physical hardware boot: not O6N, not
cixmini, not any board.** Everything in this dispatch is QEMU/KVM virtual
only. This is not a preference, it's standing operator policy
(`~/kernel-build-checklist-reference.md`: O6N boot-testing is
human-supervised, operator-only physical action). If you find yourself
reaching for an SSH command to a `192.168.207.3` or `192.168.207.66`
board, STOP — that is out of scope for this dispatch, full stop. Stage C
(the real hardware comparison) is explicitly NOT authorized here; report
what Stage A/B found and what Stage C would need, and leave it there.

## Task (review §10 Stage A + Stage B)

1. **Stage A — establish candidates.** Select and pin ONE Forky arm64 d-i
   artifact (record its exact hash, package/kernel versions, initrd
   contents). Build TWO candidate installer configurations from it, per
   review §10 Stage C's definitions (build them now even though you're not
   running the Stage C hardware comparison — Stage B still needs both
   virtual-tested):
   - **F-stock-userspace**: pinned Forky d-i userspace + ONLY the
     mandatory Sky1 kernel/module/firmware substitution + product
     preseed/deployment integration. NO disk-detect timing patch, no early
     custom USB recovery, no DNS writer, no other hardware-internals patch
     beyond the kernel/module swap itself.
   - **F-retained-fixes**: identical artifact + the CURRENT applicable
     Sky1 d-i hardware fixes (grep `build/build-iso-di.sh` for the arm64
     hand-patches — USB/NVMe timing, ACPI quirks, etc — per review §3.3
     and §4). Exclude Bookworm-only grafts from BOTH candidates (those are
     already dead code per dispatch 1's findings — confirm they're
     actually skipped for Forky, don't just assume).
   Log every integration change you had to make so "stock userspace" in
   your report isn't confused with an untouched Debian ISO — the review is
   explicit that this distinction matters.

2. **Stage B — virtual install + installed boot, BOTH candidates.** Run
   `build/kvm-install-gate.sh` (using QEMU/AAVMF for arm64, per review's
   citation of `build/kvm-install-gate.sh:101,120,135,197,204` — read what
   it currently forces vs. genuinely tests) against both F-stock-userspace
   and F-retained-fixes. Use dispatch 1's new
   `build/kvm-installed-disk-assert.sh` to check the installed result:
   real GPT, FAT32 ESP with EFI files actually mounted, installed-kernel
   banner, root mode 0755, rescue entry present.
   - Exercise full/desktop at minimum; full/headless if time allows.
   - Record which candidate passes, which fails, and at exactly which
     boundary (per review's failure classification: firmware/kernel
     startup, controller enumeration, media retrieval, d-i component
     execution, target extraction, partition/ESP layout, or installed
     kernel boot) — do not just report pass/fail, report WHERE.
   - The historical TYDEUS failure was "no real ESP, EFI files in an
     unmounted directory" — if you see this again, that's the SAME known
     failure class, say so explicitly rather than treating it as new.

3. **Do not conflate this with a kernel promotion.** Use the exact same
   pinned Sky1 kernel/headers/modules/firmware in both candidates that the
   current release build uses — verify via `build/stage-kernel.sh` or
   whatever mechanism currently stages the arm64 kernel, don't silently
   pick up something newer.

## Deliverable

Update `sbom/iso-receipts.txt` (from dispatch 1) with real Stage A/B
results for both candidates — hash, pass/fail per gate, failure boundary
if failed. Write findings into a new file
`docs/superpowers/specs/2026-09-21-arm64-forky-qualification-stage-ab.md`:
what Stage A/B found, whether F-stock-userspace got further than the
August TYDEUS attempt, and — the actual point of this whole review —
whether the evidence so far suggests Bookworm's arm64 d-i can eventually
be retired for Sky1, or whether a specific hardware fix is clearly still
required and what evidence supports that.

Commit and push incrementally (same GIT_SSH_COMMAND password-auth wrapper
as dispatch 1, see `~/kernel-build-checklist-reference.md`'s final section
on minimizing clone-to-push window) — do not batch everything into one
commit at the end.

Report back with real command output, not summary claims.
