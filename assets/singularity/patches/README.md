# Singularity Desktop downstream patches

**STALE-DOC WARNING (2026-09-18):** the `labwc` and `singularity-shell`
sections below describe patches as present/VERIFIED, but commit `59b48a7`
("retire the obsolete singularity/labwc/libsingularity patch queue")
already deleted all of them from this tree -- those PRs merged upstream.
This branch (`wip/mkosi-pipeline-2026-09-14`) inherited that retirement
but not the doc fix that went with it on `master`. Left as-is rather than
rewritten wholesale here, out of scope for the singularity-desktop patch
this commit adds -- reconcile fully against `master` in a follow-up.

Patches carried against `singularityos-lab/singularity-desktop` (and its
bundled `labwc` subproject) for NCZ-OS on CIX Sky1, applied automatically by
`build/build-singularity.sh` from `assets/singularity/patches/<subproject>/`
after the upstream tree is cloned and every submodule is re-pinned to its own
tracked branch tip (see the comment in that script for why the re-pin step
exists). A patch that fails to apply is a hard build failure, not a warning —
see the script for why. **The one exception:** a patch directory named after
the root `singularity-desktop` repo itself (not a subproject/submodule)
applies at the top level instead of `subprojects/<name>/` — see the
`singularity-desktop` section below, the first patch to need this.

Every patch here corresponds to an **open, unmerged upstream PR**. Once a PR
merges, delete its patch(es) from here in the same commit that bumps past it
— an applied-but-redundant patch is relatively harmless (the idempotency
check just reports "already present"), but a stale README entry claiming a
patch is still needed when it is not is actively misleading.

## singularity-desktop — `assets/singularity/patches/singularity-desktop/`

**Upstream PR:** [singularityos-lab/singularity-desktop#251](https://github.com/singularityos-lab/singularity-desktop/pull/251)
(branch `master`), from `perlowja/singularity-desktop` branch
`fix/wallpaper-attribution-gschema-keys`.

**Fixes:** `singularity-shell` master reads `show-wallpaper-attribution`
unguarded in `desktop_page.vala`/`background.vala`, and
`background-attribution-title`/`-author` through `SettingsSafety`.
`g_settings_get_boolean()`/`g_settings_get_string()` on a key the schema
does not declare **aborts the process** (GLib fail-fast on a schema
mismatch) — confirmed live on O6N tonight as a `singularity-desktop`
SIGABRT crash loop (`g_settings_get_boolean` -> `singularity_background_construct`
-> abort), 9 crashes in 35 seconds, via `coredumpctl`.

- `0001-fix-schema-add-the-background-attribution-keys.patch` — adds the
  three missing keys to `data/dev.sinty.desktop.gschema.xml`.

**Status:** VERIFIED — a real container build (`build/build-singularity.sh`)
applies the patch cleanly, and the staged payload's
`opt/singularity/share/glib-2.0/schemas/dev.sinty.desktop.gschema.xml`
genuinely declares all three keys (extracted and read directly from the
build output, not inferred). `glib-compile-schemas` + `gsettings get`
readback on the compiled schema confirms `show-wallpaper-attribution`
returns `true` (the declared default). Separately, an earlier live stopgap
deploy of this same fix to O6N (built directly from the PR branch, installed
as `ncz-singularity-desktop_20260918+stopgap-pr251`) confirmed the crash
itself no longer reproduces on real hardware.

## labwc — `assets/singularity/patches/labwc/`

**Upstream PR:** [singularityos-lab/labwc#5](https://github.com/singularityos-lab/labwc/pull/5)
(branch `singularity`), from `perlowja/labwc` branch `fix/dp-hdmi-replug-black-screen`.

**Fixes:** HDMI/DP replug leaves the screen black until the compositor is
restarted (`systemctl restart greetd` was the standing workaround).

- `0001-...-force-frame...patch` — `handle_output_request_state()` has a fast
  path for the case where the backend reports that only the mode changed: it
  stages the new mode into `output->pending` and schedules a frame. A DP/HDMI
  replug arrives through exactly that path while the output is still disabled
  from the unplug, and staging a mode on a disabled output makes wlroots
  reject the entire atomic state in `output_basic_test()` ("Tried to set mode
  on a disabled output"), so the output is never re-enabled. The kernel was
  ruled out (kretprobes on the three `linlondp_*` KMS entry points all
  returned 0, and `output_basic_test()` returns before any DRM ioctl). A new
  `output->power_off` flag records deliberate screen-blanking intent (set in
  `handle_output_power_manager_set_mode()`) so this only re-enables when the
  output was not deliberately powered off, is currently disabled, and the
  mode-only state does not already test clean — otherwise both the `ENABLED`
  and `MODE` bits are dropped rather than staging an invalid combination.
- `0002-...-commit-the-staged-re-enable...patch` — review finding: the first
  patch staged the re-enable and scheduled a frame, but never actually
  committed the staged state. This commits it directly instead.

**Status:** VERIFIED on real hardware — confirmed on both O6N (one output)
and MS-R1/`.66` (four outputs): display returns on replug with no
`systemctl restart greetd`, and screen blanking still blanks and stays
blanked.

## singularity-shell — `assets/singularity/patches/singularity-shell/`

**Upstream PRs:**
[singularityos-lab/singularity-shell#25](https://github.com/singularityos-lab/singularity-shell/pull/25)
(wallpaper source selector, grid scoping, rotation controls) and
[#26](https://github.com/singularityos-lab/singularity-shell/pull/26)
(OCS online browser, stacked on #25), from `perlowja/singularity-shell`
branches `wallpaper-source-selector-clean` and `ocs-browser-clean`.

Seventeen patches, in the order they must apply (`0001`-`0017`):

- `0001`-`0004` (+ `0005` chore, `0006` fix): the source-selector/rotation
  feature (PR #25) — `WallpaperCollections` (parses the `.collection`
  registry, see `docs/wallpaper-packs.md` on the website repo), Wallpaper-
  Rotation-state file helpers shared with `ncz-wallpaper-rotate`, the
  `WallpaperGallery` scanner (scopes the grid to the selected source,
  enforces source boundaries so a recent image or a nested pack from a
  different source cannot leak into the wrong gallery), and a bundle of
  fixes from an adversarial review (atomic state-file writes, tolerant
  `rotate-enabled` parsing, KeyFile field trimming, symlinked-root
  canonicalization, persisting a fallback selection).
- `0007`-`0017`: the OCS browser (PR #26) — `WallpaperOcs` (a pure JSON
  adapter over the already-shipped `ncz-wallpaper-ocs` CLI,
  `docs/OCS-WALLPAPER-BACKEND.md`), `WallpaperOcsImports`, the
  `WallpaperOcsBrowser` GTK4 window, and a fix-loop (qualify a namespace
  collision, reap timed-out import worker processes, correct a process-group
  cast, initialize a helper pid, release a closed browser's reference,
  append dropdown strings without a NULL-termination bug).

**Status:** VERIFIED — a real container build (`build/build-singularity.sh`,
no `SINGULARITY_SOURCE_DIR` override, i.e. the same path a real ISO/CI build
takes) applies all seventeen patches cleanly and produces a
`singularity-desktop` binary confirmed (via `strings`/`grep` on the staged
binary, not inferred from a clean build exit) to carry the new symbols and
UI strings from both PRs.

## Artist Packs

Contributed wallpaper art (currently Brandon Perlow and Alex Jay Brady,
`build/build-wallpaper-contrib-deb.sh`) ships as separate `.deb`s staged at
`assets/wallpaper-debs/*.deb` (gitignored, like `assets/cix-debs` — rebuild
with that script rather than committing the blob), installed by
`post-install/45-wallpaper-rotator.sh` alongside the built-in `ncz` and
`bing` collections. See `docs/wallpaper-packs.md` (website repo) for the
`.collection` format these packs, and any future third-party one, use.
