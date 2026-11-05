# Boost 1.89 config for the upstream-binary dependency layout.
#
# The headers are the official Boost 1.89 release. Only Boost.Regex needs to be
# compiled; Boost.System is header-only in this version.
#
# MaaCore uses the Boost.Process v1 API. Boost 1.89's monolithic release moved
# that API into boost::process::v1; MaaUtils/BoostIO.hpp adapts to that layout.
# std::filesystem is used instead of Boost.Filesystem, and unused Asio pieces
# (deadline_timer / stackful spawn) are disabled to avoid extra libraries.

set(Boost_VERSION 1.89.0)
set(Boost_VERSION_STRING 1.89.0)
set(Boost_LIB_VERSION "1_89")

get_filename_component(_BOOST_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(Boost_INCLUDE_DIRS "${_BOOST_PREFIX}/include")

if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED)
    set_target_properties(Boost::headers PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${Boost_INCLUDE_DIRS}"
        INTERFACE_COMPILE_DEFINITIONS "BOOST_PROCESS_USE_STD_FS;BOOST_ASIO_DISABLE_BOOST_DATE_TIME;BOOST_ASIO_DISABLE_BOOST_CONTEXT_FIBER")
endif()

if(NOT TARGET Boost::system)
    add_library(Boost::system INTERFACE IMPORTED)
    set_target_properties(Boost::system PROPERTIES
        INTERFACE_LINK_LIBRARIES Boost::headers)
endif()

if(NOT TARGET Boost::regex)
    add_library(Boost::regex STATIC IMPORTED)
    set_target_properties(Boost::regex PROPERTIES
        IMPORTED_CONFIGURATIONS "RELEASE;DEBUG"
        IMPORTED_LOCATION_RELEASE "${_BOOST_PREFIX}/lib/boost_regex.lib"
        IMPORTED_LOCATION_DEBUG "${_BOOST_PREFIX}/debug/lib/boost_regexd.lib"
        INTERFACE_INCLUDE_DIRECTORIES "${Boost_INCLUDE_DIRS}"
        INTERFACE_LINK_LIBRARIES Boost::system)
endif()

set(Boost_FOUND TRUE)
set(Boost_system_FOUND TRUE)
set(Boost_regex_FOUND TRUE)

unset(_BOOST_PREFIX)
