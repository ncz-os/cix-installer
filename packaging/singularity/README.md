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

Two more patches carried on top of the layer-shell fix, both currently
unmerged upstream:

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
`ArtistPackManager` never touches apt, GSettings, or a URL itself. It shells
out to two distro-provided scripts resolved by name via `PATH`:
`ncz-wallpaper-pack-inventory` (unprivileged, lists) and
`ncz-wallpaper-pack-install` (root, via `pkexec`, installs). Both are
installed by `post-install/49-artist-pack-browser.sh` in this repo, and both
read which apt source(s) to trust from the `artist-pack-apt-sources`
GSettings key at RUNTIME — never from a literal in either the Vala UI or the
shell scripts. The key's actual value for this distro is set the same way
every other `dev.sinty.desktop` default is (accent color, dark mode,
wallpaper, pinned apps): a packaged `.gschema.override` written by
`post-install/20-desktop.sh`, kept in sync with the two sources
`post-install/24-apt-sources.sh` wires. A different build variant swaps the
override's value — nothing in either patch changes.

A distribution that never applies these two patches, or that applies them
but never ships the two backend scripts, simply never sees the Artist Pack
browser section: `ArtistPackManager.is_available()` checks for
`ncz-wallpaper-pack-inventory` on `PATH` and the whole group is skipped when
it's absent. The feature is additive, not a hard dependency of the shell.

**Verified without a full build** (no meson/vala toolchain in this
sandbox): `data/dev.sinty.desktop.gschema.xml` parses and
`glib-compile-schemas` accepts the new key; a `.gschema.override` setting it
compiles clean under `--strict`; the SAME override compiles clean (with the
unknown key silently ignored, matching `20-desktop.sh`'s own non-`--strict`
invocation) against the schema WITHOUT this patch, so shipping the
20-desktop.sh override ahead of this patch landing does not break the
existing accent/dark-mode/wallpaper/pinned-apps overrides it sits next to;
and both shell scripts embedded in `post-install/49-artist-pack-browser.sh`
were run byte-for-byte against faked `apt-cache`/`apt-get`/`dpkg-query`/
`gsettings`, exercising: a trusted-source package listed correctly,
an untrusted-source package excluded even though its name matches the
`ncz-wallpapers-*` convention, an already-installed pack reported
`"installed":true`, and the install helper refusing a shell-metacharacter
package name, a non-Artist-Pack name, and an untrusted-source package name.
The Vala itself is unverified by a compiler — this sandbox cannot build the
full GTK4/libsingularity toolchain — so review it as such before merging.

**Known caveat, not verified either way on real hardware:**
`ncz-wallpaper-pack-install` re-reads `artist-pack-apt-sources` via
`gsettings get` while running AS ROOT under `pkexec`, to re-derive the
trusted source list rather than trust its own argv. `gsettings`/dconf
resolves values per-EUID, and root invoked through `pkexec` does not
inherit the invoking user's dconf session — whether that read then falls
back correctly to the schema's COMPILED default (the `.gschema.override`
`20-desktop.sh` bakes in at install time, which is what this value is in
the common case where no one has ever run `gsettings set` on this key) or
instead sees an empty/default-empty value depends on dconf backend
behaviour under a session-less root invocation that this sandbox has no way
to exercise. If it resolves incorrectly, the failure mode is closed, not
open: an empty read makes the helper refuse every install with "no
artist-pack-apt-sources are configured" (see the script's own error path)
rather than silently trusting an unintended source. Confirm this on real
hardware (`pkexec ncz-wallpaper-pack-install ncz-wallpapers-<pack>` on an
installed system with the override in place) before relying on the install
path; if it does fail closed, the fix is to have the Vala caller pass the
already-resolved source list as an argv (still re-validated, not trusted
blindly) rather than have the privileged helper re-derive it from a
GSettings read that may not resolve the same way root and the desktop
session do.

## Rebuilding with all three patches

    SINGULARITY_REF=<pinned-ref> build/build-singularity.sh

until all three land upstream, apply everything in `patches/` (numeric
order) to the cloned `singularity-desktop` tree — schema patch at the repo
root, shell patch inside `subprojects/singularity-shell` — before building.
