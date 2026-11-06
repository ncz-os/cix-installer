# Weekly Singularity Desktop head build (design)

TASK S step 4. What exists here is the pipeline definition and this document.
**No schedule is created by this change** — creating and enabling it is the
orchestrator's step (see the API call at the end).

Goal: every week, build the Singularity Desktop payload from the current
upstream heads for **both** arches, prove the downstream patch queue still
applies, publish the resulting bytes to ARGONAS for inspection, and stop.
Nothing reaches the apt repo, R2, or an image without a human.

## What runs

| step | queue | gate |
|---|---|---|
| refresh | arm64 | writes `pins-latest.tsv` (current heads) and annotates how many pin rows moved vs the committed set |
| reconcile | arm64 | `singularity-pins.sh validate` + `check-patches` — **fails loudly** when a downstream patch no longer applies |
| build amd64 / arm64 | amd64 / arm64 | `build-singularity.sh` then `build-singularity-deb.sh`, in parallel |
| checks amd64 / arm64 | same | asserts the build reached `== done ==`, the scenefx shader gate reported OK, the deb carries `libsingularity.so.0` and `bin/singularity-desktop`, `Depends` and the `.depends` sidecar are non-empty; prints an ABI-drift annotation when the payload's libsingularity differs from the plugin lock |
| upload | arm64 | tarball of the run to `/mnt/datapool/projects/ncz-singularity-weekly/<build>/` on ARGONAS with `SHA256SUMS` |
| summary | arm64 | annotation naming the artifacts and stating, in the pipeline itself, that nothing was published |

### Why `verify-singularity-payload` is NOT a weekly step

`verify-singularity-payload.sh` compares the built deb against
`manifests/singularity-payload.tsv` and `manifests/determinism.pin` — the pins
of the **published** payload — and against the plugin lock. A head build
deliberately differs from the published bytes, so running it weekly would fail
every week by construction and train people to ignore it. It stays a release
gate, run by the human at publish time (see below). The weekly checks assert
the subset that is meaningful for fresh bytes: internal build gates, deb
shape, soname presence, depends sidecar, and ABI drift.

### ABI drift is an annotation, not a red build

The screensaver plugin links `libsingularity` and the lock pins the exact sha
it was built against. Whenever the heads move libsingularity, the pinned
plugin is stale and must be relinked (this happened in the 2026-11-05 build:
amd64 `81fe23b1…` → `6444de93…`). A weekly red build would be the wrong
signal — the head build is still useful — so the checks step annotates the
drift with both shas and links here. Relinking is a release task.

## Prerequisites (verified 2026-11-05, not assumed)

- **`arm64` queue exists**: ULTRA's agent config carries
  `tags="queue=arm64,os=linux,arch=arm64,host=ultra88"`.
- **There is no amd64 agent**: neither HYDRA nor TYPHON has a
  `buildkite-agent` install or running process, and `/etc/buildkite-agent`
  does not exist on either. The amd64 steps therefore declare `queue: "amd64"`
  and will sit unassigned until an agent is provisioned. They must not be
  pointed at the arm64 queue: `build-singularity.sh` builds natively for the
  host arch, so an arm64 agent would silently produce arm64 bytes under an
  "amd64" label.
- Provisioning an amd64 agent (HYDRA, native amd64, the payload build host
  with docker and the ARGONAS mount) is the one infrastructure prerequisite:
  tags `queue=amd64,os=linux,arch=amd64,host=hydra78`.
- Agents need an SSH key to ARGONAS for the upload step (ULTRA already has
  one: the 2026-11-05 staging from ULTRA worked).
- The pipeline holds **no secrets**: the ARGONAS hop uses the agent's key, and
  the schedule token is never in the repository.

Note on the brief's reference to `.buildkite/pipeline.yml` in
`singularity-desktop`: that file does not exist at the current pin
(`6427e9c4`) or on the upstream default branch (the GitHub contents API
returns 404 for `/.buildkite`). The only queue name evidenced anywhere in this
fleet is the `arm64` one above, taken from the agent config and from
`docs/upstream/singularity/buildkite-publish-deb-step.yml`. No amd64 queue
name is invented in this design.

## How to read a failure

| failing step | meaning | action |
|---|---|---|
| `refresh` | upstream unreachable, or a pin row is malformed | infra flake → re-run; malformed row → fix `singularity-pins.sh propose` output, not the build |
| `reconcile` | a downstream patch no longer applies to its pinned commit, or a pin row is missing | reconcile or retire that patch in a `hv/ncz-lt-sinty-pins-<date>` branch (2026-11-05 precedent: loginui 0002 was retired because upstream took the fix over); never skip the build to get green |
| `build_*` | compile/link failure in the payload | classify from the log's `^ERROR:`/`^FAILED:` lines (the `error:` substring has ~228 false positives from source text), note the upstream repo and commit, fix the pin or the patch, rebuild |
| `checks_*` | a real defect: build did not finish its internal gates, or the deb lost a soname/binary/depends | treat as a blocked release candidate; do not publish |
| ABI-drift annotation | libsingularity moved; the pinned plugin is stale | rebuild the plugin from its pinned source against the new payload, update `post-install/lib/ncz-screensavers-plugin.lock`, re-run `check-ssplugin-abi` |
| `upload` | ARGONAS unreachable or the agent key is missing | infra; artifacts remain on the agent and as Buildkite artifacts |

## Publishing (human path, unchanged)

1. Run `build/verify-singularity-payload.sh --arch <arch> --payload-deb … --plugin-deb …`
   after the pins are committed — it is the gate that proves the deb is the
   pinned one and the plugin matches its ABI.
2. Commit the pins + plugin lock on an `hv/ncz-lt-…` branch, structured
   review (Muse), then the orchestrator publishes (apt repo + R2). The
   pipeline never runs `ncz-reprepro-publish.sh`.

## The schedule (orchestrator applies; token by key-master name only)

Proposal: Mondays 03:00 America/New_York, branch `release/preview4-20261025`.

```bash
# token: key master entry  buildkite / api_access_token   (never inline the value)
export BK_TOKEN="$(python3 - <<'PY'
import json, os
d = json.load(open(os.path.expanduser("~/.api_keys_master.json")))
print(d["buildkite"]["api_access_token"])
PY
)"

curl -sS -X POST \
  -H "Authorization: Bearer ${BK_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.buildkite.com/v2/organizations/ncz-os/pipelines/ncz-singularity-weekly/schedules" \
  -d '{
        "label": "Singularity weekly (both arches, no publish)",
        "cronline": "0 3 * * 1",
        "timezone": "America/New_York",
        "branch": "release/preview4-20261025",
        "commit": "HEAD",
        "message": "weekly Singularity Desktop head build (TASK S)",
        "env": {"NCZ_SINGULARITY_WEEKLY": "1", "NCZ_SINGULARITY_PUBLISH": "0"}
      }'
```

The pipeline `ncz-singularity-weekly` itself must exist first, with these steps
(`.buildkite/singularity-weekly.yml` in cix-installer is the uploadable
source):

```bash
buildkite-agent pipeline upload .buildkite/singularity-weekly.yml
```

Creating the pipeline and applying the schedule are the orchestrator's actions;
this document and the YAML are the reviewable artefacts.
