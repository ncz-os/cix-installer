# Native T2 forky — packaging authoring brief (A/B first)

**Date:** 2026-10-14 · **Status:** authoring brief, public-safe · **Baseline commit:** `fcd12094`
**Scope:** Debian *forky* native packaging only. No Ubuntu-built exception is assumed anywhere. Every
capability in the current install is *intended* to be reproduced (repackaged as binary where it is
binary-only); whether each is preserved is a **requirement** tracked per item below, not a claim — see the
evidence/status tables.
**Public-safety:** this document contains no LAN host/IP, no credentials, and no private evidence paths.
Revision/source claims are stated against **primary sources** (raw.githubusercontent.com, `git ls-remote`,
codeload) as pinned below; per-item status distinguishes **resolved**, **requirement**, and **blocked**.

> **Method note (why this brief exists).** Earlier research contained provenance defects: it inferred rights
> from unrelated files, treated a mutable *website URL* as an immutable source, and read a vendor `.deb` as
> proof of upstream rights. This brief pins **immutable** identities and only claims rights that the actual
> path-specific bytes support. Where rights are not declared on the path in question, the item is marked
> **BLOCKED (licensing)** rather than given an invented SPDX tag.

---

## 0. What ships today, and the native target

| Capability | Mechanism today (vendor) | Native forky target |
|---|---|---|
| T2 Wi-Fi/BT firmware | staged asset → `/lib/firmware/brcm/` | preserve (no packaging work) |
| T2 audio (ALSA UCM2) | `apple-t2-audio-config` deb (vendor) | **A** — rebuild from upstream source |
| `get-apple-firmware` fallback | `apple-firmware-script` deb (vendor, MIT) | **B** — rebuild from upstream source |
| Intel GPU VA-API / OpenCL / Level Zero | Debian forky native | preserve verbatim |
| OpenVINO GPU inference | Intel `ubuntu24` plugin | **C** — rebuild from OpenVINO source |
| OpenVINO NPU inference | Intel plugin; user driver absent from apt | **D** — build driver+compiler from source |
| NPU firmware | — | **D** — repackage binary (redistributable) |

**Ordering:** A and B are small, pure-data/pure-script packages with an immutable public source. Author them
first — they are independent of the heavy C/D work, and B can be authored now while **A remains blocked**
until path-specific rights exist, so **A cannot be landed while blocked**. C/D readiness is independent of A/B.

---

## A. `apple-t2-audio-config` — ALSA UCM2 profile

**Source (immutable):**
- Repo: `https://github.com/AdityaGarg8/t2bce`
- **Pinned commit:** `d493b0696b133ef2a3e2192790758180d62886b0` (verified live: this is `HEAD` = `refs/heads/main`)
- **Path:** `t2bce_audio-alsa-ucm-conf/ucm2`
- Raw URL template:
  `https://raw.githubusercontent.com/AdityaGarg8/t2bce/d493b0696b133ef2a3e2192790758180d62886b0/t2bce_audio-alsa-ucm-conf/ucm2/...`

**Producing recipe (upstream, for provenance):** `AdityaGarg8/t2-ubuntu-repo`
`.github/workflows/audio-new.yml` (verified): `git clone https://github.com/AdityaGarg8/t2bce.git` then
`cp -r t2bce/t2bce_audio-alsa-ucm-conf/ucm2 deb/usr/share/alsa`. Repo HEAD `699271d39382aebe8cd5de63dc492e1cfbbb7f50`.

**Package layout (author):** concrete packaging files to author —
`debian/control`, `debian/install`, `debian/changelog`, `debian/postinst`, and (only after rights resolve)
`debian/copyright`.
- `debian/control` → `Package: apple-t2-audio-config`, `Architecture: all`, `Depends:` (none — payload is plain
  ALSA UCM2 configuration text; no compiled code, no runtime deps), `Version: 0.5.3+ncz1`.
- `debian/install` → `ucm2/* usr/share/alsa/ucm2/`.
- `debian/postinst` → one-line "Restart to make the configuration files effective."
- Payload files are the six UCM2 text files: `AppleT2/HiFi-x{2,4,6}.conf` and
  `conf.d/AppleT2x{2,4,6}/AppleT2x{2,4,6}.conf`.

**Validation gates (A).**
- G-A1: source pinned to `d493b069…`, path `t2bce_audio-alsa-ucm-conf/ucm2`; per-file sha256 of the six UCM2
  files captured.
- G-A2: **apt simulation** (`apt-get install -s` of the produced deb against the forky snapshot) + **`lintian`**
  + **`dpkg`-level package audit** (file list, control correctness).
- G-A3: `UCM` validation — verify the installed UCM2 profile parses (`alsaucm`/`ucm` syntax check against a
  fixture tree), a **safe non-hardware** test; no audio hardware required.
- G-A4: rights gate — no `debian/copyright` authored and no SPDX tag assigned while **BLOCKED (licensing)**.

### A. Licensing — **BLOCKED (licensing)**, do not invent a tag

Primary-source findings (all verified against the pinned commit):

| Probe | Result |
|---|---|
| `t2bce@d493b069…/LICENSE` | HTTP **404** |
| `t2bce@d493b069…/COPYING` | HTTP **404** |
| `t2bce@d493b069…/LICENCE` | HTTP **404** |
| `t2bce_audio-alsa-ucm-conf/README.md` | 252 B — states the tree "mirrors the `alsa-ucm-conf` upstream layout … prepared as a separate upstream submission"; **no license statement** |
| `ucm2/AppleT2/HiFi-x2.conf` | **no `SPDX`/copyright/license header** (grep: none) |
| `kernel/Makefile` | `SPDX-License-Identifier: GPL-2.0-only` |

**Correction of the prior claim:** the `kernel/Makefile` `GPL-2.0-only` header is the license of the **T2BCE
kernel driver**, an *unrelated* subtree. It is **not** rights proof for the `ucm2/` data files. Likewise the
`ucm2/README.md` describes intent (a planned separate upstream submission) but conveys **no grant**. Upstream
ALSA `alsa-ucm-conf` is BSD-3-Clause — but that upstream license does **not** automatically transfer to this
forked, separately-prepared tree, and no such statement is made on the path.

> **Status: BLOCKED (licensing).** Until path-specific rights are established, do **not** assign an SPDX
> identifier, do not copy a copyright line, and do not ship a `debian/copyright` asserting a license.

**Exact next resolution steps (no maintainer contact performed by this author):**
1. Obtain a **path-specific** rights statement for `t2bce_audio-alsa-ucm-conf/ucm2` — either (a) a file-level
   grant/`LICENSE` added upstream at/after `d493b069…`, or (b) an explicit written grant from the copyright
   holder, or (c) authoritative evidence that the tree is a verbatim copy of an identified BSD-3-Clause
   `alsa-ucm-conf` revision (in which case record the exact upstream file→commit mapping per file).
2. Re-pin to the newer upstream commit that carries the grant; capture the new commit + per-file sha256.
3. Only then author `debian/copyright`. If (1) cannot be satisfied, the deliverable is the accurate **BLOCKED**
   state — that is a legitimate success outcome, not a failure to be papered over.

---

## B. `apple-firmware-script` — Wi-Fi/BT firmware fetcher (fallback only)

**Correction of the prior claim:** the prior research pinned the source as the *mutable website URL*
`https://wiki.t2linux.org/tools/firmware.sh` and quoted the **`deb`-payload** digest
(`b6b8729afe…`) as if it were the source digest. That conflates (i) a copy the repo mirrored into a `.deb`
with (ii) the upstream source. It also treats a *live page* as an immutable pin. Both are corrected here.

**Actual official source (verified):**
- The wiki at `wiki.t2linux.org` is served from the GitHub repo **`https://github.com/t2linux/wiki`**
  (Pages also lists it in the site's own links). Its `wiki` source tree — not the site root — holds the tool.
- **Immutable source of record:** repo `t2linux/wiki`, branch `master`,
  **commit `c16ca396f638727f943d577a24dcc0d7e5f0cdd8`**, path `docs/tools/firmware.sh`.
  - Raw URL:
    `https://raw.githubusercontent.com/t2linux/wiki/c16ca396f638727f943d577a24dcc0d7e5f0cdd8/docs/tools/firmware.sh`
  - **sha256 `c1c1d8aa25bb5f089e46ccd0d9738fc13bfbd784f499aa924466c690f059961e`** (31,831 bytes).
- **Live-served bytes match:** fetching `https://wiki.t2linux.org/tools/firmware.sh` returns **the identical
  sha256** (`c1c1d8aa…`) — so at audit time the live page and the pinned `master` source agree byte-for-byte.
- A second copy exists on branch `gh-pages` (`tools/firmware.sh`, 31,825 B, sha256 `568c0b1b…`); it is an
  **older/differing** revision (e.g. a "preceeded" typo and a `dnf` probe variant). **Do not pin `gh-pages`.**

**Baseline comparison (only where valid):** the prior `b6b8729afe3183378dee2f232f9311bad00d5e2646df280d0cbd3df22d58d0c6`
is the digest of the **installed payload copy** packaged in the 1.4-3 `.deb`, i.e. a mirrored snapshot — it is
**not** the upstream source digest and must not be presented as such. `b6b8729afe…` ≠ `c1c1d8aa…`: the
packaged copy and today's upstream source are **different bytes**. Pin the upstream source (`c1c1d8aa…`), and if
byte-identity with the shipped 1.4-3 payload is desired for continuity, verify that separately from the source.

### B. License — MIT (verify exact bytes at the pin)

The script carries an **in-file** MIT grant on the actual path: a `Copyright (C) 2024 …` block plus the MIT
permission/notice text, and a `# SPDX-License-Identifier: MIT` tag on a nested Python heredoc. This in-payload
grant is the rights basis for **this script**; re-confirm the exact bytes at the pinned commit before shipping
(do not reproduce the full license text here).

**Runtime dependencies (derived from the script itself, not assumed):**
- Interpreter/tooling: `bash`, `python3`.
- Python stdlib only: `logging`, `os`/`os.path`, `re`, `sys`, `pprint`, `statistics`, `tarfile`, `io`,
  `collections`, `hashlib`, `pathlib`.
- External CLI: `tar`, `install` (coreutils), `curl` (to fetch the firmware archive); `sha256sum` in one branch.
- Package-manager helpers invoked only for optional OS-package creation (`apt`/`dnf`/`pacman`) — not required
  for the default firmware-fetch path.
- **Declared Debian `Depends:` for the packaged fallback — verify against the actual code path, do not assume:
  `python3`, `curl`, `tar`, `coreutils`.** (Author must confirm the chosen default code path's tools and
  declare exactly those; drop nothing the path needs, claim nothing it does not.)

**Package layout (author):** `Architecture: all`, install to `/usr/libexec/get-apple-firmware` with an
`/usr/bin/get-apple-firmware` symlink; `debian/copyright` = the MIT text as carried in-file. Concrete
packaging files to author: `debian/control`, `debian/install`, `debian/copyright`, `debian/changelog`.
Function is a contingency fallback; primary firmware ships as the staged asset.

**Versioning note (new upstream bytes).** The pinned upstream source (`c1c1d8aa…`) differs from the bytes
packaged in the shipped 1.4-3 `.deb` (`b6b8729afe…`). Because the build will package **new upstream bytes**,
either (a) use a date-based distinct version, or (b) record **version-choice-pending** until the
bytes-vs-payload relationship is decided. Do **not** reuse `1.4-3+ncz1` as though the payload were unchanged.

**Feature-continuity gate (B).** The new source is **not** byte-identical to the old payload, so a
`diff` review of the new script against the shipped 1.4-3 payload is a required gate before the fallback is
accepted as feature-continuous — differences must be reviewed and listed, not assumed benign.

**Validation gates.**
- G-B1: source pinned to `docs/tools/firmware.sh @ c16ca39…`; sha256 `c1c1d8aa…` re-confirmed; MIT in-file text
  present at the pin.
- G-B2: new source vs. shipped 1.4-3 payload `diff` reviewed and recorded (feature-continuity).
- G-B3: declared `Depends:` match the default code path's actual tools (audit, not assumption).
- G-B4: **safe non-hardware syntax/fixture test** — `bash -n` syntax check plus a fixture run with the network
  fetch stubbed (no real download, no firmware extraction, no installer execution).

---

## C. OpenVINO GPU + NPU plugins (heavy item)

**Source (immutable, official):**
- Repo: **`https://github.com/openvinotoolkit/openvino`** (this is the official project; a probe of a
  differently-named org is not evidence about this project).
- Tag `2026.4.1` → **commit `e213a14725769a6a2bf86fc86650aa78a9c05d3e`** (verified `git ls-remote --tags`).
  Repo `HEAD` at audit = `7daf4c7d3731a46fa7e38742ed58943388a1ac46`.
- License: **Apache-2.0** (`LICENSE` @ `e213a147…` HTTP 200; sha256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`).
- Public submodules (`.gitmodules` @ `e213a147…`): oneDNN, xbyak, zlib, pugixml, gflags, gtest, OpenCL
  ICD-Loader/Headers/CLHPP, onnx, protobuf, pybind11, ittapi, plus intel_gpu oneDNN(dnnl_gpu). All public.
- No upstream `debian/` directory — the plugins are built with CMake; the deb packaging is Intel's. This is the
  crux of the remaining build work.

**Runtime deps (forky-satisfiable, retained):** `libc6 (>= 2.38)`, `libgcc-s1 (>= 3.4)`, `libstdc++6 (>= 12)`,
`libtbb12 (>= 2021.4.0)`, `libzstd1 (>= 1.5.5)` (NPU), `ocl-icd-libopencl1` family.

**Build-time deps (enumerate from upstream `install_build_dependencies.sh`, present HTTP 200 @ `e213a147…`;
MUST be checked against the forky snapshot):** `cmake`, `ninja-build`, `build-essential`, `ccache`, `git-lfs`,
`libpython3-dev`, `libtbb-dev`, `libva-dev`, `ocl-icd-opencl-dev`, `libpugixml-dev`, `libsnappy-dev`,
`libffi-dev`, `nlohmann-json`/`nlohmann-json3-dev`, `flatbuffers-dev`, `lintian` (+ OpenCV/oneDNN/onnx via
submodules).

**Recipe shape (author):** CMake Release build with `-DTHREADING=TBB -DENABLE_INTEL_GPU=ON -DENABLE_INTEL_NPU=ON
-DENABLE_INTEL_NPU_PROTOPIPE=ON …`, wrapped by a `debian/` producing `libopenvino-2026.4.1`,
`libopenvino-intel-gpu-plugin-2026.4.1`, `libopenvino-intel-npu-plugin-2026.4.1` with the same `Depends:` as
Intel's debs. **Do not** relabel Intel's `ubuntu24` (`Codename: noble`) binaries as forky.

**Test gates specific to C:**
- G-C1: source pinned to `e213a147…`; `LICENSE`/`.gitmodules` fetched from that exact commit.
- G-C2: every build-time dep resolves on the forky snapshot; record versions, or record the missing ones
  (a missing dep is a **finding**, not a reason to import a non-forky package).
- G-C3: produced binaries link only to forky-provided runtime libs (re-derive with `dpkg-shlibdeps`); diff
  against Intel's declared `Depends:`.
- G-C4: deb names/versions match Intel's series (`2026.4.1`) so on-device expectations hold.

---

## D. Intel NPU user driver + compiler + firmware

**Source (immutable):** repo **`https://github.com/intel/linux-npu-driver`**, tag `v1.38.0` →
**commit `aea583dcd86a4723a8d3bb06ad94b6eb2f80c6f2`** (repo `HEAD` = `c2e2788afac6d7f1b3d7585440bf8137a3ce89c1`).
License **MIT** at `LICENSE.md` (note the filename is `LICENSE.md`; `LICENSE`/`LICENCE` 404s are a filename
miss, not an absence of license; sha256 `451963b6682694730dbe4889fff2ef1c20def68992e2594880c15a28e6c87be5`).

**In-tree native Debian recipe (upstream-provided):** `cmake/packaging/setup.cmake` selects `PACKAGE_TYPE deb`
when `/etc/debian_version` exists, with components `driver-compiler-npu`, `fw-npu`, `level-zero-npu`
(and `validation-npu`); `cmake/packaging/generators/deb.cmake` sets `CPACK_GENERATOR DEB`,
`CPACK_DEB_COMPONENT_INSTALL ON`, `CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON`. On forky this is essentially
`cmake … && cpack -G DEB` (plus submodule fetch).

### D.1 Compiler — **RESOLVED (exact public pin); build feasibility UNTESTED**

`compiler/compiler_source.cmake` @ driver `aea583dc…`
(sha256 `56c4872aff7602f208f7d561bcd5f253261afbfa35f397c8deb6527844c0b79a`) sets:

- **`GIT_REPOSITORY https://github.com/openvinotoolkit/npu_compiler.git`** ← the actual compiler source
- `NPU_COMPILER_TAG npu_ud_2026_38_rc1`
- `NPU_COMPILER_REVISION 0b38f7d42113ff329ac2bdd33583d123de4ccf2f`
- `OPENVINO_REPOSITORY https://github.com/openvinotoolkit/openvino.git`,
  `OPENVINO_REVISION 759c5a6ab8c066af5f4bc5ebd04643706012a37d` (**= public tag `2026.3.1`**, verified)
- `NPU_COMPILER_OPENVINO_REVISION d8047fb380b27a9d5827cb3f22aec7781ae5ac82`
- `OPENCV_REVISION 8ec62ad3460fd4f371000157cf98cccaaa933303`, `GENAI_REVISION 56d9685302da2fc5cc7c9689cfab500fd0660a02`,
  `ONNXRUNTIME_TAG/RUNTIME_REVISION da9b5e3`

**Correction of the prior claim.** A prior revision of this brief recorded a **"SOURCE GAP"** here. That was
**wrong**: it probed the wrong repository. `openvinotoolkit/npu_compiler_elf` is *not* the compiler source —
it is a **nested dependency** (see below), so its tag list (ending at `npu_ud_2026_28_rc2`) says nothing about
the compiler pin. Probing `npu_compiler_elf` and concluding the compiler tag was "absent" conflated a
submodule with the parent project.

**Independent primary-source verification of the correct repo `openvinotoolkit/npu_compiler`**
(`git ls-remote` on 2026-10-14):
- `refs/tags/npu_ud_2026_38_rc1` → **`5c550fafddefe29ac4b5ca0afa62679be751fd80`** (annotated tag object)
- `refs/tags/npu_ud_2026_38_rc1^{}` → **`0b38f7d42113ff329ac2bdd33583d123de4ccf2f`** (peeled exact commit —
  byte-identical to the driver's `NPU_COMPILER_REVISION`)

At the **exact revision `0b38f7d4…`** (raw.githubusercontent.com):
- `LICENSE` → HTTP **200**, 11,351 B, sha256 `9ae406b07d50d65dcdae0de9286c0a56f52f5159d7f4df05a345409be8cd262c`
  — **Apache License 2.0** (README states "licensed under Apache License Version 2.0").
- `README.md` → HTTP 200, 3,768 B, sha256 `b5b034fbfd5d6cc1ca00c27af2659cce0076a3a1d0d1f47cb01f034e9a30fb32`.
  (`LICENSE.md`/`LICENCE` → 404 at this rev; the file is plain `LICENSE`.)

**Nested dependency closure (partially inspected — NOT a full closure claim).** `.gitmodules` at `0b38f7d4…`
declares: `thirdparty/llvm-project` → `intel-staging/npu-compiler-llvm` (shallow), `thirdparty/vpucostmodel` →
`intel/npu-nn-cost-model`, `thirdparty/gtest-parallel` → `google/gtest-parallel` (shallow), and
`thirdparty/elf` → **`openvinotoolkit/npu_compiler_elf`** (the repo wrongly probed before — it is a
*submodule*, not the compiler). `compiler_source.cmake` additionally requires **git-lfs** for the compiler
tree and for `thirdparty/vpucostmodel`. **Honest limit:** the *exact submodule revisions* and the **LFS object
closure at `0b38f7d4…` have not been enumerated/checked**, so no full-closure claim is made; that enumeration
is a gate below (G-D2).

**Status: D compiler = RESOLVED to an exact public compiler pin** (repo + annotated tag + peeled commit +
Apache-2.0 LICENSE at that rev), **but build feasibility is still UNTESTED** — no build was run, and
submodule/LFS closure is unverified. Do **not** substitute a different revision; do **not** claim the compiler
builds until the gates below pass.

### D.2 Firmware — binary redistribution (distinct from the compiler question)

`firmware/bin/vpu_{37,40,50}xx_v1.bin`; `firmware/bin/COPYRIGHT` (sha256 `a16ec0f901f841db9badea5f1c23ca3d806a67028e751e7dfe3eab4131b8cb03`)
is Intel's **binary redistribution** license (redistribute-in-binary-form permitted; **no reverse
engineering/decompilation/disassembly**). **Disposition: repackage the binary** (component `fw-npu`),
**never rebuild**. This is a licensing constraint on a redistributable artifact — a **separate** matter from
the compiler pin in D.1; keep the two separate in all reporting.

**Test gates specific to D:**
- G-D1: driver pinned to `aea583dc…`; `LICENSE.md` fetched from that commit.
- G-D2: compiler pins to the **correct repo** `openvinotoolkit/npu_compiler` at exact commit `0b38f7d4…`
  (annotated tag `5c550faf…`), `LICENSE` (Apache-2.0) and `README.md` fetched from that exact revision; the
  **submodule revisions and git-LFS object closure at that commit enumerated** (report checked vs. unchecked
  paths) — full closure is **not** claimed until this gate passes.
- G-D3: firmware repackaged verbatim with `firmware/bin/COPYRIGHT` shipped; **no rebuild**, no modification.
- G-D4: re-derive runtime `Depends:` with `dpkg-shlibdeps`; confirm Level Zero (`libze1`/`libze-dev`) source is
  forky-native.
- G-D5 (packaging validation, non-hardware): `apt-get install -s` simulation against the forky snapshot of the
  produced `driver-compiler-npu`/`fw-npu`/`level-zero-npu` debs; `lintian` on each; `apt-get`-level dependency
  audit; and a safe syntax/fixture test (see the A/B validation gates for the shared harness).

---

## E. Already-native (no work; preserve verbatim)

Level Zero, Intel GPU compute runtime, media VA driver, TBB, ocl-icd, zstd, dmg2img — Debian forky native,
pinned to Debian origin. Preserve as-is.

---

## Consolidated source pins

| Item | Repo | Immutable identity | sha256 / notes |
|---|---|---|---|
| A | `AdityaGarg8/t2bce` | commit `d493b0696b133ef2a3e2192790758180d62886b0`, path `t2bce_audio-alsa-ucm-conf/ucm2` | **BLOCKED (licensing)** — no path-specific grant |
| B | `t2linux/wiki` | commit `c16ca396f638727f943d577a24dcc0d7e5f0cdd8`, path `docs/tools/firmware.sh` | source sha256 `c1c1d8aa…`; MIT (in-file) |
| C | `openvinotoolkit/openvino` | commit `e213a14725769a6a2bf86fc86650aa78a9c05d3e` (tag `2026.4.1`) | Apache-2.0 |
| D | `intel/linux-npu-driver` | commit `aea583dcd86a4723a8d3bb06ad94b6eb2f80c6f2` (tag `v1.38.0`) | MIT (`LICENSE.md`) |
| D-compiler | **`openvinotoolkit/npu_compiler`** | tag `npu_ud_2026_38_rc1` (annotated `5c550faf…`) → exact commit `0b38f7d42113ff329ac2bdd33583d123de4ccf2f` | **RESOLVED** public pin; Apache-2.0 `LICENSE` @ rev; build feasibility **untested** |
| D-helper | `openvinotoolkit/npu_compiler_elf` | submodule `thirdparty/elf` of the compiler | **separate** nested dep — *not* the compiler source |

## Status summary

- **A** — authorable; **BLOCKED (licensing)** until path-specific rights exist. Accurate BLOCKED is a valid
  outcome. Not "landable" in the blocked state.
- **B** — authorable now; source pinned, MIT in-file, deps to be audited. New upstream bytes ≠ shipped payload
  → version choice date-based or pending; feature-continuity `diff` gate required.
- **C** — source/license/runtime resolved; open work = forky build-time deps + authoring `debian/`.
- **D** — driver authorable; **compiler RESOLVED to an exact public pin** (correct repo `openvinotoolkit/npu_compiler`);
  build feasibility **untested**; submodule/LFS closure **not** fully checked; firmware repackage-only.
  (`npu_compiler_elf` is a separate nested dependency.)

No Ubuntu repository or Ubuntu-compiled deb payload is used as a source for any item. No capability is
*asserted* preserved — per-item preservation is a requirement tracked by the gates above; the verification
record backing the claimed pins is retained outside this repository.
