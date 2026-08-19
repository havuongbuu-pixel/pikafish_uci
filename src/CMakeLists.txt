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
set_target_properties(pikafish_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

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

option(PIKAFISH_BUILD_SMOKE "Build the native bridge smoke test" ON)
if(PIKAFISH_BUILD_SMOKE AND NOT ANDROID)
  add_executable(pikafish_bridge_smoke
    ${CMAKE_CURRENT_LIST_DIR}/../tools/bridge_smoke.cpp)
  target_link_libraries(pikafish_bridge_smoke PRIVATE pikafish_uci)
endif()
