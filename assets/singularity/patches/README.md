# Singularity Desktop downstream patches

Patches carried against `singularityos-lab/singularity-desktop` (and its
bundled `labwc` subproject) for NCZ-OS on CIX Sky1, applied automatically by
`build/build-singularity.sh` from `assets/singularity/patches/<subproject>/`
after the upstream tree is cloned and every submodule is re-pinned to its own
tracked branch tip (see the comment in that script for why the re-pin step
exists). A patch that fails to apply is a hard build failure, not a warning —
see the script for why. **The one exception:** a patch directory named after
the root `singularity-desktop` repo itself (not a subproject/submodule)
applies at the top level instead of `subprojects/<name>/`.

Every patch here corresponds to an **open, unmerged upstream PR**. Once a PR
merges, delete its patch(es) from here in the same commit that bumps past it
— an applied-but-redundant patch is relatively harmless (the idempotency
check just reports "already present"), but a stale README entry claiming a
patch is still needed when it is not is actively misleading.

**This is automated** (2026-09-29 rewrite). `build/singularity-patch-reconcile.py`
walks every patch FILE here, matches it to its block in this README, and
queries the PR state (`gh pr view --json state`). A patch is deleted only when
its PR is MERGED, its block is not marked superseded, and it reverse-applies to
upstream head (`git apply --check -R`). CLOSED PRs, merged-but-different
patches, superseded blocks and patches with no entry here are reported and kept.
`build/singularity-nightly-track.sh` runs it nightly from `main` (systemd user
timer, 03:15) and commits any retirement to a bot branch
`auto/singularity-reconcile-<date>`, never to `main`. Every patch file needs a
block here (`**Upstream PR:**` or `**No upstream PR:**`).

## singularity-shell — active

**Upstream PR:** [singularityos-lab/singularity-shell#30](https://github.com/singularityos-lab/singularity-shell/pull/30)
— open, not yet merged. Patch `0002-choose-attribution-quadrant.patch`.
Needs its schema companion, `singularity-desktop#262` below, or the
Settings row this adds writes a key the shell can't read yet. Extends
the wallpaper title/author overlay from a fixed bottom-left position to
a user-selected quadrant.

Delete this patch once PR #30 merges.

**No upstream PR:** prepared, not filed. Branch
`upstream-ready/plain-contrast-20261005` on ARGONAS (`9f502f9`), rebased on
the current `singularity-shell#30` tip per the rebase rule. Patch
`0003-plain-contrast-live-quadrant-and-wrap.patch`: plain auto-contrast
attribution text, live quadrant move and a two-line wrap. Depends on
`singularity-shell#30` above; file it only after #30 merges.

Delete this patch once it lands upstream.

## singularity-desktop — active

**Upstream PR:** [singularityos-lab/singularity-desktop#262](https://github.com/singularityos-lab/singularity-desktop/pull/262)
— open, not yet merged. Patch
`0001-wallpaper-attribution-position-schema.patch` (applies at the
top level, not under `subprojects/`, per this file's own root-repo
exception above). Adds the `wallpaper-attribution-position` gschema
key that `singularity-shell#30` above reads. Additive only, defaults
to bottom-left, no existing behavior changes on its own.

Delete this patch once PR #262 merges.

**Upstream PR:** [singularityos-lab/singularity-desktop#267](https://github.com/singularityos-lab/singularity-desktop/pull/267)
— open, not yet merged. Patch
`0002-sensors-settings-keys-and-color-mode.patch`. Declares the sensors-*
gschema keys. #267 covers the six `sensors-*` keys only; the patch's extra
`sensors-color-mode` key is NOT in #267, so once #267 merges this patch will
not reverse-apply and must be reduced to that one key by hand (the reconcile
script reports MERGED-KEEP, not RETIRE).

Delete this patch once the keys land upstream.

## singularity-plugins — active

**Upstream PR:** [singularityos-lab/singularity-plugins#2](https://github.com/singularityos-lab/singularity-plugins/pull/2)
— open, not yet merged. Patch
`0001-sensors-dpi-columns-bordered-sections.patch`.

Restores two things that regressed when sensors moved out of
`panel.vala` into this standalone plugin: (1) column count in the
sensors popover now derives from monitor scale factor as well as
logical width (up to 3 columns), not a fixed 1-or-2 split at one
breakpoint; (2) `begin_detail_section()` applies the
`sensors-resource-section` CSS class so each resource-pool section
(CPU/GPU/VPU/Storage/...) reads as a distinct bordered card instead of
one continuous list — the exact "outlined groups" behavior.  The CSS lives in the
plugin's own provider, so it no longer needs a libsingularity patch.

Delete this patch once PR #2 merges.

**Upstream PR:** [singularityos-lab/singularity-plugins#3](https://github.com/singularityos-lab/singularity-plugins/pull/3)
— open, not yet merged, and superseded by the two patches below (that PR
wrote `~/.config/ncz-wallpaper/bing-markets`; these use a generic path and
pass the choice to the helper). Patches
`0002-wallpapers-bing-preferred-market.patch` (Preferred market row; the
choice picks the language of titles and credits and lists that market's
photos first while the feed stays combined) and
`0004-wallpapers-bing-prefetch.patch` (the plugin fetches the feed on
activation with network-aware retry). Both need the helper flags added in
`assets/wallpaper/ncz-wallpaper-bing`; see `docs/WALLPAPER-BING-PREFETCH.md`.

Prepared branches on ARGONAS (not filed): `upstream-ready/bing-preferred-market-20261005`
(`5c0b6fc`, clean upstream-main base) and `upstream-ready/bing-prefetch-20261005`
(`2bae472`, on top of it). The prefetch patch has no PR of its own and also
replaces the #3 approach, so #3 should be closed rather than merged.

Delete these patches once they merge upstream.

**Upstream PR:** [singularityos-lab/singularity-plugins#4](https://github.com/singularityos-lab/singularity-plugins/pull/4)
— open, not yet merged. The `owner_id` half is also open separately as
[singularity-plugins#6](https://github.com/singularityos-lab/singularity-plugins/pull/6).
Patch `0003-ocs-fetch-index-and-fix-import-owner.patch`: `choices()` fetches
its own index and the import finds its provider through `owner_id`. This one
patch therefore covers both #4 and #6.

Delete this patch once #4 and #6 have both merged.

**Upstream PR:** [singularityos-lab/singularity-plugins#5](https://github.com/singularityos-lab/singularity-plugins/pull/5)
— open, not yet merged. Patch `0005-sensors-adaptive-contrast.patch`. Sensors
text keeps contrast against the real background; depends on
`singularity-plugins#2`.

Delete this patch once PR #5 merges.

## Open upstream PRs deliberately NOT carried as patches (2026-10-05)

These upstream PRs are open but the build does not carry a patch for them.
They are new feature stacks that NCZ-OS does not need before they merge, and
each drags in schema keys plus shell/plugin code that is still unreviewed:

- `singularity-desktop#264` (wallpaper-effect keys), `#265` (wallpaper
  history/favorites keys), `#266` (wallpaper rotation filter keys). Not
  carried: nothing in the shipping desktop reads these keys yet without the
  matching shell PRs below, and schema-only patches carry their own abort risk
  (see the retired #251 note below).
- `singularity-shell#32` (history/favorites), `#33` (+effects), `#34`
  (+rotation filters). Not carried: feature stacks still under review; the
  build deliberately tracks only the reviewed, NCZ-required set.

`singularity-plugins#4` and `#6` ARE carried, indirectly: both are covered by
the single `singularity-plugins/0003-ocs-fetch-index-and-fix-import-owner.patch`
block above.

## libsingularity — retired 2026-09-29

**Upstream PR:** [singularityos-lab/libsingularity#15](https://github.com/singularityos-lab/libsingularity/pull/15)
— **CLOSED** unmerged by the maintainer. Patch
`0001-sensors-resource-section-outline.patch` deleted: the
`.sensors-resource-section` style now lives in the plugin's own CSS provider
(`singularity-plugins#2`, head `93a5bd56`).

## Previously landed

**Currently no OTHER patches carried.** Everything else previously tracked
here has merged upstream:

## singularity-desktop — retired 2026-09-18

**Upstream PR:** [singularityos-lab/singularity-desktop#251](https://github.com/singularityos-lab/singularity-desktop/pull/251)
— **MERGED** (`2281b4d26a4f1fde073c799ffda175170f63adcf`, 2026-09-18).
Verified against real upstream `singularity-desktop` HEAD: all three keys
(`show-wallpaper-attribution`, `background-attribution-title`,
`background-attribution-author`) are genuinely present in
`data/dev.sinty.desktop.gschema.xml` — confirmed by cloning upstream fresh
and reading the file directly, not inferred from PR-merged status alone.
Patch `0001-fix-schema-add-the-background-attribution-keys.patch` deleted.

Fixed a real live bug: `g_settings_get_boolean()`/`g_settings_get_string()`
on a key the schema does not declare **aborts the process** (GLib fail-fast
on a schema mismatch) — this was a confirmed `singularity-desktop` SIGABRT
crash loop on O6N (9 crashes in 35 seconds via `coredumpctl`) before the fix.

## labwc — retired (date unclear, inherited from `master`'s `59b48a7`)

**Upstream PR:** [singularityos-lab/labwc#5](https://github.com/singularityos-lab/labwc/pull/5)
— **MERGED** (`025808d51a32be0a18efe0c9445c7fb18ee39718`, 2026-09-18).

**Note on content drift:** this branch's history previously described the
carried patch as a two-part fix (a `power_off` tracking flag plus changes to
`handle_output_request_state()`). The commit that actually merged upstream is
narrower — a 2-line change in `src/output.c` scheduling a frame on a fresh
`wlr_scene_output` so its `needs_frame`-false short-circuit doesn't skip the
atomic commit that binds the CRTC on replug. The merge commit's own message
states this was deliberately rescoped in review: "the unverified mode-test
retry and its timer teardown are dropped entirely, leaving only the fix
confirmed on hardware" (O6N + MS-R1, repeated unplug/replug). No patch file
exists in this tree to delete — it was already removed before this branch's
history begins, per the note that used to live here. Recorded now so a
future reader isn't confused by this doc having previously described
different code than what's actually upstream.

## singularity-shell — retired (date unclear, inherited from `master`'s `59b48a7`)

**Upstream PRs:** [#25](https://github.com/singularityos-lab/singularity-shell/pull/25)
and [#26](https://github.com/singularityos-lab/singularity-shell/pull/26) —
both **MERGED** (2026-09-14 and 2026-09-17 respectively, per `gh pr list
--state merged`). No patch files exist in this tree — already removed
before this branch's history begins.

## Artist Packs

Contributed wallpaper art (currently Brandon Perlow and Alex Jay Brady,
`build/build-wallpaper-contrib-deb.sh`) ships as separate `.deb`s staged at
`assets/wallpaper-debs/*.deb` (gitignored, like `assets/cix-debs` — rebuild
with that script rather than committing the blob), installed by
`post-install/45-wallpaper-rotator.sh` alongside the built-in `ncz` and
`bing` collections. See `docs/wallpaper-packs.md` (website repo) for the
`.collection` format these packs, and any future third-party one, use.
