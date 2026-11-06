# BUILD-RUNBOOK.md -- operator rules for NCZ-OS image builds

Status: M12 of [BUILD-STABILITY.md](BUILD-STABILITY.md).  One rule per failure
class C1-C9.  Each rule names the **check that enforces it**, **where it fails**
(which stage or command), and the **override** (diagnostics with `--no-publish`
only).

Scope: `build/build-image.sh` and the scripts it calls, on the Preview4 branch
(`release/preview4-20261025`).  The measures referenced as `M<n>` are the
preventive measures in BUILD-STABILITY.md section 3.

**Every command in this document was checked against the scripts on this
branch.**  A command that names a script which does not exist yet is marked
**PENDING** with the measure that owns it, and is not to be run by hand: the
rule is real, its enforcement is not, and the runbook says so.

**Nothing in this document invents a version or a hash.**  Where a value
belongs to the operator (which snapshot, which kernel revision, which tarball
bytes), it points at [BUILD-DECISIONS-NEEDED.md](BUILD-DECISIONS-NEEDED.md) or
at the committed pin files instead of naming one.

---

## 0. The shape of a build

```
build/build-image.sh --arch amd64|arm64 [SCOPE] [OPTIONS]
```

The stages run in this fixed order (`build/build-image.sh:441`):

| # | stage | what it does |
|---|-------|--------------|
| 00 | `preflight` | host, disk, tmpfs, tools, privilege, pins, substrate age, repo pin coherence |
| 10 | `refresh-substrate` | restore or refresh the pinned substrate ISO |
| 20 | `stage-inputs` | stage the checksum-pinned gitignored build inputs |
| 30 | `refresh-sources` | resolve + freeze the Singularity payload sources |
| 40 | `offline-mirror` | build the offline apt closure |
| 50 | `provenance-inputs` | provenance + one-kernel check on the **inputs** (fail fast) |
| 55 | `static-gates` | mandatory static gate suites |
| 60 | `layers` | build the squashfs layers |
| 70 | `image` | assemble the raw GPT image + receipt |
| 75 | `secret-scan` | scan every shipped byte for credentials (mandatory) |
| 80 | `provenance-gate` | forky provenance + one-kernel over the finished image |
| 90 | `kvm-gate` | install + boot the image in KVM + installer UI check |
| 95 | `receipt` | run metadata + gate summary |
| 99 | `archive` | copy to the image archive **only** if every gate passed |

Two flags decide whether a run may publish:

- `--no-publish` -- build and run the gates, never copy to the image archive
  (`build/build-image.sh:229`, stage `archive` at `build/build-image.sh:2002`).
  It is the **only** override this runbook grants.
- `--gates kvm,provenance` -- run only these gates.  It **requires**
  `--no-publish`; the combination is refused otherwise
  (`build/build-image.sh:311`).

### The override rule

> **The only override is a diagnostic run with `--no-publish`.**
> A diagnostic run may proceed past a rule that is enforced by a *host*
> precondition (C2, C6, C9).  It may **never** proceed past a rule that
> protects the **bytes of the image** (C1, C3, C5, C7, C8): those are hard
> failures of the provenance and pin gates, and `--no-publish` does not relax
> them.
>
> A diagnostic run never produces a shippable artifact: the `archive` stage
> is skipped, so the image never reaches `~/.config/ncz/image-archive-dir`
> (`build/build-image.sh:2058`).

---

## C1 -- pin/ledger drift on re-pin

> **Rule C1.** A re-pin is **one commit that touches both arches**.  Never
> change `manifests/base.pin` for one arch only, and never let a builder
> rewrite a committed pin file.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| repo pin coherence (M3) | `build/check-pin-coherence.sh --root . --arch amd64` and `--arch arm64` | rule `snapshot`: `manifests/base.pin` amd64 vs arm64 vs `release.conf` `NCZ_BASE_MIRROR_SNAPSHOT` vs `manifests/forky-snapshot.tsv` vs `manifests/determinism.pin`; rule `sid-exceptions`: a ledger row reviewed at a different snapshot |
| base pin freshness | `build/check-substrate-pin.sh <arch>` | the pinned snapshot is older than `NCZ_SUBSTRATE_MAX_AGE_DAYS` (default 8), or `release.conf` and `manifests/base.pin` disagree |
| determinism pin | `build/gen-base-pin.sh --check` | `manifests/determinism.pin` no longer matches the authoritative pins |
| substrate coverage | `build/refresh-substrate.sh --arch <arch>` (exit 3) | the derived snapshot authorizes less than `NCZ_SUBSTRATE_MIN_COVERAGE` (default 99) of the substrate |

All four run in stage `preflight` (`build/build-image.sh:745-784`).  The
pin-coherence rules are decided by `build/lib/pin-coherence-gate.sh`: a rule
listed in `manifests/pin-coherence-known-fail.tsv` is a loud **WARN** that names
its owner and its exact fix and does **not** abort; any other failure, a
checker error, or a malformed known-fail list **aborts** the build.

**The re-pin itself.**  `build/repin.sh` is **PENDING (M2)** -- it does not
exist on this branch.  Until it lands, the only safe re-pin is the manual
sequence, and it must be done on **one** host, for **both** arches, in **one**
commit:

1. `build/refresh-substrate.sh --arch amd64` and then
   `build/refresh-substrate.sh --arch arm64`.  Both must derive the **same**
   snapshot; if they do not, stop and do not commit.
2. `build/classify-sid-exceptions.py --arch <arch> --iso <iso> --snapshot <snapshot> --scratch <dir> --ledger manifests/sid-exceptions.tsv --tsv-out <new-ledger>`
   for both arches, and review every new or changed row by hand.  The
   provenance gate authorizes a sid d-i package **only** for an exact
   `(name, version, arch, sha256)` row in `manifests/sid-exceptions.tsv`.
3. `build/gen-base-pin.sh` -- a failure here is fatal, never a warning.
4. `build/refresh-forky-inrelease-fixture.sh --check` -- the pinned-InRelease
   fixture is generated from the pin, never hand-edited.
5. `bash build/test-no-ubuntu.sh`, `bash build/test-build-image.sh`,
   `bash build/test-pin-coherence.sh`.
6. Commit **all** of the changed pin files together.

**Where it fails.**  Stage `preflight` (rule `snapshot` / `sid-exceptions`),
stage `refresh-substrate` (coverage exit 3), stage `provenance-inputs` (a
graduated or unlisted udeb), stage `provenance-gate` (`/cdrom pool is not fully
authorized`).

**Override.**  None for the bytes.  `--no-publish` does not relax the
provenance gate.  A **listed** known failure in
`manifests/pin-coherence-known-fail.tsv` continues by design -- but that list
is the operator's decision, not a workaround: see
[BUILD-DECISIONS-NEEDED.md](BUILD-DECISIONS-NEEDED.md).

---

## C2 -- per-host input drift

> **Rule C2.** The builder host must already hold every input this commit
> names.  Never hand-copy a `.deb` into a build tree; refresh the shared pool
> and re-stage from it.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| kernel staging visible | `build/link-kernel-mainline.sh --check` | the staging pool is not mounted, or `assets/kernel/mainline.release` names a release the pool does not hold |
| kernel revision + sha256 (M7) | `build/check-kernel-deb-pin.sh --manifest assets/kernel-manifest.json assets/kernel/mainline/KVER build/kernel-debs` | a staged Sky1 deb's full `Version` (`7.3.0-sky1-ncz+rNNN`, `1.6+rNNN`) or sha256 differs from `assets/kernel-manifest.json`; the set is incomplete; the manifest is missing or malformed |
| packaging revision | `build/build-kernel-debs.sh --print-build-rev` | prints the revision the tree would build; it must equal `assets/kernel/mainline.deb-revision` |
| build-inputs store | `build/stage-build-inputs.sh --arch <arch> --check` | a row of `manifests/build-inputs.tsv` is missing from the store, or its sha256 differs from the pin |
| substrate cache | `build/stage-substrate.sh --arch <arch> --check` | the pinned ISO is not in `downloads/`, or its sha256 differs from `manifests/base.pin` |
| one-kernel input rule | `build/verify-no-debian-kernel.sh --root build/forky-mirror/pool --arch <arch> --quiet` | a Debian kernel/modules package is in the offline pool |
| amd64 installer kernel | `build/stage-amd64-kernel.sh` | the shared pool holds no build matching `assets/kernel/amd64-stable/KVER` |

The kernel-pin check runs in the `kernel-debs` Make target
(`Makefile:347`) and again in `build/build-vendor-mirror.sh:100` and
`build/build-vendor-mirror.sh:174`, before anything is published.  The
staging checks run in stage `stage-inputs` (`build/build-image.sh:937`) and the
substrate check in stage `preflight` / `refresh-substrate`.

**The correct way to update the kernel pool.**  Publish into the shared pool
with `build/publish-amd64-kernel.sh default <deb-dir>` (amd64) or
`build/release-kernel.sh` (arm64), then re-stage.  Never `cp` a `.deb` from
an old build directory into `assets/`, `build/kernel-debs/` or the staging
pool: that is what put r292 debs under an r293 manifest on 2026-10-29.

`build/host-ready.sh` is **PENDING (M5)** -- it does not exist on this branch.
It would collect the staging, cache, inputs, privilege, KVM, disk, uid-0,
clean-tree and stdout-location checks above into one command that runs before
any stage.  Until it lands, run the individual commands in this section
yourself before every build.

**Where it fails.**  Stage `preflight` (kernel staging not visible, KVER not
resolvable), stage `stage-inputs` (a missing or mismatched build input), stage
`offline-mirror` (the kernel pin), stage `provenance-inputs` (a deb that the
ledger does not authorize).

**Override.**  `--no-publish` only, and only to diagnose: a diagnostic run may
proceed with a host that is missing an input so that the *builder* problem can
be observed.  It may not be used to ship.  `--offline` additionally forces
the substrate check to fail closed at stage `preflight`
(`build/build-image.sh:835`).

---

## C3 -- late provenance

> **Rule C3.** Every byte that will enter the image is authorized **before**
> the long stages.  A defect found at stage `provenance-gate` means an
> earlier check did not cover that input -- fix the check, not the image.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| provenance over the inputs (stage 50) | `build/check-forky-provenance.sh --debs <dir> --index-dir <dir> [--receipt <file>]` | a staged `.deb`/`.udeb` has an origin that is neither NCZ, a reviewed vendor deb, nor byte-identical to the pinned snapshot |
| one-kernel input rule | `build/verify-no-debian-kernel.sh --root build/forky-mirror/pool --arch <arch> --quiet` | as C2 |
| SceneFX shader gate | `build/check-singularity-shaders.sh` | the staged payload deb carries an unusable shader |
| final image gate (stage 80) | `build/check-forky-provenance.sh --image <img> --work <dir> --index-dir <dir>` | any package in the finished image is unauthorized |

Stage `provenance-inputs` (`build/build-image.sh:1020`) runs **after** the
offline mirror and **before** any layer work, and reports every finding at
once.  Stage `provenance-gate` (`build/build-image.sh:1853`) repeats the check
over the finished image.

`build/check-inputs-provenance.sh` is **PENDING (M1)** -- it does not exist on
this branch.  It would scan the inputs that stage 50 does not yet cover
(`assets/screensaver/*/*.deb`, `assets/mgmt/ncz-mgmt-rootfs.tar.zst`,
`assets/rescue/rescue-rootfs-<arch>.tar.zst`, and the substrate ISO's `/cdrom`
pool and initrd status) as a new stage 25, before the 13-minute mirror.  Until
it lands, a `provenance-gate` finding about a rootfs tarball, a screensaver
deb or a substrate udeb is expected, and the fix is to correct the input and
re-run.

**Where it fails.**  Stage `provenance-inputs` (rc 1), stage
`provenance-gate` (rc 1), stage `static-gates` (the shader gate).

**Override.**  None.  `--no-publish` does not relax a provenance finding: the
`provenance-gate` result file must read `result=PASS` before the archive stage
will copy the image (`build/build-image.sh:2013`).

---

## C4 -- tests with hard-coded pins

> **Rule C4.** A re-pin never edits a test file.  Tests read the pin from
> `release.conf` at run time; fixtures use their own synthetic snapshot id.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| pin-literal lint (M4) | `bash build/test-no-pin-literals.sh` | the value of `NCZ_BASE_MIRROR_SNAPSHOT` from `release.conf` appears literally in any `build/test-*.sh` or in any file under `build/testdata/` |
| fixture generator (M4) | `build/refresh-forky-inrelease-fixture.sh --check` | the committed `build/testdata/forky-snapshot/InRelease` no longer matches the pin's `inrelease_sha256` / `inrelease_size`, or `gpgv` does not report `VALIDSIG` |
| pin coherence (M3) | `build/check-pin-coherence.sh --root .` | see C1 |
| the suites themselves | `bash build/test-no-ubuntu.sh` | a snapshot literal, the fixture `InRelease`, or a ledger row disagrees with the pin |

The lint is part of the `parity` target (`Makefile:831`).  The pin is read
with `ncz_pin_snapshot` from `build/lib/mirror-apt-opts.sh`, never copied.

**Where it fails.**  The pre-commit test run, before any build stage.

**Override.**  None.  A test that needs a *different* snapshot must use a
synthetic one (the pattern `build/test-pin-coherence.sh` uses: `S=20300101T000000Z`).

---

## C5 -- stale intermediate artifacts

> **Rule C5.** A prebuilt input is bound to the snapshot it was built from.
> An input built at an older snapshot must be rebuilt, not reused.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| rootfs snapshot binding (M8) | `build/check-pin-coherence.sh --root . --arch <arch>` | rule `rootfs-inputs`: a `manifests/build-inputs.tsv` rootfs row records a build snapshot other than the pin |
| build-inputs pin | `build/stage-build-inputs.sh --arch <arch> --check` | a staged input's sha256 differs from the pin |
| kernel revision (M7) | `build/check-kernel-deb-pin.sh --manifest assets/kernel-manifest.json assets/kernel/mainline/KVER build/kernel-debs` | a reused kernel deb carries the wrong `+rNNN` revision or sha256 |
| stale run scratch | `build/layers-preflight.sh --arch <arch> --root . --run-dir <run-dir> --quarantine` | leftover scratch from an earlier run under the run dir; with `--quarantine` it is moved aside, otherwise the stage fails |
| offline-mirror fingerprint | stage `offline-mirror` records `build/forky-mirror.build-fingerprint` | the mirror is reused only when the fingerprint (release.conf + snapshot + package manifests) is unchanged |

The rootfs tarballs are **not** byte-reproducible
([SOURCE-RELEASES.md](SOURCE-RELEASES.md)), so their hashes cannot be
re-derived: they have to come from the real files.  See
[BUILD-DECISIONS-NEEDED.md](BUILD-DECISIONS-NEEDED.md) section 1 for the
open amd64/arm64 decision.

**Where it fails.**  Stage `preflight` (rule `rootfs-inputs`, a WARN today
because it is a listed known failure), stage `stage-inputs`, stage
`offline-mirror`, stage `layers` (the stale-scratch check).

**Override.**  `--no-publish` only, to diagnose which input is stale.  A
stale input must never be published.

---

## C6 -- env/permission debris

> **Rule C6.** No stage leaves a root-owned file under the clone or the run
> directory, and the build's own stdout never lands inside the clone.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| privilege model | stage `preflight` (`build/build-image.sh:723`) | no usable privilege model: neither root, nor `sudo` without a password, nor the stdin-only model from `build/lib/priv.sh` |
| scratch filesystem | stage `preflight` (`build/build-image.sh:733`) | the run dir is on `tmpfs` or `ramfs` |
| chown-back trap | `build/lib/priv.sh` (`ncz_trap_chown_back`) | the privileged gates hand their scratch back to the invoking user on every exit path; the regression test is `bash build/test-gate-chown-back.sh` |
| run-dir tmpfs check | `build/layers-preflight.sh --arch <arch> --root . --run-dir <run-dir>` | the run dir is on a tmpfs |

`find "$ROOT" -xdev -uid 0 -print -quit` is the operator's own check for
C6's residue.  The uid-0 audit **after every stage** is **PENDING (M10)** --
`build/build-image.sh` does not run it yet.  The stdout-location check
(`readlink /proc/$$/fd/1` must not resolve under the clone) is **PENDING
(M5, item 9)**.

**Where it fails.**  Today: after the build, by the operator, when
`rm`/`chown` on the clone fails.  The stage-level failures are the privilege
and tmpfs checks above.

**Override.**  `--no-publish` only.  There is no flag that lets a build write
root-owned files into the clone and still publish.

---

## C7 -- operator-procedure mistakes

> **Rule C7.** The operator changes nothing inside the clone during a build.
> Every fix is committed first; the build records the commit it ran from.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| clean tree | stage `preflight` (`build/build-image.sh:738`) | **WARN only today**: "git tree is not clean; the artifact will record git=..." |
| resume discipline | the `--resume-from` command printed by the aborting stage (`build/build-image.sh:2151`) | a resume is only valid after the fix is committed |
| no LAN URLs | `bash build/test-no-lan-urls.sh` (mandatory in stage `static-gates`, `build/build-image.sh:1324`) | a payload pin or a shipped script carries a LAN URL |
| per-host settings | the `~/.config/ncz/*-dir` files, read by `build/lib/ncz-site.sh` | a setting is missing or wrong for this host |

The clean-tree check is a **WARN**, not a FAIL, on this branch.  Making it a
FAIL for publishable builds is **PENDING (M5, item 8)**: a diagnostic run with
`--no-publish` keeps the warning and may proceed.

**The rules that are not yet mechanically enforced.**

- **Never redirect build output into the clone.**  Write it to
  `~/Projects/<run>.out` or to a run dir outside the checkout.  The check that
  would enforce this is **PENDING (M5, item 9)**.
- **Never re-pin on a builder.**  A builder that runs
  `build/refresh-substrate.sh` rewrites `manifests/base.pin` in place, for one
  arch, on one host -- the R1 failure of 2026-10-29.  The script that would
  make this impossible is **PENDING (M2)**; until it lands, run the refresh
  only on the re-pin host, and check `git status --porcelain` afterwards.
- **Never hand-copy debs into a build tree.**  See C2.
- **Set `NCZ_SUBSTRATE_CACHE_DIRS` and `NCZ_BUILD_INPUTS_DIR` in
  `~/.config/ncz/substrate-cache-dir` and `~/.config/ncz/build-inputs-dir`,
  not in the interactive shell.**  A shell-only setting is lost the next
  session and the build silently uses the wrong (or no) store.  The
  resolution order is in `build/lib/ncz-site.sh`.
- **Resume only with the printed `--resume-from` command, and only after the
  fix is committed.**  A fix made in the clone without a commit makes the
  image record a `git=<sha>` of a tree that does not exist.

**Where it fails.**  Stage `preflight` (clean-tree warning), stage
`static-gates` (the LAN-URL suite), stage `provenance-inputs` (a deb that
entered the tree by hand), or at the archive stage (an image built from an
uncommitted tree).

**Override.**  `--no-publish` for the clean-tree warning and for a
diagnostic run made with an uncommitted change.  The LAN-URL rule has **no**
override: it is a hard rule with a mandatory suite.

---

## C8 -- network/mirror flakiness

> **Rule C8.** A build fetches from a pinned URL or from a warm cache, or it
> fails.  It never floats to whatever the network serves today.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| offline mode | `build/build-image.sh --arch <arch> --offline ...` | every network access is blocked (the proxy is pointed at `127.0.0.1:9`, `build/build-image.sh:2126`); the substrate must already be staged (`build/build-image.sh:835`, `build/build-image.sh:891`) |
| substrate restore | `build/stage-substrate.sh --arch <arch>` | the pinned ISO is not in the cache; the script names the cache directories it searched and never floats to a newer Debian ISO |
| substrate signature | `build/refresh-substrate.sh --arch <arch>` | `SHA256SUMS.sign` does not verify against the committed Debian CD signing key (`manifests/keys/debian-testing-cd-signing.gpg`, fingerprint asserted in the script); the script exits 2 |
| snapshot index | `build/forky-provenance.py --fetch-index` (via `build/check-forky-provenance.sh`) | the fetched index does not match the sha256 committed in `manifests/forky-snapshot.tsv` |

`build/test-no-live-mirror.sh` is **PENDING (M9)** -- it does not exist on
this branch.  It would fail the build when a build script contains
`deb.debian.org` outside the allowlisted defaults.  Until it lands, the known
live fetch is `build/build-installer-image.sh:108` and
`build/build-installer-image.sh:122`, which reach for
`deb.debian.org` when no cached `debootstrap-udeb` is present.  A build that
must not touch the live network uses `--offline`, or stages the udeb first.

**Where it fails.**  Stage `preflight` (`--offline` with a cold substrate),
stage `refresh-substrate` (signature or coverage failure), stage
`provenance-inputs` (the index does not match the committed sha256).

**Override.**  `--offline` is the tool, not an override: it turns a silent
network fetch into a named failure.  `--no-publish` may be used to run a
diagnostic build that is allowed to reach the network.

---

## C9 -- resource limits

> **Rule C9.** The build host has the disk, the filesystem and the privileges
> this commit needs, and the operator checks before the build starts.

**Enforced by**

| check | command | where it fails |
|-------|---------|----------------|
| layer-stage resources | `build/layers-preflight.sh --arch <arch> --root . --run-dir <run-dir>` | less than `NCZ_LAYERS_MIN_FREE_GB` (default 60) free on the run-dir filesystem, or the run dir is on a tmpfs |
| preflight disk | stage `preflight` (`build/build-image.sh:848`) | less than ~20 GiB free at the run dir |
| preflight scratch | stage `preflight` (`build/build-image.sh:733`) | the run dir is on `tmpfs` or `ramfs` |
| container image | stage `preflight` (`build/build-image.sh:793`) | the `ncz-imagebuild` container image is not present (`podman image exists`) |
| KVM | stage `preflight` (`build/build-image.sh:855`) | **WARN only today**: `/dev/kvm` is absent or not rw; the gate falls back to TCG |

`build/host-ready.sh` is **PENDING (M5)** -- it would collect the resource
checks (including the measured peak) into one pre-flight command.  Until it
lands, run `build/layers-preflight.sh` yourself before a long build.

**Where it fails.**  Stage `preflight` (disk, tmpfs, container image), stage
`layers` (`layers-preflight.sh` resources check).

**Override.**  `--no-publish` only, for a diagnostic run that needs less disk
or no KVM.  `--no-container` disables the containerized stages for a
diagnostic run; it never changes the bytes of a published image and it is not
allowed on a publishable build.

---

## Quick reference -- one command per class

| class | the command that enforces it |
|-------|------------------------------|
| C1 | `build/check-pin-coherence.sh --root . --arch amd64` |
| C2 | `build/stage-build-inputs.sh --arch <arch> --check` and `build/check-kernel-deb-pin.sh --manifest assets/kernel-manifest.json assets/kernel/mainline/KVER build/kernel-debs` |
| C3 | `build/check-forky-provenance.sh --debs <dir> --index-dir <dir>` |
| C4 | `bash build/test-no-pin-literals.sh` |
| C5 | `build/check-pin-coherence.sh --root . --arch <arch>` (rule `rootfs-inputs`) |
| C6 | `build/layers-preflight.sh --arch <arch> --root . --run-dir <run-dir>` |
| C7 | `bash build/test-no-lan-urls.sh` and `git status --porcelain` |
| C8 | `build/build-image.sh --arch <arch> --offline --no-publish ...` |
| C9 | `build/layers-preflight.sh --arch <arch> --root . --run-dir <run-dir>` (the `resources` check) |

---

## PENDING summary

Every script the runbook names that does not exist on this branch, with the
measure that owns it:

| script | measure | what it would enforce |
|--------|---------|----------------------|
| `build/repin.sh` | M2 | one all-or-nothing re-pin for both arches; `--substrate refresh` stops editing tracked files |
| `build/host-ready.sh` | M5 | the host-readiness checks before any stage runs |
| `build/check-inputs-provenance.sh` | M1 | the predictive provenance gate over every input (new stage 25) |
| `build/test-no-live-mirror.sh` | M9 | no live `deb.debian.org` fetch in a build script |
| `build/build-image.sh --rehearse` | M6 | the rehearsal mode (implies `--no-publish`) |
| uid-0 audit after every stage | M10 | no stage leaves a root-owned file under the clone |
| stdout-location check | M5 (item 9) | the build's stdout never resolves under the clone |
| clean tree as a FAIL | M5 (item 8) | a publishable build needs a clean tree |

`build/test-build-runbook.sh` is the regression test for this document: it
parses every script path the runbook names and fails when the path does not
exist and is not marked PENDING with a measure id.

---

## What could not be verified

- The **PENDING** measures are not on this branch, so their checks are
  described from BUILD-STABILITY.md, not from running code.  Each is marked
  so that nobody mistakes a planned check for an enforced one.
- `assets/kernel/mainline` is a build-local link that does not exist in a
  fresh clone, so `build/link-kernel-mainline.sh --check` and the
  `check-kernel-deb-pin.sh` command above cannot be exercised here without a
  mounted kernel-staging pool.  Their flags and exit codes were read from the
  scripts.
- The host half of C2 (what a specific build host actually holds) cannot be
  checked from this repository at all.
- The values a build depends on -- the current snapshot, the kernel packaging
  revision, the rootfs tarball hashes -- are operator decisions and are named
  in [BUILD-DECISIONS-NEEDED.md](BUILD-DECISIONS-NEEDED.md), not here.
