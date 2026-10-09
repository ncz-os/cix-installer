# OpenVINO vendor APT decision, 2026-10-09

Operator decision: use APT if the actual Intel packages have no Ubuntu-only
prerequisites; otherwise consider the official archive or PyPI installers.
The condition is satisfied for the THREE amd64 OpenVINO vendor packages listed
in `manifests/vendor-debs.tsv`, version **2026.4.1.22982**. This is NOT approval
for arbitrary Ubuntu debs, Ubuntu archive sources, or all Intel packages.

## Direct evidence

Verified in the owned Debian Forky build container on HYDRA, not on PROTEUS or a
live installed system. Local receipts are under
`/Users/jasonperlow/Projects/ncz-r201-direct-build-evidence-20261009/logs/`.

- `intel-signed-index.log`: Intel InRelease signature valid, RSA key
  BAC6F0C353D04109, using the committed signing key whose sha256 is
  `db932ba032a71f732dc415eef5f4f185fc7ae768487d7a357bc2772746b6c48c`.
- Signed `ubuntu24/main/binary-amd64/Packages.gz` sha256:
  `9d3c5613361b10ee87191431533f187d882c03f725946ec42b63fff7a83a91f7`.
  Each actual deb matches its signed index identity, size and hash.
- `intel-forky-closure.log`: APT simulation succeeds with zero removals using
  ONLY the pinned Debian Forky source and the three exact local Intel debs.
  No Intel repository or Ubuntu prerequisite repository was enabled during
  this dependency-isolation check.
- `intel-real-install.log`: actual APT installation and configuration succeeded.
  The command wrapper's later diagnostic had a quoting error; its nonzero exit
  is NOT an installation success receipt on its own.
- `intel-installed-link-check.log`: corrected independent dpkg status check
  reports all three as installed. Core/C API/GPU/NPU/compiler dependencies link
  with the Forky libraries; NPU VM runtime initially lacked the Level Zero loader.
- `intel-level-zero-check.log`: Debian Forky `libze1` **1.32.0-1** supplies that
  loader, and the NPU VM runtime then has no missing linked library.
- `intel-production-helper-pass2.log`, exit 0: the changed production helper
  itself performs real signed-repository APT downloads, verifies the exact three
  deb hashes and identities, simulates zero removals and finishes real APT
  installation successfully. Linking is rechecked with no missing dependency.
  Its first attempt exposed an inherited `set -e`/zero-match grep bug, corrected
  and covered by strict-shell installation and network-retry regression tests.

Other observed Forky prerequisites include `libtbb12` 2023.1.0-3,
`libzstd1` 1.5.7+dfsg-4 and `ocl-icd-libopencl1` 2.3.4-1+b1.
Forky snapshot: `20261007T202437Z`, signed InRelease sha256
`4e61d52206993ceda46a6db6b7fbf8882a57dba3c87542b295c31213950aee4e`.

## Enforced boundaries

`intel-accel.sh` requests the fixed package version through APT, downloads it
through the signed repository, verifies exact control identity and independent
committed sha256, then simulates and installs ONLY those verified local debs.
Temporary download files are removed on normal success and failure paths.
Download/network failures remain deferred; bad identity/hash is a permanent
refusal. Existing Debian runtime seeding and zero-removal checks remain intact.

APT preferences admit only the exact three package names at the reviewed
version. Other versions of those names and every other Intel-origin package are
negative-pinned. The same protection is written by the shared installer helper
for older installed systems and by `ncz-apt-policy` **1.0.3** for new images.
The vendor-source ledger approval is the exact Intel URI/suite tuple, not a
host-only or suite-name-only exception.

These checks demonstrate package and loader compatibility, NOT inference or
hardware acceptance. The separately distributed Intel NPU user-mode driver is
not approved or installed by these rows. No PROTEUS changes, fleet reboots,
image shipping, tags, flashes or live NCZ APT publication are authorized here.

## Alternative methods

Intel documents the [archive installer](https://docs.openvino.ai/2026/get-started/install-openvino/install-openvino-archive-linux.html)
and [PyPI installer](https://docs.openvino.ai/2026/get-started/install-openvino/install-openvino-pip.html).
They remain alternatives, not a reason to discard the directly tested APT
route. No automatic fallback installs a second OpenVINO copy into the image.
