# Patches that have LANDED upstream — kept for provenance, not applied

A patch here is no longer carried downstream. It is retained so the trail from
"we shipped a fix" to "upstream owns it" survives, and so a future rebase does
not resurrect it.

## 0001-shell-drop-gdksurface-on-all-close-paths.patch

singularityos-lab/singularity-shell **PR #15 — MERGED** (merge commit
`419dfc85c228`, an ancestor of `main`).

Upstream refactored the change while landing it: instead of an inline
`hide()`+`unrealize()` pair repeated on every close path, `main` now carries
`src/core/layer_window.vala` exposing

    public void close_layer_window (Gtk.Window window) {
        ((Gtk.Widget) window).hide ();
        ((Gtk.Widget) window).unrealize ();
    }

and calls it from the close paths — verified on `main` at 14 call sites
(dock.vala 7, sidebar.vala 5, overview.vala 2), with `meson.build` listing the
new file. Our comment explaining why the `(Gtk.Widget)` cast is required
survived into upstream's version verbatim.

Because the change is upstream, applying this patch now FAILS
(`src/core/main.vala:798: patch does not apply`) and that failure correctly
aborts the build rather than producing a payload with the fix applied twice or
not at all.

**Do not re-add this to `patches/`.** Pin the ref instead — which is exactly
what `packaging/singularity/README.md` said would become sufficient once
PR #15 landed.

## STILL CARRIED DOWNSTREAM

`packaging/gtk4-layer-shell/patches/0001-layer-surface-clear-stale-buffer-before-role-creation.patch`
is the *decisive* half of the layer-shell crash fix and is NOT upstream. A metal
A/B on O6N settled it: same shell + stock library = instant crash; patched
library = no crash. Retiring the shell patch does not retire that one.
