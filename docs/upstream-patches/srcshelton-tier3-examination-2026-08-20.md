# Stuart Shelton CIX Sky1 Tier 3 patch examination

Date: 2026-08-20

Scope: read-only examination of the Tier 3 Stuart Shelton patches named by the
operator. I fetched and read every candidate patch body from
`srcshelton/gentoo-ebuilds`, read the prior Tier 1, Tier 2 and comparison
reports, inspected our 7.2 patch series (now 210 patches after the Tier 1+Tier 2
imports), and dry-applied each candidate against the 7.2 base tree and against
our partially-applied working tree.

Applicability method: I used two disposable trees:

- Pristine Linux 7.2 tarball in `/tmp/linux-7.2` (since consumed; recreated as
  needed).
- Our partial tree at
  `~/work/cix-installer/staging/port-2026-08-20/base/linux-7.2-rc7` — this is
  the tree where the 210 patches are designed to land.

I also grep-searched the 7.2-rc7 base for every site that touches
`drm_crtc_state.plane_mask` (35 files) to characterize the blast radius of
`70150`. I grep-searched our 210 patches for any file overlap with each
candidate. I read enough of the large patch bodies (72000, 72010, 80030, 80032)
to characterize the code quality and audit state, not just trust the titles. No
builds were run.

## Summary recommendation

| Patch / group | Mechanical apply | Recommendation |
|---|---:|---|
| `70150-drm-support-up-to-64-planes.patch` | clean | **Skip** (and document why). Core DRM change for a CIX cluster case our hardware doesn't exercise, with two silent-truncation bugs the patch doesn't fix. |
| `72000-media-cix-import-armcb-isp-driver.patch` | clean against the new files; Kbuild/Kconfig hunks reject against our tree (our mvx already occupies those slots) | **Skip** as a driver import. We have no CSI sensor on any shipped board, our firmware lacks the ACPI HIDs the driver binds (`CIXH3026` / `armcb,sky1-isp`), and the import is dead weight. |
| `72010-media-cix-harden-armcb-isp-platform-subdevices.patch` | clean **only if 72000 is applied first**, against a tree where the armcb-isp files exist | **Skip** with 72000. 72010's hardening is real and well-targeted (NULL/range guards on every CSI/DPHY/CSIDMA/CSIRCSU reg op, plus deletion of the `armcb_isp_execstart.c` userspace-process-knitting helper), so the *idea* is good — but it's hardening for a driver we shouldn't be carrying. |
| `72030-media-cix-port-isp-to-linux-7.2.patch` | **does NOT apply**, neither against pristine 7.2 nor against our tree+72000, nor against our tree+72000+72010 | **Skip** with the rest of the ISP group. The patch context references `<linux/soc/cix/cix_ddr_lp.h>` which is not in either tree; the strncpy→strscpy fix is valid but needs the include-hunk regenerated against the actual file. Stale patch. |
| `80030-net-realtek-import-r8126-driver.patch` | clean against 7.2 base; clean against our tree | **Skip.** Our fleet relies on mainline `r8169`, which in Linux 7.2 already supports PCI IDs `0x8125`, `0x8126`, `0x8127`. Carrying an 890KB vendor blob as a second driver behind `R8169 = n` mutex is dead weight with measurable trust surface. |
| `80031-net-realtek-r8126-prefer-performance-core-irqs.patch` | clean (depends on 80030) | **Skip** with 80030. |
| `80032-net-realtek-r8126-remove-vendor-engineering-interfaces.patch` | clean (depends on 80030; deletes rtltool.{c,h} + EEPROM-write paths + procfs/sysfs + ioctl + Kconfig gate) | **Skip** with 80030. The audit is well-scoped and real (143 insertions, 3168 deletions) but irrelevant if we don't import the driver. |
| `80033-net-realtek-r8126-remove-unused-tail-pointer-reader.patch` | clean (depends on 80030 + 80032) | **Skip** with 80030. |
| `80035-net-realtek-r8126-demote-routine-reset-message.patch` | clean (depends on 80030) | **Skip** with 80030. |
| `80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch` | clean | **Port.** Small, in-tree, narrowly scoped to Orion O6/O6N via DMI match; exactly the kind of patch that resolves board-specific rfkill noise without touching shared driver code. |
| `80020-rtw89-check-acpi-dsm-before-evaluating.patch` | clean | **Port** as a small robustness fix. Guard against evaluating `_DSM` on firmware that doesn't advertise it; the rtw89_dsm_guid is not the Realtek GUID and our ACPI stack (without this guard) will evaluate-and-log-noise on Orion hardware. |

Headline:

- **All three "high-risk" Tier 3 candidates (70150, 72000/72010/72030, 80030+) are skips.** They are bigger and harder than Tier 2 by 1–2 orders of magnitude, and the hardware case for any of them is either absent (ISP) or already covered by mainline (RTL8126). The patch author has done real work on them, but we don't need to carry the work.
- **The two rtw89 patches are an easy port.** Small, in-tree, narrowly scoped, no shared-driver risk.

## 1. `70150-drm-support-up-to-64-planes.patch`

Patch size from `git apply --numstat` (manual count from diff): 4 insertions, 4
deletions across `drivers/gpu/drm/drm_atomic.c`,
`include/drm/drm_crtc.h`, and `include/drm/drm_plane.h`. (Two of the four
insertions are the `u32`→`u64` type change itself, plus a `%x`→`%llx` printf
fix in `drm_atomic_crtc_print_state`.)

What it changes:

- `include/drm/drm_crtc.h:struct drm_crtc_state.plane_mask` from `u32` to
  `u64`.
- `include/drm/drm_plane.h:drm_plane_mask()` from `static inline u32 ... { return
  1 << idx; }` to `static inline u64 ... { return 1ULL << idx; }`. Note the
  explicit `1ULL` — required to avoid `1 << idx` being computed as `int` (UB on
  `idx ≥ 32`).
- `drivers/gpu/drm/drm_atomic.c:drm_atomic_crtc_print_state()` printf spec from
  `%x` to `%llx` for the wider type.

Risk if ported:

- **No UAPI / no ioctl ABI break.** `drm_crtc_state` is in `include/drm/`, not
  `include/uapi/`. `drm_plane_mask()` is `static inline` in an internal header.
  Widening these is a kernel-internal-only change.
- **Wider blast radius than the diff suggests.** I grepped the 7.2-rc7 tree for
  every `plane_mask` reference. 35 files use it. The pre-patch tree reads and
  writes `plane_mask` freely via `drm_plane_mask()` and direct struct
  dereference. After the patch:

  - **Two silent-truncation sites** in DRM core that the patch *does not fix*:
    1. `drivers/gpu/drm/drm_atomic_helper.c:3100-3103` —
       `drm_atomic_helper_commit_planes_on_crtc()` declares `unsigned int
       plane_mask` and does
       `plane_mask = old_crtc_state->plane_mask; plane_mask |= new_crtc_state->plane_mask;`.
       After Stuart's widening, the right-hand side is `u64` and the
       left-hand side is 32-bit; the upper bits silently truncate.
    2. `drivers/gpu/drm/drm_framebuffer.c:1008-1079` —
       `drm_atomic_helper_disable_all()` declares `unsigned plane_mask` and
       accumulates `plane_mask |= drm_plane_mask(plane);` across planes. Same
       truncation.
  - i915 reads/writes the same field but via
    `crtc_state->uapi.plane_mask |= drm_plane_mask(...)`. i915's `uapi` field
    is `struct drm_crtc_state`, so after Stuart's patch the field is `u64` and
    `drm_plane_mask()` returns `u64`. Assignment is type-safe. i915's local
    `enabled_planes`/`active_planes` are `u8` for i915's own `plane_id` space
    (max 8 planes), bounded by enum, so no overflow there.
  - AMD display manager's `amdgpu_dm_trace.h` declares `__field(u32, plane_mask)`
    in a TRACE_EVENT — trace events will log the low 32 bits. Cosmetic only.
  - `drm_for_each_plane_mask(plane, dev, mask)` is a macro that does `(mask) &
    drm_plane_mask(plane)`. After the patch both operands are `u64`, so the
    macro body remains correct in any caller that has the full 64-bit mask in
    scope. The two truncation sites I list above are the only places where a
    32-bit local copies the mask.

  So the patch is **incomplete**: as written, on any 33+ plane Linlon
  configuration the helper commit path would silently lose the upper planes.
  The fix is to also widen those two locals to `u64` (or use the field
  directly). A safe port includes that companion change in the same patch.

- **No ABI exposure, no userspace break.** Internal kernel only.
- **No new locking, ordering, or default-dependency concerns.**

Applicability:

- `git apply --check --whitespace=nowarn` is clean against both pristine 7.2 and
  our `linux-7.2-rc7` working tree.
- Our series touches `drivers/gpu/drm/drm_atomic.c` only in patch `0131`
  (`drm-linlondp-fix-WERROR.patch` — adds `const` qualifiers in linlondp code,
  not in core DRM atomic functions) and `include/drm/drm_crtc.h` only in patch
  `0008` (linlondp driver itself, unrelated to `drm_crtc_state.plane_mask`).
  No conflict.

Does our hardware need this?

**No.** I checked the CIX linlondp plane-registration code
(`drivers/gpu/drm/cix/linlon-dp/linlondp_plane.c`):

```c
/* __drm_universal_plane_init() rejects num_total_plane >= 64. */
n_planes = 0;
for (di = 0; di < n_mdevs; di++) {
    ...
    for (i = 0; i < mdev->n_pipelines; i++) {
        pipe = mdev->pipelines[i];
        n_planes += pipe->n_layers;
    }
}
if (n_planes > 64) {
    DRM_ERROR("linlondp: %u planes exceed DRM core limit (64); ...\n",
              n_planes);
    return -EINVAL;
}
```

`n_layers` is 3 per pipeline (`drivers/gpu/drm/cix/linlon-dp/linlondp_product.h`:
`n_layers : 3`). `n_pipelines` is 2-bit (max 4). So a single DPU gives
12 planes, two DPUs (cluster case) give 24, three DPUs give 36. The cluster
case is what Stuart's commit message targets ("more than 32 planes aliasing").
Our hardware (Orion O6, O6N, MS-R1) is single-DPU CIX Sky1 silicon — there is
no `linlon-cluster` device in any DSDT we ship, and `linlondp_drv.c` only
binds `armchina,linlon-d2/d6/d8` and `CIXH5010`. So our hardware exposes ≤12
planes per CRTC, well under 32.

**The fix does nothing for us, and the patch as written would silently
mis-truncate on any future cluster-mode board if such a board ever appeared.**

Recommendation:

**Skip.** Even though the patch is small and the type widening is correct in
isolation, the diff is incomplete (two silent-truncation sites in DRM core) and
the hardware case isn't on our roadmap. If cluster-mode DPU ever shows up on a
future CIX product, the right fix is the full set: widen `drm_crtc_state` *and*
the two local `unsigned int`/`unsigned` masks in `drm_atomic_helper.c` and
`drm_framebuffer.c`, with a KUnit test that exercises a synthetic 40-plane
configuration to catch any future regression. Until then, leave the field at
32 bits.

If a future CIX single-DPU silicon ever increases `n_layers` past ~10, the
practical effect is planes >32 silently aliasing — which we'd want to *fix
correctly*, not via a half-applied patch from another vendor.

---

## 2. ISP driver import (72000 / 72010 / 72030)

These three patches are best read as one feature unit: a bulk vendor import of
~38 new files under `drivers/media/platform/cix/armcb-isp/`, plus a hardening
pass, plus a build-fix.

### 2.1 `72000-media-cix-import-armcb-isp-driver.patch`

Size: 406038 bytes, 14312 lines. 40 diff entries: 38 new files plus two
modifications to existing `drivers/media/platform/cix/Kbuild` and
`drivers/media/platform/cix/Kconfig`.

New files added under `drivers/media/platform/cix/armcb-isp/`:

- `armcb_isp_entry.c` — module-init glue (`armcb_isp_submodules_init`)
- `Makefile`
- `cixvihw/cix_vi_hw.{c,h}` — VI HW / CSI / DPHY / CSIDMA / CSIRCSU register
  accessor layer; binds ACPI HID `CIXH3026`
- `common/armcb_camera_io_drv.{c,h}` — camera I/O glue
- `common/armcb_isp.h`, `common/armcb_register.h` — register definitions
- `common/armcb_v4l_sd.{c,h}` — V4L2 subdev core
- `common/isp_hw_if/isp_hw_ops.{c,h}`, `common/isp_hw_if/isp_hw_utils.{c,h}` —
  ISP hardware-ops table
- `common/system_dma.{c,h}` — DMA helper
- `common/types_utils.h` — type aliases
- `isp/armcb_isp_driver.{c,h}` — main ISP driver; binds
  `armchina,sky1-isp`
- `isp/armcb_isp_execstart.{c,h}` — userspace-process introspection (see §2.2)
- `isp/armcb_isp_hw_reg.h` — ISP register header
- `isp/armcb_v4l2_config.{c,h}`, `isp/armcb_v4l2_core.{c,h}`,
  `isp/armcb_v4l2_stream.{c,h}` — V4L2 stack
- `isp/armcb_vb2.{c,h}` — vb2 glue
- `platform/armcb_platform.{c,h}`, `platform/logger/system_logger.{c,h}` —
  platform glue + log helper
- `sensor/actuator/armcb_actuator.{c,h}`, `sensor/armcb_sensor.{c,h}` —
  sensor/actuator glue

What it changes, in shape:

- Vendor code of typical quality: `sprintf(buf, "...%d...", i)` with 32-byte
  stack buffers (no overflow risk for `int` formatting), `devm_clk_get_optional`
  in probe, sensible `PTR_ERR`/cleanup ordering. Pre-72010 the register
  accessor layer (`cix_vi_hw.c`) does `cix_vi_hw_info->ahb_dphy_base_addrs[id]`
  with no NULL check and no `id`-range check, which 72010 fixes (see §2.2).
- The probe function matches `cix,cix-vi-hw` (DT) and ACPI HID `CIXH3026`;
  the ISP driver matches `armcb,sky1-isp` (DT) / via the ACPI enumeration.
- Adds a `Kconfig` symbol `VIDEO_CIX_ARMCB_ISP` and the corresponding
  `obj-$(CONFIG_VIDEO_CIX_ARMCB_ISP) += armcb-isp/` Makefile entry.

Risk if ported:

- **Hardware fit: zero.** Our fleet does not ship a camera sensor on any board.
  I grepped every doc (`docs/`, `assets/rescue/`, the build dir) for camera
  /MIPI/CSI hardware and found exactly one passing mention —
  `docs/AI-ML-STACK.md` mentions "video transcode / camera" in the context of
  the VPU codec pipeline, not camera hardware. No DSDT, no device tree, no
  board documentation mentions a CSI-attached sensor. Furthermore:
  - The driver binds ACPI HID `CIXH3026` for the VI HW / CSI PHY block. Our
    firmware publishes a list of CIX HIDs that does *not* include `CIXH3026`.
    The set our firmware uses is: `CIXH10xx`, `CIXH20xx`, `CIXH3010` (VPU
    mvx), `CIXH40xx`, `CIXH50xx` (Linlon DPU), `CIXH60xx`. No `CIXH30xx`
    other than `3010`. If we shipped 72000+72010, the `cix_vi_hw` driver
    would simply never probe — silent dead code in our image.
  - Even if we had CSI hardware, we'd still need an `armcb,sky1-isp` DT node
    or equivalent ACPI companion for the ISP core to bind. We don't have
    either.
- **Vendor-driver trust surface.** 72000 is a raw vendor drop with no upstream
  review (the file copyrights say "Copyright (c) 2024 CIX Semiconductor" /
  "The Linux Foundation"). The armcb-isp code paths include things like
  pre-72010 NULL-deref on `cix_vi_hw_info`, raw register poking on init
  paths, and the `armcb_isp_execstart.c` userspace-process-knitting helper
  (see §2.2).
- **Build-system collision.** 72000 wants to add
  `obj-$(CONFIG_VIDEO_CIX_ARMCB_ISP) += armcb-isp/` to
  `drivers/media/platform/cix/Kbuild` after `obj-m := amvx.o`. That hunk
  rejects against our tree because our 0126 mvx-vendor drop has already
  added entries to that Kbuild in a slightly different shape. A small
  fold-in is required, but is not mechanical — it needs manual edit.
  Similarly the `Kconfig` hunk wants to append after `VIDEO_LINLON_PRINT_FILE`,
  but our tree has additional entries below it (e.g. our thermal/CIX ISP
  config from earlier patches). Mechanical fold-in again.
- **Kconfig/Makefile grows** regardless of whether the driver ever probes —
  the `VIDEO_CIX_ARMCB_ISP` symbol adds 23 lines of Kconfig even if `n`.

Applicability:

- All 38 new files apply cleanly via `git apply --check` against pristine 7.2
  and against our `linux-7.2-rc7` tree.
- The two hunks to existing `Kbuild`/`Kconfig` files reject because the
  surrounding context differs.
- 72000 *should* be considered "applies with manual fold-in for Kbuild/Kconfig
  — the file additions themselves are clean."

Recommendation:

**Skip.** We have no camera sensor on any shipped board, the firmware lacks
the ACPI HIDs the driver would bind to, and the import is ~38 files of vendor
code with no production use case. Carrying it speculatively would be the
opposite of "only ship what runs" — it would add ~38 files, ~3KB of Kconfig,
a new `drivers/media/platform/cix/` subtree, and a maintenance burden for
forward-porting future Linux kernel API drift on a driver we never exercise.

If a future CIX product adds a camera sensor and we need the ISP, the right
move at that point is to import a *fresh* armcb-isp from CIX's current
release and review it as a real port — not adopt Stuart's frozen snapshot
from this ebuild.

### 2.2 `72010-media-cix-harden-armcb-isp-platform-subdevices.patch`

Size: 97363 bytes, 3235 lines. 17 diff entries; 16 files modified plus
`Makefile`.

What it changes (the meaningful bits):

- **`armcb_isp_entry.c` hardening.** `g_ko_entries[]` becomes `static`
  (was external linkage — visible across translation units; classic vendor
  smell). The module-init function now:
  - Returns `-ENODEV` on init failure (was: silently returned 0 even if
    submodule init returned NULL).
  - Calls `armcb_cam_instance_destroy()` to clean up instances that didn't
    finish probing.
  - Iterates init entries in reverse order and calls their `exit` callbacks
    on rollback. The pre-72010 code had *no* rollback path — a failed second
    init would leave the first one alive and the rest uninitialized, with
    `is_init = true` set on success regardless of what `init()` returned.
- **`Makefile` removes `armcb_isp_execstart.o` from the build** — see
  separate point below.
- **`cix_vi_hw.c` reg-access hardening.** Every `cix_ahb_*_read_reg()` /
  `cix_ahb_*_write_reg()` for the DPHY / CSI / CSIDMA / CSIRCSU register
  ranges now:
  - Uses `READ_ONCE(cix_vi_hw_info)` and a NULL check before deref (was:
    direct deref, NULL-deref if init ordering put a reg read before the
    `cix_vi_hw` platform probe finished).
  - Bounds-checks the `id` argument against `DPHY_NUM` / `CSI_NUM` /
    `CSIDMA_NUM` (was: OOB array access if id ever got corrupted).
  - Calls a new `cix_vi_reg_valid(base, offset, size)` helper to verify
    the offset is in-range and 4-byte-aligned (was: direct `readl(base +
    offset)` with no size check).
  - `cix_enable_dphy_clk()` now early-returns if the block is already
    powered on (`dphy_power_status[id] == POWER_ON`) — was: re-enabling the
    clock every call.
- **Deletes `armcb_isp_execstart.c` and `armcb_isp_execstart.h` outright**
  (566 lines of code). This is the most significant hardening move. The
  file was a kernel-side userspace-process introspection helper that:
  - Walked `find_get_pid()` / `pid_task()` / `get_cmdline()` to identify
    userspace processes named `isp_app`.
  - Read `/proc/<pid>/cmdline` and matched argv patterns (`-c`, `-s N`,
    `-m N`) against an allowed context-ID bit mask.
  - Enforced that only certain V4L2 context IDs could open certain video
    devices, based on which `isp_app` invocation the kernel found running.

  This is the kind of "kernel enforcing userspace process policy" pattern
  that occasionally appears in vendor BSPs and that almost never survives
  upstream review. Removing it is unambiguously good — `isp_app` process
  enumeration is userspace's job, and the kernel has no business enforcing
  "which userland binary may open which V4l2 device node."

- Strips `#if (KERNEL_VERSION(4, 17, 0) > LINUX_VERSION_CODE)` (vestigial
  4.17-conditional code) from the entry path.
- Various smaller cleanups in `armcb_v4l_sd.c`, `isp_hw_ops.c`,
  `armcb_isp_driver.c`, `armcb_v4l2_core.c`, `armcb_v4l2_config.c`,
  `armcb_actuator.c`, `armcb_sensor.c` — I sampled these and they look
  like consistent hardening (additional NULL checks, error-path cleanup,
  log level tuning) rather than rearchitectures.

Risk if ported:

- 72010 is real, targeted hardening. The diff shape is the right one for
  "vendor driver with weak safety discipline." Locking discipline in the
  `cix_vi_hw.c` accessors is improved by the NULL/range guards; the
  pre-72010 code is genuinely unsafe in a way that would matter if the
  driver ever probed.
- The `armcb_isp_execstart.c` deletion removes a non-trivial chunk of
  code that was *also* a maintainability footgun.
- 72010 does not touch any shared/core code outside the imported
  `armcb-isp/` subtree. Blast radius is bounded.

Applicability:

- `git apply --check --whitespace=nowarn` is clean against pristine 7.2
  after 72000 is applied, AND against our `linux-7.2-rc7` tree after
  72000 is applied. Order matters: 72010 must come after 72000 (it
  patches files that 72000 creates).

Recommendation:

**Skip with 72000.** The hardening is real and well-targeted, and if we
were carrying the ISP, we'd want this pass. But the right place to do that
hardening is when we have an actual camera sensor to bind to, not as a
speculative import. If we ever do import the ISP for a real camera board,
72010 (or its modern equivalent) should be the first thing ported.

### 2.3 `72030-media-cix-port-isp-to-linux-7.2.patch`

Size: 1007 bytes, 24 lines. 1 diff entry: `drivers/media/platform/cix/armcb-isp/isp/armcb_v4l2_core.c`.

What it changes:

- Adds `#include <linux/string.h>` after `#include <linux/soc/cix/cix_ddr_lp.h>`.
- Changes
  `strncpy(f->description, fmt->name, sizeof(f->description) - 1);`
  to
  `strscpy(f->description, fmt->name, sizeof(f->description));`
  in `armcb_v4l2_enum_fmt_vid_cap()`.

Same intent as our own `0128` (Linux 7.2 build fix for mvx) but for a
different driver.

Risk if ported:

- The strncpy→strscpy fix is a real 7.2 string-API change and the
  description is the only `strncpy` in the file (I verified). `strscpy`
  is already used elsewhere in the same file at line 1972 (post-72010),
  so the symbol is already in scope; the `#include <linux/string.h>` is
  hygiene, not strictly needed for compilation.

Applicability:

**Does not apply.** Tested against:

- Pristine 7.2 — rejects. The `#include` hunk references
  `#include <linux/soc/cix/cix_ddr_lp.h>` at line 42 context; pristine 7.2
  doesn't have a `linux/soc/cix/cix_ddr_lp.h` include in
  `armcb_v4l2_core.c` at all. The actual `v4l2_core.c` from 72000 has
  `#include <linux/platform_device.h>` between `mutex.h` and `sched.h`,
  which 72030's hunk doesn't account for.
- Our tree + 72000 — rejects. Same reason; our tree's v4l2_core.c has
  the same `linux/platform_device.h` include layout.
- Our tree + 72000 + 72010 — rejects. 72010 also doesn't insert the
  `cix_ddr_lp.h` line; the v4l2_core.c include layout stays
  `mutex.h → platform_device.h → sched.h → slab.h → ...`.

I confirmed by reading the rejected hunk: 72030 expects the include
order to contain `<linux/soc/cix/cix_ddr_lp.h>` somewhere between
`linux/sched.h` and `linux/v4l2-dv-timings.h`, but neither pristine 7.2
nor our tree has that include in `v4l2_core.c` at all. The strscpy
hunk itself (line 1420) applies cleanly if isolated — only the
`linux/string.h` include-hunk is stale.

The fix itself is one line and valid; regenerating it against the
actual `v4l2_core.c` from 72000 would be ~30 seconds of work. But
there's no point doing that work without 72000 in the tree.

Recommendation:

**Skip with the rest of the ISP group.** The patch is stale (its context
references an include that's not in the file) and the actual fix is
trivial to regenerate if we ever want it. Don't carry a stale patch in
the series — it'll just be a tripping hazard for whoever rebases.

---

## 3. RTL8126 driver import (80030 / 80031 / 80032 / 80033 / 80035)

These five patches are one feature unit: import the vendor RTL8126 10.018.00
DKMS driver as an in-tree driver, gated against `R8169 = n`, then strip the
vendor engineering interfaces and do small cleanups.

### 3.1 `80030-net-realtek-import-r8126-driver.patch`

Size: 892115 bytes, 23586 lines. 19 diff entries — 17 new files plus
modifications to the parent `drivers/net/ethernet/realtek/Kconfig` and
`Makefile`.

Source provenance: explicit in the commit message —
`https://github.com/awesometic/realtek-r8126-dkms` tag `10.018.00-1`,
commit `fbf668194052211599594daa3d722c5c519d4c25`. Audit point is
verifiable.

Files added:

- `drivers/net/ethernet/realtek/r8126/Kconfig` — declares `R8126` tristate
  with `depends on R8169 = n` mutex, plus `R8126_UNSAFE_DIAGNOSTICS` behind
  `EXPERT`.
- `drivers/net/ethernet/realtek/r8126/Makefile` — `obj-$(CONFIG_R8126) +=
  r8126.o`; `r8126-objs := r8126_n.o rtl_eeprom.o r8126_rss.o`;
  `r8126-$(CONFIG_R8126_UNSAFE_DIAGNOSTICS) += rtltool.o`; a series of
  `-DCONFIG_*`/`-DENABLE_*` ccflags.
- `r8126_n.c` (main driver — the bulk of the ~890KB), `r8126.h`
- `r8126_firmware.{c,h}` (firmware loader), `r8126_ptp.{c,h}`,
  `r8126_realwow.h`, `r8126_rss.{c,h}` (RSS hash tables),
  `r8126_fiber.{c,h}`, `rtl_eeprom.{c,h}`, `rtltool.{c,h}` (the unsafe
  diagnostics interface that 80032 deletes).

Kconfig adds `depends on R8169 = n` — a hard mutex against mainline r8169
claiming the same PCI device. No risk of both binding. Kconfig is well
formed.

`ccflags-y` enables a meaningful feature set: NAPI, VLAN, S5/S0 WoL, EEE,
TX_NO_CLOSE, GIGA_LITE, RSS, ASPM, SOC_LAN. That's the full
production-driver surface — not a stripped-down stub.

What it changes:

- Adds a complete vendor 5GbE driver behind a Kconfig mutex.
- Per the commit message and the Kconfig, intended for use on boards
  whose mainline `r8169` is insufficient — typically the 5GbE
  RTL8126 in some early/adapter configurations where r8169 had bugs.

Risk if ported:

- **Trust surface.** 890KB of vendor code (the dkms source is on github
  and verifiable, but vendor code is vendor code: it has its own locking
  style, error-handling conventions, and bug history). 80032 strips a
  meaningful chunk (3KB of ioctl/procfs/sysfs/EEPROM-write interfaces),
  but the core driver body is still vendor code.
- **Hardware fit: zero.** Our fleet relies on mainline `r8169` for the
  O6 NIC. Authoritative source: `assets/rescue/AGENTS.md`:
  > **Radxa Orion O6** (Realtek RTL8125/8126 NIC via `r8169`).
  > **NIC:** mainline `r8169` (RTL8125/8126); `rtl_nic` firmware required
  > for the O6.

  I verified mainline `r8169` in our `linux-7.2-rc7` source already lists
  the RTL8125/8126/8127 PCI IDs:

  ```c
  drivers/net/ethernet/realtek/r8169_main.c:245-247:
    { PCI_VDEVICE(REALTEK, 0x8125) },
    { PCI_VDEVICE(REALTEK, 0x8126) },
    { PCI_VDEVICE(REALTEK, 0x8127) },
  ```

  Our `config-7.2-lean-msr1-o6n.defconfig` has `CONFIG_R8169=y`. The O6
  and O6N boards ship RTL8125 or RTL8126 NICs and mainline `r8169` drives
  them today. The vendor R8126 driver is a *parallel* driver gated by
  `R8169 = n` — carrying it adds ~890KB of object code and ~3KB of
  Kconfig to a kernel that already has working NIC support.

- **Build/option pressure.** The Kconfig `R8126` symbol is hidden behind
  `R8169 = n`, but its existence changes the meaning of `make oldconfig`
  output and adds an entry to menuconfig. Anyone doing a manual kernel
  build would see it and wonder. The thin-config stage would need to be
  aware of it to keep `R8169=y, R8126=n` (the right setting for us).

- **No shared/core code touched.** The vendor driver lives in its own
  `drivers/net/ethernet/realtek/r8126/` subtree.

- **Compatibility with r8169.** The Kconfig `R8169 = n` mutex is a hard
  guarantee that both can't be enabled at the same time. No probe-time
  collision possible.

Applicability:

- `git apply --check --whitespace=nowarn` is clean against both pristine
  7.2 and our `linux-7.2-rc7` tree.
- No patch in our 210-patch series touches `drivers/net/ethernet/realtek/`
  except `0110-net-r8169-skip-hw-tally-rtl8127-sky1.patch`, which touches
  `r8169_main.c` only.

Recommendation:

**Skip.** Our fleet's NIC works with mainline `r8169`, the vendor driver
is a parallel 890KB import gated by a Kconfig mutex that we would set to
`n` anyway, and the trust surface of a vendor network driver that we don't
need is exactly the kind of thing an installer kernel should not carry.

If a future CIX board ships an RTL8126 variant that mainline r8169 doesn't
handle well (e.g. RTL8126B revision that needs vendor microcode paths), the
right move at that point is to either (a) upstream the missing support to
r8169, or (b) bring in the vendor driver with a specific bug-fix rationale.
Not speculatively.

### 3.2 `80031-net-realtek-r8126-prefer-performance-core-irqs.patch`

Size: 3729 bytes, 107 lines. 1 diff entry: `r8126.h` + `r8126_n.c`.

What it changes:

- Adds a `struct cpumask *performance_core_mask` field to
  `struct rtl8126_private` (under `#ifdef CONFIG_ARM64`).
- Adds `rtl8126_alloc_performance_core_mask()` which uses
  `topology_get_cpu_scale(cpu)` to pick CPUs with scale ≥
  `RTL8126_LITTLE_CORE_CAPACITY` (defined as 512, i.e. A720 cores on a
  big.LITTLE part).
- Allocates this mask at `rtl8126_alloc_irq()` time, calls
  `irq_set_affinity_and_hint(irq->vector, mask)` for each IRQ vector to
  bias them toward A720 cores.
- Frees the mask and clears the affinity hint in `rtl8126_free_irq()`.

Risk if ported:

- Bounded to the imported vendor driver; no shared code touched.
- `topology_get_cpu_scale()` is the standard arch_topology helper; works
  on big.LITTLE. The `RTL8126_LITTLE_CORE_CAPACITY = 512` threshold is
  reasonable for Cortex-A720 (scale 1024) vs Cortex-A520 (scale 512
  threshold — would be excluded). The threshold is hard-coded, which is
  fragile if a future ARM part uses different scale values, but for the
  current CIX Sky1 A720+A520 it's correct.
- `irq_set_affinity_and_hint()` returning nonzero is logged at warning
  level but not fatal — graceful degradation.
- Locking: the affinity-hint allocation happens at IRQ-alloc time and
  is freed at IRQ-free time; no race window. The mask itself is
  read-only after allocation. Looks correct.

Applicability:

- Clean against pristine 7.2 and our tree, *only after 80030 is
  applied* (it patches the imported `r8126.h` and `r8126_n.c`).

Recommendation:

**Skip with 80030.** The pattern is the right one for a high-throughput
5GbE driver on a big.LITTLE SoC, but we don't have the driver.

### 3.3 `80032-net-realtek-r8126-remove-vendor-engineering-interfaces.patch`

Size: 130472 bytes, 3636 lines. 8 diff entries. By far the most
aggressive of the RTL8126 set.

What it changes:

- Deletes `drivers/net/ethernet/realtek/r8126/rtltool.{c,h}` outright.
  `rtltool.c` is the vendor's procfs/sysfs/debugfs test interface —
  things like reading/writing raw MAC registers, EEPROM bytes, PHY
  registers, cable diagnostics, and an ioctl for "raw register poke."
- Removes the `R8126_UNSAFE_DIAGNOSTICS` Kconfig entry and the
  `r8126-$(CONFIG_R8126_UNSAFE_DIAGNOSTICS) += rtltool.o` Makefile line.
- Removes `ENABLE_R8126_PROCFS`, `ENABLE_R8126_SYSFS` defines from
  `r8126.h`.
- Removes the unconditional GPL banner printer from module init
  (vendor source had a per-init `pr_info("r8126 Copyright (C) ...\n")` —
  the SPDX declarations are authoritative).
- Removes the EEPROM write path (`rtl8126_eeprom_cmd_done`,
  `rtl8126_eeprom_write_sc`, the WRITE/ERASE/EWEN/EWDS opcodes, the
  write declarations) from `rtl_eeprom.{c,h}`. Read-only EEPROM is
  retained, which is what normal network-driver operation needs.
- Strips the procfs/sysfs/debugfs helper functions and the ioctl
  handler from `r8126_n.c`.

Numbers: 143 insertions, 3168 deletions across 8 files. That's a
serious audit pass — the patch removes 23× more code than it adds.

Risk if ported:

- The strip is well-scoped. The remaining driver still has all the
  production functionality (NAPI, RSS, WoL, VLAN, EEE, PTP, fiber,
  firmware loading).
- No shared code touched; bounded to the imported `r8126/` subtree.
- The `rtl_eeprom.{c,h}` write-path removal is the only change a
  production system could conceivably notice — but writing to the NIC
  EEPROM via the kernel module was never a sensible operation, and any
  legitimate EEPROM update should use vendor userspace tools
  (out-of-tree) anyway.

Applicability:

- Clean against pristine 7.2 and our tree, after 80030. (It patches the
  same `r8126/` files 80030 imports.)

Recommendation:

**Skip with 80030.** The audit is real, well-targeted, and would
significantly reduce the trust surface of the imported driver. If we ever
imported the RTL8126 vendor driver, 80032 would be the first of the
five to port. But — same as the rest — we don't have a hardware
need.

### 3.4 `80033-net-realtek-r8126-remove-unused-tail-pointer-reader.patch`

Size: 1098 bytes, 35 lines. 1 diff entry: `r8126_n.c`.

What it changes:

- Deletes `rtl8126_get_sw_tail_ptr()` (which read the
  `sw_tail_ptr_reg` from the NIC's BAR — direct register access used
  by the now-deleted procfs/sysfs test interface). The function has no
  other callers after 80032 strips the engineering interfaces, so
  removing it cleans up a `-Wunused-function` warning.

Risk if ported:

- Cosmetic / dead-code removal post-80032. No functional impact.

Applicability:

- Clean against pristine 7.2 and our tree, after 80030+80032.

Recommendation:

**Skip with 80030.**

### 3.5 `80035-net-realtek-r8126-demote-routine-reset-message.patch`

Size: 1225 bytes, 26 lines. 1 diff entry: `r8126_n.c`.

What it changes:

- `rtl8126_reset_task()` (called for both transmit timeout and routine
  resume paths) demotes `"Device reseting!"` from `netdev_err` to
  `netdev_dbg`, and rewrites the wording.
- `rtl8126_tx_timeout()` keeps the error-level log on actual transmit
  timeout, with new wording `"Transmit timeout, scheduling device
  reset"`.

The pre-80035 behavior: a routine resume fires the same
`"Device reseting!"` message at error level as a real transmit timeout,
which makes every resume look like a hardware error in the kernel log.

Risk if ported:

- Pure log-level demote. No behavior change beyond kernel-log noise on
  resume.
- The wording fix ("reseting" typo → "Resetting device", and
  "Transmit timeout reset Device!" → "Transmit timeout, scheduling
  device reset") is a nice touch.

Applicability:

- Clean against pristine 7.2 and our tree, after 80030.

Recommendation:

**Skip with 80030.** The demote itself is correct, but irrelevant if we
don't carry the driver.

---

## 4. rtw89 patches (80010 and 80020)

These are in-tree patches to the mainline `rtw89` driver — not vendor
blobs, not driver imports. Small, focused, narrow.

### 4.1 `80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch`

Size: 886 bytes, 30 lines. 1 diff entry: `drivers/net/wireless/realtek/rtw89/core.c`.

What it changes:

- Adds a `static const struct dmi_system_id no_hw_rfkill_dmi[]` table
  matching `Radxa Computer (Shenzhen) Co., Ltd.` as sys vendor with
  either `Radxa Orion O6` or `Radxa Orion O6N` as product name.
- In `rtw89_chip_has_rfkill()`, if `rtwdev->chip->chip_id == RTL8852B`
  AND `dmi_check_system(no_hw_rfkill_dmi)` is true, returns `false`
  (no rfkill support — skip the polling).
- Otherwise behaves as before (returns the chip's `rfkill_init`).

Risk if ported:

- Touches `rtw89` shared driver code (`core.c`), but the change is
  gated by an exact DMI string match (vendor + product name) AND an
  exact chip ID. Non-Orion hardware, or Orion hardware with a
  different WiFi chip, is completely unaffected.
- The function returns earlier than before only on the matched
  DMI+chip combination; no other behavior change.
- No locking, ordering, or default-dependency concerns — `dmi_check_system`
  is cheap and synchronous.
- The fix targets a specific reported issue: hw-rfkill polling on the
  RTL8852B WiFi chip on Orion O6/O6N misbehaves (likely spurious
  rfkill state transitions during boot). Skipping the poll avoids it.

Applicability:

- Clean against pristine 7.2 and our tree. `rtw89` exists in our
  `linux-7.2-rc7` base (`drivers/net/wireless/realtek/rtw89/`) and no
  patch in our 210 series touches `rtw89/core.c`.

Recommendation:

**Port.** This is exactly the kind of small targeted patch that fixes a
board-specific WiFi noise without touching shared driver semantics. The
DMI gate is precise; the chip-ID gate adds a second layer of safety; no
non-Orion system sees the change. Standard "ship if and only if it
fixes the reported problem" pattern.

### 4.2 `80020-rtw89-check-acpi-dsm-before-evaluating.patch`

Size: 1189 bytes, 30 lines. 1 diff entry:
`drivers/net/wireless/realtek/rtw89/acpi.c`.

What it changes:

- In `rtw89_acpi_evaluate_dsm()`, before calling
  `acpi_evaluate_dsm(handle, &rtw89_guid, 0, func, NULL)`, the patch
  adds:
  1. A NULL-handle check (`!handle` → return `-ENOENT`).
  2. A `func >= 64` sanity check (the DSM function index is a 6-bit
     bitmap; values ≥64 are nonsense).
  3. An `acpi_check_dsm(handle, &rtw89_guid, 0, BIT_ULL(func))` call
     that returns the bitmask of functions firmware actually
     advertises; if the requested function isn't in the bitmap, return
     `-ENOENT` without evaluating.
- The pre-80020 code calls `acpi_evaluate_dsm()` unconditionally. On
  firmware that doesn't advertise the `_DSM` at all, this generates
  ACPI errors ("_DSM evaluate failed" warnings) even though the
  driver would have handled the missing DSM anyway.
- Logs at `RTW89_DBG_ACPI` debug level on the early-return path.

Risk if ported:

- Touches `rtw89` shared driver code (`acpi.c`) but only adds
  pre-flight checks. Behavior change: previously, `acpi_evaluate_dsm`
  would be called and would fail; now it's short-circuited before the
  call. Functionally equivalent on the failure path, and avoids the
  ACPI warning spam.
- No locking, ordering, or default-dependency concerns.
- The `func >= 64` check is a defensive bound check — `func` is an
  enum, but if a caller ever passed a junk value the old code would
  have called `acpi_evaluate_dsm` with a wild index. Good addition.
- The `acpi_check_dsm()` call is the upstream-recommended pattern for
  ACPI DSM evaluation. Aligns rtw89 with how most other kernel
  drivers check DSM availability.

Applicability:

- Clean against pristine 7.2 and our tree. `rtw89/acpi.c` exists in
  base, no overlap with our patches.

Recommendation:

**Port.** This is a generic robustness improvement to an in-tree
driver; not Orion-specific, not even CIX-specific. It avoids noisy
firmware warnings on any system where the WiFi device's ACPI companion
doesn't publish the rtw89 GUID's DSM. Carries essentially no risk and
makes the driver less noisy in production.

The two rtw89 patches are independent and can be ported in either
order. Together they total ~30 lines of diff and meaningfully improve
the rtw89 driver experience on our Orion hardware (and probably on
other systems too).

---

## Mechanical apply details

Dry-applies:

```text
git apply --check --whitespace=nowarn <patch>
```

| Patch | Pristine 7.2 | Our 7.2-rc7 tree | Notes |
|---|:-:|:-:|---|
| `70150-drm-support-up-to-64-planes.patch` | ✅ clean | ✅ clean | |
| `72000-media-cix-import-armcb-isp-driver.patch` | partial | partial | 38 new files clean; Kbuild/Kconfig hunks reject against both (different surrounding context). Manual fold-in for the Kbuild/Kconfig hunks. |
| `72010-media-cix-harden-armcb-isp-platform-subdevices.patch` | ✅ after 72000 | ✅ after 72000 | |
| `72030-media-cix-port-isp-to-linux-7.2.patch` | ❌ | ❌ | Stale include context; `<linux/soc/cix/cix_ddr_lp.h>` is not in `v4l2_core.c`. Strncpy→strscpy hunk alone applies cleanly. |
| `80030-net-realtek-import-r8126-driver.patch` | ✅ clean | ✅ clean | |
| `80031-net-realtek-r8126-prefer-performance-core-irqs.patch` | ✅ after 80030 | ✅ after 80030 | |
| `80032-net-realtek-r8126-remove-vendor-engineering-interfaces.patch` | ✅ after 80030 | ✅ after 80030 | |
| `80033-net-realtek-r8126-remove-unused-tail-pointer-reader.patch` | ✅ after 80030+80032 | ✅ after 80030+80032 | |
| `80035-net-realtek-r8126-demote-routine-reset-message.patch` | ✅ after 80030 | ✅ after 80030 | |
| `80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch` | ✅ clean | ✅ clean | |
| `80020-rtw89-check-acpi-dsm-before-evaluating.patch` | ✅ clean | ✅ clean | |

No patch in our 210-patch series has any file overlap with 80010,
80020, 70150, or 80030-80035. The ISP patches overlap with nothing
in our series.

## File-overlap matrix (vs our 210 patches)

```
70150:   drivers/gpu/drm/drm_atomic.c   (our 0131 — different lines, different change)
         include/drm/drm_crtc.h         (our 0008 — linlondp additions, not plane_mask)
72000+:  drivers/media/platform/cix/    (NEW; nothing existing except mvx Kbuild/Kconfig)
80010/20:drivers/net/wireless/realtek/rtw89/  (no overlap with our series)
80030+:  drivers/net/ethernet/realtek/  (only overlap is 0110 on r8169_main.c — different file)
```

## Net recommendation in one paragraph

Of the three "high-risk" Tier 3 candidates the operator flagged, all three
are skips: 70150 because it doesn't fix our hardware case and is itself
incomplete (the two `unsigned int` mask locals in `drm_atomic_helper.c` and
`drm_framebuffer.c` silently truncate after the field widening); 72000/72010
because we have no camera sensor and the firmware lacks the driver's ACPI
HIDs; 80030-80035 because mainline `r8169` already supports RTL8125/8126/8127
and that's what our O6/O6N fleet uses. The two rtw89 patches (80010 and
80020) are small, in-tree, narrowly targeted and should be ported — they're
the same shape as Tier 1/Tier 2 "small self-contained patch" candidates
and have none of the Tier 3 risk profile. 72030 is dead on arrival
regardless — its patch context references an include that isn't in the
file. If a future CIX product adds a camera sensor, or cluster-mode DPU,
or a NIC variant mainline r8169 can't drive, the right move is to
re-evaluate at that point with a fresh vendor drop, not pre-emptively
import what we'd then need to forward-port.
