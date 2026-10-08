# Forky provenance gate — policy and design

Operator rule (2026-10-08): *"We shouldn't be using Ubuntu debs ever"*, and every
package in an NCZ-OS image must be traceable to exactly one reviewed origin:
an NCZ build, an explicitly reviewed vendor deb, or the pinned Debian **forky**
snapshot — byte-identical where bytes exist.

This document is the policy of record for `build/check-forky-provenance.sh` /
`build/forky-provenance.py` and for `build/check-no-ubuntu.sh` (the offline
Ubuntu-evidence-only gate that runs in `make lint-platform`).

## Trust root

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

* `snapshot` = the `snapshot.debian.org` timestamp (`20261007T202437Z`);
* `inrelease_sha256` / `inrelease_size` = the reviewed digest of the signed
  `dists/<codename>/InRelease` for that snapshot;
* `keyring` / `keyring_sha256` = the Debian archive keyring and its reviewed
  digest (`manifests/keys/debian-archive-keyring.gpg`);
* `signer_keys` = the Debian archive signing key fingerprints gpgv must report.

`release.conf`'s `NCZ_BASE_MIRROR_SNAPSHOT`/`NCZ_BASE_CODENAME` must equal the
trust metadata or the gate exits 2. The index directory itself may live
anywhere (`--index-dir`), because its **contents** are verified:

1. `gpgv --keyring <committed keyring>` verifies the `InRelease` clearsignature,
   and the reported signer must be one of the pinned Debian keys;
2. the `InRelease` bytes must equal the committed `inrelease_sha256`/size;
3. the signed Release's `SHA256:` section supplies the sha256+size of every
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

### Open blocker — NCZ ledger coverage

The following NCZ packages ship but are **not** yet in the ledger, so the gate
hard-fails on them until they are reviewed and added (this is the intended
fail-closed behaviour, not a bug):

* `ncz-apt-policy`, `ncz-screensavers-plugin`, `ncz-agent-*` and other `ncz-*`
  agent/policy debs — no committed reviewed sha256 + build-source record found;
* `chromium-ncz-*`, `ncz-ffmpeg`, `ncz-singularity-desktop`, `zoder`,
  `ncz-intel-accel` and the CIX-repacked GPU/VPU DKMS debs — build outputs exist
  only on the build hosts and are not pinned in `manifests/build-inputs.tsv`.

Each must be added with its recipe and reviewed sha256 (or the build-input pin
extended). Until then, a finished image containing them fails the gate — a
deliberate guarantee that provenance is reviewed, never manufactured by hashing
whatever happens to be staged.

### CIX vendor debs

The original CIX proprietary `.deb`s (25 in `sbom/expected-assets.txt`, e.g.
`cix-gpu-umd`, `cix-ai-engine`, `cix-firmware`) are **vendor** debs, not NCZ.
They are listed in `manifests/vendor-debs.tsv` by exact identity with the sha256
from `sbom/expected-assets.txt`; `docs/SOURCE-RELEASES.md` records that their
source is the vendor's and is not republished by NCZ. The NCZ-repacked
`cix-npu-driver-dkms …+ncz3` is deliberately **not** here — it is an NCZ build in
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
* `vendor` — Chrome, Vivaldi, NVIDIA (approved); **Intel `ubuntu24` and t2linux
  are `pending` and fail closed until the operator approves them — approval is
  not invented here.**

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
  valid empty (trailer-only) early archive is accepted; duplicate pathnames
  across sections fail. Compressed-tail staging is written to the caller's owned
  scratch, never the ambient `TMPDIR`.
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
though `rdump` leaves a directory behind. The one tolerated stderr line is the
exact non-root `rdump` warning `... Operation not permitted while changing
ownership` (a non-root scan cannot chown dumped files); it is accepted **only**
for `rdump`, never changes the type+size completeness proof above, and a
different-worded error on the same command still fails closed.

### Architecture-neutral archive handling (safe virtual archive root)

A finished image legitimately contains absolute *symlink targets* that name a
path inside the archive's own virtual root, not a host path: the installer
initrd's `etc/mtab -> /proc/mounts`, and a usrmerge rootfs's `var/run -> /run`
and `var/lock -> /run/lock`. The scanner accepts these (they were false
positives) while never following them onto the host:

* **cpio**: an absolute symlink target is validated against the virtual root and
  is recorded but **never materialised**, so nothing can be written through it.
* **tar**: an absolute symlink target is rewritten to the equivalent *relative*
  link inside the extraction root before materialising, so a later member cannot
  be written onto the host; a relative target that climbs above the root, an
  absolute member path, an absolute/`..`-climbing hard-link and a duplicate
  cpio pathname all still fail closed.

### A no-dpkg squashfs layer is a hard failure (no blanket overlay bypass)

`desktop-hotfix.squashfs` is a real overlay delta with no `var/lib/dpkg/status`.
It is **rejected by default**: a layer with no dpkg database cannot establish
package origin, and accepting it merely because it lacks an `etc/apt`/`.deb`
surface would let a foreign ELF overlay override a packaged base with no content
binding -- a policy relaxation the operator never approved. To pass, such a
layer must be bound to an **external, committed** overlay-source manifest/hash
(the existing `build_hotfix` source with exact file coverage), and that binding
does not exist yet. Until it does, this layer is an explicit, fail-closed
blocker. A self-written `.overlay-manifest` carried inside the image is NOT a
trust root (the image owner can rewrite it) and is not accepted.

### Tar shadow check

Within the extraction root, tarfile could otherwise let a later member overwrite
an earlier mapped file at the same path (e.g. `var/lib/dpkg/status`). The tar
extractor now rejects a duplicate normalized member path when it would shadow
earlier content. Legitimate usr-merge symlinks (`lib -> usr/lib`) and pure data
hard-links have distinct names and are unaffected. (The residual, ambiguous
case is a symlink *alias* that maps a later path onto an earlier one; strict
root confinement keeps it inside the scratch root, and it is reported as a
limited blocker rather than guessed at.)

## NCZ derivative packages (debootstrap-udeb)

`build/iso/patch-debootstrap-stub.py` derives Debian's `debootstrap-udeb` (the
d-i package that runs `debootstrap`) into an NCZ artifact. The old repack kept
Debian's `Package`/`Version` while replacing `/usr/sbin/debootstrap`, so the
scanner saw "same name/version as forky but sha256 differs (rebuilt/foreign
bytes)" -- correct, because the bytes are no longer Debian's. The derivative
contract now:

* `Version` becomes `<base>+ncz1` (deterministic; never byte-identical to the
  pinned snapshot entry) and the control records the **authenticated** base
  sha256 (`NCZ-Base-SHA256`, which the consumer verified against the signed
  snapshot index) and the exact stub recipe hash (`NCZ-Recipe-SHA256`);
* `Package: debootstrap-udeb` and `Architecture: all` are preserved so d-i's
  dependency resolution is unaffected and no architecture-specific bytes enter a
  common package (a non-`all` base is refused);
* the packaging is byte-reproducible (Python deterministic tar/gzip and `ar`
  writers; `SOURCE_DATE_EPOCH` defaults to 0), so the same inputs always produce
  the same sha256;
* the consumer `build/build-installer-image.sh` fetches the base through
  `build/iso/fetch-pinned-debootstrap-udeb.py`, which resolves it from the
  **pinned signed snapshot** (same trust root as the scanner) and never from a
  live `deb.debian.org` forky index.
* The derivative must be added to `manifests/ncz-packages.tsv` (name, version
  `1.0.145+ncz1`, arch `all`, its sha256, recipe `build/iso/patch-debootstrap-stub.py`,
  source revision, note) once built; the control fields are audit evidence, NOT
  a self-blessing authorization -- the scanner still requires the reviewed
  ledger row, exactly like every other NCZ package.

## External gates and blockers (not satisfiable in-repo)

1. **Production verification passed.** The committed upstream `InRelease`
   fixture passes the real Debian keyring/signature and digest checks offline.
   An independent Linux run also fetched and verified the actual pinned
   snapshot (`20261007T202437Z`, 107354 index entries), then checked both
   reviewed Vivaldi packages: 2 packages checked, 0 failures. This verifies
   snapshot compatibility; it does not accept any release image.
2. **NCZ ledger coverage.** `ncz-apt-policy`, `ncz-screensavers-plugin`,
   `ncz-agent-*`, `chromium-ncz-*`, `ncz-ffmpeg`, `ncz-singularity-desktop`,
   `zoder`, `ncz-intel-accel` and the CIX-repacked GPU/VPU DKMS debs have no
   committed reviewed sha256 + source revision. A finished image containing them
   fails until they are reviewed and added (or `manifests/build-inputs.tsv` is
   extended).
3. **Intel `ubuntu24` / t2linux vendor repos** are marked `pending`; the gate
   fails closed on them until the operator approves the exact URI+suite.
4. **Release-image acceptance remains separate.** The fixture suite exercises
   `--image` using a real, small GPT/ext4/FAT image and GNU-produced initrds.
   Neither release image has been rebuilt or accepted by this change. Both
   require complete reviewed input coverage and the full release gates.
