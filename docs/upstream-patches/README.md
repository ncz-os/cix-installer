# Upstream patches pending submission

One workstream. Everything here is a fix we carry downstream that belongs
upstream, with the evidence needed to file it and the reason it has not been
filed yet. **Check this file before re-deriving anything** — the libdrm entry
below was independently rediscovered on 2026-08-15, eleven days after it was
first analysed here, because nobody looked (CLAUDE.md directive 17).

| # | patch | target | blocker | evidence |
|---|---|---|---|---|
| 1 | libdrm ACPI platform identity | gitlab.freedesktop.org/mesa/drm | needs fd.o account | proven on O6N |
| 2 | ffmpeg v4l2-m2m multi-planar | ffmpeg-devel | none — ready to send | proven on O6N |
| 3 | GTK4 xdg_surface stale buffer | gitlab.gnome.org/GNOME/gtk | needs GNOME account | logs published |
| 4 | CIX 00114 drops a UAPI field | github.com/cixtech/cix-linux-main | none — comment/issue | code read |
| 5 | gtk4-layer-shell#130 → close | github.com/wmww/gtk4-layer-shell | maintainer decision | already argued |

Accounts needed: **gitlab.freedesktop.org** (1) and **gitlab.gnome.org** (3).
Both are operator actions; 2, 4 and 5 can go today.

---

## 1. libdrm-xf86drm-acpi-platform-identity.patch

Fixes libdrm's `drmParseOFBusInfo()` MODALIAS fallback for ACPI-enumerated
platform DRM devices: an ACPI modalias ends with ':', so the parsed bus name
is empty and identical for every device, and `drmGetDevices2()` folds all
ACPI DRM devices into one. On Sky1 (3× linlondp + panthor) only one device
survived enumeration, which broke Mesa device selection, panvk GPU discovery,
and wlroots' DRM device lookup. Verified on O6N: stock enumerates 1 device
with an empty name; patched enumerates all, correctly paired, uniquely named
(sysfs device basename, e.g. "CIXH5010:00").

Submission target: https://gitlab.freedesktop.org/mesa/drm (merge request;
the anongit and GitHub mirrors are read-only). Author identity:
Jason Perlow <jperlow@gmail.com>. Needs a gitlab.freedesktop.org account to
fork + push — the patch applies with `git am` on current main (the touched
fallback path is unchanged since 2.4.134).

**2026-08-15 — this is now the single blocker between us and a working
mainline GPU stack.** With it applied on O6N:

    stock libdrm : OpenGL renderer = llvmpipe (software)
    patched      : OpenGL renderer = Mali-G720 MC10 (Panfrost)
                   Vulkan deviceName = Mali-G720 MC10, driverName = panvk

Nothing was wrong with panthor, Mesa or panvk. It also explains why armbian
users (amazingfate) never hit it: they boot Sky1 in **device tree** mode, so
`OF_FULLNAME` exists and libdrm never reaches the ACPI fallback.

Note the fix here is better than "trim the trailing colon": MODALIAS encodes the
ACPI *hardware ID*, shared by every instance of a device type, so siblings would
still collide. It uses the sysfs device basename, which is unique per instance.

## 2. ffmpeg-v4l2-multiplane.patch

`v4l2_buffer_swframe_to_buf()` decides plane layout from the V4L2 fourcc and
only recognises the explicitly multi-planar "M" variants, so on a multi-planar
driver reporting an ordinary fourcc it packs every component plane into plane 0
at a running offset. Two failures:

* **yuv420p SIGSEGVs.** `length` and `offset` are unsigned, so the third plane
  pushes offset past the mapping, `length - offset` wraps, and the memcpy runs
  off the end.
* **nv12 silently loses all chroma.** The UV write lands at exactly
  `offset == length`, copying zero bytes. The output is valid H.264 that decodes
  cleanly, which is why it looked like it worked — measured U=2 V=2 on the
  decoded frames against U=127 V=126 for the same source in software.

Driver reports (v4l2-ctl): YU12 = 3 planes 921600/230400/230400, NV12 = 2 planes
921600/460800. Fix writes each component plane into its own V4L2 plane when the
buffer has more than one, and refuses `offset > length` rather than wrapping.

Verified on O6N: h264 nv12 and yuv420p both 186337 bytes with U=127.5 V=126.3,
hevc 103688 bytes, no coredumps. Upstream master still unguarded as of
2026-08-14. Shipped downstream in ncz-ffmpeg (ncz-packaging cf13fd2).

Submission target: ffmpeg-devel mailing list (patch by email; no account
needed). **Ready to send.**

## 3. GTK4 — xdg_surface must not have a buffer at creation

GTK clears the wl_surface buffer on unmap (`gdk/wayland/gdksurface-wayland.c`,
4.22.4 and main) but not at role creation, so a frame queued before the hide
attaches a buffer *after* that clear and `xdg_surface_create_resources()` then
creates the role on a dirty surface.

Reproduces with the layer-shell library **entirely unlinked**, so it is not a
gtk4-layer-shell bug. It is also renderer-specific: clean under GTK 4.22's
default Vulkan renderer, fails under `GSK_RENDERER=ngl`. That is why it has gone
unreported — anyone on Mesa/Vulkan defaults never sees it.

Three full unfiltered WAYLAND_DEBUG=1 logs (with layer shell / XDG only /
library unlinked) are published at
https://gist.github.com/perlowja/0105821635b35b938496cc33f67d9eed

Fix: clear the buffer at role creation, not only at unmap. Zero existing GTK
issues match the error string. Submission target: gitlab.gnome.org/GNOME/gtk —
**needs a GNOME account**.

## 4. CIX 00114 drops a UAPI field

`cix-linux-main` patches-7.1/00114 removes `gpu_info.selected_coherency` in
favour of the internal `coherency_mode`. That field is ABI —
`drm_panthor_gpu_info::selected_coherency` is read by userspace (Mesa) — so
dropping it silently changes what every client sees. Our forward-port keeps it
in sync (cix-installer 097195e). Worth telling CIX before it propagates.

Submission target: github.com/cixtech/cix-linux-main issue or PR comment. No
account blocker.

## 5. gtk4-layer-shell #130 — should be closed, not merged

Our own PR. The evidence now says the defect is in GTK (see 3), and it
reproduces with the library removed. Merging a workaround into gtk4-layer-shell
would have that project carrying someone else's bug. We have already put this to
the maintainer; the decision is hers.
