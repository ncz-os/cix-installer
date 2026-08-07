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

## `0003-av1-render-order.diff` — AV1 buffer ordering

Chromium submits AV1 buffers with the slice **data** ahead of the slice
**parameters**, inside a single `vaRenderPicture()` call:

```
SaveSliceData:     size=11544 slice_params=0
SetSliceParameter: size=40 n=1 rem=0        (88us later)
```

`PackerAV1::SaveSliceData()` needs `slice_params.back()` for the payload's
offset and size. Finding none it returned 0 and **dropped the entire
bitstream**; the VPU was queued a 2-byte temporal delimiter and polled forever,
which presented as AV1 hanging at 0.0s. `vaRenderPicture()` imposes no ordering
within a call, so `RenderPicture` now applies the buffer list in two passes —
everything that is not slice data first, slice data second.

MEASURED: `Copy slice data buffer 2: size = 0 → 11508`, `bytesused 2 → 11510`.

**AV1 still does not decode after this.** The stall cause is now established
byte-for-byte: the driver queues `TD(2B) + 11,508B raw tile data`, whose tile
bytes are *identical* to the reference, while a decodable temporal unit needs
`TD + SEQUENCE_HEADER OBU (13B) + FRAME OBU (2B hdr + 20B frame header)` first.
The VPU is a stateful full-bitstream parser and cannot parse headerless tiles.
So this patch removes a real defect sitting in front of the missing-headers
problem; it does not solve it.

Regression check on this driver (`ea4a089d2843afc6`), VA-API vs software, 20
frames, `-hwaccel_output_format vaapi` + `hwdownload`, byte counts checked:

| Codec | Software | Hardware | md5 |
|---|---|---|---|
| H.264 1080p | 62,208,000 B | 62,208,000 B | `4091e415…` identical |
| VP9 720p | 27,648,000 B | 27,648,000 B | `79575f2f…` identical |

### Known remaining defects in this area (not fixed here)

- **P010 is selected for 8-bit AV1.** `IS_10BIT_PROFILE` (`device_common.h:62`)
  includes `VAProfileAV1Profile0`, so every AV1 stream takes the P010 branch of
  the no-render-target fallback in `CreateContext()`. MEASURED: plane 0 length
  1,843,200 = 1280×720×2. A fix must be bit-depth-aware — a blanket NV12 would
  break genuine 10-bit fallbacks (HEVC Main10, VP9 Profile2). For reference
  `av1_v4l2m2m` negotiates **YU12**, not NV12.
- **Silent `return 0` guards.** `SetPicParamBuffer` drops the frame-header OBU
  with no log output at any level when no CIX Ext is present; `SaveSliceData`
  has two silent returns. `CheckIntegrity()` does not catch the empty-payload
  case, because the zero-size block still increments `tiles_copied` — which is
  precisely how the 2-byte temporal unit passed integrity and got queued.

### Operational notes

VA-API through ffmpeg on this board needs `LIBVA_DRIVER_NAME=libcix_va` and
`-init_hw_device vaapi=va:/dev/dri/renderD128`; the default probe fails with
`Device creation failed: -12`. Use `/usr/bin/ffmpeg` — the local
`/root/ffbuild/ffmpeg-8.1.2/ffmpeg` build has no hwaccels (v4l2m2m only).
The driver already ships a bitstream dump facility: `CIX_VAAPI_DUMP_BITS=1`.

## `0004-vp8-groundwork-and-buffer-types.diff` + `packer_vp8.{cpp,h}`

**Incomplete — VP8 does not decode yet.** Landed because the pieces are correct
and the remaining failure is better debugged from here than from scratch.

What was found: VP8 was never a missing-hardware problem. mvxdec exposes
`vp8_profile 0x00990aff`, the driver already mapped
`V4L2_CID_MPEG_VIDEO_VP8_PROFILE` to `VAProfileVP8Version0_3`, and
`IS_VP8_PROFILE` already returned `V4L2_PIX_FMT_VP8`. The enumeration call was
simply commented out:

```c
// EnumProfiles(V4L2_CID_MPEG_VIDEO_VP8_PROFILE, false);
```

presumably because no packer existed.

This adds:

- **`PackerVP8`** — modelled on `PackerVP9`, which is effectively a passthrough
  since the stateful VPU parses whole frames itself. VP8 needs no
  show_existing_frame/superframe handling (it has no hidden frames), but it does
  honour `slice_data_offset`, which the VP9 path ignores.
- **`VAProbabilityBufferType` / `VAHuffmanTableBufferType` accepted.** VP8
  clients send the entropy-probability buffer (type 13); `ApplyBufferData()` had
  no case for it and returned `VA_STATUS_ERROR_INVALID_PARAMETER`, so the stream
  was rejected outright:
  ```
  Failed to create parameter buffer (type 13): 18 (invalid parameter)
  ```
  A stateful decoder re-parses the frame header, so these carry nothing the
  hardware needs. `VAHuffmanTableBufferType` is included for the same reason and
  will be needed by any future JPEG work.
- **Unhandled buffer types are now logged** rather than failing silently — the
  original returned an error with no indication which type was refused.

**Status: VP8 enumerates and the stream is accepted, but decode produces zero
bytes.** The profile is therefore left **withheld** (`EnumProfiles` still
commented out) so clients fall back to software cleanly instead of selecting a
path that yields nothing — the same reasoning as the AV1 gate. Re-enable the one
line when decode works.

No regressions: H.264, VP9 and HEVC remain bit-exact against software decode
with byte counts checked.
