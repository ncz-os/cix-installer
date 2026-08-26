# ISO build guardrails

**Read this before touching `build/build-squashfs-layers.sh`,
`preseed/extract-rootfs.sh`, `build/build-iso-di.sh`, or
`post-install/run-all.sh`'s hook-invocation framework.**

## The core rule

**The ISO build MECHANICS are stable. Only the image CONTENTS change
build-to-build.**

- Mechanics = the files listed above: the chroot/overlay/bake sequence
  shape, the squashfs-layer pipeline, the partman/extraction recipe
  structure, the hook-invocation framework itself. These run for EVERY
  board and EVERY variant built from this pipeline — a bug here is silent
  and systemic, not scoped to one image or one fix.
- Contents = which packages/assets/fixes get baked in, individual
  post-install hook bodies, kernel/driver versions, desktop config.
- A commit touching a mechanics file needs to say WHY the mechanics needed
  to change, in the commit message — not just what changed.
- If a PR touches both mechanics and contents, call out the mechanics part
  separately so it gets extra review.
- When chasing an unexplained regression across boards/variants, check
  `git log` on the mechanics files FIRST. A symptom that looks
  content-shaped ("the kernel changed", "the network broke") is often
  actually a mechanics regression.

## Why this exists

2026-08-26: a fresh O6N install shipped with the root filesystem (`/`) at
mode 0700 instead of 0755. Three symptoms looked unrelated — greetd
panicked (`unable to set working directory: Permission denied`), the NIC
never linked, `rtc-efi` hung on every boot — and it took hours of live
hardware debugging (serial console, rescue-partition chroot, `namei -l`
permission walks) to find they were one root cause: the squashfs-layer
build pipeline baked a bad root permission into `base.squashfs`, which
`preseed/extract-rootfs.sh`'s `unsquashfs -f -d /target` then faithfully
reproduced on every install. It affected every board built from that image,
not just O6N.

## Mandatory checks on a fresh install

- **Root filesystem mode is 0755.** `stat -c '%a' /` must read `755`. This
  is enforced as a MECHANICAL gate in `preseed/extract-rootfs.sh` — the
  install fails loudly if violated. Do not remove or weaken that gate.
- **Persistent journal survives a reboot.** `journalctl --list-boots`
  should show an entry matching the CURRENT boot's timestamp. Confirmed
  broken the same night as the above (only stale entries from an earlier
  date persisted) — that gap blocked post-mortem debugging of the exact
  incident this doc describes.
- **When 2+ symptoms look unrelated on a broken boot, compare against the
  rescue partition boot** (separate ext4 root, `nvme0n1p2`) before assuming
  independent bugs. Booting rescue and checking whether the same symptoms
  reproduce there is the fastest way to tell "one root cause, several
  symptoms" from "several real bugs" — it settled this incident in one
  boot cycle.

See also `~/.claude/rules/kernel-build-checklist.md` (kernel-specific,
separate concern) on hosts that have it.
