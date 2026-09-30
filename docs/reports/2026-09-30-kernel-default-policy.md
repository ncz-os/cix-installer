# Kernel default policy — operator directive 2026-09-30

## TL;DR

- The DEFAULT kernel on every NCZ-OS architecture is **7.2.8 (or 7.2.x-*)** —
  a release-version, never `-rcN`.
- On **Sky1/arm64 only**, an additional **non-default** `edge` entry for
  `7.3.0-rc5` is allowed. It is a separate rEFInd menu entry, never the
  default, never the only installed kernel.
- On **amd64**, **no 7.3-rc5 line ships at all** — no edge kernel .debs,
  no edge menu entry, no edge KVER sidecar. The decision is by lack of a
  validated amd64 7.3 kernel, not by preference.
- The **rescue boot entry** is preserved on both arches.

## The .66 incident (Sep 29, 2026)

Operator host **.66 (Sky1, MS-R1)** booted **7.3.0-rc5 by default** after
flashing and installing the image `ncz-os-arm64-20260929-4bd67b5f.img`
(receipt sha256 `51afe699…b73d72`, kernel-manifest variants.edge.kver
`7.3.0-rc5-sky1-ncz`, variants.mainline.kver `7.2.8-sky1-ncz`).

The shipped image's payload `KVER_NEXT` sidecar (read by
`post-install/10-our-kernel.sh` and `build/70-bootloader.sh` to install
the default kernel and stage the rEFInd menu) resolved to
`7.3.0-rc5-sky1-ncz`. The image's `assets/kernel/mainline` symlink was
*supposed* to point at `r277-7.2.8-sky1-ncz-20260927` but the image's
payload held only `assets/kernel/edge/` (the rc5 tree) and no
`assets/kernel/mainline/` directory at all.

### Root cause

`assets/kernel/mainline` is a **symlink** into the shared kernel-staging
pool at `/mnt/argonas-yocto-shared/kernel-staging/<rev>-<kver>-...`.
Whoever ran the image build on `fedora` retargeted the symlink (or had
it misdirected) at a 7.3-rc5 staging tree. The build scripts
(`build/build-iso-di.sh`, `build/build-squashfs-layers.sh`,
`build/build-baked-rootfs.sh`) all read KVER_NEXT from this symlink and
copied it into the payload as-is. No build-time check refused the
misdirected state because:

- `build/build-kernel-debs.sh` only emits the Sky1 `.deb` set from the
  symlink target — when the symlink points at rc5, it dutifully packages
  rc5.
- `build/check-kernel-deb-pin.sh` operates on the .deb set's filenames
  vs. the same symlink target. If the symlink is misdirected, the pin
  check agrees with the misdirection (both report rc5) and exits 0.
- `assets/kernel-manifest.json` carries `variants.mainline.kver =
  "7.2.8-sky1-ncz"` in the shipped build, but no build script cross-
  checks the sidecar against the manifest.

The first build-time gate that disagrees with a misdirected symlink is
the new `build/verify-kernel-default-policy.sh` shipped by
`feat/kernel-default-7.2.8-2026-09-30`.

## What changed

### Commit 1 (`f13febfa`): the verifier and the build-time gates

| Component                                  | Change                                                    |
| ------------------------------------------ | --------------------------------------------------------- |
| `build/verify-kernel-default-policy.sh`    | NEW. Static gate. Reads symlink target + manifest and     |
|                                            | refuses any violation of the policy.                      |
| `build/test-kernel-default-policy.sh`      | NEW. 16 fixture tests cover every verifier code path     |
|                                            | (positive ship states + every failure mode).             |
| `build/build-installer-image.sh`           | Calls the verifier immediately after substrate import.    |
| `build/build-squashfs-layers.sh`           | Calls the verifier at the top of `build_base()`.         |
| `build/build-baked-rootfs.sh`              | Calls the verifier before the chroot is opened.          |
| `Makefile`                                 | `make parity` now runs the new fixture tests.            |
| `docs/platform-inventory.tsv`              | Adds rows for both new scripts.                          |

The new verifier's seven independent checks are listed in
`build/verify-kernel-default-policy.sh`'s own header. They run before
*any* KVER sidecar is copied, so a misdirected symlink fails the build
instead of silently shipping.

### Commit 2 (this update): actually delete amd64-edge from the tree

The first commit added the verifier — but the operator directive
("amd64 must have no 7.3-rc5 at all, not default, not edge") requires
that no amd64-edge payload be staged at all. The verifier only BLOCKED
the build when `assets/kernel/amd64-edge/KVER` existed; it did not
itself clean up the tree. This follow-up commit actually removes the
amd64-edge channel end-to-end:

| Component                                  | Change                                                    |
| ------------------------------------------ | --------------------------------------------------------- |
| `assets/kernel/amd64-edge/`                | DELETED. Was `KVER=7.3.0-rc5-1-t2-trixie`.                |
| `build/stage-amd64-kernel.sh`              | `edge` and `all` args now REFUSE (exit 64). Only `stable` |
|                                            | stages the single 7.2.x stable line.                      |
| `build/build-iso-di.sh`                    | Stops staging `amd64-edge/` into the installer payload;  |
|                                            | asserts no `amd64-edge/` is present in the staged tree.  |
| `post-install/10-amd64-kernel.sh`          | Installs `amd64-stable/` only. If `amd64-edge/` is        |
|                                            | non-empty at install time, exits non-zero (defence-in-   |
|                                            | depth).                                                  |
| `build/verify-base-kernel-assets.sh`       | `LINES` reduced to `amd64-stable`. `EMBED_LINES_RE`       |
|                                            | updated. Pair-sanity check now single-channel.            |
| `build/preflight-freshness-gate.sh`        | `for line in amd64-stable amd64-edge` → single line.      |
|                                            | Known-prefix glob drops `amd64-edge-*`; leftovers in the |
|                                            | pool now surface as orphans, fail loudly.                 |
| `build/iso/write-usb-image.py`             | Drops `amd64-edge` from the amd64 channel list.          |
| `docs/platform-inventory.tsv`              | Removes the `assets/kernel/amd64-edge/` row.             |
| `build/test-kernel-default-policy.sh`      | (no change to fixture count -- the existing              |
|                                            | `amd64: 7.2.8 stable only` positive case already          |
|                                            | exercises the no-edge state; the                          |
|                                            | `amd64: amd64-edge exists` negative case still           |
|                                            | covers the regression-guard path.)                        |
| `docs/reports/2026-09-30-kernel-default-policy.md` | This file -- documents both commits and the        |
|                                            | gap the first one left open.                             |

After this commit, the live repo state satisfies the operator directive
**without** requiring the verifier to fail:

```
$ cat assets/kernel/amd64-stable/KVER
7.2.8-1-t2-trixie

$ ls assets/kernel/amd64-edge
ls: cannot access 'assets/kernel/amd64-edge/': No such file or directory

$ ARCH=amd64 bash build/verify-kernel-default-policy.sh
[kernel-default-policy] amd64: stable KVER '7.2.8-1-t2-trixie' (release)
[kernel-default-policy] amd64: no edge channel (policy satisfied)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=amd64 mainline=<empty>)
```

The arm64 side is unchanged at the tree level — `assets/kernel/mainline`
still symlinks to `r277-7.2.8-sky1-ncz-20260927` (the validated 7.2.8
release tree), and `assets/kernel/edge` still symlinks to
`r279-7.3.0-rc5-sky1-ncz-20260929` (the rc5 tree the operator accepts as
a non-default edge entry). The verifier now also enforces that contract
on arm64 builds.

## What was NOT changed

- The shipped kernel .debs themselves (`build/kernel-debs/*-r277*`) are
  not touched. `r277` is the validated 7.2.8-sky1-ncz build, already
  correct on the latest release branch.
- `assets/kernel/mainline` and `assets/kernel/edge` symlinks are NOT
  retargeted by this commit. They are still the operator-controlled
  staging pointers in `/mnt/argonas-yocto-shared/kernel-staging/`.
  Whoever runs the next image build must ensure both point at the
  intended trees (mainline → `r277-7.2.8-sky1-ncz`, edge →
  `r279-7.3.0-rc5-sky1-ncz`). The verifier now refuses the build if
  that contract is broken.
- The rEFInd refresh scripts (`assets/refind/ncz-refind-refresh.sh`,
  `assets/refind/ncz-refind-refresh-amd64.sh`) are unchanged. They
  already install the kernel named by `KVER_NEXT` / `KVER_STABLE` as
  the default menu entry — so once `KVER_NEXT` correctly names 7.2.8,
  the default menu entry is 7.2.8 with no script changes needed.
- The rescue partition entry and the operator-staged rescue kernel
  promotion logic are preserved verbatim.

## Verification

### Static (this commit)

- `make parity` runs the new fixture tests in addition to all existing
  parity tests. All 16 fixture tests + every prior test pass on a clean
  checkout. Observed on `cerberus` after this commit:

  ```
  parity tests: 19 passed, 0 failed
  no-software-render tests: 48 passed, 0 failed
  installer screen tests: 17 passed, 0 failed
  ncz-ui tests: 15 passed, 0 failed
  base stamp tests: 11 passed, 0 failed
  reap-images tests: 16 passed, 0 failed
  === summary: PASS=16 FAIL=0 ===
  ```

- `build/lint-platform.sh` accepts the platform-inventory update
  (`lint-platform: OK (83 hooks, 2593 files classified)`).
- `build/verify-kernel-default-policy.sh --arch amd64` against the live
  repo (now without `assets/kernel/amd64-edge`) PASSES with the
  expected `no edge channel (policy satisfied)` log line.
- `build/verify-kernel-default-policy.sh --arch arm64` against the live
  repo refuses to run because the staging pool is not mounted on this
  host — the failure mode is the new `DANGLING_SYM` message that names
  the pool path and the required mount. This is correct behaviour: the
  build host where the verifier matters (`fedora`) has the pool mounted,
  so the symlinks resolve there.

### Build (would be on `fedora`, the arm64 build host)

Not run in this commit (out of scope: heavy builds only on the build
pool per operator standing rules, and the staging pool must be mounted
on the build host for the symlinks to resolve). On `fedora`:

```sh
cd /work/cix-installer
NCZ_TARGET_ARCH=arm64 ./build/build-installer-image.sh \
  --arch arm64 \
  --substrate-iso /work/substrate/forky-DI-arm64.iso \
  --output /work/cix-installer/build/ncz-os-arm64-20260930-XXXXXXX.img
```

The verifier runs as the first gate after substrate import; if the
`assets/kernel/mainline` symlink is misdirected, the build aborts with
the FAIL message naming the misdirected target. The
`build/build-iso-di.sh` amd64 channel list no longer contains
`amd64-edge`, so an amd64 build also cannot re-introduce it.

### Runtime (would be on .66 and on a Sky1 unit)

Not run in this commit (operator standing rules: never reboot hardware
from a zoder worker). On a real Sky1 unit, after flashing a re-built
image:

```sh
# /boot/vmlinuz-* filenames
ls /boot/vmlinuz-* /boot/initrd.img-*
# expected: 7.2.8-sky1-ncz as the default; 7.3.0-rc5-sky1-ncz if edge shipped
uname -r
# expected: 7.2.8-sky1-ncz on first boot
```

The KVM gate (`build/kvm-kernel-gate.sh`) provides the install-time
analogue of this check on arm64 build hosts; on the actual `.66`
hardware the boot test sheet lives in
`docs/reports/2026-09-30-sky1-default-kernel-recovery.md` (to be
written after the operator runs the re-built image on the box).

## Things explicitly NOT verified

1. The fix was NOT validated on real hardware (per standing rules).
2. The fix was NOT validated by a full image rebuild (would require
   mounting `/mnt/argonas-yocto-shared` on the build host and running
   `build-installer-image.sh`, both outside the scope of this commit).
3. The fix was NOT validated by KVM-boot of a fresh image (same as #2).
4. The `assets/kernel/mainline` symlink target on the next build host
   was NOT verified — whoever runs the build must point it at the
   validated `r277-7.2.8-sky1-ncz` tree and the verifier will refuse
   anything else.
5. The fix does NOT retarget the symlinks in git. Whoever runs the next
   image build on `fedora` must ensure the symlinks match the policy
   before invoking `build-installer-image.sh`.
6. The fix did not unpublish any `amd64-edge-*` builds already sitting
   in the shared kernel-staging pool — those will now FAIL the
   `preflight-freshness-gate.sh` orphan-prefix check until the operator
   prunes them or republishes them with a different prefix. That is the
   intended behaviour (a silent pass would be the regression mode), but
   it does mean the next build on `fedora` may need a one-time
   pool-cleanup pass.