# Handoff — CIX Sky1 codec support across shipped browsers

Investigation brief. Goal: determine the **path of least resistance** to working
hardware video decode for **AV1, H.264, VP9 and HEVC** across the browsers
NCZ-OS ships (Chrome, Chromium, Vivaldi, Firefox), plus standalone players.

Everything below was measured on real hardware this session. Where something is
inferred rather than measured it says so. **Do not trust a claim here that is
not marked measured** — several confident-sounding claims made earlier in this
work turned out to be wrong, and they are called out explicitly so they are not
repeated.

---

## Environment

| Item | Value |
|---|---|
| Board | Radxa Orion O6 (CIX Sky1), `ssh root@192.168.207.3` |
| OS | NCZ-OS 26.7 "Maximilian", Debian Forky, arm64 |
| Desktop user | `mini` (uid 1000), Wayland compositor labwc |
| Launch GUI apps | `sudo -u mini env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland <cmd>` |
| VPU | Arm Linlon MVE v8, `/dev/video0`, kernel driver `mvxdec` |
| VA-API driver | `/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so`, installed via `dpkg-divert` (vendor original at `.distrib`) |
| Driver source | `/root/cix-vaapi-work/cixb/cix_vaapi` (on the board) |
| Build dir | same, `build/`, already configured |
| Patched sources snapshot | `/root/cix-patches/` |

### Building the driver

Upstream `cix_vaapi` does **not** build against stock libva. Working invocation
(already configured in `build/`, so `cmake --build build -j8` is enough):

```
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-I/root/cix-vaapi-work/cixb/vaprobe_inc -I/usr/src/cix-vpu-driver-1.0.2/driver/linux -I/root/cix-vaapi-work/cixb/cix_media_engine/libcme/include" \
  -DCMAKE_EXE_LINKER_FLAGS="-L/root/cixlink" -DCMAKE_SHARED_LINKER_FLAGS="-L/root/cixlink"
```

Why each is needed:
- `vaprobe_inc/va/` — CIX's libva headers. Debian `libva-dev` 2.24.1 lacks
  `VADecPictureParameterBufferAV1Ext`, which `packer_av1.cpp`/`parser_av1.cpp`
  reference unconditionally.
- `mvx-v4l2-controls.h` — from the VPU DKMS source.
- `/root/cixlink/libcme.so` — a symlink to `libcme.so.1`; only the versioned
  library ships, so `-lcme` fails without it.

Deploy: copy `build/libcix_va_drv_video.so` over the diverted path. Driver logging:
`CIX_VAAPI_LOG=3` in the client's environment (0=error … 3=debug).

### Driver binaries produced so far

| sha256 (first 16) | What |
|---|---|
| `1873f27893fcc466` | vendor original (`.distrib`) — **zero** hardware decode, every `FillProfileInfo_Locked` fails |
| `d9038b43b2063f47` | H.264 + VP9 working, verified bit-exact |
| `9ff7d3a62166edbc` | **currently deployed** — adds the HEVC SPS change below |

---

## HOW TO MEASURE — read this before running anything

Four separate false results were produced this session by bad measurement. Use
the bit-exact method and you avoid all of them.

### Use this (strongest, fastest, no GUI needed)

Decode N frames in software and in hardware, compare md5:

```
ffmpeg -i FILE -frames:v 10 -pix_fmt yuv420p -f rawvideo sw.yuv
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
       -i FILE -frames:v 10 -vf hwdownload,format=nv12 -pix_fmt yuv420p -f rawvideo hw.yuv
md5sum sw.yuv hw.yuv
```

**Always check the byte counts, not just the md5s.** Two *empty* files have
identical md5s (`d41d8cd98f00b204e9800998ecf8427e`). An earlier claim that the
V4L2 AV1 decoder was "MD5-identical to dav1d" was almost certainly this trap.
Expected size = `frames × width × height × 1.5` for yuv420p.

### Traps that produced wrong answers here

1. **`-hwaccel vaapi` alone silently falls back to software and exits 0.** You
   must pass `-hwaccel_output_format vaapi`.
2. **An open `/dev/video0` fd is not evidence of correct decode.** For most of
   this session Chrome held the VPU node while rendering flat green frames.
3. **A player's own "using hardware decoding" log line is not evidence either.**
   mpv printed `Using hardware decoding (vaapi)` for HEVC while producing zero
   output. This is how HEVC was wrongly reported as working.
4. **Never match processes by launcher path.** `pgrep -f /usr/bin/google-chrome`
   does not match the real process `/opt/google/chrome/chrome`; `pgrep -x firefox`
   does not match `firefox-esr`. Scan every PID for an open `/dev/video*` instead:
   ```
   for p in $(ls /proc | grep -E '^[0-9]+$'); do
     ls -l /proc/$p/fd 2>/dev/null | grep -q /dev/video && echo "$p $(cat /proc/$p/comm)"
   done
   ```
5. **Do not `pkill -f ffmpeg` over ssh** — the pattern matches your own ssh
   command line and kills your session (exit 255). Use `pkill -x`.
6. **`grim` hangs indefinitely** capturing Vivaldi/Chromium/Firefox windows on
   this compositor. Use the browser's own CDP `Page.captureScreenshot`
   (`/root/shot.py PORT OUT.png`, needs `--remote-debugging-port`).
7. **Vivaldi needs `--disable-vivaldi`** on a fresh profile or the first-run
   wizard blocks the page, and the browser looks broken when it is not.
8. **Chromium-family browsers need `--ozone-platform=wayland`.** Under X11 ozone
   VA-API init fails on this board for *all* of them:
   `GetHandle(): ... failed to find a suitable render node`.

Test media on the board, in `/home/mini/vatest/`: `test1080.mp4` (H.264),
`vp9-720p.webm`, `hevc-720p.mp4`, `vp8-720p.webm`, `av1-720p.mp4`, plus
`hwtest.html`, `vp9test.html`, `hevctest.html`, `vp8test.html`, `av1test.html`.

---

## Current measured state

### Hardware capability (`v4l2-ctl -d /dev/video0 --list-formats-out`)

`H263` `H264` `HEVC` `MPG2` `MPG4` `VP80` `VP90` `AV01`

### VA-API driver exposes (`vainfo`)

H.264 ConstrainedBaseline/Main/High/High10 · HEVC Main/Main10 · VP9 Profile0/Profile2 · AV1 Profile0
(**no** VP8, MPEG-2, MPEG-4, H.263 — present in hardware, not exposed)

### Codec results

| Codec | Status | Evidence |
|---|---|---|
| **H.264** 1080p | ✅ **works** | sw vs hw bit-exact, 31,104,000 B, md5 `b427ff74…` |
| **VP9** 720p | ✅ **works** | sw vs hw bit-exact, 13,824,000 B, md5 `0a5fad2e…` |
| **HEVC** 720p | ❌ **broken, all clients** | hw produces 0 bytes; see below |
| **AV1** 720p | ❌ **hangs the player** | stalls at `time 0.0s`; mpv needed SIGKILL |
| **VP8** 720p | ⚠️ software only | plays correctly, VPU untouched (no VP8 VA profile) |

### Browser results (H.264/VP9, with driver `d9038b43`)

| Browser | Result |
|---|---|
| Google Chrome 151 | ✅ H.264 + VP9, picture verified, renderer CPU ~6% |
| Vivaldi 8.1 | ✅ H.264 + VP9, picture verified |
| Chromium 150 (Debian) | ❌ built `use_vaapi=false use_v4l2_codec=true` on arm64; zero libva symbols. Forcing its V4L2 path gives `V4L2FormatToVideoFrameLayout(): Failed to convert pixel format to VideoPixelFormat: Y0A8` → `GPU process exited unexpectedly: exit_code=133`. Needs a rebuild, not a flag. |
| Firefox 140 ESR | ❌ runs fine (RDD process alive, page loads) but never opens `/dev/video0`, even with `media.ffmpeg.vaapi.enabled` and `media.hardware-video-decoding.force-enabled` set |

---

## The three open problems

### 1. HEVC — partially advanced, still broken

`PackerHEVC::PackSpsNalu()` was an **empty stub**, so no SPS ever reached the
VPU and `CheckIntegrity()` (`packer_hevc.cpp:309`) rejected every frame with
`SPS is missing`. The only other producer, `CopySPS()`, expects a raw SPS NAL in
a `VASequenceParameterBuffer` that standard VA-API HEVC decode never sends — and
that call site (`v4l2_stateful_dec.cpp:302`) is additionally compiled out unless
libva is exactly 1.22.1:
```c
#if (VA_MAJOR_VERSION == 1 && VA_MINOR_VERSION == 22 && VA_MICRO_VERSION == 1)
```

`PackSPS()` (`packer_hevc.cpp:388`) already synthesises a conforming SPS from
`pic_param` (`VAPictureParameterBufferHEVC`), exactly as `PackVPS()` does for the
VPS. **Applied fix (in `9ff7d3a62166edbc`, uncommitted):** implemented
`PackSpsNalu()` mirroring `PackVpsNalu()` — start code, `AddNaluHeader(...,
HEVC_NALU_TYPE_SPS)`, `PackSPS()`, emulation prevention — set `sps_inserted =
true`, and changed the constructor to `update_sps(true)`.

**Outcome: `SPS is missing` is gone (0 occurrences, no driver errors or warnings
at all), but decode still yields 0 bytes.** The failure moved downstream — the
VPU accepts the bitstream and never signals a frame:
```
[DEBUG] Enter BeginPicture
[DEBUG] Poll returned with revents 0x0
```

**Next steps to investigate:** whether the synthesised SPS is actually conformant
(dump the generated NAL and parse it with an independent tool, or diff against
the SPS in `hevc-720p.mp4`); whether `PackProfileTierLevel()` emits a tier/level
the VPU accepts; whether VPS/SPS/PPS IDs are consistent; whether the H.264 path
does something at `BeginPicture`/queue time that HEVC omits. H.264 works and is
the obvious reference implementation to diff against.

### 2. AV1 — hardware is fine, VA-API path is not

**Measured: the VPU decodes AV1 bit-exactly via V4L2-M2M.** Using the patched
ffmpeg at `/root/ffbuild/ffmpeg-8.1.2/ffmpeg` (has `av1_v4l2m2m`):
```
ffmpeg -c:v av1_v4l2m2m -i av1-720p.mp4 -frames:v 20 -pix_fmt yuv420p -f rawvideo h.yuv
```
gives **27,648,000 bytes, md5 `4e20cccbf7f5d6246b0a478338759645`** — identical to
the dav1d software decode. So the silicon and the kernel driver are good; only
the VA-API route fails.

Through VA-API, AV1 **hangs**: the client opens `/dev/video0`, never gets a
frame, and playback freezes at 0.0 s. Reproduced in both Chrome and mpv. This is
worse than being unsupported — the user gets a frozen player instead of a
software fallback.

Only **two lines** depend on the CIX-private extension, both in
`packer_av1.cpp:196-198`, both reading `ext->u.buffer.tile_size_bytes` from
`va_get_dec_picture_parameter_buffer_av1_ext_buffer()`. That value is
`tile_size_bytes_minus_1 + 1` from the AV1 uncompressed frame header's
`tile_info`. **If it can be parsed from the bitstream, the private extension
becomes unnecessary and AV1 works in every VA-API client with no browser
changes.** `utils/parser/parser_av1.cpp` already parses AV1 headers and is the
place to add it. Note `parser_av1.cpp:67` reads the same Ext buffer — check
whether it has the same need.

**Ship-safety fix, independent of the above:** stop advertising
`VAProfileAV1Profile0` so clients fall back to dav1d cleanly instead of hanging.
This is the single highest-value change right now and should probably land first.

### 3. Browsers that cannot use any of it

- **Chromium (Debian)** needs a rebuild with `use_vaapi=true`. A Chromium
  arm64 cross-compile is in progress on HYDRA (192.168.207.78,
  `~/chromium-build`, x86 host cross-compiling to arm64; native arm64 fails —
  `infra/3pp/tools/gperf/linux-arm64` does not exist). A build script exists at
  the scratchpad path referenced in the session; it patches `media/gpu/args.gni`
  so `use_av1_hw_decoder` includes `use_v4l2_codec`.
- **Firefox** needs the 4 Entrpi patches (in `docs/upstream-patches/firefox/`)
  and `MOZ_ENABLE_V4L2=1`; not attempted yet. Note Sky1-Linux's prebuilt Firefox
  wants `libvpx.so.11` while the board has 12.

---

## What "path of least resistance" should weigh

For each of AV1, H.264, VP9, HEVC, decide between:
- **fix the VA-API driver** — one change benefits Chrome, Vivaldi, mpv, VLC and
  GStreamer at once, no browser rebuilds. This is what fixed H.264 and VP9.
- **use the V4L2-M2M path** — proven bit-exact for AV1, but needs browser
  rebuilds (Chromium `use_v4l2_codec`, Firefox `MOZ_ENABLE_V4L2`) and the
  Chromium `Y0A8` negotiation problem solved. Note ffmpeg's `av1_v4l2m2m`
  negotiates NV12 on this same device successfully, so it is solvable — compare
  what ffmpeg does at `S_FMT` against what Chromium's V4L2 decoder does.
- **do not ship it** — de-advertise so clients fall back to software cleanly.
  Correct answer for anything that would otherwise hang.

Weigh how many of the four shipped browsers each option fixes against the work,
and say plainly which codecs are worth shipping accelerated and which should
fall back to software.

---

## Already fixed, for context (committed, `074e4ff`)

Three defects that made VA-API decode unusable in Chromium-family browsers, all
in `docs/upstream-patches/cix-vaapi/0001-vaapi-fixes.diff`:

1. `CreateConfig()` recorded only caller-supplied attributes, so an
   attribute-less config reported none and Chromium rejected every profile.
2. `ExportSurfaceHandle()` ignored `VA_EXPORT_SURFACE_SEPARATE_LAYERS`.
3. Export-before-decode returned a fresh pool surface that `BeginPicture()` then
   destroyed via `DestroyUnusedSurface()` (because `Surface::users` tracks only
   `V4l2Buffer` users, not client dmabuf holders), leaving the client with an fd
   to a buffer the VPU never writes — an all-zero NV12 frame, which renders as
   flat green `rgb(0,136,0)`. Fixed by `FetchCaptureBoundSurface()`, which
   returns a capture-bound surface: the decoder's actual output buffer.

Chromium exports every surface once, up front, before any picture is decoded,
then reuses those dmabufs; mpv exports per frame, after decode. **That
difference is why several bugs here hit only Chromium-family browsers, and it is
worth assuming it explains any remaining Chrome-only symptom.**
