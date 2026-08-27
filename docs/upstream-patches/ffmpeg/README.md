# ffmpeg — AV1 over V4L2-M2M

`0001-v4l2-m2m-av1-decoder-and-multi-fourcc.patch` — cumulative diff of the
Sky1-Linux `ffmpeg-sky1` V4L2 work (author Entrpi <entrpi@proton.me>),
126 insertions / 47 deletions across 8 files. **Attribution is theirs**; the
project is defunct and its repositories are mirrored to our infrastructure so
this is not lost. Any upstream submission must credit the original author.

This is the patch that makes AV1 hardware decode actually work on CIX Sky1.

| File | Change |
|---|---|
| `libavcodec/v4l2_m2m_dec.c` | `M2MDEC(av1, "AV1", AV_CODEC_ID_AV1, NULL)` — upstream has h264/hevc/vp8/vp9, no AV1 |
| `libavcodec/v4l2_fmt.c` | map `AV_CODEC_ID_AV1` to `V4L2_PIX_FMT_AV1_FRAME` **and** `v4l2_fourcc('A','V','0','1')` |
| `libavcodec/allcodecs.c` | register the decoder; fix `find_codec()` experimental selection |
| `libavcodec/v4l2_buffers.c`, `v4l2_context.c`, `v4l2_fmt.h` | enumerate driver formats to match the codec instead of a direct lookup |
| `fftools/ffmpeg_demux.c` | auto-select the V4L2 hw decoder (CLI only — libavcodec callers such as Firefox must ask for `av1_v4l2m2m` by name) |

## Verified

Built on NCZ-OS forky against ffmpeg **8.1.2** (upstream release; Sky1 targeted
8.0.1) and run on O6N:

```
./ffmpeg -c:v av1_v4l2m2m -i av1-720p.mp4 -frames:v 20 -c:v rawvideo -f null -
  => frame=20  speed=12.8x  video:27000KiB
```

27000 KiB is exactly `1280*720*1.5*20`, and the decoded output is **bit-identical
to dav1d** — matching MD5 `4deb3fcf536babb2ae500f64d922e3e0` over five frames.
So the VPU decodes AV1 correctly; only the fourcc plumbing was missing.

## Rebasing 8.0.1 → 8.1.2

Applies cleanly except `libavcodec/allcodecs.c` (2 of 3 hunks; the file moved
between releases). By hand:

- add `extern const FFCodec ff_av1_v4l2m2m_decoder;` after `ff_av1_cuvid_decoder`
- add `extern const FFCodec ff_vp9_v4l2m2m_encoder;` after `ff_vp9_qsv_encoder`
- in `find_codec()`, change
  `if (cap & EXPERIMENTAL && !experimental) { experimental = p; }` to
  `if (cap & EXPERIMENTAL) { if (!experimental) experimental = p; }`

## Upstreamability

Worth sending to ffmpeg: it benefits every V4L2 stateful SoC, not just Sky1, and
`V4L2_PIX_FMT_AV1` (`'AV01'`) is not a CIX invention — Chromium already defines
the same fourcc in `media/gpu/v4l2/v4l2_utils.cc`. The `fftools` auto-selection
hunk is more opinionated and would likely be split out or dropped.

Not submitted. It is someone else's work, and that decision is the operator's.
