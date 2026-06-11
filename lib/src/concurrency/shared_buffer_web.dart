/// Web implementation of [SharedBuffer] over a JavaScript
/// `SharedArrayBuffer`.
///
/// Web-only: reached exclusively through `if (dart.library.js_interop)`
/// conditional imports.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import '../core/js_bindings.dart';
import 'shared_buffer.dart';

/// Test hook: when set, [tryAllocateSharedBuffer] allocates through this
/// factory instead of the real `SharedArrayBuffer` constructor.
///
/// `Atomics.add/load/store` are specified to work on plain `ArrayBuffer`
/// views too, so tests can exercise the full [WebSharedBuffer] code path in a
/// non-isolated browser by returning an ordinary `ArrayBuffer` here.
/// Installed by `FakeJsEnvironment` from `package:wasmforge/testing.dart`.
JSObject Function(int byteLength)? debugSharedBufferFactory;

/// Test hook: when `true`, shared buffers report unsupported even if the real
/// `SharedArrayBuffer` constructor exists (simulates a non-isolated page).
bool debugForceSharedBufferUnsupported = false;

/// Whether shared memory is allocatable in this context (or a test factory is
/// installed).
bool platformSharedBufferSupported() {
  if (debugForceSharedBufferUnsupported) {
    return false;
  }
  return debugSharedBufferFactory != null ||
      sharedArrayBufferConstructor != null;
}

/// Allocates a [WebSharedBuffer], or returns `null` when unsupported.
SharedBuffer? tryAllocateSharedBuffer(int byteLength) {
  if (debugForceSharedBufferUnsupported) {
    return null;
  }
  final debugFactory = debugSharedBufferFactory;
  if (debugFactory != null) {
    return WebSharedBuffer.fromJs(debugFactory(byteLength));
  }
  if (sharedArrayBufferConstructor == null) {
    return null;
  }
  return WebSharedBuffer.fromJs(JSSharedArrayBuffer(byteLength));
}

/// [SharedBuffer] over a JS `SharedArrayBuffer` (or, under the test hook, a
/// plain `ArrayBuffer`).
///
/// Atomic operations run on a lazily-created JS `Int32Array` view — never on
/// a Dart-side list — so they are real `Atomics.*` calls. The `asXxxList()`
/// accessors return `.toDart` views (a cast on dart2js, an O(1) wrapper on
/// dart2wasm), so writes through them alias the shared memory.
final class WebSharedBuffer implements SharedBuffer {
  /// Wraps an existing JS buffer object.
  WebSharedBuffer.fromJs(this._buffer) : _byteLength = _readByteLength(_buffer);

  final JSObject _buffer;
  final int _byteLength;

  static int _readByteLength(JSObject buffer) {
    final length = (buffer as JSRecord)['byteLength'];
    if (length == null || !length.isA<JSNumber>()) {
      throw ArgumentError(
        'Object passed to WebSharedBuffer.fromJs has no numeric byteLength; '
        'expected a SharedArrayBuffer or ArrayBuffer.',
      );
    }
    return (length as JSNumber).toDartInt;
  }

  /// The underlying JS buffer, for the payload codec.
  JSObject get jsBuffer => _buffer;

  late final JSInt32Array _atomicView = JSInt32ArrayView(
    _buffer,
    0,
    _byteLength ~/ 4,
  );

  @override
  int get byteLength => _byteLength;

  @override
  Int32List asInt32List() =>
      JSInt32ArrayView(_buffer, 0, _byteLength ~/ 4).toDart;

  @override
  Float64List asFloat64List() =>
      JSFloat64ArrayView(_buffer, 0, _byteLength ~/ 8).toDart;

  @override
  Uint8List asUint8List() => JSUint8ArrayView(_buffer, 0, _byteLength).toDart;

  @override
  int atomicAdd(int index, int value) {
    _checkIndex(index);
    return atomicsAdd(_atomicView, index, value);
  }

  @override
  int atomicLoad(int index) {
    _checkIndex(index);
    return atomicsLoad(_atomicView, index);
  }

  @override
  void atomicStore(int index, int value) {
    _checkIndex(index);
    atomicsStore(_atomicView, index, value);
  }

  void _checkIndex(int index) {
    final length = _byteLength ~/ 4;
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this, 'index', null, length);
    }
  }
}
