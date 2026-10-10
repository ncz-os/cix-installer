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

## arm64-specific notes

* **Stage 1 runs on the bare host** (`build/build-squashfs-layers.sh all`), not
  in the container: it drives `mount`/`chroot` and podman for `mmdebstrap`
  itself. Stages 0/2 run in the rootful `localhost/ncz-imagebuild:trixie`
  container. The entrypoint encodes this.
* Kernel pin: `assets/kernel/mainline` → a staging dir named
  `r<N>-<kver>-sky1-ncz-<date>` (today r285, unified 7.3).
* Substrate: the pinned Debian testing netinst (arm64) kept on ARGONAS at
  `ncz-os-assets/substrate/`; verified against the committed SHA256SUMS/GPG on
  refresh. An empty `downloads/` restores it; the build refuses to float.
* `verify-arm64-inputs.sh` fails the image stage if the git-ignored inputs
  (`assets/sky1-firmware/`, the `cix-*` debs, `assets/rescue/`,
  `assets/python311/`, `assets/npu/`, `assets/wallpaper-debs/`) are not staged.
* Scratch `TMPDIR` **must** be under the tree; `/tmp` on ULTRA is a tmpfs.

Everything else (stages, gates, determinism, publish rules) is in
[IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md). Post-pass operator steps:
[IMAGE-RELEASE-RUNBOOK.md](IMAGE-RELEASE-RUNBOOK.md).
