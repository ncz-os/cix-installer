# Dispatch 1 of N: Bookworm-elimination foundation (evidence baseline + truthful gates)

## What this is

You are implementing recommended-order items 1+2 from a completed architectural
review: `docs/superpowers/specs/2026-09-21-multiarch-modernization-bookworm-elimination-review.md`
in THIS checkout. READ THAT FULL DOCUMENT FIRST — it is the authority for
every decision below, with exact `file:line` citations into this same repo.
Do not re-derive its analysis; implement what it recommends.

ONE deliverable, this dispatch: **items 1 and 2 only** (evidence baseline +
truthful install/boot/ESP gates). Do NOT touch item 3 (Forky qualification)
or later items — those are separate follow-up dispatches on this same
branch. Making your first real file edit within the first 15 tool calls is
required — if something blocks that, stop and report what's blocking you
rather than continuing to read.

## Branch/repo state

You are on branch `wip/stock-forky-di-2026-09-21`, forked from
`wip/mkosi-pipeline-2026-09-14` at commit `e9681db` (already has tonight's
eDP/r8152/OCS fixes). This branch is pushed to ARGONAS canonical
(`origin`). **Commit and push after EACH of the two items below completes
and is verified — do not batch both into one commit at the end.** This
project has hit real branch-corruption from long clone-to-push windows on
concurrent work (see `~/kernel-build-checklist-reference.md`'s final
section) — minimize your own window by pushing incrementally.

`git push` needs the password-auth wrapper (pubkey auth to ARGONAS is
flaky on this fleet):
```
GIT_SSH_COMMAND='sshpass -p "REDACTED-CREDENTIAL" ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10' git push origin wip/stock-forky-di-2026-09-21
```

## Item 1 — Correct the evidence baseline; reconcile misleading claims

Per the review's §2.1, §3.3, and recommended-order row 1:

- `build/build-iso-di.sh:2`'s header comment describes a "Bookworm d-i plus
  Ubuntu late-command pivot" — this does NOT match the actual full-mode
  execution path (which is: d-i bootstrap environment → deployment of a
  separately-prepared Forky OS, no `full-upgrade`/`dist-upgrade` anywhere).
  Rewrite this header to describe the ACTUAL flow accurately, per review
  §2.1's five-step description. Do the same for `post-install/run-all.sh:5`'s
  stale "freshly installed Bookworm rootfs" description.
- `Makefile:74-87`'s "validated end-to-end"/August-gate claims are STRONGER
  than the cited TYDEUS report actually supports (per review §3.3). Replace
  these claims with an accurate statement: what was actually validated
  (phase 1: modified testing-based installer completed install in QEMU/AAVMF),
  what was NOT validated (phase 2: installed-image boot — FAILED, disk had
  no real GPT/ESP), and that this does not constitute an end-to-end pass.
  Do not delete the historical record — correct the claim's accuracy.
- Record the currently-accepted ISO's real hash/receipts where findable in
  this repo (sbom files, release notes) rather than inferring acceptance
  from a comment.
- The misleading `--bookworm-iso` CLI flag name in `build/build-iso-di.sh`
  should get a deprecated-but-working alias that doesn't imply the input
  suite (per review §10 Stage D item 4) — e.g. accept `--installer-iso` as
  the primary name, keep `--bookworm-iso` working as a backward-compat
  alias with a one-line deprecation notice, since callers (including
  `run-fresh-amd64*.sh` scripts elsewhere in this repo, do NOT edit those,
  just don't break them) still use the old name.

## Item 2 — Truthful install/boot/ESP gates

Per review §10 Stage B and recommended-order row 2. The gates must FAIL on
real defects instead of silently passing:

- Locate the current EFI/GPT/ESP verification logic in
  `build/kvm-install-gate-amd64.sh` and `build/kvm-install-gate.sh` (arm64).
  Per review, current arm64 gate rewrites GRUB/console/preseed settings and
  "forces test options" (`build/kvm-install-gate.sh:101,120,135,197,204`) —
  read these lines, understand what's being forced vs. genuinely tested.
- Add EXPLICIT assertions the gates currently lack, per review §10 Stage B's
  "required evidence" list — at minimum:
  - Actual GPT partition table present (not MBR), correct FAT32 ESP
    filesystem type, EFI files found on a MOUNTED partition (not just
    present in an unmounted directory tree — this is the exact TYDEUS
    phase-2 failure mode: files existed but with no real ESP backing them).
  - A real installed-kernel banner appears in the boot log (not just "QEMU
    exited 0").
  - Root filesystem mode is 0755 after first-boot work completes (this
    project already has a `preseed/extract-rootfs.sh` gate for this on the
    d-i side per `docs/ISO-BUILD-GUARDRAILS.md` — the INSTALLED-system gate
    needs the equivalent check post-boot).
  - Rescue/fallback boot entry still present and independently selectable
    (never just verify the default entry).
- Make each of these a HARD FAIL (non-zero exit, clear message naming which
  check failed) — not a warning that gets logged and ignored. Per
  kernel-build-checklist discipline: "a required failure cannot be
  overwritten by an EFI-file-presence heuristic" (review's exact words) —
  do not accept "the file exists somewhere" as proof of a working ESP.
- Test that your new checks actually fire on a REAL negative case before
  calling this done — e.g. temporarily break the ESP construction, run the
  gate, confirm it fails with your new explicit message (not a generic
  timeout), then revert the deliberate breakage. This is directive-mandated
  ("prove a guard fires on real data", not just code review of the check).
- `build/e2e-install-test.sh:19` per review has "broad process-killing
  behavior" — replace with per-run process ownership (track PIDs this run
  actually started, kill only those) before this gate runs on a shared
  build host again.

## What you must NOT do this dispatch

- Do not touch Forky-qualification logic (item 3), per-patch upstream
  diffing (item 5), architecture/profile unification (item 4), or the
  incremental-assembly design (item 6) — separate dispatches.
- Do not attempt any real hardware boot (O6N, cixmini, or any physical
  board). Everything here is QEMU/KVM virtual-gate work only. This is a
  hard boundary, not a preference — the kernel-build-checklist reference in
  your home dir explains why (O6N is human-supervised-only, operator-only
  physical action).
- Do not run `build-iso-di.sh` end-to-end unless you need to for gate
  validation — if you do, it's a real ~30-90min operation, budget for it.

## Validation before you consider this done

- `bash build/preflight-freshness-gate.sh` still passes clean.
- Your new gate assertions demonstrably fire on an injected negative case
  (see above) and pass on the current known-good artifact.
- `git log` on this branch shows the header/Makefile corrections and the
  gate hardening as separate, clearly-messaged commits — not squashed into
  one "misc fixes" commit.
- Zoder adversarial review (you review your own diff, or request a
  cross-family reviewer via the TYDEUS reviewer slot) before your final
  push — fix any real finding in place.

Report back: what you changed, what you verified (with the actual command
output proving the negative-case test fired), and what's left for the next
dispatch (item 3, Forky qualification, arm64 and amd64 separately).
