@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasmforge/src/core/interop_casts.dart';
import 'package:wasmforge/src/core/js_bindings.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

Object? roundTrip(Object? value) =>
    decodePayloadValue(encodePayloadValue(value));

void main() {
  group('codec round-trips', () {
    test('scalars', () {
      expect(roundTrip(null), isNull);
      expect(roundTrip(true), isTrue);
      expect(roundTrip(false), isFalse);
      expect(roundTrip(42), 42);
      expect(roundTrip(-1.5), -1.5);
      expect(roundTrip('héllo wörld ✓'), 'héllo wörld ✓');
      expect(roundTrip(maxSafePayloadInteger), maxSafePayloadInteger);
    });

    test('integral finite numbers decode as int (cross-compiler rule)', () {
      expect(roundTrip(2.0), 2);
      expect(roundTrip(2.0), isA<int>());
      expect(roundTrip(2.5), 2.5);
      expect(roundTrip(-0.0), 0);
      expect(
        roundTrip(double.nan),
        isA<double>().having((d) => d.isNaN, 'isNaN', isTrue),
      );
      expect(roundTrip(double.infinity), double.infinity);
      // Beyond ±2^53 stays double even when "whole".
      expect(roundTrip(1e300), 1e300);
      expect(roundTrip(1e300), isA<double>());
    });

    test('typed data preserves flavor and content', () {
      expect(
        roundTrip(Uint8List.fromList([1, 2, 255])),
        allOf(isA<Uint8List>(), equals(Uint8List.fromList([1, 2, 255]))),
      );
      expect(
        roundTrip(Int32List.fromList([-5, 1 << 30])),
        allOf(isA<Int32List>(), equals(Int32List.fromList([-5, 1 << 30]))),
      );
      expect(
        roundTrip(Float64List.fromList([3.25, -0.5])),
        allOf(isA<Float64List>(), equals(Float64List.fromList([3.25, -0.5]))),
      );
      final byteData = roundTrip(ByteData(8)..setFloat64(0, 6.5))! as ByteData;
      expect(byteData.getFloat64(0), 6.5);
      final buffer = roundTrip(Uint8List.fromList([9, 8]).buffer);
      expect((buffer! as ByteBuffer).asUint8List(), [9, 8]);
    });

    test('nested lists and maps round-trip deeply', () {
      final value = <String, Object?>{
        'list': <Object?>[
          1,
          'two',
          <String, Object?>{'inner': 3.5, 'flag': false},
        ],
        'empty': <Object?>[],
        'null': null,
      };
      final back = roundTrip(value);
      expect(back, value);
      expect(back, isA<Map<String, Object?>>());
      expect((back! as Map<String, Object?>)['list'], isA<List<Object?>>());
    });
  });

  group('codec rejections', () {
    test('unsupported types name the type and the path', () {
      expect(
        () => encodePayloadValue(<String, Object?>{
          'x': <Object?>[DateTime(2026)],
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('DateTime'), contains(r'$.x[0]')),
          ),
        ),
      );
    });

    test('integers beyond 2^53 - 1: rejected only with true 64-bit ints', () {
      final intsAreJsNumbers = identical(1.0, 1);
      if (intsAreJsNumbers) {
        // dart2js: the value is already a JS double; nothing to protect.
        expect(
          () => encodePayloadValue(maxSafePayloadInteger + 1),
          returnsNormally,
        );
      } else {
        // dart2wasm: a real int64 would silently lose precision — reject.
        expect(
          () => encodePayloadValue(maxSafePayloadInteger + 1),
          throwsArgumentError,
        );
      }
    });

    test('non-String map keys are rejected', () {
      expect(
        () => encodePayloadValue(<Object?, Object?>{1: 'one'}),
        throwsArgumentError,
      );
    });

    test('decoding a JS function is rejected', () {
      final JSFunction function = (() {}).toJS;
      expect(() => decodePayloadValue(function), throwsArgumentError);
    });
  });

  group('structuredClone and transferables', () {
    test('an encoded payload survives a real structured clone', () {
      final encoded = encodePayloadValue(<String, Object?>{
        'data': Uint8List.fromList([7, 7, 7]),
        'n': 3,
      });
      final cloned = structuredClone(encoded);
      expect(decodePayloadValue(cloned), <String, Object?>{
        'data': Uint8List.fromList([7, 7, 7]),
        'n': 3,
      });
    });

    test('collectJsTransferables walks the encoded tree', () {
      final encoded = encodePayloadValue(<String, Object?>{
        'a': Uint8List.fromList([1]),
        'nested': <Object?>[
          Int32List.fromList([2]),
        ],
        'raw': Uint8List(4).buffer,
        'scalar': 5,
      });
      expect(collectJsTransferables(encoded).toDart, hasLength(3));
      expect(collectJsTransferables(encodePayloadValue('hi')).toDart, isEmpty);
    });

    test('structuredCloneWithTransfer genuinely detaches the source', () {
      final jsArray = Uint8List.fromList([1, 2, 3]).toJS;
      final buffer = (jsArray as JSRecord)['buffer']! as JSObject;
      final cloned = structuredCloneWithTransfer(
        jsArray,
        StructuredCloneOptions(transfer: <JSObject>[buffer].toJS),
      );
      expect(cloned, isNotNull);
      // Read byteLength off the JS object directly: a detached ArrayBuffer
      // reports 0. (Calling .toDart on a view of a detached buffer is
      // compiler-sensitive — dart2wasm's wrapper construction throws.)
      final byteLength =
          ((buffer as JSRecord)['byteLength']! as JSNumber).toDartInt;
      expect(
        byteLength,
        0,
        reason: 'a detached ArrayBuffer reports byteLength 0',
      );
    });
  });

  group('SharedBuffer at the codec boundary', () {
    test('a web SharedBuffer encodes to its underlying JS buffer', () {
      final environment = FakeJsEnvironment(sharedArrayBuffer: true)..install();
      addTearDown(environment.uninstall);
      final buffer = SharedBuffer.allocate(16);
      final encoded = encodePayloadValue(buffer);
      // The fake allocator hands out plain ArrayBuffers.
      expect(encoded, isNotNull);
      expect(encoded!.isA<JSArrayBuffer>(), isTrue);
    });

    test('FakeSharedBuffer is rejected by the real codec with guidance', () {
      expect(
        () => encodePayloadValue(FakeSharedBuffer(8)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('FakeSharedBuffer'),
          ),
        ),
      );
    });
  });
}
