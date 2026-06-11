// Copies wasmforge's worker bootstrap JS into a consumer project:
//
//   dart run wasmforge:copy_bootstrap [target-directory]
//
// The target defaults to `web`. Typically run next to the worker compile
// step, e.g.:
//
//   dart compile wasm lib/worker/my_worker.dart -o web/workers/my_worker.wasm
//   dart run wasmforge:copy_bootstrap web/workers
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    stderr.writeln('usage: dart run wasmforge:copy_bootstrap [target-dir]');
    exitCode = 64;
    return;
  }
  final targetDir = args.isEmpty ? 'web' : args.first;
  final assetUri = await Isolate.resolvePackageUri(
    Uri.parse('package:wasmforge/src/assets/wasmforge_worker_bootstrap.js'),
  );
  if (assetUri == null) {
    stderr.writeln(
      'copy_bootstrap: could not resolve the wasmforge package asset; run '
      'this via `dart run wasmforge:copy_bootstrap` from a project that '
      'depends on wasmforge.',
    );
    exitCode = 1;
    return;
  }
  final destination = Directory(targetDir);
  destination.createSync(recursive: true);
  final outPath =
      '${destination.path}${Platform.pathSeparator}wasmforge_worker_bootstrap.js';
  File.fromUri(assetUri).copySync(outPath);
  stdout.writeln('Copied wasmforge_worker_bootstrap.js -> $outPath');
}
