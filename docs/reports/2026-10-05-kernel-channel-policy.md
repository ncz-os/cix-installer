# Kernel channel policy: stable 7.2.9, edge 7.3-rc6, both architectures

Operator directive 2026-10-05. Supersedes the "amd64 ships no edge" and "edge is
7.3.0-rc5" parts of `2026-09-30-kernel-default-policy.md`. Everything else in that
report still holds (default is never an -rcN, rescue entry kept on both arches,
build-time gates against a misdirected `assets/kernel/mainline` symlink).

## Rule

| channel | version | boots as | AMD64 (T2 and non-T2) | Sky1 (arm64) |
|---|---|---|---|---|
| stable | **7.2.9** | default | `7.2.9-N-t2-trixie` | `7.2.9-sky1-ncz+rNNN` |
| edge | **7.3-rc6** | separate non-default entry | `7.3.0-rc6-N-t2-edge-aerfix` | `7.3.0-rc6-sky1-ncz+rNNN` |
| installer boot kernel | **7.2.9** | installer media | yes | yes |

- The default is always the stable kernel. Edge is never the default and never the only
  installed kernel. The rescue entry is preserved on both arches.
- The installer media boots 7.2.9 on both arches (already true on this line, `b43e3e52`).
- 7.2.8 is retired; 7.3-rc5 is retired as the edge version.
- Test hosts MEDUSA and CHIMERA (T2 MacBook Pros) are set to this layout: 7.2.9 stable,
  7.3-rc6 edge.

## Why amd64 may now ship edge

The 2026-09-30 ban existed because no validated amd64 7.3 kernel did. 7.3 on T2 Macs lost
power 16 to 27 s after boot. That was bisected (19 steps) to upstream commit
`eddba19b8b5f` "PCI/AER: Support Advisory Non-Fatal Errors" and proven by a revert test:
7.3.0-rc6 without the revert cut power at 16.7 s, with it survived a 64 s hold. The amd64
edge kernel must therefore carry the revert (`9010-Revert-PCI-AER-Support-Advisory-Non-Fatal-Errors.patch`,
t2linux linux-t2-patches PR 70) and must not build with `CONFIG_SENSORS_APPLESMC`.
The build `7.3.0-rc6-1-t2-edge-aerfix` booted the full desktop on MEDUSA and held 363 s.
Its provenance, SHA256SUMS and static and KVM gate output are under the kernel-staging
pool `amd64-t2-rc6-20261004/`.

## Enforcement

Implemented in this change:

- `assets/kernel/KERNEL-POLICY` pins `STABLE_BASE=7.2.9` and `EDGE_BASE=7.3.0-rc6`.
- `build/verify-kernel-default-policy.sh` check 10: when the file is present, the default
  kernel (arm64 mainline, amd64 stable) must start with `STABLE_BASE`, and a staged edge
  kernel (arm64 edge, amd64 edge) must start with `EDGE_BASE`. Tests are in
  `build/test-kernel-default-policy.sh`.

Sky1 edge (arm64) is staged:

- `assets/kernel/edge` points at the rc6 build
  `kernel-staging/r282-7.3.0-rc6-sky1-ncz-20261004`, so check 10 sees the pinned
  `EDGE_BASE=7.3.0-rc6` on the build farm (where the kernel-staging pool is mounted).
- The four accelerator overlays for that KVER are mirrored in-tree under
  `assets/kernel/{mali,npu,panthor,vpu}/7.3.0-rc6-sky1-ncz/`, which is what the
  arm64 rEFInd refresh requires before it will emit the accelerated edge entry.
- `assets/kernel/edge-manifest.json` records paths, sha256 and the source revision.
  The full build evidence (PROVENANCE, SHA256SUMS, KVM and DKMS-ABI gate logs) is in
  the staging directory itself.
- Evidence and reproduction: `docs/reports/2026-10-05-sky1-r282-rc6-staging.md`.

amd64 edge is now implemented (follow-up to the Sky1 staging):

- The amd64 edge kernel is the 7.3.0-rc6 T2 build with the AER ANFE revert
  (`7.3.0-rc6-1-t2-edge-aerfix`). `assets/kernel/amd64-edge/KVER` and
  `assets/kernel/amd64-edge-manifest.json` pin and record it.
- `build/verify-kernel-default-policy.sh` checks 5, 8 and 10 accept the pinned amd64 edge
  and refuse every other -rc; `build/stage-amd64-kernel.sh edge` and
  `build/publish-amd64-kernel.sh edge` stage/publish it under the pinned KVER;
  `build/build-iso-di.sh`, `build/iso/write-usb-image.py`,
  `build/verify-base-kernel-assets.sh` and `build/preflight-freshness-gate.sh` carry it.
- `post-install/10-amd64-kernel.sh` installs it as a second, non-default line, and the
  amd64 rEFInd classifier hook and refresh script surface it as the edge entry while
  refusing unpinned -rc kernels.
- Evidence and reproduction: `docs/reports/2026-10-05-amd64-edge-rc6-revert.md`.

The next image therefore ships 7.2.9 stable and the installer on 7.2.9 on both arches, plus
the Sky1 arm64 7.3.0-rc6 edge entry and the amd64 7.3.0-rc6 AER-revert edge entry.
