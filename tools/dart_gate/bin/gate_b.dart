// Gate B (Dart half): drives PikafishTransport the way the stage-D session
// will, and measures that the blocking native read never stalls this isolate.
import 'dart:async';
import 'dart:io';

import '../../../lib/src/ffi_uci_transport.dart';

int failures = 0;
void check(String what, bool ok, [String detail = '']) {
  stderr.writeln('  ${what.padRight(46)} ${ok ? 'PASS' : 'FAIL'}'
      '${detail.isEmpty ? '' : '  $detail'}');
  if (!ok) failures++;
}

Future<String?> await_(Stream<String> lines, String prefix, Duration limit) {
  return lines
      .firstWhere((l) => l.startsWith(prefix))
      .timeout(limit, onTimeout: () => '')
      .then((l) => l.isEmpty ? null : l);
}

Future<void> main(List<String> args) async {
  stderr.writeln('dart transport gate');
  final transport = await PikafishTransport.start(libraryPath: args.first);
  final lines = transport.lines;

  transport.send('uci');
  final id = await await_(lines, 'id name', const Duration(seconds: 5));
  check('uci -> id name', id != null, id ?? '');
  check('uci -> uciok',
      await await_(lines, 'uciok', const Duration(seconds: 5)) != null);

  transport.send('isready');
  check('isready -> readyok',
      await await_(lines, 'readyok', const Duration(seconds: 5)) != null);

  transport.send('position startpos');
  transport.send('go depth 8');
  final bm = await await_(lines, 'bestmove', const Duration(seconds: 20));
  check('go depth 8 -> bestmove', bm != null, bm ?? '');
  check('bestmove is a uci move',
      bm != null && RegExp(r'^bestmove [a-i][0-9][a-i][0-9]').hasMatch(bm));

  // The point of the reader isolate: a long search must not stall this isolate.
  // A 10 ms timer over ~1.5 s should tick ~150 times; anything near zero means
  // the blocking read leaked onto this isolate and the UI would freeze.
  var ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
  transport.send('go depth 60');
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  transport.send('stop');
  final stopped = await await_(lines, 'bestmove', const Duration(seconds: 3));
  timer.cancel();
  check('stop -> bestmove within 3s', stopped != null);
  check('main isolate stayed responsive during search', ticks > 100, '$ticks ticks');

  final closed = lines.isEmpty.then((_) => true);
  await transport.dispose();
  check('dispose closes the line stream',
      await closed.timeout(const Duration(seconds: 3), onTimeout: () => false));

  stderr.writeln(failures == 0 ? 'GATE B (dart) PASS' : 'GATE B (dart) FAIL');
  exit(failures == 0 ? 0 : 1);
}
