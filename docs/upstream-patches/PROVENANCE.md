# Provenance and attribution — CIX Sky1 media stack

NCZ-OS inherits a substantial body of CIX Sky1 (Radxa Orion O6) enablement work
from **entrpi** (`entrpi@proton.me`), who maintained the **Sky1-Linux**
distribution. That project is no longer developed. NCZ now stewards this work:
carrying it forward, rebasing it onto current sources, fixing what version drift
broke, and upstreaming what belongs upstream.

This file records who wrote what, so credit stays attached as the code moves.

## Principles

1. **entrpi's authorship is preserved.** Their patches keep their `From:` and
   `Subject:` headers. Where we rebase one, the rebase is a *separate* patch
   attributed to us, and the original is left untouched — see
   `firefox/0001-v4l2m2m-vp9-av1-esr140.patch`.
2. **Upstream submissions credit the original author.** Anything of entrpi's
   that goes upstream goes with their authorship, and where possible we ask
   whether they would rather submit it themselves.
3. **We do not claim their work, and we do not blame them for our rebases.**
   Where a rebase changes behaviour, that deviation is documented as ours.

## Inherited from Sky1-Linux (entrpi)

Archived from the defunct Sky1-Linux repositories to
`argonas:/mnt/datapool/git/sky1-linux-archive/` — 21 repositories, 14 GB.

### Firefox — `firefox/`

Three patches carried unmodified:

| Patch | What it does |
|---|---|
| `Prefer-V4L2-M2M-over-VAAPI-for-hw-decode.patch` | tries V4L2-M2M before VA-API in `InitHWDecoderIfAllowed()` |
| `Fix-V4L2-M2M-timestamp-handling.patch` | V4L2 stateful decoders don't set PTS/duration on output frames |
| `Enable-V4L2-M2M-AV1-hardware-decode-check.patch` | bypasses the VA-API-derived `gfxVars::UseAV1HwDecode()` gate for AV1 |

Written against **Firefox 146** (`firefox (146.0-1+v4l2m2m.2)`).

### FFmpeg — AV1 V4L2-M2M decoder

entrpi's addition of `av1_v4l2m2m`, absent from upstream FFmpeg. Three sites:

```
libavcodec/v4l2_m2m_dec.c   M2MDEC(av1, "AV1", AV_CODEC_ID_AV1, NULL);
libavcodec/allcodecs.c      extern const FFCodec ff_av1_v4l2m2m_decoder;
libavcodec/v4l2_fmt.c       AV1_FRAME and V4L2_PIX_FMT_AV1 ('AV01') mappings
```

MEASURED: decodes bit-exactly against dav1d — 20 frames, 27,648,000 bytes, md5
`4e20cccbf7f5d6246b0a478338759645`.

This is the single highest-value inherited piece: Debian's `libavcodec.so.62`
ships `h263/h264/hevc/mpeg1/mpeg2/mpeg4/vc1/vp8/vp9_v4l2m2m` but **no AV1**, and
neither does upstream FFmpeg.

**Correction to carry upstream:** the in-tree comment reads *"CIX Sky1 VPU uses
custom AV01 fourcc for AV1 decode"*. That is wrong — `AV01` is the standard
kernel fourcc (`V4L2_PIX_FMT_AV1`, `videodev2.h:751`), alongside `AV1F`
(`V4L2_PIX_FMT_AV1_FRAME`, stateless). The CIX VPU is conforming, and the
mapping is generically useful rather than a vendor carve-out. Fix the comment
before submission.

## NCZ work

### Firefox — rebases and fixes (ours)

| Patch | Why |
|---|---|
| `0001-v4l2m2m-vp9-av1-esr140.patch` | rebase of entrpi's AV1 decoder patch onto ESR 140, which has no `FindVideoHardwareAVCodec()` — its V4L2 selection is a single hardcoded H.264 test |
| `0002-esr140-updatedecodetimes-signature.patch` | ESR 140's `UpdateDecodeTimes()` takes `const AVFrame*`; FF 146's takes an integer duration, so entrpi's timestamp patch did not compile |
| `0003-v4l2-gate-all-codecs.patch` | extends entrpi's AV1-only `gfxVars` bypass to H.264/VP8/VP9/HEVC — those gates are VA-API-derived and false on a V4L2-only platform, so `InitV4L2Decoder()` was never reached for any codec |

**Deviation to note on 0002:** entrpi fed the *corrected* duration (sample
duration when the V4L2 frame's is invalid) into the decode-time statistics. ESR
140's signature cannot accept that, so the correction still reaches
`CreateImageV4L2` — which affects playback — but the statistics fall back to
`Duration(mFrame)`, the value known to be invalid. Those statistics drive the
"HW decoding is slow, switching back to SW decode" heuristic, so a bogus value
could cause spurious fallback. This is a known weakness of our rebase, not of
entrpi's original.

### Chromium — `chromium/`

Ours, built on no prior Sky1-Linux work. Four defects in the V4L2-only
configuration, which upstream CI evidently does not exercise: `args.gni` AV1
gating, a missing `base/logging.h`, the mvxdec coded-size negotiation, and the
stateful HEVC profile-control map entry.

### cix_vaapi — `cix-vaapi/`

Ours. Config attributes, surface export layering, the export-before-decode
buffer bug (flat green frames), the HEVC SPS bit-width error, and AV1 buffer
ordering.

## Upstream routing

| Recipient | What | Author credited |
|---|---|---|
| FFmpeg (`ffmpeg-devel`) | AV1 V4L2-M2M decoder | **entrpi** |
| Chromium (Gerrit) | `args.gni`, `base/logging.h`, HEVC map entry | NCZ |
| CIX (`cix_vaapi`) | config/export/surface, HEVC SPS, AV1 ordering | NCZ |
| mvxdec (kernel) | coded-size self-contradiction | NCZ |
| Debian | bug report: arm64 Chromium ships without VA-API | NCZ |
| Mozilla | V4L2 gating, if it survives review | entrpi + NCZ |

Debian is **not** the right recipient for the AV1 FFmpeg decoder — they build
stock upstream FFmpeg, and asking them to carry a downstream delta is the wrong
request. Upstream first; Debian inherits it.

Chrome and Vivaldi receive nothing: closed prebuilt binaries that consume the
driver fixes.

## Open question

Whether entrpi wishes to submit the FFmpeg AV1 decoder themselves. Preferred
over us upstreaming their code on their behalf. Worth asking before we send it.
