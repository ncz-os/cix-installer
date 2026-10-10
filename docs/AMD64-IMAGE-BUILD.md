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

The entrypoint's mandatory `refresh-substrate` stage runs
`build/refresh-substrate.sh --arch amd64`: it fetches the newest Debian testing
netinst, verifies `SHA256SUMS.sign` against the committed Debian CD signing key,
caches it on ARGONAS, measures the substrate against the snapshot's indexes,
derives the snapshot pin, and rewrites `manifests/base.pin`. The Makefile's
`SUBSTRATE_SHA` is then read from `base.pin` (currently `123a250b...`), and
`downloads/debian-testing-amd64-netinst.iso` must match it (an empty
`downloads/` restores it from the ARGONAS substrate store). `make
check-substrate-pin ARCH=amd64` fails closed if the pin is stale (>8 days) or the
substrate is not authorized by the pinned snapshot. `NCZ_ONE_KERNEL=1` (the
`--full` default) enables the one-kernel filter (operator ruling 2026-10-10;
only OUR kernel ships) — see [ONE-KERNEL.md](ONE-KERNEL.md).

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
* Git-ignored inputs that stage 0/1 do not produce:
  - `assets/cix-debs/ncz-singularity-desktop_*_amd64.deb` — stage 0's
    `sinty-out-sync` copies the newest one into `build/sinty-out/`, and
    `verify-local-package-versions` refuses an empty set.
  - `build/ncz-screensavers-out/ncz-screensavers_<v>_amd64.deb` (at least the
    floor in `build/screensavers-version.env`) and the settings plugin via
    `make ssplugin-stage` (or `build/stage-screensaver-plugin.sh amd64`).
  - `assets/rescue/rescue-rootfs-amd64.tar.zst`, `assets/python311/`,
    `assets/wallpaper-debs/`. Missing wallpaper packs are built by stage 1; the
    Cygnus ArtistPack manifest is in-repo.
* The installer UI check samples the amd64 framebuffer: it proves the console
  never goes blank and that dialogs/progress advance; it cannot read dialog text.

Everything else (stages, gates, determinism, publish rules) is in
[IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md). Post-pass operator steps:
[IMAGE-RELEASE-RUNBOOK.md](IMAGE-RELEASE-RUNBOOK.md).
