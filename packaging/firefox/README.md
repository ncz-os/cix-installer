# Firefox — V4L2 hardware decode

**This directory exists for one patch, and should be deleted when that patch
lands upstream.**

## The finding

Firefox 153 already ships V4L2 decoder selection for all five codecs —
`h264/vp8/vp9/hevc/av1_v4l2m2m`. entrpi's decoder patches, which we had been
rebasing onto ESR 140, went upstream somewhere between 146 and 153 and are now
**obsolete**. ESR 140 carries only `h264_v4l2m2m`.

What remains is a single gate. `ShouldEnableLinuxHWDecoding()` decides per
codec:

```c
case AV_CODEC_ID_H264:
  supported = gfx::gfxVars::UseH264HwDecode();
```

Those `gfxVars` are populated from Firefox's **VA-API** probe. On a V4L2-M2M-only
platform they are all false, so the function returns "disable" before
`InitHWDecoderIfAllowed()` runs and `InitV4L2Decoder()` is never called.

MEASURED on stock Mozilla 153.0.3, arm64, on a Radxa Orion O6: the FFmpeg module
reports it supports `video/avc`, `video/vp8`, `video/vp9`, `video/hevc` and
`video/av1` — and 629 lines of `PlatformDecoderModule` logging contain **no V4L2
line at all**. `/dev/video*` is never opened. The decoders are present and
reachable; only this gate stands in front of them.

The patch adds an `#ifdef MOZ_ENABLE_V4L2` bypass to all five cases, letting the
V4L2 init decide. Where no matching `v4l2m2m` decoder exists,
`avcodec_find_decoder_by_name()` returns null, `InitV4L2Decoder()` fails, and the
existing fall-through to VA-API and then software is unchanged.

## Why it should go upstream rather than be maintained

This is not Sky1-specific. Any platform with V4L2-M2M hardware and no VA-API
hits it. Carrying a Firefox fork means owning a browser's security cadence —
the same commitment as Chromium — for four lines of `#ifdef`.

`check-upstream.sh` runs in the pipeline as a reminder to check whether the fix
has landed, because the correct outcome is deleting this directory and shipping
Mozilla's own arm64 packages.

## Build notes

Native arm64 only; Mozilla's build system does not cross-compile cleanly here.

`mach bootstrap` could not reach `firefoxci.taskcluster-artifacts.net` from
cixmini, so the toolchain it would fetch had to be installed by hand:
`llvm clang lld libclang-dev`, `cbindgen` via cargo, and the usual GTK/ALSA
development packages. `--without-wasm-sandboxed-libraries` avoids the WASI
sysroot that bootstrap would also have supplied; it is a hardening feature,
unrelated to what this patch tests.

There is no `--enable-v4l2` option — `toolkit/moz.configure` sets
`MOZ_ENABLE_V4L2` automatically for `aarch64` with the GTK toolkit, and passing
the flag is a hard configure error.

Building through Mozilla's own tree also sidesteps the `clang` SIGSEGV in
`gfx/wr/swgl` (exit 139) that blocked every clean Debian ESR packaging build.

## Fuzz policy

A patch applying with fuzz fails the build. A hunk landing slightly off could
end up somewhere that no longer gates anything, producing a browser that
compiles and silently decodes in software — indistinguishable from success
without a hardware check. That is exactly how the earlier ESR patch set went
unnoticed for weeks.

The build additionally asserts that at least five `MOZ_ENABLE_V4L2` blocks are
present after patching, so an upstream rename cannot quietly neuter it.
