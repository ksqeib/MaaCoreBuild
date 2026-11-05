cmake_minimum_required(VERSION 3.28)

project(MaaCoreStandalone)

option(INSTALL_FLATTEN "do not use bin/lib/include directory" ON)
option(WITH_EMULATOR_EXTRAS "build with emulator extras" ${WIN32})
option(WITH_EXTRA_CALLERS "build with extra callers" ${APPLE})
option(WITH_MAC_SCK "build with macOS ScreenCaptureKit" ${APPLE})
set(MAA_INCLUDE_ROOT "${PROJECT_SOURCE_DIR}/include" CACHE PATH "Single include root for standalone MaaCore")
set(MAA_PUBLIC_INCLUDE_DIR "${MAA_INCLUDE_ROOT}/upstream" CACHE PATH "Public include directory for MaaCore API headers")
set(MAA_THIRDPARTY_INCLUDE_DIR "${MAA_INCLUDE_ROOT}/3rd" CACHE PATH "Header-only 3rdparty include directory")

if(INSTALL_FLATTEN)
    set(MaaCore_install_flatten_args
        RUNTIME DESTINATION .
        LIBRARY DESTINATION .
        ARCHIVE DESTINATION .
        PUBLIC_HEADER DESTINATION .)
endif()

# Version string exposed by AsstGetVersion(). Release CI passes -DMAA_HASH_VERSION=<tag>;
# otherwise derive it from git so local builds never report DEBUG_VERSION.
if(NOT DEFINED MAA_HASH_VERSION OR MAA_HASH_VERSION STREQUAL "")
    find_package(Git QUIET)
    if(GIT_FOUND)
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" describe --tags --always --dirty
            WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
            RESULT_VARIABLE _maa_git_result
            OUTPUT_VARIABLE _maa_git_version
            ERROR_QUIET
            OUTPUT_STRIP_TRAILING_WHITESPACE)
        if(_maa_git_result EQUAL 0 AND NOT _maa_git_version STREQUAL "")
            set(MAA_HASH_VERSION "${_maa_git_version}" CACHE STRING "MaaCore version" FORCE)
        endif()
    endif()
endif()

# Dependency layout:
#   deps/      prebuilt third-party binaries (OpenCV / ONNXRuntime / fastdeploy / Boost / zlib)
#              Provisioned by tools/fetch-deps.ps1 from a pinned release asset; not tracked.
#   MaaUtils/  vendored source, built in-tree as a shared library.
set(MAADEPS_DIR "${PROJECT_SOURCE_DIR}/deps" CACHE PATH "Directory holding prebuilt MaaCore dependencies")
set(DEP_DEPS_DIR "${MAADEPS_DIR}")
set(MAA_DEPS_CONFIG "${PROJECT_SOURCE_DIR}/cmake/maadeps.cmake")

include(${PROJECT_SOURCE_DIR}/MaaUtils/MaaUtils.cmake)

add_library(HeaderOnlyLibraries INTERFACE)

if(NOT EXISTS "${MAA_PUBLIC_INCLUDE_DIR}")
    message(FATAL_ERROR "Missing include/upstream directory. Run tools/bootstrap-standalone.ps1 to prepare standalone dependencies.")
endif()

if(NOT EXISTS "${MAA_THIRDPARTY_INCLUDE_DIR}")
    message(FATAL_ERROR "Missing include/3rd directory. Run tools/bootstrap-standalone.ps1 to prepare standalone dependencies.")
endif()

target_include_directories(HeaderOnlyLibraries INTERFACE ${MAA_THIRDPARTY_INCLUDE_DIR})

file(GLOB maa_root_src CONFIGURE_DEPENDS *.h *.hpp *.cpp)
file(GLOB_RECURSE maa_tree_src CONFIGURE_DEPENDS
    Common/*.h Common/*.hpp Common/*.cpp
    Config/*.h Config/*.hpp Config/*.cpp
    Controller/*.h Controller/*.hpp Controller/*.cpp
    Task/*.h Task/*.hpp Task/*.cpp
    Ui/*.h Ui/*.hpp Ui/*.cpp
    Utils/*.h Utils/*.hpp Utils/*.cpp
    Vision/*.h Vision/*.hpp Vision/*.cpp)
set(maa_src ${maa_root_src} ${maa_tree_src})

# Exclude the platform-specific OCR implementation that is not needed on this target
if(ANDROID)
    list(FILTER maa_src EXCLUDE REGEX "OcrPack\\.cpp$")
else()
    list(FILTER maa_src EXCLUDE REGEX "OcrPackNcnn\\.cpp$")
endif()

if(WITH_MAC_SCK)
    if(APPLE)
        list(APPEND maa_src Controller/MacSCKHelper.mm)
    else()
        message(WARNING "MacSCK is only supported on Apple platforms, ignoring")
        set(WITH_MAC_SCK OFF)
    endif()
endif()

add_library(MaaCore SHARED ${maa_src})

if(WITH_EMULATOR_EXTRAS)
    if(EXISTS ${PROJECT_SOURCE_DIR}/3rdparty/EmulatorExtras/Mumu)
        target_include_directories(MaaCore PUBLIC ${PROJECT_SOURCE_DIR}/3rdparty/EmulatorExtras)
    else()
        message(WARNING "EmulatorExtras not found, please run `git submodule update --init 3rdparty/EmulatorExtras`")
        set(WITH_EMULATOR_EXTRAS OFF)
    endif()
endif()

target_compile_definitions(MaaCore PRIVATE ASST_WITH_EMULATOR_EXTRAS=$<BOOL:${WITH_EMULATOR_EXTRAS}>)
target_compile_definitions(MaaCore PUBLIC ASST_WITH_EXTRA_CALLERS=$<BOOL:${WITH_EXTRA_CALLERS}>)
target_compile_definitions(MaaCore PRIVATE ASST_WITH_MAC_SCK=$<BOOL:${WITH_MAC_SCK}>)

target_include_directories(MaaCore PUBLIC ${MAA_PUBLIC_INCLUDE_DIR} PRIVATE .)
add_dependencies(MaaCore MaaUtils)
if(ANDROID)
    find_package(ncnn REQUIRED)
    find_package(polyclipping CONFIG REQUIRED)
    target_link_libraries(MaaCore
        HeaderOnlyLibraries MaaUtils ${OpenCV_LIBS}
        ncnn
        polyclipping::polyclipping
        ONNXRuntime::ONNXRuntime ZLIB::ZLIB Boost::system)
    set_property(TARGET MaaCore PROPERTY NO_SYSTEM_FROM_IMPORTED TRUE)
    target_compile_options(MaaCore PRIVATE -Wno-c11-extensions)
else()
    target_link_libraries(MaaCore HeaderOnlyLibraries MaaUtils ${OpenCV_LIBS} fastdeploy_ppocr ONNXRuntime::ONNXRuntime ZLIB::ZLIB Boost::system)
endif()

if(WIN32)
    target_link_libraries(MaaCore ws2_32 dxgi)
endif()

if(LINUX)
    target_link_libraries(MaaCore pthread dl)
endif()

if(APPLE AND WITH_MAC_SCK)
    target_link_libraries(MaaCore "-framework Accelerate"
                                  "-framework Foundation"
                                  "-framework CoreGraphics"
                                  "-framework CoreMedia"
                                  "-framework CoreVideo"
                                  "-framework ScreenCaptureKit")
endif()

if(MSVC)
    set_target_properties(MaaCore PROPERTIES VS_DEBUGGER_VISUALIZER "${CMAKE_CURRENT_SOURCE_DIR}/meojson.natvis")
endif()

if(ANDROID)
    # Logger.hpp 直接调用 __android_log_*，需显式链接 liblog；
    # dl 由 ncnn 的 INTERFACE_LINK_LIBRARIES 传递，无需显式添加
    target_link_libraries(MaaCore log)
endif()

file(GLOB_RECURSE MaaCore_PUBLIC_HEADERS ${MAA_PUBLIC_INCLUDE_DIR}/*.h)
target_sources(MaaCore PUBLIC ${MaaCore_PUBLIC_HEADERS})
set_target_properties(MaaCore PROPERTIES PUBLIC_HEADER "${MaaCore_PUBLIC_HEADERS}")

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} FILES ${maa_src})


if(WIN32)
    # 注意：相比VS版本缺少了 -D_CONSOLE -D_WINDLL 两项
    target_compile_definitions(MaaCore PRIVATE ASST_DLL_EXPORTS _UNICODE UNICODE)
endif()

if(APPLE)
    set_target_properties(MaaCore PROPERTIES INSTALL_RPATH "@loader_path/")
    set_target_properties(MaaCore PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE)
    set_target_properties(MaaUtils PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE)
elseif(UNIX)
    set_target_properties(MaaCore PROPERTIES INSTALL_RPATH "$ORIGIN/")
endif()

maadeps_install(.)
install(TARGETS MaaUtils ${MaaCore_install_flatten_args})
install(TARGETS MaaCore ${MaaCore_install_flatten_args})

if(WIN32)
    add_custom_command(
        TARGET MaaCore
        POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory_if_different
        "${MAADEPS_DIR}/runtime/${MAADEPS_TRIPLET}/$<$<CONFIG:Debug>:msvc-debug/>"
        $<TARGET_FILE_DIR:MaaCore>
        COMMAND_EXPAND_LISTS)
endif()

if(ANDROID)
    if(CMAKE_STRIP)
        add_custom_command(
            TARGET MaaCore
            POST_BUILD
            COMMAND ${CMAKE_STRIP} --strip-all $<TARGET_FILE:MaaCore>
            COMMENT "Stripping MaaCore for Android")
    else()
        message(WARNING "CMAKE_STRIP not found, Android library will not be stripped")
    endif()
endif()
