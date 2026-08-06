# cix_vaapi patches — CIX Sky1 hardware video decode

Against `cixtech/cix_vaapi`. Applied on top of the vendor tree as shipped in
NCZ-OS 26.7 ("Maximilian", Debian Forky, arm64), verified on a Radxa Orion O6.

`0001-vaapi-fixes.diff` — apply from the repo root with `patch -p1`.

## What it fixes

Hardware decode through the VA-API path was unusable in Chromium-family
browsers. Three independent defects, in the order they bite:

1. **`vaQueryConfigAttributes()` reported no attributes.**
   `CreateConfig()` recorded only the attributes the caller passed in.
   Chromium deliberately creates an attribute-less config so the driver will
   enumerate its RT formats; getting none back, it rejected every profile
   (`FillProfileInfo_Locked failed for va_profile ...` for H.264, HEVC, VP9 and
   AV1) and fell back to software. The driver's own `VAConfigAttribRTFormat` is
   now recorded when the caller supplies none.

2. **Exported surfaces used a single composed layer.**
   Chromium exports with `VA_EXPORT_SURFACE_SEPARATE_LAYERS` and rejects any
   layer carrying more than one plane. `ExportSurfaceHandle()` now honours the
   flag, one layer per plane, with per-plane DRM formats (`R8`/`GR88` for NV12,
   `R16`/`GR1616` for P010).

3. **The exported buffer was not the decoder's output buffer** — the flat green
   frames.
   Chromium exports every surface once, up front, *before* any picture is
   decoded, then reuses those dmabufs for the life of the stream. mpv exports
   per frame, after decode, which is why only Chromium saw this.

   On an export-before-decode there was no surface bound to the requested
   `VASurfaceID`, so the driver minted a fresh pool surface and returned its fd.
   `BeginPicture()` then calls `DestroyUnusedSurface(render_target)`; since
   `Surface::users` tracks only `V4l2Buffer` users and not client dmabuf
   holders, `HasUser()` was false and that surface was destroyed. Decoding
   proceeded into a capture buffer instead, leaving the client holding an fd to
   a buffer nothing ever writes — an all-zero NV12 frame, which renders as flat
   green (`rgb(0,136,0)`).

   The capture port owns the real decode targets: `Port::CreateBuffers()` takes
   32 pool surfaces, binds each to a `V4l2Buffer`, and clears their IDs.
   `FetchCaptureBoundSurface()` returns one of those, so the exported dmabuf is
   the buffer the VPU writes into, and it survives `DestroyUnusedSurface()`
   because it now has a `V4l2Buffer` user.

Also included: `vaCreateBuffer(data == NULL)` support (host-side storage filled
via `vaMapBuffer()`/`vaUnmapBuffer()`), which Chromium's AV1 path uses.

`FetchUnassignedSurface()` is a secondary guard — handing back a surface still
bound to a live `VASurfaceID` aliases two IDs onto one dmabuf. It closes a real
hole but, tested on its own, did **not** fix the green frames; item 3 did.

## Verification

Google Chrome 151, Wayland ozone, on the O6:

| Codec | Result |
|---|---|
| H.264 1080p | correct moving picture, `/dev/video0` held, renderer CPU ~6% |
| VP9 720p | correct moving picture |

Motion was confirmed by the video's own burnt-in timestamp and frame counter
advancing across successive screenshots (`00:00:01.400` frame 42 →
`00:00:01.633` frame 49), not by an open device node alone — an open
`/dev/video0` accompanied the green frames too and is not evidence of correct
decode.

mpv (`--hwdec=vaapi`) was correct before and after; it is the control.

## Not fixed here

- **AV1** needs `VADecPictureParameterBufferAV1Ext`, a CIX-private libva
  extension (magic `0x31425643`, `'CVB1'`) absent from upstream libva.
- **Debian's Chromium** cannot use any of this: it is built `use_vaapi=false
  use_v4l2_codec=true` on arm64 and its V4L2 path dies on the Arm proprietary
  `Y0A8` capture format (`GPU process exited unexpectedly: exit_code=133`).
  It needs a rebuild, not a flag.
- Under **X11 ozone** VA-API init fails on this board for every Chromium-family
  browser (`GetHandle(): ... failed to find a suitable render node`). Launch
  with `--ozone-platform=wayland`.

## Building

Upstream `cix_vaapi` does not build against stock libva. It needs:

- CIX's libva headers (`vaprobe_inc/va/`) for the AV1 `Ext` types — Debian's
  `libva-dev` 2.24.1 lacks them
- `mvx-v4l2-controls.h` from the VPU DKMS source
  (`/usr/src/cix-vpu-driver-*/driver/linux`)
- a `libcme.so` symlink; only `libcme.so.1` ships
