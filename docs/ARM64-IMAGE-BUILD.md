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
   - `assets/rescue/rescue-rootfs-arm64.tar.zst`, `assets/python311/`,
     `assets/npu/`, `assets/sinty-nm/`, `assets/wallpaper-debs/`.
   The 2026-09-27/28 images were built from a worktree that had 1 Cix deb and
   2 firmware files; every gate passed. That cannot happen again.
3. `assets/kernel/edge` symlink points at a kernel-staging directory named
   `r<N>-<kver>-sky1-ncz-<date>`. Directories with any other prefix inside
   `/mnt/argonas-yocto-shared/kernel-staging` fail preflight gate [3]
   (move them to `kernel-staging-archive/`, do not delete).
4. Substrate ISO is NOT pinned by the Makefile: `downloads/debian-testing-arm64-netinst.iso`
   is fetched from Debian's rolling weekly-builds when the file is absent. On 2026-09-29 a
   fresh worktree pulled the 20260928 weekly d-i, and the resulting image stopped at
   "Detect and mount installation media: Incorrect installation media detected"
   (its initrd carries newer util-linux/blkid than the 20260921 d-i the working images
   used). Until that is root-caused, copy the known-good substrate into the worktree
   BEFORE stage 2 (ULTRA: `~/Projects/cix-installer/downloads/debian-testing-arm64-netinst.iso`,
   1,019,523,072 bytes, sha256 starting bcdea12698a4c643fbbc) and `touch` it.
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

## 3. Adding or replacing `ncz-screensavers` (short path)

Wiring lives on branch `feat/ncz-screensavers-pkg-wiring-2026-09-29` (not merged
into the baseline image). It touches only: a `build/ncz-screensavers-out/` row in
the desktop mirror's local-package table (and keeps local NCZ packages out of the
closure prune), an optional `manifests/install-extra.pkgs` that seeds the install
media's offline mirror WITHOUT baking the package into the layers, and
`post-install/59-ncz-screensavers-pkg.sh`, which installs the package at install
time when the mirror has a candidate (simulates first, refuses removals, no-op
when absent). It does not edit `58-screensaver-chooser.sh` or the held
`57-screensaver.sh`. Proven with a dummy package in a scratch worktree:
desktop-mirror kept and indexed it, and forky-mirror grew 1805 -> 1806 packages.

```
git merge feat/ncz-screensavers-pkg-wiring-2026-09-29                # once
mkdir -p build/ncz-screensavers-out
cp /path/to/ncz-screensavers_<ver>_arm64.deb build/ncz-screensavers-out/
echo ncz-screensavers >> manifests/install-extra.pkgs
rm -rf build/desktop-mirror                     # so the local deb is re-added to the pool
# stage 0 again (about 8 minutes; verify-offline-mirror-seeds now sees the new seed and
# rebuilds forky-mirror). Stage 1 is NOT needed: the package is not baked.
# Then stage 2 (make image BUILD_SHA=...) and the gate exactly as above.
```

If the package has Depends outside what the desktop closure already carries,
list those names in `manifests/install-extra.pkgs` too. Before stage 2 confirm
`grep -c '^Package: ncz-screensavers$' build/forky-mirror/dists/*/main/binary-arm64/Packages`
is 1. After the gate, the `[59-ncz-screensavers] installed ...` line in
`target-logs/cix-installer-late.log` proves it landed.

## 4. Two build-breaking limits found on 2026-09-29 (both now guarded)

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
