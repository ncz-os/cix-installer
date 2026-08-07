# NCZ media stack packaging

Three packages that ship together. Installing the browser without the driver
gives a browser that silently decodes in software — the exact failure this
work exists to fix — so the dependency is declared hard, not recommended.

| Package | Contents | Consumers |
|---|---|---|
| `cix-vaapi-driver` | patched `libcix_va_drv_video.so` | Chrome, Vivaldi, VLC, mpv — any VA-API client |
| `ncz-ffmpeg` | `libavcodec` with `av1_v4l2m2m` | Firefox, and anything requesting the decoder by name |
| `chromium-ncz-sky1` | the browser | end users |

## Two hardware-decode paths, deliberately

They are separate implementations and each needs its own maintenance. This is
not duplication that can be collapsed.

**VA-API (`cix-vaapi-driver`)** — the only path prebuilt browsers can use.
Chrome and Vivaldi are closed binaries; they get H.264, VP9 and HEVC from this
driver with no browser-side change. Its limitation is structural: the VPU is a
*stateful* decoder that wants complete bitstreams, while VA-API supplies parsed
parameters. Every codec therefore needs bitstream reconstruction in the driver —
HEVC needed SPS synthesis, AV1 needs sequence and frame OBUs, VP8 needs a
bool-coded partition header. AV1 and VP8 are consequently withheld.

**V4L2-M2M** — no such problem, because whole frames are passed through. Two
independent consumers:

- *ffmpeg's v4l2m2m decoders* — ten codecs from one shared implementation
  (h263, h264, hevc, mpeg1, mpeg2, mpeg4, vc1, vp8, vp9, plus our av1).
  Reachable only by applications that use the **system** libavcodec. Among
  browsers that is **Firefox alone**: it `dlopen`s `libavcodec.so.53` through
  `.62`. VP8 decodes bit-exactly here, on the same hardware where VA-API cannot.
- *Chromium's own `media/gpu/v4l2`* — a separate implementation in Chromium's
  tree. Chromium-family browsers bundle a stripped ffmpeg and never ask
  libavcodec to decode in hardware, so they cannot inherit the above. Our four
  Chromium patches live here.

So: work on the driver benefits Chrome and Vivaldi; work on ffmpeg benefits
Firefox; work on Chromium benefits our own browser. There is no single change
that serves all three.

## Publishing

`publish-apt.sh <suite> <deb>...` builds the `Packages`/`Release` indices and
signs them when `NCZ_APT_GPG_KEY` is set. It refuses any `.deb` that `dpkg-deb`
cannot read or that is implausibly small — a Firefox build has already exited 0
while producing 25 KB packages, and byte counts are the only thing that caught
it.

An unsigned repository trains every consumer to disable verification, so the
absence of a signing key is reported loudly rather than passed over.
