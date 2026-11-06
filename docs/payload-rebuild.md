# Singularity payload rebuild — runbook

Purpose: rebuild `ncz-singularity-desktop` from the bumped upstream pins once the
patch queue is settled, and refresh the pins that record it.

## What blocks it, and what does not

**Not blocked by the Debian mirror.** Neither `build/build-singularity.sh` nor
`build/build-singularity-deb.sh` contains a debootstrap or chroot step — the payload
is built with the host toolchain against the pinned sources. The snapshot outage that
has been holding the rootfs assets since 09:57Z does not touch this path.

**Blocked by the patch queue.** The build applies the downstream queue inside a
disposable workspace, so any patch that does not apply stops it. Current state at the
pinned commits: shell 13/13, loginui 3/3, greeter 3/3, nearby 1/1, desktop 0 files,
plugins 3/5 — the two exceptions are `singularity-plugins/0001` (density-derived
column count) and `0005` (contrast via `scrim_for()`), both awaiting a product
decision because upstream reimplemented each feature differently.

## Preconditions

1. `bash build/singularity-pins.sh validate` → `[pins] OK: 84 upstream pins … cover
   every patch queue` (verified 2026-11-06).
2. The patch queue decides cleanly in every repo. Prove it before building rather
   than after a 40-minute compile:
   `bash build/singularity-patch-drift.sh <scratch-clone> assets/singularity/patches/singularity-<repo>`
   per repo, or `bash build/singularity-pins.sh check-patches` for the full clone-and-apply pass.
3. Scratch clones at the pinned commits exist for each repo carrying patches
   (`~/scratch-<repo>-*` are sufficient for the drift tool; `check-patches` clones its own).

## Build

```
# 1. payload tree
bash build/build-singularity.sh            # applies the queue in a disposable
                                           # workspace, writes build/sinty-out/singularity-opt.tgz

# 2. package it
NCZ_SINGULARITY_GIT_SHA=<superproject-sha> \
  bash build/build-singularity-deb.sh build/sinty-out/singularity-opt.tgz
```

Without `NCZ_SINGULARITY_GIT_SHA` the deb version is tagged from the tarball content
hash (`tgz<sha256:8>`), so different content can never reuse a version — that is the
property the version gate relies on. Prefer supplying the superproject SHA: it makes
the version traceable to `assets/singularity/upstream-pins.tsv`.

## Record what was built

1. `manifests/singularity-payload.tsv` — the per-arch row
   (`<arch>\t<sha256>\t<version>`). `build/gen-base-pin.sh` reads field 2 and emits
   `singularity_payload_sha256_<arch>` into `manifests/determinism.pin`, which seeds
   the hotfix layer fingerprint.
2. The image layers stage `NCZ_SINGULARITY_PREBUILT_DEB` / `NCZ_SINGULARITY_PREBUILT_SHA256`;
   `build/layers-preflight.sh check_frozen_deb` rejects a mismatch.
3. If the payload's gschema keys or the patch list changed, update the header of
   `manifests/singularity-payload.tsv` so the next reader knows what the build carries.

## Verification before calling it done

- `dpkg-deb -f` on the artifact: name, version, architecture as expected.
- The version string carries `bk0` plus either the git tag or the tarball hash.
- `manifests/determinism.pin` matches the artifact hash on both arches.
- Install on a soak host per the SING-TEST procedure; the desktop payload is already
  the thing that procedure hashes (`libscreensaver.so`), so a rebuild changes that
  hash and the poll's identity check must be re-baselined deliberately, not silently.

## Notes

- Build on a release host with the toolchain, not on STUDIO.
- One build at a time per host; set a busy marker (`~/.config/hive-worker/busy.d/`).
- Artifacts stay local / on ARGONAS until the orchestrator publishes; no outward push.
