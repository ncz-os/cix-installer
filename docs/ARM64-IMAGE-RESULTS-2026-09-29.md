# arm64 image ncz-os-arm64-20260929-18e8a14: build and gate record

Built on ULTRA (Fedora Asahi, SELinux enforcing) from branch
`integrate/arm64-image-2026-09-29` at `18e8a14` (later commits on the branch are
gate tooling and docs only; the image did not change).

| item | value |
|---|---|
| file | `ncz-os-arm64-20260929-18e8a14.img` |
| size | 8,927,576,064 bytes (8.4 GiB) |
| sha256 | `a1bc58442ed37e674802f0bd3b48aed69fbaa369d28abe4f5c0a082051d4484a` |
| shipped to | `jperlow@192.168.207.4:~/Downloads/` (sha256 re-verified on arrival) |
| default-boot kernel | `7.2.8-sky1-ncz` |
| d-i substrate | Debian weekly netinst, installer build 20260921 (unpinned in the Makefile; see ARM64-IMAGE-BUILD.md) |

## Gate: KVM phase 1 + 2 PASS

- phase 1: install reached the finish stage with no ship-critical hook failure
  (76 post-install steps DONE; optional-hook warnings: `13-firmware-bom` (0 of 40
  packages missing after the per-package retry), `50-update-manager`,
  `58-screensaver-chooser`; the 09-27 image also warned on 25, 38, 47 and 88).
- installed-target accelerator check (`build/verify-installed-target-arm64.sh`,
  reads the installed root with debugfs): 16/16 `.fwb` + `dsp_fw.bin` + Mali CSF
  blob; `aipu` KMD 6.2.0 DKMS-built for 7.2.8-sky1-ncz (not 5.11.0) with
  `/usr/src/aipu-6.2.0` and dkms state; `amvx` registered in modules.dep;
  `/usr/bin/load-modules.sh` creating `/dev/video-cixdec0`; libavcodec carrying
  `h264_v4l2m2m`; `google-chrome-stable` and `chromium-ncz-sky1` installed.
- phase 2: qemu rc=124, "installed system reached userspace" (rc=124 with an empty
  boot.log is the expected pass signal).

## Not proven by KVM (needs the real O6N, operator only)

The NPU inference test (`noe_benchmark` expecting `Driver UMD: 6.2.0, KMD: 6.2.0`),
VPU decode/encode on hardware, GPU/EGL bring-up, and the physical boot itself.
No VA-API driver for the Sky1 VPU ships: `libcix_va_drv_video.so` comes from the
`cix-vaapi`, `cix-libva*` and `cix-libcme` debs, none of which is staged in
`assets/cix-debs`, so `84-vpu-vaapi.sh` exits with "cix-vaapi package not
installed, skipping" and `vainfo` cannot open a driver on the installed system
(only Mesa's `*_drv_video.so` files are present).

## Defects found and fixed while building this image

1. Stage 2 (`shutil.copytree` on the dangling `scripts/kernel-doc` symlink;
   `headers-dir.native-prepare-rejected` staged; empty `BUILD_SHA`): zoder's fix
   from `fix/arm64-stage2-2026-09-29`, plus a worktree bug (`.git` is a file in a
   worktree) and two review findings (anchored prune globs, scoped Makefile error).
2. Git-ignored accelerator inputs missing (1 of 22 Cix debs, 2 of 29 firmware files)
   while every gate passed: `build/verify-arm64-inputs.sh`, fail-loud
   `12-sky1-firmware.sh`, ship-critical 12/25 on arm64, and the installed-target
   verifier (both directions tested).
3. `preseed/early_command` at 15,634 bytes broke d-i media detection on arm64
   ("Incorrect installation media detected"): hostname logic moved to
   `preseed/hostname-suggest.sh`, budget enforced by `build/check-early-command-size.sh`.
   The amd64 T2 branch (`fix/chimera-boot-firmware-2026-09-28`, commit `9ec1e87`)
   carries the same defect.
4. `late.sh` asset union-sync died under `set -e` on the dangling baked
   `assets/kernel/edge` symlink once the media carried a populated `edge/`.
5. Freshness gate flagged an orphan kernel-staging directory
   (`sky1-7.2.8-20260927`, byte-identical to `r277`); moved to
   `kernel-staging-archive/`.
