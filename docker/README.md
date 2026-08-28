# Build container definitions

These files are the source of truth for the containers the NCZ-OS build hosts
run. They were host-local and untracked until 2026-08-28, which meant the two
build hosts could drift apart with nothing able to detect it. They diverged.

## The two images

| file | image | role | host |
|---|---|---|---|
| `Dockerfile.yocto` | `ncz-yocto-y6` | Yocto kernel builds (`bitbake linux-cix-sky1-ncz`) | TYDEUS |
| `Containerfile.isobuild` | `ncz-isobuild` | ISO builds (`make iso`) | ULTRA |

They are deliberately different images because they do different jobs. Parity
does NOT mean one image; it means **every build host can build and run both,
from these committed files, and produces byte-identical output**.

## Known divergences as of 2026-08-28 -- NOT yet resolved

Recorded here because they are real and unfixed, not because they are accepted.

1. **Different base distributions.** `Dockerfile.yocto` is `ubuntu:22.04`;
   `Containerfile.isobuild` is `debian:trixie`. Bringing the Yocto image to a
   Debian base is a change to the kernel toolchain environment and must not be
   made casually -- a host-compiler or Python change can alter build output.
   Any such move needs a before/after comparison of the built kernel.

2. **Different container engines, and one is rootless.** TYDEUS runs docker as
   root; ULTRA runs podman ROOTLESS. This is not cosmetic: rootless podman
   cannot `mknod`, which blocks rootfs extraction outright. The same script can
   therefore succeed on one host and fail on the other. Whichever engine wins,
   both hosts must run the same one in the same rootful/rootless mode.

3. **Different checkout paths.** TYDEUS uses `~/cix-installer`, ULTRA uses
   `~/isobuild/cix-installer`. Both track the same canonical remote
   (`root@192.168.207.101:/mnt/datapool/git/cix-installer.git`), but scripts
   that assume a path will only work on one host.

## The rule that produced the drift

The ISO container's package list grew by trial and error: each `make iso`
failed on one more missing tool, which was added by hand to a file that lived
only on ULTRA. Nine tools were added that way (qemu-system-arm, qemu-efi-aarch64,
p7zip-full, kmod, dosfstools, mtools, fakechroot, gcc, build-essential). None of
it was recoverable from the repo. That is why these files are committed now:
**a build host requirement that is not in git is not a requirement, it is a
local accident.**
