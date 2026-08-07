# Supported video codec matrix — CIX Sky1

NCZ-OS 26.7 on Radxa Orion O6 (CIX Sky1, Arm Linlon MVE VPU).
Driver `cix_vaapi` build `9aa21698`.

## Summary

| Codec | Chrome | Vivaldi | **Chromium NCZ Sky1** | Chromium (Debian) | Firefox ESR |
|---|---|---|---|---|---|
| **H.264** | ✅ hardware | ✅ hardware | ✅ hardware | ✗ | software |
| **VP9** | ✅ hardware | ✅ hardware | ✅ hardware | ✗ | software |
| **HEVC** | ✅ hardware | ✅ hardware | ✅ hardware | ✗ | software |
| **AV1** | software | software | ✅ **hardware** | ✗ | software |
| VP8 | software | software | software | ✗ | software |

**"software" means it plays correctly, just on the CPU.** Nothing in this table
fails to render — the difference is power draw and headroom at high resolution.

**Chromium NCZ Sky1 Edition is the only browser on this platform with hardware
AV1.** That is the reason it exists.

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
