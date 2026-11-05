# OpenCV config for the upstream-binary dependency layout.
#
# Used instead of OpenCV's stock config because MaaCore/FastDeploy consume the
# historical `_maa` DLL names. The DLLs themselves are the official OpenCV
# 4.12.0 binaries, renamed; the import libraries are generated from those DLLs
# by tools/build-upstream-deps.ps1.
#
# Layout (relative to this file, which lives in deps/lib/cmake/opencv4):
#   deps/include/opencv4                  headers
#   deps/lib/opencv_world4.lib            release import lib -> opencv_world4_maa.dll
#   deps/bin/opencv_world4_maa.dll        release DLL
#   deps/debug/lib/opencv_world4d.lib     debug import lib -> opencv_world4d_maa.dll
#   deps/debug/bin/opencv_world4d_maa.dll debug DLL

set(OpenCV_VERSION 4.12.0)
set(OpenCV_VERSION_MAJOR 4)
set(OpenCV_VERSION_MINOR 12)
set(OpenCV_VERSION_PATCH 0)

get_filename_component(_OPENCV_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(OpenCV_INCLUDE_DIRS "${_OPENCV_PREFIX}/include/opencv4")

if(NOT TARGET opencv_world)
    add_library(opencv_world SHARED IMPORTED)
    set_target_properties(opencv_world PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${OpenCV_INCLUDE_DIRS}"
        IMPORTED_CONFIGURATIONS "RELEASE;DEBUG"
        IMPORTED_IMPLIB_RELEASE "${_OPENCV_PREFIX}/lib/opencv_world4.lib"
        IMPORTED_LOCATION_RELEASE "${_OPENCV_PREFIX}/bin/opencv_world4_maa.dll"
        IMPORTED_IMPLIB_DEBUG "${_OPENCV_PREFIX}/debug/lib/opencv_world4d.lib"
        IMPORTED_LOCATION_DEBUG "${_OPENCV_PREFIX}/debug/bin/opencv_world4d_maa.dll")
endif()

foreach(_component core imgproc imgcodecs calib3d)
    if(NOT TARGET opencv_${_component})
        add_library(opencv_${_component} INTERFACE IMPORTED)
        set_target_properties(opencv_${_component} PROPERTIES
            INTERFACE_LINK_LIBRARIES opencv_world)
    endif()
endforeach()

set(OpenCV_LIBS opencv_world)
set(OpenCV_LIB_COMPONENTS opencv_world)
set(OpenCV_FOUND TRUE)

unset(_OPENCV_PREFIX)
unset(_component)
