# Hardware video decode — release notes

NCZ-OS 26.7 ("Maximilian"), CIX Sky1 / Radxa Orion O6.

## Credit

The V4L2-M2M hardware video decode work on this platform originates with
**entrpi** (`entrpi@proton.me`), who maintained the **Sky1-Linux** distribution.
That project is no longer developed. NCZ stewards this work now: carrying it
forward, rebasing it onto current sources, fixing what version drift broke, and
submitting upstream what belongs upstream.

Specifically entrpi's:

- the **FFmpeg `av1_v4l2m2m` decoder**, which does not exist in upstream FFmpeg
  or in Debian's `libavcodec` — the only route to AV1 hardware decode on this
  hardware
- the Firefox V4L2-M2M patches: preferring V4L2 over VA-API, the stateful
  decoder timestamp fix, and the AV1 hardware-decode gate bypass

Full attribution, including which parts are NCZ's and which weaknesses our
rebases introduced, is in `upstream-patches/PROVENANCE.md`.

## What works

| Codec | Chrome | Vivaldi | Our Chromium | Notes |
|---|---|---|---|---|
| H.264 | ✅ | ✅ | ✅ | bit-exact vs software |
| VP9 | ✅ | ✅ | ✅ | bit-exact vs software |
| HEVC | ✅ | ✅ | ✗ | bit-exact vs software (VA-API) |
| AV1 | software | software | ✅ | hardware only via V4L2 |

Chrome and Vivaldi reach the VPU through **VA-API** (`cix_vaapi`); our own
Chromium build uses **V4L2-M2M** directly. AV1 is the one codec that works
only on the V4L2 path, so only the browser we compile ourselves accelerates it.
Chrome and Vivaldi fall back to dav1d software decode for AV1, which plays
correctly.

"Bit-exact" means byte-count-checked identical output against software decode,
not an open device node and not a log line — both of which produced false
positives during this work.

## Why we maintain our own forks

Three components are carried as NCZ builds rather than distro packages. Each has
a specific reason, and each is intended to stop being a fork.

### FFmpeg

Upstream FFmpeg has **no AV1 V4L2-M2M decoder**. Debian's `libavcodec.so.62`
ships `h263/h264/hevc/mpeg1/mpeg2/mpeg4/vc1/vp8/vp9_v4l2m2m` and no AV1. Without
our build there is no AV1 hardware decode on this platform at all.

entrpi's patch is prepared for `ffmpeg-devel` submission with their authorship
intact (`upstream-patches/ffmpeg/`). Expect a long wait: of 30 `v4l2_m2m`
patches on FFmpeg patchwork since 2022, most remain in `new` state, including a
2023 resolution-change fix and a 2025 segfault fix. The fork is the plan, not a
stopgap.

Scope note: these are ffmpeg *decoders*, not hwaccels, so nothing selects them
automatically. MEASURED — mpv with `--hwdec=auto` sees `av1_v4l2m2m` in our
library and still never opens the VPU. Applications must request the decoder by
name. Our FFmpeg is therefore a **dependency for Firefox AV1**, not a blanket
improvement for every media application.

### Chromium

Debian's arm64 Chromium is built `use_vaapi=false use_v4l2_codec=true`, and its
V4L2 path dies on the Arm proprietary `Y0A8` capture format
(`GPU process exited unexpectedly: exit_code=133`). It cannot use any of this
work — it needs a rebuild, not a flag.

Our build also required fixing four defects in Chromium's V4L2-only
configuration, which upstream CI evidently does not exercise: AV1 hardware
decode gated to VA-API in `args.gni`, a missing `base/logging.h`, the mvxdec
coded-size negotiation, and stateful HEVC missing from the profile-control map.
Three are clean upstream candidates (`upstream-patches/chromium/`).

Launching it needs `--enable-features=AcceleratedVideoDecoder` — upstream
disables hardware decode by default when `USE_VAAPI` is off.

### Firefox

Debian's `firefox-esr` has no V4L2-M2M support. entrpi's patches target Firefox
146; we run ESR 140, which lacks the code they extend, so three rebase patches
are ours (`upstream-patches/firefox/`).

**Status: not yet delivering hardware decode.** Firefox routes to its bundled
`ffvpx` software decoder, and its hardware-decode gate keys on VA-API-derived
`gfxVars` that are false on a V4L2-only platform, so `InitV4L2Decoder()` was
never reached for any codec. A fix extending entrpi's AV1-only gate bypass to
H.264/VP8/VP9/HEVC is built but unverified at time of writing.

## Known issues

- **AV1 in Chrome and Vivaldi is software-only.** The VA-API driver cannot
  assemble a decodable AV1 bitstream: it queues tile data with the sequence
  header and frame header OBUs absent, and the VPU is a stateful full-bitstream
  parser. Establishing this took a byte-for-byte comparison against the working
  V4L2 path. Fixing it needs an AV1 uncompressed-header writer — realistically
  1,000+ lines whose only consumers are closed browser binaries. Deliberately
  deferred. AV1 is withheld from the driver's advertised profiles so clients
  fall back cleanly rather than freezing.
- **HEVC does not work in our Chromium build.** Codec enumeration is fixed but
  decode fails with `PIPELINE_ERROR_DECODE` before reaching the V4L2 decoder.
  HEVC works in Chrome and Vivaldi via VA-API.
- **VLC, mpv and GStreamer are unverified.** They use the same VA-API driver
  that is bit-exact for three codecs, so they should work — but "should" is not
  measured, and unmeasured assumptions produced several wrong conclusions during
  this work.

## Upstreaming

| Recipient | What | Author |
|---|---|---|
| FFmpeg | AV1 V4L2-M2M decoder | **entrpi** |
| Chromium | `args.gni` AV1 gating, missing include, HEVC map entry | NCZ |
| CIX | `cix_vaapi` config/export/surface, HEVC SPS, AV1 ordering | NCZ |
| mvxdec | coded-size self-contradiction | NCZ |
| Debian | bug report: arm64 Chromium ships without VA-API | NCZ |

Chrome and Vivaldi take no patches — closed binaries that consume the driver
fixes.
