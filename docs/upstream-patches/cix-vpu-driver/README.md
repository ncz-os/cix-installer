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
