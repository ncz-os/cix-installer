# Building the amd64 install image on PROTEUS

This is the sequence that produced `ncz-os-amd64-20261007-1bbf33df.img`
(r200 candidate, `GATE PASS (phase 1+2)`). It mirrors
[ARM64-IMAGE-BUILD.md](ARM64-IMAGE-BUILD.md). Heavy builds never run on STUDIO.
PROTEUS (192.168.207.68, Fedora x86_64, rootful podman, `/dev/kvm` needs sudo)
is the amd64 image host. Scratch stays local to PROTEUS under `~/Projects`;
only kernel staging, the image archive and pinned inputs live on ARGONAS.

## 0. Preconditions (each was a real failure)

1. A fresh clone or worktree under `~/Projects/<dir>` (never `/tmp`: on
   PROTEUS it is a 16G tmpfs). Set `TMPDIR` under that directory.
2. `localhost/ncz-imagebuild:trixie` in BOTH podman stores. A prune deletes it.
   Rebuild it from `build/containers/Containerfile.ncz-imagebuild` with
   `sudo podman build`, then `sudo podman save` and `podman load` it into the
   rootless store.
3. Kernel: `build/stage-amd64-kernel.sh` copies the build that matches the
   committed pin `assets/kernel/amd64-stable/KVER` (today
   `7.3.0-rc6-4-t2-edge-aer9010`) from `<yocto-shared>/kernel-staging`. On
   PROTEUS that is `/mnt/argonas/datapool/yocto-shared`; the tracked
   `assets/kernel/mainline` symlink uses the ULTRA spelling
   `/mnt/argonas-yocto-shared`, which must also be mounted.
4. Substrate: **`make refresh-substrate ARCH=amd64` is the MANDATORY first
   stage** of an image build. It fetches the newest Debian testing netinst,
   verifies it against the committed CD signing key, caches it on ARGONAS,
   derives the snapshot pin, and writes `manifests/base.pin`. The Makefile's
   `SUBSTRATE_SHA` is then read from `base.pin` (currently `123a250b...`), and
   `downloads/debian-testing-amd64-netinst.iso` must match it (an empty
   `downloads/` restores it from the ARGONAS substrate store). `make
   check-substrate-pin` fails closed if the pin is stale (>8 days) or the
   substrate is not authorized by the pinned snapshot.
5. Git-ignored inputs that stage 0/1 do not produce:
   - `assets/cix-debs/ncz-singularity-desktop_*_amd64.deb`. Stage 0's
     `sinty-out-sync` copies the newest one into `build/sinty-out/`, and
     `verify-local-package-versions` refuses an empty set.
   - `build/ncz-screensavers-out/ncz-screensavers_<v>_amd64.deb` (at least the
     floor in `build/screensavers-version.env`) and the settings plugin via
     `make ssplugin-stage` (or `build/stage-screensaver-plugin.sh amd64`).
   - `assets/rescue/rescue-rootfs-amd64.tar.zst` and `assets/python311/`.
   - `assets/wallpaper-debs/`. Any missing pack is built by stage 1. The
     Cygnus pack's ArtistPack manifest is in-repo
     (`assets/branding/wallpaper/artistpack/cygnus-2610/`), so no private
     ArtistPack checkout is needed for it.

## 1. Stages

```
cd ~/Projects/<dir>/cix-installer
SHA=$(git rev-parse --short HEAD)
make refresh-substrate ARCH=amd64        # MANDATORY first stage: newest netinst,
                                         # verified, cached, pin derived (base.pin)
make check-substrate-pin ARCH=amd64      # preflight: fresh + covered by the pin
KS=/mnt/argonas/datapool/yocto-shared/kernel-staging
ctr() { sudo podman run --rm --privileged --net=host -v "$PWD":/work/cix-installer -v /dev:/dev \
  -v $KS:$KS -v /mnt/argonas-yocto-shared:/mnt/argonas-yocto-shared -w /work/cix-installer \
  -e NCZ_TARGET_ARCH=amd64 -e HOME=/root localhost/ncz-imagebuild:trixie \
  bash -lc "git config --global --add safe.directory '*'; $1"; }

ctr "make offline-mirror BUILD_SHA=$SHA"                     # stage 0, about 6 min
sudo chown -R "$USER": build/sinty-out build/chrome-deb-cache
NCZ_TARGET_ARCH=amd64 build/build-squashfs-layers.sh all      # stage 1, about 13 min
NCZ_ONE_KERNEL=1 ctr "make image BUILD_SHA=$SHA"              # stage 2, about 10 min
```

`make refresh-substrate` and `make check-substrate-pin` are mandatory BEFORE
`make offline-mirror`/`make image` (the image target itself depends on
`check-substrate-pin`, so `make image` fails closed on a stale or uncovered
substrate). `NCZ_ONE_KERNEL=1` enables the one-kernel filter that stops merging
Debian's kernel/module udebs into the image (operator ruling 2026-10-10); the
installer then runs the NCZ kernel — see [ONE-KERNEL.md](ONE-KERNEL.md).

`make image` does NOT build the base or desktop layers. Since this revision
`stage-ncz-payload.py` refuses a `desktop-hotfix.squashfs` without
`desktop.squashfs` (the 25c30d6d image shipped 5.1 GB with no desktop layer).
A complete image is about 7.9 GB, and its receipt's `staged_files` lists
`base.squashfs`, `desktop.squashfs`, `desktop.overlay-manifest`,
`desktop-hotfix.squashfs`, `desktop-hotfix.overlay-manifest`,
`busybox-amd64` and `sqtools`.

If a seed manifest changes, delete `build/desktop-mirror` and
`build/forky-mirror` (the seed check compares names, not versions) and rerun
stages 0 and 1. If the base package set changes, rebuild every layer.

## 2. Gate

```
python3 -m venv ~/Projects/<dir>/pyte-venv && ~/Projects/<dir>/pyte-venv/bin/pip install pyte
sudo env TMPDIR=$TMPDIR NCZ_PYTE_PYTHON=~/Projects/<dir>/pyte-venv/bin/python HOME=$HOME \
  bash build/kvm-install-gate-gpt.sh "$PWD/build/ncz-os-amd64-<date>-<sha>.img" ~/Projects/<dir>/kvm-gate
```

The gate must end with `GATE PASS (phase 1+2)`. Phase 1 installs unattended
and then checks the installed target (Chrome, `sudo_ok=1`, screensavers and
plugin, never-software-render pieces including `ncz-gpu-env`, sshd password
login). Phase 2 boots the disk and requires zero unexpected failed units. The
amd64 UI check samples the framebuffer: it proves the console never goes blank
and that the dialogs and progress bars advance, but it cannot read the dialog
text, so it does not assert the dialog order. The workdir needs about 45 GB
(the evidence copy of the target is kept).

## 3. Ship

```
NCZ_IMAGE_ARCHIVE=/mnt/argonas/datapool/projects/ncz-os-assets/images \
NCZ_FLEET_PASS_FILE=<0600 file> bash build/ship-image.sh "$PWD/build/<image>" --gate-log <gate log>
```

The default archive path is the ULTRA spelling (`/mnt/argonas-projects/...`).
On PROTEUS set `NCZ_IMAGE_ARCHIVE`. The script copies and verifies; the reap
step is a dry run. Never pass `--reap-apply`.
