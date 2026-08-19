# Mirrors the per-ARCH flag logic in third_party/Pikafish-HCE/src/Makefile.
#
# The upstream Makefile is the authority. Any change here must keep
# tools/bench_parity.sh passing: a build whose node count differs from the
# Makefile reference is compiling different code, however well it runs.
#
# Note the Makefile adds -mfpu=neon for armv7 only on Linux with a non-NDK
# compiler, so the Android armeabi-v7a build intentionally omits it.

function(pikafish_apply_arch_flags target)
  if(ANDROID)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
      target_compile_definitions(${target} PRIVATE IS_64BIT USE_POPCNT USE_NEON=8)
    elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
      target_compile_definitions(${target} PRIVATE USE_POPCNT USE_NEON=7)
    elseif(ANDROID_ABI STREQUAL "x86_64")
      target_compile_definitions(${target} PRIVATE
        IS_64BIT USE_POPCNT USE_SSE41 USE_SSSE3 USE_SSE2)
      target_compile_options(${target} PRIVATE
        -msse -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt)
    else()
      message(FATAL_ERROR "pikafish: unsupported ANDROID_ABI '${ANDROID_ABI}'")
    endif()

  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
    target_compile_definitions(${target} PRIVATE IS_64BIT USE_POPCNT USE_NEON=8)

  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
    target_compile_definitions(${target} PRIVATE
      IS_64BIT USE_POPCNT USE_SSE41 USE_SSSE3 USE_SSE2)
    target_compile_options(${target} PRIVATE
      -m64 -msse -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt)

  else()
    message(FATAL_ERROR
      "pikafish: no arch mapping for '${CMAKE_SYSTEM_PROCESSOR}'. Add one here "
      "and mirror the matching ARCH block in the upstream Makefile.")
  endif()
endfunction()
