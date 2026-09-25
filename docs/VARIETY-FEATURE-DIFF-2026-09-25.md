# Variety feature diff - 2026-09-25

## Scope and evidence

This compares Variety 0.9.0/master with `singularityos-lab/singularity-shell`
`9776811` and the fork commits `62d6905`, `f52f031`, `1dafed2`, and `de80e23`.
It is a feature comparison, not a proposal to copy Variety's GPL-3.0 code.

Primary sources:

- [Variety README](https://github.com/varietywalls/variety#readme)
- [Variety 0.9.0 releases](https://github.com/varietywalls/variety/releases)
- [Variety command-line and D-Bus entry point](https://github.com/varietywalls/variety/blob/master/variety/__init__.py)
- [Variety default configuration](https://github.com/varietywalls/variety/blob/master/variety/data/config/variety.conf)
- [Variety desktop quick actions](https://github.com/varietywalls/variety/blob/master/variety.desktop)
- [Variety preferences UI](https://github.com/varietywalls/variety/blob/master/variety/data/ui/PreferencesVarietyDialog.ui)

The Singularity status below is based on commit reachability, file inspection,
and tests, not branch names or commit subjects alone.

## What is actually upstream

Current upstream has local and plugin-provided wallpaper collections, online
provider browsing, interval rotation, an opt-in in-process rotator, current-image
exclusion, provider attribution, and an attribution position control. The real
rotation groundwork landed through PR #25: upstream contains `9a11855` and its
safe-default follow-up `97a9455`.

The supplied Phase 1 status is incorrect as of `9776811`. Commit `62d6905` is
not an ancestor of upstream `main`; `src/core/wallpaper_favorites.vala` and
`src/core/wallpaper_history.vala` do not exist upstream; and PR #28 is the Artist
Pack browser. Therefore favorites, bounded previous/next history, and the Phase
1 panel controls are built on the fork but are not shipped upstream.

## Built on the fork but not merged

### Phase 1: favorites, history, and panel controls

Commit `62d6905` contains real persistence classes, panel actions, a
path-specific wallpaper signal, and focused tests. It is not present on current
upstream and needs its own clean rebase/PR before code may rely on
`WallpaperFavorites`.

### Phase 2: cached effects

Commit `f52f031` contains real native implementations of grayscale, a
three-pass box/convolution blur, oil painting, and a Cairo/Pango quote overlay.
`tests/wallpaper_effects_test.vala` exercises all four transforms and a cache
hit. Quote rendering is not scaffold code: it creates a Cairo surface, lays out
the supplied text with Pango, draws a translucent rounded backing and shadow,
and converts the rendered surface back to a pixbuf.

The old commit is not merge-ready unchanged. Its settings page reads
`wallpaper-effect`, `wallpaper-effect-blur-radius`, and
`wallpaper-effect-quote-text`, but neither the commit nor current upstream's
schema repository defines those keys. The transform layer is real; the old UI
wiring is not functional without a state contract. The cache is bounded at 500
MiB and keyed by source identity, output dimensions, effect, and parameters.

Compared with Variety, this is deliberately narrower. Variety can randomly
select from configurable ImageMagick filters, and its current defaults also
include pointillism and pixelation. Singularity's branch selects one native
effect and has no arbitrary command filter surface, which is preferable for a
compositor-owned component but is not full feature parity.

### Phase 3: smart selection

The genuine new Phase 3 change is `de80e23`: minimum image dimensions,
same-aspect preference, threefold favorites weighting, and an immediate
next-wallpaper action, with deterministic tests. The preceding
`1dafed2`/upstream `9a11855` work is the runtime rotator required by the already
shipped rotation settings; it is groundwork, not smart selection.

The Phase 3 commit is not independently mergeable today because favorites
weighting imports `WallpaperFavorites`, which is only on the unmerged Phase 1
commit. A Phase 3 PR must either follow a Phase 1 PR or omit favorites weighting
and honestly narrow its scope.

## Genuine gaps relative to Variety

### High-value interaction gaps

- **Blacklist / never show again:** missing. Variety maintains banned image
  URLs and exposes trash/reject behavior separately from favorites. Singularity
  has deletion for owned collection items but no durable ban identity that also
  prevents an online provider from returning the image again.
- **Desktop-entry or desktop-context quick actions:** partially missing.
  Variety's desktop entry provides Next, Previous, Pause/Resume, History, and
  Preferences actions. Phase 1 puts comparable actions in the shell panel, but
  it is unmerged, and there is no wallpaper/background right-click menu.
- **Scriptable control surface:** missing. Variety forwards command-line
  requests to the running per-profile instance over session D-Bus and supports
  actions such as next, previous, pause, history, preferences, and current
  metadata. Singularity has an internal object signal but no stable D-Bus or CLI
  wallpaper API.
- **Complete history/recent-download browser:** missing upstream. The fork's
  Phase 1 has bounded navigation state, not Variety's thumbnail history and
  recent-download views.

### Source and acquisition gaps

- **Source breadth and user-defined sources:** partial. Singularity has a plugin
  provider boundary and the existing OCS/Bing/Openverse-style work, while
  Variety ships multiple direct downloaders and lets users configure folders,
  feeds/searches, and source-specific behavior.
- **Clipboard and drag/drop URL acquisition:** missing. Variety can monitor the
  clipboard with a host whitelist and save manually supplied image URLs.
- **Download retention and disk quota:** missing as a user-facing policy.
  Variety can cap and purge its download folder independently of its prepared
  wallpaper cache.
- **Content filtering:** mostly missing. Variety supports minimum dimensions,
  landscape/color constraints, filename regex, EXIF rating, and source-side
  safety controls. Phase 3 implements only minimum dimensions and aspect
  preference.

### Presentation gaps

- **Dynamic quote system:** only a small subset is built. Phase 2 renders one
  user-entered quote. Variety has quote sources, authors/tags, favorites,
  independent quote-change timing, font/color/shadow/background/width/position,
  and maximum-length controls.
- **Clock overlay:** missing. Variety can render a configurable digital clock
  and date and refresh it independently of wallpaper rotation.
- **Display modes and smart fit:** missing or delegated. Variety exposes fit,
  zoom, scale, span, blurred-padding, and image-dependent smart-fit modes.
- **Ratings:** missing. Variety reads/writes image ratings and can filter by a
  minimum EXIF rating.
- **Slideshow integration:** missing. Variety can launch a separate pan-and-zoom
  slideshow using favorites and/or downloads and select its monitor.

### Multi-monitor status

Independent per-output wallpapers are missing from Singularity. Current
`WallpaperManager` owns one `background-picture-uri` and one display texture.
Variety itself should not be described as fully satisfying this requirement:
its current desktop adapters generally apply one prepared wallpaper across
outputs, its preferences label multi-monitor behavior experimental, and its
tracker still has an open request for different wallpapers and settings per
monitor. Variety supports multi-monitor desktop integration and slideshow
monitor selection, but true independent wallpaper selection per output remains
an open Variety gap too.

Implementing this in Singularity is an architectural change: wallpaper URI,
effect cache identity, attribution, rotation history, and selection policy need
an output identifier; the background component must bind a distinct texture per
`Gdk.Monitor`; and hotplug/output removal needs an explicit fallback policy.

## Recommended order

1. Rebuild and submit Phase 1 from current upstream so favorites/history have a
   real upstream base.
2. Give Phase 2 a real state contract, then submit the self-contained effects
   pipeline and its five focused tests.
3. Submit Phase 3 after Phase 1, keeping the already-upstream rotator groundwork
   out of the diff.
4. Add blacklist identity and D-Bus/CLI actions before broadening source count;
   both make provider results and shell controls substantially more manageable.
5. Treat independent multi-monitor wallpapers as a separate design project,
   not a small extension of the single-URI manager.
