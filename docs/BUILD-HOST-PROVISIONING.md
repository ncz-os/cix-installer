# Turning an installed NCZ-OS box into a build host

**Status:** deliverable only — DO NOT provision cixmini now (operator decision
D6, 2026-10-10: "we can advance .66 to second builder once we stabilize its
installation"). The operator reflashes cixmini with the new r203 arm64 image;
this checklist is what to run **after** that, when the operator says go.
**Author:** Jason Perlow `<jperlow@gmail.com>`

This is the checklist for promoting an installed NCZ-OS machine (specifically
**cixmini `192.168.207.66`**, CIX Sky1 / Cortex-A720) into a **second arm64
build host**, so `build/verify-reproducible.sh --arch arm64` can do a real
two-host comparison instead of same-host-twice. A bit-identical rebuild across
cixmini (CIX Sky1) and ULTRA (Apple Silicon / Asahi) proves **CPU-independence**
of the build — no `-march=native`, no CPU-feature-dependent codegen/paths.

> Everything here is a **build host** concern. The host stays a normal NCZ-OS
> install; nothing here changes the shipped image. `build/verify-reproducible.sh`
> runs builds with `--no-publish`, so nothing is shipped from a test host.

## 0. Preconditions

- The box is a **freshly installed r203 arm64 image** and boots to the desktop.
- `sudo` works for the `ncz` user (fleet model: `~/.api_keys_master.json`
  `fleet_credentials.sudo_password`, or passwordless sudo for the build user).
- Network reachable to ARGONAS and to the fleet; the clock is synced.
- **≥ 200 GiB free** on a **real disk** (never tmpfs, never `/tmp` if it is a
  tmpfs — check `findmnt -no FSTYPE -T /tmp`).

## 1. Packages (Debian forky base)

`build/lib/envpin.sh` and `build/build-image.sh` preflight name the host tools.

```
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  git make python3 mksquashfs mkfs.ext4 sgdisk sfdisk tar sha256sum zstd \
  unsquashfs mke2fs util-linux e2fsprogs squashfs-tools ca-certificates \
  rsync mformat dosfstools qemu-utils openssh-client
```

- `podman` (rootful or rootless — see §3). Docker is accepted but the fleet uses
  podman.
- The **exact toolchain versions must match `manifests/env.pin`** for the
  `host`-scope keys (or the run is a WARN). The heavy tooling that affects
  artifact bytes runs **inside the pinned container**, so host drift is
  tolerable; set `NCZ_ENVPIN_STRICT_HOST=1` only when the verification pair is
  required to have identical host toolchains.

## 2. The pinned build container (by digest)

Every builder must load the **same** `ncz-imagebuild:trixie` image **from the
same saved tar**, so its digest matches `manifests/env.pin`:

```
# on the source builder (ULTRA):
sudo podman save -o ncz-imagebuild-trixie.tar localhost/ncz-imagebuild:trixie
# copy the tar to the new box, then:
sudo podman load -i ncz-imagebuild-trixie.tar
sudo podman image inspect --format '{{.Digest}}' localhost/ncz-imagebuild:trixie
# this MUST equal manifests/env.pin container imagebuild_digest
```

Build it from `build/containers/Containerfile.ncz-imagebuild` if no tar exists.
`preflight` FAILS on a digest mismatch — a differing digest means the box is not
the environment the pin was taken from.

## 3. Privilege model

`build/lib/priv.sh` is the only model: root → direct; passwordless sudo → `sudo`;
otherwise the fleet sudo password from `~/.api_keys_master.json` on **stdin
only**. Rootless podman is fine for the container stages; the KVM gate needs
`/dev/kvm` (see §5).

## 4. ARGONAS mounts and caches

The build reads the kernel-staging pool and the content-addressed input caches:

- `/mnt/argonas-yocto-shared` (ULTRA spelling) **or** `/mnt/argonas/datapool/yocto-shared`
  — the kernel-staging pool. `assets/kernel/mainline` is a committed symlink; the
  preflight auto-bind-mounts the alternate spelling if needed.
- `/mnt/datapool/projects/ncz-os-assets/build-inputs/` — the hermetic caches
  (`git-mirrors/`, `go-modcache/`, `meson-subprojects/`, `cargo-vendor/`,
  `npm-store/`, `pip-wheelhouse/`, `downloads/`). These are **build inputs, not
  scratch** — list them for the reaper KEEP list; never reap them.
- `/mnt/datapool/projects/ncz-os-assets/substrate/`, `.../images/`,
  `.../ncz-singularity-debs/` as needed.

Provide them over NFS (per the fleet matrix) or set `NCZ_BUILD_INPUT_CACHE` to a
local mirror of the cache tree. Scratch goes under `~/Projects`, **not** `/tmp`.

## 5. KVM / device access

The KVM install gate is optional for a *second-builder verification* run
(`--gates provenance`), but needed for a full local gate. Enable `/dev/kvm` for
the build user (`kvm` group, or rootful) exactly as the other hosts do:

```
ls -l /dev/kvm
# root-run gate, or: sudo usermod -aG kvm ncz  (then re-login)
```

## 6. Fleet keys and ARGONAS access

- `~/.ssh` authorized_keys as the fleet does it (the fleet rotates keys between
  hosts; see the sentinel's `authorized_keys.bak-*` convention).
- No ARGONAS password in tracked files (r203 removed one; never re-add).
- No release signing keys on a build host (D7: operator-held only).

## 7. Reaper / scratch policy

Follow `~/.claude/rules/scratch-and-cleanup.md`: every build leaves a cleanup
receipt; scratch under `~/Projects`; no build leftovers on tmpfs. Add a reaper
timer as the other build hosts have it, and add the `build-inputs/` caches to the
**KEEP** list.

## 8. Register the host and enable the second-builder path

1. Add a row to `build/config/builders.tsv`:
   `cixmini  192.168.207.66  arm64  CIX Sky1 (Cortex-A720)  localhost/ncz-imagebuild:trixie  pending`
   → flip `pending` to `second` when validated.
2. Verify the environment pin on the new box:
   `make test-env-pin` (or `bash build/gen-env-pin.sh --check`).
3. Prove the enforcement works there: `make test-hermetic`.
4. Run the second-builder verification:
   `build/verify-reproducible.sh --arch arm64 --primary ultra --second cixmini`.

## 9. What proves CPU-independence

`verify-reproducible.sh` records, per builder, `builder_cpu`, `builder_kernel`,
and `builder_container_digest` in the attestation. A byte-identical arm64 result
from **ULTRA (Apple Silicon)** and **cixmini (CIX Sky1 / Cortex-A720)** is the
explicit CPU-independence claim; until cixmini is ready the attestation records
`second_builder = "pending(cixmini)"` and the run is same-host-twice on ULTRA.

## 10. Rollback / un-provision

Nothing here is irreversible: remove the container image, the reaper timer, and
the `builders.tsv` row (or leave it `pending`). The box stays a normal NCZ-OS
install; no image or boot configuration is changed by being a build host.
