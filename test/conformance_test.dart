// The shared conformance corpus, run through this port's reader, writer and
// measure: the file system front of conformance_runner.dart, which holds the
// runner itself. See that file for what the runner checks and why.
//
//     dart run test/conformance_test.dart [--expect-failures <list>] [path ...]

import 'dart:io';

import 'conformance_dirs.dart';
import 'conformance_runner.dart';
import 'harness.dart';

/// The vector files under [paths]: a directory is enumerated, never named
/// file by file, so a newly vendored vector file runs without anyone editing
/// a list here.
List<File> _vectorFiles(List<String> paths) {
  final files = <File>[];
  for (final path in paths) {
    if (FileSystemEntity.isDirectorySync(path)) {
      files.addAll(
        Directory(
          path,
        ).listSync().whereType<File>().where((f) => f.path.endsWith('.txt')),
      );
    } else {
      files.add(File(path));
    }
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

void run([List<String> paths = const ['conformance']]) {
  test('conformance: the vendored corpus is present', () {
    for (final path in paths) {
      expect(
        FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
        '$path is missing: the corpus is vendored from mas-bandwidth/serialize',
      );
    }
  });

  final files = _vectorFiles([
    for (final path in paths)
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound)
        path,
  ]);

  test('conformance: the corpus holds vector files', () {
    // an empty corpus is a broken checkout and not a pass
    if (files.isEmpty) {
      failUnowned('${paths.join(' ')} holds no vector files');
    }
  });

  for (final file in files) {
    test('conformance: ${file.uri.pathSegments.last}', () {
      final vectors = runVectorFile(file.path, file.readAsStringSync());
      if (vectors == 0) {
        failUnowned('${file.path} holds no vectors');
      }
    });
  }

  test('conformance: the corpus ran', () {
    expect(vectorsChecked > 0, 'no vectors ran: an empty run is a failure');
    print('  ${corpusSummary(files.length)}');
  });
}

/// The names a `conformance-controls/<rule>.expected` file lists: one per
/// line, `#` comments and blank lines ignored.
Set<String> _expectedNames(String path) => {
  for (final line in File(path).readAsLinesSync())
    if (line.trim().isNotEmpty && !line.startsWith('#')) line.trim(),
};

/// Runs this suite on its own, so the interop job can hold this reader and
/// the pinned C++ reader to the same corpus in one place. test/all.dart calls
/// [run] directly.
///
///     dart run test/conformance_test.dart [--expect-failures <list>] [path ...]
///
/// With no path it runs conformance/, or the directory
/// `SERIALIZE_CONFORMANCE_DIR` names (conformance_dirs.dart), which is how the
/// nightly functional test runs the upstream corpus. With `--expect-failures`,
/// the run is a NEGATIVE CONTROL: it passes only when the vectors that fail
/// are exactly the ones the list names, and nothing else fails.
void main(List<String> args) {
  String? expectFailures;
  final paths = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--expect-failures' && i + 1 < args.length) {
      expectFailures = args[++i];
    } else {
      paths.add(args[i]);
    }
  }
  run(
    paths.isEmpty
        ? [conformanceDir(Directory.current.path, Platform.environment)]
        : paths,
  );
  final failed = summarize();
  if (expectFailures == null) {
    exit(failed > 0 ? 1 : 0);
  }

  final expected = _expectedNames(expectFailures);
  final missing = expected.difference(failedVectorNames);
  final extra = failedVectorNames.difference(expected);
  for (final name in missing) {
    print('CONTROL: $name did not fail, $expectFailures says it must');
  }
  for (final name in extra) {
    print('CONTROL: $name failed, $expectFailures does not list it');
  }
  if (unownedFailures > 0) {
    print('CONTROL: $unownedFailures failure(s) belong to no vector');
  }
  final exact = missing.isEmpty && extra.isEmpty && unownedFailures == 0;
  print(
    exact
        ? 'CONTROL: exactly the ${expected.length} expected vector(s) failed'
        : 'CONTROL: the failing set is not the expected set',
  );
  exit(exact ? 0 : 1);
}
