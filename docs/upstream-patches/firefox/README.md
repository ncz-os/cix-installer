# Firefox V4L2-M2M hardware video decode — CIX Sky1

Patches for `firefox-esr` on NCZ-OS 26.7 (Debian Forky, arm64), giving Firefox
hardware video decode through the **V4L2-M2M** path rather than VA-API.

## Attribution

Three of these four patches are **entrpi's** work (`entrpi@proton.me`), from the
Sky1-Linux `firefox-sky1` packaging repository. They are included unmodified:

- `Prefer-V4L2-M2M-over-VAAPI-for-hw-decode.patch`
- `Fix-V4L2-M2M-timestamp-handling.patch` — V4L2 stateful decoders don't set
  proper PTS/duration on output frames
- `Enable-V4L2-M2M-AV1-hardware-decode-check.patch` — `gfxVars::UseAV1HwDecode()`
  is VA-API-derived and returns false on V4L2-M2M systems, which stops Firefox
  even attempting V4L2 AV1

The fourth, `0001-v4l2m2m-vp9-av1-esr140.patch`, is a rebase of entrpi's
`Add-V4L2-M2M-AV1-decoder-support.patch` onto ESR 140 (see below).

## Why the rebase was needed

entrpi built against **Firefox 146** (`firefox (146.0-1+v4l2m2m.2)`). Debian
testing carries only **firefox-esr 140.13.0esr-2**, which is also what the board
runs, so ESR 140 is the base we want.

The AV1 patch extends a `FindVideoHardwareAVCodec()` switch carrying
`vp9_v4l2m2m` and `hevc_v4l2m2m` cases. **That function does not exist in ESR
140** — its V4L2 codec selection is a single hardcoded H.264 test, so V4L2-M2M is
H.264-only there. The rebase performs the same change through 140's structure:

```c
  if (mCodecID == AV_CODEC_ID_H264) {
    codec = mLib->avcodec_find_decoder_by_name("h264_v4l2m2m");
  } else if (mCodecID == AV_CODEC_ID_VP9) {
    codec = mLib->avcodec_find_decoder_by_name("vp9_v4l2m2m");
  } else if (mCodecID == AV_CODEC_ID_AV1) {
    codec = mLib->avcodec_find_decoder_by_name("av1_v4l2m2m");
  }
```

Only decoders the Sky1 VPU actually exposes through the patched ffmpeg are added
(`av1_v4l2m2m`, `vp9_v4l2m2m`). `avcodec_find_decoder_by_name()` returns null for
anything absent, which the existing "No appropriate v4l2 codec found" path
already handles.

The other three patches apply to ESR 140 with fuzz/offset only — in particular
`Enable-V4L2-M2M-AV1-hardware-decode-check` lands at offset −14, because ESR 140
has the identical `case AV_CODEC_ID_AV1: supported = gfxVars::UseAV1HwDecode();`.

## Why V4L2-M2M and not VA-API

AV1 through VA-API on this hardware **hangs** — the client opens `/dev/video0`,
never receives a frame, and playback freezes at 0.0 s (reproduced in Chrome and
mpv). The CIX VA-API driver needs a CIX-private libva extension carrying the raw
AV1 frame-header OBU, which no unmodified VA-API client supplies. See
`../cix-vaapi/HANDOFF-codec-investigation.md`.

V4L2-M2M has no such problem: `av1_v4l2m2m` decodes **bit-exactly** against
dav1d — 20 frames, 27,648,000 bytes, md5 `4e20cccbf7f5d6246b0a478338759645`.

This also means Chrome and Vivaldi cannot benefit: they are closed prebuilt
binaries using VA-API. Only browsers we compile — Firefox and Chromium — can take
the V4L2 route.

## Applying

Against an extracted `firefox-esr-140.13.0esr` source tree, in `debian/patches/`:

```
mkdir -p debian/patches/sky1
cp *.patch debian/patches/sky1/
for p in Prefer-V4L2-M2M-over-VAAPI-for-hw-decode \
         Fix-V4L2-M2M-timestamp-handling \
         0001-v4l2m2m-vp9-av1-esr140 \
         Enable-V4L2-M2M-AV1-hardware-decode-check; do
  echo "sky1/$p.patch" >> debian/patches/series
done
QUILT_PATCHES=debian/patches quilt push -a
```

Build native arm64 (`dpkg-buildpackage -us -uc -b -j10`). Do **not** cross-build
or emulate — an emulated Firefox build is many times the ~3.5 h native cost.

## Status

Patches apply cleanly; the build is the next verification step. **Nothing here is
confirmed to decode AV1 yet** — that requires the built package on the board,
checked with the bit-exact method in the cix-vaapi handoff, not with an open
`/dev/video0` fd or a log line.
