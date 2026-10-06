# Kernel default policy — operator directive 2026-09-30

> **SUPERSEDED (operator 2026-10-05):** NCZ-OS now ships ONE unified 7.3 kernel on
> every arch. 7.2.9 is retired and there is no edge channel. See
> `docs/reports/2026-10-05-kernel-channel-policy.md`. This report is kept as
> history.

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

## Step 1 (read-only): shipped-image inspection

Both shipped images were loop-mounted read-only on ARGONAS and inspected
on 2026-09-30 to confirm exactly which kernel each defaults to, which
.debs are staged, and (for arm64) why 7.3-rc5 became the default kernel.
This is the evidence base for the build-time gates in the next section.

### Image A: `ncz-os-arm64-20260929-4bd67b5f.img` (Sky1)

Receipt: `ncz-os-arm64-20260929-4bd67b5f.img.receipt.json`

- `arch=arm64`, `BUILD_HOST=fedora`, `BUILD_VERSION=2026.09.29-4bd67b5f`,
  `BUILD_DATE=2026-09-29T23:53:19Z`, output sha256
  `51afe69916cd73666794e2d7d35f6a240f0cba544fd74c196bcbcbbaa5b73d72`.
- ESP partition (`/dev/loop98p1`): the `EFI/BOOT/refind.conf` shipped is
  the **installer** rEFInd — the boot menu (`Install`, `Install (expert)`,
  `Rescue mode`) loads `/linux` + `/initrd.gz`, both the d-i installer
  kernel/initrd. The installed system's rEFInd menu is generated at first
  boot by `post-install/70-bootloader.sh`, not from this image.
- Data partition (`/dev/loop98p2`):
  - `/ncz-payload/KVER_NEXT` = `7.3.0-rc5-sky1-ncz`
  - `/ncz-payload/assets/kernel/` contains `edge/`, `mali/`, `mali-70012/`,
    `modules-overlay/`, `npu/`, `panthor/`, `vpu/` — **no `mainline/`
    directory at all**.
  - `/ncz-payload/assets/kernel/edge/KVER` = `7.3.0-rc5-sky1-ncz` (with
    full `Image-cixmini.bin`, `modules-cixmini.tgz`,
    `config-7.3.0-rc5-sky1-ncz`, `headers-cixmini.tar.zst`,
    `sky1-orion-o6.dtb`, `PROVENANCE.txt`, `overlays/`).
  - `/ncz-payload/post-install/10-our-kernel.sh` (the hook that becomes
    the runtime KVER installation) reads `KVER_NEXT` and installs that
    version as the active kernel via `apt-get install
    linux-image-cixmini` from the Buildkite apt source. With
    `KVER_NEXT=7.3.0-rc5-sky1-ncz`, the install path bakes
    7.3.0-rc5 as the default.

**Result**: this shipped image installs **7.3.0-rc5-sky1-ncz** as the
default kernel on .66 because the **only** kernel payload is the `edge/`
tree (rc5), and the build's KVER_NEXT sidecar (`7.3.0-rc5-sky1-ncz`)
copied into the image carries that same value. The build host (`fedora`)
had the `assets/kernel/mainline` symlink either retargeted at the rc5
tree or pointing into the staging pool at a tree that happened to be
the rc5 one at the moment the build ran; the build scripts copied
whichever tree the symlink resolved to, without any independent check.

### Image B: `ncz-os-amd64-20260929-617e7303.img` (amd64)

Receipt: `ncz-os-amd64-20260929-617e7303.img.receipt.json`

- `arch=amd64`, `BUILD_HOST=hydra`, `BUILD_VERSION=2026.09.29-617e7303`,
  `BUILD_DATE=2026-09-29T23:50:56Z`, output sha256
  `c4325acb0c1c948260b666145bf584c563e2c39137d34fac599d7f5c2c417f05`.
- ESP partition (`/dev/loop99p1`): `EFI/BOOT/refind.conf` shipped is the
  installer rEFInd; menu comment line reads
  `"NCZ-OS 26.7 Maximilian -- built 2026-09-29 -- stable 7.2.8-3-t2-trixie /
  edge 7.3.0-rc5-1-t2-trixie"` (this label string is generated from the
  manifest's per-arch KVERs at build time, so it was honest at build time).
  The boot entries themselves (`Install`, `Install (expert)`,
  `Rescue mode`) load the d-i installer kernel/initrd — the installed
  system's rEFInd menu is generated at first boot by
  `post-install/70-bootloader.sh` + the runtime classifier hook
  (`assets/refind/zz1-ncz-refind-refresh-amd64`).
- Data partition (`/dev/loop99p2`):
  - `/ncz-payload/assets/kernel/` contains **both** `amd64-stable/` and
    `amd64-edge/` (the latter was DELETED from the source tree by
    commit 834dd7f4 on this branch; this shipped image pre-dates that
    deletion).
  - `/ncz-payload/assets/kernel/amd64-stable/KVER` = `7.2.8-3-t2-trixie`
    (`linux-image-7.2.8-3-t2-trixie_7.2.8-3_amd64.deb` +
    `linux-headers-7.2.8-3-t2-trixie_7.2.8-3_amd64.deb`).
  - `/ncz-payload/assets/kernel/amd64-edge/KVER` = `7.3.0-rc5-1-t2-trixie`
    (`linux-image-7.3.0-rc5-1-t2-trixie_7.3.0-rc5-1_amd64.deb` +
    `linux-headers-7.3.0-rc5-1-t2-trixie_7.3.0-rc5-1_amd64.deb`).
  - `/ncz-payload/post-install/10-amd64-kernel.sh` (the hook that becomes
    the runtime KVER installation on amd64) has a stub
    `install_one()` called for both `amd64-stable` and `amd64-edge`,
    installing both .deb sets side by side, then writing both KVERs to
    `/usr/local/lib/cix-installer/KVER_LIST_AMD64`. The
    first-installed line is the stable one, but the hook does NOT
    refuse to install the rc5 edge; the only fail-closed behaviour is
    if zero kernels install.

**Result**: this shipped image installs **both** `7.2.8-3-t2-trixie` and
`7.3.0-rc5-1-t2-trixie` on the amd64 target; the runtime classifier
(`assets/refind/zz1-ncz-refind-refresh-amd64`) at first-boot decides
which becomes the rEFInd `default_selection` based on per-line install
order and initrd presence. The operator directive 2026-09-30 ("amd64
must have no 7.3-rc5 at all, not default, not edge") rejects BOTH
states: the .deb was even present on the disk, and the runtime
classifier was free to mark it edge and write it as a menu entry.
Commit 834dd7f4 removes the directory from the source tree, commit
c5f57fc6 makes the classifier refuse to enumerate edge on amd64 even
if a stray rc kernel is detected, and commit f13febfa's verifier
refuses any build that stages `assets/kernel/amd64-edge/KVER`. The
post-install hook's own defence-in-depth (refuses to install if
`amd64-edge/` is non-empty) was added in commit 834dd7f4.

### Why 7.3-rc5 became the default on arm64 (.66), the chain

1. `assets/kernel/mainline` symlink → pool tree (intended
   `r277-7.2.8-sky1-ncz-20260927`).
2. On `fedora` at image-build time, the symlink was misdirected (or the
   pool had been rotated) so it resolved to the `r279-7.3.0-rc5-sky1-ncz-
   20260929` tree.
3. `build/build-squashfs-layers.sh` copied whatever tree the symlink
   resolved to into `ncz-payload/assets/kernel/mainline/` ... but on
   this build the source dir was already named `edge/` in the staging
   pool, so the payload came out as `ncz-payload/assets/kernel/edge/`
   only (no `mainline/` at all).
4. `build/build-baked-rootfs.sh` then read `KVER_NEXT` from the
   resolved tree (`7.3.0-rc5-sky1-ncz`) and wrote it into
   `ncz-payload/KVER_NEXT` in the image.
5. `post-install/10-our-kernel.sh` on the .66 install reads
   `KVER_NEXT` and runs `apt-get install linux-image-cixmini` for that
   version (the rc5 .deb is present in the Buildkite repo).
6. `post-install/70-bootloader.sh` then stages the rEFInd menu using
   `KVER_NEXT` as the default and an optional `KVER_EDGE` as a second
   entry — but in this build `KVER_EDGE` is empty (the
   `assets/kernel/edge` symlink was also unmapped to the SAME rc5
   tree), so the rEFInd menu has only ONE entry — the rc5 — and that
   one is the default.
7. Result: .66 boots 7.3.0-rc5.

### Order of operations: where the new gates plug in

| Gate                            | Where             | Catches                                                       |
| ------------------------------- | ----------------- | ------------------------------------------------------------- |
| `verify-kernel-default-policy.sh` check 1 | build start | `assets/kernel/mainline/KVER` carries `-rcN` (rejects build)   |
| `verify-kernel-default-policy.sh` check 2 | build start | mainline KVER ≠ manifest `variants.mainline.kver` (manifest drift) |
| `verify-kernel-default-policy.sh` check 3 | build start | mainline payload missing files (Image, modules, config, headers) |
| `verify-kernel-default-policy.sh` check 4 | build start | arm64 edge KVER == mainline KVER (the misdirection class)     |
| `verify-kernel-default-policy.sh` check 5 | build start | amd64 `assets/kernel/amd64-edge/KVER` exists (banned payload)  |
| `verify-kernel-default-policy.sh` check 6 | build start | amd64 `amd64-stable/KVER` carries `-rcN`                      |
| `verify-kernel-default-policy.sh` check 7 | build start | `kernel-manifest.json` missing/invalid                       |
| `verify-kernel-default-policy.sh` check 8 | build start | amd64 classifier + refresh regression (directive markers gone)|
| `post-install/10-amd64-kernel.sh` defence | install time | non-empty `$ASSETS/amd64-edge` payload refuses install (exit 1) |
| `assets/refind/zz1-ncz-refind-refresh-amd64` | runtime  | refuses to classify any `*-rc*` kernel as `edge` on amd64     |
| `assets/refind/ncz-refind-refresh-amd64.sh` | runtime  | ignores any `KVER_EDGE` passed in (amd64 has no validated 7.3) |

Any single check failing closes the gate. The build-time verifier
(`verify-kernel-default-policy.sh`) is wired into three entry points:
`build/build-installer-image.sh` (after substrate import),
`build/build-squashfs-layers.sh` (top of `build_base()`), and
`build/build-baked-rootfs.sh` (before the chroot opens). A misdirected
symlink now exits the build at the very first stage rather than
silently baking the wrong kernel.

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

## Commit 3 (this update): runtime defence in depth on amd64

Commits 1 and 2 close the BUILD-time gaps (no edge channel staged, no
edge in the manifest, no edge kernel .debs). But the operator directive
("amd64 ships NO 7.3-rc5 line at all") also applies at RUNTIME: even if
a stray 7.3-rc5 kernel were ever apt-installed on an amd64 box
(out-of-band operator experiment, an unscheduled pool rehydration,
etc.), the rEFInd menu must NOT surface it as a bootable edge entry.
The classifier hook and the refresh script must therefore refuse to
enumerate edge on amd64.

This commit closes that runtime gap:

| Component                                       | Change                                                    |
| ----------------------------------------------- | --------------------------------------------------------- |
| `assets/refind/zz1-ncz-refind-refresh-amd64`    | `classify()` now refuses to return `edge` on amd64. Any  |
|                                                 | `*-t2-trixie` with `-rcN` is dropped (the kernel stays   |
|                                                 | installed but no menu entry is written); the legacy      |
|                                                 | `*-ncz-amd64-edge` glob is dead code (kept commented so  |
|                                                 | future grep audits still surface it).                    |
| `assets/refind/ncz-refind-refresh-amd64.sh`     | Even if a stray KVER_EDGE is passed in (legacy hook data,|
|                                                 | future operator-initiated staging), the refresh script   |
|                                                 | zeroes it and logs a WARN -- an edge menu entry is NEVER  |
|                                                 | written on amd64. The stable line still boots by default.|
| `build/verify-kernel-default-policy.sh`         | New check 8 (amd64-only): the runtime rEFInd refresh      |
|                                                 | pipeline (classifier hook AND refresh script) MUST      |
|                                                 | contain the directive-2026-09-30 markers. If either is   |
|                                                 | rolled back, the build fails closed.                     |
| `build/test-kernel-default-policy.sh`           | 3 new fixture tests: classifier rolled back -> FAIL;     |
|                                                 | refresh script rolled back -> FAIL; both honoured ->     |
|                                                 | PASS. (16 -> 19 tests total.)                            |
| `build/test-amd64-kernel-classifier.sh`         | The pre-existing classifier test was rewritten: it now    |
|                                                 | asserts the directive (amd64 has NO edge, regardless of  |
|                                                 | what `*-rc` kernels are in /boot). REPO_ROOT env override|
|                                                 | added so `make parity` can source from the working tree.  |
| `Makefile`                                      | `make parity` now runs `test-amd64-kernel-classifier.sh`  |
|                                                 | (with REPO_ROOT passed in).                              |

### Why this gap was real

The classifier rewrite in b85ac93 ("feat(amd64): apt-published
kernels + postinst hook to keep rEFInd current") was motivated by an
earlier symptom (the `-xhcifix` orphan) and DID correctly classify
7.3-rc4-ncz-amd64-edge as edge on amd64. The test of that era
asserted exactly that ("rc5 becomes EDGE, 7.2.8 stays STABLE"). After
the 2026-09-30 directive, that behaviour is OUT OF POLICY. This commit
flips the test to assert the directive and adds the static verifier
check so a future contributor cannot silently roll it back.

### What this commit DOES NOT do

- It does NOT change the arm64/Sky1 path. arm64 still ships
  `assets/kernel/edge` (rc5) and the rEFInd menu still offers it as a
  console-only experimental entry. The classifier hook on arm64 is
  unchanged.
- It does NOT remove the 7.3.0-rc4-ncz-amd64-edge classification logic
  from the script -- it is kept (in the legacy case branch) because
  the verifier still grep-audits the directive markers, and a silent
  grep audit passing is the regression mode the directive is designed
  to ban.
- It does NOT touch any pool-pruning or build-side payload changes --
  those are commits 1+2.

### Verification (after this commit)

```
$ ARCH=amd64 bash build/verify-kernel-default-policy.sh
[kernel-default-policy] amd64: stable KVER '7.2.8-1-t2-trixie' (release)
[kernel-default-policy] amd64: no edge channel (policy satisfied)
[kernel-default-policy] amd64: classifier hook refuses to enumerate edge (directive 2026-09-30)
[kernel-default-policy] amd64: rEFInd refresh refuses to write an edge entry (directive 2026-09-30)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=amd64 mainline=<empty>)
```

`make parity` exits 0. Test totals: 19 (parity) + 48 (no-software-render)
+ 17 (installer-screens) + 15 (ncz-ui) + 11 (base-stamp) + 16
(reap-images) + 8 (amd64-kernel-classifier) + 19 (kernel-default-policy)
= 153 individual tests, 0 failed.

`make lint-platform` exits 0 ("lint-platform: OK (83 hooks, 2593 files
classified)").
## Commit 4 (this update): verifier runs on dev hosts without the kernel-staging pool mounted

Commits 1-3 closed the policy gaps (build-time and runtime), but the
verifier itself refused to run on any host that did not have the
`/mnt/argonas-yocto-shared` NFS pool mounted -- the
`assets/kernel/{mainline,edge}` symlinks point there and dangle when the
pool is absent. That made the gate un-runnable on dev / CI hosts that
ship the trees vendored in-tree (`assets/kernel/r277-7.2.8-...` etc.)
but have no NFS share available.

This commit adds an offline fallback that closes the gap without
weakening fail-closed behaviour on the build farm:

| Component                                | Change                                                    |
| ---------------------------------------- | --------------------------------------------------------- |
| `build/verify-kernel-default-policy.sh`  | New `find_local_sibling()`: when a symlink is dangling,  |
|                                         | scan `assets/kernel/r*/` for a directory whose KVER      |
|                                         | matches the manifest's `variants.mainline.kver` (mainline)|
|                                         | or any directory carrying `-rcN` in its KVER (edge). If a |
|                                         | matching sibling is found, the verifier logs a WARN      |
|                                         | ("build farm uses the pool-mounted symlink") and uses it.|
|                                         | If no sibling matches, the canonical "mount the pool or  |
|                                         | repoint the symlink" FAIL message is emitted unchanged --|
|                                         | behaviour on a real build host is identical.             |
| `build/verify-kernel-default-policy.sh`  | Per-KVER headers filename variant: accept                |
|                                         | `headers-<kver>.tar.zst` (newer r2* convention) in       |
|                                         | addition to `headers-cixmini.tar.zst` (legacy). The edge |
|                                         | payload no longer warns when the tree only ships the     |
|                                         | per-KVER filename.                                       |
| `build/test-kernel-default-policy.sh`    | 3 new fixture tests:                                     |
|                                         |   - positive: offline fallback finds the local sibling  |
|                                         |   - negative: dangling symlink with NO matching sibling |
|                                         |     still fails closed with the canonical message       |
|                                         |   - positive: edge payload with per-KVER headers        |
|                                         | 19 -> 22 tests total.                                    |

### Verification (after this commit)

```
$ ARCH=arm64 bash build/verify-kernel-default-policy.sh
[kernel-default-policy] WARN: assets/kernel/mainline symlink ->
    '/mnt/argonas-yocto-shared/kernel-staging/r277-7.2.8-sky1-ncz-20260927'
    (unresolved) but local tree 'assets/kernel/r277-7.2.8-sky1-ncz-20260927'
    has matching KVER '7.2.8-sky1-ncz'; using it
[kernel-default-policy] mainline KVER '7.2.8-sky1-ncz' (release)
[kernel-default-policy] mainline KVER matches manifest: 7.2.8-sky1-ncz
[kernel-default-policy] WARN: assets/kernel/edge symlink -> '...r279-7.3.0-rc5-sky1-ncz-20260929'
    (unresolved) but local rc tree 'assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920/'
    has KVER '7.3.0-rc4-sky1-ncz'; using it as the edge channel
[kernel-default-policy] edge KVER '7.3.0-rc4-sky1-ncz' (rc; non-default experimental entry)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=arm64 mainline=7.2.8-sky1-ncz)

$ ARCH=amd64 bash build/verify-kernel-default-policy.sh
[kernel-default-policy] amd64: stable KVER '7.2.8-1-t2-trixie' (release)
[kernel-default-policy] amd64: no edge channel (policy satisfied)
[kernel-default-policy] amd64: classifier hook refuses to enumerate edge (directive 2026-09-30)
[kernel-default-policy] amd64: rEFInd refresh refuses to write an edge entry (directive 2026-09-30)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=amd64 mainline=<empty>)

$ make parity ; echo $?
... summary: PASS=22 FAIL=0
0
```

Note on arm64 edge KVER: locally we ship the `r273 7.3.0-rc4` tree
because the r279 7.3.0-rc5 staging tree lives only on ARGONAS. The
verifier accepts any `-rcN` kernel on the edge channel (the directive
is "edge = -rcN, not mainline"), so both satisfy the policy. The next
build host run will pick up r279 7.3.0-rc5 from the mounted staging
pool and the verifier will report it unchanged.

### What this commit DOES NOT do

- It does NOT change the policy. Default = 7.2.x, edge = -rcN (arm64
  only), amd64 has no edge. The verifier still fail-closes on a real
  build host if the pool is mounted but the symlink is misdirected.
- It does NOT vendor the r279 staging tree in git. The tree lives on
  ARGONAS only (`/mnt/argonas-yocto-shared/kernel-staging/`); the
  in-tree sibling (`r273 7.3.0-rc4-sky1-ncz`) is sufficient for local
  verification and is also a valid edge under the directive.

## Final test inventory (after commit 4)

`make parity` runs (with the merged `feat/kernel-default-7.2.8-2026-09-30`
branch):

| Suite                            | Tests | Notes |
| -------------------------------- | ----- | ----- |
| parity                           | 19    | unchanged from prior |
| no-software-render               | 48    | unchanged |
| installer-screens                | 17    | unchanged |
| ncz-ui                           | 15    | unchanged |
| base-stamp                       | 11    | unchanged |
| reap-images                      | 16    | unchanged |
| amd64-kernel-classifier          | 8     | rewritten in commit 3 |
| kernel-default-policy            | 22    | 16 + 3 (commit 3) + 3 (commit 4) |
| **total**                        | **156** | all PASS |

`make lint-platform` exits 0 ("lint-platform: OK (83 hooks, 2593 files
classified)").

## Commit 6 (`1d8bdd5d`, r6 of this report): defense in depth at every gate

The previous five commits added the verifier and the four runtime
defense-in-depth hooks (amd64 classifier/refresh + amd64-edge
deletion + the offline fallback for dev hosts). After r5 was
rejected (2026-09-30 11:23 EDT), an inventory of the remaining
unguarded paths showed three more gates that the .66 root cause
could still exploit, plus two existing checks that needed to be
tightened:

### What this commit does

| Change | Why |
| ------ | --- |
| `Makefile` `kernel-debs` target now runs `verify-kernel-default-policy.sh --arch arm64` before any deb is built or moved | The .debs are produced here on the build host. A misdirected `assets/kernel/mainline` symlink at packaging time silently produces `rc5` .debs (exactly the .66 root cause); gating packaging closes that path. |
| `assets/refind/ncz-refind-refresh.sh` runtime gate: refuse to write an rEFInd menu where `KVER_NEXT` matches `*-rc[0-9]*` | This is the arm64 analogue of the amd64 `KVER_EDGE` zeroing in `ncz-refind-refresh-amd64.sh`. The build-time verifier catches a misdirected mainline symlink, but a hand-edit or an OTA retargeting `KVER_NEXT` at `-rcN` would still write an `rcN` default entry. The runtime gate is the last line of defense. |
| `build/build-iso-di.sh` standalone path now runs the verifier before any `KVER` is read | This script is the path that produced the .66 image today (CI calls it directly for the arm64 production image). The other entry scripts gated on the verifier; `build-iso-di.sh` did not. Same gate, same point. |
| `post-install/10-amd64-kernel.sh` amd64-edge guard: was "any `.deb` in `amd64-edge/`"; now ANY non-hidden entry (a stray `KVER` sidecar, a stray `PROVENANCE.txt`, etc.) | The `amd64-edge/` directory is supposed to be ABSENT, not to host a sidecar with no .debs. Tightening the check to "any non-hidden file" closes that ambiguity. |
| `build/verify-kernel-default-policy.sh` check 9 (NEW): require both rEFInd refresh scripts to still carry the `*-rescue` sparing/promotion logic and the arm64 `PRESERVE OPERATOR-STAGED RESCUE KERNELS` marker comment | Operator directive 2026-09-30 says "keep the rescue entry"; a future refactor that drops the rescue-promotion contract silently removes the safety net. This static check catches that on every build. Synthesized fixture trees don't carry the refresh scripts on purpose, so the check is gated by `SKIP_RESCUE_CHECK` in fixture tests and runs only against the real repo. |
| `build/test-kernel-default-policy.sh`: add the rescue-preservation positive and regression-guard cases against the real repo and a synthesized regression copy | Three new tests: arm64 + amd64 both preserve the rescue markers today; arm64 catches the regression if the `*-rescue` sparing/promotion logic is stripped out. |

### Final test inventory (after commit 6, this commit)

```
$ bash build/test-kernel-default-policy.sh
... PASS=25 FAIL=0
exit=0

$ make parity
... PASS=25 FAIL=0
exit=0

$ bash build/verify-kernel-default-policy.sh --arch amd64
[kernel-default-policy] amd64: stable KVER '7.2.8-1-t2-trixie' (release)
[kernel-default-policy] amd64: no edge channel (policy satisfied)
[kernel-default-policy] amd64: classifier hook refuses to enumerate edge (directive 2026-09-30)
[kernel-default-policy] amd64: rEFInd refresh refuses to write an edge entry (directive 2026-09-30)
[kernel-default-policy] rescue entry preservation: both arches carry the *-rescue sparing/promotion logic (directive 2026-09-30)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=amd64 mainline=<empty>)
exit=0

$ bash build/verify-kernel-default-policy.sh --arch arm64
[kernel-default-policy] WARN: ... mainline symlink -> '...r277-7.2.8-sky1-ncz-20260927' (unresolved) but local tree ... has matching KVER '7.2.8-sky1-ncz'; using it
[kernel-default-policy] mainline KVER '7.2.8-sky1-ncz' (release)
[kernel-default-policy] mainline KVER matches manifest: 7.2.8-sky1-ncz
[kernel-default-policy] WARN: ... edge symlink -> '...r279-7.3.0-rc5-sky1-ncz-20260929' (unresolved) but local rc tree '...r273-7.3.0-rc4-sky1-ncz-20260920/' has KVER '7.3.0-rc4-sky1-ncz'; using it as the edge channel
[kernel-default-policy] edge KVER '7.3.0-rc4-sky1-ncz' (rc; non-default experimental entry)
[kernel-default-policy] rescue entry preservation: both arches carry the *-rescue sparing/promotion logic (directive 2026-09-30)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=arm64 mainline=7.2.8-sky1-ncz)
exit=0

$ make kernel-debs
[kernel-default-policy] WARN: ... edge symlink -> '...' (unresolved) but local rc tree '...' has KVER '7.3.0-rc4-sky1-ncz'; using it as the edge channel
[kernel-default-policy] edge KVER '7.3.0-rc4-sky1-ncz' (rc; non-default experimental entry)
[kernel-default-policy] rescue entry preservation: both arches carry the *-rescue sparing/promotion logic (directive 2026-09-30)
[kernel-default-policy] OK -- kernel default policy satisfied (arch=arm64 mainline=7.2.8-sky1-ncz)
[kernel-debs] skipping Sky1 kernel packages for amd64
exit=0

$ bash build/lint-platform.sh
lint-platform: OK (83 hooks, 2593 files classified)
exit=0
```

Totals (this branch, HEAD `1d8bdd5d`):

- `bash build/test-kernel-default-policy.sh`: 25 tests, 0 failed
- `make parity`: 25 tests, 0 failed (the parity target re-runs the
  kernel-default-policy suite via `Makefile`)
- `bash build/lint-platform.sh`: passes

### Push (commit 6, this commit)

```
$ git push argonas feat/kernel-default-7.2.8-2026-09-30
To ssh://192.168.207.101/mnt/datapool/git/cix-installer.git
   297ff5f7..1d8bdd5d  feat/kernel-default-7.2.8-2026-09-30 -> feat/kernel-default-7.2.8-2026-09-30

$ git push origin feat/kernel-default-7.2.8-2026-09-30
To https://gitlab.com/ncz-os/cix-installer.git
   297ff5f7..1d8bdd5d  feat/kernel-default-7.2.8-2026-09-30 -> feat/kernel-default-7.2.8-2026-09-30

$ git ls-remote argonas refs/heads/feat/kernel-default-7.2.8-2026-09-30
1d8bdd5dc4c4db3e0aff1a22ecaf9281eb1d4119    refs/heads/feat/kernel-default-7.2.8-2026-09-30

$ git ls-remote origin refs/heads/feat/kernel-default-7.2.8-2026-09-30
1d8bdd5dc4c4db3e0aff1a22ecaf9281eb1d4119    refs/heads/feat/kernel-default-7.2.8-2026-09-30
```

Both remotes are in sync at `1d8bdd5d`. The push to the operator's
ssh mirror (`ssh://jasonperlow@192.168.207.101/...`) succeeds
without a bundle/patch fallback (the r5 report's push failure has
been resolved: the operator mirror accepted the ed25519 key since
the r5 push).

### Files changed on commit 6 (cumulative)

```
$ git diff --stat 297ff5f7..1d8bdd5d
 Makefile                              | 14 +++++++++
 assets/refind/ncz-refind-refresh.sh   | 18 +++++++++++
 build/build-iso-di.sh                 | 19 ++++++++++++
 build/test-kernel-default-policy.sh   | 57 ++++++++++++++++++++++++++++++++---
 build/verify-kernel-default-policy.sh | 42 ++++++++++++++++++++++++++
 post-install/10-amd64-kernel.sh       | 16 +++++-----
 6 files changed, 155 insertions(+), 11 deletions(-)
```

### Branch SHAs on both remotes (final, this commit)

```
$ git log --oneline 727c9a62..HEAD
1d8bdd5d kernel(policy): close the .66 incident -- defense in depth at every gate
297ff5f7 docs: kernel-default-policy report -- add Step 1 shipped-image inspection (both arches)
0cc686b8 docs: kernel-default-policy report -- record commit 4 (offline fallback) and final test inventory
aabf5e59 merge: bring gitlab's runtime defence-in-depth + offline-fallback commits into the local branch
47545e01 kernel(policy): verifier runs on dev hosts without the kernel-staging pool mounted
c5f57fc6 kernel(policy): amd64 runtime defence in depth (classifier + refresh refuse edge)
834dd7f4 kernel(policy): delete amd64-edge; amd64 ships only the 7.2.x stable line
f13febfa kernel(policy): enforce 7.2.8 as default on every arch; arm64-only edge for 7.3-rc5
```

Six commits on top of `release/dual-arch-2026-09-29` (base
`727c9a62`); HEAD is `1d8bdd5d` on both `argonas` and `origin`
(gitlab). This matches the operator's standing rule "before
reporting done: tests pass, git status clean, HEAD committed AND
pushed (ARGONAS origin ssh://... plus the gitlab remote if the
repo has one)".

### Things still explicitly NOT verified (cumulative)

1. QEMU/KVM boot of a fresh image on either arch. The operator
   rule forbids kernel rebuilds and hardware reboots; the
   static-gate + fixture-test path is the highest rigour permitted
   by the rules.
2. `assets/kernel/mainline` symlink target on the next build host
   run. Whoever runs the build must point it at the validated
   `r277-7.2.8-sky1-ncz` tree (the verifier will refuse anything
   else, with or without the fallback).
3. The Cygnus 26.10 branding branch
   (`origin/feat/cygnus-26-10-2026-09-30` @ d2956cd0) is NOT
   merged into this branch per operator policy.
4. Live boot of a fully-rebuilt image on the .66 (Sky1, MS-R1)
   hardware. The operator's standing rule is "never reboot
   hardware" -- the proof is by static gate + fixture test only.
5. The arm64 edge KVER on the build farm is r279 7.3.0-rc5
   (kernel-staging pool); locally we only have r273 7.3.0-rc4.
   The verifier accepts either.
