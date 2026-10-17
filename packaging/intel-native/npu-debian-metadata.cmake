# CPack PRE_BUILD helper: add the Debian packaging metadata for the four
# Intel NPU native driver packages without touching upstream sources.
# Runs via CPACK_PRE_BUILD_SCRIPTS: after the staged install, before
# package production, so CPACK_TEMPORARY_DIRECTORY/<component>/ exists.
#
# Fixes the following Lintian E-class findings:
#   1. no-copyright-file       - writes /usr/share/doc/<pkg>/copyright
#   2. no-changelog            - writes /usr/share/doc/<pkg>/changelog.gz
#   3. lacks-ldconfig-trigger  - declares a triggers file, via
#                                 CPACK_DEBIAN_<COMP>_PACKAGE_CONTROL_EXTRA,
#                                 for driver-compiler-npu and level-zero-npu
#   4. no-shlibs               - declares shlibs for level-zero-npu
#                                 (control member, same mechanism)
#   6. control-file-has-bad-permissions - forces CPACK_DEBIAN_PACKAGE_CONTROL_
#                                 STRICT_PERMISSION=ON so CPack applies 0755 to
#                                 postinst/postrm in CONTROL_EXTRA
#
# Blocker 5 (missing-soname) and blocker 7 (maintainer) cannot be fixed from
# an overlay and are documented in FIX-REPORT.md.

if(NOT CPACK_GENERATOR STREQUAL "DEB")
  message(FATAL_ERROR "npu-debian-metadata: DEB generator required")
endif()

if(NOT CPACK_TEMPORARY_DIRECTORY OR NOT IS_DIRECTORY "${CPACK_TEMPORARY_DIRECTORY}")
  message(FATAL_ERROR "npu-debian-metadata: CPACK_TEMPORARY_DIRECTORY missing")
endif()

set(_expected_components driver-compiler-npu fw-npu level-zero-npu validation-npu)
set(_actual_components "${CPACK_COMPONENTS_ALL}")
if(NOT _actual_components STREQUAL "driver-compiler-npu;fw-npu;level-zero-npu;validation-npu")
  message(FATAL_ERROR "npu-debian-metadata: CPACK_COMPONENTS_ALL must be exactly driver-compiler-npu;fw-npu;level-zero-npu;validation-npu (got '${_actual_components}')")
endif()

if(NOT CPACK_PACKAGE_VERSION STREQUAL "1.38.0.ncz1")
  message(FATAL_ERROR "npu-debian-metadata: unexpected CPACK_PACKAGE_VERSION '${CPACK_PACKAGE_VERSION}'")
endif()

# Upstream deb.cmake appends ~${LINUX_SYSTEM_NAME}${LINUX_SYSTEM_VERSION_ID} to
# CPACK_PACKAGE_VERSION to form the full Debian version.  We do not override it;
# we only verify it has the expected prefix.
if(NOT CPACK_DEBIAN_PACKAGE_VERSION MATCHES "^1\\.38\\.0\\.ncz1~")
  message(FATAL_ERROR "npu-debian-metadata: unexpected CPACK_DEBIAN_PACKAGE_VERSION '${CPACK_DEBIAN_PACKAGE_VERSION}'")
endif()

if(NOT DEFINED ENV{SOURCE_DATE_EPOCH} OR "$ENV{SOURCE_DATE_EPOCH}" STREQUAL "")
  message(FATAL_ERROR "npu-debian-metadata: SOURCE_DATE_EPOCH env required")
endif()
if(NOT "$ENV{SOURCE_DATE_EPOCH}" MATCHES "^[0-9]+$")
  message(FATAL_ERROR "npu-debian-metadata: SOURCE_DATE_EPOCH must be numeric")
endif()

# Derive the changelog date from SOURCE_DATE_EPOCH for build reproducibility.
# Use the environment variable directly (CMake's $ENV{SOURCE_DATE_EPOCH} is
# not a CMake variable and cannot be referenced with ${} in execute_process).
find_program(_DATE_EXECUTABLE date REQUIRED)
execute_process(
  COMMAND "${_DATE_EXECUTABLE}" -u -d "@$ENV{SOURCE_DATE_EPOCH}" "+%Y-%m-%dT%H:%M:%SZ"
  OUTPUT_VARIABLE _changelog_date
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _date_rc
  ERROR_VARIABLE _date_err)
if(NOT _date_rc EQUAL 0)
  message(FATAL_ERROR "npu-debian-metadata: date failed (rc=${_date_rc}): ${_date_err}")
endif()
if(NOT _changelog_date MATCHES "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$")
  message(FATAL_ERROR "npu-debian-metadata: unexpected date format '${_changelog_date}'")
endif()

find_program(_GZIP gzip REQUIRED)

# Disable the shlibdeps scan and dbgsym packaging so CPack does not re-glob the
# staged tree after we have written our metadata files.
set(CPACK_DEBIAN_PACKAGE_GENERATE_SHLIBS OFF)
set(CPACK_DEBIAN_DEBUGINFO_PACKAGE OFF)
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS OFF)

# Force strict control-extra permissions: CPackDeb.cmake (CMake >= 3.28) passes
# this value through to the C++ DebGenerator which applies 0755 to
# postinst/postrm/preinst/prerm/config in CONTROL_EXTRA.  Without it the source
# file permissions are used verbatim and a 0775 postinst produces the
# control-file-has-bad-permissions Lintian error.
set(CPACK_DEBIAN_PACKAGE_CONTROL_STRICT_PERMISSION "ON")

# Full Debian version as emitted by upstream deb.cmake.
# Note: CPackDeb.cmake (per-component) reads CPACK_DEBIAN_PACKAGE_VERSION.
# The value is set by upstream deb.cmake as
#   ${CPACK_PACKAGE_VERSION}~${LINUX_SYSTEM_NAME}${LINUX_SYSTEM_VERSION_ID}
# and is NOT overridden here.
set(_full_version "${CPACK_DEBIAN_PACKAGE_VERSION}")

# Copyright templates
set(_copyright_driver_compiler "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: intel-linux-npu-driver
Source: https://github.com/intel/linux-npu-driver
Upstream-Contact: Intel Corporation
Maintainer: Jason Perlow <jperlow@gmail.com>

Files: *
Copyright: 2022-2026 Intel Corporation
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the
 "Software"), to deal in the Software without restriction, including
 without limitation the rights to use, copy, modify, merge, publish,
 distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to
 the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

License: MIT

Files: compiler/*
Copyright: 2022-2026 Intel Corporation
License: Apache-2.0
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 .
     http://www.apache.org/licenses/LICENSE-2.0
 .
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
")

set(_copyright_fw "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: intel-linux-npu-driver
Source: https://github.com/intel/linux-npu-driver
Upstream-Contact: Intel Corporation
Maintainer: Jason Perlow <jperlow@gmail.com>

Files: *
Copyright: 2022-2026 Intel Corporation
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the
 "Software"), to deal in the Software without restriction, including
 without limitation the rights to use, copy, modify, merge, publish,
 distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to
 the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

License: MIT

Files: bin/*.bin
Copyright: 2023 Intel Corporation
License: Custom-Intel-Firmware-Binary
 Redistribution and use in binary form, without modification, are
 permitted provided that the following conditions are met:
 .
 * Redistributions must reproduce the above copyright notice and the
   following disclaimer in the documentation and/or other materials
   provided with the distribution.
 * Neither the name of Intel Corporation nor the names of its suppliers
   may be used to endorse or promote products derived from this software
   without specific prior written permission.
 * No reverse engineering, decompilation, or disassembly of this software
   is permitted.
 .
 Limited patent license.  Intel Corporation grants a world-wide,
 royalty-free, non-exclusive license under patents it now or hereafter
 owns or controls to make, have made, use, import, offer to sell and
 sell ("Utilize") this software, but solely to the extent that any
 such patent is necessary to Utilize the software alone.  The patent
 license shall not apply to any other combinations which include this
 software.  No hardware per se is licensed hereunder.
 .
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE;
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
")

set(_copyright_level_zero "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: intel-linux-npu-driver
Source: https://github.com/intel/linux-npu-driver
Upstream-Contact: Intel Corporation
Maintainer: Jason Perlow <jperlow@gmail.com>

Files: *
Copyright: 2022-2026 Intel Corporation
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the
 "Software"), to deal in the Software without restriction, including
 without limitation the rights to use, copy, modify, merge, publish,
 distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to
 the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

License: MIT
")

set(_copyright_validation "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: intel-linux-npu-driver
Source: https://github.com/intel/linux-npu-driver
Upstream-Contact: Intel Corporation
Maintainer: Jason Perlow <jperlow@gmail.com>

Files: *
Copyright: 2022-2026 Intel Corporation
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the
 "Software"), to deal in the Software without restriction, including
 without limitation the rights to use, copy, modify, merge, publish,
 distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to
 the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

License: MIT
")

# ldconfig trigger: exactly one line as required by the task.
set(_triggers_content "interest ldconfig /usr/lib/x86_64-linux-gnu\n")

# shlibs entry for libze_intel_npu.so.1.
# Upstream umd/level_zero_driver/api/CMakeLists.txt sets:
#   VERSION 1.38.0  SOVERSION 1
# so the SONAME is libze_intel_npu.so.1 and the shlibs symbol version is 1.
set(_shlibs_content "libze_intel_npu 1 intel-level-zero-npu (>= 1.38.0~)\n")

foreach(_comp IN LISTS _expected_components)
  string(TOUPPER "${_comp}" _C)

  # CPack derives the DEB component package name itself as
  # "${CPACK_PACKAGE_NAME}-${component}"; upstream deb.cmake never sets
  # CPACK_DEBIAN_<COMP>_PACKAGE_NAME. Mirror CPack's rule here (verified to
  # produce Package: intel-<component>) instead of requiring a variable that
  # does not exist, then assert the result is what we expect.
  set(_pkg "${CPACK_PACKAGE_NAME}-${_comp}")

  # Expected package names
  if(_comp STREQUAL "driver-compiler-npu")
    set(_expected_pkg "intel-driver-compiler-npu")
  elseif(_comp STREQUAL "fw-npu")
    set(_expected_pkg "intel-fw-npu")
  elseif(_comp STREQUAL "level-zero-npu")
    set(_expected_pkg "intel-level-zero-npu")
  elseif(_comp STREQUAL "validation-npu")
    set(_expected_pkg "intel-validation-npu")
  endif()
  if(NOT _pkg STREQUAL _expected_pkg)
    message(FATAL_ERROR "npu-debian-metadata: unexpected ${_pkg_var}='${_pkg}'")
  endif()

  set(_docdir "${CPACK_TEMPORARY_DIRECTORY}/${_comp}/usr/share/doc/${_pkg}")
  file(MAKE_DIRECTORY "${_docdir}")

  # --- copyright ---
  if(_comp STREQUAL "driver-compiler-npu")
    set(_copyright "${_copyright_driver_compiler}")
  elseif(_comp STREQUAL "fw-npu")
    set(_copyright "${_copyright_fw}")
  elseif(_comp STREQUAL "level-zero-npu")
    set(_copyright "${_copyright_level_zero}")
  elseif(_comp STREQUAL "validation-npu")
    set(_copyright "${_copyright_validation}")
  endif()
  file(WRITE "${_docdir}/copyright" "${_copyright}")

  # --- changelog.gz ---
  set(_changelog "${_docdir}/changelog")
  file(WRITE "${_changelog}"
    "${_pkg} (${_full_version}) unstable; urgency=medium\n\n"
    "  * Native NCZ packaging of Intel NPU driver stack ${_full_version}.\n"
    "  * Built from pinned upstream sources; no upstream source modifications.\n\n"
    " -- Jason Perlow <jperlow@gmail.com>  ${_changelog_date}\n")
  execute_process(
    COMMAND "${_GZIP}" -n -9 -f "${_changelog}"
    RESULT_VARIABLE _gz_rc)
  if(NOT _gz_rc EQUAL 0)
    message(FATAL_ERROR "npu-debian-metadata: gzip failed for ${_changelog} (rc=${_gz_rc})")
  endif()
  if(NOT EXISTS "${_changelog}.gz")
    message(FATAL_ERROR "npu-debian-metadata: ${_changelog}.gz not produced")
  endif()
  file(REMOVE "${_changelog}")

  # --- ldconfig triggers + shlibs go into the CONTROL archive ---
  #
  # Writing them into ${CPACK_TEMPORARY_DIRECTORY}/${_comp}/ puts them in the
  # DATA archive (verified: they appeared as /triggers and /shlibs in the
  # filesystem), where dpkg ignores them. They must be declared as
  # CPACK_DEBIAN_<COMP>_PACKAGE_CONTROL_EXTRA so CPackDeb copies them into
  # DEBIAN/ as real control members.  A PRE_BUILD script may set that variable:
  # it is read when the package is prepared, which happens afterwards.
  #
  # Keep the staged files outside the per-component data tree so they are never
  # picked up as package contents.
  set(_ctrl_dir "${CPACK_TEMPORARY_DIRECTORY}/ncz-npu-meta/${_comp}")
  file(MAKE_DIRECTORY "${_ctrl_dir}")

  set(_extra "")
  if(_comp STREQUAL "driver-compiler-npu" OR _comp STREQUAL "level-zero-npu")
    file(WRITE "${_ctrl_dir}/triggers" "${_triggers_content}")
    list(APPEND _extra "${_ctrl_dir}/triggers")
  endif()
  if(_comp STREQUAL "level-zero-npu")
    file(WRITE "${_ctrl_dir}/shlibs" "${_shlibs_content}")
    list(APPEND _extra "${_ctrl_dir}/shlibs")
  endif()

  # Preserve anything the project already attached (fw-npu ships a postinst).
  set(_existing "${CPACK_DEBIAN_${_C}_PACKAGE_CONTROL_EXTRA}")
  if(_existing)
    list(APPEND _extra ${_existing})
  endif()
  if(_extra)
    set(CPACK_DEBIAN_${_C}_PACKAGE_CONTROL_EXTRA "${_extra}")
  endif()
endforeach()
