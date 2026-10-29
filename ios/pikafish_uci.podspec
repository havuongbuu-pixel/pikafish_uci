#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
# The engine has no fork/exec on iOS (the sandbox forbids it), so it runs
# in-process, driven over dart:ffi's DynamicLibrary.process(). See
# docs/engine/pikafish_hce_integration_plan.md §3.1 and
# pikafish_flutter_project_structure.md §8 — those docs assume a *static*
# framework, but that turns out not to work for a plugin with no Swift/ObjC
# entry point: nothing in the app statically references the five bridge
# functions (Dart finds them by name at runtime), so the linker never pulls
# their object files out of a static archive at all, `used` attribute or not
# — confirmed empirically on macOS (see integration_test/pikafish_smoke_test.dart,
# which failed against a static framework with the symbols entirely absent
# from the final binary, and passed once this became a regular embedded
# framework). A dynamic framework doesn't have that problem: dyld loads it
# whole at launch, in the same process as the app (fork/exec is irrelevant
# here — that constraint is about a *separate process*, which this isn't
# either way), and DynamicLibrary.process() sees its exports immediately.
require_relative '../src/generate_pikafish_sources'

# Writes generated/*.cpp: one forwarder per engine source plus the bridge, and
# the text-patched entry point. See generate_pikafish_sources.rb for why this
# indirection exists — source_files below cannot reference ../src or
# ../third_party directly.
PikafishSources.generate!(__dir__)

Pod::Spec.new do |s|
  s.name             = 'pikafish_uci'
  s.version          = '0.1.0'
  s.summary          = 'Pikafish NNUE xiangqi engine exposed to Flutter over FFI.'
  s.description      = 'In-process FFI bridge to the official Pikafish NNUE engine.'
  s.homepage         = 'https://github.com/havuongbuu-pixel/HocVienCoTuong'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'Hoc Vien Co Tuong' => 'havuongbuu@gmail.com' }
  s.source           = { :path => '.' }

  s.source_files = 'generated/*.{cpp,S}'

  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Generated sources live outside third_party/Pikafish/src,
    # so its #include "bitboard.h" (relative to the upstream tree) needs this
    # to resolve — mirrors CMakeLists.txt's target_include_directories.
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/generated/upstream/src" "$(PODS_TARGET_SRCROOT)/../src"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # Reproducible winner of tools/benchmark_apple_optimizations.sh. PGO was
    # only ~1% faster and its profdata is tied to the producing Xcode version;
    # Full LTO is the fastest reproducible configuration without a fragile
    # binary profile.
    'GCC_OPTIMIZATION_LEVEL[config=Release]' => '3',
    'GCC_OPTIMIZATION_LEVEL[config=Profile]' => '3',
    'LLVM_LTO[config=Release]' => 'YES',
    'LLVM_LTO[config=Profile]' => 'YES',
    'DEAD_CODE_STRIPPING[config=Release]' => 'YES',
    'DEAD_CODE_STRIPPING[config=Profile]' => 'YES',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    # Per-arch defines mirror src/pikafish_arch.cmake's non-Android branches
    # exactly. Verify any change against that file, not this one.
    'GCC_PREPROCESSOR_DEFINITIONS' => 'NDEBUG=1',
    'GCC_PREPROCESSOR_DEFINITIONS[arch=arm64]' =>
      '$(inherited) ARCH=armv8 IS_64BIT=1 USE_PREFETCH=1 USE_POPCNT=1 USE_NEON=8',
    'GCC_PREPROCESSOR_DEFINITIONS[arch=x86_64]' =>
      '$(inherited) ARCH=x86-64-sse41-popcnt IS_64BIT=1 USE_PREFETCH=1 USE_POPCNT=1 USE_SSE41=1 USE_SSSE3=1 USE_SSE2=1',
    'OTHER_CFLAGS[arch=x86_64]' => '-msse -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt',
    'OTHER_CPLUSPLUSFLAGS[arch=x86_64]' => '$(inherited) -msse -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt',
  }
  s.compiler_flags = '-funroll-loops', '-fno-exceptions', '-Wall'
  s.swift_version = '5.0'
end
