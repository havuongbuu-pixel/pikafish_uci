foreach(required IN ITEMS
    PIKAFISH_MAIN_INPUT PIKAFISH_MAIN_PATCH PIKAFISH_MAIN_OUTPUT)
  if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} must be provided.")
  endif()
endforeach()

file(READ "${PIKAFISH_MAIN_INPUT}" input_source)
file(STRINGS "${PIKAFISH_MAIN_PATCH}" removed_lines
  REGEX "^[-]int main\\(")
file(STRINGS "${PIKAFISH_MAIN_PATCH}" added_lines
  REGEX "^[+]int pikafish_main\\(")

list(LENGTH removed_lines removed_count)
list(LENGTH added_lines added_count)
if(NOT removed_count EQUAL 1 OR NOT added_count EQUAL 1)
  message(FATAL_ERROR
    "The Pikafish entry-point patch must contain exactly one removed main() "
    "line and one added pikafish_main() line.")
endif()

list(GET removed_lines 0 old_line)
list(GET added_lines 0 new_line)
string(SUBSTRING "${old_line}" 1 -1 old_line)
string(SUBSTRING "${new_line}" 1 -1 new_line)
# Match the complete definition line. Current upstream also has a one-line
# UNIVERSAL_BINARY shim whose prefix is identical; replacing the prefix would
# corrupt that separate function.
string(APPEND old_line "\n")
string(APPEND new_line "\n")

string(REPLACE "${old_line}" "" without_old "${input_source}")
string(REPLACE "${new_line}" "" without_new "${input_source}")
string(LENGTH "${input_source}" input_length)
string(LENGTH "${without_old}" without_old_length)
string(LENGTH "${without_new}" without_new_length)
string(LENGTH "${old_line}" old_line_length)
string(LENGTH "${new_line}" new_line_length)
math(EXPR old_count
  "(${input_length} - ${without_old_length}) / ${old_line_length}")
math(EXPR new_count
  "(${input_length} - ${without_new_length}) / ${new_line_length}")

if(old_count EQUAL 1 AND new_count EQUAL 0)
  string(REPLACE "${old_line}" "${new_line}" output_source "${input_source}")
elseif(old_count EQUAL 0 AND new_count EQUAL 1)
  # Also accept a tree patched manually by tools/apply_patches.sh.
  set(output_source "${input_source}")
else()
  message(FATAL_ERROR
    "Pikafish main.cpp does not match either side of the published "
    "entry-point patch (main=${old_count}, pikafish_main=${new_count}).")
endif()

get_filename_component(output_dir "${PIKAFISH_MAIN_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${output_dir}")
set(temp_output "${PIKAFISH_MAIN_OUTPUT}.tmp")
file(WRITE "${temp_output}" "${output_source}")
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${temp_output}" "${PIKAFISH_MAIN_OUTPUT}"
  RESULT_VARIABLE copy_result)
file(REMOVE "${temp_output}")
if(NOT copy_result EQUAL 0)
  message(FATAL_ERROR "Could not write ${PIKAFISH_MAIN_OUTPUT}.")
endif()
