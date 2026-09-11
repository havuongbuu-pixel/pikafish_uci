import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'uci_transport.dart';

/// [UciTransport] backed by Pikafish linked into this process.
///
/// The engine runs on a native thread; `pikafish_read` blocks whichever thread
/// calls it, so reading happens on a dedicated Dart isolate and never on the
/// isolate that drives the UI. Writes are cheap and go direct.
///
/// The engine starts exactly once per process. There is no restart: Pikafish
/// holds global state that is not built for teardown, so [dispose] ends the
/// engine for the lifetime of the app.
final class PikafishTransport implements UciTransport {
  PikafishTransport._(this._bindings, this._reader, this._controller);

  final PikafishBindings _bindings;
  final Isolate _reader;
  final StreamController<String> _controller;
  bool _disposed = false;

  static bool _startedInThisProcess = false;

  /// Physical RAM visible to the process, without starting the engine.
  ///
  /// Zero means the native platform could not report it; callers must retain
  /// conservative settings in that case.
  static int physicalMemoryMb({String? libraryPath}) => PikafishBindings(
    PikafishBindings.openLibrary(path: libraryPath),
  ).physicalMemoryMb();

  /// Whether the engine can read its NNUE network out of the app package.
  ///
  /// True only on Android, and only after the Activity has handed over an
  /// AssetManager. Callers use it to decide between pointing EvalFile at an
  /// asset and materialising the network as a file first.
  ///
  /// Never throws. On a host with no engine library at all - a unit test on a
  /// desktop, say - the answer is simply no.
  static bool canReadAssets({String? libraryPath}) {
    try {
      return PikafishBindings(
        PikafishBindings.openLibrary(path: libraryPath),
      ).canReadAssets;
    } on Object {
      return false;
    }
  }

  /// Starts the engine and begins pumping its output.
  ///
  /// [libraryPath] overrides library lookup, for desktop builds and tests.
  static Future<PikafishTransport> start({String? libraryPath}) async {
    if (_startedInThisProcess) {
      throw const UciTransportException(
        'the engine can only be started once per process',
        status: PikafishStatus.alreadyStarted,
      );
    }

    final bindings = PikafishBindings(
      PikafishBindings.openLibrary(path: libraryPath),
    );
    final status = bindings.start();
    if (status != PikafishStatus.ok) {
      throw UciTransportException(
        'could not start the engine: ${PikafishStatus.describe(status)}',
        status: status,
      );
    }
    _startedInThisProcess = true;

    final controller = StreamController<String>.broadcast();
    final fromReader = ReceivePort();
    final reader = await Isolate.spawn(
      _readLoop,
      _ReaderConfig(fromReader.sendPort, libraryPath),
      debugName: 'pikafish-reader',
    );

    fromReader.listen((Object? message) {
      if (message is String) {
        if (!controller.isClosed) controller.add(message);
      } else {
        // Sentinel: the engine closed its output stream.
        if (!controller.isClosed) controller.close();
        fromReader.close();
      }
    });

    return PikafishTransport._(bindings, reader, controller);
  }

  @override
  Stream<String> get lines => _controller.stream;

  @override
  void send(String command) {
    if (_disposed) {
      throw const UciTransportException('transport already disposed');
    }
    final status = _bindings.writeCommand(command);
    if (status != PikafishStatus.ok) {
      throw UciTransportException(
        'could not send "$command": ${PikafishStatus.describe(status)}',
        status: status,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // `quit` makes the engine's UCI loop return, which closes its output pipe
    // and unblocks the reader isolate so it can exit on its own.
    try {
      _bindings.writeCommand('quit');
    } on Object {
      // The engine may already be gone; shutdown proceeds either way.
    }

    await _controller.done.timeout(
      const Duration(seconds: 2),
      onTimeout: () async {
        _reader.kill(priority: Isolate.immediate);
      },
    );
    if (!_controller.isClosed) await _controller.close();
  }
}

class _ReaderConfig {
  const _ReaderConfig(this.sendPort, this.libraryPath);

  final SendPort sendPort;
  final String? libraryPath;
}

/// Runs on the reader isolate: blocks on the engine's output and forwards
/// complete lines. Partial lines are held until their newline arrives, since
/// one `read` can split a line or carry several.
void _readLoop(_ReaderConfig config) {
  final bindings = PikafishBindings(
    PikafishBindings.openLibrary(path: config.libraryPath),
  );

  const bufferSize = 4096;
  final buffer = malloc<Uint8>(bufferSize);
  final pending = StringBuffer();

  try {
    while (true) {
      final read = bindings.read(buffer, bufferSize);
      if (read <= 0) break; // 0 = engine exited; negative = pipe error.

      pending.write(
        utf8.decode(buffer.asTypedList(read), allowMalformed: true),
      );
      final text = pending.toString();
      pending.clear();

      var start = 0;
      for (var i = 0; i < text.length; i++) {
        if (text.codeUnitAt(i) != 0x0a) continue;
        var end = i;
        if (end > start && text.codeUnitAt(end - 1) == 0x0d) end--;
        config.sendPort.send(text.substring(start, end));
        start = i + 1;
      }
      if (start < text.length) pending.write(text.substring(start));
    }
  } finally {
    malloc.free(buffer);
    config.sendPort.send(null); // sentinel: output stream closed
  }
}
