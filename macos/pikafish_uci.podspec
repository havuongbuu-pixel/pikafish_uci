#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
# Runs in-process, driven over dart:ffi's DynamicLibrary.process(), the same
# model as iOS (see ios/pikafish_uci.podspec for why this is a regular
# embedded framework rather than the static framework
# pikafish_flutter_project_structure.md §8 originally called for: nothing in
# the app statically references the four bridge functions, so a static
# archive never gets pulled into the final binary at all — confirmed here via
# integration_test/pikafish_smoke_test.dart, which is what actually runs the
# engine inside the compiled app and checks for a real bestmove, not just a
# successful compile).
require_relative '../src/generate_pikafish_sources'

# Writes generated/*.cpp: one forwarder per engine source plus the bridge, and
# the text-patched entry point. See generate_pikafish_sources.rb for why this
# indirection exists — source_files below cannot reference ../src or
# ../third_party directly.
PikafishSources.generate!(__dir__)

Pod::Spec.new do |s|
  s.name             = 'pikafish_uci'
  s.version          = '0.1.0'
  s.summary          = 'Pikafish HCE xiangqi engine exposed to Flutter over FFI.'
  s.description      = 'In-process FFI bridge to the Pikafish HCE xiangqi engine.'
  s.homepage         = 'https://github.com/havuongbuu-pixel/HocVienCoTuong'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'Hoc Vien Co Tuong' => 'havuongbuu@gmail.com' }
  s.source           = { :path => '.' }

  s.source_files = 'generated/*.cpp'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # generated/pikafish_main.cpp lives outside third_party/Pikafish-HCE/src,
    # so its #include "bitboard.h" (relative to the upstream tree) needs this
    # to resolve — mirrors CMakeLists.txt's target_include_directories.
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/../third_party/Pikafish-HCE/src',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    # Per-arch defines mirror src/pikafish_arch.cmake's non-Android branches
    # exactly. Verify any change against that file, not this one.
    'GCC_PREPROCESSOR_DEFINITIONS' => 'NDEBUG=1 USE_PTHREADS=1',
    'GCC_PREPROCESSOR_DEFINITIONS[arch=arm64]' =>
      '$(inherited) IS_64BIT=1 USE_POPCNT=1 USE_NEON=8',
    'GCC_PREPROCESSOR_DEFINITIONS[arch=x86_64]' =>
      '$(inherited) IS_64BIT=1 USE_POPCNT=1 USE_SSE41=1 USE_SSSE3=1 USE_SSE2=1',
    'OTHER_CFLAGS[arch=x86_64]' => '-msse -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt',
    'OTHER_CPLUSPLUSFLAGS[arch=x86_64]' => '-msse -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt',
  }
  s.compiler_flags = '-fno-exceptions', '-Wall'
  s.swift_version = '5.0'
end
