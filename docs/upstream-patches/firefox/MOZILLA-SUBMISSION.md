# Mozilla submission: multi-object DRM PRIME descriptors

## What is being submitted

One change, to `dom/media/platforms/ffmpeg/FFmpegVideoFramePool.cpp`:
`FFmpegDescToVA()` mishandles DRM PRIME descriptors that use more than one
dmabuf object.

**Deliberately NOT submitted** — the two gate relaxations in
`FFmpegVideoDecoder.cpp` (the per-codec `gfxVars::Use*HwDecode()` checks and
the hardware-WebRender requirement). They are platform-specific, their benefit
is unproven because playback on our hardware still fails afterwards, and
bundling unproven changes with a real bug fix is how the real bug fix gets
rejected. They stay downstream in `0003-multi-object-drm-prime.patch`.

## The bug

`FFmpegDescToVA()` assumes every NV12 and YUV420 descriptor is a single
contiguous dmabuf holding all planes, and reads only `objects[0]`:

```c
MOZ_ASSERT(aDesc.nb_objects == 1);
vaDesc.objects[0].fd = aDesc.objects[0].fd;
vaDesc.layers[1].offset[0] = offset + uncrop_width * uncrop_height;
```

True for VA-API and Vulkan. **False for V4L2 multiplanar drivers**, which
allocate one buffer per plane and therefore export one dmabuf per plane.

Because `MOZ_ASSERT` compiles out in release builds, this does not fail
loudly. It constructs a descriptor naming only the luma FD, with chroma
offsets computed as if chroma lived inside that same buffer. EGL then rejects
the import, `GetVideoFrameSurface()` returns null, the caller reports a decode
error — and `MediaFormatReader` converts any decode error from a
hardware-accelerated decoder into `mHardwareDecodingDisabled = true`
(`MediaFormatReader.cpp`, the `XP_LINUX` block). So the visible symptom is
silent permanent fallback to software decode, with nothing in the log naming a
cause.

## Evidence

Measured on CIX Sky1 (Radxa Orion O6N, Arm Linlon MVE v8 VPU, Mali-G720 /
libmali), Firefox 153.0.3, against a libavcodec patched to export DRM PRIME
from `v4l2_m2m`.

Before, with a 3-object YUV420 descriptor:

```
egl-import-ok      plane=0 fourcc=R8 1920x1080 offset=0
egl-import-FAILED  plane=1 fourcc=R8  960x540  offset=2073600
```

Offset 2073600 is exactly `stride * height` — past the end of a luma-only
buffer. After the change, all three planes import and `CreateImageV4L2`
returns success for every frame.

Incidental finding worth noting in review: this driver's libmali EGL imports
single-plane `R8` dmabufs but rejects `GR88`, so the YUV420 three-`R8` layout
works where the NV12 `R8`+`GR88` layout does not. Both branches are fixed here
regardless.

## Honest limitation

This fix is necessary but **not sufficient** for working playback on our
hardware. With it applied, import succeeds and no fallback decoder is created,
but playback still terminates with `NS_ERROR_DOM_MEDIA_FATAL_ERR` from a point
we have not yet isolated. The descriptor handling is wrong on its own terms and
worth fixing on its own terms; we are not claiming it makes V4L2 decode work
end to end. That should be stated plainly in the bug.

## How to submit

1. **Bugzilla account** — https://bugzilla.mozilla.org/ — and enable
   two-factor authentication, which Phabricator registration requires.
2. **Phabricator** — https://phabricator.services.mozilla.com/ — "Log In or
   Register" hands off to Bugzilla, then creates the linked Phabricator
   account.
3. **moz-phab** — `pip3 install MozPhab`, then run `moz-phab install-certificate`
   from inside the tree; it prints a URL that issues an API key, which is
   stored in `~/.arcrc`.
4. File the bug under **Core :: Audio/Video: Playback**, assign it to yourself,
   then `moz-phab submit` from the branch.

No CLA is required — Mozilla does not use one for Firefox contributions.

Patch: `0004-mozilla-multi-object-drm-prime.patch` in this directory.
