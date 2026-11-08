# Release candidates

A release candidate (rcN) is one commit of cix-installer. This page lists the
candidates cut on the `release/preview4-20261025` line, says what makes a
candidate complete, and how a new kernel gets into the next one.

## The candidates

| rc | commit | amd64 kernel | arm64 kernel | state |
|---|---|---|---|---|
| rc1 | `096c74f4` | 7.3.0-t2-ncz (7.3.0-2) | 7.3.0-sky1-ncz (+r293) | superseded |
| rc2 | `df719dc1` | 7.3.0-t2-ncz (7.3.0-2) | 7.3.0-sky1-ncz (+r293) | superseded |
| rc3 | `ba74b7c7` | 7.3.0-t2-ncz (7.3.0-2) | 7.3.0-sky1-ncz (+r293) | **incorrect**: 7.3.0 was already retired for 7.3.1; desktop images built 2026-11-07 carry it (run metadata `kernel_kver 7.3.0-t2-ncz`) |
| rc4 | branch `hv/rc4-kernel-731-20261107` | **7.3.3-t2-ncz (7.3.3-r297)** | 7.3.3-sky1-ncz (+r298) built and staged; refused until the O6N boot test (see arm64) | amd64 ready to build; arm64 waits for O6N |

rc4 is rc3 (via the image-CI branch `hv/magnetar-ci-20261107` @ `13520afc`,
which sits on `hv/ncz-opus-determinism3-20261107` @ `5702cc38` on `ba74b7c7`)
plus the kernel change and the lifecycle gate. The branch name says 731
because the work started as a 7.3.1 repin; 7.3.3 passed the MEDUSA boot test
during the work and replaced it (operator rule below).

### rc4 amd64 kernel

| field | value |
|---|---|
| KVER / package | `7.3.3-t2-ncz` / `7.3.3-r297` |
| source | v7.3.3 `d50d994bffa3`, amd64-kernel-t2 `0bed835` (`feat/amd64-7.3.3-r297-20261107`), 26 patches |
| pool dir | `kernel-staging/amd64-stable-7.3.3-t2-ncz-20261107` (`staging_pool_relative`) |
| linux-image sha256 | `acd8182dad75de5e3429960c6201ce0cb5146d07d6d268fb233becff894ab48a` |
| linux-headers sha256 | `1fff1b802ef110a4231fef83af3b88e3d19ca1e93d869b92f581f727a0389980` |
| vmlinuz sha256 | `f0709e473fe9cc9fe3f9163307de3a097a0c3f6f3c108c87806efd1d96ff5854` (same as MEDUSA `/boot`) |
| vmlinux build id | `6c0964025578f800beaca05e7c84b5c639025bd2` |
| modules | 6890 `.ko`, none compressed, vermagic `7.3.3-t2-ncz SMP preempt mod_unload modversions` |
| gates | KVM boot (port build's gate and a re-run on these bytes); MEDUSA hardware boot 2026-11-07, 31 min soak, PASS |

Build evidence (provenance, BUILD-IDS.txt, MEDUSA logs) is in
`projects/t2-kernel-stage/7.3.3-r297/` on the artifact store; the manifest
records it in `build_evidence`.

### arm64

The unified policy wants the same kernel series on both arches, so arm64 needs
a 7.3.3 Sky1 build. None exists:

- The committed pin is still `7.3.0-sky1-ncz` (+r293), which is retired.
- `7.3.1-sky1-ncz` exists twice, and neither helps: r295 (pinned on branch
  `build/arm64-r295-pin-20261101`) names a staging dir,
  `kernel-staging/r295-7.3.1-sky1-ncz-20261101`, that does not exist; r297
  (`kernel-staging/arm64-sky1-7.3.1-ncz-ultra-20261102`) is side-by-side debs
  only (`linux-image-7.3.1-sky1-ncz`), not the image input layout. O6N booted
  that r297 kernel twice on 2026-11-02 (journal), but it is below MIN_VERSION
  7.3.3 anyway.
- kernel-ci lists `sky1-arm64 stable 7.3.3` as queued, with no build adapter.

Update 2026-11-07: the missing artifact now exists. `7.3.3-sky1-ncz` r298
(v7.3.3 `d50d994bffa3`, the 7.3.1 series unchanged) was built through the Sky1
lane on ULTRA and staged as `kernel-staging/r298-7.3.3-sky1-ncz-20261107`. That
dir holds the Image, modules, config, headers, Module.symvers, six rebuilt
overlays, the `linux-image-cixmini` / `linux-headers-cixmini` /
`cixmini-boot` debs at `+r298`, O6N side-by-side debs, PROVENANCE, BUILD-IDS
and SHA256SUMS. It has not been booted on hardware. The pin is a ready patch,
not applied (docs/ARM64-KERNEL-733-PIN.md), and the boot test is
docs/O6N-TEST-PLAN-7.3.3.md. `CURRENT_KVER_arm64` stays empty, and every arm64
build stops at the policy gate, until that test passes and the patch is applied.

## What a complete candidate is

A candidate is complete only when all four media are built from that one
commit and are at least `deterministic` in `build/image-ci-matrix.sh --status`
(docs/IMAGE-CI-MATRIX.md): desktop and server (Magnetar), on amd64 and arm64.
Each cell is gated (KVM, provenance, secret scan) and two clean builds compare
equal. Each kernel it pins must be the promoted CURRENT kernel for its arch
(`assets/kernel/KERNEL-LIFECYCLE`), which means it passed a hardware boot test.
rc4 is not complete until arm64 has a promoted kernel and all four cells are
built.

## Kernel promotion

Operator rule (2026-11-07): kernel pins are not hand-edited per release. Once a
new kernel is boot-tested and passes, it replaces the existing one.

The state lives in the kernel-ci registry on the artifact store
(`projects/kernel-ci/registry.json`): a build is `provisional`, then
`boot-tested`, then `current`; the previous `current` becomes `retired`. The
tree sees that state through one committed file the registry writes:

```
assets/kernel/KERNEL-LIFECYCLE
  LIFECYCLE_SCHEMA=1
  MIN_VERSION=7.3.3                       lowest version any pin may use
  CURRENT_KVER_<arch>=  CURRENT_PKG_<arch>=  the promoted kernel per arch
  RETIRED=7.3.0-t2-ncz,7.3.1-t2-ncz,...   never pinned again
```

`build/check-kernel-lifecycle.py` (run by `verify-kernel-default-policy.sh`
Check 11, so by every image build) refuses a pin that is retired, below
MIN_VERSION, not the CURRENT kernel, or not the same in every pin file, and
refuses an arch with no CURRENT kernel. The rc4 values are the seed; this
change is the first promotion.

A promotion flows like this:

1. **Registry update.** The boot test passes (for amd64: MEDUSA). The registry
   marks the build `current`, the old current `retired`.
2. **Generated pin-bump branch.** The registry tool publishes the debs into the
   kernel-staging pool (`build/publish-amd64-kernel.sh`) and opens a branch that
   rewrites `KERNEL-LIFECYCLE` and the pin files below in one commit. The
   lifecycle gate and the tests must pass on it; it is reviewed and merged.
3. **Next build uses it.** `build/stage-amd64-kernel.sh` stages exactly the
   manifest's pool dir and checks each deb's sha256; the freshness gate checks
   the same dir. Older pins fail the gate.

### Pin files a promotion changes

amd64:

| file | change |
|---|---|
| `assets/kernel/KERNEL-LIFECYCLE` | `MIN_VERSION`, `CURRENT_KVER_amd64`, `CURRENT_PKG_amd64`, add the old KVER to `RETIRED` |
| `assets/kernel/amd64-stable/KVER`, `PKGVERSION` | new KVER and package revision |
| `assets/kernel/amd64-stable-manifest.json` | kver, package_revision, build_rev, staging_pool_relative, source (tag, commit, t2 branch and commit), artifacts sha256/size, identity (vmlinuz sha256, build id), gates |
| `manifests/ncz-packages.tsv` | the linux-image / linux-headers rows |
| `manifests/components.tsv` | regenerate: `python3 build/gen-components-registry.py` |
| `manifests/determinism.pin` | ledger digest; check with `bash build/gen-base-pin.sh --check` |
| `assets/kernel/KERNEL-POLICY` | the one comment line naming the pinned versions |

arm64 (first Sky1 promotion): `KERNEL-LIFECYCLE` (`CURRENT_KVER_arm64`,
`CURRENT_PKG_arm64`), `assets/kernel/mainline.release`,
`assets/kernel/mainline.deb-revision` (delete when the staged release has its own
revision), `assets/kernel-manifest.json` (regenerate with
`build/kernel-manifest.py gen`), `assets/kernel/sky1-manifest.json`, the overlay
dirs `assets/kernel/{mali,npu,panthor,vpu}/<KVER>/`, `manifests/ncz-packages.tsv`
(linux-image-cixmini, linux-headers-cixmini, cixmini-boot),
`manifests/components.tsv` and `manifests/determinism.pin`.

### Checks for a pin-bump branch

```
bash build/test-kernel-lifecycle.sh
bash build/test-kernel-default-policy.sh
bash build/test-stage-amd64-kernel.sh
bash build/test-amd64-freshness-gate.sh
bash build/test-pin-coherence.sh
bash build/test-kernel-revision-pin.sh
bash build/test-build-image.sh
bash build/gen-base-pin.sh --check
python3 build/check-kernel-lifecycle.py --arch amd64   # and arm64
```
