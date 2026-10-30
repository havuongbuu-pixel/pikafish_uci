# Build a private, patched source tree. Headers and implementation must come
# from the same tree: the embedded-host patch changes Network::verify's return
# type, and mixing original and patched declarations violates the C++ ODR.
foreach(required IN ITEMS PIKAFISH_INPUT_ROOT PIKAFISH_OUTPUT_ROOT PIKAFISH_PATCH_ROOT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} must be provided")
  endif()
endforeach()
if(NOT EXISTS "${PIKAFISH_INPUT_ROOT}/src/main.cpp")
  message(FATAL_ERROR "Missing pinned Pikafish source")
endif()
find_package(Git REQUIRED)
get_filename_component(input_root "${PIKAFISH_INPUT_ROOT}" REALPATH)
get_filename_component(output_root "${PIKAFISH_OUTPUT_ROOT}" REALPATH)
get_filename_component(output_name "${output_root}" NAME)
string(FIND "${output_root}/" "${input_root}/" inside_input)
if(NOT output_name STREQUAL "upstream" OR inside_input EQUAL 0)
  message(FATAL_ERROR "Pikafish snapshot must be a build-owned upstream directory")
endif()
# Do not retain headers from a previously selected upstream revision. Only
# remove the verified source snapshot, never the caller's build directory.
get_filename_component(output_source "${output_root}/src" REALPATH)
string(FIND "${output_source}/" "${output_root}/" inside_output)
if(NOT inside_output EQUAL 0)
  message(FATAL_ERROR "Pikafish source snapshot escapes its build directory")
endif()
file(REMOVE_RECURSE "${output_root}/src")
file(MAKE_DIRECTORY "${PIKAFISH_OUTPUT_ROOT}/src")
file(COPY "${PIKAFISH_INPUT_ROOT}/src/" DESTINATION "${PIKAFISH_OUTPUT_ROOT}/src")
# Git for Windows checks out this submodule as CRLF. Keep patch application
# independent of checkout settings without changing the submodule itself.
file(GLOB_RECURSE text_sources
  "${PIKAFISH_OUTPUT_ROOT}/src/*.cpp" "${PIKAFISH_OUTPUT_ROOT}/src/*.h")
foreach(path IN LISTS text_sources)
  file(READ "${path}" source)
  string(REPLACE "\r\n" "\n" source "${source}")
  file(WRITE "${path}" "${source}")
endforeach()
foreach(name IN ITEMS
    0001-rename-main.patch
    0002-embedded-nnue-failure.patch
    0003-android-asset-network.patch)
  execute_process(
    # An absolute --directory still lets Git silently skip paths when invoked
    # below another repository's root (Gradle's .cxx cache is such a directory).
    # Make the snapshot the explicit work tree and run from its root instead.
    COMMAND "${GIT_EXECUTABLE}" "--work-tree=${output_root}" -C "${output_root}"
      apply --no-index "${PIKAFISH_PATCH_ROOT}/${name}"
    RESULT_VARIABLE result ERROR_VARIABLE error)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot apply reviewed Pikafish patch ${name}: ${error}")
  endif()
endforeach()

function(require_snapshot_marker relative marker)
  file(READ "${output_root}/${relative}" source)
  string(FIND "${source}" "${marker}" found)
  if(found EQUAL -1)
    message(FATAL_ERROR "Pikafish patch was not applied to ${relative}")
  endif()
endfunction()
require_snapshot_marker(src/main.cpp "int pikafish_main(")
require_snapshot_marker(src/nnue/network.h "bool          verify(")
require_snapshot_marker(src/nnue/network.cpp "PIKAFISH_NNUE_LOAD_FAILED")
require_snapshot_marker(src/nnue/network.cpp "PikafishNnueStream::open(")
require_snapshot_marker(src/nnue/network.cpp "input->verified()")
