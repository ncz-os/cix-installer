# packaging/singularity — reproducing the Singularity payload we ship

`assets/singularity/singularity-opt.tgz` is the `/opt/singularity` tree that
`ncz-singularity-desktop` wraps and every NCZ-OS desktop boots. As of
2026-08-10 it could **not** be rebuilt from this repo, and that cost us:

* the shipped payload carried a layer-shell crash fix that existed ONLY as a
  hand-built tree at `/opt/singularity.FIXED24` on the O6N test board;
* `build/build-singularity.sh` clones `singularityos-lab/singularity-desktop`
  at **floating `master`**, so it would neither reproduce that payload nor even
  build the same upstream twice;
* the forky tree was still staging the UNPATCHED payload (`singularity-desktop`
  md5 `e23ebc08`), so an ISO built from it would have shipped the exact crash
  the fix exists to prevent.

This directory tracks the delta so the payload stops being a binary somebody
has to remember to copy off a board.

## The fix being carried

`patches/0001-shell-drop-gdksurface-on-all-close-paths.patch` is
singularityos-lab/singularity-shell **PR #15**, taken from the PR itself:

    base   main @ 13014ee46fc5a051b9ceec446e76db7af6c0b52a
    head   f45364123457543c9a6c571c2232a25552500d79 (perlowja/singularity-shell)
    7 files, 118 insertions

**What it does.** GTK keeps ONE `wl_surface` across hide/show and tears down
only the role object. gtk4-layer-shell then builds a new
`zwlr_layer_surface_v1` over that same surface. `wl_surface` state is
persistent, so a frame queued by a closing animation landing ~0.7 ms after
unmap re-attaches a live buffer, and role creation inherits it — which the
protocol forbids outright ("Creating a layer surface from a wl_surface which
has a buffer attached or committed is a client error"). The patch calls
`unrealize()` after `hide()` on all 24 close paths so the GdkSurface is dropped
and the next open gets a fresh `wl_surface`.

**The cast is required.** `((Gtk.Widget) x).unrealize()` — a bare
`unrealize()` binds to `gtk_native_unrealize`, not the widget one. A regex that
matched only bare `hide()` missed `((Gtk.Widget) this).hide()` and silently
patched 18 of 24 paths while claiming all of them.

## THIS IS THE SECOND HALF OF THE FIX

The decisive half is the **library**: see `packaging/gtk4-layer-shell/`. A metal
A/B on O6N settled it — SAME unpatched shell, stock library = instant crash;
patched library = no crash. Ship both; do not assume this patch alone is
sufficient.

## Rebuilding

    SINGULARITY_REF=<pinned-ref> build/build-singularity.sh

`build/build-singularity.sh` still defaults `SINGULARITY_REF=master`. Pin it,
and apply `patches/` to the shell before building, until PR #15 lands upstream —
after which the pin alone is enough.

## Verifying a payload actually has the fix

Do not trust a filename or a build log; check the binary:

    ./verify-payload.sh assets/singularity/singularity-opt.tgz

It greps the dynamic symbols for `gtk_widget_unrealize`, which is present only
in a patched build. Known values:

    fa54b57e…  singularity-desktop  PATCHED   (1 import)  — /opt/singularity.FIXED24
    e23ebc08…  singularity-desktop  UNPATCHED (0 imports) — what forky was staging

md5 alone does NOT discriminate: two independent builds of the same source
differ, so compare the symbol, not the hash.

## Artist Pack browser (2026-09-12)

**RETIRED 2026-09-29:** the two patches below were deleted from
`patches/` (stale, unreferenced; neither applies to current upstream). Kept
as history. They were carried on top of the layer-shell fix:

* `patches/0001-schema-artist-pack-apt-sources.patch` — singularity-desktop,
  adds the `artist-pack-apt-sources` (`as`) key to
  `data/dev.sinty.desktop.gschema.xml`.
* `patches/0002-shell-artist-pack-browser.patch` — singularity-shell, adds
  an "Artist Packs" group to `DesktopPage` (see
  `docs/WALLPAPER-PACKS.md`, remaining-work item 1/2) and the backing
  `ArtistPackManager` class (`src/core/artist_pack_manager.vala`).

**What it does.** Lists curated wallpaper packs (`ncz-wallpapers-*` debs,
the naming convention `build/build-wallpaper-contrib-deb.sh` uses) that are
available or already installed, with an Install button per pack.

**The apt source is config, not code — this is the point of the feature.**
`ArtistPackManager` never touches apt or a URL itself. It shells out to two
distro-provided scripts resolved by name via `PATH`:
`ncz-wallpaper-pack-inventory` (unprivileged, lists) and
`ncz-wallpaper-pack-install` (root, via `pkexec`, installs). Both are
installed by `post-install/49-artist-pack-browser.sh` in this repo. The
inventory script reads which apt source(s) to trust for BROWSING from the
`artist-pack-apt-sources` GSettings key at RUNTIME — never from a literal in
the Vala UI or the shell scripts. The key's actual value for this distro is
set the same way every other `dev.sinty.desktop` default is (accent color,
dark mode, wallpaper, pinned apps): a packaged `.gschema.override` written by
`post-install/20-desktop.sh`. A different build variant swaps the override's
value — nothing in either patch changes.

**The privileged install step does NOT use GSettings at all — see "Trust
boundary fix" below.** It re-derives trust directly from the apt sources
actually configured on the system
(`/etc/apt/sources.list.d/ncz-os-apt-*.list`, the same plain files
`post-install/24-apt-sources.sh` writes), plus a fresh, live `apt-cache
madison` check. This is a deliberate, reviewed change from the first
prototype of this feature (see below) — not an oversight.

A distribution that never applies these two patches, or that applies them
but never ships the two backend scripts, simply never sees the Artist Pack
browser section: `ArtistPackManager.is_available()` checks for
`ncz-wallpaper-pack-inventory` on `PATH` and the whole group is skipped when
it's absent. The feature is additive, not a hard dependency of the shell.

**Verified with a real toolchain, on ULTRA (arm64 Fedora Asahi Remix), not
just brace-balance checking:**

* `data/dev.sinty.desktop.gschema.xml` (patched) parses and
  `glib-compile-schemas --strict` accepts the new key; a `.gschema.override`
  setting it compiles clean under `--strict`; the SAME override against the
  UNPATCHED schema compiles clean under a plain (non-`--strict`) invocation
  with the unknown key silently ignored (matching `20-desktop.sh`'s own
  non-`--strict` call) and correctly FAILS under `--strict` — so shipping
  the `20-desktop.sh` override ahead of this patch landing does not break
  the existing accent/dark-mode/wallpaper/pinned-apps overrides it sits
  next to. All three outcomes reproduced exactly as claimed, with real
  `glib-compile-schemas`.
* **`patches/0002-shell-artist-pack-browser.patch` was rebased onto current
  singularity-shell `master` and built with a REAL `meson setup` +
  `meson compile` on ULTRA** (subprojects `libsingularity` +
  `singularity-loginui`, GTK4/libadwaita/Vala toolchain, not simulated).
  First attempt failed with a real compiler error the original prototype's
  brace/paren-balance check could not have caught:
  `` ../src/core/artist_pack_manager.vala:12.35-12.40: error: `Object' is an
  ambiguous reference between `GLib.Object' and `Json.Object' `` — the file
  does `using Json;` alongside `using GLib;`, so bare `Object` as a base
  class is ambiguous. Fixed by qualifying both classes as `GLib.Object`
  explicitly. After that fix the patched `singularity-shell` builds clean
  (`ninja -C build`, zero errors, only pre-existing warnings unrelated to
  this feature) and produces a working `singularity-desktop` binary.
* Both shell scripts embedded in `post-install/49-artist-pack-browser.sh`
  were run against faked `apt-cache`/`apt-get`/`dpkg-query`/`gsettings`,
  exercising: a trusted-source package listed correctly, an
  untrusted-source package excluded despite matching the
  `ncz-wallpapers-*` name convention, empty-sources returning `[]` rather
  than hanging/crashing, and the install helper refusing (a) a
  shell-metacharacter package name, (b) a non-Artist-Pack name, (c) a
  source URI absent from `/etc/apt/sources.list.d/ncz-os-apt-*.list`
  entirely, (d) a configured-but-mismatched source where the package's
  LIVE apt candidate actually resolves elsewhere, while (e) a genuinely
  trusted, configured, live-matching install and (f) a re-install of an
  already-installed pack both correctly reach `apt-get`.
* **The empty-inventory case — the single most important behavior, since
  it is the actual current production state — was verified against the
  REAL, LIVE apt repos, not a fixture.** Fetched
  `dists/any/main/binary-arm64/Packages` from both
  `packages.buildkite.com/ncz-os/ncz/any/` (primary) and the Cloudflare R2
  backup directly: 76 real packages exist between them, zero are named
  `ncz-wallpapers-*`. Then ran the actual (unmodified)
  `ncz-wallpaper-pack-inventory` script against a real, isolated
  `apt-get update` of both live indexes (arm64) — it printed exactly `[]`,
  no crash, no hang, no placeholder entry. The Vala side already renders a
  `packs.size == 0` result as a plain "No Artist Packs available" row (see
  `populate_artist_packs_async()` in the shell patch), so the end-to-end
  empty state is what a real install would show today.

### Trust boundary fix: install helper no longer reads GSettings as root

The FIRST prototype of this feature had `ncz-wallpaper-pack-install`
re-read the `artist-pack-apt-sources` GSettings key itself, via
`gsettings get`, while running AS ROOT under `pkexec` — flagged at the time
as an unverified caveat. Investigated properly rather than shipped as-is:

GSettings/dconf resolves per-EUID. A `pkexec`-elevated root process does
not share the desktop user's dconf session, so `gsettings get` as root
consults root's own (essentially always-empty) dconf "user" profile, not
the desktop user's, and falls through to the schema's build-time-compiled
default at a fixed system path
(`/opt/singularity/share/glib-2.0/schemas`). In THIS specific case that
default happens to be reachable identically for both root and the desktop
user, because nothing exposes a UI control to `gsettings set` this key at
runtime — so the two would likely read the same value today. But relying
on that is the wrong invariant for a privileged trust check: the moment
anyone ever DOES run `gsettings set` on this key by hand (e.g. to narrow
the trusted source list on a running system), root's read would silently
keep validating against the wider, stale COMPILED default instead of the
narrower live value — a fail-**open** direction, not the fail-closed one
the original caveat assumed, and exactly the kind of drift a privileged
re-check exists to prevent.

**Fix:** the privileged path no longer touches GSettings at all.
`ncz-wallpaper-pack-install` now takes the package name AND the source URI
the inventory step already resolved
(`ArtistPackManager.install_async(package, source)` →
`pkexec ncz-wallpaper-pack-install <package> <source-uri>`), and
independently re-validates that pairing against two session-independent
facts: (1) the source URI must appear in one of the plain, root-owned
`/etc/apt/sources.list.d/ncz-os-apt-*.list` files `24-apt-sources.sh`
already writes — filesystem truth, identical for every UID, no dconf
involved; and (2) the package's LIVE `apt-cache madison` candidate,
queried fresh at install time, must actually resolve to that same URI —
so the caller's claim is still never trusted blindly. This is also a more
literal reading of the operator's "the artist pack source has to be set at
a config level from apt" than a hand-synced GSettings shadow-copy of the
same two URIs: it validates directly against apt's own configured sources
rather than a parallel list that has to be kept in sync by hand. The
unprivileged inventory script is unchanged and still reads GSettings
normally — it runs in the desktop user's own session, where dconf behaves
exactly as expected, so there was never a reason to move it.

### polkit `.policy` + `pkexec`, not a D-Bus system daemon

This codebase's actual pattern for privileged system changes elsewhere is
a D-Bus call to a system daemon owning its own polkit action (e.g.
`org.freedesktop.hostname1`-style). No existing `pkexec`+apt or
PackageKit precedent was found anywhere in `singularity-shell` or its
sibling repos, and that remains true after this pass (confirmed by
grepping this repo's own `post-install/*.sh` for prior polkit usage: only
mentions of udisks' own polkit action, nothing this repo added itself).

Kept the prototype's `pkexec` + standalone-`.policy` approach rather than
reworking it into a D-Bus daemon. Reasoning: the action is narrowly scoped
(`org.freedesktop.policykit.exec.path` pins it to exactly one
single-purpose script, not a general "run anything as root" grant), it is
real polkit either way (same authentication UI, same admin-auth
semantics), and standing up a whole system daemon for one install action
would be materially more code and attack surface for a curated
wallpaper-pack installer than the risk actually warrants. If a THIRD
privileged action is ever added to this desktop, that would be the point
to reconsider centralizing on a daemon; for a single action, `pkexec` +
a tightly scoped `.policy` is proportionate.

## Rebuilding with the Artist Pack patches

    SINGULARITY_REF=<pinned-ref> build/build-singularity.sh

Open upstream PRs, both built and verified as described above:

* `singularityos-lab/singularity-desktop` PR #253 (schema patch — #252 was
  closed and reopened as #253 after discovering it had been built against a
  stale GitLab-mirrored `master` that had diverged from the real GitHub
  `master` for this repo; GitHub is NOT a passive mirror of GitLab for
  `singularity-desktop` the way it is for `cix-installer` — verify against
  the actual GitHub base before opening a PR here in future)
* `singularityos-lab/singularity-shell` PR #28 (shell patch)

Until both land, apply `patches/` in numeric order to the cloned
`singularity-desktop` tree — the schema patch at the repo root, the shell
patch inside `subprojects/singularity-shell` — before building. (PR #15,
the layer-shell fix documented above, has already landed upstream; its
patch file is retired from this directory.)
