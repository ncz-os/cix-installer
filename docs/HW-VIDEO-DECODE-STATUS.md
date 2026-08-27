# Hardware video decode on CIX Sky1 — status

**Board:** O6N (Radxa Orion O6 / CIX Sky1), NCZ-OS.
**Measured:** 2026-08-05, Chromium/Chrome 151, `cix-vaapi` 1.1.0 sources.
**Applies to:** the six patches in `docs/upstream-patches/cix-vaapi/`. Without
them, browser hardware video decode does not work at all on this platform.

Every "works" below was confirmed by **looking at the picture** (a `grim`
screenshot of the compositor), not by a proxy signal. That distinction matters
here — see *How to verify* at the end.

## Summary

| Codec | ffmpeg (VA-API) | Chromium | Notes |
|---|---|---|---|
| **H.264** 1080p | works | **works** | renderer CPU ~27% → ~3.5%, 0 dropped frames |
| **VP9** 720p | works | **works** | renderer CPU ~12.5% → ~3.5% |
| **AV1** | hangs | **does not work** | blocked upstream, see below |
| **HEVC** | inconclusive | untested | see *Known issues* |
| **H.264 / HEVC encode** | works | n/a | Chromium gates VA-API encode itself |

**YouTube is still decoded in software.** Chromium advertises AV1 support to the
site regardless of what the driver offers (it has a built-in software AV1
decoder), so YouTube serves AV1 and Chromium decodes it on the CPU. Forcing
H.264/VP9 client-side — e.g. the `enhanced-h264ify` extension — makes YouTube
use the VPU. Note `--load-extension` is disabled in Chrome 151, so that has to
be a normal Web Store install.

## What the patches fix

Four defects had to be fixed before a browser could hardware-decode anything.
Each failed *silently* — no error was logged by anything — which is why the
platform looked simply "unsupported".

1. **`vaQueryConfigAttributes` returned zero attributes.** Chromium deliberately
   creates a config with no attributes so the driver will enumerate its RT
   formats; it got none back and rejected every profile. Its own diagnostic for
   this is compiled out of release builds.
   *Effect:* `about:gpu` "Video Acceleration Information" completely empty.
2. **No surface pool when a context is created with zero render targets** —
   which is legal, and what Chromium does. Capture buffers were then bound to
   nothing, and the first `VIDIOC_QBUF` failed `EINVAL` with an uninitialised
   plane fd.
3. **`vaExportSurfaceHandle` ignored `VA_EXPORT_SURFACE_SEPARATE_LAYERS`.**
   Chromium requests one layer per plane and rejects anything else. The call
   returned `VA_STATUS_SUCCESS`, so this was invisible.
4. **`vaCreateBuffer(data == NULL)` was rejected**, and buffer payloads were
   consumed at creation time rather than in submission order. Chromium's VP9 and
   AV1 paths both create their picture parameter buffer empty and fill it via
   `vaMapBuffer` — only its H.264 path passes the struct inline, which is why
   H.264 was the sole codec that got anywhere.
5. **The decoder wrote into surfaces the client never sees.** `ExportSurfaceHandle`
   handed out a freshly allocated orphan surface instead of one bound to a
   capture buffer. This is the one that produced **flat green video**: playback
   ran at full speed with frames counted and none dropped, showing an empty
   rectangle. Fixing it is what made real pictures appear.
6. A driver crash: `PackerAV1::SaveSliceData()` called `back()` on an empty
   vector, aborting the *client* process (`exit_code=134`).

## Known issues

### AV1 — will not work without upstream change

AV1 decode stalls: the first frame never completes and the client hangs. This
happens in Chromium **and** in `ffmpeg`, on the **unmodified vendor driver**, so
it is not caused by these patches.

Root cause: `cix_vaapi`'s AV1 path requires a **CIX-private libva extension**.
`cixtech/cix_libva` overlays a vendor struct on the standard
`VADecPictureParameterBufferAV1`'s reserved padding, guarded by a magic value
`0x31425643` (`'CVB1'`). Measured with Chromium:

```
DIAG AV1 ext: magic=0x00000000 expected=0x31425643 -> NULL
```

A standard client zeroes `va_reserved[]`, so the accessor returns `NULL`, and
three AV1 paths depend on it: `GetPpsBuffer()` (the client's **raw frame-header
OBU bytes**, memcpy'd to the VPU), `CopySlice()` (`tile_size_bytes`), and
`PackRepeatFrame()`. The VPU therefore receives neither a frame header nor
correctly framed tile data, accepts the submission, and produces nothing.

Separately, the driver only ever obtains an AV1 **sequence header** from a
client-supplied `VASequenceParameterBufferType` buffer — and VA-API AV1 decode
has no such buffer type. `ParserAV1::ParseSPS()` does not synthesise one; it
just records bytes the caller passed.

So AV1 works only for clients patched to fill the CIX extension — CIX's own
`cix_ffmpeg` / `cix_gstreamer` forks. Supporting stock clients means the driver
must serialise the frame header itself from `VADecPictureParameterBufferAV1` and
derive tile sizes from `VASliceParameterBufferAV1`, i.e. implement what other
VA-API AV1 drivers do. That is a vendor-side redesign, not a patch.

**Mitigation shipped:** the AV1 profile is withheld from
`GetSupportedProfiles()` unless `CIX_VAAPI_ENABLE_AV1=1` is set. Otherwise
clients pick hardware AV1 and hang; withholding it makes them fall back to
software cleanly. Re-enable only for debugging.

### Other

- **HEVC** — `ffmpeg` reported `[ERROR] SPS is missing` on a libx265-in-MP4
  clip. That may be a test-file artefact (`hvc1` vs Annex-B extradata) rather
  than a driver defect; not re-tested with a properly tagged stream. Chromium
  HEVC untested.
- **VPU session leak** — a failed or hung decode leaves the client stuck in
  `futex_do_wait` still holding `/dev/video0`, surviving `kill -9`, with
  `MVX session: ... Unable to signal EOS` filling dmesg. Sessions accumulate;
  only a reboot clears them.
- **VPP / `cme`** is broken independently of decode: `ffmpeg -vf scale_vaapi`
  fails with `VPP EndPicture: output surface not found` / invalid VASurfaceID.
- **GStreamer** `va` plugin registers 0 elements — separate, undiagnosed. Its
  device scan never processes `renderD*` despite correct udev state.
- **`cme_initialize` fails (`ret=-7`) inside Chromium's GPU process** only. It
  is logged and ignored, and is **not** related to decode — a red herring.
- **Encode** works at the driver level (`h264_vaapi`, `hevc_vaapi` both fine),
  but Chromium reports "Video Encode: Software only" — a Chromium-side feature
  gate, untested which flag unlocks it.
- **`/dev/video-cixdec0` → `/dev/video3`** points at `mvxjpegenc`; the decoder
  is `/dev/video0` (`mvxdec`). Cosmetic today — the driver enumerates nodes
  itself — but wrong, and could mislead other consumers.

## The V4L2-M2M alternative (and why AV1 works there)

The now-defunct **Sky1-Linux** project reached a different conclusion about this
hardware: **bypass VA-API entirely and use V4L2-M2M directly.** Their
`libva-v4l2-stateful` VA driver is explicitly marked

> `THIS PROJECT IS DEPRECATED. We use V4L2-M2M natively instead now.`

and its codec table lists H.264, HEVC, VP8, VP9 — **no AV1**. Meanwhile their
`ffmpeg-sky1` ("AV1/VP9 V4L2M2M, auto-hwaccel") and `gstreamer-sky1`
(`v4l2av1dec`) do support AV1. So the VPU decodes AV1 fine; it is the **VA-API
route** that cannot reach it, which is consistent with the CIX-private extension
finding above.

Their Chromium configuration (`chromium-sky1-config`) is just flags:

```sh
--enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,\
V4L2VideoDecoder,UseOzonePlatform,ChromeOSHWAV1Decoder
--disable-features=UseChromeOSDirectVideoDecoder
--ozone-platform=wayland --ignore-gpu-blocklist
--disable-gpu-driver-bug-workarounds
```

**Tested on Debian's Chromium 150 on this board: no effect** — no video node is
ever opened. Debian's build contains the V4L2 decoder *symbols* but the feature
is not wired in; it needs `use_v4l2_codec=true` at gn-config time. So these
flags only work against a Chromium built for it, i.e. Sky1-Linux's own package.

**Implication for AV1:** the realistic routes are (a) ship a Chromium built with
`use_v4l2_codec=true`, (b) use `ffmpeg-sky1` / `gstreamer-sky1` for non-browser
AV1, or (c) have CIX make their VA-API driver work without the private
extension. Patching `cix_vaapi`'s AV1 path from the outside is not viable.

Sky1-Linux is defunct; its repositories are mirrored to our own infrastructure
so these artifacts survive.

## How to verify (and how not to)

Enumeration is not decode, and an open VPU node is not a picture. Both misled
this investigation for hours.

**Reliable:** play real video, then screenshot the compositor and *look*. A
process holding `/dev/video0` alongside `renderD*`/`mali0` indicates the VPU is
engaged; cross-check renderer CPU.

Traps that produced confidently wrong answers:

- `ffmpeg -hwaccel vaapi` **silently falls back to software** and still exits 0.
  Pass `-hwaccel_output_format vaapi` to make it fail loudly.
- `about:gpu`'s "Video Decode: Hardware accelerated" line is a generic
  capability flag — it read that way while the decode table was empty. Use the
  profile table.
- An `about:gpu` export reflects only the **currently running** GPU process;
  without restarting the browser you re-serialise stale enumeration.
- Chrome `--headless=new` fails on this board (`GLDisplayEGL::Initialize
  failed`), so `--dump-dom chrome://gpu` yields nothing useful.
- A second Chrome instance silently folds into the running one
  (`ProcessSingleton.NotifyResult = 1`) unless `--user-data-dir` is writable by
  the launching user.
- The desktop locks after 5 minutes (`swayidle` → `ncz-lock`) and blanks at 6,
  so long test runs screenshot the lock screen instead of the video.
- After a reboot the board sits at the greeter with no `/run/user/1000`;
  scripted browser tests then report a meaningless "no playback / 0% CPU".
