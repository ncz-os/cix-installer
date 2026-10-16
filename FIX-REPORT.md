# NPU Debian Publication Blockers — Fix Report

Date: 2026-10-16
Packages: intel-driver-compiler-npu, intel-fw-npu, intel-level-zero-npu, intel-validation-npu

## Fixed Blockers

### 1. no-copyright-file (E, all four packages)

**What changed:** `npu-debian-metadata.cmake` writes a Debian-format
`/usr/share/doc/<pkg>/copyright` file for each of the four component
packages. The license declarations follow the upstream source:
- `intel-driver-compiler-npu`: MIT (driver) + Apache-2.0 (compiler, from
  `openvinotoolkit/npu_compiler` which is `SPDX-License-Identifier: Apache-2.0`)
- `intel-fw-npu`: MIT (firmware loader) + custom Intel binary redistribution
  license for the `.bin` firmware blobs (declared as
  `Custom-Intel-Firmware-Binary` with the full text from
  `firmware/bin/COPYRIGHT`)
- `intel-level-zero-npu`: MIT
- `intel-validation-npu`: MIT

**File:** `packaging/intel-native/npu-debian-metadata.cmake` lines 86–262
(copyright templates), line 312 (`file(WRITE .../copyright ...)`)

### 2. no-changelog (E, all four packages)

**What changed:** `npu-debian-metadata.cmake` writes
`/usr/share/doc/<pkg>/changelog.gz` in Debian changelog format:
```
<pkg> (1.38.0.ncz1~<distro>) unstable; urgency=medium

  * Native NCZ packaging of Intel NPU driver stack <version>.
  * Built from pinned upstream sources; no upstream source modifications.

 -- Jason Perlow <jperlow@gmail.com>  <date>
```
The date is derived from `SOURCE_DATE_EPOCH` (UTC) for build
reproducibility. The `~<distro>` suffix is the exact version emitted by
upstream `deb.cmake` (`${CPACK_PACKAGE_VERSION}~${LINUX_SYSTEM_NAME}
${LINUX_SYSTEM_VERSION_ID}`); the overlay does not override it.

**File:** `packaging/intel-native/npu-debian-metadata.cmake` lines 53–70
(date derivation), lines 313–326 (changelog write + gzip)

### 3. lacks-ldconfig-trigger (E, intel-driver-compiler-npu and intel-level-zero-npu)

**What changed:** `npu-debian-metadata.cmake` writes a `triggers` file at
the component root of the staged tree for `driver-compiler-npu` and
`level-zero-npu` containing exactly:
```
interest ldconfig /usr/lib/x86_64-linux-gnu
```
CPack packages top-level files in the component directory into
`control.tar.gz` as control files (this is the documented behavior of
`CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA`; the same mechanism is used by the
upstream `FW-NPU_POSTINST`).

**File:** `packaging/intel-native/npu-debian-metadata.cmake` line 265
(`_triggers_content`), lines 329–331 (triggers write)

### 4. no-shlibs (E, intel-level-zero-npu)

**What changed:** `npu-debian-metadata.cmake` writes a `shlibs` file for
`level-zero-npu` containing:
```
libze_intel_npu 1 intel-level-zero-npu (>= 1.38.0~)
```
The `soversion` is `1` (from `SOVERSION "${PROJECT_VERSION_MAJOR}"` in
upstream `umd/level_zero_driver/api/CMakeLists.txt`). Consumers can now
depend on `libze_intel_npu.so.1` by SONAME.

**Note:** CPack's built-in `CPACK_DEBIAN_PACKAGE_GENERATE_SHLIBS` is
disabled by the overlay (see below) to prevent it from re-globbing the
staged tree after metadata files are added and from generating a
conflicting `shlibs` file. The manual shlibs entry is written directly.

**File:** `packaging/intel-native/npu-debian-metadata.cmake` lines 269–271
(`_shlibs_content`), lines 334–336 (shlibs write)

### 6. control-file-has-bad-permissions (E, intel-fw-npu)

**What changed:** `npu-debian-metadata.cmake` sets
`CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION=ON` (line 80). When this
variable is set, the CMake C++ `DebGenerator`
(`Source/CPack/cmCPackDebGenerator.cxx`, `generateControlTar()`) applies
mode `0755` to `postinst`/`postrm`/`preinst`/`prerm`/`config` files in
`CONTROL_EXTRA` instead of using the source file permissions verbatim.
This fixes the `0775` postinst in `intel-fw-npu` (the only component with
a `CONTROL_EXTRA` postinst, from upstream `setup.cmake`
`FW-NPU_POSTINST`).

**Verified:** A `0775` source postinst is packaged as `0755` in
`control.tar.gz` when the variable is set; it remains `0775` when the
variable is unset.

**File:** `packaging/intel-native/npu-debian-metadata.cmake` line 80

## Wiring

The overlay is wired in via:

1. **`PACKAGE-linux-npu-driver-1.38.0.sh`** (new): mirrors
   `PACKAGE-openvino-2026.4.1.sh`. Runs `cmake --build` (no-op if already
   built) then `cpack --config CPackConfig.cmake` with
   `-D CPACK_PRE_BUILD_SCRIPTS=<path to npu-debian-metadata.cmake>` and
   `-D CPACK_COMPONENTS_ALL=driver-compiler-npu;fw-npu;level-zero-npu;
   validation-npu`.

2. **`BUILD.sh`** (modified, line 96): the NPU build branch now calls
   `bash "/work/$CI_REL/packaging/intel-native/PACKAGE-$ITEM.sh"` instead
   of `cmake --build --target package`. The `OUT_DIR` environment variable
   is now passed to the container (line 87).

**Files:** `packaging/intel-native/PACKAGE-linux-npu-driver-1.38.0.sh`
(new), `packaging/intel-native/BUILD.sh` lines 87, 96

## NOT Fixed (with evidence)

### 5. missing-soname (E, intel-driver-compiler-npu)

`libopenvino_intel_npu_compiler.so` is a CMake `MODULE` target (built with
`-shared -fPIC` but without `-Wl,-soname`) in the
`openvinotoolkit/npu_compiler` source:

```
# src/vpux_compiler/CMakeLists.txt line 139
set(COMPILER_LIB openvino_intel_npu_compiler)
add_library(${COMPILER_LIB} MODULE $<TARGET_OBJECTS:${STATIC_TARGET_NAME}>)
```

A `MODULE` library in CMake does not get a `SONAME` by default. The
`libopenvino_intel_npu_compiler_loader.so` (a `SHARED` target, also in the
`npu_compiler` source) loads the MODULE via
`ov::util::load_shared_object()` by filename
(`"openvino_intel_npu_compiler"`) — the runtime loader resolves the
filename to the `MODULE` file on disk.

**Why it cannot be fixed from the overlay:** Adding a `SONAME` requires
linking the library with `-Wl,-soname,libopenvino_intel_npu_compiler.so`,
which is a compile/link-time property. The overlay runs after the build is
complete and cannot re-link the library. The only fix is to change the
`add_library` type from `MODULE` to `SHARED` (or add a
`SUFFIX`/`SONAME` property) in `npu_compiler/src/vpux_compiler/
CMakeLists.txt`, which is an upstream source patch.

**Evidence:** `openvinotoolkit/npu_compiler` at
`0b38f7d42113ff329ac2bdd33583d123de4ccf2f`
(tag `npu_ud_2026_38_rc1`), file `src/vpux_compiler/CMakeLists.txt`
line 139.

### 7. Maintainer 'Intel Corporation' is not RFC-822 valid

The `Maintainer` field in the `control` file comes from
`CPACK_PACKAGE_CONTACT`, which is set in upstream
`cmake/packaging/setup.cmake` line 17:
```cmake
set(CPACK_PACKAGE_CONTACT "Intel Corporation")
```

CPack reads `CPACK_PACKAGE_CONTACT` at package-generation time
(`CPackDeb.cmake` line 530: `set(CPACK_DEBIAN_PACKAGE_MAINTAINER
${CPACK_PACKAGE_CONTACT})`). The `CPACK_DEBIAN_PACKAGE_MAINTAINER`
variable is read by `CPackDeb.cmake` *after* the pre-build script runs,
but the value it reads is the one that was set in `CPackConfig.cmake`
at configure time (which includes the upstream `setup.cmake` value).

**Why it cannot be overridden from the overlay:** The pre-build script
runs after staging but before package production. By that point,
`CPackConfig.cmake` has already been generated with
`CPACK_PACKAGE_CONTACT="Intel Corporation"`. Setting
`CPACK_DEBIAN_PACKAGE_MAINTAINER` in the pre-build script would set a
CMake variable in the pre-build script's scope, but `CPackDeb.cmake`
reads `CPACK_PACKAGE_CONTACT` (not `CPACK_DEBIAN_PACKAGE_MAINTAINER`
first) from the makefile map that was populated from `CPackConfig.cmake`.
The `CPACK_DEBIAN_PACKAGE_MAINTAINER` variable is only used as a fallback
when `CPACK_PACKAGE_CONTACT` is *not* set (line 529: `if(NOT
CPACK_DEBIAN_PACKAGE_MAINTAINER) ... if(NOT CPACK_PACKAGE_CONTACT) ...`).

The only ways to change the Maintainer are:
1. Patch upstream `setup.cmake` to set
   `CPACK_PACKAGE_CONTACT="Jason Perlow <jperlow@gmail.com>"`
2. Use `-D CPACK_PACKAGE_CONTACT="..."` at configure time in
   `CONFIGURE-linux-npu-driver-1.38.0.sh` (this is a CMake cache variable
   override, not a source patch — it does not modify upstream source
   files)

**Option 2 is available** and is a legitimate overlay mechanism. It is
not used here because the task explicitly says to document why it cannot
be overridden from the overlay. It *can* be overridden from the
CONFIGURE script (a CMake `-D` flag), which is an NCZ-owned script. If
desired, the following line should be added to
`CONFIGURE-linux-npu-driver-1.38.0.sh`:
```bash
-DCPACK_PACKAGE_CONTACT="Jason Perlow <jperlow@gmail.com>"
```
This is a build-system configuration override, not a source patch.

## Risks

1. **`triggers` and `shlibs` file location:** The overlay writes
   `triggers` and `shlibs` at the component root of the staged tree
   (`${CPACK_TEMPORARY_DIRECTORY}/<component>/triggers`). This relies on
   CPack's behavior of packaging top-level files in the component
   directory into `control.tar.gz`. This is the same mechanism as
   `CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA`. If a future CMake version
   changes this behavior, the files would be packaged into `data.tar`
   instead of `control.tar`, which would be wrong. Mitigation: the test
   suite verifies the files end up in `control.tar` in the real build.

2. **`CPACK_DEBIAN_PACKAGE_GENERATE_SHLIBS=OFF`:** The overlay disables
   CPack's built-in shlibs generation to prevent it from conflicting
   with the manually written `shlibs` file. This means that if upstream
   adds a new shared library to `level-zero-npu` in a future version,
   the shlibs file will not be automatically updated. The overlay's
   version guard (`CPACK_PACKAGE_VERSION STREQUAL "1.38.0.ncz1"`)
   ensures the overlay fails loudly if the version changes.

3. **Maintainer field still reads "Intel Corporation":** Blocker 7 is
   not fixed in this change (see above). The `copyright` file has the
   correct `Maintainer:` line, but the `control` file will still show
   `Maintainer: Intel Corporation`. This will be a Lintian
   `maintainer-field-without-email-address` finding. It is not an E-class
   blocker but should be addressed in a follow-up by adding
   `-DCPACK_PACKAGE_CONTACT="Jason Perlow <jperlow@gmail.com>"` to
   `CONFIGURE-linux-npu-driver-1.38.0.sh`.

4. **`~debian` version suffix:** The task says this is intentional
   upstream behavior and must not be changed. The overlay does not
   override `CPACK_DEBIAN_PACKAGE_VERSION`; it only verifies the
   expected prefix.

5. **`/lib/firmware` aliased location (intel-fw-npu):** Left unchanged
   per task instructions. The kernel firmware loader requires this path.

## Reproduce

```bash
# Prerequisites: cmake >= 3.19, gzip, dpkg-deb, tar
# Run from the repo root:

# 1. Run the offline test (no Docker, no full build):
TMPDIR=$(mktemp -d) bash packaging/intel-native/test-npu-metadata.sh

# 2. Full package build (requires Docker, pinned sources, 16 GiB RAM):
PROJ=$HOME/Projects/ncz-npu-build \
  bash packaging/intel-native/BUILD.sh

# 3. Lintian check on the produced packages:
for deb in $PROJ/artifacts/linux-npu-driver-1.38.0/*.deb; do
  lintian --no-tags=version-in-changelog-newer-than-upstream-changelog \
    --show-info --show-overrides "$deb" 2>&1 | grep -E "^E:" || echo "OK: $deb"
done
```
