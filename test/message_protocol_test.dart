@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

void main() {
  group('EnvelopeKind', () {
    test('round-trips through its wire strings', () {
      for (final kind in EnvelopeKind.values) {
        expect(EnvelopeKind.fromWire(kind.wire), kind);
      }
    });

    test('unknown wire string parses to null', () {
      expect(EnvelopeKind.fromWire('nonsense'), isNull);
    });
  });

  group('Envelope', () {
    test('constructors set the discriminating fields', () {
      const ready = Envelope.ready();
      expect(ready.kind, EnvelopeKind.ready);
      expect(ready.protocol, protocolVersion);

      const task = Envelope.task(id: 7, task: 'blur', payload: 42);
      expect(task.kind, EnvelopeKind.task);
      expect(task.id, 7);
      expect(task.task, 'blur');
      expect(task.payload, 42);

      const result = Envelope.result(id: 7, payload: 'done');
      expect(result.kind, EnvelopeKind.result);
      expect(result.payload, 'done');

      const error = Envelope.error(
        id: 7,
        errorMessage: 'boom',
        errorStack: 'stack',
        errorType: 'StateError',
      );
      expect(error.kind, EnvelopeKind.error);
      expect(error.errorMessage, 'boom');

      const boot = Envelope.bootError(errorMessage: 'no wasm');
      expect(boot.kind, EnvelopeKind.bootError);
      expect(boot.id, isNull);
    });

    test('toString names the kind and key fields', () {
      expect(
        const Envelope.task(id: 3, task: 'sieve').toString(),
        'Envelope.task(id: 3, task: sieve)',
      );
    });
  });

  group('TaskRegistry', () {
    test('registers and dispatches typed handlers', () async {
      final registry = TaskRegistry()
        ..register<int, int>('double', (n) => n * 2)
        ..register<String, String>('shout', (s) async => s.toUpperCase());
      expect(registry.contains('double'), isTrue);
      expect(registry.taskNames, unorderedEquals(['double', 'shout']));
      expect(await registry.dispatch('double', 21), 42);
      expect(await registry.dispatch('shout', 'hey'), 'HEY');
    });

    test('rejects duplicate task names', () {
      final registry = TaskRegistry()..register<int, int>('t', (n) => n);
      expect(
        () => registry.register<int, int>('t', (n) => n),
        throwsArgumentError,
      );
    });

    test('unknown task throws UnknownTaskException listing known tasks', () {
      final registry = TaskRegistry()..register<int, int>('known', (n) => n);
      expect(
        () => registry.dispatch('missing', null),
        throwsA(
          isA<UnknownTaskException>()
              .having((e) => e.taskName, 'taskName', 'missing')
              .having((e) => e.knownTasks, 'knownTasks', ['known']).having(
                  (e) => e.toString(), 'toString', contains('known')),
        ),
      );
    });

    test('payload of the wrong type surfaces as a dispatch error', () {
      final registry = TaskRegistry()..register<int, int>('inc', (n) => n + 1);
      expect(() => registry.dispatch('inc', 'not an int'), throwsA(anything));
    });
  });

  group('assertEncodablePayload', () {
    test('accepts the full supported table', () {
      final buffers = <Object?>[
        null,
        true,
        1,
        1.5,
        'text',
        Int8List.fromList([1]),
        Uint8List.fromList([2]),
        Int16List.fromList([3]),
        Uint16List.fromList([4]),
        Int32List.fromList([5]),
        Uint32List.fromList([6]),
        Float32List.fromList([7]),
        Float64List.fromList([8]),
        ByteData(4),
        Uint8List(4).buffer,
        FakeSharedBuffer(16),
        <Object?>[1, 'two', null],
        <String, Object?>{
          'nested': <String, Object?>{'deep': true},
        },
      ];
      expect(() => assertEncodablePayload(buffers), returnsNormally);
    });

    test('rejects unsupported types, naming type and path', () {
      expect(
        () => assertEncodablePayload(<String, Object?>{
          'outer': <Object?>[1, DateTime(2026)],
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('DateTime'), contains(r'$.outer[1]')),
          ),
        ),
      );
    });

    test('rejects non-String map keys', () {
      expect(
        () => assertEncodablePayload(<Object?, Object?>{1: 'one'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Map key'),
          ),
        ),
      );
    });

    test('rejects integers beyond 2^53 - 1', () {
      expect(
          () => assertEncodablePayload(maxSafePayloadInteger), returnsNormally);
      expect(
        () => assertEncodablePayload(maxSafePayloadInteger + 1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('2^53'),
          ),
        ),
      );
      expect(
        () => assertEncodablePayload(-maxSafePayloadInteger - 1),
        throwsArgumentError,
      );
    });
  });

  group('collectTransferableBuffers', () {
    test('deduplicates views sharing one buffer', () {
      final bytes = Uint8List(16);
      final ints = bytes.buffer.asInt32List();
      final collected = collectTransferableBuffers(<Object?>[bytes, ints]);
      expect(collected, hasLength(1));
      // Not same(): on the VM every `.buffer` access returns a fresh wrapper
      // object; ByteBuffer equality compares the underlying buffer.
      expect(collected.single, equals(bytes.buffer));
    });

    test('collects distinct buffers, raw ByteBuffers, and nested values', () {
      final a = Uint8List(4);
      final b = Uint8List(4);
      final raw = Uint8List(4).buffer;
      final collected = collectTransferableBuffers(<String, Object?>{
        'a': a,
        'nested': <Object?>[b, raw],
        'scalar': 5,
      });
      expect(collected, hasLength(3));
    });

    test('skips SharedBuffer memory', () {
      final shared = FakeSharedBuffer(16);
      final plain = Uint8List(4);
      final collected = collectTransferableBuffers(<Object?>[shared, plain]);
      expect(collected, hasLength(1));
      expect(collected.single, equals(plain.buffer));
    });

    test('returns empty for scalar-only payloads', () {
      expect(collectTransferableBuffers(<Object?>[1, 'two', null]), isEmpty);
    });
  });

  group('simulateStructuredClone', () {
    test('deep-copies containers and typed data', () {
      final original = <String, Object?>{
        'bytes': Uint8List.fromList([1, 2, 3]),
        'list': <Object?>[
          1,
          <String, Object?>{'inner': 2.5},
        ],
      };
      final clone = simulateStructuredClone(original)! as Map<String, Object?>;

      (original['bytes']! as Uint8List)[0] = 99;
      (original['list']! as List<Object?>)[0] = 'mutated';

      expect(clone['bytes'], Uint8List.fromList([1, 2, 3]));
      final clonedList = clone['list']! as List<Object?>;
      expect(clonedList[0], 1);
      expect((clonedList[1]! as Map<String, Object?>)['inner'], 2.5);
    });

    test('preserves typed-data flavor and ByteData contents', () {
      final data = ByteData(8)..setFloat64(0, 3.5);
      final clone = simulateStructuredClone(data)! as ByteData;
      expect(clone.getFloat64(0), 3.5);
      data.setFloat64(0, 9.9);
      expect(clone.getFloat64(0), 3.5);

      expect(
        simulateStructuredClone(Float32List.fromList([1.5])),
        isA<Float32List>(),
      );
    });

    test('passes SharedBuffer through by reference', () {
      final shared = FakeSharedBuffer(16);
      final clone =
          simulateStructuredClone(<Object?>[shared])! as List<Object?>;
      expect(clone.single, same(shared));
    });

    test('rejects unsupported values like the wire codec would', () {
      expect(
        () => simulateStructuredClone(<Object?>[DateTime(2026)]),
        throwsArgumentError,
      );
    });
  });
}
