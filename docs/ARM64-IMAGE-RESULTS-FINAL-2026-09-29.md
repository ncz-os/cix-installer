# arm64 final image ncz-os-arm64-20260929-28a868c (with ncz-screensavers 0.3.3): build and gate record

Built on ULTRA from `release/arm64-final-2026-09-29` at `28a868c` (later commits are docs only).

| item | value |
|---|---|
| file | `ncz-os-arm64-20260929-28a868c.img` |
| size | 8,927,576,064 bytes |
| sha256 | `1520d161a98f61047f3ff4532444413ad4012c079d8b066b14e09d3bc45abb5f` |
| shipped to | `jperlow@192.168.207.4:~/Downloads/` with `.sha256` and `.receipt.json` (sha256 re-verified on arrival) |
| ncz-screensavers | 0.3.3 (arm64 deb sha256 `bde2a5fd301049cc65192f635f3d7fd8ff3741f2ce32074ebf3d85b9d7b00978`, source `consolidated/ncz-os-mvp` 9ef00ca), highest version under `/mnt/argonas-projects/ncz-screensavers-debs` at build time |
| d-i substrate | pinned, installer build 20260921, sha256 `bcdea126...6944f67` |
| default-boot kernel | `7.2.8-sky1-ncz` |

Builds of the same branch with 0.3.2 (`ecdb95e`) also passed the gate; 0.3.3 superseded it before shipping.

## Gate: KVM phase 1 + 2 PASS

Phase 1 reached the finish stage with no ship-critical hook failure; phase 2 exited rc=124 and reached
userspace. The installed-target check (debugfs on the installed root) passed:

- the earlier accelerator set (16/16 firmware blobs, aipu KMD 6.2.0 DKMS-built, amvx, cixdec0 helper,
  `h264_v4l2m2m` ffmpeg, both browsers);
- VA-API: `libcix_va_drv_video.so`, the `linlondp_drv_video.so` compat symlink, the matched
  `cix-libva2` runtime, `LIBVA_DRIVER_NAME=libcix_va`, and `/etc/mpv/mpv.conf` with `hwdec=vaapi`;
- ncz-screensavers 0.3.3 installed with `ncz-screensaver`, `ncz-screensaver-settings`,
  `ncz-screensaver-idled` (+ enabled user unit), `ncz-screensaver-run`, the compiled
  `dev.ncz.screensaver` schema and 84 hack binaries, and `ncz-idle-manager` NOT enabled.

Not proven by KVM: actual VA-API decode/encode on the VPU, NPU inference, GPU/EGL, screensaver rendering and
the physical boot. Those are operator-only on the real O6N.

## What changed since 18e8a14

- VA-API debs (`cix-vaapi`, `cix-libva*`, `cix-libcme`) found in the cix-mm SDK archive on ARGONAS and staged.
- d-i substrate pinned (Makefile), pinned ISO stored on ARGONAS.
- Gate no longer skips the screensaver assertions silently; VA-API, mpv and screensaver assertions added.
- desktop-mirror closure re-sorted after adding local packages (`comm: input is not in sorted order`).
- Stable, machine-derived hostname suggestion (DMI uuid/serial, onboard wireless MAC, PCI NIC MAC, random),
  identical helper as the amd64 branch `fix/amd64-early-command-hostname-2026-09-29`.
