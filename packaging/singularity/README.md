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
