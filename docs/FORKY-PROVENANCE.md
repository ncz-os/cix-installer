# Forky provenance gate — policy and design

Operator rule (2026-10-08): *"We shouldn't be using Ubuntu debs ever"*, and every
package in an NCZ-OS image must be traceable to exactly one reviewed origin:
an NCZ build, an explicitly reviewed vendor deb, or the pinned Debian **forky**
snapshot — byte-identical where bytes exist.

This document is the policy of record for `build/check-forky-provenance.sh` /
`build/forky-provenance.py` and for `build/check-no-ubuntu.sh` (the offline
Ubuntu-evidence-only gate that runs in `make lint-platform`).

## Gate correctness fixes (r203)

Four over-strict/under-coverage defects were fixed without weakening the gate's
security properties (each has both-direction tests in `build/test-no-ubuntu.sh`):

1. **`main/debian-installer/binary-all` index is now loaded.** `index_need()`
   requests every `(component, architecture)` including the literal `all`
   pseudo-arch for both the main components and `main/debian-installer`, so
   `Architecture: all` d-i udebs (`partman-lvm`, `partman-md`,
   `base-installer`, …) are authorized from the pin. Previously they were
   reported missing even though the signed Release carries a
   `main/debian-installer/binary-all/Packages.xz`.
2. **Absolute symlink TARGETS are no longer treated as escapes.** A real
   rootfs (`./var/lock -> /run/lock`, `./var/run -> /run`) and initrd
   (`etc/mtab -> /proc/mounts`) legitimately contain them. Only a **relative**
   target that resolves outside the extraction root fails, and absolute/`..`
   MEMBER paths still fail. For tar roots the extractor also refuses to write
   any member *through* an already-extracted symlink (write-through escape); for
   cpio the scanner already never materialises symlinks. Tests mutate real GNU
   tar/cpio output: absolute-member, `..`-member, relative-escaping-symlink and
   write-through all FAIL; absolute-symlink rootfs tarballs PASS.
3. **Reviewed partial overlay allow-list** (`manifests/overlay-layers.tsv`) —
   see the NCZ-ledger section below. A status-less layer NOT on the list still
   fails closed.
4. **The substrate's sid d-i content is authorized per package, not by suite
   (`manifests/sid-exceptions.tsv`).** The netinst substrate's debian-installer
   udebs are built from the snapshot's development suite (`sid`), not from
   `testing` (`forky`). An earlier cut of this fix authorized the WHOLE
   `main/debian-installer` index of the pinned snapshot's `sid` suite -- a
   blanket suite grant. That is **replaced** by a reviewed per-package ledger:
   the gate still verifies the `sid` `InRelease` digest (committed in
   `manifests/forky-snapshot.tsv` as `di_suite`/`di_inrelease_sha256`) and loads
   sid's `main/debian-installer` indexes, but a sid d-i package is authorized
   **only** by an exact `(name, version, arch, sha256)` row in
   `manifests/sid-exceptions.tsv` whose `sha256` equals the SIGNED sid index's.
   A sid d-i package with no row **FAILS** ("no blanket sid grant"); a row whose
   package forky now provides at the same-or-newer version **FAILS**
   ("GRADUATED, use forky"); an expired `review_by` **FAILS**. The `sid` runtime
   (`binary-*`) packages were never authorized and still are not. See
   "sid exceptions" below.

## sid exceptions — the reviewed, shrinking per-package ledger

Operator ruling (2026-10-10): *"I would use Sid only for those packages with no
forky versions. If we can rebuild them ourselves we should rebuild them if the
gap is small. If it is a large gap, keep track of the Sid specific components and
gradually replace with forky as it is provided by the upstream."*

`manifests/sid-exceptions.tsv` is that ledger. Every installer-substrate d-i
package the pinned snapshot authorizes only from `sid` gets **one reviewed row**;
nothing else from `sid` is authorized. Columns (TAB):

```
name version arch sha256 class forky_version gap reason first_seen snapshot
owner_action review_by tracking_url
```

* `class` — **B** (small gap: forky has the same source at a close version ->
  plan to rebuild the needed version from the forky source in a clean forky
  container as an NCZ udeb) or **C** (large gap / forky lacks it -> wait for
  upstream or replace). **Class A** (forky already provides the exact version)
  must NOT be listed: it is forky's and `class=A` is a schema error (exit 2).
* `sha256` — the SIGNED sid index's sha256 for that exact identity at the pinned
  snapshot. The gate chains every row to the archived, signed bytes; a row whose
  sha does not match the current pin's signed sid index fails closed.
* `owner_action` — `rebuild` | `wait` | `replace` (how the row will be removed).
* `review_by` — a review deadline (default +30 days). Past it the gate FAILS:
  re-review (remove if forky provides it, else re-date).
* `snapshot` — the pin the row was measured at. A row pinned to a different
  snapshot than the current pin FAILS: a re-pin requires regenerating the ledger.
* `tracking_url` — a Debian tracker/PTS link.

The gate (`build/forky-provenance.py`) enforces, with both-direction tests in
`build/test-no-ubuntu.sh` (§2f):

| situation | result |
|---|---|
| sid d-i package with an exact ledger row (sha == signed sid index) | authorized (`SID-EXC`) |
| sid d-i package with **no** ledger row | **FAIL** (no blanket grant) |
| ledger row sha != the signed sid index sha | **FAIL** |
| ledger row sha == signed sid index sha but the deb bytes differ | **FAIL** |
| no `di_suite` declared (no signed sid index to chain to) | **FAIL** |
| ledger row whose package forky now provides at >= version | **FAIL** (`GRADUATED: use forky`) |
| ledger row pinned to another snapshot | **FAIL** |
| expired `review_by` | **FAIL** |
| `class=A` or a bad `owner_action` | exit 2 (schema) |

The gate's graduation check is against the **BUILD pin** (the pinned snapshot's
forky index), so a shipped image is internally consistent. The *forward* signal
-- forky's live archive (deb.debian.org / `rmadison`) -- is reported by
`build/check-sid-exceptions.sh`, which writes the generated `docs/SID-EXCEPTIONS.md`
and records the per-arch count in the image receipt (`sid_exceptions` in
`<img>.receipt.json`).

**The gradual-replacement loop.** Run `make sid-exceptions` at the refresh/pin
stage (`make refresh-substrate` calls it):

1. It compares every row with the pinned forky index and the latest forky.
2. `GRADUATED` (forky now provides it) -> remove the row and use forky; if the
   substrate still carries the sid version, re-pin/refresh so the substrate's
   d-i matches testing (`build/classify-sid-exceptions.py` regenerates the
   ledger from the refreshed substrate).
3. `SHRINKING` -> upstream is catching up; keep the row, re-check next build.
4. `EXPIRED` -> re-review the row now.
5. Class B rows also disappear when the NCZ rebuild lands (an `+ncz` udeb in
   `manifests/ncz-packages.tsv`) or when the build stops merging the sid udeb.

`build/classify-sid-exceptions.py --arch <a> --iso <netinst>` regenerates the
ledger from a substrate: it extracts the netinst's own d-i identities (xorriso),
compares them with the pinned snapshot's forky full index and sid d-i index, and
classifies each A/B/C/K (K = Debian kernel artifact, removed by the one-kernel
policy and never listed). The ledger is reviewed and committed like any other
manifest; it may only ever shrink.



The checkout that contains `build/forky-provenance.py` **is** the trust root.
`ROOT` is derived from the file location; there is no `NCZ_PROVENANCE_ROOT` or
equivalent environment override, and no flag relocates the trust metadata
(`release.conf`, `manifests/`). This is deliberate: an environment variable that
redirects a ship-mode invocation to a different tree silently changes the thing
the gate protects.

All external tools (`dpkg-deb`, `unsquashfs`, `debugfs`, `gpgv`, `tar`, `zstd`,
`mdir`, …) run with a fixed scrubbed environment (`PATH` fixed, no `BASH_ENV`,
no inherited `NCZ_*`). Nothing in the verifier sources `apt-separation.sh` or
any other file whose trusted list can be steered by the environment.

## The pinned snapshot index (cryptographic, verified every run)

`manifests/forky-snapshot.tsv` is the immutable BUILD pin:

* `snapshot` = the `snapshot.debian.org` timestamp (`20261005T120000Z`,
  DERIVED from the pinned netinst substrate by measurement -- see
  "Substrate vs snapshot" below);
* `inrelease_sha256` / `inrelease_size` = the reviewed digest of the signed
  `dists/<codename>/InRelease` for that snapshot;
* `di_suite` (+ `di_inrelease_path`/`di_inrelease_sha256`/`di_inrelease_size`) =
  the SAME pinned snapshot's development suite (`sid`). The netinst substrate's
  debian-installer udebs are built from `sid` while its base packages are
  `testing` (`forky`); a snapshot timestamp is the whole archive state, so the
  gate reads forky's **full** index set AND sid's **`main/debian-installer`
  indexes**. This is one Debian origin read across its suites, **not a fourth
  origin**, and it never authorizes sid's runtime (`binary-*`) packages
  (`index_need()` requests no `(sid, main, …)` component; tested both ways).
  The sid d-i indexes are used **only** to chain a reviewed
  `manifests/sid-exceptions.tsv` row to the signed archive -- they do not
  authorize anything by themselves (see "sid exceptions" above).
  `build/pin-snapshot-suites.sh` records/verifies both digests against the
  committed keyring; `build/refresh-substrate.sh` keeps them in lockstep with the
  pin;
* `keyring` / `keyring_sha256` = the Debian archive keyring and its reviewed
  digest (`manifests/keys/debian-archive-keyring.gpg`);
* `signer_keys` = the Debian archive signing key fingerprints gpgv must report.

`release.conf`'s `NCZ_BASE_MIRROR_SNAPSHOT`/`NCZ_BASE_CODENAME` must equal the
trust metadata or the gate exits 2. The index directory itself may live
anywhere (`--index-dir`), because its **contents** are verified:

1. `gpgv --keyring <committed keyring>` verifies each declared suite's
   `InRelease` clearsignature, and the reported signer must be one of the pinned
   Debian keys;
2. each `InRelease`'s bytes must equal its committed `*inrelease_sha256`/size;
3. each signed Release's `SHA256:` section supplies the sha256+size of every
   `Packages.xz`; each needed index file must match that sha256+size;
4. each `Packages` file must decompress and yield at least one record.

A missing, truncated, forged, mismatched, or wrong-snapshot index is a hard
failure. **A self-written stamp is not verification** — only the gpgv chain
rooted at the committed digest counts. Downloads are written to a temp file,
`fsync`'d, and renamed only after they verify; failures clean up. Existing
caches are re-verified every run, so a poisoned cache can never be trusted.

Because the index is verified cryptographically, a cache location is not a
trust decision; `--index-dir` is required for the full (non `--ubuntu-only`)
gate. `build/ship-image.sh` creates an owned unique scratch under
`${NCZ_PROVENANCE_WORK_BASE:-$HOME/Projects/.ncz-ship-provenance}` and passes
`--index-dir "$PROV_WORK/index" --fetch-index`; the verifier makes its own unique
subdirectory and cleans up after itself (no `rm -rf` of a caller-supplied path).

## NCZ build ledger (`manifests/ncz-packages.tsv`)

Columns (TAB): `name`, `version`, `arch`, `sha256`, `recipe`, `source_revision`,
`note`. `sha256` must be 64 lowercase hex; `recipe` (col 5) and
`source_revision` (col 6) must be **non-empty** (a canonical build recipe and its
source revision/digest) — `note` (col 7) is optional. A row with an empty
`source_revision` is a hard failure even when its note is non-empty.

A package is NCZ **only** if its exact `(name, version, arch)` is in this
reviewed ledger, with a canonical build recipe + source revision and a 64-hex
reviewed sha256. Package-name prefixes (`ncz-*`, `cix-*`, …) and `+ncz` versions
are **not** proof and are ignored. When deb bytes are available the sha256 must
match; for dpkg-status / Packages identities (no bytes) the reviewed identity is
the mapping and the gate prints a NOTE that bytes were not hashed.

The ledger is seeded from the committed reviewed pin file
`manifests/build-inputs.tsv` plus the packaging recipe for the repacked CIX NPU
DKMS (`packaging/cix-npu-driver-dkms-6.2.0`). It is **incomplete by design**: it
lists only entries whose reviewed bytes exist today.

### NCZ ledger coverage (r203: populated)

r203 populates the ledger for every NCZ-built package observed in the r202
amd64/arm64 images: the T2-edge amd64 kernel + headers, the Sky1 arm64 kernel
trio (`linux-image-cixmini`, `linux-headers-cixmini`, `cixmini-boot`),
`ncz-screensavers`, `ncz-screensavers-plugin`, `ncz-apt-policy`,
`ncz-wallpapers-cygnus-2610`, the deliberately **patched** `debootstrap-udeb`
1.0.145 (recipe `build/iso/patch-debootstrap-stub.py`; both per-arch sha256
recorded), the NCZ-repacked DKMS set (`cix-gpu-kmd-dkms`,
`panthor-cix-dkms`, `cix-vpu-driver-dkms`), `ncz-usb-recovery`,
`chromium-ncz-sky1`, `ncz-ffmpeg` and the repacked `libgtk4-layer-shell0`.
`cix-npu-driver-dkms` was also corrected to `arch=all` (the .deb control field;
the previous `arm64` row never matched the `all` deb).

**Non-bit-reproducible `Architecture: all` builds.** Some `all` packages are
not bit-reproducible across build hosts (e.g. dpkg's `Installed-Size` differs by
filesystem block use — `ncz-apt-policy`, `ncz-wallpapers-cygnus-2610`,
`debootstrap-udeb`). The ledger therefore accepts a **set** of reviewed sha256
per `(name,version,arch)`; every member is an explicit reviewed sha256 (exact
bytes), never a pattern or wildcard.

**Build-timestamped NCZ packages (`manifests/ncz-timestamped.tsv`).**
`ncz-singularity-desktop` embeds a build timestamp in its version and so cannot
be statically sha-pinned. The narrowest safe rule applies: its **exact name +
anchored version regex** must match, AND the sha256 of the .deb actually
installed must be recorded in the finished image's receipt
(`<image>.receipt.json`, key `ncz_timestamped_debs`, written by
`build/iso/write-usb-image.py`). The gate recomputes the .deb sha256 while
scanning the image and cross-checks it against that receipt entry. A
build-timestamped package with no matching receipt entry **fails closed**; no
package-name prefix and no blanket version glob can authorize one.

**Reviewed partial overlay layers (`manifests/overlay-layers.tsv`).** A
squashfs layer with no `var/lib/dpkg/status` is accepted only if its exact
basename is listed here AND it actually contains the declared tree root
(`desktop-hotfix.squashfs` -> `opt/singularity`, the reviewed partial
Singularity overlay). Any other status-less layer still fails closed, and a
listed layer whose declared root is absent still fails.

The ledger remains **incomplete by design** for any *future* NCZ package not yet
reviewed: a finished image containing one fails the gate until it is added — a
deliberate guarantee that provenance is reviewed, never manufactured by hashing
whatever happens to be staged.

### CIX vendor debs

**Operator ruling 2026-10-10: the `cix-*` debs built for Debian 13 are the
reviewed VENDOR origin.** The original CIX proprietary `.deb`s (e.g.
`cix-gpu-umd`, `cix-ai-engine`, `cix-firmware`, and the CIX VA-API set
`cix-vaapi`/`cix-libva*`/`cix-libcme`) are **vendor** debs, not NCZ. They are
listed in `manifests/vendor-debs.tsv` by exact identity + version + arch with
the reviewed sha256; `docs/SOURCE-RELEASES.md` records that their source is the
vendor's and is not republished by NCZ. r203 adds the previously-unlisted CIX
VA-API / CME / libglvnd/libdrm rows. The NCZ-repacked `cix-*…+ncz*` DKMS debs
(`cix-npu-driver-dkms`, `cix-gpu-kmd-dkms`, `panthor-cix-dkms`,
`cix-vpu-driver-dkms`) are deliberately **not** here — they are NCZ builds in
`manifests/ncz-packages.tsv`, keeping repacked DKMS separate from unchanged
vendor originals.

## Apt source / pin allowlist

`manifests/vendor-repos.tsv` is the **complete** apt-source allowlist. Every
source line and deb822 source must match a row exactly on
`(scheme, host, path, suite)`. There is no host-only exception and no `*` suite
wildcard. Rows are:

* `debian-pin` — the build-time `snapshot.debian.org/archive/debian/<pin>`, suite
  `forky`, supplied by `release.conf` (BUILD reproducibility);
* `debian-live` — the installed system's runtime `deb.debian.org/debian` /
  `ftp.debian.org/debian`, suite `forky` (`release.conf` intentionally configures
  live runtime updates; the gate must not break them);
* `ncz` — the Buildkite Packages repo and the R2 fallback, exact URI + suite
  `any`;
* `vendor` — Chrome, Vivaldi, NVIDIA (approved). r203 additionally **approves**,
  with justification, the two previously-`pending` vendor *sources*:
  `apt.repos.intel.com/openvino ubuntu24` (Intel's own OpenVINO runtime; the
  `ubuntu24` suite token is Intel's ABI/compat label, not the Ubuntu archive) and
  `adityagarg8.github.io/t2-ubuntu-repo ./` (the t2linux project's T2
  firmware/audio vendor repo). Approving a SOURCE does not admit an Ubuntu
  *deb*: `classify()` still hard-rejects any Ubuntu-maintained or
  `ubuntu`-versioned package regardless of source, and the T2 packages install
  only on real T2 hardware at install time (they are not baked into the image).
  `build/test-no-ubuntu.sh` stays green (128/0).

Apt `Pin:` audit is semantic, not a growing deny-list: a `Pin:` with
`Pin-Priority >= 0` is allowed only if it is `origin <reviewed host>`, a
`release` pin whose `n=/c=/a=` is `forky` and whose `o=/l=` is Debian/NCZ, or a
`version` pin. Preferences files are split on `Package:` so records without a
blank line between them are still fully audited. Deb822 parsing is
case-insensitive and folding-aware; `.disabled` / `.dpkg-old` / `.bak` / `~`
files are ignored.

## Scanners fail closed

`--debs`, `--packages`, `--status`, `--rootfs`, `--squashfs` and `--image`
inputs fail closed on: a missing/empty requested pool or directory; a missing
or malformed control/status/Packages record (including a missing `Status:`); a
missing required tool; an unreadable or corrupt squashfs; an extraction or
listing failure; and a missing asset/vendor pool. A malformed record or an
absent input is never a silent skip.

`scan_image` confirms the actual image shape before requiring optional trees.
It recursively enumerates `/dists`, `/pool` and `/ncz-payload` with `debugfs
ls -p` **before** dumping, then asserts every enumerated path/type/size exists
in the extraction (a partial dump fails even though `rdump` leaves a directory
behind); debugfs's version banner is ignored and any other stderr line is a hard
failure for required trees. It scans the offline `/dists` (including compressed
`Packages` indexes) and `/pool`; requires the `rescue` and `mgmt` rootfs
tarballs; scans every asset/vendor pool present (`cix-debs`,
`ncz-screensavers-plugin`, `kernel`, `npu`, `debootstrap-udeb`, `ssh-udebs`);
and inspects the EFI System Partition for `/ncz/ssh-udebs`, failing closed if the
ESP is present but cannot be inspected. A boot initrd is magic-sniffed and its
concatenated cpio archives are parsed in-process (no filename guess); an
unrecognised format or trailing bytes fail closed. Optionally-present arch
trees are required only when the image actually enumerates them, avoiding
optional-architecture false positives.

## Local build mirrors

A local (`file:`/absolute) build mirror is accepted only after
`ncz_verify_local_mirror` runs `--verify-mirror`. That mode first verifies the
**independent upstream reference**: the signed `InRelease` for the committed pin
is fetched (or read from the verified cache) and gpgv-checked against the
committed keyring/digest, giving an authoritative `(name, version, arch) ->
sha256` map. It then reads the **candidate** mirror's own (possibly
regenerated, self-signed, subset) `Release`/`Packages` and authorizes every
listed package against that reference — or against a reviewed vendor/NCZ ledger
entry — never against the candidate's own metadata. Every referenced pool file
must exist and match its authorized sha256+size, and any orphan pool `.deb`/
`.udeb` not listed by a candidate index fails. A byte-identical full upstream
copy is accepted by the same path. A candidate `InRelease` identical to upstream
is **not** required; candidate metadata can be regenerated but cannot authorize a
package. A path name or a stamp is not proof.

## Offline (`file:`) sources and binding

A source line with a `file:`/absolute URI is accepted **only** for the reviewed
offline layout roots in `manifests/vendor-repos.tsv` (`offline` rows): the
installer data root `/cdrom` (suite `forky`) and the flat `/cdrom/ncz-payload/
apt-repo` (suite `/`). Matching is by **exact normalized path** against an
explicit policy row: a bound parent root never authorizes an unscanned child
(`file:///cdrom` does not admit `file:///cdrom/unscanned-repo`, whose own pool
was never authorized), and authority/query/fragment/`..` forms are rejected. An
arbitrary path fails. This models the installer's USB mount path only; there is
no persistent media repo or optical transport.

Beyond the path, the root must be **bound to content actually verified in the
same scan**. `scan_image` binds a root only after `authorize_pool` authorizes the
pool's own Packages index and referenced bytes against the already-authenticated
`Ref.idx` (the verified snapshot index) plus the reviewed vendor/NCZ ledgers —
after cryptographically authorizing the actual pool, not merely enumerating a
tree. `/cdrom` is the image data root (`dists`+`pool` at the partition root);
`/cdrom/ncz-payload/apt-repo` is a separate flat candidate pool (its `Packages`
may sit at the pool root). Every record must carry Filename/SHA256/Size whose
bytes match, the deb's control identity must match the record, filenames must
stay inside the pool (no absolute/`../`/symlink escape), and any orphan pool
`.deb`/`.udeb` fails. Missing, empty, partial, foreign or unapproved pools do
**not** bind, so a `file:` source referencing them fails closed. Binding happens
**before** any squashfs/rootfs apt-config audit and is cleared at the start of
each image and restored in `finally`, so one image's approved pool can never
authorize another image or a later standalone-rootfs scan. A standalone rootfs
has no binding and therefore rejects every `file:` source.

## Offline lint mode

`--ubuntu-only` (run by `build/check-no-ubuntu.sh` in `make lint-platform`) is a
separate, offline mode: no network, no snapshot index and no `forky-snapshot.tsv`
trust metadata. It still reads `release.conf` and the committed
`manifests/` ledgers/source allowlist, fails only on explicit Ubuntu evidence
(maintainer/version/os-release/sources), and reports `unchecked` for everything
else. It is refused together with `--image`/`--verify-mirror` so it can never
downgrade a shipping scan. The full gate always requires a verified index.

## Substrate vs snapshot — refreshed at every build (`manifests/base.pin`)

The finished image merges two Debian-derived trees into `/cdrom`:
`build/iso/write-usb-image.py` copies the offline apt closure (built by
`build/build-forky-mirror.sh` **from the pinned snapshot**, `NCZ_BASE_MIRROR`)
and then `copytree`s the pinned **netinst substrate's** udeb+deb pool over
`/pool`, regenerating only the d-i `Packages` index. The provenance gate
authorizes every package against the pinned snapshot. If the substrate's archive
state differs from the snapshot pin, the substrate's own `.debs` (orphan pool
files) and `.udebs` (not in the snapshot index) fail.

**Operator ruling (2026-10-10): the substrate must be refreshed to the newest
Debian testing netinst at EVERY build, and the snapshot must be DERIVED from
that same substrate — one archive state, three origins, no fourth origin.**

`build/refresh-substrate.sh --arch <a>` is the mechanical, reviewed step:
1. fetches the newest weekly netinst and `SHA256SUMS` + `SHA256SUMS.sign` from
   `cdimage.debian.org/cdimage/weekly-builds/<arch>/iso-cd`;
2. verifies the signature against the committed Debian CD signing key
   (`manifests/keys/debian-testing-cd-signing.gpg`, fingerprint
   `F41D30342F3546695F65C66942468F4009EA8AC3`, asserted) and the ISO sha256
   against the signed `SHA256SUMS` (**fails closed** on any mismatch);
3. caches the verified ISO on ARGONAS
   (`ncz-os-assets/substrate/`, keeping the last two per arch);
4. derives the snapshot by measurement (`build/derive-base-pin.py`): reads the
   netinst's own `Packages` identities from the ISO, tries candidate
   snapshot.debian.org timestamps around the netinst's Release date, and picks
   the one authorizing the most identities — measured across the codename's
   **full** index set **plus the same snapshot's `sid` debian-installer indexes**
   (see "The pinned snapshot index" above);
5. writes `manifests/base.pin` (arch, substrate sha256 + date, snapshot,
   measured coverage, source URL), then updates `release.conf`'s snapshot and
   records **both** suites' signed `InRelease` digests via
   `build/pin-snapshot-suites.sh` — pin, closure and trust digests move together;
6. **fails** if the substrate is older than `NCZ_SUBSTRATE_MAX_AGE_DAYS` (8) or
   if the best coverage is below `NCZ_SUBSTRATE_MIN_COVERAGE` (99).

`manifests/base.pin` is the single base pin. `build/check-substrate-pin.sh`
(and the build preflight) verifies that `release.conf`'s
`NCZ_BASE_MIRROR_SNAPSHOT` **equals** `base.pin`'s snapshot, that the substrate
is fresh, and that the recorded coverage meets the floor — so a build can never
ship a substrate the pinned snapshot does not authorize. The Makefile's
`SUBSTRATE_SHA` is **read from `base.pin`** (no separate literal to drift).

**Measured reality at r203 (fixed):** the freshest available netinst (weekly
`123a250b…` amd64 / `b6f455d1…` arm64, archive date 2026-10-05) is authorized at
**100.0 %** (amd64: 746/746, arm64: 734/734) by its own derived snapshot
`20261005T120000Z` once the gate reads the same snapshot's `sid`
debian-installer indexes. Before the di_suite fix coverage was 91.8 % / 90.7 %
(codename-only) — the residual was the substrate's d-i udebs (`*-modules-
7.2.9+deb14-*-di`, `apt-setup-udeb`, `dbus-udeb`, `fdisk-udeb`, …), whose
versions the netinst draws from `unstable`. They are the SAME pinned Debian
snapshot's d-i content, so no fourth origin and no newer weekly is needed. A
substrate whose d-i content is newer than any snapshot's d-i indexes still fails
loudly (exit 3) and lists the uncovered identities. The one-kernel ruling (ship
OUR kernel + an initrd built from our module set, stop merging Debian's
kernel/module udebs) additionally removes those udebs from the image — see
`docs/ONE-KERNEL.md`.

## Verification

All suites were run on the Linux validation host (ACHILLES, 192.168.207.11) from
a fresh clone of this branch at `5e9218df`, with the working tree byte-identical
to the author checkout (per-file sha256 compared) and `TMPDIR` on project ext4.

| Suite | Result |
|---|---|
| `build/test-no-ubuntu.sh` (isolated trust root + signed-index + real artifacts) | 118 passed, 0 failed |
| `build/lint-platform.sh` | OK (83 hooks, 2972 files) |
| `build/test-platform-lint.sh` | 37 passed, 0 failed |
| `build/test-release-identity.sh` | 31 passed, 0 failed |
| `build/test-sibling-mirror-apt-opts.sh` | 21 passed, 0 failed |
| `build/test-apt-separation.sh` | 66 passed, 0 failed |
| full `build/test-*.sh` sweep (104 suites) | 104/104 rc 0 (pre-cpio-fix; re-run before merge) |

The `test-no-ubuntu` fixture signs its own Release with a throwaway key and pins
that key/digest in an isolated copy of the trust metadata — the shipped verifier
has no fixture bypass. Positive and negative cases cover: signature/digest/
truncation/missing-index rejection, name-only and `+ncz` NCZ rejection, env
steering (`NCZ_APT_NCZ_HOSTS`, `NCZ_PROVENANCE_ROOT`, `HOME`), pool-byte
verification, strict pin parsing, URI query/credential/port/traversal rejection,
deb822 duplicate/empty/missing-`Types` rejection, duplicate pins, and
absent/empty/malformed debs/status/Packages.

Real artifacts (not hand-serialized) are exercised end to end:

* **squashfs** — `mksquashfs -processors 1` positive and corrupt negative.
* **initrd** — positive archives come from **GNU `cpio -o -H newc` / `-H crc`**
  (never a hand serializer), covering a bare `initrd` name, gzip/xz/zstd, two
  concatenated archives, a raw-newc + compressed-tail mix, and a valid `070702`
  crc archive; negatives mutate GNU output (path/symlink escapes, an unknown
  magic section, a corrupted crc) and must fail. The parser aligns by the TOTAL
  (header+pathname) offset and uses the additive `070702` checksum per GNU/FreeBSD
  `cpio(5)` semantics. Every archive must be terminated by a valid `TRAILER!!!`
  (a trailer-stripped or mid-stream-truncated archive fails); hard-link groups
  are resolved after the whole archive (GNU writes zero-size link records before
  the data member), keyed by `(devmajor, devminor, ino)` and **scoped per
  archive** so concatenated archives cannot copy earlier content forward; a
  valid empty (trailer-only) early archive is accepted. A duplicate pathname
  WITHIN one archive is malformed and fails; the SAME pathname in two
  CONCATENATED archives is normal initramfs override semantics, so the later
  copy is written to a distinct path and BOTH are scanned (no content is hidden,
  and every embedded .deb/.udeb is still classified). Compressed-tail staging is
  written to the caller's owned scratch, never the ambient `TMPDIR`.
* **finished `.img`** — a real GPT image built with `sfdisk` + `mkfs.ext4 -d` +
  `mkfs.vfat`/`mtools`, carrying `/dists`, `/pool`, `/ncz-payload` (squashfs +
  rescue/mgmt rootfs tarballs) and a FAT ESP with `/ncz/ssh-udebs/*.deb` and a
  gzip initrd, all with real `file:///cdrom` and `file:///cdrom/ncz-payload/
  apt-repo` apt config; scanned via `--image`. Positive: passes only because the
  pools authorize and bind. Negatives: tampered, partial, foreign/orphan and
  missing flat pools all fail closed. A per-image leak test proves the same
  `Ref` scanning a standalone rootfs afterwards does not inherit the binding. A
  fault-injection probe stubs the tool runner to drop a pool deb after `rdump`,
  and the pre-dump enumeration must catch it.
* **subset mirror** — a self-signed `build-forky-mirror.sh`-style mirror is
  authorized only against the independently verified upstream snapshot index;
  tampered pool, orphan deb and unauthorized package all fail.

`scan_image` recursively enumerates `/dists`, `/pool` and `/ncz-payload` with
`debugfs ls -p` **before** dumping, then asserts every enumerated path/type/size
exists in the extraction. debugfs's version banner is ignored; any other stderr
line is a hard failure for required trees. A partial dump therefore fails even
though `rdump` leaves a directory behind.

## External gates and blockers (not satisfiable in-repo)

1. **Production verification passed.** The committed upstream `InRelease`
   fixture passes the real Debian keyring/signature and digest checks offline.
   An independent Linux run also fetched and verified the actual pinned
   snapshot (`20261007T202437Z`, 107354 index entries), then checked both
   reviewed Vivaldi packages: 2 packages checked, 0 failures. This verifies
   snapshot compatibility; it does not accept any release image. (r203 re-pins
   the snapshot to `20261005T120000Z`; the same offline gpgv chain verifies its
   committed `InRelease` fixture -- `build/testdata/forky-snapshot/InRelease`,
   sha256 `436c53ff...`.)
2. **NCZ ledger coverage — CLOSED in r203** for the packages observed in the
   r202 images (see "NCZ ledger coverage (r203: populated)"). Any *future* NCZ
   package not yet reviewed still fails closed until it is added.
3. **Intel `ubuntu24` / t2linux vendor repos — APPROVED in r203** with
   justification (see the apt allowlist section); a package-level Ubuntu deb is
   still hard-rejected.
4. **Release-image acceptance remains separate.** The fixture suite exercises
   `--image` using a real, small GPT/ext4/FAT image and GNU-produced initrds.
   Neither release image has been rebuilt or accepted by this change. Both
   require complete reviewed input coverage, a rebuild against the re-pinned
   snapshot, and the full release gates. The residual substrate-vs-snapshot
   identities (see "Substrate vs snapshot") remain a genuine, listed failure.
