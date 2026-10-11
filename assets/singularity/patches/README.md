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

**Upstream PR:** [singularityos-lab/singularity-shell#37](https://github.com/singularityos-lab/singularity-shell/pull/37)
— open, not yet merged. Patch `0006-dock-launch-feedback-owned-timer-captures.patch`.
Fixes a use-after-free in `DockLaunchFeedback.stretch_dot()`: the 10 s give-up
timer captured the dock-item wrapper and its dot with `unowned` (raw) pointers,
so a dock rebuild/destroy inside that window made the callback call
`g_object_get_data()` on freed memory — SIGSEGV in
`g_type_check_instance_is_fundamentally_a` (O6N arm64, core pid 2613,
2026-10-11). The patch makes the captures owned so the objects stay valid until
the timer fires. This is the image-blocking arm64 crash-loop fix.

Delete this patch once PR #37 merges.

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
— open. Patch `0002-sensors-settings-keys.patch`. Declares the six `sensors-*` keys the
sensors plugin reads (interval 2 s with range 1-60, frequency, utilization, grouped,
GPU and CPU zone). The earlier private `sensors-color-mode` key is gone: nothing in the
pinned payload reads it. Delete this patch once PR #267 merges.

## singularity-plugins — active

All six patches are the heads of our upstream PRs, applied in order to the pinned commit
(7bc0e598), except 0004. The 2026-10-07 convergence replaced the earlier private variants
that had drifted from what the maintainer reviewed.

**Upstream PR:** [singularityos-lab/singularity-plugins#2](https://github.com/singularityos-lab/singularity-plugins/pull/2)
— open. Patch `0001-sensors-dpi-columns-bordered-sections.patch`. Popover column
count from the logical width only (up to 3) and the `.sensors-resource-section`
outline, defined in the plugin own `compact_rows_provider` so libsingularity is not
touched. Delete this patch once PR #2 merges.

**Upstream PR:** [singularityos-lab/singularity-plugins#3](https://github.com/singularityos-lab/singularity-plugins/pull/3)
— open. Patch `0002-wallpapers-bing-preferred-market.patch`. Preferred Region row:
the market list comes from the helper `markets` command and the choice is read and
saved through the helper `market` command (added to `assets/wallpaper/ncz-wallpaper-bing`,
covered by `build/test-wallpaper-market.sh`). Delete this patch once PR #3 merges.

**Upstream PR:** [singularityos-lab/singularity-plugins#4](https://github.com/singularityos-lab/singularity-plugins/pull/4)
— open. Patch `0003-ocs-fetch-index.patch`. `choices()` fetches its own index from the
helper. Delete this patch once PR #4 merges.

**Upstream PR:** [singularityos-lab/singularity-plugins#5](https://github.com/singularityos-lab/singularity-plugins/pull/5)
— open. Patch `0005-sensors-adaptive-contrast.patch`. WCAG contrast for the sensors chip
and popover. Delete this patch once PR #5 merges.

**Upstream PR:** [singularityos-lab/singularity-plugins#6](https://github.com/singularityos-lab/singularity-plugins/pull/6)
— open. Patch `0006-ocs-import-owner-id.patch`. Items carry the provider id as owner so
imports find the provider. Delete this patch once PR #6 merges.

**Not yet filed upstream.** Patch `0004-wallpapers-bing-prefetch.patch`, stacked on #3:
runs the helper `fetch --if-stale` on activation, when the network returns and daily,
skipping metered links, with backoff. It has no PR link on purpose: it must not be
retired when #3 merges. See `docs/WALLPAPER-BING-PREFETCH.md`.

**Not yet filed upstream** (draft in the r200 upstream-drafts folder). Patch
`0007-sensors-popover-tabs-per-category.patch`, on top of #2 and #5. The sensors popover
stacked every category in one tall column that reached the dock on a 16 inch panel. It now
has tabs (CPU, Processor, Memory & Storage, Hardware; empty tabs are left out)
using `Singularity.Widgets.SegmentedControl` over a `Gtk.Stack`. Grouped/Ungrouped works
inside each tab, the logical-width column count from #2 is unchanged, the per-group row cap
is 12 (was 6) and a height cap (monitor - chip bottom - dock - gap) stays as a safety net.
No `**Upstream PR:**` link on purpose.

## libsingularity — active

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

**Not filed upstream** (2026-10-07). Patch
`0003-build-cups-flags-not-a-vala-package.patch`. The 2026-10-06
libsingularity release added `dependency('cups')` to the Vala target, which
makes meson pass `--pkg cups` to valac. Debian's valac (0.56.19) ships no
`cups.vapi`, so the build stops with "Package `cups' not found in specified
Vala API directories". No Vala source uses a libcups binding (only
`src/print/ipp_transport.c` does), so the patch passes the cups compile and
link flags directly, exactly as `lcms2` is already handled in the same file.
Delete it when upstream stops handing libcups to valac or Debian ships the
binding.

**Not filed upstream** (2026-10-07). Patch
`libsingularity/0004-drag-lift-bind-drag-icon-unowned.patch`. Vala 0.56's
gtk4.vapi declares `DragIcon.get_for_drag` as a named constructor, so the
static-method call in `drag_lift.vala` stops valac with "use `new' operator".
Writing `new Gtk.DragIcon.get_for_drag(drag)` compiles but is wrong: the C
function returns the drag's existing icon widget (transfer none) and Vala
would unref a reference it never took when the variable goes out of scope. The
patch binds the C function as an unowned function in `gdkextra.vapi`. Delete it
when upstream's call compiles against the distribution's vapi.

**Not filed upstream** (2026-10-07). Patch
`singularity-write/0001-write-implement-accessibletext-vfuncs-added-in-gtk-4-22.patch`.
`WriteDocView` implements `Gtk.AccessibleText` but not the five vfuncs GTK 4.22
added, which Vala 0.56's gtk4.vapi declares abstract. Each reports "not
supported". Delete it when upstream implements them.

**Not filed upstream** (2026-10-07). Patch
`singularity-shell/0004-wallpaper-tests-link-libm.patch`. Three wallpaper test
executables compile `dynamic_wallpaper.vala` (which calls `sin()`) without a
math library; Debian's linker has no implicit DT_NEEDED and stops with
"undefined reference to symbol 'sin@@GLIBC_2.17'". Adds `cc.find_library('m')`.
Delete it when upstream does.

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

**Not yet filed upstream.** Patch `0002-brand-splash-keep-logo-aspect-session-only.patch`.
`loginui_render_brand()` (the splash `singularity-splash` shows after greeter login) scaled
the logo with `cairo_scale(size / lw, size / lh)`, forcing every logo into a 256x256 square.
`singularity-splash` loads the OS wordmark with `loginui_load_image(path, -1, 256)`, a wide
image, so the 13:1 Cygnus wordmark came out squeezed horizontally and stretched vertically.
The patch fits the logo inside a box (256 tall, up to 768 or half the surface wide) with one
scale factor, centred, and puts the loading bar 48 px under the drawn logo; square emblems
are unchanged. The file name carries `session-only`: the boot splash's bundled loginui copy
has no `brand.c`, so the build and `singularity-pins.sh check-patches` skip such patches there.
Separate from 0001, which fixes `loginui_render_splash()` (the boot splash).
Covered by `build/test-splash-brand-aspect.sh` (manual, like `test-splash-logo-fit.sh`, which
is a known env-only failure on HYDRA). No `**Upstream PR:**` link on purpose.

## singularity-session — active

**Not filed upstream.** Patch `0001-session-no-software-fallback-with-gpu.patch` is the
NCZ never-software-render policy (refuses the software compositor retry when a render
device exists) and stays downstream; a neutral opt-out env var is drafted separately.
Patch `0002-supervisor-per-run-logs-signals-core.patch`: per-run shell logs, named crash
signals, core limit; drafted for upstream, not yet filed. Neither has an
`**Upstream PR:**` link, so the reconcile script never retires them.

## singularity-shell — also carried, not filed

Patch `0003-plain-contrast-live-quadrant-and-wrap.patch` (plain attribution text, live
quadrant move, two-line wrap) sits on top of `0002` above and has no PR link; its two bug
fixes are drafted as follow-ups to #30.

Patch `0005-plugins-add-a-screensaver-and-lock-category.patch` adds the `lock` row
("Screensaver and Lock") to the Settings > Plugins hub category table, between Files
and Previews and Tools, so a plugin declaring `X-Singularity-Category=lock` (the
ncz-screensavers plugin, 0.3.20) gets its own row instead of sitting in Tools. One
table line: the rows, links, counts and search filtering are all built from the table.
A shell without the row treats the unknown id as Other. Not filed upstream yet (no PR
link, so the reconcile script never retires it); the upstream draft is
`upstream-drafts/singularity-shell/08-lock-category`.

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

## libsingularity — retired 2026-10-07 (closed, not merged)

**Upstream PR:** [libsingularity#15](https://github.com/singularityos-lab/libsingularity/pull/15) was closed by the
maintainer ("plugin-specific styles belong in the plugin"). Patch
`0001-sensors-resource-section-outline.patch` deleted: the class now lives in
`singularity-plugins/0001`, and nothing else in the pinned shell, libsingularity or
plugins reads `sensors-resource-section`.

## Artist Packs

Contributed wallpaper art (currently Brandon Perlow and Alex Jay Brady,
`build/build-wallpaper-contrib-deb.sh`) ships as separate `.deb`s staged at
`assets/wallpaper-debs/*.deb` (gitignored, like `assets/cix-debs` — rebuild
with that script rather than committing the blob), installed by
`post-install/45-wallpaper-rotator.sh` alongside the built-in `ncz` and
`bing` collections. See `docs/wallpaper-packs.md` (website repo) for the
`.collection` format these packs, and any future third-party one, use.
