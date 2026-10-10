# NCZ-OS image release runbook — OPERATOR ONLY

Everything in this file is **operator-only**. The build
(`build/build-image.sh`, see [IMAGE-BUILD-PROCESS.md](IMAGE-BUILD-PROCESS.md))
stops at a gated candidate in the ARGONAS image store. Tagging, shipping,
flashing, reaping and live-repo/R2/Buildkite changes are human decisions and are
never performed by the build or by an agent acting on its own.

## 0. Preconditions

- `build/build-image.sh --arch <a> --full` finished with
  `build-image <arch> COMPLETE`, and `<image>.gates.json` has
  `"all_required_passed": true` (KVM + provenance, which includes the
  installer-UI and one-kernel checks).
- The candidate is in `/mnt/datapool/projects/ncz-os-assets/images/` with its
  `.receipt.json`, `.gates.json` and `.sha256` sidecars.
- `reports/r203-buildproc-REPORT.md` and the determinism evidence under
  `reports/r203-determinism/` are present and consistent with the artifact sha.

## 1. Record the gate marker

```sh
build/reap-images.sh --mark-gated <image> --note "r203 <arch> KVM+provenance PASS"
```

This writes `<image>.gated`. Nothing is deleted.

## 2. Operator validation (hardware)

### 2.1 Mali (Sky1 / O6N) smoke — REQUIRED for an arm64 ship

The vendor-Mali default entry is the one the SceneFX/libmali regression broke
(black screen). Before shipping an arm64 payload, run the hardware smoke on a
Sky1 Mali board (O6N, `sky1.gpu=vendor`) with the shaders of the *built* payload:

```sh
# generate the payload's formatted SceneFX shaders (on the arm64 build host)
python3 assets/singularity/scenefx-smoke/make_shaders.py \
    <labwc-build-tree>/subprojects/scenefx $HOME/Projects/shaders   # or a checkout + patch
# copy assets/singularity/scenefx-smoke/ + the shaders to the board's user dir, then:
NCZ_SMOKE_SHADERS_DIR=$PWD/shaders bash run_probe.sh $PWD/shaders $PWD/out
# PASS: "[summary] programs=15 failures=0" on GL_RENDERER=Mali-G720-Immortalis
```

`programs=15 failures=0` is the acceptance line; `failures=8` (quad, quad_clip,
tex_*) means the SceneFX patch did not reach the build. The static gate
(`build/check-singularity-shaders.sh`) already runs in every payload build; the
hardware smoke proves the *driver* accepts the shaders. Record the deb sha256 and
the smoke line in `assets/singularity/MALI-VERIFIED.md`.

Flash the candidate to a test device and boot it (operator-only; the fleet
policy forbids unattended flash/reboot of test hosts). When satisfied:

```sh
build/reap-images.sh --mark-validated <image> --note "r203 <arch> operator-validated"
```

This writes `<image>.validated` — the known-good fallback.

## 3. Ship

```sh
NCZ_IMAGE_ARCHIVE=/mnt/argonas/datapool/projects/ncz-os-assets/images \
bash build/ship-image.sh <image> --gate-log <the KVM gate log>
```

`ship-image.sh` requires a gate log containing `GATE PASS (phase 1+2)`, copies
the image and sidecars, records the gate marker, and **shows** the reap plan by
default. It does not touch a live repo/R2/Buildkite.

## 4. Reap superseded images (dry run, then apply)

```sh
# inspect first
build/reap-images.sh --arch <arch> --archive /mnt/datapool/projects/ncz-os-assets/images \
    --dir <host-local image dir> [--remote HOST:DIR] [--workdir GLOB]
# then, only after reading the plan:
... --apply
```

Retention policy: keep the newest **gated** image per arch, the newest
**validated** image per arch, and any image newer than the newest gated one.
Everything else of that arch is reaped from every listed location, with a
sha256 entry in `<archive>/reap.log`. Never reap another arch; never reap the
only copy of anything.

## 5. Tag / announce

Tagging and the release announcement are operator actions outside this repo's
build. Do not let an agent do them.

## 6. Cleanup receipt

After a release, record what was kept and removed (image names + sha256, hosts
touched, disk freed) in the run's report. The build-policy cleanup rules
(`~/.claude/rules/scratch-and-cleanup.md`) apply to any scratch created during
validation.
