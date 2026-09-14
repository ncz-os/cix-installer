# mkosi phase 2 — replacing build-squashfs-layers.sh's job

Status: implementation started 2026-09-14. Verified at small scale on PROTEUS;
NOT yet exercised against the real installer-base/desktop manifests at full
size. See "What's verified" at the end before trusting this for a real ISO.

## Current architecture (build-squashfs-layers.sh, read from source)

- `base.squashfs` — a real, standalone rootfs. debootstrap/mmdebstrap into
  `$WORK/base`, apt-install the base manifest, then `mksquashfs $WORK/base`
  whole. This is a normal single-tree build.
- `desktop.squashfs` (and other role deltas: server, etc.) — NOT a standalone
  rootfs. Built by: unsquash base as an overlayfs LOWERDIR, mount an overlay
  with a fresh UPPERDIR, `apt-get install` the role's package set into the
  merged mount (so apt resolves dependencies against base+role, writes land
  in upperdir only), then:
  1. materialize `trusted.overlay.metacopy=y` files — a file can appear in the
     upperdir's metadata while its data still lives in the lowerdir via the
     merged mount; the real bytes must be copied before the upperdir is
     squashed alone, or the delta ships broken empty files.
  2. generate an "overlay operation manifest" (whiteout chardevices, opaque-dir
     xattrs) — plain squashfs has no overlayfs semantics, so these get
     replayed by the INSTALLER at apply time from this sidecar manifest.
  3. strip overlay-internal xattrs (`trusted.overlay.*`, `security.selinux`).
  4. `mksquashfs` the upperdir ALONE as `$role.squashfs` — this is the delta.
- At boot, the INSTALLED system runs base.squashfs (ro, lower) +
  desktop.squashfs (delta, upper) as a live overlayfs mount. The delta is
  never flattened into a standalone rootfs on disk.
- LAYER-COHERENCE RULE (existing, must survive any replacement): role deltas
  copy up `/var/lib/dpkg/status` into their upperdir. Changing base's package
  set without rebuilding every role delta leaves the merged view showing the
  OLD dpkg status — new base packages become invisible to dpkg. This is
  overlayfs semantics, not a build-tool limitation; whatever replaces the
  script must preserve the discipline of rebuilding deltas when base changes.
- tmpfs guard (existing, must survive): `/tmp` on the build host can be a
  32G tmpfs (RAM). A ~1.7G desktop layer's decompress+verify pass can exceed
  available tmpfs and gets silently misdiagnosed as squashfs corruption
  (real incident). The script auto-relocates its WORK dir off tmpfs unless
  the caller explicitly chose one.

## Correction: no phase-1 mmdebstrap foundation exists to build on

MEMORY.md claims "phase 1 mmdebstrap done" (commit 5eaace2, 2026-09-11). This
is stale/wrong relative to current HEAD (verified 2026-09-14): `git show
HEAD:build/build-base-rootfs.sh` returns "fatal: path does not exist in
HEAD" (checked `--follow -M`, no rename either — the file is simply gone,
no trace). Nothing in the current tree mentions mmdebstrap.
`build-squashfs-layers.sh`, the real live pipeline entry point, still
debootstraps directly per its own header comment (`base.squashfs
debootstrap resolute + ...`) and one further debootstrap-specific error-
message reference — unchanged, no mmdebstrap involvement anywhere.

This doesn't block phase 2: mkosi's own apt/package-manager-driven install
(exercised in the spike as `Format=directory`+`Bootable=no`) is a full
replacement for debootstrap on its own — it does not need an mmdebstrap
layer underneath it. The design below builds `base` directly via mkosi,
superseding debootstrap outright rather than sitting on top of a phase-1
foundation that doesn't currently exist in the tree.

## mkosi's native primitive — it has exactly this pattern

`BaseTrees=` + `Overlay=yes` is NOT a generic "layering system" grafted on
top of a flat assembler — it is the SAME overlayfs base+delta pattern:

> When used together with BaseTrees=, the output will consist only out of
> changes to the specified base trees. Each base tree is attached as a lower
> layer in an overlayfs structure, and the output becomes the upper layer,
> initially empty.

`BaseTrees=` accepts a directory, tar, or disk image. For package-set deltas
to resolve correctly against the base's installed set, the base tree must
keep its package-manager metadata (`CleanPackageMetadata=no` on the base
build) — otherwise the delta build doesn't know what's already installed and
either reinstalls or has broken dependency resolution.

So the replacement shape is direct:
1. Build `base` via mkosi normally (`Format=directory`, `Bootable=no`,
   `CleanPackageMetadata=no`), installing the base manifest.
2. Build each role delta via mkosi with `BaseTrees=<path to base tree>`,
   `Overlay=yes`, installing only that role's *additional* packages. mkosi
   mounts the overlay, installs, and hands back JUST the upper layer as the
   output directory — no hand-rolled `mount -t overlay` / `unsquashfs` step.

## CONFIRMED HAZARD (empirical, 2026-09-14): mkosi's overlay dedup strips dpkg status

Built a real delta on PROTEUS: `BaseTrees=<mmdebstrap base dir>`, `Overlay=yes`,
`CleanPackageMetadata=no`, `Packages=curl` (curl + 10 real dependencies).
mkosi's own build log:

    ‣ Removing duplicate path /etc/ld.so.cache from overlay
    ‣ Removing duplicate path /var/lib/dpkg/lock from overlay
    ‣ Removing duplicate path /var/lib/dpkg/status from overlay
    ‣ Removing duplicate path /var/lib/dpkg/status-old from overlay
    ‣ Removing duplicate path /var/lib/dpkg/triggers/Lock from overlay

`/var/lib/dpkg/status` genuinely does NOT end up in the delta output —
confirmed (`ls`: No such file or directory) — even though curl+deps were
installed and the status file necessarily differs from base's. mkosi's
"duplicate path" removal is NOT a content-equality check; it strips known
package-manager runtime-state paths from any `Overlay=yes` output
unconditionally, grouped with genuinely-transient files (lock files,
ld.so.cache). This is exactly the hazard this doc already flagged
("mkosi does not eliminate it just by being used") — confirmed for real,
and more acute than expected: mkosi actively deletes the changed file from
THIS SAME BUILD's own output, not just failing to detect a later drift.

**Working mitigation, verified**: two script hooks around the dedup pass.
1. `PostInstallationScripts=` (runs right after packages install, before
   mkosi's dedup): copy `/var/lib/dpkg/status` (and `status-old`) to a path
   with no counterpart in base (e.g. `/var/tmp/.saved-dpkg-status`) — a
   novel path survives dedup since it can't be "duplicate" of anything.
2. `PostOutputScripts=` (runs on the finalized `$OUTPUTDIR`, after dedup has
   already run): move the stashed file back to `/var/lib/dpkg/status`.

Verified end-to-end: final output directory carries a real
`/var/lib/dpkg/status` containing `Package: curl`, stash file cleaned up.
This pair of hooks is a REQUIRED component of any mkosi.conf used for NCZ
role-delta production, not an optional nicety -- the build script below
bakes them in rather than leaving them as something a future config author
could omit.

## What mkosi does NOT replace

mkosi's overlay output is a plain directory (the upper layer contents) — it
has no concept of NCZ's install-time overlay-manifest replay format, and it
does not itself materialize `metacopy` files or squash anything. These stay
NCZ-owned, unchanged in shape, just fed from mkosi's output directory instead
of a hand-mounted overlay's upperdir:
- metacopy materialization pass (still needed — mkosi's overlay mount has the
  same metacopy semantics as the hand-rolled one, same hazard)
- overlay-manifest generation (still needed — installer-side replay format)
- xattr stripping + `mksquashfs` of the delta directory (unchanged)

The dpkg-status coherence RULE is not eliminated by switching tools — it's
overlayfs semantics either way. What changes is who owns the mount lifecycle
(mkosi, reliably, instead of a hand-written `mount -t overlay` + cleanup
trap); the "rebuild every delta when base's package set changes" discipline
is still on NCZ, same as before.

## tmpfs guard

mkosi supports `WorkspaceDirectory=` / `--workspace-dir` to pin its scratch
location explicitly instead of `/var/tmp` defaults. The existing tmpfs-
detection-and-relocate logic in build-squashfs-layers.sh is ported forward
as an explicit `--workspace-dir` pointed at the same non-tmpfs path, rather
than trusted to a default.

## Cross-arch

Confirmed in the phase-2 spike (2026-09-14, PROTEUS): `mkosi --architecture
arm64` cross-builds cleanly on x86_64 via the host's existing
`qemu-user-static` + systemd-binfmt registration — no new emulation
mechanism needed, same qemu-aarch64-static path ARGOS already uses.

## Separate mechanics problem: build inputs silently go stale

Operator directive 2026-09-14: builds must pick up current upstream/HEAD
automatically, not whatever was pinned whenever a human last remembered to
bump it. Two concrete examples this session:
- `singularity-desktop`'s `.gitmodules` pins `subprojects/singularity-session`
  to a commit frozen since 2026-08-10. `git submodule update --recursive`
  (what `build/build-singularity.sh` runs) does NOT auto-track the declared
  `branch = main` — only `--remote` plus a re-committed pointer bump does
  that, and nothing currently does.
- `assets/wallpaper/ncz-wallpaper-ocs` staged into a fresh ISO predated
  cix-installer's own git HEAD, despite the ISO carrying today's date.

CORRECTION (found while investigating, 2026-09-14): the submodule-pin half
of this is **already solved** on master, not missing. `build/
build-singularity.sh` (commit `3092c4d`, landed 2026-09-06) already
re-pins every `.gitmodules`-tracked-branch submodule to its LIVE branch tip
(`git fetch origin "$branch"; git checkout FETCH_HEAD`) before the
recursive submodule update, whenever it runs without
`SINGULARITY_SOURCE_DIR` set. So once PR #6 merges to singularity-session's
`main`, the next true-fresh `build-singularity.sh` run picks it up with no
further code change needed. The earlier framing in this doc ("submodule
pins don't auto-track branches") was correct about plain
`git submodule update --recursive` in general, but wrong about this
specific script, which already works around exactly that gap.

**The real gap is one level up: is the resulting `singularity-opt.tgz`
payload ever actually regenerated, or does it sit as a stale cached
artifact indefinitely?** Found `tools/nightly/ncz-singularity-sync.sh` +
`.service`/`.timer` in the repo — a complete, well-designed daily job that
mirrors upstream, validates via a real Buildkite arm64 build, and stages a
DATED candidate artifact to ARGONAS (deliberately never auto-promoting —
promotion is left an explicit human step, by design). Checked whether this
timer is actually installed anywhere on the fleet (ARGOS, HYDRA, TYDEUS):
**`systemctl is-enabled` returns `not-found` on all three.** The automation
exists, fully written, and has never been deployed anywhere. This is the
concrete instance of "we keep leaving code on the table" for the
singularity-session case specifically — not a missing mechanism, a
mechanism nobody turned on, plus a promotion step nobody automated even a
notification for (no "list unpromoted candidates" tooling exists either).

Two real, scoped follow-ups (not done in this pass — need an operator
decision on which host should run this and where `/etc/ncz/
singularity-sync.env` credentials should live, not something to guess):
1. Deploy `ncz-singularity-sync.timer`/`.service` to a real host (the
   script's own path convention, `~/sinty-build/...`, suggests it expects a
   dedicated build host — none of the three checked have that directory
   either, so this may never have been deployed anywhere at all, not just
   regressed).
2. Add a lightweight "candidates awaiting promotion" surface (even just a
   log line an existing fleet-apt-status-style weekly digest could pick up)
   so a staged-but-unpromoted artifact doesn't sit invisible.

`assets/wallpaper/ncz-wallpaper-ocs`'s staleness is a DIFFERENT, smaller
case — no cross-repo sync involved, cix-installer's own git HEAD already
has `--page-size` (commit `0dee16c`); the ISO build simply staged an older
copy. This one is closer to the `ensure_base_tarball_fresh()` pattern
below: cix-installer should not treat any file under `assets/` that has a
tracked, edited source elsewhere in the SAME repo as something that can go
stale silently. Not designed in this pass; flagging the shape of the fix
(an age/hash check analogous to `ensure_base_tarball_fresh()`, scoped to
`assets/wallpaper/ncz-wallpaper-ocs` specifically since that's the one
confirmed case, generalized only if a second case turns up) rather than
building a generic repo-wide staleness scanner speculatively.

## What's verified (as of this fork's work)

- mkosi `BaseTrees=`/`Overlay=yes` mechanism exercised at small scale on
  PROTEUS with a minimal package set (not the real installer-base/desktop
  manifests) — see commit for exact evidence captured.
- NOT yet run against the actual multi-thousand-package installer-base +
  desktop manifests, which is the real proof this can replace the production
  path (historically ~30 min per full layer rebuild per the existing script's
  own comments) — that run needs to happen before this replaces
  build-squashfs-layers.sh in the real ISO pipeline.
- Cross-arch arm64 confirmed working generically (see the phase-2 spike), not
  yet re-confirmed specifically inside the BaseTrees+Overlay delta flow.
