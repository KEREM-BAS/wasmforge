@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

void main() {
  group('real (non-isolated) test-server environment', () {
    test('gating reports unsupported without crashing', () {
      expect(SharedBuffer.isSupported, isFalse);
      expect(SharedBuffer.tryAllocate(64), isNull);
      expect(() => SharedBuffer.allocate(64), throwsStateError);
    });
  });

  group('FakeJsEnvironment(sharedArrayBuffer: true)', () {
    late FakeJsEnvironment environment;

    setUp(() {
      environment = FakeJsEnvironment(
        sharedArrayBuffer: true,
        crossOriginIsolated: true,
      );
      environment.install();
    });
    tearDown(() => environment.uninstall());

    test('gating flips on (simulated isolated state)', () {
      expect(isCrossOriginIsolated, isTrue);
      expect(SharedBuffer.isSupported, isTrue);
      expect(SharedBuffer.tryAllocate(32), isNotNull);
    });

    test('VIEW semantics: atomics and asInt32List alias the same memory', () {
      final buffer = SharedBuffer.allocate(32);
      buffer.atomicStore(0, 42);
      expect(
        buffer.asInt32List()[0],
        42,
        reason: 'toDart must produce a view, not a copy',
      );
      final view = buffer.asInt32List();
      view[3] = 99;
      expect(
        buffer.atomicLoad(3),
        99,
        reason: 'writes through the Dart list must be visible to Atomics',
      );
    });

    test('byte and float views alias the same memory', () {
      final buffer = SharedBuffer.allocate(32);
      expect(buffer.byteLength, 32);
      buffer.asInt32List()[0] = 0x01020304;
      expect(
          buffer.asUint8List().sublist(0, 4), containsAll(<int>[1, 2, 3, 4]));
      buffer.asFloat64List()[2] = 2.5;
      expect(buffer.asFloat64List()[2], 2.5);
    });

    test('atomicAdd returns the previous value and wraps int32', () {
      final buffer = SharedBuffer.allocate(16);
      expect(buffer.atomicAdd(0, 5), 0);
      expect(buffer.atomicAdd(0, 7), 5);
      expect(buffer.atomicLoad(0), 12);
      buffer.atomicStore(1, 0x7fffffff);
      expect(buffer.atomicAdd(1, 1), 0x7fffffff);
      expect(buffer.atomicLoad(1), -0x80000000);
    });

    test('atomic indices are range-checked', () {
      final buffer = SharedBuffer.allocate(16);
      expect(() => buffer.atomicLoad(-1), throwsRangeError);
      expect(() => buffer.atomicLoad(4), throwsRangeError);
      expect(() => buffer.atomicStore(4, 0), throwsRangeError);
    });
  });

  group('FakeJsEnvironment() — simulated non-isolated state', () {
    test('forces unsupported even where the engine could allocate', () {
      final environment = FakeJsEnvironment()..install();
      addTearDown(environment.uninstall);
      expect(isCrossOriginIsolated, isFalse);
      expect(SharedBuffer.isSupported, isFalse);
      expect(SharedBuffer.tryAllocate(8), isNull);
      expect(() => SharedBuffer.allocate(8), throwsStateError);
    });
  });
}
