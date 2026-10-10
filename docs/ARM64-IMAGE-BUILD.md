# Building the arm64 (Sky1 / Orion O6N) install image

> **Superseded.** The authoritative, single-source process — the one command,
> the inputs/pins, the stages, the determinism contract and every gate — is
> [IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md). This file keeps only the
> arm64 host specifics.

## Host

ULTRA (`192.168.207.88`, aarch64, SELinux enforcing, pubkey-only ssh).
`--arch both` reaches it as `NCZ_ARM64_HOST`. Heavy builds never run on STUDIO.

```sh
build/build-image.sh --arch arm64 --full
# plan first: build/build-image.sh --arch arm64 --full --dry-run
```

The entrypoint's mandatory `refresh-substrate` stage runs
`build/refresh-substrate.sh --arch arm64`: it fetches the newest Debian testing
arm64 netinst, verifies `SHA256SUMS.sign` against the committed Debian CD signing
key, caches it on ARGONAS (`ncz-os-assets/substrate/`, keeping the last two),
derives the snapshot pin, and rewrites `manifests/base.pin`. The Makefile's
`SUBSTRATE_SHA` is read from `base.pin` (currently `b6f455d1...`; the arm64 ISO
is kept at `.../debian-testing-arm64-netinst-20261010-b6f455d1.iso`, ULTRA:
`/mnt/argonas-projects/ncz-os-assets/substrate`). An empty `downloads/` restores
it from there; if it cannot, the build refuses instead of floating. `make
check-substrate-pin ARCH=arm64` fails closed if the pin is stale (>8 days) or the
substrate is not authorized by the pinned snapshot. Debian republishes the
filename weekly, so the refresh+cache step is what keeps the pin stable.

## arm64-specific notes

* **Stage 1 runs on the bare host** (`build/build-squashfs-layers.sh all`), not
  in the container: it drives `mount`/`chroot` and podman for `mmdebstrap`
  itself. Stages 0/2 run in the rootful `localhost/ncz-imagebuild:trixie`
  container. The entrypoint encodes this.
* Kernel pin: `assets/kernel/mainline` → a staging dir named
  `r<N>-<kver>-sky1-ncz-<date>` (today r285, unified 7.3); provenance in the
  staging dir's `PROVENANCE.txt` and `assets/kernel/sky1-manifest.json`. There is
  no `assets/kernel/edge` any more; a directory with any other prefix inside
  `/mnt/argonas-yocto-shared/kernel-staging` fails preflight gate [3] (move it to
  `kernel-staging-archive/`, do not delete).
* Substrate: the pinned Debian testing netinst (arm64) kept on ARGONAS at
  `ncz-os-assets/substrate/`; verified against the committed SHA256SUMS/GPG on
  refresh. An empty `downloads/` restores it; the build refuses to float.
* `NCZ_ONE_KERNEL=1` (the `--full` default) enables the one-kernel filter
  (operator ruling 2026-10-10; only OUR kernel ships) — see
  [ONE-KERNEL.md](ONE-KERNEL.md).
* `verify-arm64-inputs.sh` fails the image stage if the git-ignored inputs are
  not staged:
  - `assets/sky1-firmware/`: the 29-file canonical set (16 `.fwb`,
    `dsp_fw.bin`, `arm/mali/arch12.8/mali_csffw.bin`, `mediatek/`, `rtw89/`),
    from `/mnt/argonas-projects/cix-installer/assets/sky1-firmware` on ULTRA.
  - `assets/cix-debs/*.deb`: at least 22, including `cix-gpu-umd`,
    `cix-libglvnd`, `cix-mesa`, `cix-noe-umd`, `cix-npu-driver-dkms` (aipu
    6.2.0), `cix-vpu-driver-dkms`, `cix-gpu-kmd-dkms`, `panthor-cix-dkms`,
    `cix-firmware`, plus the VA-API set (`cix-vaapi`, `cix-libva2`,
    `cix-libva-drm2`, `cix-libva-wayland2`, `cix-libva-x11-2`,
    `cix-libva-glx2`, `cix-libcme`; from the cix-mm SDK archive on ARGONAS).
  - `assets/rescue/rescue-rootfs-arm64.tar.zst`, `assets/python311/`,
    `assets/npu/`, `assets/sinty-nm/`, `assets/wallpaper-debs/`.
* Scratch `TMPDIR` **must** be under the tree; `/tmp` on ULTRA is a tmpfs.
* The arm64 KVM install gate is **UNPROVEN** as of r203 (the installaudit
  branch did not rebuild/re-gate arm64); the Mali payload must be validated on
  hardware before an arm64 image is accepted.

Everything else (stages, gates, determinism, publish rules) is in
[IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md). Post-pass operator steps:
[IMAGE-RELEASE-RUNBOOK.md](IMAGE-RELEASE-RUNBOOK.md).
