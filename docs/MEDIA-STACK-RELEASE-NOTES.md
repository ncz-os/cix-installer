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

### Browsers we ship

**Chromium NCZ Sky1 Edition** (`chromium-ncz-sky1`) is the default browser and
the only one that reaches the Sky1 VPU. It is built with `use_v4l2_codec=true`
and decodes **every codec the VPU supports — H.264, HEVC, VP8, VP9 and AV1 — in
hardware**.

**Google Chrome** is shipped alongside it for **DRM material only** (Widevine:
`/opt/google/chrome/WidevineCdm/_platform_specific/linux_arm64/libwidevinecdm.so`,
which our Chromium cannot have — the CDM is a proprietary Google binary and
cannot be built from source). **Chrome decodes in software on this platform.**

**Epiphany/WebKit is not shipped.** It could not use the VPU at all and could
not be made to perform; see "Why Epiphany was removed" below.

| Codec | Chromium NCZ Sky1 | Chrome | Notes |
|---|---|---|---|
| H.264 | ✅ hardware | software | |
| HEVC | ✅ hardware | software | see note on site availability |
| VP9 | ✅ hardware | software | |
| VP8 | ✅ hardware | software | |
| AV1 | ✅ hardware | software | hardware only via V4L2 |
| DRM (Widevine) | ✗ | ✅ | Chrome only; Linux is Widevine **L3** |

Measured 2026-08-09 on rc7 by **checking which process holds an open fd on
`/dev/video*`** during playback (`fuser` on the five `mvx` nodes). Chromium NCZ
holds the VPU across H.264/HEVC/VP9/VP8/AV1 and on YouTube with zero crashes;
Google Chrome and Epiphany hold it **never**.

> **Do not measure this by counting `MVX session` lines in `dmesg`.** An earlier
> revision of this file did, claiming the driver logs one per decode session. It
> does not. Every such line is the warning `v4l2: Invalid frame period from
> client (1/30). Return 60/1`, which fires only when a client sets that specific
> frame period — so it counts a client quirk, not decode sessions. It reports
> zero for genuinely hardware-accelerated playback: a forced
> `v4l2h264dec ! waylandsink` pipeline ran to `Got EOS` with the VPU fd open and
> logged nothing. Use the fd check, or `chrome://media-internals` in a browser.

Corroborated independently by Chromium's own `chrome://media-internals` during a
real **Facebook** session, which is the browser reporting on itself rather than
us inferring from the kernel:

```
"kVideoDecoderName": "V4L2VideoDecoder"     (21 occurrences)
"kIsPlatformVideoDecoder": true
codecs: av1, vp9        errors: none
```

No software decoder appears anywhere in that log — no `FFmpegVideoDecoder`, no
`Dav1dVideoDecoder`, no `LibvpxVideoDecoder` — and no `PIPELINE_ERROR`. Note
Facebook served **AV1 and VP9** in that session, not H.264, so AV1 hardware
decode is not a synthetic-benchmark win: it is what a mainstream site actually
delivers, and it is the codec no other browser on this hardware accelerates.

Note on HEVC: it now decodes in hardware, but almost no site uses it. Facebook
and X are H.264 (Facebook adding AV1 on Reels), YouTube is VP9/AV1, and the
services that do use HEVC are DRM-gated — and Widevine on Linux is L3, which
caps streams to ~1080p H.264/VP9 and never delivers HEVC. HEVC's practical
value here is **local media playback**, not the web.

"Bit-exact" below means byte-count-checked identical output against software
decode, not an open device node and not a log line — both of which produced
false positives during this work.

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
- ~~**HEVC does not work in our Chromium build.**~~ **FIXED — re-measured
  2026-08-09 on rc7.** HEVC now engages the VPU in `chromium-ncz-sky1` (one new
  `MVX session` per playback run, same as every other codec). The old
  `PIPELINE_ERROR_DECODE` before reaching the V4L2 decoder no longer reproduces.
  Kept here rather than deleted because this file asserted the opposite for
  several releases.
- **GStreamer is verified accelerated; WebKit does not use it.** GStreamer
  itself selects a `v4l2*dec` element for all seven cases tested on rc7 (H.264
  1080p and 4K, HEVC, AV1, VP9 plain and colorimetry-tagged, VP8), each
  reaching `Got EOS`. But WebKit/Epiphany, which is a GStreamer client, never
  engaged the VPU: MVX sessions stayed at 3 across a full local `<video>`
  playback and no web process ever held `/dev/video*`. Accelerated GStreamer
  does not imply an accelerated GStreamer *application*.
- **VLC, mpv, ffplay and Celluloid decode in SOFTWARE, and are not cheaply
  fixable.** Verified 2026-08-09 by fd check: none ever opens `/dev/video*`.
  The cause is not a missing decoder — it is the VPU's capture format. The
  Linlon VPU accepts every codec on its output side (`H263 H264 HEVC MPG2 MPG4
  VP80 VP90 AV01`) but emits **only AFBC-compressed formats** on the capture
  side (`Y0A8`, `Y0AA`, `Y2A8`, `Y2AA`). FFmpeg's `v4l2_m2m` expects plain
  NV12/YUV420, so it probes every node and rejects each one:

  ```
  [h264_v4l2m2m] probing device /dev/video-cixdec0
  [h264_v4l2m2m] driver 'mvx' on card 'Linlon Video device' in mplane mode
  [h264_v4l2m2m] v4l2 output format not supported
  ```

  This is the same Y0A8 problem that defeats Debian's Chromium. Installing
  `ncz-ffmpeg` does NOT fix these players: its libraries load correctly and
  `av1_v4l2m2m` is present, but the AFBC rejection happens before any codec
  choice matters. Fixing them means teaching FFmpeg's `v4l2_m2m` to consume
  AFBC — a real patch, not a wrapper or an env var. `mpv` illustrates the trap:
  it *lists* `h264_v4l2m2m`, then logs `Using software decoding` and picks the
  software decoder anyway, even when named explicitly via `--vd`.

- **GStreamer players ARE accelerated, including our own.** Verified by fd
  check: `gst-launch playbin`, an explicit `v4l2h264dec ! waylandsink`
  pipeline, and **`singularity-videos`** each hold the VPU during playback.
  `singularity-videos` links GStreamer and no FFmpeg, which is why it works.
  So the shipped desktop video player is hardware-accelerated with no change
  required; the third-party FFmpeg players are the ones that are not.

## Why Epiphany was removed

Epiphany was slow and crashed on YouTube. Both symptoms had one cause, and it is
structural rather than a tuning problem.

WebKit's web process has no Wayland connection, so it renders through the
DMABUF/GBM path, and that path requires a DRM **render node**. On the Mali
backend the GPU is reached through `/dev/mali0` (`mali_kbase`) and is not a DRM
device at all. The only render nodes on Sky1 — `renderD128-130` — belong to
`linlondp`, the display controller, which cannot render. WebKit picked one
anyway, handed it to the CIX `libgbm` stub, and aborted:

```
Failed to create GBM device for DRM node: /dev/dri/renderD130
Could not create default EGL display: EGL_BAD_PARAMETER. Aborting...
```

That crashed `WebKitWebProcess` on every page load (five coredumps in ten
seconds). Because nothing ever painted, it presented as "the browser has no
network" — the network was fine throughout: gateway ping OK, DNS OK,
`curl https://www.gnome.org` returned HTTP 200.

Stripping `/opt/cixgpu-compat` stopped the crash (6 per page load to 0) but only
by falling back to software GL, and WebKit still never engaged the VPU. Software
GL plus software decode is not a browser worth shipping on this hardware, so
Epiphany is purged and `chromium-ncz-sky1` is the default.

The structural fix, if WebKit is ever wanted here, is **panthor**, which exposes
the GPU as a real DRM render node. `panthor.ko` is already built on rc7 as DKMS
but is not the booted backend.

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
