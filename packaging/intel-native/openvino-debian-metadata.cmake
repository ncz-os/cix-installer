# CPack PRE_BUILD helper: add the Debian packaging changelog for each
# selected component package without touching upstream changelog/copyright.
# Runs after staged install, before package production (CMake >= 3.19).

if(NOT CPACK_GENERATOR STREQUAL "DEB")
  message(FATAL_ERROR "openvino-debian-metadata: DEB generator required")
endif()

if(NOT CPACK_TEMPORARY_DIRECTORY OR NOT IS_DIRECTORY "${CPACK_TEMPORARY_DIRECTORY}")
  message(FATAL_ERROR "openvino-debian-metadata: CPACK_TEMPORARY_DIRECTORY missing")
endif()

set(_expected_components core cpu gpu npu)
set(_actual_components "${CPACK_COMPONENTS_ALL}")
if(NOT _actual_components STREQUAL "core;cpu;gpu;npu")
  message(FATAL_ERROR "openvino-debian-metadata: CPACK_COMPONENTS_ALL must be exactly core;cpu;gpu;npu (got '${_actual_components}')")
endif()

if(NOT CPACK_PACKAGE_VERSION STREQUAL "2026.4.1.1")
  message(FATAL_ERROR "openvino-debian-metadata: unexpected CPACK_PACKAGE_VERSION '${CPACK_PACKAGE_VERSION}'")
endif()

if(NOT CPACK_DEBIAN_PACKAGE_RELEASE STREQUAL "ncz1")
  message(FATAL_ERROR "openvino-debian-metadata: unexpected CPACK_DEBIAN_PACKAGE_RELEASE '${CPACK_DEBIAN_PACKAGE_RELEASE}'")
endif()

if(NOT CPACK_DEBIAN_PACKAGE_EPOCH STREQUAL "1")
  message(FATAL_ERROR "openvino-debian-metadata: unexpected CPACK_DEBIAN_PACKAGE_EPOCH '${CPACK_DEBIAN_PACKAGE_EPOCH}'")
endif()

if(NOT DEFINED ENV{SOURCE_DATE_EPOCH} OR "$ENV{SOURCE_DATE_EPOCH}" STREQUAL "")
  message(FATAL_ERROR "openvino-debian-metadata: SOURCE_DATE_EPOCH env required")
endif()
if(NOT "$ENV{SOURCE_DATE_EPOCH}" MATCHES "^[0-9]+$")
  message(FATAL_ERROR "openvino-debian-metadata: SOURCE_DATE_EPOCH must be numeric")
endif()

string(TIMESTAMP _deb_date "%a, %d %b %Y %H:%M:%S +0000" UTC)

set(_abi "2026.4.1")

foreach(_comp IN LISTS _expected_components)
  string(TOUPPER "${_comp}" _C)
  set(_pkg_var "CPACK_DEBIAN_${_C}_PACKAGE_NAME")
  if(NOT DEFINED ${_pkg_var} OR "${${_pkg_var}}" STREQUAL "")
    message(FATAL_ERROR "openvino-debian-metadata: ${_pkg_var} not set")
  endif()
  set(_pkg "${${_pkg_var}}")
  if(_comp STREQUAL "core")
    set(_expected_pkg "libopenvino-${_abi}")
  else()
    set(_expected_pkg "libopenvino-intel-${_comp}-plugin-${_abi}")
  endif()
  if(NOT _pkg STREQUAL _expected_pkg)
    message(FATAL_ERROR "openvino-debian-metadata: unexpected ${_pkg_var}='${_pkg}'")
  endif()

  set(_docdir "${CPACK_TEMPORARY_DIRECTORY}/${_comp}/usr/share/doc/${_pkg}")
  if(NOT IS_DIRECTORY "${_docdir}")
    message(FATAL_ERROR "openvino-debian-metadata: staged doc dir missing: ${_docdir}")
  endif()
  if(NOT EXISTS "${_docdir}/copyright")
    message(FATAL_ERROR "openvino-debian-metadata: upstream copyright missing: ${_docdir}/copyright")
  endif()
  if(NOT EXISTS "${_docdir}/changelog.gz")
    message(FATAL_ERROR "openvino-debian-metadata: upstream changelog.gz missing: ${_docdir}/changelog.gz")
  endif()

  set(_full_version "1:${CPACK_PACKAGE_VERSION}-${CPACK_DEBIAN_PACKAGE_RELEASE}")
  set(_changelog "${_docdir}/changelog.Debian")
  file(WRITE "${_changelog}"
    "${_pkg} (${_full_version}) unstable; urgency=medium\n\n"
    "  * Native NCZ packaging of Intel OpenVINO ${_abi} (${_comp} component).\n"
    "  * Built from pinned upstream sources; no upstream source modifications.\n"
    "  * Upstream changelog and copyright preserved verbatim.\n\n"
    " -- Jason Perlow <jperlow@gmail.com>  ${_deb_date}\n")

  find_program(_GZIP gzip REQUIRED)
  execute_process(
    COMMAND "${_GZIP}" -n -9 -f "${_changelog}"
    RESULT_VARIABLE _gz_rc)
  if(NOT _gz_rc EQUAL 0)
    message(FATAL_ERROR "openvino-debian-metadata: gzip failed for ${_changelog} (rc=${_gz_rc})")
  endif()
  if(NOT EXISTS "${_changelog}.gz")
    message(FATAL_ERROR "openvino-debian-metadata: ${_changelog}.gz not produced")
  endif()
endforeach()
