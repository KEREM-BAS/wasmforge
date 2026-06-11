/// Typed, explicit conversions between Dart payload values and their
/// JavaScript wire representations.
///
/// This is the single place where protocol data crosses the JS↔Dart boundary.
/// No `dynamic` is involved anywhere: every conversion is an explicit,
/// recursive dispatch over the supported type table (see
/// `assertEncodablePayload` in `src/concurrency/message_protocol.dart` for
/// the authoritative list).
///
/// Web-only: reached exclusively through `if (dart.library.js_interop)`
/// conditional imports. Not exported from the public library — its signatures
/// use JS types, which cannot cross a conditional-export boundary.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'js_bindings.dart';

/// Largest integer magnitude that survives a JS `number` round trip
/// (2^53 - 1).
const int maxSafeWireInteger = 9007199254740991;

/// Encodes a supported Dart payload [value] into its JS wire form.
///
/// Throws [ArgumentError] (naming the offending runtime type and path) for
/// values outside the supported table, for non-`String` map keys, and for
/// integers beyond ±2^53 - 1, which would silently lose precision as JS
/// numbers.
JSAny? encodePayloadValue(Object? value) => _encode(value, r'$');

JSAny? _encode(Object? value, String path) {
  switch (value) {
    case null:
      return null;
    case final bool v:
      return v.toJS;
    case final int v:
      if (v > maxSafeWireInteger || v < -maxSafeWireInteger) {
        throw ArgumentError(
          'Integer $v at $path exceeds ±2^53 - 1 and cannot cross the worker '
          'boundary without precision loss. Send it as a String or split it.',
        );
      }
      return v.toJS;
    case final double v:
      return v.toJS;
    case final String v:
      return v.toJS;
    case final Int8List v:
      return v.toJS;
    case final Uint8List v:
      return v.toJS;
    case final Int16List v:
      return v.toJS;
    case final Uint16List v:
      return v.toJS;
    case final Int32List v:
      return v.toJS;
    case final Uint32List v:
      return v.toJS;
    case final Float32List v:
      return v.toJS;
    case final Float64List v:
      return v.toJS;
    case final ByteData v:
      return v.toJS;
    case final ByteBuffer v:
      return v.toJS;
    case final List<Object?> v:
      final encoded = <JSAny?>[
        for (var i = 0; i < v.length; i++) _encode(v[i], '$path[$i]'),
      ];
      return encoded.toJS;
    case final Map<Object?, Object?> v:
      final record = JSRecord();
      for (final entry in v.entries) {
        final key = entry.key;
        if (key is! String) {
          throw ArgumentError(
            'Map key ${entry.key} (${entry.key.runtimeType}) at $path is not '
            'a String; only Map<String, Object?> crosses the worker boundary.',
          );
        }
        record[key] = _encode(entry.value, '$path.$key');
      }
      return record;
    default:
      throw ArgumentError(
        'Unsupported payload value of type ${value.runtimeType} at $path. '
        'Supported: null, bool, int, double, String, typed data, ByteBuffer, '
        'List, and Map<String, Object?> thereof.',
      );
  }
}

/// Decodes a JS wire [value] back into its Dart form.
///
/// Inverse of [encodePayloadValue]. Finite whole numbers decode as [int]
/// (mirroring dart2js semantics so dart2js and dart2wasm agree); everything
/// else stays [double]. Typed arrays decode as views where the platform
/// allows (cast on dart2js, O(1) wrapper on dart2wasm).
Object? decodePayloadValue(JSAny? value) => _decode(value, r'$');

Object? _decode(JSAny? value, String path) {
  if (value == null) {
    return null;
  }
  if (value.isA<JSBoolean>()) {
    return (value as JSBoolean).toDart;
  }
  if (value.isA<JSString>()) {
    return (value as JSString).toDart;
  }
  if (value.isA<JSNumber>()) {
    final n = (value as JSNumber).toDartDouble;
    final isWholeAndSafe = n.isFinite &&
        n.abs() <= maxSafeWireInteger.toDouble() &&
        n.truncateToDouble() == n;
    return isWholeAndSafe ? n.toInt() : n;
  }
  if (value.isA<JSArray>()) {
    final elements = (value as JSArray<JSAny?>).toDart;
    return <Object?>[
      for (var i = 0; i < elements.length; i++)
        _decode(elements[i], '$path[$i]'),
    ];
  }
  if (value.isA<JSInt8Array>()) {
    return (value as JSInt8Array).toDart;
  }
  if (value.isA<JSUint8Array>()) {
    return (value as JSUint8Array).toDart;
  }
  if (value.isA<JSInt16Array>()) {
    return (value as JSInt16Array).toDart;
  }
  if (value.isA<JSUint16Array>()) {
    return (value as JSUint16Array).toDart;
  }
  if (value.isA<JSInt32Array>()) {
    return (value as JSInt32Array).toDart;
  }
  if (value.isA<JSUint32Array>()) {
    return (value as JSUint32Array).toDart;
  }
  if (value.isA<JSFloat32Array>()) {
    return (value as JSFloat32Array).toDart;
  }
  if (value.isA<JSFloat64Array>()) {
    return (value as JSFloat64Array).toDart;
  }
  if (value.isA<JSDataView>()) {
    return (value as JSDataView).toDart;
  }
  if (value.isA<JSArrayBuffer>()) {
    return (value as JSArrayBuffer).toDart;
  }
  if (value.isA<JSFunction>()) {
    throw ArgumentError('Functions cannot cross the worker boundary ($path).');
  }
  if (value.isA<JSObject>()) {
    final record = value as JSRecord;
    final keys = objectKeys(record).toDart;
    final map = <String, Object?>{};
    for (final jsKey in keys) {
      final key = jsKey.toDart;
      map[key] = _decode(record[key], '$path.$key');
    }
    return map;
  }
  throw ArgumentError(
    'Unsupported JS value at $path cannot be decoded into a payload.',
  );
}

/// Collects the transferable `ArrayBuffer`s reachable from an **encoded**
/// payload [encoded], reference-deduplicated, ready to pass as the transfer
/// list of `postMessage`.
///
/// Collection runs over the encoded JS tree (not the Dart payload) because
/// dart2wasm may copy typed data while encoding — only the encoded buffers
/// are the ones actually being posted. `SharedArrayBuffer`s are skipped:
/// they are shared by reference and are not transferable.
JSArray<JSObject> collectJsTransferables(JSAny? encoded) {
  final seen = JSSet();
  final result = <JSObject>[];
  _collectTransferables(encoded, seen, result);
  return result.toJS;
}

void _collectTransferables(JSAny? value, JSSet seen, List<JSObject> result) {
  if (value == null) {
    return;
  }
  if (value.isA<JSArrayBuffer>()) {
    _addTransferable(value as JSArrayBuffer, seen, result);
    return;
  }
  if (arrayBufferIsView(value)) {
    final buffer = (value as JSRecord)['buffer'];
    // A view over a SharedArrayBuffer reports a non-ArrayBuffer buffer here
    // and is skipped on purpose.
    if (buffer != null && buffer.isA<JSArrayBuffer>()) {
      _addTransferable(buffer as JSArrayBuffer, seen, result);
    }
    return;
  }
  if (value.isA<JSArray>()) {
    final elements = (value as JSArray<JSAny?>).toDart;
    for (final element in elements) {
      _collectTransferables(element, seen, result);
    }
    return;
  }
  if (value.isA<JSBoolean>() ||
      value.isA<JSNumber>() ||
      value.isA<JSString>()) {
    return;
  }
  if (value.isA<JSObject>() && !value.instanceOfString('SharedArrayBuffer')) {
    final record = value as JSRecord;
    final keys = objectKeys(record).toDart;
    for (final jsKey in keys) {
      _collectTransferables(record[jsKey.toDart], seen, result);
    }
  }
}

void _addTransferable(
  JSArrayBuffer buffer,
  JSSet seen,
  List<JSObject> result,
) {
  if (!seen.has(buffer)) {
    seen.add(buffer);
    result.add(buffer);
  }
}
