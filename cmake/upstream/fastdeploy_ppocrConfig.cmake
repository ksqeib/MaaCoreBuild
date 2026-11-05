# fastdeploy_ppocr config for the MaaCoreBuild dependency layout.
#
# The FastDeploy fork is built from source by tools/build-fastdeploy.ps1 and
# installed into the deps tree as:
#   deps/include/fastdeploy             headers
#   deps/lib/fastdeploy_ppocr.lib       release import lib -> fastdeploy_ppocr_maa.dll
#   deps/bin/fastdeploy_ppocr_maa.dll   release DLL
#   deps/debug/lib/fastdeploy_ppocr.lib debug import lib -> fastdeploy_ppocr_maa.dll
#   deps/debug/bin/fastdeploy_ppocr_maa.dll
#
# The import libraries are generated with the `_maa` DLL name, so the bundle
# loads the same OpenCV/ONNXRuntime modules as the rest of the SDK.

set(fastdeploy_ppocr_FOUND TRUE)

get_filename_component(_FASTDEPLOY_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

if(NOT TARGET fastdeploy_ppocr)
    find_package(OpenCV COMPONENTS core imgproc REQUIRED)

    add_library(fastdeploy_ppocr SHARED IMPORTED)
    set_target_properties(fastdeploy_ppocr PROPERTIES
        IMPORTED_CONFIGURATIONS "RELEASE;DEBUG"
        IMPORTED_IMPLIB_RELEASE "${_FASTDEPLOY_PREFIX}/lib/fastdeploy_ppocr.lib"
        IMPORTED_LOCATION_RELEASE "${_FASTDEPLOY_PREFIX}/bin/fastdeploy_ppocr_maa.dll"
        IMPORTED_IMPLIB_DEBUG "${_FASTDEPLOY_PREFIX}/debug/lib/fastdeploy_ppocr.lib"
        IMPORTED_LOCATION_DEBUG "${_FASTDEPLOY_PREFIX}/debug/bin/fastdeploy_ppocr_maa.dll"
        INTERFACE_INCLUDE_DIRECTORIES "${_FASTDEPLOY_PREFIX}/include"
        INTERFACE_LINK_LIBRARIES "${OpenCV_LIBS}")
endif()

# ONNX Runtime 1.19.2 DirectML does not ship the WebGPU EP. The API is still
# compiled into FastDeploy and falls back to CPU at runtime.
set(fastdeploy_ppocr_WITH_WEBGPU OFF)

unset(_FASTDEPLOY_PREFIX)
