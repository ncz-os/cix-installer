# Bookworm elimination — consolidated recommendation

Date: 2026-09-21
Inputs: `2026-09-21-arm64-forky-qualification-stage-ab.md`,
`2026-09-21-amd64-forky-qualification-stage-ab.md` (both on this branch),
building on `2026-09-21-multiarch-modernization-bookworm-elimination-review.md`.

## Bottom line

**Bookworm can be retired as the d-i substrate on BOTH architectures.**
Stage A+B evidence (QEMU only, Stage C/real-hardware not authorized or
run) supports this on both arches, for different reasons:

| Arch | Verdict | Why |
| --- | --- | --- |
| arm64/Sky1 | Retire Bookworm AND the 4 "Sky1 hardware fix" d-i overlays | F-stock-userspace (stock Forky d-i + only the mandatory Sky1 kernel/module/firmware swap) passes install+boot+on-disk cleanly. F-retained-fixes (same + all 4 overlays) FAILS on TCG — the overlays cost enough wall-clock time to blow the 90-min install budget. The overlays solve problems the Sky1 kernel swap already solves; none are Sky1-hardware-required on the current pin. |
| amd64 | Retire Bookworm | amd64 has no Sky1-class hardware-quirk history at all — F-stock-userspace passes cleanly on the first fully-preseeded run once the real d-i preseed-dialog blockers (found and fixed by this dispatch: `passwd/*`, `partman-auto/*`, an explicit expert recipe with an `efi` method, `finish-install/reboot_in_progress`) were supplied. |

Neither arch needed the Bookworm substrate itself for anything — both
installs completed against a pinned Forky netinst with only
architecture-appropriate kernel/module handling.

## What actually blocked stock d-i before this dispatch (real root causes, not guesses)

1. **arm64**: the four "Sky1 hardware fixes" (disk-detect wait extension,
   finish-install progress-owner, S35usb-rescan initrd overlay,
   sshd-watcher DNS writer) were bundled under one
   `NCZ_SKY1_OVERLAYS` gate as if all Sky1-specific. Only two of the
   four actually touch Sky1 hardware; the other two are generic d-i
   quality-of-life patches mis-classified as hardware fixes. On the
   current Forky + Sky1 7.2.6-r272 pin, none are required.
2. **amd64**: stock Forky d-i's `preseed/file=` did not silently work as
   assumed — it needed `preseed/url=file://...` plus explicit answers
   for six additional interactive dialogs (root password, partman
   method, partman confirm, an `efi` partman recipe method, and the
   final reboot-continue prompt) that the CURRENT preseed apparently
   already answers for the Bookworm-substrate path but were missing/
   different for a bare stock-Forky attempt. This was a preseed-
   completeness gap, not a d-i defect.

## Recommended order of work (supersedes recommended-order rows 3-4 in
## the architectural review, now that Stage B data exists)

1. **Flip `NCZ_SKY1_OVERLAYS` default 1→0** for the Forky substrate path
   (arm64). Keep the code path available (do not delete the overlays
   outright) in case a future kernel/substrate pin regresses and needs
   them back — but stop applying them by default.
2. **Decompose the overlay gate**: split disk-detect-wait +
   S35usb-rescan (genuinely Sky1-hardware-shaped) from
   finish-install-progress-owner + sshd-watcher-DNS-writer (generic d-i
   UX, unrelated to Sky1). Evaluate the latter two independently as
   general d-i improvements, not hardware fixes.
3. **Port amd64's proven preseed additions** (`preseed/url=` form,
   `passwd/*`, `partman-auto/*`, explicit `efi` recipe method,
   `finish-install/reboot_in_progress`) into the real preseed used by
   production builds, gated appropriately if the Bookworm and Forky
   paths still need to diverge during the transition.
4. **Add `d-i debian-installer/add-kernel-options string
   console=ttyS0,115200`** to the amd64 preseed (one-line, needed for
   any future automated serial-console boot validation on amd64 — arm64
   already has this).
5. **Fix `build/kvm-installed-disk-assert.sh`'s qcow2/`parted`
   limitation** (false GPT-missing on some qcow2 layouts) before relying
   on it as a hard gate for either arch's Stage C work.
6. **Stage C (real hardware, human-supervised, NOT part of this
   dispatch or this recommendation)**: confirm on real Sky1 silicon that
   removing the 4 overlays doesn't regress, and confirm amd64's proven
   preseed additions work on real T2/PC hardware, before calling
   Bookworm retirement release-ready. TCG throughput differences mean
   the arm64 install-timeout finding is NOT conclusively "the overlays
   are broken" — only "the overlays cost more than F-stock, and F-stock
   passes without them on the current pin." Real hardware is fast enough
   that this margin may not matter either way, which is exactly why
   Stage C is still needed before shipping.

## What this does NOT resolve

- Architecture leakage in `build-iso-di.sh` (Sky1 discovery/asset-copy
  code paths reachable from amd64 builds, per the architectural
  review's §4) — flagged, not fixed, in both dispatch docs.
- The incremental-assembly design (separate doc) — unaffected by this
  finding either way; Bookworm retirement simplifies its Bookworm/Forky
  dual-substrate handling but doesn't obsolete the design.
- Sky1 kernel/DKMS work itself — orthogonal. The Sky1 kernel line stays
  required regardless of which d-i substrate wraps it.
