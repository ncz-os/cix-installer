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
  kernel (arm64 mainline, amd64 stable) must start with `STABLE_BASE`, and a staged arm64
  edge kernel must start with `EDGE_BASE`. Tests are in `build/test-kernel-default-policy.sh`.

Not yet implemented (needs a reviewed follow-up before an image ships amd64 edge):

- `build/verify-kernel-default-policy.sh` checks 5 and 8, `build/stage-amd64-kernel.sh`,
  `build/publish-amd64-kernel.sh`, `build/build-iso-di.sh` and `build/build-squashfs-layers.sh`
  still refuse any amd64 edge payload.
- The amd64 rEFInd classifier hook and refresh script still refuse to write an edge entry.
- A Sky1 7.3-rc6 kernel does not exist yet; the Sky1 edge channel stays rc5 until it is built
  and passes the static, DKMS ABI and KVM gates. Until then an image has no Sky1 edge entry
  rather than a rc5 one that contradicts this policy.

The next image therefore ships 7.2.9 stable and the installer on 7.2.9 on both arches, and
gains the edge entries only when the follow-up lands and the rc6 kernels are staged.
