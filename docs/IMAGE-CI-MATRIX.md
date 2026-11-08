# Image CI matrix: desktop and Magnetar, amd64 and arm64

A release candidate is four media: desktop and server (Magnetar) on amd64 and
arm64. `build/image-ci-matrix.sh` builds and checks all four. The trigger runner
(`build/image-ci-run.sh`) calls it for the `forky-pin` and `ncz-debs` triggers,
for the arch of the host it runs on.

## Cells

| cell | host | build | KVM gate |
|---|---|---|---|
| desktop/amd64 | HYDRA or TYPHON | `NCZ_VARIANT=desktop build-image.sh --arch amd64 --full --sources pinned --substrate pinned --no-publish` | full gate + `norescue norescue-mgmt nodesktop minimal stalefs` |
| server/amd64 | HYDRA or TYPHON | same, `NCZ_VARIANT=server` | `server server-offline-negative` |
| desktop/arm64 | ULTRA | same, `--arch arm64` | as desktop/amd64 |
| server/arm64 | ULTRA | same, `NCZ_VARIANT=server --arch arm64` | as server/amd64 |

The other gates are build-image.sh's own stages and run for both variants:
provenance-predict, provenance-inputs, static gates, provenance gate (for server
`--variant server --server-payload`, which also checks base.squashfs, the asset
bundle and the offline pool against the receipt pins) and the secret scan (for
server, the medium plus the payload).

The server KVM sets install over the gate's own HTTP payload server and check:
each artifact fetched and sha256-verified (`[FETCH] ... verified`), ssh enabled,
no telnet, no desktop or graphical boot entries, a serial login prompt and the
first-boot report. `server-offline-negative` checks that a stopped payload
server fails loudly within the deadline with nothing installed. No management
container is expected on a server install.

A CI server medium is a gate medium. The matrix removes `NCZ_PAYLOAD_BASE_URL`,
`NCZ_PAYLOAD_URL`, `NCZ_PAYLOAD_SHA256`, `NCZ_ASSETS_URL`, `NCZ_POOL_URL` and
`NCZ_SERVER_PAYLOAD` from the build environment, so the medium pins the KVM
gate's local server (option B: the pool is a pinned download). Nothing is
uploaded. The R2 upload of a release payload happens after the operator's
hardware test, as a separate step.

## Per cell

1. Clone A: a fresh clone of the commit into `CELL/src-a`.
2. Build A, with `--run-dir CELL/run-a`.
3. Clone B and build B: the same pins in a second clean clone.
4. Compare: `compare-images.sh IMG_A IMG_B --layers src-a/assets/squashfs src-b/assets/squashfs`.
   Server cells add `--payload run-a/payload run-b/payload`, which compares
   base.squashfs, `ncz-assets-<arch>.tar.gz`, `ncz-pool-<arch>.tar.gz` and their
   `.sha256` files. A file present on one side only is a failure. If
   `manifests/determinism-expect.tsv` exists, it is passed as `--expect`.
5. Keep image A and its receipt in `CELL/artifacts/` with `SHA256SUMS`, plus
   `run-a/` (logs, gate results, payload) and `compare.json`. Remove both
   clones (unless `--keep-clones`), payload B and `CELL/tmp`.

If build A fails, B does not run. A failed or nondeterministic cell does not
stop the other cells, but the run exits 1.

## Layout, lock, marker

- Run root: `~/Projects/ncz-image-ci/<UTC stamp>-<sha12>[-N]/<variant>-<arch>/`
  (`NCZ_IMAGE_CI_ROOT`). A root on tmpfs is refused. TMPDIR is the cell's `tmp/`.
- Lock: every build takes `~/Projects/ncz-build-runs/.ncz-build.lock`, the same
  lock as an ad-hoc build-image.sh run with its default run dir (`NCZ_BUILD_LOCK`).
- Hive busy marker: `~/.config/hive-worker/busy.d/ncz-image-ci-matrix`. Its first
  line is the pid of the process that runs the whole chain, so the worker build
  gate holds the host's workers off between builds too (clone, compare). A live
  marker blocks a second matrix (exit 3). A stale marker is cleared and named.
- Hosts: `NCZ_IMAGE_CI_HOSTS_AMD64` (default `hydra typhon`), `NCZ_IMAGE_CI_HOSTS_ARM64`
  (default `ultra fedora`). A cell refuses to run on any other host, on the wrong
  arch, or on macOS (STUDIO).
- Host defaults, applied only when unset and the path exists: HYDRA
  `NCZ_SUDO_PASS_FILE=~/.config/ncz/sudo-pass.json`; ULTRA
  `NCZ_BUILD_INPUTS_DIR=~/ncz-assets`, `NCZ_SUBSTRATE_CACHE_DIRS=~/ncz-assets/substrate`.

Cost: a host runs its two cells one after another, desktop A, B, then server
A, B, so four full builds per arch. `--no-determinism` (or
`NCZ_IMAGE_CI_DETERMINISM=0`) builds A only and skips the compare.

## Commands

```
bash build/image-ci-matrix.sh                          # dry run: all four cells
bash build/image-ci-matrix.sh --json                   # the same plan as JSON
bash build/image-ci-matrix.sh --arch amd64 --execute   # on HYDRA or TYPHON: detached
bash build/image-ci-matrix.sh --arch arm64 --execute   # on ULTRA: detached
bash build/image-ci-matrix.sh --status --from DIR ...  # the candidate grid
```

`--execute` prints `started pid=... log=... root=...` and returns. The log is
`<root>/matrix.log`, and `<root>/matrix.tsv` has one row per cell.

## Release-candidate status

A candidate (one commit) is complete only when all four cells are at least
`deterministic`. Cell states, lowest to highest:

| state | means |
|---|---|
| not built | no image A in `artifacts/` |
| built | image A exists |
| gated | built, and the KVM, provenance and secret-scan results of run A are all PASS (provenance recorded) |
| deterministic | gated, and `compare.json` says `deterministic` (two clean builds identical, or every difference covered by a documented `--expect` rule) |
| shipped | deterministic, and the orchestrator's ship step wrote `CELL/shipped` |

`--status` reads every launch dir of the commit under the run root, plus each
`--from` dir. The amd64 half is built on HYDRA or TYPHON and the arm64 half on
ULTRA, so copy one launch dir back next to the other, or pass both. For each
cell it reports the highest state any run reached. Exit 0 means complete.

```
           amd64            arm64
desktop    deterministic    gated
server     not built        not built
candidate 8ceda7338eb5: INCOMPLETE (a candidate needs all four cells at least deterministic)
```

## What the matrix does not do

Publish, upload, tag, flash or reboot. Install a timer (`build/systemd/image-ci-poll.*`
is the operator's step). Ship an image. `shipped` is only read from the
orchestrator's record.
