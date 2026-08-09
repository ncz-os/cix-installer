# cix-vpu-driver (amvx) patches

Patches against the CIX vendor VPU driver — the `amvx` kernel module that
drives the Arm Linlon MVE v8 and provides `/dev/video0`.

## Provenance

The source is CIX's vendor SDK (`cix-vpu-driver` 1.0.2), unpacked to
`/usr/src/cix-vpu-driver-1.0.2` and built via DKMS. On the O6N test board it is
**not dpkg-owned** — it was unpacked by hand from the SDK on ARGONAS, so there
is no package to carry a patch. Apply these to the DKMS source tree and rebuild:

```sh
cd /usr/src/cix-vpu-driver-1.0.2
patch -p1 < 0001-vp8-decode-framesize-4096.patch
dkms build   -m cix-vpu-driver -v 1.0.2 -k "$(uname -r)" --force
dkms install -m cix-vpu-driver -v 1.0.2 -k "$(uname -r)" --force
rmmod amvx && modprobe amvx
```

Verify with `v4l2-ctl -d /dev/video0 --list-framesizes=VP80`.

## Patches

### 0001-vp8-decode-framesize-4096.patch

`mvx_session_enum_framesizes()` grouped `MVX_FORMAT_VP8` into the same `case`
as H.263 and MPEG-4, reporting a maximum of 2048x2048 for VP8. The hardware
does considerably better than that.

Measured on Sky1, VP8 decode is **bit-exact against libvpx** at 2048x1152,
3840x2160, 4096x2304 and 4096x4096, and fails at 5120x2880 with
`capture buffer initialization (Input/output error)`. The real limit is
4096x4096.

The under-report was not cosmetic. V4L2 clients that honour
`VIDIOC_ENUM_FRAMESIZES` refuse to use hardware above the advertised size:

| | before | after |
|---|---|---|
| Chromium NCZ Sky1, VP8 1080p | hardware | hardware |
| Chromium NCZ Sky1, VP8 4K | **software fallback** | **hardware** |
| ffmpeg `vp8_v4l2m2m`, VP8 4K | hardware, bit-exact | hardware, bit-exact |

ffmpeg never consulted the enumeration, which is why the driver bug stayed
invisible until a browser was tested against the same clip. That divergence —
one client refusing what another was already doing correctly — is what pointed
at the enumeration rather than at the decoder.

Encode keeps the conservative 2048x2048; VP8 encode was not measured, and
raising a limit that has not been tested is how you ship a plausible
regression.

**Upstream-Status:** Pending. To be sent to CIX against the vendor driver.

## Upstream status (filed 2026-08-09)

Both patches sent to CIX as issues on
[`cixtech/cix_opensource__vpu_driver`](https://github.com/cixtech/cix_opensource__vpu_driver):

| Patch | Issue |
|---|---|
| `0001-vp8-decode-framesize-4096` | [#5](https://github.com/cixtech/cix_opensource__vpu_driver/issues/5) |
| `0002-decoder-capture-default-nv12` | [#6](https://github.com/cixtech/cix_opensource__vpu_driver/issues/6) |

Both bugs were re-verified as **still present upstream** on branch
`cix_mainline_upstream_dev` @ `5b9b07b` ("CIX P1 KERNEL 7.0 VERSION 1.0.2
RELEASE") before filing — VP8 still shares the 2048 case with H.263/MPEG-4 at
`driver/if/mvx_session.c:6828`, and `mvx_raw_fmts[]` still lists
`MVX_FORMAT_YUV420_AFBC_8` first.

**Filed as issues, not PRs, deliberately.** The repo has never received a pull
request, has no CONTRIBUTING, and its description ("Create ... via api")
suggests a push-mirror from an internal tree, which a PR could not merge into.
Issues are the only channel the repo demonstrably uses.

**Set expectations:** every existing issue there has **zero** comments,
including a licence-clarification request open since 2026-05-11. Assume no
response and keep carrying these downstream until proven otherwise.

**Licence note:** the repo has no LICENSE file and the sources carry no SPDX
identifier (only `(C) COPYRIGHT 2021-2021 Arm Technology (China) Co., Ltd.`),
but `driver/mvx_driver.c:40` declares `MODULE_LICENSE("GPL")`. That ambiguity is
issue #1 upstream and is unresolved.

**Note:** our installed DKMS source is already 1.0.2 with both fixes applied, so
these patches are carried forward, not pending application locally.
