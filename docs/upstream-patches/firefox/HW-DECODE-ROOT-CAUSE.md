# Firefox hardware decode on CIX Sky1 — root cause

Firefox decoded all five codecs in software while our Chromium did all five on
the VPU. The V4L2 patches were applied, `MOZ_ENABLE_V4L2` was set, and libxul
carried `av1_v4l2m2m`/`hevc_v4l2m2m` — yet `InitV4L2Decoder()` never ran.

Pref-level guessing did not find it. Forcing the GPU process, disabling the RDD
and Utility processes, `media.prefer-non-ffvpx`, `media.ffvpx-hw.enabled` and
disabling the media sandboxes all failed, and none produced a diagnostic.

## Why the logs were useless

`FFmpegVideoDecoder`'s own `FFMPEG_LOG` output never reached `MOZ_LOG_FILE`,
even at `PlatformDecoderModule:5`, while the base class's `ProcessDecode` lines
from the same process did. Four runs produced twelve debug lines total and not
one from the decoder itself.

So the instrumentation deliberately does **not** use MOZ_LOG. `fprintf(stderr)`
tagged `NCZDBG` cannot be filtered by a log module, a level, or a child
process's log plumbing — the channel under investigation cannot also be the
instrument.

## What it showed

Stock prefs:

```
NCZDBG ctor mime=video/avc codecid=27 libav=62 rdd=1 gpu=0 hwdisabled=1
NCZDBG gate=no-hw-webrender allocator=1 backend=1 swwr=1
NCZDBG InitHWDecoderIfAllowed entry disabled=1 libav=62
```

- The decoder **is** the OS-library ffmpeg62 build (`libav=62`), **in the RDD
  process** (`rdd=1`), so the `XRE_IsRDDProcess()` gate passed.
- **Our codec-gate patch worked** — no `gate=codec-not-accelerated`.
- It died at `gate=no-hw-webrender` with `swwr=1`: Firefox was running
  **software WebRender**, which disables hardware video decode outright, before
  V4L2 is ever reached.

The decoder was never the problem.

## Two defects, not one

**1. Software WebRender was on by default.** With
`gfx.webrender.software=false` and `gfx.webrender.all=true`:

```
NCZDBG ctor ... hwdisabled=0
NCZDBG reached V4L2 init
NCZDBG InitV4L2Decoder rv=0x0 ok=1      <- V4L2 initialises successfully
```

**2. The decoder that performs playback has no image allocator.** Immediately
after the successful one, two more decoders are constructed:

```
NCZDBG ctor ... hwdisabled=1
NCZDBG gate=no-hw-webrender allocator=0 backend=-1 swwr=-1
```

`mImageAllocator == nullptr`, so the first clause of `isHardwareWebRenderUsed`
is false for it regardless of the compositor. `/dev/video0` is never held and
playback lands in software with 150 frames decoded and 0 dropped.

## The patch

The hardware-WebRender requirement is a VA-API constraint: that path returns
DMABuf surfaces only a hardware compositor can import. V4L2-M2M returns
ordinary buffers and has no such dependency. Under `MOZ_ENABLE_V4L2` the gate
falls through to the V4L2 probe, which is the only check that can actually
answer whether the hardware will take the stream.

## Result of the gate relaxation: still software

Built and tested on O6N. V4L2 initialises, and playback still falls back:

```
NCZDBG ctor ... hwdisabled=0
NCZDBG reached V4L2 init
NCZDBG InitV4L2Decoder rv=0x0 ok=1
NCZDBG ctor ... hwdisabled=1        <- second decoder, no gate of ours fired
NCZDBG InitHWDecoderIfAllowed entry disabled=1
```

The second decoder reports `hwdisabled=1` with **no gate message**, so
`ShouldDisableHWDecoding` fell through to `return aDisableHardwareDecoding` -
the caller passed true. That is Firefox's own fallback path after a hardware
decoder fails. Dropped frames also went from 0 to 9, consistent with a failed
hardware attempt before the switch.

So the V4L2 decoder initialises successfully and then fails at decode time.
`/dev/video0` is never held for a sustained period.

## The actual blocker: ffmpeg, not Firefox

Instrumenting the decode path found it on the first frame.

```
NCZDBG frame-path hwaccel=1 usingV4L2=1
NCZDBG v4l2-desc nb_objects=1246381896 nb_layers=1364283729
       layer0_fourcc=0x51515151 nb_planes=1364283729 w=1920 h=1080 avformat=23
NCZDBG v4l2-no-surface w=1920 h=1080
NCZDBG CreateImageV4L2 frame=0 rv=0x806e0004 ok=0
```

`layer0_fourcc=0x51515151` is `'QQQQ'` - uninitialised memory, not a fourcc.
`avformat=23` is **`AV_PIX_FMT_NV12`, not `AV_PIX_FMT_DRM_PRIME`**.

`CreateImageV4L2` casts `mFrame->data[0]` to an `AVDRMFrameDescriptor`. The
frame is a plain NV12 CPU frame, so the cast reads pixel data as a struct,
every field is garbage, dmabuf surface allocation fails, and the resulting
`NS_ERROR_DOM_MEDIA_DECODE_ERR` is what MediaFormatReader turns into
`mHardwareDecodingDisabled = true`.

Firefox is not at fault. `ChooseV4L2PixelFormat` correctly asks for DRM_PRIME
and returns `AV_PIX_FMT_NONE` otherwise; it never gets offered DRM_PRIME:

- Debian's `libavcodec.so.62`: **zero** occurrences of DRM_PRIME.
- `ffmpeg -h decoder=h264_v4l2m2m` advertises only `num_output_buffers` and
  `num_capture_buffers`.
- In the FFmpeg 8.1.2 source tree, `v4l2_m2m_dec.c`, `v4l2_buffers.c` and
  `v4l2_context.c` contain no `DRM_PRIME`, no `AVDRMFrameDescriptor` and no
  DRM export path. The only decoders in the whole of `libavcodec` that produce
  `AV_PIX_FMT_DRM_PRIME` are `rkmppdec` / `rkmppenc` (Rockchip).

So **FFmpeg 8.x's V4L2-M2M wrapper cannot produce DRM_PRIME frames at all**,
and Firefox's V4L2 path is written against one that can. No combination of
prefs or Firefox patches can bridge that: the frames simply are not dmabufs.

## What would actually fix it

Restore DRM_PRIME export to `v4l2_m2m` in the ffmpeg fork we already maintain
for `av1_v4l2m2m`. The decoder must export its capture buffers as dmabuf and
hand back an `AVDRMFrameDescriptor`, which is what `CreateImageV4L2` expects.

That is real C work in libavcodec, not a Firefox patch, and it is the only
route to hardware decode in Firefox on this platform.

Chromium is unaffected - it drives V4L2 directly rather than through ffmpeg,
and does all five codecs at 1080p and 4K.
