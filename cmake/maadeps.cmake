# CMake adapter for the repo-local prebuilt dependency tree.
#
# Replaces MaaDeps' maadeps.cmake. The binaries themselves live in `deps/`
# (provisioned by tools/fetch-deps.ps1 from a pinned release asset); this file
# only wires them into CMake and provides the helpers MaaUtils/MaaCore expect:
#
#   1. `MAADEPS_TRIPLET`   - the layout triplet (e.g. maa-x64-windows).
#   2. `maadeps_install`   - install/copy of the runtime DLLs into `dest`.
#
# `DEP_DEPS_DIR` must be set by the top-level project before including this file.

if(NOT DEFINED DEP_DEPS_DIR)
    message(FATAL_ERROR "DEP_DEPS_DIR must point at the prebuilt dependency tree (e.g. <repo>/deps)")
endif()

# --- Detect the layout triplet, identical to MaaDeps --------------
function(detect_maadeps_triplet outvar)
  string(TOLOWER "${CMAKE_SYSTEM_NAME}" maadeps_triplet_system)
  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" maadeps_triplet_arch)
  if(maadeps_triplet_system STREQUAL "darwin")
    set(maadeps_triplet_system "osx")
  endif()
  if(maadeps_triplet_arch MATCHES "(amd64|x86_64)")
    set(maadeps_triplet_arch "x64")
  elseif(maadeps_triplet_arch MATCHES "i[3456]86")
    set(maadeps_triplet_arch "x86")
  elseif(maadeps_triplet_arch MATCHES "(aarch64|armv8l|arm64)")
    set(maadeps_triplet_arch "arm64")
  else()
    message(FATAL_ERROR "Unrecognized CMAKE_SYSTEM_PROCESSOR: ${CMAKE_SYSTEM_PROCESSOR}")
  endif()
  set(${outvar} "maa-${maadeps_triplet_arch}-${maadeps_triplet_system}" PARENT_SCOPE)
endfunction()

if(NOT DEFINED MAADEPS_TRIPLET)
  detect_maadeps_triplet(MAADEPS_TRIPLET)
  set(MAADEPS_TRIPLET "${MAADEPS_TRIPLET}" CACHE STRING "")
  message(STATUS "Dependency triplet: ${MAADEPS_TRIPLET}")
endif()

# Make find_package(OpenCV/Boost/ZLIB/fastdeploy/ONNXRuntime) resolve from
# the prebuilt tree.
list(PREPEND CMAKE_PREFIX_PATH "${DEP_DEPS_DIR}")

# OpenCV: the upstream-binary layout ships a small config that exposes the
# official DLLs under the historical _maa names. Fall back to whatever CMake
# finds for other layouts.
if(EXISTS "${DEP_DEPS_DIR}/lib/cmake/opencv4/OpenCVConfig.cmake")
  set(OpenCV_DIR "${DEP_DEPS_DIR}/lib/cmake/opencv4" CACHE PATH "OpenCV config for prebuilt dependencies" FORCE)
endif()

# ZLIB: point both configurations at the vendored static libraries so Debug and
# Release do not pick up unrelated zlib installations.
if(EXISTS "${DEP_DEPS_DIR}/lib/zlib.lib")
  set(ZLIB_LIBRARY_RELEASE "${DEP_DEPS_DIR}/lib/zlib.lib" CACHE FILEPATH "ZLIB release library" FORCE)
endif()
if(EXISTS "${DEP_DEPS_DIR}/debug/lib/zlibd.lib")
  set(ZLIB_LIBRARY_DEBUG "${DEP_DEPS_DIR}/debug/lib/zlibd.lib" CACHE FILEPATH "ZLIB debug library" FORCE)
endif()

# --- maadeps_install: copy runtime DLLs next to the build output -----
function(maadeps_install dest)
  if(MSVC)
    install(DIRECTORY "${DEP_DEPS_DIR}/runtime/${MAADEPS_TRIPLET}/$<$<CONFIG:Debug>:msvc-debug/>" DESTINATION ${dest} USE_SOURCE_PERMISSIONS)
  else()
    install(DIRECTORY "${DEP_DEPS_DIR}/runtime/${MAADEPS_TRIPLET}/" DESTINATION ${dest} USE_SOURCE_PERMISSIONS)
  endif()
endfunction()
