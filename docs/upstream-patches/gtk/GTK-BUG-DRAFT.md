# DRAFT — GTK issue report (for human review before filing)

**Status: NOT READY TO FILE.** One reproduction run is still missing; see
"Outstanding" at the bottom. GNOME's CONTRIBUTING requires the reporter to
verify and write up the issue themselves, so this is prepared material, not a
submission.

**Where it goes:** https://gitlab.gnome.org/GNOME/gtk — NOT gtk4-layer-shell,
and NOT labwc. See "Why here" below.

---

## Title (proposed)

GL/GLES renderer: a frame queued before `hide()` re-attaches a buffer after
unmap, so the next `xdg_surface` fails with "must not have a buffer at creation"

## Summary

Cycling two GTK4 toplevels hidden/shown produces a fatal Wayland protocol
error on the GL/GLES renderer:

```
xdg_wm_base#40: error 3: xdg_surface must not have a buffer at creation
Gdk-Message: Error 71 (Protocol error) dispatching to Wayland display.
```

GTK keeps one `wl_surface` alive across hide/show and recreates only the role
object. `wl_surface` state is persistent, so a paint queued just before the
unmap can land *after* GTK's clean `attach(nil)`, leaving a live buffer
attached. The next `xdg_surface` is then created over a surface that already
has a buffer, which the protocol forbids.

The failing sequence, from `WAYLAND_DEBUG=1`:

```
-> xdg_toplevel#57.destroy()
-> wl_surface#53.attach(nil, 0, 0)          <- GTK's clean unmap
-> wl_surface#53.commit()
-> wl_surface#53.attach(wl_buffer#64, 0, 0) <- stray: the queued paint lands
-> wl_surface#53.commit()
-> xdg_wm_base#40.get_xdg_surface(new id ..., wl_surface#53)
-> wl_surface#53.commit()
wl_display#1.error(xdg_wm_base#40, 3, "xdg_surface must not have a buffer at creation")
```

Measured at roughly 0.7 ms after unmap. It is a race on `wl_buffer.release`,
so the number of cycles before it fires varies — 5 or 50, not a fixed count.

## Renderer dependence (the important part)

| renderer | result |
|---|---|
| Vulkan (GTK 4.22 default) | clean — 120 cycles per window |
| `GSK_RENDERER=ngl` | fails within four surfaces |
| `GSK_RENDERER=gl` | fails |

On the default renderer this never fires, which is very likely why it has
looked like a ghost. It is only visible where the GL/GLES path is actually in
use.

## Reproducer

`gtk-repro.c`, attached. Pure GTK4 — no layer shell, not linked against it
(`ldd | grep layer-shell` is empty).

```
cc -o gtk-repro gtk-repro.c $(pkg-config --cflags --libs gtk4)
GSK_RENDERER=ngl ./gtk-repro     # fails
./gtk-repro                      # default: clean
```

Two conditions are both required, and missing either makes it look clean:

1. **Two or more windows cycling.** With one window it never fails —
   720 surfaces clean across three runs. With two it fails every run.
2. **The hide must be dispatched after a paint is queued.** Hiding from
   inside the tick callback is clean; hiding from a `G_PRIORITY_HIGH` idle
   scheduled in that tick fails. The idle stands in for a real close
   animation, which is what queues the late frame in production.

## Why here, and not the two places it was reported first

This was originally filed against gtk4-layer-shell
(wmww/gtk4-layer-shell#130, closed unmerged). Three runs on one machine, same
binary except where noted, settled it:

| case | result |
|---|---|
| with layer shell | `zwlr_layer_surface_v1` error 2 |
| layer-shell calls removed, library still linked | `xdg_wm_base` error 3 |
| layer-shell library not linked at all | `xdg_wm_base` error 3 |

It fails identically with layer shell removed entirely, so it is not a
layer-shell bug. The maintainer's own criterion was that if it still crashes
without the library it is not his — and it does.

It is also not a compositor bug: refusing a buffer attached before the first
configure is what the protocol requires, so labwc raising the error is
correct behaviour, not a defect to work around.

The remaining candidates are GTK's GL/GLES renderer path and the graphics
driver. This report does not claim to have isolated which.

## Environment

- GTK 4.22.4+ds-1
- wayland-client 1.26.0
- labwc 0.9.5, wlroots 0.20.2
- aarch64, CIX Sky1 (Radxa Orion O6N), Mali G720, GLES
- Debian forky

## Prior art / links

- wmww/gtk4-layer-shell#130 — closed unmerged; contains the three-case logs
- `WAYLAND_DEBUG=1` logs: see the layer-shell issue above.
- singularityos-lab/singularity-desktop#241 — downstream report
- singularityos-lab/singularity-shell#15 — client-side workaround, MERGED
  (drops the `GdkSurface` after `hide()` so each open gets a fresh
  `wl_surface`)

## Outstanding before this can be filed

1. **A fresh reproduction on this hardware with a real GL/GLES path.**
   Attempted 2026-09-04 and NOT obtained: the board was booted on the Panthor
   entry, where GTK reports

       Not using Vulkan: VK_ERROR_INCOMPATIBLE_DRIVER
       Not using GL: renderer is llvmpipe

   and both runs completed 120 cycles cleanly. With no GL path active there
   is nothing to fail, so that run neither confirms nor refutes anything. The
   run must be repeated on the **Mali** boot entry, where GLES is genuinely
   in use, and the resulting log attached.

2. **Confirm against current GTK.** The original numbers are from 4.22.4; if
   a newer GTK is available, re-run before filing.

3. **Human write-up.** Per GNOME's CONTRIBUTING AI policy this must be
   verified and written by the reporter. Treat the text above as notes.
