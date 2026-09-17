# Singularity Desktop downstream patches

Patches carried against `singularityos-lab/singularity-desktop` and its bundled
subprojects for NCZ-OS on CIX Sky1, applied by `build/build-singularity.sh`
from `assets/singularity/patches/<subproject>/` (bind-mounted into the build
container as `/ncz-patches`) after the upstream tree is cloned and every
submodule is re-pinned to its own tracked branch tip. A patch that fails to
apply is a hard build failure, not a warning - see the script for why.

Every patch here must correspond to an **open, unmerged upstream PR**. When a
PR merges, delete its patch(es) in the same commit - a stale README entry
claiming a patch is still needed when it is not is worse than a redundant
patch file, because it hides the fact that the build no longer carries
anything.

## Current state: the overlay is EMPTY

There are no patch directories under here, only this file. The previous queue
(24 patches under `labwc/`, `singularity-shell/` and `libsingularity/`) was
retired in `59b48a7` on 2026-09-07 after per-patch forward/reverse
`git apply --check` showed 19 conflicting, 4 already-applied no-ops, and 1
that would have inserted a duplicate `SelectionRow.set_options()` and broken
the compile. That work had landed as native commits instead.

An earlier revision of this file still described the `labwc/` and
`singularity-shell/` directories as present and verified. They had already
been deleted. Corrected 2026-09-17.

## Why most of our upstream work needs no patch here

`build/build-singularity.sh` defaults `SRC_REF=master` and re-pins every
submodule to the tracked branch its `.gitmodules` declares, all of which point
at `singularityos-lab` upstream. So anything merged upstream is picked up by
the next real build with no patch and no pin to bump:

| Subproject | Tracked branch | Merged work it now carries |
| --- | --- | --- |
| `singularity-shell` | `main` | #24, #25, #26, #27 |
| `singularity-session` | `main` | #5, #6 |
| `libsingularity` | `main` | #9, #11, #12, #13 |
| `singularity-desktop` (super) | `master` | #253 |

## Known gap: the labwc replug fix is NOT in current builds

`labwc` tracks upstream branch `singularity`, and
[labwc#5](https://github.com/singularityos-lab/labwc/pull/5) (DP/HDMI replug
leaves the screen black until the compositor restarts; standing workaround was
`systemctl restart greetd`) is still **open**. Its downstream patches went away
with the rest of the queue in `59b48a7`, so builds since then carry no fix for
it on either arch.

The PR is now a two-line change to `configure_new_output()` in `src/output.c`
(`wlr_output_schedule_frame()` before `lab_wlr_scene_output_commit()`),
hardware-confirmed on O6N and MS-R1. Re-adding it as a single patch under
`labwc/` would be consistent with the doctrine at the top of this file, but
that is a deliberate decision, not a cleanup - left open rather than done
silently.

## Artist Packs

Contributed wallpaper art (currently Brandon Perlow and Alex Jay Brady,
`build/build-wallpaper-contrib-deb.sh`) ships as separate `.deb`s staged at
`assets/wallpaper-debs/*.deb` (gitignored, like `assets/cix-debs` - rebuild
with that script rather than committing the blob), installed by
`post-install/45-wallpaper-rotator.sh` alongside the built-in `ncz` and `bing`
collections. See `docs/wallpaper-packs.md` on the website repo for the
`.collection` format.
