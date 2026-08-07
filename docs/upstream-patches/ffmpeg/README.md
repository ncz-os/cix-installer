# FFmpeg — AV1 V4L2-M2M decoder

`0001-avcodec-v4l2_m2m-add-AV1-decoder.patch`

Adds `av1_v4l2m2m`. **Authored by entrpi** (`entrpi@proton.me`) for Sky1-Linux;
NCZ forwards it upstream since that project is no longer developed and NCZ-OS
depends on the decoder shipping. The `From:` header preserves their authorship.

## Why it is not upstream already

Neither political nor architectural, as far as the evidence goes:

- **Not licensing.** AV1 is AOMedia royalty-free. Upstream already ships
  `h264_v4l2m2m` and `hevc_v4l2m2m`, the *encumbered* codecs — if licensing
  drove this, those would be the omissions.
- **Not structural.** The addition is one line in the same table as the other
  nine: `M2MDEC(av1, "AV1", AV_CODEC_ID_AV1, NULL);`
- **Most likely nobody had the hardware.** Almost all AV1 V4L2 hardware uses the
  *stateless* request API (`AV1F`), which FFmpeg largely leaves to GStreamer and
  Chromium. Stateful AV1 silicon like the Linlon MVE is rare.

FFmpeg patchwork returns **0 results** for `av1_v4l2m2m`, and no AV1 patch
appears among the 30 `v4l2_m2m` patches since 2022 — so this has not been
submitted before. Note also that most of those 30 sit in `new` state for years,
including a 2023 resolution-change fix and a 2025 segfault fix. **Expect slow
review, and plan to carry this in our fork meanwhile.**

## What was removed before submission

Our working tree bundled three unrelated changes. Only the AV1 work is
submitted:

| Change | Disposition |
|---|---|
| AV1 decoder, fourcc mappings, `matches_codec` helper | **submitted** |
| `extern const FFCodec ff_vp9_v4l2m2m_encoder;` | **dropped** — declared, never defined anywhere |
| `find_codec()` experimental-selection change | **held back** — alters generic codec selection for every codec in FFmpeg, unrelated to V4L2, and `av1_v4l2m2m` is not marked experimental so it is not needed here. May be a legitimate bug fix; it needs its own patch and rationale. |

Also corrected: the in-tree comment claimed *"CIX Sky1 VPU uses custom AV01
fourcc"*. `AV01` is the standard `V4L2_PIX_FMT_AV1` (`videodev2.h:751`). The CIX
VPU is conforming and the mapping is generically useful.

## Fork policy

We ship our own `libavcodec` until this lands upstream. Debian's
`libavcodec.so.62` carries `h263/h264/hevc/mpeg1/mpeg2/mpeg4/vc1/vp8/vp9_v4l2m2m`
but **no AV1**; ours is a drop-in with the same soname.

Caveat on the payoff: these are ffmpeg *decoders*, not hwaccels, so nothing
selects them automatically. MEASURED: mpv with `--hwdec=auto` sees
`av1_v4l2m2m` in our library and still never opens the VPU. Applications must
request the decoder by name — which is exactly what Firefox's V4L2 patch does.
So the fork is a **dependency for Firefox AV1**, not a blanket win for every
media application.

## Verification

Bit-exact against libdav1d on the Linlon MVE: 20 frames of 1280x720, 27,648,000
bytes, md5 `4e20cccbf7f5d6246b0a478338759645`. Byte count checked — two empty
files share an md5.
