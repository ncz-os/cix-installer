# Upstream patches pending submission

## cix-vaapi/ — browser hardware video decode on Sky1

Six patches against https://github.com/cixtech/cix_vaapi (`main`, 6e03daa,
"Multimedia SDK 2026Q2"). Apply with `git am`.

**Result: H.264 and VP9 hardware decode work in Chromium; AV1 does not** — AV1
is blocked by a vendor design decision, documented below and in
`docs/HW-VIDEO-DECODE-STATUS.md`.

Every defect below failed *silently*: no error surfaced from libva, the driver
or the browser, which is why the platform simply looked unsupported.

| # | Defect |
|---|---|
| 0001 | `vaQueryConfigAttributes` returns zero attributes for an attribute-less config, so Chromium — which creates one specifically to enumerate RT formats — rejects every profile. Its diagnostic is `DLOG_IF`, compiled out of release builds. |
| 0002 | A context created with `num_render_targets == 0` (legal; Chromium does it) gets no surface pool, so capture buffers bind to nothing and the first `VIDIOC_QBUF` fails `EINVAL` with an uninitialised plane fd. |
| 0003 | `vaExportSurfaceHandle` ignores `VA_EXPORT_SURFACE_SEPARATE_LAYERS` and returns one layer holding both planes; Chromium requires one plane per layer. Returned `VA_STATUS_SUCCESS`, so it failed invisibly. |
| 0004 | `vaCreateBuffer(data == NULL)` is rejected although the spec permits it, and payloads are consumed at creation time instead of in submission order. Chromium's VP9 **and** AV1 paths create their picture parameter buffer empty; only H.264 passes it inline. |
| 0005 | `PackerAV1::SaveSliceData()` calls `back()` on an empty vector, aborting the **client** process (`exit_code=134`). |
| 0006 | `vaExportSurfaceHandle` hands the client a freshly allocated orphan surface instead of one bound to a capture buffer, so the decoder writes where the client never looks. |

0006 is the subtle one and the reason to be careful with 0002–0004 alone: with
those applied but not 0006, Chromium plays **flat green video** at full speed —
VPU node open, frames counted, almost none dropped, CPU low. Every proxy signal
said "working". Only looking at the screen revealed it.

### Measured result (O6N, Chromium 151, screenshot-verified)

| | stock | patched |
|---|---|---|
| about:gpu decode profiles | none | 9 |
| `FillProfileInfo_Locked failed` | 15 | 0 |
| H.264 1080p | software | **VPU, correct picture, 0 dropped** |
| VP9 720p | software | **VPU, correct picture** |
| renderer CPU during playback | ~27% | **~3.5%** |

No regressions: `ffmpeg -hwaccel vaapi -hwaccel_output_format vaapi` still
decodes H.264 and VP9, `vaQuerySurfaceAttributes` still returns its full set,
`vainfo` still enumerates, desktop/greetd/NPU service unaffected.

### AV1 — the part these patches do NOT fix

AV1 stalls on the **stock** driver too, in Chromium and ffmpeg alike, because
`cix_vaapi`'s AV1 path requires a **CIX-private libva extension**:
`cix_libva` overlays a vendor struct on the standard
`VADecPictureParameterBufferAV1`'s reserved padding behind a magic value
`0x31425643` (`'CVB1'`). Measured with Chromium:

```
DIAG AV1 ext: magic=0x00000000 expected=0x31425643 -> NULL
```

Standard clients zero `va_reserved[]`, so `GetPpsBuffer()` (the raw frame-header
OBU bytes), `CopySlice()` (`tile_size_bytes`) and `PackRepeatFrame()` all get
nothing, and the VPU is handed neither a frame header nor framed tile data.
Separately, the driver only obtains an AV1 sequence header from
`VASequenceParameterBufferType` — which VA-API AV1 decode does not define.

Supporting stock clients therefore requires the driver to serialise the frame
header itself and derive tile sizes from `VASliceParameterBufferAV1`. That is a
vendor-side change, so 0006 also **withholds the AV1 profile** unless
`CIX_VAAPI_ENABLE_AV1=1` — otherwise clients select hardware AV1 and hang
instead of cleanly falling back to software.

Submission target: https://github.com/cixtech/cix_vaapi. Author identity:
Jason Perlow <jperlow@gmail.com>. Related: cixtech/cix_libva#7 (filed against
cix_libva; all defects are in cix_vaapi).

### Reproducers and verification — `cix-vaapi-repro/`

`vaprobe.c` replays Chromium's early `FillProfileInfo_Locked` steps; `vaprobe2.c`
replays the final block and shows `num_config_attributes = 0` before 0001.

Build on the board (no cmake, no CIX SDK tarball needed):

```sh
# CME headers: github.com/cixtech/cix_media_engine libcme/include
# VPU UAPI header ships in cix-vpu-driver: /usr/src/cix-vpu-driver-*/driver/linux
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

There is no `libcme.so`/`libva.so` dev symlink on the board — link the versioned
`.so.1`/`.so.2` directly. Test without touching the packaged driver via
`LIBVA_DRIVERS_PATH=/opt/testdri LIBVA_DRIVER_NAME=<name>`; note the directory
must be readable by the browser's user (`/root` is not). Deploy with
`dpkg-divert --add --rename --divert $D.distrib $D`, revert with
`dpkg-divert --remove --rename $D`.

**Verify by looking at the picture.** `docs/HW-VIDEO-DECODE-STATUS.md` lists the
measurement traps that produced confidently wrong answers here — including that
plain `ffmpeg -hwaccel vaapi` silently falls back to software and still exits 0.

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
