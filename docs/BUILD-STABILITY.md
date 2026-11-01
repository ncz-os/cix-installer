# BUILD-STABILITY.md -- why NCZ-OS image builds fail, and how to stop it

Status: design (STAB1 part 1). Nothing here is implemented yet. Part 2 implements
the measures in the order given in section 4.

Scope: `build/build-image.sh` and the scripts it calls, on the Preview4 branch
(`release/preview4-20261025`, HEAD `fb022bc5`), as exercised by the 2026-10-29
builds on HYDRA (amd64) and ULTRA (arm64).

Evidence used (paths relative to the evidence bundle given to this task):

| tag | file |
|-----|------|
| T  | `TODAYS-BUILD-FAILURES.md` (operator timeline, 8 items) |
| A1 | `amd64/ncz-p4-amd64-build-20261029.out` + `amd64/ncz-p4-amd64-run-20261029/logs/` |
| A2 | `amd64/ncz-p4b-amd64-build-20261029.out` + `amd64/ncz-p4b-amd64-run-20261029/logs/` |
| R1 | `arm64/ncz-p4-arm64-build-20261029.out` + `arm64/ncz-p4-arm64-run-20261029/logs/` |
| R2 | `arm64/ncz-p4b-arm64-build{,2,3}-20261029.out` + `arm64/ncz-p4b-arm64-run-20261029/logs/` |

Note: every line in the per-stage logs appears twice. Stage functions write
`... | tee -a "$log"`, and `run_stage()` (`build/build-image.sh:643`) pipes the
whole function through `tee -a "$log"` again. The line numbers below are the
real line numbers in the files, duplicates included.

---

## 1. Failure taxonomy

Wall-clock times come from the `OK`/`ERROR` stage lines in the `.out` files.
"Minutes wasted" means build time spent before the failure was reported, plus
the operator fix time that T records. The two do not add up exactly, because T
rounds.

| # | class | runs hit | minutes wasted |
|---|-------|----------|----------------|
| C1 | pin/ledger drift on re-pin | A1, A2 | ~20 + part of 28 |
| C2 | per-host input drift | R1, R2 | ~25 + "minutes" |
| C3 | late provenance (stage 80 finds input defects) | A2 | ~28 + fix work |
| C4 | tests with hard-coded pins | commit fb022bc5 | ~40 |
| C5 | stale intermediate artifacts | A2 (rootfs tarballs), R2 (kernel debs) | inside C2/C3 |
| C6 | env/permission debris | T item 6 | unquantified ("until sudo chown -R") |
| C7 | operator-procedure mistakes | T items 1, 4, 5 | inside C1/C2/C4 |
| C8 | network/mirror flakiness | A2 layers, A1/R1 substrate fetch | 0 failures today; 7 min of fetch per full run |
| C9 | resource limits | none observed today | 0 |

Total quantified loss on 2026-10-29: roughly 2 h of build and fix time, for zero
shippable images.

### C1 -- pin/ledger drift on re-pin

- **Evidence.**
  - A1 `05-provenance-inputs.log:4-7`:
    `FAIL [sid-exceptions] libaio1-udeb 0.3.113-10 amd64 :: GRADUATED: forky now provides 0.3.113-10`
    and `ledger row pinned to snapshot 20261018T082309Z != current pin 20261026T022331Z; regenerate the ledger on re-pin`
    (the same pair repeats for arm64).
  - A2 `10-provenance-gate.log:6-20`: `btrfs-progs-udeb 7.3-1`, `haveged-udeb 1.9.27-1` and
    `zlib1g-udeb 1:1.3.dfsg+really1.3.2-4` are "present in the pinned snapshot's sid
    debian-installer index but NOT in manifests/sid-exceptions.tsv". `/cdrom pool is not fully authorized`.
  - A2 `10-provenance-gate.log:111,151` (initrd-status): `haveged-udeb`, `nano-udeb 9.3-1`.
  - Commit `fb022bc5` removed the two graduated rows but added none for the new substrate's udebs.
- **Root cause.** A re-pin changes one input (the substrate ISO plus the snapshot) that
  several committed files depend on: `manifests/base.pin`, `release.conf`,
  `manifests/forky-snapshot.tsv`, `manifests/determinism.pin`,
  `manifests/sid-exceptions.tsv`, `build/testdata/forky-snapshot/InRelease`, the
  test literals, and the prebuilt rootfs tarballs in `manifests/build-inputs.tsv`.
  `build/refresh-substrate.sh` updates only the first four (section "4b", lines
  93-120). Even there, a `gen-base-pin.sh` failure is only a `WARN` (line 120).
  `build/classify-sid-exceptions.py`, which classifies exactly these substrate udebs
  against the pin (exit 3: "the pin does not authorize the substrate"), is not
  called by any pipeline script. It is referenced only from comments in
  `build/iso/*.py`.
- **Stage detected.** 50 provenance-inputs (A1, the libaio rows) and 80
  provenance-gate (A2, the new udebs).
- **Stage where it could have been detected.** At re-pin time, before commit. At
  the latest, stage 10 refresh-substrate, because the substrate ISO is already on
  disk there.
- **Minutes wasted.** A1: 22:24:45 to 22:42:43, about 18 minutes (T item 3 says
  ~20). A2's udeb half of the stage 80 failure is part of C3.

### C2 -- per-host input drift

- **Evidence.**
  - T item 2: on ULTRA, `NCZ_SUBSTRATE_CACHE_DIRS` was unset although the ISO existed
    under `~/ncz-assets/substrate`.
  - T item 5: "the manifest expects kernel debs r293 but ULTRA's
    ~/ncz-assets/kernel-staging only holds up to r292".
  - R2 `05-provenance-inputs.log:1-8`:
    `FAIL [mirror] cixmini-boot 1.6+r292 arm64 :: not authorized by the verified snapshot index or a reviewed vendor/NCZ/sid-exceptions ledger`,
    the same for `linux-headers-cixmini` and `linux-image-cixmini 7.3.0-sky1-ncz+r292`,
    followed by `orphan pool file` lines.
  - R2 `.out:95` and `ncz-p4b-arm64-build-20261029.out:167` show the r292 debs were
    built and then passed the kernel pin:
    `[kernel-debs] no debs present; building local kernel packages` and
    `[kernel-pin] OK: ... match the shipping kernel 7.3.0-sky1-ncz (7.3.0-sky1-ncz+r292)`.
- **Root cause.** This drift is partly in the repo, not only on the host.
  - Commits `100bd157` ("kernel-manifest: pin the r293 Sky1 debs") and `86f7fe82`
    ("ncz-packages: review rows for the r293 Sky1 kernel packages") moved
    `assets/kernel-manifest.json` and `manifests/ncz-packages.tsv:40-42` to r293.
  - `assets/kernel/mainline.release` still says `r292-7.3.0-sky1-ncz-20261023`.
    It was last changed by `33709095`.
  - `build/build-kernel-debs.sh:141` builds from the `mainline.release` directory,
    so it can only produce r292.
  - The kernel pin check compares the KVER (`7.3.0-sky1-ncz`) and ignores the
    `+rNNN` packaging revision, so it passes.
  - `ncz_resolve_kver()` (`build/build-image.sh:416`) also strips the revision.
  - Preflight logs the link as "(unchanged)" (A1 `00-preflight.log`: `kernel mainline link: ... r292-7.3.0-sky1-ncz-20261023 (unchanged)`)
    without comparing it with `kernel-manifest.json`.
- **Stage detected.** 50 provenance-inputs (R2, twice: `build` at 23:07:35 and
  `build2` at 23:09:24).
- **Stage where it could have been detected.** A static repo test with no host at
  all (`mainline.release` revision != `kernel-manifest.json` revision). For the
  host half (r293 missing from kernel-staging), stage 00.
- **Minutes wasted.** About 25 (T item 5), plus "minutes" for the cache-dir variable
  (T item 2). The fix was a hand copy of hash-identical debs, which is itself C7.

### C3 -- late provenance

- **Evidence.** A2 reached stage 80 after `layers (680s)`, `image (403s)` and
  `secret-scan (409s)` (`.out:10006,10253,10262`), then failed with 71 findings
  (`10-provenance-gate.log`, final line:
  `8419 packages checked, 71 failure(s)`). By input:
  - **Prebuilt rootfs tarballs from the old snapshot.** `[image:rescue-rootfs.tar.zst]`
    has 38 rows (from line 38), including
    `etc/apt/sources.list :: source https://snapshot.debian.org/archive/debian/20261018T082309Z forky is not a reviewed ... source`.
    `[image:ncz-mgmt-rootfs.tar.zst]` has the same pattern, lines 76-85.
  - **NCZ debs without a ledger row.**
    `[image:assets/screensaver/amd64:ncz-screensavers_0.8.19_amd64.deb] ... not in the reviewed NCZ ledger`
    (lines 86-87). `manifests/ncz-packages.tsv:43-44` only has 0.8.18. The 0.8.19
    debs are tracked in git (`git ls-files assets/screensaver`), added by the
    0.8.19 series ending `0d52fd46`.
  - **Substrate udebs** (the C1 rows above).
- **Root cause.** `stage_provenance_inputs()` (`build/build-image.sh:978-1092`) checks
  only five things:
  1. The offline mirror.
  2. `assets/{cix,vendor,ncz}-debs` and `downloads/vendor-debs`.
  3. The one-kernel rule.
  4. The payload shader.
  5. Pin freshness.

  It never looks at:
  - `assets/screensaver/*/*.deb`
  - `assets/mgmt/ncz-mgmt-rootfs.tar.zst`
  - `assets/rescue/rescue-rootfs-*.tar.zst`
  - The substrate ISO's `/cdrom` pool or its initrd `var/lib/dpkg/status`.

  `scan_image()` (`build/forky-provenance.py:1921`) checks all of these, but only
  on the finished `.img`. The building blocks for the early check already exist:
  `safe_extract_zst()` (1588), `scan_rootfs()` (1460), `_scan_initrd()` (2503) and
  `scan_debs()` (1219). The early stage just never calls them on the inputs. This
  breaks design rule 2026-10-10 in the `build/build-image.sh` header ("a bad input
  must fail in minutes, not after hours of layers").
- **Stage detected.** 80.
- **Stage where it could have been detected.** 20 stage-inputs. Every one of these
  bytes is on disk by then.
- **Minutes wasted.** 23:03:43 to 23:32:06, about 28 minutes (T item 7), plus the fix
  work.

### C4 -- tests with hard-coded pins

- **Evidence.** T item 4: `build/test-no-ubuntu.sh` failed 3 checks (two snapshot
  literals plus the fixture `InRelease`). Commit `fb022bc5` touched
  `build/test-no-ubuntu.sh` (4 lines) and rewrote
  `build/testdata/forky-snapshot/InRelease` (1578 lines). The literals are still
  there: `build/test-no-ubuntu.sh:1174` (`.../archive/debian/20261026T022331Z`)
  and `:1180` (`= "20261026T022331Z"`). The next re-pin will break the same three
  checks again.
- **Stage detected.** Pre-commit test run, after the re-pin had already been made
  on two hosts.
- **Stage where it could have been detected.** Never needed. The tests should read
  the pin from `release.conf` via `ncz_pin_snapshot` (which is already exercised at
  line 1180), and the fixture should be self-contained.
- **Minutes wasted.** About 40 (T item 4). This includes discovering that the
  arm64 `base.pin` line had been refreshed only in ULTRA's clone.

### C5 -- stale intermediate artifacts

- **Evidence.**
  - The rescue and mgmt rootfs tarballs still carry snapshot `20261018T082309Z`
    (C3).
  - The r292 kernel debs were rebuilt and reused under an r293 manifest (C2).
  - The offline mirror is rebuilt or reused based on a fingerprint:
    `[offline-mirror] missing or stale; rebuilding` (R2 `.out:278`) versus
    `existing mirror matches local package pins` (R2 build2 `.out:72`).
    The fingerprint covers release.conf, the snapshot and the package manifests,
    which is correct, but nothing ties the rootfs tarballs to the snapshot.
    `manifests/build-inputs.tsv:7-10` pins them by sha256 and size only.
  - Historical: "stale-layer forcing" was one of the r202 manual steps listed in
    the `build/build-image.sh` header.
- **Stage detected.** 80 (tarballs) and 50 (kernel debs).
- **Stage where it could have been detected.** 20, if `build-inputs.tsv` recorded the
  snapshot each tarball was built from.
- **Minutes wasted.** Counted inside C2 and C3.

### C6 -- env/permission debris

- **Evidence.**
  - T item 6: "root-owned files in the clone after the containerised build stages
    made rm/cleanup fail until `sudo chown -R`".
  - The repo has fixed this class piecemeal three times already:
    - `build/check-forky-provenance.sh:23-46` ("strand the run dir (2026-10-11)")
    - `stage_provenance_gate()` NCZ_CHOWN_BACK
    - `ncz_magnetar_collect` `chown -R` (`build/build-image.sh:1636`)
  - `ncz_container_run()` (`build/build-image.sh:564`) runs `make offline-mirror`
    and the layer/image makes as root in a container mounted on the clone, and has
    no general chown-back.
  - Separately, A2 `07-layers.log:199-202`: `W: cannot mount because CAP_SYS_ADMIN is not in the effective set`.
    This is a warning today but is the same class (privilege assumptions inside
    the container).
- **Stage detected.** After the build, by the operator.
- **Stage where it could have been detected.** In `run_stage()` right after each
  stage, as a uid-0 file audit of `$ROOT` and `$RUN_DIR`. Also at stage 00 of the
  next run.
- **Minutes wasted.** Not recorded.

### C7 -- operator-procedure mistakes

- **Evidence.**
  - T item 1: stdout redirected into the clone made the tree dirty. Preflight only
    warns about this (`build/build-image.sh:737-739`:
    `WARN: git tree is not clean; the artifact will record git=...`).
  - T item 4: a re-pin committed with only the amd64 half. R1
    `01-refresh-substrate.log` shows the pipeline itself rewrote the tracked file on
    ULTRA:
    `wrote /home/jasonperlow/Projects/ncz-p4-arm64-20261029/manifests/base.pin: arm64 substrate efa75a8f ... -> snapshot 20261026T022331Z`.
    This happens because `--full` defaults to `--substrate refresh`
    (`build/build-image.sh` header, `--substrate`), and `stage_refresh_substrate()`
    (858-911) runs `build/refresh-substrate.sh` in place. Every full build on a
    stale pin edits committed manifests for one arch on one host.
  - T item 5: a hand copy of kernel debs out of an old build directory.
  - T item 8: a server image with a LAN address baked in (rule commit `adc49dd9`).
- **Stage detected.** Varies: preflight warning, the test run, provenance.
- **Stage where it could have been detected.** Stage 00. Each of these is
  mechanically checkable (section 3).
- **Minutes wasted.** Counted inside C1, C2 and C4.

### C8 -- network/mirror flakiness

- **Evidence.**
  - A2 `07-layers.log:440-450`:
    `W: Failed to fetch http://deb.debian.org/debian/dists/forky/InRelease Temporary failure resolving 'deb.debian.org'`,
    the same for `forky-updates`, `forky-security` and `forky-debug`, then
    `Some index files failed to download. They have been ignored, or old ones used instead.`
    This is the mkosi tools tree inside the layers stage. It survived today only
    because apt treats it as a warning.
  - `build/build-installer-image.sh:108,122` still `curl`s
    `https://deb.debian.org/debian/dists/forky/main/debian-installer/...` (live
    forky, not the snapshot) when no cached `debootstrap-udeb` exists.
  - `stage_refresh_substrate()` re-downloaded the weekly ISO even after
    `stage-substrate.sh` had restored it from the cache. R1
    `01-refresh-substrate.log:3-7` shows `staged ... from .../debian-testing-arm64-netinst-20261025-a108887b.iso`
    and then `fetching https://cdimage.debian.org/...`.
  - Both provenance stages pass `--fetch-index` (`build/build-image.sh:992,1873`)
    against snapshot.debian.org.
- **Stage detected.** None today (latent).
- **Stage where it could have been detected.** 00 (`--offline` capability check) and
  `--rehearse`.
- **Minutes wasted.** 0 failures today. Refresh-substrate cost 255 s (A1) and 179 s
  (R1) of network time per full build.

### C9 -- resource limits

- **Evidence.** No resource failure in today's evidence.
  - Guards exist: the preflight disk/tmpfs checks
    (`build/build-image.sh:730-734`), `layers-preflight.sh check_resources()`
    (`NCZ_LAYERS_MIN_FREE_GB`, default 60), and the reaper policy.
  - Peak usage is not recorded per run. Today's builds ran with 790 GB free on
    HYDRA's `/`, so the 60 GB guard was never tested.
  - The cost is time: offline-mirror took 788 s cold (A1 `.out:1959`) versus 107 s
    warm (A2 `.out:1921`).
- **Stage detected / could have been.** 00 and stage 60's preflight. This class is a
  risk, not a cause today.

---

## 2. Per-stage structural weaknesses

For each stage: what it assumes, what it checks, and what it does not check that a
later stage depends on.

**00 preflight** (`stage_preflight`, `build/build-image.sh:704`)
- Assumes: the clone is committed and coherent, and host resources match the
  manifests.
- Checks: privilege model, run-dir fs, `check-substrate-pin.sh`,
  `gen-base-pin.sh --check`, host tools, container image, kernel mainline link
  existence and bind mount, KVER, KVM (warn only), reaper.
- Does not check:
  - Dirty tree. Warn only (737-739), and stdout inside `$ROOT` is not detected at
    all.
  - Pin staleness. Downgraded to a `say` when `--substrate refresh` (749-750), so
    a stale pin turns into an in-place edit three minutes later.
  - That the kernel-staging dir holds the revision `assets/kernel-manifest.json`
    expects (C2).
  - That `NCZ_SUBSTRATE_CACHE_DIRS` / `~/.config/ncz/substrate-cache-dir` resolve
    to a dir holding the pinned sha (C2, T item 2).
  - That `NCZ_BUILD_INPUTS_DIR` holds every `build-inputs.tsv` row.
  - Root-owned files in `$ROOT` (C6).
  - KVM is a warning, and free disk is not checked against the layer stage's 60 GB
    rule.

**10 refresh-substrate** (`stage_refresh_substrate`, 858; `build/refresh-substrate.sh`)
- Assumes: refreshing the pin in place is safe.
- Checks: signature and coverage (exit 2 / 3), and restores the ISO from the cache
  via `build/stage-substrate.sh`.
- Does not check:
  - It mutates tracked files for one arch and does not regenerate
    `sid-exceptions.tsv`, the test fixtures or the rootfs tarballs.
  - It never classifies the substrate's udebs (`classify-sid-exceptions.py`
    exists but is not wired in).
  - It re-fetches after a cache restore (C8).

**20 stage-inputs** (`stage_stage_inputs`, 916; `build/stage-build-inputs.sh`, `stage-amd64-kernel.sh`, `stage-arm64-assets.sh`, `stage-screensaver-plugin.sh`)
- Assumes: a sha256 match means the input is valid for this pin.
- Checks: sha256 and size against `manifests/build-inputs.tsv`.
- Does not check: what snapshot a rootfs tarball was built from, and whether the
  packages inside it are authorized. Stage 80 depends on both (C3, C5).

**30 refresh-sources** (`stage_refresh_sources`, 1104)
- Checks: freezes the payload and writes `payload-receipt.json`.
- Weakness: the receipt only covers `ncz-singularity-desktop`. Other NCZ debs
  committed to `assets/` (screensavers) have no receipt and no ledger check until
  stage 80.

**40 offline-mirror** (`stage_offline_mirror`, 958)
- Assumes: the kernel debs in `build/kernel-debs` are the ones the manifest wants.
- Checks: the kernel pin by KVER only (R2 `.out:167`).
- Does not check: the packaging revision. It builds r292 debs from
  `mainline.release` and publishes them into the mirror. This is also the longest
  early stage (788 s cold), so every defect detected after it costs at least 13
  minutes.

**50 provenance-inputs** (`stage_provenance_inputs`, 978)
- Strong on what it does scan, and it reports every finding at once.
- Gaps:
  - It runs after the 13-minute mirror build even for defects that do not depend
    on the mirror (sid ledger, rootfs tarballs, screensaver debs).
  - Its coverage is a strict subset of stage 80's (see C3).

**55 static-gates** (`stage_static_gates`, 1270)
- Runs the mandatory suites (CUDA, greeter console fallback, NPU SSDT).
- Weakness: none of them is a repo-coherence check (pin files agreeing with each
  other).

**60 layers** (`stage_layers`, 1352; `build/layers-preflight.sh`)
- `layers-preflight.sh` re-checks pins, unique debs and resources.
- Weakness: it inherits the same deb-dir list (`check_inputs_unique`, lines
  297-298), so it has the same blind spots as stage 50. It also generates
  `rootfs-forky-amd64.tar.zst` when absent (A2 `07-layers.log:159`), and the mkosi
  tools tree reaches the network (C8).

**70 image** (`stage_image`, 1600; `build/build-installer-image.sh`)
- Checks: `substrate matches the pin` (R2 build3 `.out:10284`).
- Weakness: it may still download `debootstrap-udeb` from live forky (108-122).

**75 secret-scan** (1665)
- Costs 409 s on amd64 (A2 `.out:10262`).
- Weakness: it runs before the provenance gate, so a provenance-doomed image pays
  for a full secret scan first.

**80 provenance-gate** (1853)
- The only stage that sees the substrate udebs, the initrd status and the rootfs
  tarballs. It is correct, but it is the first place these inputs are examined.

---

## 3. Preventive measures (ranked)

Ranking is by minutes saved per unit of effort, using today's evidence. Effort
sizes: S is up to half a day, M is 1-2 days, L is 3 or more days. Every shell test
below follows the repo's pattern (`build/test-*.sh`, a fixture repo under a
`mktemp -d` in `$TMPDIR`, and `expect_rc`). Every negative case must fail on the
current tree without the change.

### M1 -- Early predictive provenance gate over all inputs

- **Checks.** Every byte that stage 80 will authorize, taken from the inputs, with
  the same verdict code:
  1. The offline mirror (as today).
  2. Kernel debs: `build/kernel-debs` and the kernel-staging dir, against
     `assets/kernel-manifest.json` and `manifests/ncz-packages.tsv`, including the
     `+rNNN` revision.
  3. Vendor debs (`manifests/vendor-debs.tsv`).
  4. NCZ debs: `assets/cix-debs`, `assets/ncz-debs` and `assets/screensaver/*/*.deb`
     against `ncz-packages.tsv` and the payload receipt.
  5. `assets/mgmt/ncz-mgmt-rootfs.tar.zst` and
     `assets/rescue/rescue-rootfs-$ARCH.tar.zst`, extracted and scanned, including
     their `etc/apt/sources.list` snapshot URI.
  6. The pinned substrate ISO: its `/cdrom` pool udebs, and the udebs in its
     initrd's `var/lib/dpkg/status`, against `manifests/sid-exceptions.tsv`.
- **Where.**
  - Parts 2-6 need only staged files, so they run as a new stage 25
    `provenance-predict`, between stage-inputs and refresh-sources: under 1 minute
    in, before the 13-minute mirror.
  - Part 1 stays in stage 50.
  - The gate is also callable standalone: `build/check-inputs-provenance.sh --arch A`.
- **Script/function.**
  - New `build/check-inputs-provenance.sh`, and a new `stage_provenance_predict()`
    in `build/build-image.sh` (added to `STAGES`, `stage_index`, `stage_enabled`).
  - Extend `build/forky-provenance.py` with:
    - `--rootfs-tar FILE`: `safe_extract_zst()` + `scan_rootfs()` + `audit_apt_files()`.
    - `--substrate-iso FILE`: xorriso extraction of the pool and initrd, then
      `authorize_pool()` + `_scan_initrd()`.
  - `scan_image()` and the new modes call the same helpers, so the verdicts cannot
    diverge.
  - Extend the deb-dir list in `stage_provenance_inputs()` and
    `layers-preflight.sh check_inputs_unique()` with `assets/screensaver/$ARCH`.
- **Tests** (new `build/test-provenance-predict.sh`):
  - Positive: a fixture tarball whose packages and sources match the fixture
    snapshot passes (rc 0). A fixture ISO whose udebs are in the fixture ledger
    passes.
  - Negative:
    - A tarball whose `sources.list` names a different snapshot fails with rc 1.
    - An ISO pool udeb missing from the ledger fails with rc 1.
    - A `ncz-screensavers_0.8.19` deb with only a 0.8.18 ledger row fails with rc 1.
    - A `+r292` kernel deb under an `+r293` manifest fails with rc 1.
  - Stage-order assertion in `build/test-build-image.sh`: with a failing predict
    stage, `stages.tsv` has no `offline-mirror` row.
- **Effort.** L (3 days). Most of the work is the ISO/initrd extraction wiring and
  fixtures.
- **Eliminates.** C3 entirely. Moves C1, C2 and C5 detection from stage 50/80 to
  stage 25. Today this would have saved ~28 min (A2) and ~18 min (A1) per attempt.

### M2 -- Scripted all-or-nothing re-pin for both arches

- **Checks.** That a re-pin produces a coherent commit or nothing.
- **Where.** Developer step, run on one host. It is never run by `build-image.sh`.
- **Script.** New `build/repin.sh [--snapshot S]`. It:
  1. Copies the tracked pin set into `$TMPDIR/repin.XXXX/` (a worktree).
  2. Runs `refresh-substrate.sh --arch amd64` and `--arch arm64` there, and
     requires both to pick the same snapshot.
  3. Runs `classify-sid-exceptions.py --iso` for both arches and regenerates
     `sid-exceptions.tsv`. Graduated rows are dropped. New class B/C rows are
     written with `review_by` and must be accepted with `--accept-new-exceptions`
     (human review stays explicit).
  4. Regenerates `build/testdata/forky-snapshot/InRelease`, but only while M4 is not
     yet in place.
  5. Runs `gen-base-pin.sh`. A failure is fatal; today it is a WARN at
     `refresh-substrate.sh:120`.
  6. Lists the `build-inputs.tsv` rootfs rows whose recorded snapshot (M8) no longer
     matches, as "rebuild required", and refuses to finish unless they were rebuilt
     or `--defer-rootfs` was given (in which case it writes nothing).
  7. Runs `build/test-no-ubuntu.sh`, `build/test-build-image.sh` and
     `build/test-pin-coherence.sh` (M3) in the worktree.
  8. Only then copies the files back and prints the exact `git add` list.
- **Also.** Change `stage_refresh_substrate()` so that `--substrate refresh` never
  writes tracked files. On a stale pin it fails with
  `pin stale: run build/repin.sh and commit`, or writes candidate pins into
  `$RUN_DIR/repin/` for review. This removes the R1 behaviour of rewriting
  `manifests/base.pin` in place on ULTRA.
- **Tests** (new `build/test-repin.sh`, with refresh and classify stubbed by
  fixtures):
  - Positive: both arches move, the ledger is regenerated, and the tests pass. All
    9 files of the `fb022bc5` set change together.
  - Negative:
    - The arm64 stub fails, and no tracked file changes (`git status --porcelain`
      empty).
    - An unreviewed new class-C udeb without `--accept-new-exceptions` fails with
      rc 1 and no write.
    - The arches resolve to different snapshots, and the script fails.
    - `build-image.sh --substrate refresh` against a stale fixture pin leaves
      `manifests/` byte-identical.
- **Effort.** M-L (2-3 days).
- **Eliminates.** C1, the half re-pin in C7, and part of C4. Saves ~60 min per
  re-pin (T items 3 and 4).

### M3 -- Repo pin-coherence test

- **Checks.** Cross-file agreement inside the commit, with no host involved:
  - `assets/kernel/mainline.release` revision equals the `+rNNN` revision in
    `assets/kernel-manifest.json` and in the `ncz-packages.tsv` cixmini rows.
    Today: r292 vs r293, which fails.
  - Every `.deb` tracked in git under `assets/` has an exact
    `ncz-packages.tsv`/`vendor-debs.tsv` row with a matching sha256. Today:
    `ncz-screensavers_0.8.19_*.deb` vs rows for 0.8.18 only, which fails.
  - The `base.pin` amd64 and arm64 rows have the same snapshot, which also equals
    `release.conf` `NCZ_BASE_MIRROR_SNAPSHOT` and the `determinism.pin` `snapshot`.
  - Every `sid-exceptions.tsv` row's snapshot equals the pin.
  - The `build-inputs.tsv` rootfs snapshot column (M8) equals the pin.
- **Where.** A static-gates suite (stage 55). Also called from preflight in
  `--rehearse`, and run by `build/repin.sh`. Because it needs no host, it also
  runs at commit time.
- **Known failures (2026-11-01).** `build-image.sh` preflight runs the check
  for the build arch through `build/lib/pin-coherence-gate.sh`. A rule listed
  in `manifests/pin-coherence-known-fail.tsv` (rule, owner, exact fix, reason)
  is a loud WARN and does not abort; any other failure, a checker error, or a
  malformed list aborts. `test-pin-coherence.sh` reads the same list and fails
  when a listed rule passes. The kernel revision is the packaging revision in
  `assets/kernel/mainline.deb-revision` (r293) when it differs from the staged
  release in `mainline.release` (r292).
- **Script.** New `build/test-pin-coherence.sh` plus `build/check-pin-coherence.sh`.
  The check is the reusable part; the test drives it on fixture repos.
- **Tests.**
  - Positive: a coherent fixture passes.
  - Negative, one per rule:
    - A fixture with `mainline.release` at r292 and the manifest at r293 fails.
    - An untracked-in-ledger deb under `assets/` fails.
    - A one-arch `base.pin` change fails.
  - The real tree is expected to fail today. That proves the check catches the
    live defects.
- **Effort.** S-M (1 day).
- **Eliminates.** The repo half of C2, the screensaver half of C3, and C7 half
  re-pins. It catches problems before a build starts.

### M4 -- Remove hard-coded snapshot literals from tests

- **Checks.** That no test hard-codes the current pin.
- **Where.** `build/test-no-ubuntu.sh:1174,1180`, and the fixture
  `build/testdata/forky-snapshot/InRelease`.
- **Change.**
  - Lines 1174 and 1180 read the pin with `ncz_pin_snapshot "$ROOT"` (from
    `build/lib/mirror-apt-opts.sh`), and assert it is well formed and equals the
    `base.pin` column.
  - The fixture InRelease becomes a generated fixture with its own throwaway
    keyring and a synthetic snapshot id. It is created in `$T` at test start, so
    the tests that verify the signature chain no longer depend on the real pin.
  - Synthetic dates such as `build/test-derive-base-pin-candidates.sh:22-41` are
    fine and stay.
  - Add a lint, `build/test-no-pin-literals.sh`. It fails if the value of
    `NCZ_BASE_MIRROR_SNAPSHOT` from `release.conf` appears literally in any
    `build/test-*.sh` or under `build/testdata/`.
- **Tests.**
  - Positive: the lint passes after the change.
  - Negative: on a fixture copy where a test contains the current pin literal, the
    lint fails. Run the lint on today's tree: it must fail (lines 1174 and 1180).
- **Effort.** S-M (1 day). Re-signing the fixture is the main work.
- **Eliminates.** C4. Saves ~40 min per re-pin.

### M5 -- Builder-host readiness check

- **Checks.** That the host can satisfy this commit. Each item fails with an
  actionable line:
  1. The kernel-staging dir (`ncz_kernel_staging_dir()`, or
     `NCZ_YOCTO_SHARED_DIR/kernel-staging`) contains the release named in
     `mainline.release`. For arm64 it also contains debs with the
     `kernel-manifest.json` revision and sha256. For amd64 it contains
     `assets/kernel/amd64-stable/KVER`.
  2. The substrate cache (`NCZ_SUBSTRATE_CACHE_DIRS` or
     `~/.config/ncz/substrate-cache-dir`) resolves and holds an ISO with the
     `base.pin` sha256 for the arch. The hash check result is cached by
     path+mtime+size.
  3. The inputs dir (`NCZ_BUILD_INPUTS_DIR` or `~/.config/ncz/build-inputs-dir`)
     holds every `build-inputs.tsv` and `build-inputs-public.tsv` row for the arch,
     sha256-verified. This reuses `stage-build-inputs.sh` in a new `--verify-only`
     mode.
  4. A sudo mechanism exists (`ncz_priv_model` != none) without reading the
     password file's contents.
  5. `/dev/kvm` is rw for the user or the `kvm` gid. This becomes a FAIL for builds
     that include the kvm-gate, instead of today's warning (842-845).
  6. Free disk on the run-dir and clone filesystems is at least
     `NCZ_LAYERS_MIN_FREE_GB` plus the measured peak (C9).
  7. No uid-0 files under `$ROOT` (`find "$ROOT" -xdev -uid 0 -print -quit`) or a
     reused `$RUN_DIR`.
  8. `git status --porcelain` is empty. This becomes a FAIL for publishable builds;
     `--no-publish` keeps the WARN.
  9. Build stdout and stderr are outside the clone:
     `readlink /proc/$$/fd/1` and `fd/2` must not resolve under `$ROOT`.
  10. The container image is present.
- **Where.** A standalone `build/host-ready.sh --arch A` that operators run before
  starting. `stage_preflight()` calls it first, and any FAIL aborts stage 00.
- **Tests** (new `build/test-host-ready.sh`, with fixture dirs and env overrides
  like layers-preflight's `--df-fixture`):
  - Positive: a fully populated fixture host passes.
  - Negative, each failing alone:
    - The staging dir has r292 only while the manifest wants r293.
    - The cache-dir env is unset and no config file exists.
    - One inputs row is missing.
    - An inputs file has a wrong sha.
    - A root-owned file is in the fixture clone (skipped when the test runs as
      root, like `test-greeter-console-fallback`).
    - The tree is dirty.
    - stdout is redirected to a file inside the fixture clone.
    - The df fixture is below the threshold.
- **Effort.** M (2 days).
- **Eliminates.** C2 (host half), C6 at the next run, C7 (items 1 and 5), and C9
  surprises. Would have stopped T items 1, 2 and 5 at 0 minutes in.

### M6 -- `--rehearse` mode

- **Checks.** That everything except the expensive byte production would pass.
- **Where.** `build/build-image.sh --rehearse` (implies `--no-publish`). It runs:
  - 00 (with M5)
  - 20
  - 25 (M1)
  - 55, plus M3
  - offline-mirror in verify-only mode: when the mirror fingerprint
    (`layerplan.py fingerprint --layer mirror`) matches, verify it; otherwise
    predict the closure from the manifests against the pinned snapshot index.
  - `layers-preflight.sh` and `layerplan.py plan` to show which layers would
    rebuild.

  It then stops and prints a predicted verdict per stage, and writes `rehearse.tsv`
  to the run dir.
- **Script.** `build/build-image.sh`: argument parsing, `stage_enabled()` and a
  `REHEARSE` guard in `run_stage()`. It reuses the existing `NCZ_TEST_STAGE_SKIP`
  shape, which shows that skipping bodies after static-gates is already safe.
- **Tests** (`build/test-build-image.sh`):
  - Positive: `--rehearse` on a passing fixture leaves `stages.tsv` with no
    `layers`, `image` or `provenance-gate` rows, and with rc 0.
  - Negative:
    - A failing predict stage gives rc 1 and is named in `rehearse.tsv`.
    - `--rehearse` combined with publish flags is a usage error (rc 2).
- **Effort.** M (1-2 days, after M1, M3 and M5).
- **Eliminates.** The cost of every class that M1, M3 and M5 detect. A rehearsal
  costs 2-5 minutes, against 18-28 minutes for today's failing attempts.

### M7 -- Kernel revision pin, not just KVER

- **Checks.** That each staged kernel deb's full `Version` (`7.3.0-sky1-ncz+r293`,
  `1.6+r293`) and sha256 equal `assets/kernel-manifest.json`.
- **Where.** The kernel-pin check that prints `[kernel-pin] OK: ... (7.3.0-sky1-ncz+r292)`
  (R2 `.out:167`), the `kernel-debs` reuse decision (R2 build2 `.out:15`), and
  `build/build-kernel-debs.sh:139-141`. These must refuse to build from a
  `mainline.release` whose revision differs from the manifest.
- **Tests.**
  - Positive: r293 debs with an r293 manifest pass.
  - Negative:
    - r292 debs with an r293 manifest fail. Today this passes.
    - Same version with a wrong sha fails.
- **Effort.** S (half a day).
- **Eliminates.** C2 (kernel), and C5 for kernel debs. Moves detection from stage 50
  to stage 40's first second (and to stage 00 through M5).

### M8 -- Bind prebuilt rootfs inputs to the snapshot

- **Checks.** That `ncz-mgmt-rootfs` and `rescue-rootfs` were built from the current
  pin.
- **Where.**
  - Add a `snapshot` column to `manifests/build-inputs.tsv` for rootfs rows.
  - `build/build-mgmt-rootfs.sh` and `build/build-rescue-rootfs.sh` record it.
  - `build/stage-build-inputs.sh` refuses a row whose snapshot differs from
    `release.conf`. M3 checks the column and M1 verifies the contents.
- **Tests.**
  - Positive: the row snapshot equals the pin, and the stage passes.
  - Negative: a row at `20261018T082309Z` under pin `20261026T022331Z` fails at
    stage 20. Today it passes until stage 80.
- **Effort.** S-M (1 day, plus rebuilding both tarballs once).
- **Eliminates.** C5 (rootfs), and the rootfs half of C3.

### M9 -- Pin and cache the network inputs

- **Checks.** That every network fetch during a build is from a pinned URL, cached,
  and retried with a bound. With `--offline` the build either completes or fails
  in stage 00.
- **Where.**
  1. `build/build-installer-image.sh:100-125`: take `debootstrap-udeb` only from
     the substrate pool or the pinned snapshot (`release.conf`). Remove the live
     `deb.debian.org` fallback.
  2. The mkosi tools tree in the layers stage (A2 `07-layers.log:440-450`): point
     it at the snapshot or the offline mirror, or disable tools-tree apt update.
     Treat any `Failed to fetch` there as FAIL.
  3. `stage_refresh_substrate()`: skip `refresh-substrate.sh` when the restored ISO
     already matches `base.pin` and the pin is fresh (R1 lines 3-7: 179 s wasted).
     Under M2 this stage only verifies.
  4. The `--fetch-index` downloads in `forky-provenance.py atomic_fetch()`: a host
     cache keyed by the `forky-snapshot.tsv` InRelease sha, so the index is fetched
     once per pin per host.
  5. A shared `ncz_fetch` helper with 3 tries and backoff, for every snapshot or
     cdimage `curl` call.
- **Tests.**
  - Positive: `--offline` with a warm cache passes stages 00-55 on a fixture.
  - Negative:
    - `--offline` with a cold index cache fails at stage 00 with a named missing
      item.
    - The grep lint (new `build/test-no-live-mirror.sh`) fails when a build script
      contains `deb.debian.org` outside allowlisted defaults. Today it fails on
      `build-installer-image.sh:108,122`.
- **Effort.** M (2 days).
- **Eliminates.** C8, and removes 3-4 minutes of fetch from every full build.

### M10 -- Ownership audit and chown-back for container stages

- **Checks.** That no stage leaves uid-0 files under `$ROOT` or `$RUN_DIR`.
- **Where.**
  - `ncz_container_run()` (564) gets the same `NCZ_CHOWN_BACK` trap that
    `check-forky-provenance.sh` uses (`ncz_trap_chown_back` in
    `build/lib/priv.sh`).
  - `run_stage()` runs `find -xdev -uid 0` after each stage and fails the stage,
    listing up to 20 paths, if any exist.
- **Tests.**
  - Positive: a stub container stage that creates root files, then chowns back,
    passes.
  - Negative: a stub stage that leaves a root-owned file fails, and the file is
    named. Runs only where sudo is available; otherwise it is skipped with a
    message.
- **Effort.** S (half a day).
- **Eliminates.** C6.

### M11 -- Provenance before secret-scan, and log de-duplication

- **Change 1.** Reorder 75/80 so the cheap provenance gate (48 s in A2: 23:31:18 to
  23:32:06) runs before the 409 s secret-scan. Both stay mandatory. This saves
  about 7 minutes on every provenance-doomed image.
- **Change 2.** Drop the inner `tee -a "$log"` in stage functions (or the outer one
  in `run_stage()`), so log line numbers mean something.
- **Tests.**
  - `test-build-image.sh` stage-order assertion: provenance-gate comes before
    secret-scan, and both rows exist on success.
  - Every log line appears once in a fixture run.
- **Effort.** S.
- **Eliminates.** Part of the C3 cost, and makes diagnosis faster.

### M12 -- Operator runbook rules (with enforcement)

These go in `docs/BUILD-RUNBOOK.md`. Each rule names the check that enforces it,
so the runbook is not the only safeguard.

1. Never redirect build output into the clone. Write to `~/Projects/<run>.out`.
   Enforced by M5 item 9.
2. Never re-pin on a builder. Re-pin with `build/repin.sh` on one host, commit
   both arches, and every builder pulls. Enforced by M2 (no in-place writes) and
   M3.
3. Never hand-copy debs into a build tree. Update kernel-staging via the kernel
   publish step, then rerun `build/host-ready.sh`. Enforced by M5 item 1 and M7.
4. Run `build/build-image.sh --rehearse` on each builder before the real build,
   after any pull that touches `manifests/`, `assets/kernel*`, `release.conf` or
   `assets/*.deb`.
5. Resume only with the printed `--resume-from` command, and only after the fix is
   committed. A fix made in the clone without a commit makes the image record
   `git=<sha>` of a tree that does not exist.
6. Set `NCZ_SUBSTRATE_CACHE_DIRS` and `NCZ_BUILD_INPUTS_DIR` in
   `~/.config/ncz/*-dir` files, not in the interactive shell. M5 checks the
   resolved values.
7. No LAN addresses in images or new code. Configuration comes from the
   environment (rule `adc49dd9`). Enforced by the existing gate.

- **Tests.** These are the tests of M2, M5 and M7. The runbook adds no
  unenforced rule except rule 4.
- **Effort.** S.
- **Eliminates.** C7.

### Ranking summary

| rank | measure | effort | classes | est. minutes saved today |
|------|---------|--------|---------|--------------------------|
| 1 | M3 pin-coherence test | S-M | C2, C3, C7 | ~25 (r292/r293), screensaver half of 28 |
| 2 | M7 kernel revision pin | S | C2, C5 | ~25 |
| 3 | M1 predictive provenance gate | L | C1, C3, C5 | ~46 |
| 4 | M2 scripted re-pin | M-L | C1, C4, C7 | ~60 |
| 5 | M4 test literal removal | S-M | C4 | ~40 |
| 6 | M5 host readiness | M | C2, C6, C7, C9 | "minutes" (T items 1, 2) + ~25 |
| 7 | M8 rootfs snapshot binding | S-M | C3, C5 | part of 28 |
| 8 | M6 `--rehearse` | M | all detectable classes | the cost of every attempt |
| 9 | M10 ownership audit | S | C6 | unquantified |
| 10 | M9 network pinning | M | C8 | 3-4 per full build |
| 11 | M11 gate order + logs | S | C3 cost | ~7 per doomed image |
| 12 | M12 runbook | S | C7 | n/a |

The savings overlap: M1, M3 and M7 each catch the r292/r293 drift, for example.

---

## 4. Implementation order and definition of done

**Order** (each step lands with its tests, and each negative test is shown to fail
on the parent commit):

1. **M3 + M7** (day 1). Pure checks with no pipeline restructuring. They will fail on
   today's tree (r292 vs r293, screensavers 0.8.19), and those two repo defects are
   fixed in the same series, with the fixes reviewed separately.
2. **M4** (day 2). Unblocks M2's test step.
3. **M8** (day 2-3). Adds the rootfs snapshot column and rebuilds both tarballs at
   the current pin.
4. **M1** (days 3-5). The new stage 25 plus the `forky-provenance.py` modes.
5. **M2** (days 6-7). `build/repin.sh`, and `--substrate refresh` stops editing
   tracked files.
6. **M5** (days 8-9). `build/host-ready.sh` wired into `stage_preflight()`.
7. **M10, M11** (day 10).
8. **M6** (days 11-12). It needs M1, M3 and M5 to be meaningful.
9. **M9** (days 13-14).
10. **M12** (written alongside each enforcing measure, and finalized last).

**Definition of done**

- Of builds started from a commit that passed `--rehearse` on the same host, 0%
  fail in or after stage 60 for C1-C7 reasons, measured over the next 10 builds
  per arch. Any such failure is a bug in a check and gets a regression test.
- Every finding that `stage_provenance_gate()` reports on an image is also reported
  by stage 25 or 50 on the same inputs. Test: the 71 A2 findings, replayed against
  fixture inputs, are all caught by `build/check-inputs-provenance.sh`.
- A re-pin is one `build/repin.sh` invocation and one commit touching both arches.
  `build/test-no-ubuntu.sh` and `build/test-build-image.sh` pass at the new pin
  with no test file edited.
- `git grep "$(sed -n 's/^NCZ_BASE_MIRROR_SNAPSHOT="\(.*\)"/\1/p' release.conf)" -- 'build/test-*.sh' build/testdata`
  returns nothing.
- `build/build-image.sh --full` on a stale pin leaves `git status --porcelain` empty.
- `build/host-ready.sh` fails, before any stage runs, on each of T items 1, 2 and 5
  reproduced on a fixture host.
- No uid-0 file under the clone after a full build.
- `--offline` builds succeed with warm caches. No `deb.debian.org` fetch appears in
  any stage log.
- Existing suites stay green: `build/test-no-ubuntu.sh` (182/0 today),
  `build/test-build-image.sh` (174/0 today), and `build/test-layers-hardening.sh`
  (the `layers-preflight.sh` suite).

---

## 5. Risks and what could not be verified

**Risks**

- **M1 duplicates stage-80 logic.** If the predictive and final gates use different
  code paths, they will disagree and the early gate becomes noise. Mitigation:
  both call the same `forky-provenance.py` helpers, and a parity test replays
  stage-80 fixtures through stage 25.
- **ISO/initrd extraction at stage 25** needs `xorriso` and the cpio/zstd decoders
  on the host, not only in the container. M5 must check for them. The initrd
  `_extract_newc()` path has hardened extraction rules that must not be relaxed
  for speed.
- **M2 can automate approval.** Generating `sid-exceptions.tsv` rows automatically
  risks rubber-stamping new sid content. The `--accept-new-exceptions` flag and the
  `review_by` column keep the human step. The ledger's purpose ("keep it small and
  shrinking") must not be lost.
- **Stopping in-place refresh changes operator habits.** A stale pin now blocks a
  builder until someone commits a re-pin. The 8-day limit
  (`NCZ_SUBSTRATE_MAX_AGE_DAYS`) means a re-pin is due weekly anyway. M2 makes it
  cheap.
- **Stricter preflight** (dirty tree, KVM, uid-0 files) will block some builds that
  succeed today. Each check needs a clear message and a documented override for
  `--no-publish` diagnostics only.
- **`--rehearse` predicts the mirror closure without building it.** That
  prediction can be wrong (apt resolver differences). It is a predictor, not a
  replacement for stage 50.
- **Reordering 75/80** is safe only if nothing in the provenance gate depends on
  secret-scan output. The code read here shows no such dependency, but this was
  not exhaustively traced.

**Could not verify**

- ULTRA's actual host state (kernel-staging contents, substrate cache, config
  files). No access to other hosts was allowed. C2's host half rests on T item 5
  and R2's logs.
- The arm64 provenance-gate result. R2 build3 ends inside secret-scan (`.out:10441`),
  so it is unknown whether arm64 has the same substrate udeb and rootfs findings
  as amd64. The shared root cause makes it likely.
- T item 1 says preflight failed, but A1 `00-preflight.log` shows the stale-pin
  FAIL downgraded and stage 00 passing (`.out:23`, `OK [preflight] (1s)`).
  Item 1 may describe an earlier run with no surviving log.
- Minutes lost to C6 debris and to T items 1 and 2 ("minutes").
- Whether `build/check-sid-exceptions.sh`, which is wired into `make sid-exceptions`
  and runs non-fatally (`|| true`, Makefile:451), would have flagged the new udebs.
  It tracks existing rows, not unlisted ones, so probably not.
- Peak disk use of a full build. It is not recorded, so the C9 thresholds are
  unvalidated.
- Effort estimates are judgement, not measurement.
- `build/test-no-ubuntu.sh` (182 passed, 0 failed) and `build/test-build-image.sh`
  (174 passed, 0 failed) were run on HEAD `fb022bc5`. No image build was run for
  this document.
