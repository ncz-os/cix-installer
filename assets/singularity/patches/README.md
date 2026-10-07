# Singularity Desktop downstream patches

Patches carried against `singularityos-lab/singularity-desktop` (and its
bundled `labwc` subproject) for NCZ-OS on CIX Sky1, applied automatically by
`build/build-singularity.sh` from `assets/singularity/patches/<subproject>/`
after the upstream tree is cloned and every submodule is checked out at its
pinned commit in `assets/singularity/upstream-pins.tsv` (since 2026-10-06;
before that, every submodule was re-pinned to its tracked branch tip, and an
upstream push broke the r199 respin the same day). `build/preflight-freshness-gate.sh`
check [2] and `build/singularity-pins.sh check-patches` verify each queue
against those pinned commits. A new or rebased patch must apply to the pinned
commit; moving to newer upstream is a deliberate pin bump
(`build/singularity-pins.sh propose`, then `check-patches`, then a build). A patch that fails to apply is a hard build failure, not a warning —
see the script for why. **The one exception:** a patch directory named after
the root `singularity-desktop` repo itself (not a subproject/submodule)
applies at the top level instead of `subprojects/<name>/`.

Every patch here corresponds to an **open, unmerged upstream PR**. Once a PR
merges, delete its patch(es) from here in the same commit that bumps past it
— an applied-but-redundant patch is relatively harmless (the idempotency
check just reports "already present"), but a stale README entry claiming a
patch is still needed when it is not is actively misleading.

**This is now automated, not just a manual convention** (2026-09-21).
`build/singularity-patch-reconcile.py` queries each `**Upstream PR:**` link's
real GitHub state (`gh pr view --json state`) and, for anything MERGED,
deletes the patch file(s) and rewrites this section into a retired entry —
same shape as the retired entries below. `build/singularity-nightly-track.sh`
runs it nightly (systemd timer, `build/systemd/ncz-singularity-patch-*`,
03:15, same cadence as ULTRA's existing `ncz-singularity-sync`) and
commits+pushes if anything changed. It retires a merged PR's patch only once
the pinned upstream commit contains the merge; until the pin is bumped past
it, the patch stays (the pinned build still needs it) and the script says so. A human editing this file by hand is
still fine — the script only ever removes, never re-adds — but the nightly
run means a merged PR's patch won't sit stale for days between manual passes.

## singularity-shell — active

**Upstream PR:** [singularityos-lab/singularity-shell#30](https://github.com/singularityos-lab/singularity-shell/pull/30)
— open, not yet merged. Patch `0002-choose-attribution-quadrant.patch`.
Needs its schema companion, `singularity-desktop#262` below, or the
Settings row this adds writes a key the shell can't read yet. Extends
the wallpaper title/author overlay from a fixed bottom-left position to
a user-selected quadrant.

Delete this patch once PR #30 merges.

## singularity-desktop — active

**Upstream PR:** [singularityos-lab/singularity-desktop#262](https://github.com/singularityos-lab/singularity-desktop/pull/262)
— open, not yet merged. Patch
`0001-wallpaper-attribution-position-schema.patch` (applies at the
top level, not under `subprojects/`, per this file's own root-repo
exception above). Adds the `wallpaper-attribution-position` gschema
key that `singularity-shell#30` above reads. Additive only, defaults
to bottom-left, no existing behavior changes on its own.

Delete this patch once PR #262 merges.

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
one continuous list — the exact "outlined groups" behavior. Depends on
`libsingularity#15` below for the CSS class to exist at all.

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

Delete these patches once they merge upstream.

## libsingularity — active

**Upstream PR:** [singularityos-lab/libsingularity#15](https://github.com/singularityos-lab/libsingularity/pull/15)
— open, not yet merged. Patch
`0001-sensors-resource-section-outline.patch`. Adds the
`.sensors-resource-section` CSS class (1px border, 8px radius, padding)
that `singularity-plugins#2` above applies. CSS-only, 10 lines.

Delete this patch once PR #15 merges.

**Not yet filed upstream** (proposed to Mirko Brombin, the upstream
maintainer, by this branch's operator brief; NOT filed by this task). Patch
`0002-user-theme-loads-above-base.patch`. The theme template documents that
a user theme's `singularity/style.css` "is loaded above the built-in
libsingularity base", but at the current priorities it is loaded at
`GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 5` / `+ 6` (605/606) -- BELOW the
base palette at `GTK_STYLE_PROVIDER_PRIORITY_USER` (800), so a theme can
only add properties and use its own named colours; it cannot override a base
named colour (`@window_bg`, `@surface_bg`, `@text_color`, ...) or any
property the base already sets. Raises the user theme to `USER + 3` and its
variant to `USER + 4` so a theme can opt into overriding the base, as the
template already promises. Small and general, not NCZ-specific: it is what
makes the Cygnus violet-black surfaces apply.

Deliberately has no `**Upstream PR:**` link, so
`build/singularity-patch-reconcile.py` will not auto-retire it. When the
change is filed and merged upstream, delete the patch and this block.

**Not yet filed upstream.** Patch `0003-cups-link-as-plain-library.patch`
(2026-10-07). libsingularity 23fb1709 lists `dependency('cups')` among the
dependencies of the Vala library target, so meson passes `--pkg cups` to valac,
and Debian forky's valac 0.56.19 (like Ubuntu 24.04's) has no cups binding:
`error: Package 'cups' not found in specified Vala API directories`. Only the
C file `src/print/ipp_transport.c` uses libcups, so the patch finds the library
with `cc.find_library('cups')` and checks `cups/cups.h`. Deliberately has no
`**Upstream PR:**` link, so `build/singularity-patch-reconcile.py` will not
auto-retire it. When upstream carries a binding or changes the dependency,
delete the patch and this block.

## singularity-loginui — active

**Not yet filed upstream.** Patch
`0001-splash-fit-logo-to-surface-and-scale-loading-bar.patch`.
`loginui_render_splash()` sized the logo from the surface height alone
(16 %), so the 696x52 Cygnus wordmark came out about 2.1x the screen height
wide and was cropped on every landscape display (about 4100 px wide on the
3072x1920 MacBookPro16,1 panel, about 2300 px on 1920x1080), and the loading
bar was a fixed 220x4 px. The patch fits the logo inside 60 % of the width
and 16 % of the height and grows the bar with the surface height. Square
emblem logos are unchanged.

This one patch reaches two binaries: the session splash, through the
desktop tree's `subprojects/singularity-loginui` (the generic loop in
`build/build-singularity.sh`), and the native KMS boot splash, whose separate
repository bundles its own loginui copy (the dedicated loop in the
boot-splash section of the same script). Policy and render evidence:
`docs/HIDPI-SCALING.md`.

Deliberately has no `**Upstream PR:**` link, so
`build/singularity-patch-reconcile.py` will not auto-retire it. Filing it
upstream needs the singularityos-lab AI-disclosure trailers that the
project's CI enforces. When it merges upstream, delete the patch and this
block.

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
