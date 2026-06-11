// Smoke entrypoint proving the public library compiles under dart2wasm.
// Compiled (not run) by tool/check.sh via `dart compile wasm`. As the public
// surface grows, this file references it so the web implementation branches
// are pulled into the compile.
import 'package:wasmforge/wasmforge.dart';

void main() {
  print('wasmforge $wasmforgeVersion');
  print(detectCapabilityMatrix());
  print('SharedBuffer.isSupported=${SharedBuffer.isSupported}');
  final buffer = SharedBuffer.tryAllocate(64);
  print('tryAllocate(64) -> ${buffer?.byteLength} bytes');
  assertEncodablePayload(<String, Object?>{'n': 1, 'ok': true});
  final registry = TaskRegistry()..register<int, int>('inc', (n) => n + 1);
  print('registry tasks: ${registry.taskNames.join(', ')}');
  // Reference the pool and worker runtime so dart2wasm compiles them.
  final pool = WorkerPool(
    workerEntrypoint: Uri.parse('workers/smoke.wasm'),
    size: 1,
  );
  print('pool size: ${pool.size}, runWorker: ${runWorker.runtimeType}');
}
