@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

void main() {
  tearDown(clearCapabilityOverrides);

  test('isWeb is true under a web compiler', () {
    expect(isWeb, isTrue);
  });

  test('crossOriginIsolated reads safely on a non-isolated test server', () {
    // package:test's server sends no COOP/COEP headers, so this must be
    // false — and, critically, must not throw.
    expect(isCrossOriginIsolated, isFalse);
  });

  test('supportsWasmGc feature-detects via WebAssembly.validate', () {
    // Chrome has shipped WasmGC since 119; the suite runs on Chrome.
    expect(supportsWasmGc, isTrue);
  });

  test('overrides win over real detection on the web too', () {
    setCapabilityOverridesForTesting(
      const CapabilityOverrides(crossOriginIsolated: true, wasmGc: false),
    );
    expect(isCrossOriginIsolated, isTrue);
    expect(supportsWasmGc, isFalse);
    clearCapabilityOverrides();
    expect(isCrossOriginIsolated, isFalse);
    expect(supportsWasmGc, isTrue);
  });

  test('capability matrix snapshots web reality', () {
    final matrix = detectCapabilityMatrix();
    expect(matrix.isWeb, isTrue);
    expect(matrix.isCrossOriginIsolated, isFalse);
    expect(matrix.supportsWasmGc, isTrue);
  });
}
