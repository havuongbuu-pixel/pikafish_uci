cmake_minimum_required(VERSION 3.18)
project(pikafish_uci LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(PIKAFISH_BUILD_CLI "Build the desktop CLI used by bench_parity.sh" ON)

include(${CMAKE_CURRENT_LIST_DIR}/pikafish_arch.cmake)

set(PIKAFISH_SRC_DIR ${CMAKE_CURRENT_LIST_DIR}/../third_party/Pikafish-HCE/src)

if(NOT EXISTS ${PIKAFISH_SRC_DIR}/main.cpp)
  message(FATAL_ERROR
    "Pikafish-HCE sources missing. Run: git submodule update --init --recursive")
endif()

# Mirrors SRCS in the upstream Makefile, verbatim and in order.
# nnue/ is deliberately absent: the HCE fork ships the directory but does not
# compile it. Do not replace this with a glob.
set(PIKAFISH_SOURCES
  benchmark.cpp bitboard.cpp evaluate.cpp main.cpp material.cpp
  misc.cpp movegen.cpp movepick.cpp position.cpp psqt.cpp endgame.cpp
  search.cpp thread.cpp timeman.cpp tt.cpp uci.cpp ucioption.cpp tune.cpp)
list(TRANSFORM PIKAFISH_SOURCES PREPEND ${PIKAFISH_SRC_DIR}/)

find_package(Threads REQUIRED)

add_library(pikafish_core STATIC ${PIKAFISH_SOURCES})
target_include_directories(pikafish_core PUBLIC ${PIKAFISH_SRC_DIR})
target_compile_definitions(pikafish_core PRIVATE NDEBUG USE_PTHREADS)
target_compile_options(pikafish_core PRIVATE
  -Wall -Wcast-qual -fno-exceptions -O3)
target_link_libraries(pikafish_core PUBLIC Threads::Threads)
pikafish_apply_arch_flags(pikafish_core)
# Hidden by default so the shared library exports only the four functions
# marked PIKAFISH_EXPORT. Without this the engine's own renamed entry point
# leaks into the dynamic symbol table and the FFI contract stops being obvious.
set_target_properties(pikafish_core PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

# main() was renamed to pikafish_main() by patches/0001-rename-main.patch, so
# the entry point is supplied here. Stage B links the same core into a shared
# library alongside the FFI bridge instead.
if(PIKAFISH_BUILD_CLI AND NOT ANDROID)
  add_executable(pikafish_cli ${CMAKE_CURRENT_LIST_DIR}/pikafish_cli.cpp)
  target_link_libraries(pikafish_cli PRIVATE pikafish_core)
endif()

# The FFI surface: engine core plus the pipe/thread bridge. This is the library
# Dart opens on Android and links into the app binary on iOS.
add_library(pikafish_uci SHARED ${CMAKE_CURRENT_LIST_DIR}/pikafish_bridge.cpp)
target_link_libraries(pikafish_uci PRIVATE pikafish_core)
target_compile_options(pikafish_uci PRIVATE -Wall -fno-exceptions -O3)
set_target_properties(pikafish_uci PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

if(ANDROID)
  # Google Play rejects apps targeting Android 15+ whose native libraries are
  # not 16 KB page aligned. NDK r28+ does this by default; the flag is kept so
  # an older pinned NDK cannot silently produce a rejectable artifact.
  # tools/android_build.sh verifies the shipped .so rather than trusting this.
  target_link_options(pikafish_uci PRIVATE
    -Wl,-z,max-page-size=16384
    # ANDROID_STL=c++_static pulls libc++ in as an archive, and archive symbols
    # keep default visibility, so without this the library re-exports the whole
    # of libc++ from its dynamic symbol table. That is a well-known source of
    # symbol collisions with other native libraries in the same process.
    # --exclude-libs hides everything that arrived via an archive, including our
    # own engine core; the four bridge functions are compiled straight into this
    # target and keep their explicit default visibility.
    -Wl,--exclude-libs,ALL)
endif()

option(PIKAFISH_BUILD_SMOKE "Build the native bridge smoke test" ON)
if(PIKAFISH_BUILD_SMOKE AND NOT ANDROID)
  add_executable(pikafish_bridge_smoke
    ${CMAKE_CURRENT_LIST_DIR}/../tools/bridge_smoke.cpp)
  target_link_libraries(pikafish_bridge_smoke PRIVATE pikafish_uci)
endif()
