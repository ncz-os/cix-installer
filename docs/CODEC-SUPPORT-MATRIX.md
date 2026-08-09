# Supported video codec matrix — CIX Sky1

NCZ-OS 26.7 on Radxa Orion O6 (CIX Sky1, Arm Linlon MVE VPU).
Driver `cix_vaapi` build `9aa21698`.

## Summary

Measured 2026-08-08 at both 1080p and 4K (3840x2160), five codecs, two
resolutions, per browser.

| Codec | Chromium NCZ Sky1 1080p | Chromium NCZ Sky1 4K | Firefox NCZ Sky1 | Chrome | Vivaldi |
|---|---|---|---|---|---|
| **H.264** | ✅ hardware | ✅ hardware | software | ✅ hardware | ✅ hardware |
| **HEVC** | ✅ hardware | ✅ hardware | software | ✅ hardware | ✅ hardware |
| **VP8** | ✅ hardware | ✅ hardware¹ | software | software | software |
| **VP9** | ✅ hardware | ✅ hardware | software | ✅ hardware | ✅ hardware |
| **AV1** | ✅ **hardware** | ✅ **hardware** | software | software | software |

¹ Needed a driver fix. See "VP8 at 4K" below.

Debian's own Chromium and Firefox are no longer shipped — they are replaced by
`chromium-ncz-sky1` and `firefox-ncz-sky1`.

**"software" means it plays correctly, just on the CPU.** Nothing in this table
fails to render — the difference is power draw and headroom at high resolution.

**Chromium NCZ Sky1 Edition is the only browser on this platform with hardware
decode for all five codecs, at 1080p and 4K.** That is the reason it exists.
It needs `--enable-features=AcceleratedVideoDecoder`, which its launcher
passes; without that flag every codec silently decodes in software.

### Hardware baseline

Before any browser is judged, the driver itself was measured. All five codecs
decode **bit-exact against software** at both 1080p and 4K:

| Codec | 1080p | 4K |
|---|---|---|
| H.264 | bit-exact | bit-exact |
| HEVC | bit-exact | bit-exact |
| VP8 | bit-exact | bit-exact |
| VP9 | bit-exact | bit-exact |
| AV1 | bit-exact* | bit-exact* |

\* AV1 requires the patched ffmpeg carrying `av1_v4l2m2m`; stock Debian ffmpeg
8.1.2 has no AV1 V4L2 decoder. That patch is submitted upstream and it holds at
4K.

So every browser cell that reads "software" is a browser-side gap, not a
hardware one.

### VP8 at 4K

Chromium fell back to software for 4K VP8 while ffmpeg decoded the same clip on
the VPU bit-exact. The cause was the driver: `VIDIOC_ENUM_FRAMESIZES` reported
VP8 as 2048x2048 because the vendor code grouped it with H.263 and MPEG-4.
Chromium honours the enumeration; ffmpeg does not consult it.

Measured ceiling is 4096x4096 (5120x2880 fails). Fixed in
`docs/upstream-patches/cix-vpu-driver/0001-vp8-decode-framesize-4096.patch`;
Chromium then decodes 4K VP8 on the VPU.

### Epiphany / WebKitGTK

Added 2026-08-08. WebKitGTK routes media through GStreamer, whose V4L2 support
is mature where ffmpeg's was absent entirely - GStreamer already ships
`v4l2h264dec`, `v4l2h265dec`, `v4l2vp8dec`, `v4l2vp9dec` and `v4l2av1dec` on
this board.

All of them were dead until the driver's decoder capture default was changed
from AFBC to NV12 (`docs/upstream-patches/cix-vpu-driver/0002-*`). No browser
patching was required.

| Codec | 1080p | 4K |
|---|---|---|
| H.264 | ✅ hardware | ✗ media error 4 |
| HEVC | ✅ hardware | ✅ hardware |
| VP8 | software | software |
| VP9 | ✗ stalls | ✗ stalls |
| AV1 | ✅ **hardware** | ✅ **hardware** |

Verified by `/dev/video0` held by WebKitWebProcess during playback, with the
clip running to completion (`currentTime` reaching 5s, `readyState` 4,
`error` null). Note WebKit does not implement
`getVideoPlaybackQuality()`, so decoded-frame counts always read 0 and cannot
be used as the signal here.

VP8 and VP9 fail identically at the GStreamer command line, so those are
GStreamer/driver issues rather than WebKit ones. H.264 at 4K fails while HEVC
at 4K succeeds, which is not yet explained.

### Firefox

Firefox NCZ Sky1 Edition decodes all five codecs correctly, all in software.
`MOZ_ENABLE_V4L2` is set in the build and libxul carries the V4L2 decoder
symbols, but at runtime decoding lands in the RDD or Utility process and
`InitV4L2Decoder()` is never entered. Forcing the GPU process,
`media.prefer-non-ffvpx`, `media.ffvpx-hw.enabled` and disabling the media
sandboxes each failed to move it. Unresolved.

## Decode path

Chrome and Vivaldi are prebuilt binaries that use **VA-API**, so they benefit
from the `cix_vaapi` driver without any browser-side change. Our Chromium uses
**V4L2-M2M** directly.

AV1 splits along exactly that line: it works over V4L2-M2M and not over VA-API,
so no prebuilt VA-API browser can reach it. See "Why AV1 differs" below.

## What was measured

Browser cells: the browser held `/dev/video*` during playback **and** rendered a
correct moving picture, confirmed by the test clip's burnt-in frame counter
advancing across captures. Chrome H.264 at 27.4s/1920x1080, Chrome HEVC at
7.5s/1280x720, and so on.

Driver-level decode was additionally verified **bit-exact against software
decode**, 20 frames, byte counts checked as well as checksums:

| Codec | Software | Hardware | md5 |
|---|---|---|---|
| H.264 1080p | 31,104,000 B | 31,104,000 B | identical |
| VP9 720p | 13,824,000 B | 13,824,000 B | identical |
| HEVC 720p | 13,824,000 B | 13,824,000 B | identical |
| HEVC Main10 | 27,648,000 B | 27,648,000 B | identical |
| AV1 720p (V4L2) | 27,648,000 B | 27,648,000 B | identical |

An open device node is *not* treated as evidence — it accompanied flat green
frames throughout development. Neither is a player's "using hardware decoding"
log line, which mpv printed for HEVC while producing zero output.

## Why AV1 differs

The CIX VPU decodes AV1 correctly — `av1_v4l2m2m` output is bit-exact against
libdav1d. The gap is in the VA-API driver, which cannot assemble a decodable AV1
bitstream: it queues tile data with the sequence-header and frame-header OBUs
absent, and the VPU is a stateful full-bitstream parser. Establishing that took
a byte-for-byte comparison against the working V4L2 path.

Closing it needs an AV1 uncompressed-header writer — realistically 1,000+ lines,
whose only beneficiaries are closed browser binaries. Deferred deliberately.

AV1 is therefore **withheld from the driver's advertised profiles**, so Chrome
and Vivaldi fall back to dav1d cleanly rather than selecting a hardware path
that never produces a frame.

## Known gaps

- **VP8** — the VPU supports it and the driver groundwork is in place (packer,
  probability-buffer handling), but decode yields nothing yet. The profile is
  withheld rather than advertised-and-broken.
- **Debian's Chromium cannot use any of this.** It is built `use_vaapi=false
  use_v4l2_codec=true` on arm64 and its V4L2 path fails on the Arm proprietary
  `Y0A8` capture format (`GPU process exited unexpectedly: exit_code=133`). It
  needs a rebuild, not configuration.
- **Firefox decodes in software for every codec.** Its hardware path is gated on
  VA-API-derived `gfxVars` that are false on a V4L2-only platform, so its V4L2
  decoder is never reached. A fix exists but is unverified; Firefox is shipped
  unmodified for now.
- **VLC, mpv and GStreamer are unverified.** They use the same VA-API driver
  that is bit-exact for three codecs, so they are expected to work — but that is
  an expectation, not a measurement.
- **10-bit** is verified for HEVC Main10 only. H.264 High10 and VP9 Profile2 are
  advertised but untested.

## Launch requirements

Chrome and Vivaldi need Wayland ozone — under X11 ozone, VA-API initialisation
fails on this platform for every Chromium-family browser:

```
google-chrome  --ozone-platform=wayland
vivaldi-stable --ozone-platform=wayland
```

Chromium NCZ Sky1 Edition's launcher applies its own required flags
(`--ozone-platform=wayland --enable-features=AcceleratedVideoDecoder`);
upstream disables hardware decode by default in builds without VA-API.
