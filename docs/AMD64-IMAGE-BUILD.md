# Building the amd64 install image

> **Superseded.** The authoritative, single-source process — the one command,
> the inputs/pins, the stages, the determinism contract and every gate — is
> [IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md). This file keeps only the
> amd64 host specifics.

## Host

ACHILLES (`192.168.207.11`, x86_64, rootful podman, `/dev/kvm` used as root).
`--arch both` reaches it as `NCZ_AMD64_HOST`. Heavy builds never run on STUDIO.

```sh
build/build-image.sh --arch amd64 --full
# or: make release-image ARCH=amd64 RELEASE_IMAGE_ARGS="--full"
# plan first: build/build-image.sh --arch amd64 --full --dry-run
```

## amd64-specific notes

* Kernel pin: `assets/kernel/amd64-stable/KVER` (today
  `7.3.0-rc6-4-t2-edge-aer9010`), staged from the pool by
  `build/stage-amd64-kernel.sh`.
* The tracked `assets/kernel/mainline` symlink uses the ULTRA spelling
  `/mnt/argonas-yocto-shared`; on a host where only
  `/mnt/argonas/datapool/yocto-shared` exists, preflight bind-mounts it
  automatically.
* Substrate: `downloads/debian-testing-amd64-netinst.iso`, pinned by
  `SUBSTRATE_SHA`; empty `downloads/` is restored from the ARGONAS cache.
* The installer UI check samples the amd64 framebuffer: it proves the console
  never goes blank and that dialogs/progress advance; it cannot read dialog text.

Everything else (stages, gates, determinism, publish rules) is in
[IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md). Post-pass operator steps:
[IMAGE-RELEASE-RUNBOOK.md](IMAGE-RELEASE-RUNBOOK.md).
