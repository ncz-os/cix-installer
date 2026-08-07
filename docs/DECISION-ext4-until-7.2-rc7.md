# Decision: ext4 root by default until kernel 7.2-rc7

**Date:** 2026-08-06
**Status:** active — revisit when the shipped kernel is 7.2-rc7 or later
**Scope:** NCZ-OS installer ISO (Radxa Orion O6 / CIX Sky1)

## Decision

The NCZ-OS installer defaults the root filesystem to **ext4**, not btrfs. btrfs
remains selectable, both interactively and via `ncz_fs=btrfs`.

**No ISO ships before 7.2-rc7** (operator, 2026-08-06). So no released image
will ever carry the rc6 exposure described below, and the installer prompt
carries no kernel-specific warning text — it would be false for every image we
actually ship. The ext4 default stands on its own merits; flipping back to
btrfs is a live option once rc7 is the shipped kernel.

## Why

We ship kernel **7.2.0-rc6-sky1-ncz**. The btrfs COW fixup worker is missing
from it, and is restored only in **7.2-rc7**:

> [GIT PULL] Btrfs fixes for 7.2-rc7, part 2 — David Sterba, 2026-08-06
> tag `for-7.2-rc6-fixup-worker-tag`, merged as `6c68fa601b49`
> <https://lore.kernel.org/lkml/cover.1786044747.git.dsterba@suse.com/>

Two patches by Boris Burkov:

1. **`btrfs: trigger cow fixup via dirty_folio()`** — restores detection of
   pages/folios dirtied without filesystem knowledge, which need COW fixup.
   Sterba: *"The consequence of not doing so is silent data loss."* The
   mechanism had been removed in `b2a9f217ad3fa8`; this reinstates it, now
   folio-aware and with subpage block-size support.
2. **`btrfs: flush the fixup workers during close_ctree`** — handles fixup work
   still outstanding at unmount.

651 insertions across `inode.c`, `subpage.c`, `extent_io.c`, `disk-io.c`.

Silent data loss on a root filesystem is not a risk worth carrying for
snapshots and compression, and the exposure ends at rc7. ext4 costs us those
two features and nothing else.

## Exposure at time of decision

| Host | Kernel | btrfs |
|---|---|---|
| O6N board `.3` | `7.2.0-rc6-sky1-ncz` | **root fs is btrfs** — `nvme0n1p3[/@rootfs]`, `ssd,discard=async,space_cache=v2` |
| cixmini `.66` | `7.0.12-cix-sky1-next` | root + two nbd-mounted `@rootfs` |
| HYDRA, ACHILLES | — | none |

`.66` runs 7.0.12 and was **not** assessed against the removal commit
`b2a9f217ad3fa8`; whether that tree is exposed is unverified. Do not assume
either way without checking.

## What changed

- `preseed/disk-fs-chooser.sh` — the `ncz/root-fs` template now offers
  `ext4, btrfs` with `Default: ext4`. The description is neutral: no
  kernel-version warning, since no shipped ISO will carry the affected kernel.
- `preseed/preseed-ubuntu.cfg` — the static `partman-auto/expert_recipe`
  fallback root partition is now ext4, so the fallback agrees with the chooser.
  This recipe applies only when the chooser's `db_set` does not win.

Unchanged: the ESP stays fat32, the rescue partition stays ext4 (it always was),
`ncz_fs=btrfs` still works for anyone who wants it.

## Reverting

Optional once the shipped kernel is 7.2-rc7 or later — at that point the rc6
hazard is gone and this is purely a default-filesystem preference:

1. `preseed/disk-fs-chooser.sh` — restore `Choices: btrfs, ext4` /
   `Default: btrfs`.
2. `preseed/preseed-ubuntu.cfg` — restore the root stanza to `btrfs`.
3. Confirm the running kernel actually carries commit `ae2567b11c3df43861d05f856bdb3434b3961aa1`
   ("btrfs: flush the fixup workers during close_ctree") before flipping back —
   a version number alone is not proof, since our kernel is a patched tree.

## Not verified

This decision is based on the upstream patch series and on our kernel being
rc6. It is **not** based on a reproduced failure on our hardware. If a specific
btrfs symptom was observed, it has not been matched to these patches — patch 2
would fit an unmount hang, patch 1 would fit corruption after mmap writes.
