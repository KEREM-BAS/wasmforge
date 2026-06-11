@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

void main() {
  tearDown(clearCapabilityOverrides);

  test('every capability reports false off the web, without throwing', () {
    expect(isWeb, isFalse);
    expect(isCrossOriginIsolated, isFalse);
    expect(supportsWasmGc, isFalse);
  });

  test('overrides flip each getter independently', () {
    setCapabilityOverridesForTesting(
      const CapabilityOverrides(isWeb: true),
    );
    expect(isWeb, isTrue);
    expect(isCrossOriginIsolated, isFalse);
    expect(supportsWasmGc, isFalse);

    setCapabilityOverridesForTesting(
      const CapabilityOverrides(crossOriginIsolated: true, wasmGc: true),
    );
    expect(isWeb, isFalse);
    expect(isCrossOriginIsolated, isTrue);
    expect(supportsWasmGc, isTrue);
  });

  test('clearCapabilityOverrides restores real detection', () {
    setCapabilityOverridesForTesting(
      const CapabilityOverrides(isWeb: true, crossOriginIsolated: true),
    );
    expect(isWeb, isTrue);
    clearCapabilityOverrides();
    expect(isWeb, isFalse);
    expect(isCrossOriginIsolated, isFalse);
  });

  test('detectCapabilityMatrix snapshots the getters and prints readably', () {
    setCapabilityOverridesForTesting(
      const CapabilityOverrides(
        isWeb: true,
        crossOriginIsolated: true,
        wasmGc: false,
      ),
    );
    final matrix = detectCapabilityMatrix();
    expect(matrix.isWeb, isTrue);
    expect(matrix.isCrossOriginIsolated, isTrue);
    expect(matrix.supportsWasmGc, isFalse);
    expect(
      matrix.toString(),
      'CapabilityMatrix(isWeb: true, isCrossOriginIsolated: true, '
      'supportsWasmGc: false)',
    );
  });
}
