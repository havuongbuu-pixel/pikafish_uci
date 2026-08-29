import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Return codes mirrored from `src/pikafish_bridge.h`.
abstract final class PikafishStatus {
  static const int ok = 0;
  static const int alreadyStarted = -1;
  static const int notStarted = -2;
  static const int invalid = -3;
  static const int pipe = -4;
  static const int thread = -5;
  static const int io = -6;

  static String describe(int code) => switch (code) {
    ok => 'ok',
    alreadyStarted => 'engine already started',
    notStarted => 'engine not started',
    invalid => 'invalid argument',
    pipe => 'pipe or dup2 failed',
    thread => 'could not start the engine thread',
    io => 'pipe I/O failed',
    _ => 'unknown status $code',
  };
}

/// Thin hand-written bindings for the five C entry points.
///
/// Deliberately not generated: the surface is five stable functions declared in
/// a header we own, so ffigen would add a build-time dependency and a generated
/// file to review without removing any real work.
final class PikafishBindings {
  PikafishBindings(DynamicLibrary library)
    : start = library.lookupFunction<Int32 Function(), int Function()>(
        'pikafish_start',
      ),
      isRunning = library.lookupFunction<Int32 Function(), int Function()>(
        'pikafish_is_running',
      ),
      physicalMemoryMb = library
          .lookupFunction<Int64 Function(), int Function()>(
            'pikafish_physical_memory_mb',
          ),
      _write = library
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('pikafish_write'),
      read = library
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Int32),
            int Function(Pointer<Uint8>, int)
          >('pikafish_read');

  final int Function() start;
  final int Function() isRunning;
  final int Function() physicalMemoryMb;
  final int Function(Pointer<Utf8>) _write;
  final int Function(Pointer<Uint8>, int) read;

  int writeCommand(String command) {
    final encoded = command.toNativeUtf8();
    try {
      return _write(encoded);
    } finally {
      malloc.free(encoded);
    }
  }

  /// Opens the native library for the current platform.
  ///
  /// iOS and macOS load the embedded engine framework into the app process,
  /// so its symbols are already visible there. Android and desktop load a
  /// shared object. [path] overrides the lookup for tests and desktop builds.
  static DynamicLibrary openLibrary({String? path}) {
    if (path != null) return DynamicLibrary.open(path);
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    if (Platform.isWindows) return DynamicLibrary.open('pikafish_uci.dll');
    return DynamicLibrary.open('libpikafish_uci.so');
  }
}
