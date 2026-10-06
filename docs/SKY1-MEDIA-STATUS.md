# Sky1 media status: video decode and audio output (2026-10-06)

**Boards:** O6N (192.168.207.3) and MS-R1 (192.168.207.66), NCZ-OS 26.10 from the
diag image, kernel `7.3.0-rc6-sky1-ncz` (r284), `cix-vpu-driver-dkms 1.0.2-ncz1`,
`cix-vaapi 1.0.0` + `cix-libva 2.22.1`, mpv 0.41, ffmpeg 9.0.1 (`/opt/ncz-ffmpeg`, first
on PATH) and 9.0.2 (Debian), GStreamer 1.28.7, `chromium-ncz-sky1 154.0.8037.0-ncz20260907`.
Both boards were measured with the same clips and commands. Results matched on both boards
unless a row says otherwise. Raw output is under `~/Projects/oc-mission/media-evidence/` on STUDIO.

Test clips: ffmpeg `testsrc2` + a 440 Hz tone, 30 s at 30 fps, 1080p and 2160p, encoded as
H.264 High, HEVC Main, HEVC Main10, VP9 profile 0, AV1 main (webm and mp4) and MPEG-2.

## The short version

| Layer | State | Evidence |
|---|---|---|
| Kernel VPU driver (amvx) | **healthy** | V4L2 M2M decodes every VPU codec, with frames bit-identical to software. A 6-session parallel soak ran ~3 min at real time: 36/36 runs completed, no hangs, no fence or IRQ timeouts. |
| CIX VA-API driver | **broken for decode** | H.264 and HEVC hang or fail, and VP9/AV1/MPEG-2 are not offered (details below). |
| mpv default (`hwdec=vaapi`) | **broken** (fixed in this branch) | It inherits the VA-API failure. `v4l2m2m-copy` works. |
| Chromium video decode | **healthy** for H.264/VP9/AV1 | V4L2VideoDecoder runs on the VPU at real time. HEVC fails in this build. |
| Chromium *playback* | **freezes** when the default audio sink is broken | Chromium's media clock follows the audio track (details below). |
| Audio, MS-R1 | DP/HDMI I2S dead (kernel clock); analog works | The kernel I2S clock reads 0 Hz, so hw_params returns EINVAL (details below). |
| Audio, O6N | DP I2S fails **intermittently** (kernel clock) | The same EINVAL appears after DP hotplug. |
| GStreamer H.264/HEVC | **broken** | `v4l2h264dec` gets the AFBC capture format by default (details below). |

The operator saw the same "unreliable video" on both boards. The cause is two common-stack
failures stacking:

1. the mpv default goes through the broken VA-API driver;
2. Chromium playback stalls whenever the default PipeWire sink cannot start. That happened
   on MS-R1 every time, and on O6N after DP hotplug events. Either way the video looks frozen.

## Video, per path (fps = decode-only frames per second, `-f null`, no display)

| Clip | Software (ffmpeg) | V4L2 M2M (`*_v4l2m2m`) | VA-API (`-hwaccel vaapi -hwaccel_output_format vaapi`) |
|---|---|---|---|
| H.264 1080p | 790-960 fps, 7-8 cores | **1090 fps, 37-67% CPU, 60/60 frames bit-exact** | hangs in the driver (`futex_do_wait`), killed after 90 s, needs SIGKILL; dmesg `MVX if: Buffer plane too small ... size=2076672 filled=2081280`, `FATAL_ERROR_AFBC_REF_CORRUPT`, `MMU ABORT` |
| H.264 2160p | 410 fps | **297 fps, 41-46% CPU, bit-exact** | same hang (`size=8294400 filled=8309760/8355840`) |
| HEVC 1080p / 2160p | 870-910 / 330 fps | **1240 / 345 fps, ~50% CPU, bit-exact** | `[ERROR] SPS is missing`, 17 frames, then a hang |
| HEVC Main10 1080p / 2160p | 615-650 / 220 fps | **1235 / 340 fps**: output is NV12 (8-bit), PSNR 61 dB vs the 10-bit reference | `SPS is missing`, hang |
| VP9 1080p / 2160p | 400 / 340-350 fps, 3.5-6.5 cores | **1085-1110 / 317-320 fps, 32-46% CPU, bit-exact** | not offered by the driver, so software |
| AV1 1080p / 2160p | 235 / 125-130 fps (dav1d, ~2.5 cores) | no `av1_v4l2m2m` decoder exists in FFmpeg | not offered, so software |
| MPEG-2 1080p / 2160p | 870-1060 / 580-600 fps | **800 / 204 fps, 16-55% CPU**, PSNR 69 dB (IDCT rounding) | not offered, so software |

The VA-API failure comes first, in the VA driver: `vainfo` lists only H.264 (CB/Main/High/High10)
and HEVC (Main/Main10) VLD. The driver hands the VPU capture surfaces sized exactly W×H for plane 0,
while the firmware writes 1084/1096 (1080p) or 2164/2176 (2160p) lines. amvx rejects the fill
(`Buffer plane too small`, NEED_REALLOC), the driver's QBUF fails (`Failed to queue type 9 buffer`),
and its poll loop spins (`Poll returned error event`, gigabytes of stderr) until the process is
killed. The same amvx serves V4L2 M2M (driver-allocated MMAP buffers) correctly, so the kernel
driver is not the failing layer. The installed `cix-vaapi 1.0.0` also lacks the VP9/AV1 profiles
that `docs/HW-VIDEO-DECODE-STATUS.md` (patched 1.1.0 build) lists. The image ships the vendor
build, not that patched one.

### mpv, real-time playback with and without the compositor

Each run is a 10 s probe with `--aid=no`. "cpu" is the mpv process alone.

| Clip | shipped `hwdec=vaapi`, `vo=dmabuf-wayland` | `v4l2m2m` + `dmabuf-wayland` | **`v4l2m2m-copy` + `gpu-next`** | `v4l2m2m-copy` + `vo=null` | software + `gpu-next` |
|---|---|---|---|---|---|
| H.264 1080p | MS-R1: **mpv exits rc=2** (`Failed to send decoder command`). O6N: software, 68% | software, 69-70% | **HW, 4%, 0 drops** | HW, 2% | 39-43% |
| HEVC 2160p | **rc=2 on both** (`SPS is missing`), no playback | software, 264-268% | **HW, 13-15%, 0 drops** | HW, 2% | 74-75% |
| VP9 2160p | software, 254-258% | software, 248-255% | **HW, 13-14%, 0-1 drops** | HW, 1-3% | 57-60% |
| AV1 1080p | software, 59% | software, 60% | software (dav1d), 28-30% | 25% | 29-31% |

Presentation is not the bottleneck: `vo=null` and `gpu-next` show the same decode health.
`dmabuf-wayland` accepts VA-API surfaces only, so it never engages the V4L2 decoder.
**Fix shipped here:** `84-vpu-mpv.sh` writes `hwdec=v4l2m2m-copy`, `vo=gpu-next,x11`.

### Chromium (`chromium-ncz-sky1`, the shipped wrapper, Wayland session)

The binary carries the V4L2 stateful decoder and no VA-API (no `libva.so` reference, so
`VaapiVideoDecoder` flags are inert). Its log shows `Initialize(): V4L2 decoder using MPLANE
queues` for every codec, and the GPU process holds `/dev/video0` during playback.

Each run plays 8 s per clip from a local `<video>` page:

| Run | H.264 1080p | H.264 2160p | VP9 1080p/2160p | AV1 1080p/2160p | HEVC |
|---|---|---|---|---|---|
| shipped, MS-R1 (default sink = failing DP) | t=0.26 s of 8, 4/9 dropped | t=1.26 | t=1.79 / 0.8 | t=1.96 / 0.93 | PIPELINE_ERROR_DECODE |
| shipped, O6N (default DP sink in `error` state) | t=0.94 | t=0 (4 frames) | t=0 | t=0 | PIPELINE_ERROR_DECODE |
| `--disable-accelerated-video-decode` | stalls the same way | | | | |
| `--disable-audio-output` | **t=7.93, 235-240 frames, ≤5 dropped** | | **7.92-7.94** | **7.93** | PIPELINE_ERROR_DECODE |
| new autoswitch, MS-R1 (default = analog) | **t=7.90, 3 dropped** | **7.91** | **7.92** | **7.91** | not run |
| new autoswitch, O6N (DP healthy at the time) | **7.75** | **7.73** | 6.79 | 7.6 | not run |

Software decode stalls too, while turning off audio output alone restores smooth playback. So
the freeze is the audio sink, not the decoder.

HEVC is advertised (`canPlayType` "probably", `mediaCapabilities` supported/powerEfficient), but
`V4L2VideoDecoder` fails on the second frame (`DecoderStatus::201` → `PIPELINE_ERROR_DECODE`).
FFmpeg's `hevc_v4l2m2m` decodes the same stream bit-exact, so this is a Chromium-side defect in
this build. There is no runtime feature to withhold HEVC (`PlatformHEVCDecoderSupport` is not in
the binary). This is for the chromium-ncz-sky1 package owner.

The wrapper flags stay as they are (`--enable-features=AcceleratedVideoDecoder`,
`--disable-features=AudioServiceOutOfProcess,AudioServiceSandbox`, Wayland, render-node
override). Audio streams reach PipeWire normally with the audio service in-process.
`build/test-sky1-media-defaults.sh` locks the flags.

### GStreamer

`playbin3` fails H.264 and HEVC mp4 (`pipeline doesn't want to preroll`). With an explicit
pipeline, `v4l2h264dec` reports `V4L2 format Y0A8 not supported`: amvx sets both queues to
AFBC at open, and GStreamer keeps the driver's capture format. VP9 and AV1 webm play. A
candidate amvx fix is `docs/upstream-patches/amvx/0001` (not shipped, not runtime-tested).
No GStreamer player is installed by default, so this does not affect the shipped mpv,
Celluloid, or Chromium paths.

## amvx (cix-vpu-driver-dkms 1.0.2-ncz1) on 7.3

- `CONFIG_DMABUF_DEBUG` is **not set** on either running kernel (`/proc/config.gz`), so the
  DMABUF_DEBUG zero-page trigger is inactive.
- The VPU (`CIXH3010:00`) has **no IOMMU group**, so DMA address == physical address.
  `append_sg_table()`/`get_sg_table_npages()` mix the CPU sg walk (`for_each_sg_page` over
  `nents`) with DMA addresses read through a cast. That is latent on this hardware, not active.
  `docs/upstream-patches/amvx/0002` converts both to `for_each_sgtable_dma_page()`. It is
  compile-checked against the r285 headers and behaviour-neutral without an IOMMU.
- No firmware-load errors, IRQ timeouts, or session leaks under V4L2 M2M load. Remaining noise:
  - `MVX if: Buffer plane too small` at H.264 session start on the MMAP path too (handled by
    realloc; frames stay bit-exact);
  - `Invalid frame period from client (1/30). Return 60/1`;
  - `MVX dev: Ref is zero`;
  - `watchdog_work enqueued on deprecated workqueue`.
- The VA-API failure is a VA-driver surface-size problem (above), not an amvx regression.
- ffmpeg's `-stream_loop` with a `*_v4l2m2m` decoder stops after the first pass (900 frames,
  rc=0). That is an FFmpeg v4l2m2m flush limitation, not a hang.

## Audio

### MS-R1

| PCM | Result |
|---|---|
| `hw:0,0` ALC269VC Analog | plays: hw_ptr advances, rc=0, at S16 and S32 48 kHz |
| `hw:0,1` ALC269VC Digital (SPDIF) | plays |
| `hw:1,0..2` I2S → DP0/DP1/DP3 | `set_params: Unable to install hw params` (EINVAL) every time |

- The kernel logs `cdns-i2s-mc CIXH6011:0x: clk freq 0 is too low, must greater then 48000 * 32 *
  2 * 6 = 18432000`.
- `clk_summary` shows `audio_clk2` and `audio_clk3` at **0 Hz** on MS-R1 versus 270950000 /
  316108333 Hz on O6N. `audss_mclk0..4` are 0 Hz on both boards.
- The monitor (ViewSonic VP2488-4K on DP-3) does carry audio: ELD `eld#2` reports 1 SAD, LPCM
  2 ch, 32-96 kHz, 16/20/24-bit.
- PipeWire's own `output:stereo-fallback` profile for the HDA card plays (0 ERR, RUNNING). It is
  marked unavailable only because jack sensing reports the line-out unplugged.
- The old autoswitch picked the DP sink because its ELD has audio, then reloaded it every 2 s
  forever. pipewire-pulse drops a module-alsa-sink whose node fails to start, and sink ids climbed
  1558 → 3360 → 5763. The journal filled with `set_hw_params: Invalid argument` and
  `failed to set default sink ... No such entity`.

### O6N

- `hw:0,1` and `hw:0,2` played at 17:57. From 18:29, `hw:0,0` (CIXH6011:02) and, around DP hotplug
  at 18:41, `hw:0,1` (CIXH6011:03) returned the same `clk freq 0` EINVAL, while `audio_clk2` read
  270.95 MHz and `audss_i2s5/6/9` read 294.912 MHz. The clock failure is intermittent here.
- WirePlumber's `stereo-fallback` sink for the cix,sky1 card is always PCM 0 (DP0), so on O6N it
  points at an unconnected port. It went into `error`.
- The autoswitch's DP sink then sat in PipeWire state `error` while still listed. `pw-play`
  hung forever, and Chromium froze.
- The old daemon crashed every iteration with `'utf-8' codec can't decode byte 0xd5`, from
  non-UTF-8 stream properties in `pactl list sinks`.

### What the new autoswitch does (`assets/audio/ncz-sky1-audio-autoswitch.py`)

- **Probes before selecting.** It opens a DP/HDMI PCM once with `aplay` (48 kHz S16 stereo,
  50 ms of silence) before making it a sink. A busy PCM counts as usable.
- **Backs off from broken PCMs.** A PCM that refuses, or a sink that vanishes or sits in
  PipeWire `error` (seen via `pw-dump`), is parked with a 30 s → 10 min back-off. The daemon
  logs once, unloads its own broken sink, and falls through to analog. It never reloads the
  sink every poll.
- **Prefers WirePlumber's own analog sink.** If WirePlumber's ACP sink for the same analog PCM
  appears (a jack plugged in), the daemon uses it and drops its duplicate.
- **Falls back to a silent sink.** When every real sink is broken, it defaults to the null sink
  `ncz_sky1_silent`, so players keep their clocks instead of hanging.
- **Survives bad output.** Non-UTF-8 `pactl` output no longer kills an iteration.

Validated live on MS-R1 (the shipped service was stopped for the test and restarted after):

- one probe and one kernel clock line, then the analog default;
- `pw-play` RUNNING on `hw:0,0` with 0 ERR and no PipeWire errors during the run;
- Chromium playing at real time with its audio stream on the analog sink.

### What r285 changes (kernel patch 0008, `sky1-audss-clk` ACPI clock names)

r285 is expected to give the audio-subsystem clocks their `audio_clk0..5` parents. That should
make the following disappear:

- `clk freq 0` / `ASoC error (-22)`;
- `set_hw_params: Invalid argument` on `hw:1,x` (MS-R1) and the intermittent `hw:0,x` failures
  (O6N);
- the DP-sink start errors and, with them, the Chromium freeze on boards that pick DP audio.

None of this is verified until a board boots r285. The userspace guard stays useful even with
working clocks: a monitor without audio, a DP link that goes away, or a future clock regression
must not leave a broken default. With r285 the MS-R1 should go back to DP audio on the
VP2488-4K automatically, because a display with audio still outranks analog.
