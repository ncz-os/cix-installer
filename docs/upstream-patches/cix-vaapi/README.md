# CIX VA-API upstream patches

These patches target <https://github.com/cixtech/cix_vaapi>. As of
2026-08-26 the newest public upstream commit is:

```text
6e03daa4 CIX vaapi for Multimedia SDK 2026Q2 release
```

Submit upstream by opening a standard GitHub pull request against
`cixtech/cix_vaapi`; this repository has no Gerrit flow and no CONTRIBUTING file
in the public two-commit source tree.

## 0001-Report-RTFormat-from-vaQueryConfigAttributes-for-att.patch

Fixes Chromium rejecting every CIX VA-API decode and encode profile after its
second, attribute-less config probe.

Root cause: `MediaDevice::CreateConfig()` stores only the attributes passed by
the client. For the valid VA-API call:

```c
vaCreateConfig(dpy, profile, entrypoint, NULL, 0, &cfg);
```

the stored `DeviceConfig::attribs` vector is empty. Later,
`MediaDevice::QueryConfigAttributes()` returns that vector verbatim, so Chromium
sees `num_attribs = 0` and cannot find `VAConfigAttribRTFormat`.

The driver already knows the real format mask through the backend
`GetConfigAttributes(profile, entrypoint, ...)` dispatcher. The patch records an
effective `VAConfigAttribRTFormat` during `CreateConfig()` whenever the caller
omitted it, while preserving any explicit RTFormat supplied by the caller.

Expected acceptance result after building and running with the patched driver:

```text
num_attribs > 0
VAConfigAttribRTFormat present
RTFormat includes VA_RT_FORMAT_YUV420 at minimum
```

This is the path Chromium's `VaapiWrapper::FillProfileInfo_Locked()` depends on
when it creates a second config with `nullptr, 0` so the driver reports its
default internal formats.

## Verification status

Source review:

- Confirmed the root cause in upstream `devices/device_common.cpp`: config
  creation copies the caller's attribute list, and config query returns the
  stored list.
- Confirmed both CIX backends already implement `GetConfigAttributes()` for
  `VAConfigAttribRTFormat`.
- Ran `git diff --check` on the upstream patch.
- Ran zoder adversarial review twice. First pass raised only scope comments;
  second pass approved the targeted RTFormat fix with no blocking defects.

Build/test attempts on 2026-08-26:

- Local workspace build blocked at CMake configure: `pkg-config` cannot find
  `libva`.
- O6N board `192.168.207.3` has `libva-dev`, `/dev/dri/renderD128`, `g++`, the
  runtime `libcme.so.1`, and the VPU control header, but no `cmake` and no
  `cme.h`.
- A manual board compile reached source compilation but could not complete
  because SDK development headers were missing: `cme.h` was absent, and the
  first compile attempt also needed explicit include paths for VPU/libdrm
  headers. No driver was installed or deployed.

Because the available systems lack the full CIX VA-API SDK build environment,
the patched shared object and runtime acceptance repro were not produced in this
run. To complete hardware verification, build in an SDK environment containing
`cmake`, `libva-dev`, libdrm development headers, `mvx-v4l2-controls.h`,
`cme.h`, and the matching `libcme` development files, then run the repro with an
isolated driver path:

```bash
mkdir build
cmake -S . -B build
cmake --build build -j"$(nproc)"

mkdir -p /tmp/cix-vaapi-patched-dri
cp build/libcix_va_drv_video.so /tmp/cix-vaapi-patched-dri/
LIBVA_DRIVER_NAME=cix_va \
LIBVA_DRIVERS_PATH=/tmp/cix-vaapi-patched-dri \
./repro /dev/dri/renderD128
```

Do not replace `/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so` on a live
system until the operator reviews the patch and build artifact.

