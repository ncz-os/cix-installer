# Image build process — sid exceptions integration (r203)

This is the **build-process** companion to `docs/FORKY-PROVENANCE.md`'s
"sid exceptions" section. It is a SEPARATE file on purpose: the deterministic
image-build-process work lives on `fix/r203-build-process-20261010`
(`docs/IMAGE-BUILD-PROCESS.md`); this file carries only the sid-exceptions
integration so the two branches do not conflict. When both land, fold this
content into the build-process document and delete this file.

Policy: `docs/FORKY-PROVENANCE.md` §"sid exceptions" — reviewed, per-package,
shrinking `manifests/sid-exceptions.tsv`; no blanket sid suite grant.

## Where it sits in the build

```
make refresh-substrate ARCH=<a>     # fetch newest netinst, derive base.pin, re-pin suites
  └─ build/refresh-substrate.sh
       └─ build/check-sid-exceptions.sh        # NEW stage: track the ledger + forky trend
make sid-exceptions                          # NEW target: same tracker, standalone
make offline-mirror ARCH=<a>                 # forky closure (sid d-i never enters the mirror)
NCZ_ONE_KERNEL=1 make image ARCH=<a>         # substrate udebs merged; Debian kernels dropped
  └─ build/iso/write-usb-image.py            # receipt records sid_exceptions {count,...}
build/check-forky-provenance.sh --image ...  # gate: sid d-i authorized ONLY via the ledger
```

## Stages

1. **Ledger generation / review** — when the substrate is refreshed, regenerate
   the ledger from the new netinst and review the diff:
   ```
   build/classify-sid-exceptions.py --arch amd64 --iso <netinst> \
       --snapshot <pin> --ledger manifests/sid-exceptions.tsv \
       --tsv-out <rundir>/classify-amd64.tsv
   ```
   It classifies every substrate d-i identity A/B/C/K and rewrites the ledger
   (B/C rows only; K = Debian kernel artifacts are dropped by the one-kernel
   policy and never listed). The ledger is committed after review.

2. **Tracking (refresh/pin stage)** — `make sid-exceptions`
   (`build/check-sid-exceptions.sh`) compares every row with the pinned forky
   index and the latest forky, writes `docs/SID-EXCEPTIONS.md`, and records the
   per-arch count in `<img>.receipt.json`. `make refresh-substrate` runs it
   after the pin moves. `SID_EXC_FLAGS=--strict` makes a GRADUATED/EXPIRED row
   fatal.

3. **Build gate** — every `make image` run is gated by
   `build/check-forky-provenance.sh` on the finished `.img`;
   `build/forky-provenance.py` authorizes a substrate sid d-i udeb **only** by an
   exact `manifests/sid-exceptions.tsv` row chained to the signed sid index, and
   FAILS a sid d-i package with no row, a graduated row, a row pinned to another
   snapshot, or an expired row. This is the "do not weaken any other check"
   floor: the offline `/cdrom` pool authorization
   (`authorize_pool(..., sid_idx=ref.sid_idx)`) routes sid d-i through the same
   ledger.

4. **Class-B rebuild (small gap → NCZ udeb)** — see
   `build/rebuild-sid-udeb.sh`. A rebuilt udeb is added to
   `manifests/ncz-packages.tsv` (name, version with a `+ncz` suffix, sha256,
   recipe, source revision) *and its ledger row is removed*, so the image carries
   an NCZ-ledgered udeb instead of a sid exception. Until the rebuild lands the
   row stays with `owner_action=rebuild`.

## Receipt contract

`<img>.receipt.json` gains a top-level `sid_exceptions` object:

```json
{"ledger": ".../manifests/sid-exceptions.tsv", "count": 30,
 "by_class": {"B": 29, "C": 1}, "by_action": {"rebuild": 29, "wait": 1},
 "sha256": "<ledger digest>", "snapshot": "<pin>"}
```

It records how much sid content the image carries and ties it to the exact
ledger revision, so the count is auditable per image and its trend is visible
across builds.
