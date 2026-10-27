// The float/double write-then-read fuzz on the web target.
//
//   dart run tool/web_float_fuzz.dart [seed] [rounds]
//
// Builds fuzz/float_roundtrip.dart with dart2wasm, the seed and the round
// count compiled in, and runs it under Node. dart2wasm once misconverted
// float and double bit patterns whose 32-bit halves are shaped like a
// signaling NaN (lib/src/float32.dart says how), which the VM never does, so
// a VM-only gate could not see it: this one runs where it happened.
//
// Everything it writes goes under .dart_tool/web_float_fuzz/.

import 'dart:io';

const String _node = '''
import { readFileSync } from 'node:fs';
const [, , mjs, wasm] = process.argv;
const module = await import(mjs);
const instance = await (await module.compile(readFileSync(wasm))).instantiate({});
instance.invokeMain();
''';

Future<int> _run(String executable, List<String> args, String cwd) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<void> main(List<String> args) async {
  final seed = args.isNotEmpty ? int.parse(args[0]) : 1;
  final rounds = args.length > 1 ? int.parse(args[1]) : 1000000;
  final root = File.fromUri(Platform.script).parent.parent.absolute.path;
  final work = Directory('$root/.dart_tool/web_float_fuzz');
  if (work.existsSync()) {
    work.deleteSync(recursive: true);
  }
  work.createSync(recursive: true);
  File('${work.path}/run.mjs').writeAsStringSync(_node);

  if (await _run(Platform.resolvedExecutable, [
        'compile',
        'wasm',
        '-DSEED=$seed',
        '-DROUNDS=$rounds',
        '-o',
        '${work.path}/main.wasm',
        'fuzz/float_roundtrip.dart',
      ], root) !=
      0) {
    stderr.writeln('web float fuzz: dart2wasm could not build the program');
    exit(1);
  }
  if (await _run('node', [
        '${work.path}/run.mjs',
        '${work.path}/main.mjs',
        '${work.path}/main.wasm',
      ], root) !=
      0) {
    stderr.writeln('web float fuzz: a float or double failed under dart2wasm');
    exit(1);
  }
}
