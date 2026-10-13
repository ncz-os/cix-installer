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
03:15, the same cadence as the existing `ncz-singularity-sync`) and
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
`g_type_check_instance_is_fundamentally_a` (Radxa Orion O6N arm64, core pid 2613,
2026-10-11). The patch makes the captures owned so the objects stay valid until
the timer fires. This is the image-blocking arm64 crash-loop fix.

Delete this patch once PR #37 merges.

**Not yet filed upstream** (2026-10-11). Patches
`0013-lockscreen-honour-output-scale.patch`,
`0014-lockscreen-host-an-out-of-process-frame-source.patch`,
`0015-lockscreen-overlay-unlock-prompt-on-screensaver.patch`,
`0016-lockscreen-no-prompt-on-pointer-enter.patch` and
`0018-lockscreen-share-the-login-card-field-label.patch`, applied in that order
(0014 depends on the `struct lock_output.scale` field that 0013 adds; 0015
extends 0014's frame-source hook to also hold the source during input, so the
unlock prompt composites over the live saver rather than a flat background;
0016 fixes the raise-on-lock defect described below).

- `0013` makes the session-lock client render at the output's scale instead of
  letting the compositor upscale (the lock screen and its prompt were blurry on a
  HiDPI output), and logs the configured surface geometry. Generic; the
  scale-only part is the upstreamable change.
- `0014` adds an optional, build-flagged (`-Dlock_framesrc=enabled`) host that
  lets a **separate process** render a screensaver off-screen and hand the lock
  client a buffer fd over an AF_UNIX socket, which the lock imports and presents
  on its lock surface. While a session is locked, `ext-session-lock-v1` presents
  only the lock surface, so a second process cannot draw underneath it; this is
  how a screensaver can be shown over the lock. The lock never executes
  frame-source code, so a crash/hang/GPU error/bad fd degrades to the lock's own
  Cairo prompt (fail-closed). Default off: the upstream locker is unchanged.
- `0015` keeps the 0014 frame source running on input instead of stopping it,
  and composites the clock and password card over the live saver behind a light
  scrim (the prompt hides again after the idle delay and the raw frames return).
  Same build flag (`-Dlock_framesrc=enabled`); no upstream PR link on purpose;
  nothing filed upstream for this part either.
- `0016` fixes a defect in `0015`: the prompt was raised from the pointer ENTER
  handler, so on a host where the full-screen lock surface maps under the
  (stationary) cursor the compositor's enter (no user action) painted the
  password card at lock time instead of the raw saver frames. The prompt now
  raises only on a real key press, pointer button or pointer movement; a motion
  delivered at the entered position (an initial motion some compositors send)
  is ignored because the position did not change. Same build flag; no upstream
  PR link (nothing filed upstream for this part either). The regression is
  pinned by `tests/lockscreen-framesrc/test-framesrc.sh` cases 7-9
  (`idle -> lock, no prompt before input`).

- `0018` derives the unlock card's credential-field label through the shared
  `loginui_field_label()` helper added by `singularity-loginui/0003`, so the
  lock's card and the greeter's card are built from ONE code path instead of
  two hand-kept copies (the greeter had drifted: a duplicate status/prompt row
  under the field and no output-scale render). No behaviour change on the lock
  (still `Password`, or `PIN` when the `sock` broker is present). It edits
  `src/lockscreen/lock_main.c` -- the SAME file the thermals `0017` patch
  edits -- so `0017` must land first and the queue order must stay
  `...0016, 0017, 0018`; the two changes are at different sites and were
  verified to apply in that order (`0017` then `0018`).

None of 0013-0016 nor 0018 has a `**Upstream PR:**` link on purpose (nothing is filed; the
mirkoprs task owns the upstream offer). Delete them if/when the corresponding
change lands
upstream.

**Not yet filed upstream** (2026-10-13). Patch `0020-titlebar-buttons-when-legacy.patch`.
The labwc SSD layout (Chromium, foot, GTK apps with CSD off) is sourced from
`org.gnome.desktop.wm.preferences.button-layout` (default `appmenu:close`,
close-only). The `dev.sinty.desktop.legacy-titlebar` toggle ("Show a classic
static titlebar with inline buttons instead of the floating hover window
controls") currently controls only libsingularity CSD apps and is not wired
to `write_labwc_rc_xml` or `apply_gtk_decoration_layout`, so even with the
toggle on a user got close-only on every SSD window. The patch adds one
helper `effective_button_layout()` that returns `appmenu:minimize,maximize,close`
when `legacy-titlebar` is true and feeds it into both writers; it also wires
`settings.changed["legacy-titlebar"]` to the same writers (matching the
existing `button-layout` listener). Upstream default (legacy-titlebar=false)
is unchanged. The patch is a generic helper, no NCZ paths/naming.

No `**Upstream PR:**` link on purpose (nothing is filed). The mirkoprs task
owns the upstream offer.

## singularity-greeter — active

**Not yet filed upstream** (2026-10-11). Patches
`0001-greeter-cancel-session-before-recreate.patch`,
`0002-greeter-answer-info-error-messages.patch` and
`0003-greeter-match-the-lock-login-card.patch`, applied in order.

- `0001` fixes "a session is already being configured": after a rejected password
  the greeter called `create_session` again while greetd still held the session
  under configuration. It now cancels first and re-creates only once greetd
  acknowledges the cancel.
- `0002` fixes a stuck "Authenticating…": greetd's PAM conversation blocks on
  every `auth_message` including the `info`/`error` kinds, and the greeter
  displayed them without replying. It now replies with a null response.

- `0003` makes the greeter paint the SAME login card as the session lock
  (2026-10-12: the greeter should match the lock visually). Two
  drifts were removed: (a) the greetd/PAM prompt was drawn as a SECOND row
  under the field (so the greeter card showed both a placeholder and a
  `Password:` row while the lock showed one field) -- the prompt is now
  resolved into the single shared field label via `loginui_field_label()`
  (`singularity-loginui/0003`) and the auth message is still handled and shown
  in that one field; (b) the greeter rendered a logical-size buffer the
  compositor upscaled, so on a HiDPI panel its card landed a fraction of a
  pixel off the lock's natively-rendered one -- it now renders at the output's
  `wl_output.scale` exactly as the lock does (0013). The greeter's own extras
  (user dots, power button, brand footer, session pill) are kept and do not
  move or restyle the shared card. Verified pixel-for-pixel against the lock
  at 1920x1080@1x, 3840x2160@2x and 3072x1920@2x.

No `**Upstream PR:**` link on purpose (nothing is filed). Real-greetd
confirmation on hardware is still to be done.

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
retired when #3 merges.

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
maintainer; not yet filed). Patch
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
is a known environment-only failure on some build hosts). No `**Upstream PR:**` link on purpose.

**Not yet filed upstream** (2026-10-12). Patch
`0003-loginui-share-the-login-card-field-label-session-only.patch` adds
`loginui_field_label()`: the one derivation of the login card's credential-field
label, used by BOTH login surfaces (the greeter and the session lock) so the
shared card cannot drift between them again. It normalises a greetd/PAM prompt
(strips a trailing `:` and surrounding whitespace) so a PAM `Password: ` renders
identically to the lock's own `Password`, and falls back to the credential kind
(`PIN`/`Password`) when there is no prompt. The file name carries `session-only`:
the boot splash's bundled loginui copy is a different commit and has no session
surface, so `build-singularity.sh` and `singularity-pins.sh check-patches` skip
it there (it is applied to the desktop `subprojects/singularity-loginui`).
Parity evidence: `greetmatch` -- card-region pixel diff 0 px at all three target
geometries. No `**Upstream PR:**` link on purpose.

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
crash loop on Radxa Orion O6N (9 crashes in 35 seconds via `coredumpctl`) before the fix.

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
confirmed on hardware" (Radxa Orion O6N + MS-R1, repeated unplug/replug). No patch file
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
`bing` collections. See [`docs/WALLPAPER-PACKS.md`](../../../docs/WALLPAPER-PACKS.md) for the
`.collection` format these packs, and any future third-party one, use.
