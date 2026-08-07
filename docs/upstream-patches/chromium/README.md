# Chromium V4L2 hardware video decode — CIX Sky1

Against Chromium **151.0.7922.75**, built arm64 with:

```
use_v4l2_codec = true
use_vaapi      = false
use_linux_v4l2_only = true
chrome_pgo_phase = 0        # profiles not checked out in .gclient
```

`0001-v4l2-av1-and-mvxdec-coded-size.patch` covers `media/gpu/`. Two build-env
fixes live outside it and are described below.

## Result

**AV1 720p and H.264 1080p both decode in hardware and render correctly** on a
Radxa Orion O6 (Arm Linlon MVE / `mvxdec`, `/dev/video0`), Wayland ozone.
Verified by picture plus motion — the burnt-in frame counter advancing and
successive screenshots differing — not by an open `/dev/video*` fd, which
accompanied broken output repeatedly during this work.

Launch needs `--enable-features=AcceleratedVideoDecoder`: upstream
`kAcceleratedVideoDecodeLinux` is `DISABLED_BY_DEFAULT` when `USE_VAAPI` is off,
so a V4L2-only build silently uses software without it.

## What the patch fixes

### 1. `media/gpu/args.gni` — AV1 hw decode excluded V4L2

```
-      is_chromeos || (is_linux && use_vaapi) || is_win || is_apple
+      is_chromeos || (is_linux && (use_vaapi || use_v4l2_codec)) ||
+      is_win || is_apple
```

Without this a V4L2 build gets no AV1 decoder at all.

### 2. `hardware_video_decoding_sandbox_hook_linux.cc` — missing include

Uses `LOG(ERROR)` but never includes `base/logging.h`; it compiles by default
only because `media/gpu/vaapi/vaapi_wrapper.h` pulls logging in transitively,
and that include sits behind `#if BUILDFLAG(USE_VAAPI)`. With `use_vaapi=false`:

```
error: use of undeclared identifier 'ERROR'
```

### 3. `v4l2_stateful_video_decoder.cc` — mvxdec coded-size negotiation

The real interop bug. `InitializeCAPTUREQueue()` aborted for every codec:

```
AV1   1280x720 : adjusted 1280x720  vs chosen 1280x728
H.264 1920x1080: adjusted 1920x1080 vs chosen 1920x1084
```

mvxdec's self-contradiction, established by direct probing:

- `G_FMT` advertises coded size **1920x1084**
- `G_SELECTION` gives visible rect **(0,4 1920x1080)** — rows 4..1084
- `S_FMT` at 1084 **or** at a macroblock-aligned 1088 both return **1080**
- on a *fresh* fd, `S_FMT` returns exactly what is asked (1080→1080,
  1084→1084, 1088→1088) — the clamp only appears once a stream is configured

So it advertises a visible rect it will not allocate rows to back. Three
layered changes, each uncovered by the previous one:

1. Require the returned size to contain the **visible rect** rather than the
   driver's bookkeeping coded size.
2. If that fails, retry `S_FMT` with a 16-aligned size covering the visible
   rect (ruled out "just ask for more" — the driver still clamps).
3. If it *still* fails only because of the rect's **origin**, drop the origin to
   (0,0). A rect too large even at the origin remains a hard error.

Step 1 is what surfaced the actual fault: it refused to proceed rather than
silently decoding into an undersized buffer.

**Why dropping the origin is defensible:** a 1080p stream is normally coded 1088
with the crop at (0,0), and ffmpeg's `av1_v4l2m2m` drives this same device to
output that is **bit-exact against dav1d** (20 frames, 27,648,000 bytes, md5
`4e20cccbf7f5d6246b0a478338759645`). The 4-row offset is almost certainly
spurious. This is a workaround for a driver bug, not a correct general fix — if
a stream legitimately needs a non-zero origin, output would shift by that
offset. It only fires when the driver cannot back the origin at all.

## Build-environment fixes (not in the patch)

**Sysroot kernel headers.** Chromium's bundled Debian Bullseye sysroots predate
the V4L2 AV1 controls, so `use_av1_hw_decoder` fails to compile:

```
error: incomplete result type 'struct v4l2_ctrl_av1_sequence'
error: use of undeclared identifier 'V4L2_CID_MPEG_VIDEO_AV1_PROFILE'
```

Copy `linux/v4l2-controls.h` and `linux/videodev2.h` from a ≥6.0 kernel into
`build/linux/debian_bullseye_{amd64,arm64,i386}-sysroot/usr/include/linux/`.
**All three** — the `clang_x64_v8_arm64` host toolchain uses the amd64 sysroot,
so patching only arm64 fails later in the build.

**PGO.** `is_official_build=true` wants profiles that `.gclient` does not fetch;
set `chrome_pgo_phase = 0`.

## Upstream relevance

Five separate defects in the V4L2-only desktop Linux configuration — AV1 gating,
sysroot headers, the missing include, and the coded-size negotiation. That
configuration is evidently not exercised by upstream CI. Items 1 and 2 are
clean upstream candidates; item 3 is arguably a driver bug in `mvxdec` and
should be raised there too.

## Not verified

Pixel-exact correctness. Motion and a sane picture are confirmed; a byte-count-
checked bit-exact comparison against software decode has **not** been run for
the browser path. VP9 through this build is untested.

## 4. `v4l2_utils.cc` — stateful HEVC absent from the profile-control map

`kV4L2CodecPixFmtToProfileCID` lists both the stateful and stateless pixel
formats for H.264, VP8, VP9 and AV1, but only `V4L2_PIX_FMT_HEVC_SLICE` for
HEVC. A stateful decoder advertising `V4L2_PIX_FMT_HEVC` — as mvxdec does, and
it exposes `hevc_profile 0x00990b67` (`V4L2_CID_MPEG_VIDEO_HEVC_PROFILE`) —
never matches, so no HEVC profiles are enumerated and Chromium rejects the codec
outright: `canPlayType` returns empty and the video element reports `0x0`.

Adding `{V4L2_PIX_FMT_HEVC, V4L2_CID_MPEG_VIDEO_HEVC_PROFILE}` alongside the
slice entry matches what every other codec in the table already does.

MEASURED effect: `canPlayType("video/mp4; codecs=hvc1.1.6.L93.B0")` goes from
unsupported to `probably`, and the pipeline now attempts decode.

**HEVC still does not decode in this build** — it fails with
`PIPELINE_ERROR_DECODE` and *zero* `media/gpu/v4l2` errors, i.e. it gives up
before reaching the V4L2 decoder. This entry fixes codec enumeration only; the
remaining failure is unresolved. Note HEVC *does* decode bit-exactly through the
VA-API path (see `../cix-vaapi/`), so this affects only the V4L2 build.
