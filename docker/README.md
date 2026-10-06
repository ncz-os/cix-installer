# Build container definitions

Source of truth for the containers the NCZ-OS build hosts run. These files were
host-local and untracked until 2026-08-28, which meant the two build hosts could
drift apart with nothing able to detect it. They had.

## Images

| file | image | role |
|---|---|---|
| `Containerfile.yocto` | `ncz-yocto-y6:trixie` | Yocto kernel builds (`bitbake linux-cix-sky1-ncz`) |
| `../build/containers/Containerfile.ncz-imagebuild` | `ncz-imagebuild:trixie` | raw GPT image builds (`make image`); see `build/containers/README.md` |

Two images because they do two different jobs. Parity does not mean one image;
it means **every build host builds and runs both, from these files, and gets
identical output**.

Build them with `./build-images.sh` on any host. Add `--rootful` where the work
needs device nodes (see below).

## What was wrong, and what changed 2026-08-28

Measured before the change:

    TYDEUS  ncz-yocto-y6   base ubuntu:22.04    docker 29.1.3, rooted
    ULTRA   ncz-isobuild   base debian:trixie   podman 5.8.4, ROOTLESS

Two base distributions, two container engines, one of them rootless, and
neither definition in git. Fixed:

- **Both images now build from `debian:trixie`.** The Ubuntu base was never a
  deliberate choice; it was what the image happened to be built from.
- **Both hosts now run podman.** podman was installed on TYDEUS alongside
  docker -- docker was NOT removed, because TYDEUS runs the fleet's GPU
  inference services (llama-gemma-4-31b-it-qat, qwen38, gpu0-sentinel,
  tydeus-modeld) on it. Only the build containers moved.
- **Both definitions and the build script are committed here.**

## Still open

- **Rootless cannot mknod.** Rootless podman cannot create device nodes, which
  blocks rootfs extraction during an ISO build. Use `build-images.sh --rootful`
  and run such builds under `sudo podman`. This is a property of the engine
  mode, not something a Containerfile can fix.
- **podman versions differ**: TYDEUS 4.9.3 (Ubuntu 24.04), ULTRA 5.8.4 (Fedora
  Asahi 44). Same engine, different generation.
- **Host OSes differ** (Ubuntu 24.04 vs Fedora Asahi 44, both aarch64). This is
  why ULTRA baked build-host SELinux labels into shipped squashfs layers until
  `-xattrs-exclude '^security\.selinux'` was added. Containerising makes the
  host mostly irrelevant, but only where the build actually runs in one.
- **Checkout paths differ**: `~/cix-installer` on TYDEUS,
  `~/isobuild/cix-installer` on ULTRA. Any script assuming a path works on one
  host only.

## The Yocto base change is NOT trusted until the A/B passes

The Yocto container is the kernel's host toolchain environment -- the native
tools, python and shell that bitbake runs. Changing its base can change build
output. The validation is an A/B: build the SAME kernel source under the old
`ubuntu:22.04` image and the new `debian:trixie` image and compare the resulting
`Image` byte-for-byte. Yocto pins `SOURCE_DATE_EPOCH`, so a matching Image means
the change is inert. Run it; do not assume it.

Until that A/B passes, `~/yocto-docker/y6-run.sh` should keep pointing at the
old image.

## Why these files exist at all

The old ISO-build container's package list (`Containerfile.isobuild`, since
removed; its packages live on in `Containerfile.ncz-imagebuild`) grew by trial
and error: each build failed on one more missing tool, which was added by hand to a file that lived
only on ULTRA. Nine tools accumulated that way (qemu-system-arm,
qemu-efi-aarch64, p7zip-full, kmod, dosfstools, mtools, fakechroot, gcc,
build-essential) and none of it was recoverable from the repo.

**A build-host requirement that is not in git is not a requirement, it is a
local accident.**
