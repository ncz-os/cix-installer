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
DKMS (`packaging/cix-npu-driver-dkms-6.2.0`), and from the r201 built payloads
whose bytes are held on a canonical ARGONAS store and were independently
sha256-verified (`ncz-singularity-desktop`, `ncz-screensavers-plugin`; source
revision bound to the `singularity-opt.tgz` content digest +
`assets/singularity/upstream-pins.tsv`, and to the `ncz-screensavers` plug-in
commit). It is **incomplete by design**: it lists only entries whose reviewed
bytes exist today.

### Open blocker — NCZ ledger coverage

The list below is the **actual** shipping set from the read-only strict-gate
inventory of the r201 `ba426921` images (clean `e478a5d5` trust root), not a
policy name list. These identities ship and are not yet in the ledger, so the
gate hard-fails on them until reviewed and added (intended fail-closed
behaviour, not a bug):

* **Built, non-live, proof incomplete** — `ncz-apt-policy 1.0.1 all`,
  `ncz-usb-recovery 1.2 arm64`, and the CIX-repacked `cix-gpu-kmd-dkms
  1.0+ncz2 all`, `panthor-cix-dkms 7.2.0+ncz2 all`, `cix-vpu-driver-dkms
  1.0.2-ncz1+ncz2 all`. Bytes exist on the non-live ARGONAS staging store
  (`ncz-package-staging/r201-e478a5d5-20261008`); the build's dependency
  universe is not yet cryptographically bound to the pinned snapshot, so the
  rows are **withheld** until the authenticated rebuild completes and is
  independently verified (see the cheap-package verification receipt).
* **Ships, no canonical build record / bytes** — arm64 `ncz-ffmpeg 9.0.1-ncz3`,
  arm64 `chromium-ncz-sky1 154.0.8037.0-ncz20260907`, arm64
  `libgtk4-layer-shell0 1.3.0-1+ncz20260925`, and the older `libdrm2` /
  `libdrm-common 2.4.134-3+ncz1` still present in the r201 desktop-mirror pool.
* **Ships, no ledger row yet** — `ncz-wallpapers-cygnus-2610 1.1 all` (both arches).
* **Kernel / boot input provenance (image-input work, distinct from the
  current-kernel-warning followup)** — amd64
  `linux-image-7.3.0-rc6-4-t2-edge-aer9010` and `linux-headers-…` `7.3.0-rc6-4`;
  arm64 `linux-image-cixmini` / `linux-headers-cixmini 7.3.0-rc6-sky1-ncz+r285`
  and `cixmini-boot 1.2+r285`.
* **Additional CIX names that ship** — beyond the ledgered
  `cix-npu-driver-dkms 6.2.0-…+ncz3`, the images also carry `cix-vaapi 1.0.0`,
  `cix-libcme 1.0.0` and `cix-libva2 2.2.1-1` (arm64); classify vendor-vs-NCZ
  before adding.

Not ledger blockers (correcting an earlier framing — do not list these as
shipped-but-unpinned):

* `ncz-agent-*` and `zoder` are **absent from both r201 images**; no canonical
  deb artifact exists, so there is nothing to pin. (`zoder` ships as a tarball,
  `zoder-0.2.1`, not a deb, and is not in this repo's deb namespace.)
* `ncz-intel-accel` is **not a deb**: it is a userspace setup service plus
  `assets/intel` keying. The Intel OpenVINO plugin is instead supplied by the
  `pending` `apt.repos.intel.com/openvino` (`ubuntu24`) vendor repo (item 3 below).

Reviewed r201 entries added 2026-10-08, for the exact debs the gated images
install, are excluded from the list above: `ncz-singularity-desktop`
(amd64/arm64) and `ncz-screensavers-plugin` (amd64/arm64).

Each remaining package must be added with its recipe and reviewed sha256 once
its bytes exist on a canonical store (or the build-input pin extended). Until
then, a finished image containing them fails the gate — a deliberate guarantee
that provenance is reviewed, never manufactured by hashing whatever happens to
be staged.

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
though `rdump` leaves a directory behind.

## External gates and blockers (not satisfiable in-repo)

1. **Production verification passed.** The committed upstream `InRelease`
   fixture passes the real Debian keyring/signature and digest checks offline.
   An independent Linux run also fetched and verified the actual pinned
   snapshot (`20261007T202437Z`, 107354 index entries), then checked both
   reviewed Vivaldi packages: 2 packages checked, 0 failures. This verifies
   snapshot compatibility; it does not accept any release image.
2. **NCZ ledger coverage.** The r201 `ba426921` images fail the strict gate on the
   actual shipping identities listed under "Open blocker — NCZ ledger coverage"
   above (the five built-but-unauthenticated cheap debs, arm64
   ffmpeg/chromium/gtk4-layer-shell, `ncz-wallpapers-cygnus-2610`, the kernel/boot
   set, and the additional CIX names). `ncz-singularity-desktop` and
   `ncz-screensavers-plugin` are now covered (r201 entries, 2026-10-08).
   `ncz-agent-*` and `zoder` do **not** ship and `ncz-intel-accel` is not a deb, so
   they are not ledger blockers.
3. **Intel `ubuntu24` / t2linux vendor repos** are marked `pending`; the gate
   fails closed on them until the operator approves the exact URI+suite.
4. **Release-image acceptance remains separate.** The fixture suite exercises
   `--image` using a real, small GPT/ext4/FAT image and GNU-produced initrds.
   Neither release image has been rebuilt or accepted by this change. Both
   require complete reviewed input coverage and the full release gates.
