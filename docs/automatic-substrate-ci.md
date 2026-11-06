# Automatic substrate CI — design note

Status: design (not yet implemented). Branch `hv/ncz-lt-substrate-20261106`.
Order: OPERATOR ORDER 2026-11-06T02:45Z, item 2 ("design and build the AUTOMATIC process ... deliver
the design note first (docs), then the pipeline + tests").

## 1. What this automates, and what it may not do

The substrate is the set of pins every NCZ image is built from: the Debian `forky` snapshot, the
kernel and firmware inputs, mesa, the wayland/labwc stack, GTK, pipewire, our own apt-repo packages,
and Singularity desktop. Today that set moves by hand, and moving it by hand is where the errors have
come from: a pin that silently drops a quarter of the archive, a substrate that goes stale until no
preflight will pass, a dependency bump that nobody notices is one major version ahead.

The CI job's job is narrow and mechanical:

1. **resolve** candidate pins on a schedule,
2. **prove** every candidate is actually authorized by the archived snapshot (measured, not assumed),
3. **build** both arches through the existing gate suite,
4. **decide**: auto-merge only inside a small, configured delta with every gate green — otherwise open
   a merge request for a human,
5. **warn** before a pin expires,
6. **retain** exactly one validated pin plus one in-flight candidate.

It may never: weaken a coverage/verification gate, raise `NCZ_SUBSTRATE_MAX_AGE_DAYS` to hide a stale
pin, publish anything to a public forge, or merge on data it could not verify.

## 2. The failure modes this design is built around

These are not hypotheticals — all five were found in the field on 2026-11-06 while moving one pin.

| # | Failure | What it looks like | Invariant the CI must enforce |
|---|---|---|---|
| F1 | **Silent empty scoring** | the snapshot serves 0 bytes for an index; the tool scores "component absent" and reports a fake 63.5 % — or worse, a fake 100 % on a partial index | 404 means "absent"; anything else is retried then marked UNVERIFIABLE; **no candidate is scored from a partial index** |
| F2 | **Partial-success pin** | a candidate hits 100 % early, then a later flaky candidate trips the breaker and the good pin is discarded | keep the first **verified** 100 %; fail-closed only when *no* candidate verifies |
| F3 | **Silent candidate-set shrinkage** | the monthly archive-run listing fails once, no retry; the candidate set falls back to the grid and the two arches pin **different** snapshots | retry the listing; on fallback emit a WARNING; **enforce one snapshot for both arches** by measuring the other arch's pin against this substrate and adopting it only if ≥ min-coverage |
| F4 | **Unfetchable package objects** | `pool/*.deb` answer 503/504 while indices serve; `debootstrap` fetches each package exactly once, so every whole-run retry restarts from zero and can never converge | asset builds treat mirror degradation as retryable **per file** (warm cache), never as "build failed, try again tomorrow" |
| F5 | **Pin divergence drift** | `release.conf` carries one snapshot but `base.pin` has two rows; a tool that writes one row without the other leaves an unbuildable tree | the pin move is **transactional across all four files** (`base.pin`, `release.conf`, `forky-snapshot.tsv`, `determinism.pin`); partial writes abort |

## 3. Pipeline topology

Scheduled pipeline (GitLab CI canonical, runner on our build hosts — HYDRA amd64, ULTRA arm64),
never on a machine that is also doing interactive work. One build per host, busy marker
`~/.config/hive-worker/busy.d/ncz-ci-<run>`, released in an `after_script` that also clears any
half-mounted chroot.

```
 stage 0  preflight      snapshot health probe + pin age + tool self-test
 stage 1  resolve        candidate pins for every subsystem (parallel, read-only)
 stage 2  prove          coverage measurement per arch; cross-arch consistency
 stage 3  propose        branch + changelog + machine-readable delta report
 stage 4  build:amd64    rootfs + image on HYDRA, full gate suite
 stage 5  build:arm64    rootfs + image on ULTRA, full gate suite
 stage 6  gate           aggregate: KVM boot gate, static gates, modversions, driver binding
 stage 7  decide         auto-merge within delta, else MR; alert on expiry
 stage 8  retain         prune to last-validated + in-flight
```

Stages 4 and 5 are the only long ones (tens of minutes each) and are the only ones that touch a
build host's CPU. Everything before stage 3 runs in a couple of minutes and is safe to run hourly.

## 4. Stage detail

### 0. Preflight — refuse to work on a sick mirror

Probe a fixed, small set of objects **before** any resolution: `dists/forky/Release`,
`dists/forky/InRelease`, and three known `.deb` paths from the current pin (one per component). Each
probe records status, bytes and latency.

- any probe non-200 after retries (`0/5/15 s`, matching `derive-base-pin.py`) → **exit 0 with
  `substrate-ci: mirror degraded`**, no branch, no pin motion, one alert. A degraded mirror is not a
  failing pipeline; a pipeline that pings the whole fleet because Debian is having a bad morning is
  noise.
- `pin_age >= NCZ_BASE_MIRROR_SNAPSHOT_MAX_AGE_DAYS - 3` → warn; `>= MAX_AGE` → fail loudly, because
  that is the state where every build refuses to start.
- tool self-test: run the deriver's unit tests (`test-derive-base-pin-candidates.sh`) and the
  `*-freshness-gate` tests. A broken tool must not be allowed to propose a pin.

### 1. Resolve — one resolver per subsystem, all read-only

| subsystem | resolver | notes |
|---|---|---|
| Debian forky | `build/derive-base-pin.py` (candidate grid + archive-run listing + persistent index cache) | must run against a **freshly fetched** netinst; the ISO identity is the substrate identity |
| kernel / firmware inputs | `resolve-sky1-kernel-inputs.sh`, `check-kernel-deb-pin.sh` | pin is `manifests/*.pin` + `determinism.pin` |
| mesa, labwc/wlroots, GTK, pipewire | `NCZ_LIBDRM_NCZ_REV`, `NCZ_DKMS_DEB_REV` and the runtime mirror pins in `release.conf` | resolved from our apt repo, not from upstream git |
| Singularity desktop | upstream `singularityos-lab` main/releases via `build/singularity-pins.sh propose` | **read that repo's `AGENTS.md` first**; attribution rules apply; never bump a submodule pointer without the patch queue re-check |
| our own debs | `check-ncz-repo-policy.sh` + repo index | policy gate decides what may enter |

Every resolver writes to a scratch dir, prints `name old -> new` plus the evidence URL, and never
mutates the tree.

### 2. Prove — measurement, not assumption

For each candidate Debian snapshot: measure the **actual netinst package closure** coverage exactly as
`derive-base-pin.py` does, both arches, and require `>= NCZ_SUBSTRATE_MIN_COVERAGE` (99 %). Additionally:

- **cross-arch**: after each arch's scan, measure the *other* arch's pinned snapshot against this
  substrate and adopt only if ≥ min-coverage (F3). Both rows must end on one timestamp.
- **no partial-index scoring** (F1): a candidate whose index fetch failed is UNVERIFIABLE, never 0 %.
- **keep the first verified 100 %** (F2): the grid scan is ascending, so the earliest verified maximum
  is provably the full scan's answer.
- **record the digests**: `pin-snapshot-suites.py` writes the signed InRelease digest and size; the
  CI fetches these **independently from both hosts** and requires byte-identical results before a pin
  is considered proven (F5). Two hosts, two fetches, `cmp`.

### 3. Propose — branch + changelog + delta report

Branch `hv/ncz-lt-substrate-<YYYYMMDD>-ci`. One commit per subsystem so a revert is surgical, plus a
generated `docs/substrate-changelog-<date>.md`: for every pin moved, `name old -> new`, package count
delta, added/removed package names (capped at 50 with a count), and the evidence URL. A machine
readable `runs/substrate-delta-<date>.json` feeds stage 7.

### 4-6. Build and gate — the existing suite, unchanged

amd64 on HYDRA, arm64 on ULTRA, in parallel, one build per host. Gates are the ones that exist today;
the CI **calls** them and may not skip one:

- `check-substrate-pin.sh`, `check-forky-provenance.sh`, `preflight-freshness-gate.sh`
- `kvm-kernel-gate.sh`, `kvm-install-gate-gpt.sh` (KVM boot gate), `kvm-installer-ui-check.sh`
- `dkms-abi-gate.sh` (modversions), driver-binding checks, `lint-hook-arch-gates.sh`
- `check-ssplugin-abi.sh`, `check-singularity-shaders.sh`, `check-installed-apt-config.sh`
- `secret-scan-gate.sh` (mandatory before any outward step)
- rootfs artifact checks (zstd integrity, entry count, 0 unsafe/0 duplicate paths, required binaries,
  no host keys, no machine-id)

A gate that is *skipped* is reported as failed, not as passed.

### 7. Decide — the only stage allowed to merge

Auto-merge requires **all** of:

1. every gate green on **both** arches, from the same tree;
2. both `base.pin` rows on one snapshot with measured coverage ≥ min-coverage, digests identical from
   two hosts;
3. delta within configured bounds (below);
4. no package **removals** and no new non-forky (sid) exception;
5. `secret-scan-gate.sh` clean;
6. the delta report attached to the merge.

Delta bounds (config, defaults chosen so today's routine moves pass and surprises do not):

| knob | default | meaning |
|---|---|---|
| `NCZ_CI_MAX_PKG_DELTA` | 150 | binary packages that may appear/disappear in one move |
| `NCZ_CI_MAX_MAJOR_BUMP` | 0 | any package whose upstream major version changes → review |
| `NCZ_CI_REQUIRE_EMPTY_REMOVALS` | true | one removed package → review |
| `NCZ_CI_AUTOMERGE` | false until the first ten green runs | hard off-switch |
| `NCZ_CI_MIN_COVERAGE` | 99 | never lowered without an orchestrator call |

Anything outside those bounds produces a **merge request** with the changelog, the delta report, the
gate log and the two-host digest evidence. The default posture is "open an MR"; auto-merge is a
privilege earned per subsystem.

### 8. Retain and alert

- Keep the last **validated** pin's artifacts plus at most one in-flight candidate branch; prune
  everything else (build chroots, caches older than N days, superseded branches). The debootstrap and
  substrate caches are kept — they are what makes a degraded mirror survivable.
- Alerts at `MAX_AGE - 4` days (warning) and `MAX_AGE - 1` day (urgent), including the exact resolver
  failure if resolution is blocked, so "pin is old" is never reported without the reason.
- Outward pushes (GitHub, public forge) are **never** automatic. The CI stops at a local/ARGONAS
  branch plus a merge candidate for the orchestrator.

## 5. Test plan

The tests are the deliverable that makes the invariants real. Pattern follows the existing
`build/test-*.sh` scripts; a fake snapshot server provides fault injection, so no test needs the
network.

| test | injects | asserts |
|---|---|---|
| `test-ci-preflight-degraded` | 503/504 on pool probes | exits 0 with "mirror degraded", opens no branch, one alert |
| `test-ci-partial-index` | index truncated mid-body | candidate scored UNVERIFIABLE, never 0 %, pin untouched |
| `test-ci-listing-failure` | archive-run listing 503 | WARNING emitted, candidate set = grid only, cross-arch adoption used, both rows agree |
| `test-ci-breaker-keeps-verified-pin` | flaky candidates after a verified 100 % | pin keeps the verified candidate; no revert |
| `test-ci-cross-arch-divergence` | amd64 100 % at T1, arm64 pin at T2 | CI refuses to propose two rows; adopts T1 only if measured ≥ min-coverage |
| `test-ci-transactional-pin` | disk full / write error between files | no partial pin state; tree either fully moved or untouched |
| `test-ci-delta-bounds` | synthetic delta 151 pkgs / one major bump / one removal | each routes to MR, never auto-merge |
| `test-ci-gate-skip` | a gate exits non-zero | result is FAILED, not skipped-as-pass |
| `test-ci-secret-scan` | seeded token in the diff | no outward step; MR marked blocked |
| `test-ci-retention` | three old branches + one candidate | only last-validated + candidate survive |

## 6. Rollout

1. Stage 0-3 only, schedule daily, `NCZ_CI_AUTOMERGE=false` — read-only proposal pipeline; it will
   produce MRs but never merge. Two weeks of clean proposals is the evidence needed to consider
   auto-merge.
2. Add stages 4-6 (builds + gates) once the rootfs assets are stable enough that a red build means a
   real regression rather than mirror noise.
3. Enable auto-merge **per subsystem**, starting with Debian forky, only after ten consecutive green
   runs.
4. Singularity desktop last: its patch queue (currently 22 patches needing port) must be green in CI
   before its pins are allowed to move automatically.

## 7. Open questions for the orchestrator

1. **Runner placement**: GitLab CI on HYDRA/ULTRA as today's build hosts, or a dedicated runner?
   (My default: reuse, one build per host, busy markers — no new hardware.)
2. **Scheduling**: daily resolution, weekly full build? (Default: resolve daily, build on change only,
   full build weekly even if pins did not move — that is the drift detector.)
3. **Auto-merge authority**: is "both arches green + inside delta + secret scan clean" enough to merge
   into the substrate branch without a human, or should the first ten merges still be reviewed by the
   named non-DeepSeek reviewer?
4. **Where the pin move lands**: `hv/ncz-lt-substrate-<date>` (my current convention) or a stable
   `substrate/auto` branch the CI writes to?
