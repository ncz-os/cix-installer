# Original Radxa Orion O6 fails to bring up display: 40 planes into a 32-plane DRM device

**Reporter:** Gábor Sebestyén, UART capture 2026-08-29 (raw log:
`2026-08-29-gabor-orion-o6-boot-uart.log`).
**Board:** Radxa Orion O6 — the ORIGINAL O6, not O6N. BIOS 1.3.1 2026-07-16.
**Image:** NCZ-OS installer, `ncz_rev=2026.08.27`, desktop variant, kernel
7.2.0-sky1-ncz.
**Status:** root-caused from the log plus our own sources. NOT yet reproduced
on our hardware — we do not have a 5-DPU board.

## Root cause

The board has **five** DPU instances (`CIXH502F:00` … `:04`) under ACPI cluster
`CIXH50C0`, each reporting two pipelines of four layers:

```
[drm] Found ARMCHINA Linlon-D60 version r0p0      x5   (DP00..DP04)
[drm] Pipeline-0: n_layers: 4, n_scalers: 2 ...
[drm] Pipeline-1: n_layers: 4, n_scalers: 2 ...
linlon-cluster: registered 5 DPU(s) for ACPI cluster CIXH50C0
[drm] CRTC-0 .. CRTC-9                            10 CRTCs = 5 DPUs x 2 pipes
```

5 DPUs x 2 pipelines x 4 layers = **40 planes** registered into ONE DRM device.

Mainline v7.2 `drivers/gpu/drm/drm_plane.c:379` — the exact line named in the
warning, and the kernel we build (`SRCREV_kernel = 8d3ae59288f1…`, the v7.2
tag) — says:

```c
	/* plane index is used with 32bit bitmasks */
	if (WARN_ON(config->num_total_plane >= 32))
		return -EINVAL;
```

DRM allows at most **32 planes per device** because plane indices are carried
in 32-bit bitmasks. Plane 33 onwards is refused, so
`linlondp_kms_add_planes_multi()` fails, `linlondp_kms_attach_cluster()`
returns an error, and the cluster never binds — no display.

### Why this has never shown up on our boards

    O6N       1 DPU  x 2 pipes x 4 layers =  8 planes   fine
    MS-R1     4 DPUs x 2 pipes x 4 layers = 32 planes   exactly at the limit
    O6 (Gábor) 5 DPUs x 2 pipes x 4 layers = 40 planes  OVERFLOWS

The original O6 is the first configuration that exceeds it. MS-R1 sits exactly
on the boundary, which is uncomfortably close: any future patch that adds a
single plane (a cursor plane, a writeback plane) breaks the MS-R1 too.

## The second warning is a consequence, not a separate bug

Five copies of:

```
Unable to drop a managed device link reference
WARNING drivers/base/core.c:1020 device_link_put_kref
  device_link_del  <- linlondp_cluster_bind+0x2a0 [linlon_dp]
```

one per DPU (x21 = 0,1,2,3,4). Our own patch
`patches-7.2/0067-drm-cix-replace-linlon-dp-dptx-with-cixtech-2026q2-o.patch`
creates the links with **flags = 0**:

```c
cl->dpu_links[i] = device_link_add(dev, cl->mdevs[i]->dev, 0);
```

Flags of 0 makes a *managed* link, owned by the driver core.
`device_link_del()` is only valid on links created with `DL_FLAG_STATELESS`;
on a managed link the core warns and refuses. `linlondp_cluster_bind()`'s
error path — reached because of the plane overflow above — calls
`linlondp_cluster_dpu_links_del()`, hence one warning per link.

So this warning is harmless noise that only appears when bind fails, but it is
still wrong and it obscures the real error.

## Fixes

1. **The plane budget (the actual bug).** Do not register every layer of every
   pipeline of every DPU as a DRM plane. Options, in rough order of
   preference:
   - only add planes for pipelines that have a connected/used output;
   - expose a bounded set per CRTC (primary + one overlay) and keep the rest
     internal;
   - register one DRM device per DPU rather than one per cluster, which is
     what the single-DPU path already does successfully.
   Whatever is chosen, `linlondp_kms_add_planes_multi()` must check the budget
   itself and fail with a clear message rather than letting DRM WARN, because
   the current failure is silent from a user's point of view: no display, no
   explanation unless you have UART.

2. **The device links.** Pass `DL_FLAG_STATELESS` to `device_link_add()` since
   the driver deletes the links explicitly in both the error path and
   `linlondp_cluster_unbind()`. Alternatively drop the explicit deletes and let
   the core manage them. Do one or the other, not the current mix.

## Not yet verified

- Neither fix is written or tested; we have no 5-DPU board. MS-R1 (4 DPUs, 32
  planes) is the closest thing and it currently passes, so a regression test
  there will NOT catch a plane-budget mistake. Any fix should be tested by
  temporarily lowering the limit or by synthesising a 5th DPU.
- The plane count of 40 is derived from the log's own numbers (5 DPUs, 2
  pipelines each, `n_layers: 4`), not from instrumented counting on the board.

## Unrelated observations in the same log

- `rtw89_core: Unknown symbol ieee80211_*` x ~70. The Realtek Wi-Fi module is
  being loaded without `mac80211`/`cfg80211` present, so it cannot bind. Wi-Fi
  will not work on this image until the dependency is shipped or the module is
  not installed.
- The install itself proceeded: NVMe, both RTL8126A NICs, USB storage and the
  installer menu all came up. The failure is display-only.
