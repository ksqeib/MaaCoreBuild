#pragma once

#define BOOST_PROCESS_USE_STD_FS 1

#include <boost/asio.hpp>

// Boost 1.89's monolithic release moved the v1 Process API into
// boost::process::v1. Modular/older Boost releases keep it at boost::process.
// Keep both layouts working without patching Boost itself.
#if defined(__has_include)
#  if __has_include(<boost/process/v1.hpp>)
#    include <boost/process/v1.hpp>
namespace boost
{
namespace process
{
using namespace v1;
}
}
#    ifdef _WIN32
#      include <boost/process/v1/extend.hpp>
#      include <boost/process/v1/windows.hpp>
#    endif
#  else
#    include <boost/process.hpp>
#    ifdef _WIN32
#      include <boost/process/extend.hpp>
#      include <boost/process/windows.hpp>
#    endif
#  endif
#else
#  include <boost/process.hpp>
#  ifdef _WIN32
#    include <boost/process/extend.hpp>
#    include <boost/process/windows.hpp>
#  endif
#endif
