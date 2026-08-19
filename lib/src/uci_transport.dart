/// A bidirectional UCI channel: lines out, commands in.
///
/// Everything above this interface — the request queue, option handling, the
/// parser, the app's gateways — depends only on this. That is what lets the
/// same session code run against the in-process FFI engine on mobile, a child
/// process on desktop, or a scripted fake in unit tests.
abstract interface class UciTransport {
  /// Engine output, one line per event, with newlines stripped.
  ///
  /// Closes when the engine exits. A broadcast stream: late listeners miss
  /// earlier lines, so subscribe before sending the command you care about.
  Stream<String> get lines;

  /// Sends one UCI command. A trailing newline is added by the transport.
  void send(String command);

  /// Shuts the transport down. For the in-process engine this ends the process's
  /// only engine instance and cannot be undone.
  Future<void> dispose();
}

class UciTransportException implements Exception {
  const UciTransportException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => status == null
      ? 'UciTransportException: $message'
      : 'UciTransportException: $message (status $status)';
}
