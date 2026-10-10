# NCZ-OS nightly canary + weekly full build

Operator directive (2026-10-10): *"We should build everything that we depend on
including singularity from HEAD"* — nightly builds with refreshed inputs.

This document describes the automatic nightly **canary** (target ~1–3 h per arch,
unattended) and the **weekly full build**, their artifacts, the ledger-candidate
mechanism, and the systemd install instructions.

> **Nothing here is installed yet.**  The timer/service files ship in the repo;
> installing them is an operator decision.

## 1. What runs

Entry point: `build/nightly-canary.sh`.

```
build/nightly-canary.sh --arch amd64|arm64|both --mode nightly|weekly [--unattended]
```

### nightly stages

1. `preflight` — host, tools, registry.
2. `refresh-substrate` — refresh/verify the pinned Debian testing netinst
   (`build/refresh-substrate.sh`), which also re-derives the pinned forky
   snapshot (there is deliberately no fourth origin).
3. `resolve-heads` — resolve the current upstream HEAD of every source-buildable
   component (`build/refresh-singularity-sources.sh --sources latest`): the
   singularity-desktop superproject + every subproject, and the labwc
   SceneFX/wlroots/libsfdo compositor wraps.  The resolved commit SHAs are
   frozen in the run receipt.
4. `kernel-head-check` — resolve each NCZ kernel tree's HEAD and
   `git apply --check` **every carried patch** (no full kernel build).  Conflicts
   are reported, not fixed.  See `build/nightly/kernel-head-check.sh`.
5. `rebuild-components` — rebuild every source component from HEAD:
   the singularity payload (`build/build-singularity.sh` +
   `build/build-singularity-deb.sh`), wallpapers, `ncz-apt-policy`, the NCZ
   libdrm set, the DKMS debs (cix-gpu-kmd / panthor / vpu), the debootstrap stub,
   and usb-recovery.  Components with no in-tree recipe (screensavers, the NPU
   DKMS) are recorded `SKIPPED(reason)` and their published/vendor versions are
   reported.
6. `ledger-candidates` — emit the run's `ledger-candidates.tsv` (see §3).
7. `provenance-inputs` — the pre-build provenance gate in **nightly** mode
   (`build/check-forky-provenance.sh --ledger-mode nightly --ledger-candidates …`).
8. `shader-gate` — the static SceneFX quoted-`#error` gate
   (`build/check-singularity-shaders.sh`).
9. `unit-tests` — the component suites that exist (best-effort).
10. `hw-smoke` — the four-host read-only hardware smoke (see
    `docs/TEST-HOSTS.md`); skipped on a busy/unreachable host with a clear
    status.
11. `status` — write `status/<date>.json`, `status/latest.json`,
    `status/last-green.json`, and on red `TRIAGE.md`.
12. `retention` — keep the last 3 nightly run dirs and the last 2 weekly.

### weekly stages

The nightly stages **plus** `weekly-image`:
`build/build-image.sh --arch both --full --sources latest --no-publish`
(new stage order: `provenance-inputs` before `layers`, `provenance-gate` before
`kvm-gate`) with every gate (KVM incl. the installer-UI check, provenance,
installer messages) and a determinism compare of the layers on one arch.

## 2. Artifacts (never published)

Outputs go to `$NCZ_NIGHTLY_ROOT/<YYYYMMDD>/{amd64,arm64}/` (production:
`/mnt/argonas/datapool/projects/ncz-os-assets/nightly/`), containing `debs/`,
`sha256`, `run-metadata.json` (every resolved upstream commit SHA + build env),
and `ledger-candidates.tsv`.  Images are produced **only** for a weekly run and
are **never** copied to `.../ncz-os-assets/images/`, tagged, or shipped.

The newest weekly that PASSED all gates is the **last-known-good candidate**; an
operator promotes it by hand.  Promotion is operator-only.

## 3. Ledger candidates

`manifests/ncz-packages.tsv` is a **reviewed** ledger: exact
`name/version/arch/sha256` + recipe + source revision.  A HEAD rebuild changes the
versions and bytes every night, so the nightly must not edit the reviewed ledger.
Instead:

* the run writes auto-generated rows, same schema plus resolved source SHAs and
  build-run id with `status=candidate`, to `ledger-candidates.tsv`;
* `build/check-forky-provenance.sh --ledger-mode nightly --ledger-candidates FILE`
  accepts a package from the reviewed ledger **or** from the current run's
  candidates **only when the sha256 of the bytes scanned matches** the candidate
  sha; release mode (the default) never reads candidates, so a candidate is an
  unknown package there (a hard failure);
* `build/promote-ledger-candidates.sh <run-id>` prints a diff and, with an
  explicit reviewer + `NCZ_PROMOTE_OPERATOR=1`, appends reviewed rows — it never
  runs automatically.

Tests: `build/test-provenance-ledger-candidates.sh` (classify both directions +
CLI contract) and `build/test-nightly-ledger-candidates.sh` (emitter +
promotion, including the wrong-sha and conflict cases).

## 4. Breakage handling

A red nightly is the point.  `status/<date>.json` records each stage's
result/time, the first failing component, and the suspect upstream commit range
since the last green run (the recorded SHAs of the two runs).  `status/latest.json`
rolls forward; `status/last-green.json` is the last all-green run.
`nightly/<date>/TRIAGE.md` carries the first failing stage's log tail.  There are
no outbound notifications; the orchestrator's hourly check reads
`status/latest.json`.

## 5. Scheduling (files only — NOT installed)

Files: `deploy/systemd/ncz-nightly-canary.{service,timer}` (daily ~02:30),
`deploy/systemd/ncz-nightly-weekly.service` + `ncz-nightly-weekly.timer`
(Sunday ~20:00), and per-host drop-ins under `deploy/systemd/dropins/`.

Install (operator-approved; run on each build host):

```sh
sudo install -d /etc/systemd/system/ncz-nightly-canary.service.d
sudo cp deploy/systemd/ncz-nightly-canary.service /etc/systemd/system/
sudo cp deploy/systemd/ncz-nightly-canary.timer  /etc/systemd/system/
sudo cp deploy/systemd/ncz-nightly-weekly.service /etc/systemd/system/
sudo cp deploy/systemd/ncz-nightly-weekly.timer   /etc/systemd/system/
# per host (ACHILLES=amd64, ULTRA=arm64):
sudo cp deploy/systemd/dropins/ncz-nightly-canary-achilles.conf \
        /etc/systemd/system/ncz-nightly-canary.service.d/10-host.conf
printf 'NCZ_NIGHTLY_ARCH=amd64\n' | sudo tee /etc/ncz-nightly.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now ncz-nightly-canary.timer ncz-nightly-weekly.timer
```

`--unattended` gives: no prompts, a lock so runs never overlap, refusal to start
if the disk is >70% full, a `ncz-scratch-reaper --check` at start and cleanup at
the end, strict per-stage timeouts, and nice/ionice.  Never tmpfs.

## 6. Running by hand

```sh
build/nightly-canary.sh --arch amd64 --mode nightly --dry-run     # plan
build/nightly-canary.sh --inventory                               # dependency table
build/nightly-canary.sh --arch amd64 --mode nightly --unattended
```

Do not run a nightly concurrently with a real image build: the canary locks and
also refuses when another build is active.
