# NPU Debian Publication Blockers — Fix Report

Date: 2026-10-16
Packages: intel-driver-compiler-npu, intel-fw-npu, intel-level-zero-npu, intel-validation-npu
Version: 1.38.0.ncz1~debian
Result: **all four packages are clear of every Lintian E-class finding.**

Everything below is produced by one mechanism, `packaging/intel-native/npu-debian-metadata.cmake`,
run as a CPack pre-build script. Two earlier entries in this report claimed a
blocker "cannot be fixed from the overlay"; both were disproved by running the
real build and are corrected here.

## How the overlay is invoked

`PACKAGE-linux-npu-driver-1.38.0.sh` runs

```
cpack --config CPackConfig.cmake -B "$OUT_DIR" \
  -D "CPACK_COMPONENTS_ALL=driver-compiler-npu;fw-npu;level-zero-npu;validation-npu" \
  -D "CPACK_PRE_BUILD_SCRIPTS=$HELPER"
```

`CPACK_PRE_BUILD_SCRIPTS` is undocumented but honoured by CMake 4.3.4. Verified
ordering with a probe project: it runs **after** the per-component install stage
(`CPACK_TEMPORARY_DIRECTORY/<component>/` already exists) and **before** the
packages are produced. Variables it sets are read during package preparation,
so both data-tree edits and `CPACK_DEBIAN_<COMP>_*` overrides take effect.

## Fixed Blockers

### 1. no-copyright-file (E, all four packages)

The overlay writes `/usr/share/doc/<pkg>/copyright` for each component, in
DEP-5 format. Licences follow the upstream source:

- `intel-driver-compiler-npu`: MIT (driver) + Apache-2.0 (compiler)
- `intel-fw-npu`: MIT + `Custom-Intel-Firmware-Binary` for the `.bin` blobs
- `intel-level-zero-npu`: MIT
- `intel-validation-npu`: MIT

Apache-2.0 is expressed as a reference to
`/usr/share/common-licenses/Apache-2.0`; a paraphrased copy trips
`copyright-not-using-common-license-for-apache2`.

### 2. no-changelog (E, all four packages)

`/usr/share/doc/<pkg>/changelog.gz` is written in Debian changelog format and
gzipped with `-n` for reproducibility. The trailer date is derived from
`SOURCE_DATE_EPOCH` and formatted **RFC 2822** — an ISO 8601 stamp produces
`syntax-error-in-debian-changelog (badly formatted trailer line)`.

The version is the one upstream `deb.cmake` emits
(`${CPACK_PACKAGE_VERSION}~${LINUX_SYSTEM_NAME}${LINUX_SYSTEM_VERSION_ID}`);
the overlay does not override it.

### 3. lacks-ldconfig-trigger (E, intel-driver-compiler-npu and intel-level-zero-npu)

Lintian's `libraries/shared/trigger/ldconfig` check matches the trigger line
against `/^\s*activate-noawait\s+ldconfig\s*$/`. The `triggers` file therefore
contains exactly:

```
activate-noawait ldconfig
```

Earlier attempts using `interest ldconfig /usr/lib/x86_64-linux-gnu` did **not**
clear the finding (they also raised `uses-implicit-await-trigger`).

The file is a **control** member. It is staged outside the component data tree
and declared through `CPACK_DEBIAN_<COMP>_PACKAGE_CONTROL_EXTRA`. Writing it to
`${CPACK_TEMPORARY_DIRECTORY}/<component>/triggers` puts it in the *data*
archive (`/triggers` in the filesystem) where dpkg ignores it.

### 4. no-shlibs (E, intel-level-zero-npu)

A `shlibs` entry is declared for `libze_intel_npu.so.1` through the same
`CONTROL_EXTRA` mechanism:

```
libze_intel_npu 1 intel-level-zero-npu (>= 1.38.0~)
```

The soversion is `1` (`SOVERSION "${PROJECT_VERSION_MAJOR}"` in upstream
`umd/level_zero_driver/api/CMakeLists.txt`).

### 5. sharedobject-in-library-directory-missing-soname (E, intel-driver-compiler-npu)

Upstream builds `libopenvino_intel_npu_compiler.so` as a CMake `MODULE`, so it
gets no SONAME (`src/vpux_compiler/CMakeLists.txt`: `add_library(... MODULE ...)`).

The previous revision of this report argued this needed a source patch. It does
not: the overlay sets a SONAME on the staged file with `patchelf`:

```
patchelf --set-soname libopenvino_intel_npu_compiler.so <staged .so>
```

The file name is unchanged and the loader still dlopens it by name, so loading
is unaffected; the missing SONAME is simply added.

**Verified:** `readelf -d` on the packaged `.so` reports
`Library soname: [libopenvino_intel_npu_compiler.so]`.

### 6. control-file-has-bad-permissions (E, intel-fw-npu)

The overlay sets `CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION=ON`, so CPack
applies `0755` to `postinst`/`postrm`/`preinst`/`prerm` in `CONTROL_EXTRA`
instead of using the source file mode verbatim. This fixes the `0775` postinst
in `intel-fw-npu` (the only component carrying an upstream `CONTROL_EXTRA`).

### 7. Maintainer field is not RFC-822 valid (all four packages)

Upstream `cmake/packaging/setup.cmake` sets
`CPACK_PACKAGE_CONTACT "Intel Corporation"` — not an address, so Lintian cannot
parse the `Maintainer` field.

The previous revision of this report argued the pre-build script could not
override it. It can: the overlay sets

```cmake
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Jason Perlow <jperlow@gmail.com>")
```

and `CPackDeb.cmake` reads it during package preparation, which happens after
the pre-build script runs. Confirmed by the resulting `control` file and by
Lintian no longer reporting the field.

### 8. aliased-location (E, intel-fw-npu)

Upstream installs firmware under `/lib/firmware/...`. On merged-usr systems
`/lib` is a symlink to `/usr/lib`, which Lintian reports as `aliased-location`.

The overlay relocates the staged `lib/` tree to `usr/lib/` for `fw-npu`. The
kernel firmware loader finds it either way on a merged-usr system.

**Verified:** the packaged paths now read `usr/lib/firmware/updates/intel/vpu/...`.

## Implementation bugs in the overlay itself (found and fixed)

- **Unescaped quotes in the copyright bodies.** The licence texts are held in
  CMake double-quoted strings and contain `"Software"`, `"AS IS"` and the
  common-licenses path. Unescaped, they terminated the strings early, producing
  a stream of `Argument not separated from preceding token by whitespace`
  warnings and copyright files built from mangled fragments. Now escaped.
- **Component package names.** The overlay required
  `CPACK_DEBIAN_<COMP>_PACKAGE_NAME`, which upstream never sets; CPack composes
  the name itself as `${CPACK_PACKAGE_NAME}-${component}` (verified:
  `Package: intel-<component>`). The overlay now mirrors that rule and asserts
  the result.
- **Control-file placement**, described under blockers 3 and 4.
- **`fw-npu` postinst preservation.** The overlay appends to any existing
  `CPACK_DEBIAN_<COMP>_PACKAGE_CONTROL_EXTRA` rather than replacing it, so the
  upstream postinst survives.

## Build-harness bugs (in `BUILD.sh`, unrelated to the overlay)

These did not affect Lintian directly, but each one silently produced wrong or
unbuildable output:

1. **Stale debs copied over fresh packages.** `BUILD.sh` copied `*.deb` from
   the build tree into `artifacts/<item>` after packaging. That directory only
   ever contains *older* packages from previous runs, so the copy reverted the
   freshly built packages — this is why `cpack` or `PACKAGE-*.sh` alone
   produced correct packages while a full `BUILD.sh` run did not. The copy is
   removed; CPack already writes directly to `OUT_DIR`.
2. **Non-reproducible `SOURCE_DATE_EPOCH`.** It defaulted to the checkout time
   of this repository. `APPLY-NPU-LLVM-PATCH.py` derives its patched commits
   from that epoch, so every run produced a different commit hash and the guard
   rejected the tree it had itself created last run
   (`llvm HEAD ... not base or derived`). It is now derived from `SNAPSHOT`.
3. **git-lfs false-positive dirty check.** `git status --porcelain` reports
   `filter=lfs` paths as modified on every checkout even when the bytes match
   HEAD, which aborted the build. The check now compares real content: sha256 of
   the worktree against the blob from git for lfs paths, `git diff` otherwise.
4. **Host copy into a root-owned staging tree.** The `.deb` staging tree is
   written by the container as root, so the host could not create files in it.
   The copy now happens in-container.

## Wiring

- `packaging/intel-native/PACKAGE-linux-npu-driver-1.38.0.sh` (new): mirrors
  `PACKAGE-openvino-2026.4.1.sh`; runs `cmake --build` (no-op when already
  built) then `cpack` with the overlay and component list.
- `packaging/intel-native/BUILD.sh`: the NPU branch calls `PACKAGE-$ITEM.sh`
  instead of `cmake --build --target package`, passes `OUT_DIR`, and pins
  `SOURCE_DATE_EPOCH` to `SNAPSHOT`.
- `packaging/intel-native/test-npu-metadata.sh`: offline fixture. It no longer
  fabricates `CPACK_DEBIAN_<COMP>_PACKAGE_NAME` (that fabrication is why the
  earlier tests passed against a state the real build never produces); it sets
  `CPACK_PACKAGE_NAME`, asserts the control members are declared and staged
  outside the data tree, requires an RFC 2822 changelog trailer, requires the
  `activate-noawait ldconfig` trigger, and checks a wrong vendor prefix is
  rejected.

## Remaining Lintian findings (W-class only, non-blocking)

Mostly upstream and out of scope for publication:

- `maintscript-calls-ldconfig` on upstream postinst/postrm (`level-zero-npu`,
  `driver-compiler-npu`) — the scripts call ldconfig directly although a trigger
  is now declared.
- `undeclared-elf-prerequisites`, `shared-library-lacks-version`,
  `package-name-doesnt-match-sonames`, `link-to-shared-library-in-wrong-package`
  — upstream shared-object metadata.
- `no-manual-page` for the validation binaries.
- `extended-description-line-too-long` — upstream `CPACK_COMPONENT_*_DESCRIPTION`.
- `non-standard-file-perm 0400 != 0644` on three firmware blobs (upstream mode).

## Verification

Full `BUILD.sh` run, then Lintian on the produced packages:

```
$ for p in artifacts/linux-npu-driver-1.38.0/*.deb; do
    case $p in *dbgsym*) continue;; esac
    lintian --tag-display-limit 0 "$p" 2>/dev/null | grep -E "^E:" || echo "(no E-class)"
  done
intel-driver-compiler-npu  (no E-class)
intel-fw-npu               (no E-class)
intel-level-zero-npu       (no E-class)
intel-validation-npu       (no E-class)
```

Artifacts (sha256):

```
8bb32c9383a961b55f00293c59336da2becd1e10372552256af8af3ddbf4db4a  intel-driver-compiler-npu_1.38.0.ncz1~debian_amd64.deb
67f892999ba7aaa4efaefc53341a3a5eed9375d8e996b63666d164b65af84122  intel-fw-npu_1.38.0.ncz1~debian_amd64.deb
90638876ca06278047a799264cc3260938c229072c0a4bc98eda6c3df6784fe4  intel-level-zero-npu_1.38.0.ncz1~debian_amd64.deb
6685324791c03883e9b89c2f866c4d6fee31e569fa91f5884813aae6c4044d86  intel-validation-npu_1.38.0.ncz1~debian_amd64.deb
```

## Reproduce

```bash
# 1. Offline metadata tests (no Docker, no full build):
TMPDIR=$(mktemp -d) bash packaging/intel-native/test-npu-metadata.sh

# 2. Full package build (requires Docker, pinned sources, 16 GiB RAM):
PROJ=$HOME/Projects/ncz-npu-build bash packaging/intel-native/BUILD.sh

# 3. Lintian on the produced packages:
for deb in $PROJ/artifacts/linux-npu-driver-1.38.0/*.deb; do
  case $deb in *dbgsym*) continue;; esac
  lintian --tag-display-limit 0 "$deb" 2>/dev/null | grep -E "^E:" || echo "OK: $deb"
done
```

## Publishing (operator step)

The upload itself is an operator action (`build/ops/publish/ncz-reprepro-publish.sh`).
The repo policy work needed to make these packages publishable is on this branch:

- `post-install/lib/apt-separation.sh`: the four `intel-*-npu` names are now rows
  of `ncz_apt_debian_overrides` (amd64). A Debian-named package may only be
  published to the NCZ suite, and win over Debian/Intel's repo, if it has a row
  there; without one `build/check-ncz-repo-policy.sh` rejects it.
- `build/build-ncz-apt-policy-deb.sh`: version **1.0.6**. The live Buildkite index
  already carries 1.0.5 with different content, and the version gate refuses to
  reuse a published version, so 1.0.6 follows it. Built and gate-checked locally
  (`version-gate: ok ... is new (published highest: 1.0.5)`).
- `build/gen-components-registry.py` (the source of truth) and the regenerated
  `manifests/components.tsv`: `intel-driver-compiler-npu` and
  `intel-level-zero-npu` now source `ncz-apt`/`buildkite-packages` instead of
  `debian`/`debian-forky`; `intel-fw-npu` (pulled as a dependency) and
  `intel-validation-npu` (optional tooling, not installed by default) gained rows.

Gates after the change:

```
gen-components-registry.py --check   exit 0
components.py check                  0 errors, 0 warnings
check-ncz-repo-policy.sh --components  31 rows examined, 0 violations
test-apt-separation.sh               73 passed, 0 failed
```

## Risks

1. **No debug symbols.** Upstream turns `CPACK_DEBIAN_<COMP>_DEBUGINFO_PACKAGE`
   on for `level-zero-npu` and `validation-npu`, which yields separate `.ddeb`
   packages. The overlay switches that off *and* strips the staged ELF payload
   itself (CPackDeb strips only as part of splitting debug symbols, so switching
   it off alone left the packages unstripped: `level-zero-npu` went 0.5 MB ->
   8.5 MB). No `.ddeb` is emitted and the packages are small again, but there
   are no debug symbols for these packages. To get them back, leave debug-info
   on and drop the strip step.
2. **Manual `shlibs`.** The overlay writes `shlibs` directly, so a future
   upstream library added to `level-zero-npu` would not be listed
   automatically. The version guard (`CPACK_PACKAGE_VERSION STREQUAL
   "1.38.0.ncz1"`) fails loudly if the version moves.
3. **`~debian` version suffix.** Intentional upstream behaviour; the overlay
   verifies the prefix and does not override it.
4. **Binary edit.** Blocker 5 is fixed with `patchelf`, i.e. by rewriting the
   staged ELF header. It changes the binary hash but not the file name, exports
   or loading path.
