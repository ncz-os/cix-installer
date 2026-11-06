# Build decisions needed (operator)

These pin-coherence failures (docs/BUILD-STABILITY.md M3/M7) cannot be fixed
from the evidence in this repository alone.  Nothing below invents a version or
a hash.  Each entry lists the failure, the candidate values with their
evidence, and the decision the operator has to make.  Once an entry is
resolved, delete it, and delete its manifests/pin-coherence-known-fail.tsv row
in the same commit.

Written 2026-11-01 from branch sonnet/opstab3 (base sonnet/opstab1b-20261101).

## 1. rootfs-inputs: mgmt and rescue rootfs tarballs predate the pin

**Failure.** `build/check-pin-coherence.sh` rule `rootfs-inputs`, on both
arches:

```
manifests/build-inputs.tsv:7:  amd64 assets/mgmt/ncz-mgmt-rootfs.tar.zst        built at snapshot 20261018T082309Z, pin is 20261026T022331Z
manifests/build-inputs.tsv:8:  amd64 assets/rescue/rescue-rootfs-amd64.tar.zst  built at snapshot 20261018T082309Z, pin is 20261026T022331Z
manifests/build-inputs.tsv:9:  arm64 assets/mgmt/ncz-mgmt-rootfs.tar.zst        built at snapshot 20261018T082309Z, pin is 20261026T022331Z
manifests/build-inputs.tsv:10: arm64 assets/rescue/rescue-rootfs-arm64.tar.zst  built at snapshot 20261018T082309Z, pin is 20261026T022331Z
```

Listed in manifests/pin-coherence-known-fail.tsv, so build-image.sh preflight
WARNs (it shows the owner and the fix) and does not abort.  The image still
carries rootfs packages from the old snapshot.  On 2026-10-29 the amd64
provenance gate failed 48 checks on exactly these two tarballs
(docs/REPIN-20261026.md on origin/sonnet/repin-20261029).

**Candidates.**

| arch | input | value in this tree (snapshot 20261018T082309Z) | candidate at the pin | evidence for the candidate |
|---|---|---|---|---|
| amd64 | ncz-mgmt-rootfs.tar.zst | c63e8aa6...04f3, 55459672 | 594f36a1699db16c7f8c21795b5b530cf455d1c7b273941aaa76ae7797a41ea3, 55468424 | commit c193eca8 (origin/sonnet/repin-20261029, not merged); its docs/REPIN-20261026.md records a native rebuild at 20261026T022331Z, forky-provenance 149 pkgs / 0 failures |
| amd64 | rescue-rootfs-amd64.tar.zst | 5d09aa3c...904a, 212697798 | daa331d6e7fbc8705d8da98cc44c5e532219f2e243dceb29f16968d63cad45de, 212778470 | same commit; 392 pkgs / 0 failures; both tarballs together 541 pkgs / 0 failures under the gate's own extract |
| arm64 | ncz-mgmt-rootfs.tar.zst | 8323979d...ae08, 52913282 | **none** | no rebuild at the pin is recorded anywhere (both scripts need a native arm64 host) |
| arm64 | rescue-rootfs-arm64.tar.zst | 6c836eca...d2, 200282429 | **none** | same |

**Why this branch did not adopt the amd64 candidates.**
- c193eca8 states that those exact bytes existed only in that clone's
  gitignored `assets/`, and that publishing them to the build-inputs store was
  left open.  This task cannot reach the store, so it cannot confirm that a
  fresh clone can stage them.  A pin for bytes nobody can stage would turn a
  WARN into a staging failure.
- The rootfs tarballs are not byte-reproducible (docs/SOURCE-RELEASES.md), so
  the hashes cannot be re-derived.  They have to come from the real files.
- The rule is per row: with the amd64 rows adopted, arm64 still fails, so the
  known-fail row stays either way.

**Decision needed.**
1. amd64: confirm that the store holds 594f36a1... and daa331d6...
   (`build/stage-build-inputs.sh --arch amd64 --check` on a tree pinned to
   them), or run `--publish` from the clone that has them.  Then merge or
   cherry-pick the two build-inputs.tsv rows from c193eca8, plus the
   determinism.pin update that comes with them (`build/gen-base-pin.sh`).
   If those files are lost, rebuild them on the amd64 host and pin the new
   hashes.
2. arm64: on the arm64 build host, rebuild both tarballs at the pin:
   `build/build-mgmt-rootfs.sh <chroot> assets/mgmt/ncz-mgmt-rootfs.tar.zst forky arm64`
   and `build/build-rescue-rootfs.sh <chroot> assets/rescue/rescue-rootfs-arm64.tar.zst forky arm64`.
   Verify them with `build/forky-provenance.py --rootfs`, then run
   `build/stage-build-inputs.sh --arch arm64 --publish` and commit
   manifests/build-inputs.tsv.
3. Once both arches pass, delete the `rootfs-inputs` row from
   manifests/pin-coherence-known-fail.tsv.  test-pin-coherence.sh fails until
   you do.

## 2. Sky1 kernel +r293: is a fresh build byte-identical to the pin?

**Status.** No pin-coherence rule fails.  The revision is now coherent:
assets/kernel/mainline.deb-revision says r293, matching kernel-manifest.json
and the ledger (commit "kernel: r293 is a packaging revision ...").  The open
question is about reproducibility, so there is no known-fail row.

**Evidence.** The pinned r293 debs (kernel-manifest.json sha256 58967e53...,
882406b6..., d771239...) match the debs in the 2026-10-29 arm64 build log
(evidence/arm64/ncz-p4b-arm64-build3-20261029.out).  They were repackaged from
the staged r292-7.3.0-sky1-ncz-20261023 tree (commits 100bd157, 86f7fe82,
1c2d3371, a18a8d57, e7417407).  No r293 staging directory or tag exists in
linux-cix or meta-cix.  build-kernel-debs.sh derives SOURCE_DATE_EPOCH from the
manifests/base.pin arm64 snapshot, and that snapshot moved
(20261026T022331Z) after the r293 debs were built.

**Not verified.** No arm64 build was run here, so it is unknown whether stage
40 reproduces those sha256s.  If it does not, the kernel pin
(check-kernel-deb-pin.sh --manifest) refuses the new debs, and the build stops.
It does not ship them.

**Decision needed.** Pick one of these:
- (a) Keep the published r293 debs as the input.  Stage them from the store
  instead of rebuilding them.
- (b) Rebuild at the current pin and re-pin kernel-manifest.json and the ledger
  rows to the new hashes, under a new packaging revision (r294) so the version
  says the bytes changed.
