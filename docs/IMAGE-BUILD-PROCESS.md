# NCZ-OS image build process — single source of truth

This document is the authoritative description of how an NCZ-OS install image
is built: the inputs and pins, the one command, what every stage reads and
writes, the determinism contract and how to verify it, the gates, where
artifacts live, and what the build is **never** allowed to do.

It supersedes the step-by-step instructions that used to live in
[AMD64-IMAGE-BUILD.md](AMD64-IMAGE-BUILD.md) and
[ARM64-IMAGE-BUILD.md](ARM64-IMAGE-BUILD.md); those files now carry only the
per-host notes and point back here. The human steps **after** a passing build
(operator validation, ship, reap) are in
[IMAGE-RELEASE-RUNBOOK.md](IMAGE-RELEASE-RUNBOOK.md).

> **One rule above all:** an image is *repeatable and deterministic* when the
> same pinned inputs produce bit-identical artifacts. This document defines the
> pins (§2), the contract (§5), and the tool that proves it
> (`build/compare-images.sh`). If a change makes two builds differ and it is not
> listed as a documented exception (§5.4), it is a bug.

---

## 1. The one command

```sh
build/build-image.sh --arch amd64|arm64|both [SCOPE] [OPTIONS]
# or, equivalently:
make release-image ARCH=amd64 RELEASE_IMAGE_ARGS="--full"
```

The entrypoint runs the whole pipeline in a fixed order and refuses to publish
anything that did not pass every required gate. `--help` prints the full flag
list; `--dry-run` prints the exact plan (which stages run, which layers are
reused, the derived UUIDs) without touching anything.

```sh
build/build-image.sh --arch amd64 --full --dry-run
build/build-image.sh --arch both  --full            # amd64@ACHILLES + arm64@ULTRA, in parallel
build/build-image.sh --arch amd64 --components screensavers   # one package changed
build/build-image.sh --arch arm64 --no-publish --gates kvm    # local build, no copy to ARGONAS
```

### Which flag do I use?

| Situation | Flag |
|---|---|
| New substrate / weekly netinst, full release build | `--full` (default) |
| One package/component changed | `--components <name>` |
| Desktop layer or Singularity payload bump | `--rebuild-desktop` |
| Base layer change (kernel, apt policy, post-install, assets) | `--rebuild-base` |
| Only the hotfix overlay changed | `--rebuild-hotfix` |
| Re-assemble from cached layers, no layer rebuild | `--only-image` |
| Reuse whatever is unchanged, rebuild the rest | `--respin` / `--quick-respin` |
| Both arches at once | `--arch both` |
| Build but never copy to ARGONAS | `--no-publish` |
| Run only some gates (local check) | `--gates kvm,provenance --no-publish` |

### Scope semantics

* **`--full`** — refresh the substrate, rebuild the offline mirror and every
  layer (base → desktop → hotfix), assemble the image, run every gate. This is
  the only scope that refreshes the substrate by default.
* **`--respin` / `--quick-respin`** — the offline mirror and every layer whose
  input **fingerprint** (§5.2) is unchanged is reused; anything whose inputs
  changed, and every layer above it, is rebuilt; the image is always
  re-assembled and re-gated exactly like a full build.
* **`--rebuild-base`** — rebuild the base layer and everything above it.
* **`--rebuild-desktop`** — rebuild the desktop layer (including the Singularity
  payload rebuild/re-pin) and the hotfix layer above it.
* **`--rebuild-hotfix`** — rebuild only the hotfix overlay.
* **`--components LIST`** — expand the named components to the minimum set of
  layers and rebuild those plus dependents:
  `kernel, base-assets, apt-policy, post-install, base → base`;
  `desktop, desktop-mirror, screensavers, wallpapers, plugins → desktop`;
  `singularity → desktop + hotfix`; `installer-initrd, preseed, image → image`.
* **`--only-image`** — re-assemble the image from the cached layers; no layer is
  rebuilt.

A published image must have run **all** required gates (§6). `--gates` may only
be combined with `--no-publish`: a build that skips a gate can never be copied
to the ARGONAS image store.

### Artifact naming and receipt

* Image: `build/ncz-os-<arch>-<YYYYMMDD>-<git-short-sha>.img`
  (the build date is the only date in the name; it is **not** an input to any
  hash).
* Image receipt: `<image>.receipt.json` — written by `build/iso/write-usb-image.py`;
  lists the staged layers, their overlay manifests, the tool payloads, the
  `.deb` sha256s it embedded and (from the provenance work) the
  `ncz_timestamped_debs` map used by the provenance gate.
* Gate summary: `<image>.gates.json` — written by the receipt stage; records the
  `kvm`/`provenance`/`ui`/`one_kernel` results and `all_required_passed`.
* Run metadata: `<run-dir>/run-metadata.json` — the build-time record: mode,
  flags, per-layer fingerprint + `reused|rebuilt`, git SHA, pin digest,
  `SOURCE_DATE_EPOCH`, host, finish time. **This file is deliberately not an
  input to any artifact hash** (§5.3), so it may carry wall-clock values.

---

## 2. Inputs and pins

The determinism root is **`manifests/base.pin` plus the git commit**. `base.pin`
aggregates every upstream/substrate pin into one file that the build hashes;
its canonical digest (`build/lib/reproducible.py pin-digest`) seeds every derived
UUID and `SOURCE_DATE_EPOCH`. Pins come from their authoritative sources, never
hand-edited:

| Pin | Authority | How to refresh | Who may |
|---|---|---|---|
| Substrate (Debian testing netinst, per arch) | `Makefile` `SUBSTRATE_SHA`; cached on ARGONAS | `build/refresh-substrate.sh --arch <a>` (verifies SHA256SUMS + GPG against the committed CD key, derives the snapshot, writes `base.pin`) | operator / build owner |
| Snapshot (`snapshot.debian.org` timestamp) | derived from the substrate by `build/derive-base-pin.py` | same as above; must be ≥99% coverage of the substrate | operator / build owner |
| Kernel debs | `assets/kernel/<channel>/KVER`, `assets/kernel-manifest.json`, `manifests/build-inputs.tsv` | bump the KVER commit + re-run `build/kernel-manifest.py`; stage via the kernel-staging pool | kernel owner |
| `cix-*` / vendor debs, NCZ packages | `manifests/vendor-debs.tsv`, `manifests/ncz-packages.tsv`, `manifests/ncz-timestamped.tsv` | reviewed row with name/version/arch/sha256/recipe/source_revision | operator (reviewed) |
| Singularity payload | `assets/singularity/upstream-pins.tsv`, optional `manifests/singularity-payload.tsv` | bump the upstream commit pin, or record the prebuilt deb sha256 | singularity owner |
| Wallpaper / screensaver packs | `assets/wallpaper*`, `manifests/build-inputs.tsv` | build the pack deb, re-pin | operator |
| Git-ignored staged inputs (rescue/mgmt rootfs, python311, wallpaper debs) | `manifests/build-inputs.tsv` | `build/stage-build-inputs.sh --arch <a> --publish` from the tree that holds the file | build owner |

`build/gen-base-pin.sh` (this branch) regenerates `manifests/base.pin` from
these sources and `--check` fails preflight when it is stale. The provenance
branch replaced the substrate/snapshot authority with
`build/refresh-substrate.sh` + `build/derive-base-pin.py`; both are compatible
with the fingerprint reader in `build/lib/layerplan.py`, which accepts either
the key/value pin or the arch-major pin.

---

## 3. Host and tool prerequisites

Heavy work never runs on a laptop/STUDIO. The `--arch both` mode dispatches
each arch to its own host.

| Arch | Host | Notes |
|---|---|---|
| amd64 | ACHILLES `192.168.207.11` (`NCZ_AMD64_HOST`) | x86_64, rootful podman, `/dev/kvm` usable as root |
| arm64 | ULTRA `192.168.207.88` (`NCZ_ARM64_HOST`) | aarch64; stage 0/2 in the `ncz-imagebuild:trixie` container, **stage 1 on the bare host** |
| verification | HYDRA `192.168.207.78` | cross-check / second-host determinism runs |

Per host:

* `git make python3 mksquashfs mkfs.ext4 sgdisk tar sha256sum zstd unsquashfs`
  present; `podman` and the `localhost/ncz-imagebuild:trixie` image for the
  container stages; `mformat`/`rsync` for `--no-container`.
* Disk: ~20 GiB working headroom at the run dir (the KVM gate workdir is the
  large consumer and is cleaned by policy).
* Scratch **must** be on a real disk, never a tmpfs. The entrypoint sets
  `TMPDIR` under the run dir and preflight fails if the run dir is `tmpfs`.
* Kernel staging: `assets/kernel/mainline` is a committed symlink using the
  ULTRA spelling `/mnt/argonas-yocto-shared/...`. On a host where that path is
  absent but `/mnt/argonas/datapool/yocto-shared` exists, preflight performs the
  bind mount automatically (this was a manual step in r202).

### Privilege model (one model, no password FIFOs)

`build/lib/priv.sh` is the single model:

1. already root → run directly;
2. passwordless sudo → `sudo`;
3. otherwise → read the fleet sudo password from
   `~/.api_keys_master.json` (`fleet_credentials.sudo_password`) with
   `python3 -I` and feed it to `sudo -S` **on stdin only** — never a file, never
   argv, never logged.

`--privilege` is reported in the plan and recorded in `priv.model`. The r202
"password FIFO" is gone.

---

## 4. Stages

The pipeline is a fixed list of stages; each writes a timestamped log under
`<run-dir>/logs/NN-<stage>.log` and a row in `<run-dir>/stages.tsv`. A failure
aborts with the stage name and a ready-to-paste resume command.

| # | Stage | Reads | Writes | Gate / failure semantics |
|---|---|---|---|---|
| 00 | `preflight` | host, tools, `base.pin`, disk, `/dev/kvm` | `priv.model`, plan | exit 3 on any precondition; actionable message |
| 10 | `refresh-substrate` | `build/refresh-substrate.sh` (or the pinned ISO cache) | refreshed `base.pin`, pinned ISO into `downloads/` | fails closed on signature/sha mismatch; `--substrate pinned` only within the 8-day staleness guard |
| 20 | `stage-inputs` | `manifests/build-inputs.tsv` | staged `assets/…` | refuses a missing/mismatched git-ignored input |
| 30 | `offline-mirror` | the forky/vendor/desktop mirror sources + package manifests | `build/{forky,desktop,vendor}-mirror`; `mirror.build-fingerprint` | every image `.deb` resolves from the pinned snapshot |
| 40 | `layers` | the offline mirror + staged assets + the layer plan | `assets/squashfs/{base,desktop,desktop-hotfix}.squashfs` (+ `.build-fingerprint`) | reuse/rebuild per fingerprint; a stale layer is rotated aside, never clobbered |
| 50 | `image` | layers + mirror + ESP/initrd content | `build/ncz-os-*.img` + `.receipt.json` | refuses a partial layer set |
| 60 | `kvm-gate` | the image | `kvm-gate.result`, gate log | install + boot + installer-UI check; must end `GATE PASS` |
| 70 | `provenance-gate` | the image + snapshot index | `provenance.result` | three-origin + one-kernel rule; must PASS |
| 80 | `receipt` | the run | `run-metadata.json`, `<image>.gates.json` | records mode, flags, per-layer fingerprint + decision, gate results |
| 90 | `archive` | the image + gate results | copy in the ARGONAS images dir + sidecars | **refuses unless kvm AND provenance PASSed this run**; never `ship-image` |

Resume: `build/build-image.sh --arch <a> --resume-from <stage> --run-dir <dir>`.
`--resume-from kvm-gate` onwards accepts `--image <path>` to gate an image that
already exists.

---

## 5. Determinism contract

### 5.1 Definition

> Given the same **git commit** and the same **`manifests/base.pin`**, a build
> produces **bit-identical** artifacts: the built `.img`, every squashfs layer,
> the initrd, and the ESP contents. `SOURCE_DATE_EPOCH`, every filesystem/GPT
> UUID, the FAT volume serial, tar/cpio member order and ownership, and the
> squashfs compression parameters are all derived from the pin or fixed.

### 5.2 Fingerprints (what makes a quick respin safe)

`build/lib/layerplan.py` is the single implementation of a layer's input
fingerprint: a sha256 over the **content** of every declared input of the layer
— package lists, hook scripts (`post-install/`), asset trees (including
`assets/wallpaper/`), the kernel/payload deb sha256s, the upstream/substrate
pins, and (recursively) the layers below it. The dependency chain is
`mirror → base → desktop → hotfix`; if a lower layer changes, every layer above
it is rebuilt against the new bytes.

The fingerprint deliberately **excludes the git commit SHA and
`SOURCE_DATE_EPOCH`**: including them would make every commit invalidate every
layer and a quick respin could never reuse anything. The commit SHA and
`SOURCE_DATE_EPOCH` are part of the image and the run receipt, where they
belong. A change to a build **script** (`build/*.sh`) is content and does
invalidate the layers it feeds.

The r202 report found the old base reuse stamp missed `assets/wallpaper/` and
`post-install/`; the fingerprint now covers them (and the kernel channel layout,
the kernel-deb manifest and the mirror closure).

### 5.3 What is fixed and how

* `SOURCE_DATE_EPOCH` = the git commit time (or `snapshot_epoch` with no git
  history); `NCZ_SOURCE_DATE_EPOCH` can pin it explicitly. `LC_ALL=C`,
  `TZ=UTC`, `umask 022`.
* `tar` → `--sort=name --format=gnu --mtime=@$SOURCE_DATE_EPOCH --owner=0
  --group=0 --numeric-owner` (`ncz_tar_repro`).
* `mksquashfs` → `-comp zstd -Xcompression-level 15 -all-time 0 -fstime 0
  -processors 1 -xattrs-exclude '^security\.selinux' -noappend` (`ncz_mksquashfs`;
  SELinux labels are host-specific and excluded, `security.capability` is kept).
* ext4 → `mke2fs -U <pin-uuid> -E hash_seed=<pin-hash-seed>`; vfat → fixed serial;
  GPT → fixed disk + partition GUIDs; all derived from the pin
  (`ncz_uuid`/`repro_uuid`).
* No unpinned network fetch inside the build: everything comes from the pinned
  mirror/snapshot/ARGONAS cache with sha256 verification; `--offline` blocks the
  network (proxy `127.0.0.1:9`) and fails if anything needs to fetch.
* Package lists are sorted, `apt` uses `--no-install-recommends` and the pinned
  snapshot explicitly.
* Initramfs / cpio are built with `SOURCE_DATE_EPOCH` and a reproducible member
  order.
* The build time appears **only** in `run-metadata.json` (never an artifact
  input). The image name carries a date, which is not hashed.

### 5.4 Documented exceptions

Any artifact that legitimately differs is listed in an `--expect` file passed to
`build/compare-images.sh`, with a rule
(`content-equal-container-diff`, `json-volatile-only`, or `documented-exception`)
and a one-line reason. As of this revision there are **no exceptions for the
.amd64/arm64 final image**; container-level metadata differences on a squashfs
whose normalised member listing is identical are auto-accepted
(`content-equal-container-diff`). A first-boot-generated item (machine-id, ssh
host keys, random seeds) must not be in a hashed artifact at all; anything that
must be generated at first boot is documented in the layer's hook, not
fingerprinted into the layer.

### 5.5 How to verify (the proof)

```sh
# build twice from clean state, then:
build/compare-images.sh --arch amd64 \
    --layers runA/assets-squashfs runB/assets-squashfs \
    --report report.json buildA.img buildB.img
```

It compares the whole-file sha256 of the final image and of every layer, the
initrd and the ESP, and for any difference decomposes it (normalised squashfs /
FAT / cpio listings, canonical JSON) and accepts it only when an `--expect` rule
matches. Exit 0 = deterministic (or fully explained); exit 1 = a real
regression. See `reports/r203-determinism/` on ARGONAS for the evidence.

```sh
make test-build          # unit-level: SDE/UUID derivation, tar/squashfs
                         # byte-stability, fingerprint invalidation, CLI, plan
```

### 5.6 A quick respin equals a full build

The plan guarantees that an unchanged layer keeps its bytes and a changed layer
is rebuilt against the same lower-layer bytes a full build would use, so
`compare-images` of a full build vs a `--components X` respin from the same pin
must be identical. `build/test-build-image.sh` proves the plan/fingerprint
mechanics; the host-side proof is recorded under `reports/r203-determinism/`.

---

## 6. Gates

* **KVM gate** (`build/kvm-install-gate-gpt.sh`) — installs the image unattended
  in QEMU/KVM, verifies the installed target, then boots the installed disk.
  Phase 1 must reach the finish stage with no ship-critical hook failure and no
  optional-hook WARN; phase 2 must reach userspace with zero unexpected failed
  units. The **installer UI check** (`build/check-installer-screens.py`) runs
  inside this gate and asserts the branded dialogs and that the console never
  goes blank. `/dev/kvm` is used as root when the device is not directly
  writable (r202 workaround #2).
* **Provenance gate** (`build/check-forky-provenance.sh` +
  `build/forky-provenance.py`) — the **three-origin rule**: every `.deb`/`.udeb`
  in the image is from the pinned Debian snapshot, the reviewed vendor/NCZ
  ledgers, or the substrate (which must itself be authorized by the pinned
  snapshot). It also enforces the **one-kernel rule**: exactly one kernel
  version across every layer, the ESP/boot files, the `/cdrom` pool, the
  installer initrd and refind entries — the NCZ kernel only, no Debian kernels.
* **Substrate refresh rule** — the substrate must be refreshed **every build**
  and its snapshot derived from it; the gate fails if the pinned snapshot does
  not authorize the substrate or if the substrate is older than
  `NCZ_SUBSTRATE_MAX_AGE_DAYS` (default 8).
* **Publish rule** — the archive stage copies to the ARGONAS image store only
  when the KVM gate and the provenance gate both PASSed **in this run**, and
  never when `--no-publish`. A respin is gated exactly like a full build.

---

## 7. Artifacts, retention, cleanup

* **Images** live on ARGONAS: `/mnt/datapool/projects/ncz-os-assets/images/`
  (ULTRA spelling `/mnt/argonas-projects/ncz-os-assets/images/`). The build only
  ever **adds** a candidate; it never reaps.
* **Retention** (enforced by the operator/runbook, not the build): keep the last
  operator-validated image per arch **plus** the in-flight candidate. Reaping is
  `reap-images.sh` (dry-run by default) and is operator-only.
* **Substrate cache**: `/mnt/datapool/projects/ncz-os-assets/substrate/` — keep
  the last two per arch; managed by `refresh-substrate.sh`.
* **Run dirs**: `~/Projects/ncz-build-runs/<arch>-<date>-<sha>/` — logs and run
  metadata kept; `tmp/` and the KVM work dirs are removed on success (or with
  `--clean`); `--keep-work` retains them. The reaper policy
  (`~/.claude/rules/scratch-and-cleanup.md`) applies: no build cruft on tmpfs,
  no stale qcow2/img left behind.

---

## 8. What the build is NEVER allowed to do

Tag, `ship-image`, flash/reboot a test host, `reap-apply`, or touch a live
repo / R2 / Buildkite. Those are **operator-only**
([IMAGE-RELEASE-RUNBOOK.md](IMAGE-RELEASE-RUNBOOK.md)). The entrypoint never
runs them and never copies a failing image to ARGONAS.

---

## 9. Troubleshooting (drawn from the r202 process-validation notes)

| Symptom | Cause | Fix |
|---|---|---|
| `sudo: a password is required` / hand-rolled FIFO | old per-run privilege hack | use the entrypoint; `build/lib/priv.sh` reads the fleet key via `python3 -I` and feeds stdin (no FIFO) |
| gate falls back to TCG, 10–40× slower | `/dev/kvm` gid != the user's group | run the gate as root (the entrypoint does) or fix the device group |
| `assets/kernel/mainline` not visible / no KVER | ULTRA vs ARGONAS symlink spelling | preflight bind-mounts the alternate pool automatically |
| `make image` floats to the current netinst and refuses on sha | substrate cache not visible to the container | preflight pre-stages the pinned ISO into `downloads/` |
| reused `base.squashfs` misses a wallpaper/post-install fix | old base stamp gap | fixed: the fingerprint covers `assets/wallpaper/` and `post-install/` |
| untracked scratch trips `lint-platform` LINT-COVER | scratch inside the worktree | keep logs in the run dir (outside the tree); `.git/info/exclude` only as a last resort |
| Singularity payload rebuilds (~20 min) on a respin | payload rebuild is the default | a `--components`/`--respin` that does not touch `singularity` reuses the cached layer; to use a pinned prebuilt deb, set `NCZ_SINGULARITY_PREBUILT_DEB`+`_SHA256` (recorded in `base.pin`) |
| arm64 stage 1 behaves differently from stage 0/2 | stage 1 needs host mount/chroot | stage 1 always runs on the bare host; the entrypoint does this |
| provenance gate FAIL with many `orphan pool file` / `unknown origin` | NCZ ledger coverage or `/cdrom` re-index gap | see [FORKY-PROVENANCE.md](FORKY-PROVENANCE.md); populate the ledger rows, then re-run the gate (no rebuild needed) |
| provenance gate sees two kernel ABIs | substrate d-i udebs from a Debian kernel | one-kernel rule: filter them in the image writer; see [ONE-KERNEL.md](ONE-KERNEL.md) |
| `--respin` rebuilds everything | a global input (a `.sh`, `release.conf`, a manifest) changed, or no stamps present yet | expected on the first respin after a tooling change; inspect `--dry-run` layer plan |
| `TMPDIR must point at build-host local-disk scratch` | tmpfs | set `--run-dir` on a real disk (the entrypoint does) |
