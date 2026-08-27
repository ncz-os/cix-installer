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
| 6 | panthor: Sky1 ACPI shader-stack clock | dri-devel / panthor | none — ready to send | proven on O6N |
| 7 | panthor: block power-on readiness poll | dri-devel / panthor | none — ready to send | code read |
| 8 | amvx: coded size excludes visible rect | CIX / cixtech | needs investigation | Chromium logs |

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


## 6. panthor — enable the shader-stack clock under ACPI (Sky1)

**The most valuable thing in this list.** Under ACPI there is no "stacks" clkdev
entry, so `devm_clk_get_optional(dev, "stacks")` returns NULL, the later
`clk_prepare_enable()` is a silent no-op, and the shader-stack clock is never
enabled. Any `SHADER_PWRON` — host- or firmware-initiated — then wedges forever
in `SHADER_PWRTRANS`.

Measured on O6N before the fix:

    SHADER_READY=0x0  SHADER_PWRTRANS=0x550555   (all ten cores stuck >5s)
    MCU_STATUS=1, GPU_FAULT_STATUS=0, TILER_READY=0x1, L2_READY=0x1
    clk_summary: gpu_core (con_id gpu_clk_stacks) enable_count=0

L2 and TILER live on `gpu_top`, which is why probe, firmware boot, MMU traffic
and `vulkaninfo` all succeed while the first real shader job kills the GPU. A
host-side `SHADER_PWRON` issued before MCU boot also sticks, which rules out
firmware, CSG, GEM and scheduler explanations.

`mali_kbase` gets this right by con_id: `clk_names[] = { "gpu_clk_core",
"gpu_clk_stacks" }` (mali_kbase_core_linux.c).

**Upstream status — VERIFIED AGAINST next-20260814, 15,435 commits since
v7.2-rc7:** there is NO competing fix and no CIX ACPI support at all.
`git grep -i acpi drivers/gpu/drm/panthor/` returns **0 hits**; `git log
-S"SHADER_PWRON"` and `-S"PWRTRANS"` are both empty; `panthor_drv.c` matches only
`mediatek,mt8196-mali`, `rockchip,rk3588-mali`, `arm,mali-valhall-csf` — no
`acpi_device_id`. No `CIXH*` HID exists anywhere in the upstream tree.

So this cannot be dropped on rebase and has no upstream owner. Submitting it is
the single highest-leverage upstream action available to us. Note the likely
review question: upstream will want the clock named in a binding rather than
gated on an ACPI HID, so expect to argue the ACPI-vs-DT enumeration gap.

Local commit: `38e5efd panthor(sky1): enable the shader-stack clock under ACPI`
(also populates `clks.backup[]` with `gpu_clk_200M`/`gpu_clk_400M`, which the
struct declared but never assigned).

## 7. panthor — block power-on readiness poll is wrong (and truncates)

    u32 val;
    ... (mask & val) == val

is satisfied when `val == 0`, i.e. it reports power-on SUCCESS while the block is
still transitioning. Readiness means all requested bits ARE set: `(mask & val)
== mask`. Both sites also feed `gpu_read64_relaxed_poll_timeout()`, so `val`
must be `u64` — as written, any ready bit above bit 31 is invisible.

Not the primary Sky1 killer (the firmware path does not use this helper), but a
genuine defect that masked the stacks-clock failure from the host power-on path
and makes L2 power-on a race generally. Correct-by-construction; no behavioural
change has been demonstrated on its own.

Local commit: `669edf5 panthor: fix block power-on readiness poll (u64 + wrong condition)`

## 8. amvx — driver reports a coded size that excludes the visible rect

From Chromium's V4L2 stateful decoder on real playback:

    InitializeCAPTUREQueue(): Adjusted coded size 854x480 does not contain
      visible rect 0,8 854x480; retrying with 864x496.
    Driver cannot back visible rect 0,8 854x480 within 854x480; dropping its
      origin and using 0,0 854x480.

The mvx driver returns a coded size that does not cover the visible rectangle at
y-offset 8. Chromium works around it and playback is correct (4K60 AV1 verified
smooth), so this is a conformance/robustness issue rather than a functional one.
Needs a minimal v4l2-ctl reproduction before filing.

---

# Pre-rebase checklist — DKMS panthor (NOT upstream work)

Verified against `next-20260814`. **Do not pre-apply these against v7.2-rc7 —
none of them compile there.** Apply at the moment of rebase.

| what | where | why |
|---|---|---|
| add `.num_rqs = 1` | `panthor_mmu.c` `panthor_vm_create()`, `panthor_sched.c` `group_create_queue()` | drm/sched run-queue rework was REVERTED tree-wide on 2026-08-11; `num_rqs` is back. Ours is a designated initializer, so a missing field **compiles clean and defaults to 0** → `ZERO_SIZE_PTR` → init "succeeds" → dies on first entity. Silent GPU death. |
| `is_cow_mapping(vma->vm_flags)` → `vma_is_cow_mapping(vma)` | `panthor_gem.c` | `1050f28d3e6a mm: provide vma_[flags_]is_cow_mapping() and remove is_cow_mapping()` — hard compile break |
| drop `DRIVER_GEM_GPUVA` | `panthor_drv.c` | `21fcb222f0d1 drm: Remove DRIVER_GEM_GPUVA feature flag` — hard compile break |
| `of_drm_get_panel_orientation()` → `drm_of_get_panel_orientation()` | kernel patches `0008`, `0058` | `b5a8b1f2a973` — `0058` anchors a hunk on the old `EXPORT_SYMBOL`, so it fails to APPLY, not just to build |

**Trap:** the `num_rqs` API was removed *and* reverted inside the same range, so a
commit-title scan shows both directions and reads as a no-op. Only the net header
diff settles it.

# Downstream patches to DROP on rebase

- **`0138-clk-cix-sky1-bind-acpi-bus` + `0147-clk-cix-sky1-restore-platform-supplier`** —
  an add/remove pair that nets to zero, and `0138` is built on `struct
  acpi_driver`, which `541b293ab186 ACPI: bus: Eliminate struct acpi_driver`
  deletes. (`acpi_driver_data()` still exists, so patch `0043` is unaffected.)
- **Consider cherry-picking `3314c90a2eda pmdomain: arm: Fix -EINVAL from
  scmi_pd_set_perf_state() on state 0`** (`Cc: stable`) — pairs with our
  `0187-drm-panthor-route-scmi-dvfs-through-perf-opp` and may retire part of it.
- **Check whether our six in-tree panthor patches are dead code.** The lean O6N
  defconfig has `# CONFIG_DRM_PANTHOR is not set` — panthor ships DKMS-only, so
  `0084`, `0086`, `0092`, `0094`, `0187`, `0033` may be patching source the
  shipped kernel never compiles.
