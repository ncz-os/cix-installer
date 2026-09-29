# Building the arm64 (Sky1 / Orion O6N) install image on ULTRA

This is the exact sequence that produced `ncz-os-arm64-20260929-185c2f6.img`,
plus the short path for re-building with a new `ncz-screensavers` package.
Heavy builds never run on STUDIO. ULTRA (192.168.207.88, Fedora Asahi, SELinux
enforcing, pubkey-only ssh) is the arm64 image host; scratch stays local to
ULTRA, only downloads/sstate/kernel staging are on ARGONAS.

## 0. Preconditions (each was a real failure)

1. Worktree under `~/Projects` (not `$HOME`, not `/tmp`):
   `git worktree add -b <branch> ~/Projects/cix-installer-<tag> origin/main`,
   then merge the fix branches you need.
2. Git-ignored inputs MUST be staged; `build/verify-arm64-inputs.sh` now fails
   the build if they are not:
   - `assets/sky1-firmware/`: the 29-file canonical set (16 `.fwb`,
     `dsp_fw.bin`, `arm/mali/arch12.8/mali_csffw.bin`, `mediatek/`, `rtw89/`),
     from `/mnt/argonas-projects/cix-installer/assets/sky1-firmware` on ULTRA.
   - `assets/cix-debs/*.deb`: at least 22, including `cix-gpu-umd`,
     `cix-libglvnd`, `cix-mesa`, `cix-noe-umd`, `cix-npu-driver-dkms`
     (aipu 6.2.0), `cix-vpu-driver-dkms`, `cix-gpu-kmd-dkms`,
     `panthor-cix-dkms`, `cix-firmware`. Source used on 2026-09-29:
     `~/Projects/cix-installer-arm64-build-2026-09-25/assets/cix-debs` plus
     `cix-vpu-driver-dkms` from `~/Projects/cix-iso-build-fresh`.
   - VA-API: `cix-vaapi`, `cix-libva2`, `cix-libva-drm2`, `cix-libva-wayland2`, `cix-libva-x11-2`,
     `cix-libva-glx2`, `cix-libcme` (versions 1.0.0 / 2.22.1-1). They are NOT in the older
     checkouts; they come from the cix-mm SDK archive on ARGONAS
     (`/mnt/argonas-projects/nclawzero-yocto/sdk/cix-mm-1.0.0.tar.gz`, `cix-mm/debian12/`,
     built for Debian 12, `Depends: libc6 (>= 2.34)`, `libyuv0`). `verify-arm64-inputs.sh` requires
     them; `25-cix-proprietary.sh` installs them and `84-vpu-vaapi.sh` wires the driver.
   - `assets/rescue/rescue-rootfs-arm64.tar.zst`, `assets/python311/`,
     `assets/npu/`, `assets/sinty-nm/`, `assets/wallpaper-debs/`.
   The 2026-09-27/28 images were built from a worktree that had 1 Cix deb and
   2 firmware files; every gate passed. That cannot happen again.
3. `assets/kernel/edge` symlink points at a kernel-staging directory named
   `r<N>-<kver>-sky1-ncz-<date>`. Directories with any other prefix inside
   `/mnt/argonas-yocto-shared/kernel-staging` fail preflight gate [3]
   (move them to `kernel-staging-archive/`, do not delete).
4. The d-i substrate is pinned (Makefile `SUBSTRATE_SHA`, arm64): Debian weekly netinst,
   installer build 20260921, sha256 `bcdea12698a4c643fbbc68c69fb8be96a3f292bdfa1b5c41c8fdaeaae6944f67`.
   Debian republishes the filename weekly and drops old builds, so the pinned ISO is kept on
   ARGONAS at `ncz-os-assets/substrate/debian-testing-arm64-netinst-20260921-bcdea126.iso`
   (ULTRA: `/mnt/argonas-projects/ncz-os-assets/substrate`). An empty `downloads/` restores it
   from there; if it cannot, the build refuses instead of floating, and `make image`
   re-verifies the file. Adopting a newer installer is deliberate: build on it, run the KVM
   gate, store the ISO in that directory as `<name>-<yyyymmdd>-<sha8>.iso`, change the pin.
   amd64 has no pin yet and only warns.
5. `ncz-imagebuild:trixie` in BOTH podman stores (rootless build, rootful run):
   `podman save localhost/ncz-imagebuild:trixie | sudo podman load`.
   A prune deletes it; rebuild from `build/containers/Containerfile.ncz-imagebuild`.

## 1. Stages

```
cd ~/Projects/cix-installer-<tag>
SHA=$(git rev-parse --short HEAD)          # compute on the HOST (SELinux hides .git in the container)
KS=/mnt/argonas-yocto-shared/kernel-staging

# stage 0: offline mirrors (rootful container)
sudo podman run --rm --privileged --net=host -v "$PWD":/work/cix-installer -v /dev:/dev -v $KS:$KS \
  -w /work/cix-installer -e NCZ_TARGET_ARCH=arm64 -e HOME=/root localhost/ncz-imagebuild:trixie \
  bash -lc 'git config --global --add safe.directory "*"; make offline-mirror BUILD_SHA='$SHA

# stage 0 leaves root-owned build/ dirs; stage 1 runs as your user
sudo chown -R "$USER": build/sinty-out build/kernel-debs build/libdrm-debs build/usb-recovery-deb build/chrome-deb-cache

# stage 1: layers, on the BARE host (drives mkosi/podman itself)
NCZ_TARGET_ARCH=arm64 build/build-squashfs-layers.sh all

# stage 2: assemble (rootful container); refuses if verify-arm64-inputs.sh fails
sudo podman run --rm --privileged --net=host -v "$PWD":/work/cix-installer -v /dev:/dev -v $KS:$KS \
  -w /work/cix-installer -e NCZ_TARGET_ARCH=arm64 -e HOME=/root localhost/ncz-imagebuild:trixie \
  bash -lc 'git config --global --add safe.directory "*"; make image BUILD_SHA='$SHA
```

The image name is `build/ncz-os-arm64-<YYYYMMDD>-<sha>.img`. `make` now
refuses to run image goals with an empty `BUILD_SHA`.

## 2. Gate

```
bash build/kvm-install-gate-gpt.sh "$PWD/build/ncz-os-arm64-<date>-<sha>.img" "$HOME/kvm-install-arm64-<sha>"
```

Pass a workdir explicitly (the default reaps nothing of a wrapper's own
naming). Expected: phase 1 installs and reaches the finish stage, then the
arm64-only installed-target check (`build/verify-installed-target-arm64.sh`)
reads the installed root with debugfs and asserts firmware, aipu 6.2.0 built
for the Sky1 kernel (not 5.11.0), amvx, the `/dev/video-cixdec0` helper, an
ffmpeg with `*_v4l2m2m`, and both browsers; phase 2 exits `rc=124` with an
EMPTY boot.log, which is the PASS signal (the guest booted and stayed up).
Reap `iso-patch/` under old gate workdirs afterwards.

Both verifiers have negative tests: `build/test-arm64-gates.sh` and
`build/test-installed-target-verifier.sh`.

## 3. Shipping `ncz-screensavers`

Merged on branch `release/arm64-final-2026-09-29` (from `feat/ncz-screensavers-pkg-wiring-2026-09-29`).
The package is staged from `/mnt/argonas-projects/ncz-screensavers-debs/<highest version>/`
(check `ls` for the highest `x.y.z` directory and its `SHA256SUMS` first), installed at install
time by `post-install/59-ncz-screensavers-pkg.sh` (simulates first, refuses removals, no-op when
the mirror has no candidate) and seeded into the offline mirror by `manifests/install-extra.pkgs`,
so the layers do not change and stage 1 is not repeated. The package's postinst disables the
older `ncz-idle-manager` user service; 59 runs after 58, so the old unit exists to be disabled.

```
V=0.3.2                                                     # highest dir under ncz-screensavers-debs
mkdir -p build/ncz-screensavers-out && rm -f build/ncz-screensavers-out/*.deb
cp /mnt/argonas-projects/ncz-screensavers-debs/$V/ncz-screensavers_${V}_arm64.deb build/ncz-screensavers-out/
grep -qx ncz-screensavers manifests/install-extra.pkgs || echo ncz-screensavers >> manifests/install-extra.pkgs
sudo rm -rf build/desktop-mirror build/forky-mirror          # re-add the local deb to the pool AND re-resolve the install mirror
                                                            # (the seed check compares package NAMES, so a new VERSION of the same package would not trigger a rebuild)
# stage 0 (about 8 minutes), stage 2, gate: exactly as in sections 1 and 2.
```

`verify-arm64-inputs.sh` refuses stage 2 if the deb is unstaged or missing from `forky-mirror`;
the installed-target check asserts the package is installed with launcher, settings app, idled
unit (enabled), `ncz-screensaver-run`, the compiled `dev.ncz.screensaver` schema and 84 hack
binaries, and that `ncz-idle-manager` is not enabled next to it.

## 5. Two build-breaking limits found on 2026-09-29 (both now guarded)

- `preseed/early_command`, joined, must stay under 13,000 bytes
  (`build/check-early-command-size.sh`, run by `build-iso-di.sh`). At 15,634 bytes
  `/bin/preseed_command` dies in confmodule (`return: line 88: Illegal number`),
  early_command never mounts the ext4 medium and d-i stops at "Incorrect
  installation media detected". Put logic in a helper under `preseed/` and add it
  to `BAKED_HELPERS` in `build/iso/patch-initrd-t2-kernel.py` (see
  `hostname-suggest.sh`).
- `late.sh` asset union-sync must survive a dangling baked symlink where the media
  has a directory (`assets/kernel/edge` in `base.squashfs`); regression test
  `build/test-late-union-sync.sh`.
