# Brief: AV1 decode stalls in the CIX VA-API driver

System review request. The question is **why AV1 decode never produces a frame
through the CIX VA-API driver**, and what the minimal correct fix is.

This is a whole-path question — client buffer submission, driver buffer
plumbing, AV1 bitstream assembly, V4L2 queue handling and the VPU — not a single
diff. Two hypotheses have already been wrong, so treat prior conclusions in this
brief as evidence, not as settled.

---

## Why AV1 through VA-API matters

Chrome and Vivaldi are **closed prebuilt binaries that use VA-API only**. We
cannot patch them. So the VA-API driver is the *only* route to AV1 for the two
browsers most users will run.

Browsers we compile ourselves (our Chromium build, Firefox) can instead use
**V4L2-M2M**, and there AV1 already works: our patched Chromium 151 decodes AV1
720p and H.264 1080p correctly, and ffmpeg's `av1_v4l2m2m` is **bit-exact
against dav1d** (20 frames, 27,648,000 bytes, md5
`4e20cccbf7f5d6246b0a478338759645`). **The silicon and kernel driver are fine.**
The defect is confined to the VA-API path.

---

## Environment

| Item | Value |
|---|---|
| Board | Radxa Orion O6 (CIX Sky1), `ssh root@192.168.207.3` |
| OS | NCZ-OS 26.7, Debian Forky, arm64, kernel `7.2.0-rc6-sky1-ncz` |
| VPU | Arm Linlon MVE v8, `/dev/video0`, kernel driver `mvxdec` |
| Driver source | `/root/cix-vaapi-work/cixb/cix_vaapi` (on the board) |
| Build | `cmake --build build -j8` (already configured), then copy `build/libcix_va_drv_video.so` over `/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so` (dpkg-divert in place, vendor original at `.distrib`) |
| Driver logging | `CIX_VAAPI_LOG=3` in the client env (0=error … 3=debug) |
| Current driver | `ea4a089d2843afc6` |
| AV1 opt-in | `CIX_VAAPI_ENABLE_AV1=1` — AV1 is withheld by default (see below) |

Reproduce:

```
sudo -u mini env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
  XDG_SESSION_TYPE=wayland CIX_VAAPI_ENABLE_AV1=1 CIX_VAAPI_LOG=3 \
  /usr/bin/google-chrome --ozone-platform=wayland \
  --user-data-dir=/home/mini/vatest/av1x --no-first-run \
  --autoplay-policy=no-user-gesture-required --window-size=1280,800 \
  'file:///home/mini/vatest/av1test.html' > /tmp/av1x.log 2>&1
```

---

## What works, and what the same driver does for other codecs

| Codec | VA-API | Evidence |
|---|---|---|
| H.264 1080p | **works** | bit-exact vs software, 31,104,000 B, md5 `b427ff74…` |
| VP9 720p | **works** | bit-exact vs software, 13,824,000 B, md5 `0a5fad2e…` |
| HEVC | broken | `SPS is missing` fixed, still 0 bytes, stalls at `Poll` |
| AV1 | broken | stalls, detail below |

H.264/VP9 work because the driver **re-synthesises** their bitstream from the
parsed VA parameter buffers — `PackSPS()`, `PackPPS()` etc., built on the
`cix_bsw_*` bitstream writer. **`packer_av1.cpp` calls `cix_bsw_write` zero
times** (`packer_hevc.cpp` calls it 17 times). AV1 instead copies OBUs supplied
by the client.

---

## Current AV1 failure, measured

Negotiation succeeds:

```
Set format: 1280x720 AV01        (OUTPUT)
Set format: 1280x720 P010        (CAPTURE)   <- note P010, 10-bit, for an 8-bit stream
Request buffers: type 9  memory 4 count 32
Stream on: type 9
Request buffers: type 10 memory 1 count 32
Stream on: type 10
Enter BeginPicture               <- exactly once, then nothing
Poll returned with revents 0x0   <- forever
```

Chrome creates exactly three buffers: type 0 (picture param), type 4 (slice
param), type 5 (slice data). **No sequence parameter buffer.**

### Bug already found and fixed (this is real, keep it)

Chrome submits **slice data before slice parameters** within one
`vaRenderPicture()` call:

```
AV1DBG SaveSliceData:     size=11544 slice_params=0
AV1DBG SetSliceParameter: size=40 n=1 rem=0     (88us later)
```

`PackerAV1::SaveSliceData()` needs `slice_params.back()` for the payload offset
and size, found none, returned 0, and **dropped the whole bitstream**. The VPU
was queued 2 bytes (`bytesused = 2`) and polled forever.

Fix applied in `MediaDeviceV4l2Stateful::RenderPicture` — apply the buffer list
in two passes, non-slice-data first, slice data second, since
`vaRenderPicture()` imposes no ordering within a call.

Result: the payload now arrives.

```
before: Copy slice data buffer 2: size = 0     -> bytesused = 2
after:  Copy slice data buffer 2: size = 11508 -> bytesused = 11510
```

**But decode still does not start.** `BeginPicture` fires once, `Poll` returns
`0x0` indefinitely. This change is currently **uncommitted** on the board.

Note: an earlier "empty vector" guard in `SaveSliceData` was masking this — it
prevented a crash but silently discarded the payload, turning a crash into a
hang. Be alert for more guards of that shape.

---

## The architectural suspicion (unproven — do not assume)

`packer_av1.h`'s own class comment describes the design as: temporal delimiter
OBU (`PackSpsNalu`), sequence OBU **from the client** (`CopySPS`), frame-header
OBU **from the VA picture extension** (`CopyPPS`), tile payloads (`CopySlice`).

The CIX-private extension `VADecPictureParameterBufferAV1Ext` (magic
`0x31425643`, `'CVB1'`, declared only in CIX's libva headers at
`/root/cix-vaapi-work/cixb/vaprobe_inc/va/va_dec_av1.h`) carries three things
standard VA-API does not:

```c
struct { void *buffer_address; uint32_t buffer_size;
         uint8_t refresh_frame_flags; uint8_t tile_size_bytes; } buffer;
```

- `buffer_address`/`buffer_size` — the raw AV1 frame-header OBU
  (`parser_av1.cpp:75`)
- `refresh_frame_flags` — `packer_av1.cpp:157`
- `tile_size_bytes` — `packer_av1.cpp:196`

No unmodified VA-API client sends this extension. The working theory has been
that AV1 therefore requires writing an **AV1 uncompressed-header synthesiser**
from `VADecPictureParameterBufferAV1`, the way `PackSPS()`/`PackPPS()` do for
HEVC. That is a large job and has **not been validated** — the ordering bug
above was hiding in front of it, so the theory may be wrong, incomplete, or
only part of the story.

Also unexplained and possibly significant: the CAPTURE queue is set to **P010
(10-bit)** for an 8-bit AV1 stream. For H.264 the same driver selects NV12.

---

## What I want from this review

1. **Root-cause the remaining stall.** Why does the VPU accept an 11,510-byte
   AV1 temporal unit and never produce a frame? Is the assembled bitstream
   actually well-formed? Dump what the driver queues and compare against the
   same frames as produced by `av1_v4l2m2m` (which works) — that is the
   reference implementation available on this very device.
2. **Confirm or refute the header-synthesiser theory** with evidence, and if
   confirmed, scope it honestly.
3. **Assess the P010 selection** — is a 10-bit CAPTURE format correct here?
4. **Look for more silent-drop guards** of the shape described above, across the
   AV1 path and the HEVC path, which fails in the same "queues data, polls
   forever" way.
5. Say whether AV1 through VA-API is worth pursuing at all, given V4L2-M2M
   already works for the browsers we build, and Chrome/Vivaldi are the only
   things that need it.

## Verification discipline — non-negotiable

Several confident results in this work turned out false. Do not repeat them:

- **Byte counts, not just md5.** Two empty files share md5
  `d41d8cd98f00b204e9800998ecf8427e`. That produced one false "bit-exact"
  result already.
- **`ffmpeg -hwaccel vaapi` silently falls back to software and exits 0** unless
  you also pass `-hwaccel_output_format vaapi`.
- **An open `/dev/video*` fd is not evidence of decode** — it accompanied flat
  green frames for hours.
- **A player's "using hardware decoding" log line is not evidence** — mpv
  printed it for HEVC while producing zero output.
- **Patch application is not verification** — a Firefox patch applied cleanly
  under quilt and was still semantically wrong for the target version.
- **Never `pkill -f <pattern>` over ssh** where the pattern matches your own
  command line; it kills the session (exit 255). Use `pkill -x` or kill by PID.
- `grim` hangs on some windows on this compositor; use the browser's own CDP
  screenshot (`/root/shot.py PORT OUT.png`, needs `--remote-debugging-port`).

State clearly what is MEASURED versus INFERRED, and report negative results —
a hypothesis eliminated is useful.
