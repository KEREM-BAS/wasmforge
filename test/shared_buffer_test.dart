@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

void main() {
  group('SharedBuffer gating off the web', () {
    test('isSupported is false and never throws', () {
      expect(SharedBuffer.isSupported, isFalse);
    });

    test('tryAllocate returns null (graceful path)', () {
      expect(SharedBuffer.tryAllocate(64), isNull);
    });

    test('tryAllocate still rejects negative lengths as a caller bug', () {
      expect(() => SharedBuffer.tryAllocate(-1), throwsRangeError);
    });

    test('allocate throws a StateError pointing at the COOP/COEP docs', () {
      expect(
        () => SharedBuffer.allocate(64),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Cross-Origin-Embedder-Policy'),
              contains('tryAllocate'),
            ),
          ),
        ),
      );
    });
  });

  group('FakeSharedBuffer', () {
    test('reports its byteLength', () {
      expect(FakeSharedBuffer(64).byteLength, 64);
    });

    test('typed views alias the same memory', () {
      final buffer = FakeSharedBuffer(16);
      buffer.asInt32List()[0] = 0x01020304;
      final bytes = buffer.asUint8List();
      expect(bytes.sublist(0, 4), containsAll(<int>[1, 2, 3, 4]));

      buffer.asFloat64List()[1] = 2.5;
      expect(buffer.asFloat64List()[1], 2.5);
    });

    test('atomicAdd returns the previous value and accumulates', () {
      final buffer = FakeSharedBuffer(16);
      expect(buffer.atomicAdd(2, 5), 0);
      expect(buffer.atomicAdd(2, 7), 5);
      expect(buffer.atomicLoad(2), 12);
    });

    test('atomicStore/atomicLoad round-trip and alias the views', () {
      final buffer = FakeSharedBuffer(16);
      buffer.atomicStore(1, -123);
      expect(buffer.atomicLoad(1), -123);
      expect(buffer.asInt32List()[1], -123);
    });

    test('32-bit arithmetic wraps like JS Atomics', () {
      final buffer = FakeSharedBuffer(8);
      buffer.atomicStore(0, 0x7fffffff);
      expect(buffer.atomicAdd(0, 1), 0x7fffffff);
      expect(buffer.atomicLoad(0), -0x80000000);
    });

    test('atomic indices are range-checked in Int32 elements', () {
      final buffer = FakeSharedBuffer(16); // 4 Int32 slots
      expect(() => buffer.atomicLoad(-1), throwsRangeError);
      expect(() => buffer.atomicLoad(4), throwsRangeError);
      expect(() => buffer.atomicStore(4, 1), throwsRangeError);
      expect(() => buffer.atomicAdd(4, 1), throwsRangeError);
    });
  });
}
