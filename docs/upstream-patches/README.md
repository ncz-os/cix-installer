# Upstream patches pending submission

## cix-vaapi-queryconfigattributes-rtformat.patch

Fixes browser hardware video decode on Sky1. `MediaDevice::CreateConfig()` in
cix_vaapi stores only the attributes the caller passed to `vaCreateConfig()`,
and `MediaDevice::QueryConfigAttributes()` echoes that array back, so a config
created with `(attrib_list = NULL, num_attribs = 0)` reports zero attributes.
Chromium's `VASupportedProfiles::FillProfileInfo_Locked()` creates exactly such
an attribute-less config specifically so the driver will enumerate its RT
formats, finds no `VAConfigAttribRTFormat`, and rejects every profile. The
rejection goes through `DLOG_IF()`, compiled out of release builds, so it fails
*silently* — about:gpu shows an empty decode table while ffmpeg and mpv work
fine on the same driver, because they never call `vaQueryConfigAttributes()`.

The patch records the driver's own RTFormat in `CreateConfig()` when the caller
supplies none, sourcing it from the existing `GetConfigAttributes()` dispatcher
so v4l2/cme keep control of what they advertise.

Verified on O6N (.3) with Chrome 151, driver built from cix_vaapi `main`
(6e03daa, "Multimedia SDK 2026Q2"):

| | `vaQueryConfigAttributes` | Chrome `FillProfileInfo` failures | about:gpu decode table |
|---|---|---|---|
| stock  | 0 attribs, all 7 pairs | 15 | empty |
| patched| 1 attrib (`RTFormat`)  | 0  | 9 profiles, 144x144–8192x8192 |

AV1Profile0 correctly reports `YUV420|YUV420_10` via the existing
`IS_10BIT_PROFILE()` path. No regression: `ffmpeg -hwaccel vaapi` decodes
unchanged and `vaQuerySurfaceAttributes()` still returns its full set.

Submission target: https://github.com/cixtech/cix_vaapi. Author identity:
Jason Perlow <jperlow@gmail.com>. Related: cixtech/cix_libva#7 (the issue is
filed against cix_libva, but the defect is in cix_vaapi).

### Reproducers — `cix-vaapi-repro/`

`vaprobe.c` replays Chrome's earlier `FillProfileInfo_Locked` steps (RTFormat
check, `vaCreateConfig` with required attribs, two-pass
`vaQuerySurfaceAttributes`); all of these already pass on the stock driver.
`vaprobe2.c` replays the final block — attribute-less `vaCreateConfig` then
`vaQueryConfigAttributes` — and is the one that shows `num_config_attributes = 0`.

Build the driver from source on the board (no cmake, no CIX SDK tarball needed):

```sh
# headers: cixtech/cix_media_engine libcme/include, plus the VPU UAPI header
# already present on NCZ-OS at /usr/src/cix-vpu-driver-*/driver/linux
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
from `va_version.h.in` (VA-API 1.22.1 → major 1, minor 22, micro 1).

Test a build without touching the packaged driver:

```sh
cp cixtest_drv_video.so /tmp/dri/
LIBVA_DRIVERS_PATH=/tmp/dri LIBVA_DRIVER_NAME=cixtest ./vaprobe2 /dev/dri/renderD129
```

Deployed on O6N via `dpkg-divert` (the vendor binary is owned by `cix-vaapi`):

```sh
D=/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so
dpkg-divert --add --rename --divert $D.distrib $D   # vendor copy -> .distrib
install -m 0755 cixtest_drv_video.so $D
# revert: rm $D && dpkg-divert --remove --rename $D
```

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
