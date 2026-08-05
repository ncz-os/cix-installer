# Upstream patches pending submission

## cix-vaapi/ — hardware video decode in browsers on Sky1

Three patches against https://github.com/cixtech/cix_vaapi (`main`, 6e03daa
"Multimedia SDK 2026Q2"). Apply with `git am`. Together they take Chromium
from "no hardware decode at all" to decoding H.264 1080p on the VPU. Each
fixes a distinct defect and each was measured on O6N (.3) with Chrome 151.

**0001 — vaQueryConfigAttributes reports no attributes.**
`CreateConfig()` stored only caller-supplied attributes and
`QueryConfigAttributes()` echoed them back, so a config created with
`(NULL, 0)` reported zero attributes. Chromium creates exactly such a config
so the driver will enumerate its RT formats, finds no `VAConfigAttribRTFormat`
and rejects every profile — silently, since the diagnostic is `DLOG_IF()` and
is compiled out of release builds. ffmpeg/mpv were unaffected: they never call
`vaQueryConfigAttributes()`.
*Before:* about:gpu decode table empty, 15 `FillProfileInfo_Locked failed`.
*After:* 9 profiles listed (h264 baseline/main/high, vp9 profile0/2, hevc
main/main10/still-picture, av1 main), 0 failures.

**0002 — no surface pool when a context has no render targets.**
`vaCreateContext()` with `num_render_targets == 0` is legal; Chromium
allocates surfaces afterwards. `CreateContext()` used the lookup-only
`GetSurfacePool(w, h)`, which returns null before any pool exists, and
`SetSurfacePool()` is guarded by `if (pool)` — so the codec had no pool, the
CAPTURE port's DMABUF buffers bound no surfaces, and every plane kept an
uninitialised fd:
`Failed to queue type 9 buffer 0: errno = 22 (Invalid argument), plane 0: fd = 1073741824`.
Note the format passed to the creating overload must be the *raw* one; the
config carries the compressed format and yields a zero-plane pool.

**0003 — vaExportSurfaceHandle ignores VA_EXPORT_SURFACE_SEPARATE_LAYERS.**
The export always produced one layer carrying every plane. Chromium exports
with `READ_ONLY | SEPARATE_LAYERS` and rejects any layer holding more than one
plane. It returned `VA_STATUS_SUCCESS`, so this failed silently: Chromium
selected `VaapiVideoDecoder`, logged `Initialize() successful`, then discarded
the surface while building its frame pool and fell back with only "video
decoder fallback after initial decode error". `BeginPicture()` was never
reached — no frame was ever submitted.

### Measured result (O6N .3, Chrome 151, H.264 1080p)

| | stock | patched |
|---|---|---|
| about:gpu decode profiles | none | 9 |
| `FillProfileInfo_Locked failed` | 15 | 0 |
| GPU process opens `/dev/video0` | no | **yes** |
| renderer CPU during playback | ~27–46% | **~3.4%** |

No regressions: `ffmpeg -hwaccel vaapi -hwaccel_output_format vaapi` still
decodes, `vaQuerySurfaceAttributes()` still returns its full set, `vainfo`
still lists 14 profiles, desktop/greetd/NPU service unaffected.

Submission target: https://github.com/cixtech/cix_vaapi. Author identity:
Jason Perlow <jperlow@gmail.com>. Related: cixtech/cix_libva#7 (filed against
cix_libva, but all three defects are in cix_vaapi).

### Reproducers — `cix-vaapi-repro/`

`vaprobe.c` replays Chromium's early `FillProfileInfo_Locked` steps (these
already pass on the stock driver). `vaprobe2.c` replays the final block —
attribute-less `vaCreateConfig()` then `vaQueryConfigAttributes()` — and is
the one that shows `num_config_attributes = 0` before 0001.

Build the driver from source on the board (no cmake, no CIX SDK tarball):

```sh
# CME headers: github.com/cixtech/cix_media_engine libcme/include
# VPU UAPI header already on NCZ-OS at /usr/src/cix-vpu-driver-*/driver/linux
g++ -std=c++11 -fPIC -shared -o cixtest_drv_video.so \
  $(find cix_vaapi/ddi cix_vaapi/devices cix_vaapi/utils -name '*.cpp') \
  $(find cix_vaapi/utils -name '*.c') \
  -I<libva-2.22-headers> -Icix_vaapi/ddi -Icix_vaapi/devices \
  -Icix_vaapi/devices/v4l2 -Icix_vaapi/devices/cme \
  -Icix_vaapi/utils/packer -Icix_vaapi/utils/parser \
  -Icix_vaapi/utils/extractor -Icix_vaapi/utils/tools \
  -Icix_media_engine/libcme/include -I/usr/src/cix-vpu-driver-1.0.2/driver/linux \
  /usr/lib/aarch64-linux-gnu/libcme.so.1
```

Gotchas: there is no `libcme.so` / `libva.so` dev symlink on the board, so
`-lcme` and `-lva` both fail — link the versioned `.so.1` / `.so.2` directly.
libva headers come from cixtech/cix_libva `va/`, with `va_version.h` generated
from `va_version.h.in` (VA-API 1.22.1 -> major 1, minor 22, micro 1).

Test without touching the packaged driver:

```sh
LIBVA_DRIVERS_PATH=/tmp/dri LIBVA_DRIVER_NAME=cixtest ./vaprobe2 /dev/dri/renderD129
```

Deployed on O6N via `dpkg-divert` (the vendor binary is owned by `cix-vaapi`):

```sh
D=/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so
dpkg-divert --add --rename --divert $D.distrib $D   # vendor copy -> .distrib
install -m 0755 cixtest_drv_video.so $D
# revert: rm $D && dpkg-divert --remove --rename $D
```

### Verifying hardware decode (measurement traps)

Enumeration is not decode. The reliable signature is the process holding
`/dev/video0` open alongside `renderD*`/`mali0`, cross-checked against
renderer CPU. Traps that produced wrong answers here:

- `ffmpeg -hwaccel vaapi` **silently falls back to software** and still exits
  0. Pass `-hwaccel_output_format vaapi` to make it fail hard; it then reports
  `Video: wrapped_avframe, vaapi(progressive)`.
- `timeout 40 ffmpeg ... & P=$!` captures *timeout*'s pid, not ffmpeg's, so
  `/proc/$P/fd` looks empty. Resolve the real child first.
- `about:gpu`'s "Video Decode: Hardware accelerated" line is a generic
  capability flag — it already read that way while the decode table was empty.
  Use the profile table, not that line.
- Chrome `--headless=new` fails on this board (`GLDisplayEGL::Initialize
  failed`), so `--dump-dom chrome://gpu` yields nothing useful.
- A second Chrome instance silently folds into the running one
  (`ProcessSingleton.NotifyResult = 1`) unless `--user-data-dir` is writable
  by the launching user.
- about:gpu exports reflect only the *currently running* GPU process; without
  restarting Chrome you re-serialise stale enumeration.

## libdrm-xf86drm-acpi-platform-identity.patch

Fixes libdrm's `drmParseOFBusInfo()` MODALIAS fallback for ACPI-enumerated
platform DRM devices: an ACPI modalias ends with ':', so the parsed bus name
is empty and identical for every device, and `drmGetDevices2()` folds all
ACPI DRM devices into one. On Sky1 (3× linlondp + panthor) only one device
survived enumeration, which broke Mesa device selection, panvk GPU discovery,
and wlroots' DRM device lookup. Verified on O6N: stock enumerates 1 device
with an empty name; patched enumerates all, correctly paired, uniquely named
(sysfs device basename, e.g. "CIXH5010:00").

Submission target: https://gitlab.freedesktop.org/mesa/drm (merge request;
the anongit and GitHub mirrors are read-only). Author identity:
Jason Perlow <jperlow@gmail.com>. Needs a gitlab.freedesktop.org account to
fork + push — the patch applies with `git am` on current main (the touched
fallback path is unchanged since 2.4.134).
