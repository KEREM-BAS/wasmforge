// Smoke entrypoint proving the public library compiles under dart2wasm.
// Compiled (not run) by tool/check.sh via `dart compile wasm`. As the public
// surface grows, this file references it so the web implementation branches
// are pulled into the compile.
import 'package:wasmforge/wasmforge.dart';

void main() {
  print('wasmforge $wasmforgeVersion');
  print('isWeb=$isWeb');
  print('isCrossOriginIsolated=$isCrossOriginIsolated');
  print('supportsWasmGc=$supportsWasmGc');
  print(detectCapabilityMatrix());
}
