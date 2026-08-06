# Firefox — V4L2-M2M hardware video decode

Four patches, originally from the now-defunct **Sky1-Linux** project
(`firefox-sky1`, author Entrpi <entrpi@proton.me>, MIT/MPL as per that repo).
Preserved here because that project is gone; the repositories are mirrored to
our infrastructure. **Attribution belongs to the original author** — if any of
this is submitted upstream, it must be submitted as theirs, not ours.

| Patch | What it does |
|---|---|
| `Prefer-V4L2-M2M-over-VAAPI-for-hw-decode.patch` | try V4L2-M2M before falling back to VA-API |
| `Fix-V4L2-M2M-timestamp-handling.patch` | V4L2 stateful decoders do not set PTS/duration on output frames |
| `Add-V4L2-M2M-AV1-decoder-support.patch` | add `av1_v4l2m2m` to the decoder lookup (Firefox had h264/vp8/vp9/hevc only) |
| `Enable-V4L2-M2M-AV1-hardware-decode-check.patch` | bypass the VA-API-based `gfxVars::UseAV1HwDecode()` gate when V4L2 is available |

Build also needs `MOZ_ENABLE_V4L2 = 1` (set per-architecture in `debian/rules`).

## The interesting one

`Enable-V4L2-M2M-AV1-hardware-decode-check.patch` exists because Firefox gates
AV1 hardware decode behind `gfxVars::UseAV1HwDecode()`, which is derived from
**VA-API** detection. On a V4L2 platform that returns false, so Firefox never
even attempts V4L2 AV1:

```cpp
     case AV_CODEC_ID_AV1:
+#ifdef MOZ_ENABLE_V4L2
+      // V4L2-M2M AV1 support is checked later; allow the attempt
+      supported = true;
+#else
       supported = gfx::gfxVars::UseAV1HwDecode();
+#endif
```

**Chromium has the identical bug** in a different codebase — see
`../chromium/`, where `media/gpu/args.gni` computes

```gni
use_av1_hw_decoder = is_chromeos || (is_linux && use_vaapi) || ...
```

Two independent browser engines both assume *AV1 hardware decode implies
VA-API*, and both therefore exclude V4L2 SoCs. On this hardware the VPU
advertises AV1 (`v4l2-ctl --list-formats-out` → `'AV01'`) and decodes it
bit-exactly (verified against dav1d, matching MD5), so the assumption is simply
wrong here.

That symmetry is worth stating in either upstream submission: it is not a
platform quirk, it is a shared blind spot.

## Status here

Not yet built or verified on NCZ-OS. Two things are known:

- Sky1's **prebuilt** Firefox deb does not run on forky — it needs
  `libvpx.so.11` (we have 12), the same older-Debian soname mismatch that makes
  their ffmpeg debs unusable. Firefox must be rebuilt from source.
- Stock Debian `firefox-esr` already ships the V4L2-DRM decoder framework and
  the `v4l2test` prober, but its codec lookup knows only `h264_v4l2m2m` —
  confirmed by string comparison against Sky1's build, which adds
  `av1_v4l2m2m`, `hevc_v4l2m2m`, `vp8_v4l2m2m`, `vp9_v4l2m2m`.

So Firefox needs *both* these patches **and** a system ffmpeg carrying the AV1
V4L2-M2M patch in `../ffmpeg/`. Prefs alone are not enough — an earlier attempt
with stock `firefox-esr`, the four Sky1 prefs and a patched system ffmpeg failed
with *"Video can't be played because the file is corrupt"*, because disabling
`ffvpx` left it with no AV1 decoder it could reach.
