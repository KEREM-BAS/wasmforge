/// Hand-rolled `dart:js_interop` bindings for ECMAScript built-ins that
/// `package:web` (generated from WebIDL) does not cover: `SharedArrayBuffer`,
/// `Atomics`, typed-array view constructors, `WebAssembly.validate`,
/// `structuredClone`, plain-object access, and a scope-agnostic
/// `crossOriginIsolated`.
///
/// This library is web-only: it must be reached exclusively through
/// `if (dart.library.js_interop)` conditional imports.
library;

import 'dart:js_interop';

/// `globalThis.crossOriginIsolated`, readable from both window and worker
/// scopes.
///
/// Nullable on purpose: in engines or contexts where the property is
/// undefined this reads as `null` instead of crashing, which callers must
/// treat as "not isolated".
@JS()
external JSBoolean? get crossOriginIsolated;

/// The `SharedArrayBuffer` constructor, or `null` when the API is hidden.
///
/// Browsers remove the constructor from the global scope when the page is not
/// cross-origin isolated, so a `null` here means [JSSharedArrayBuffer] must
/// not be instantiated.
@JS('SharedArrayBuffer')
external JSFunction? get sharedArrayBufferConstructor;

/// The `WebAssembly` namespace object, or `null` where WebAssembly is
/// unavailable.
@JS('WebAssembly')
external JSObject? get webAssemblyNamespace;

/// A JavaScript `SharedArrayBuffer`: a fixed-length raw binary buffer whose
/// memory is shared (not copied) when posted between agents.
@JS('SharedArrayBuffer')
extension type JSSharedArrayBuffer._(JSObject _) implements JSObject {
  /// Allocates [byteLength] bytes of shared memory.
  ///
  /// Only call when [sharedArrayBufferConstructor] is non-null; otherwise the
  /// constructor reference itself throws in JavaScript.
  external factory JSSharedArrayBuffer(int byteLength);

  /// Total length of the buffer, in bytes.
  external int get byteLength;
}

/// `Atomics.add`: atomically adds [value] to the element of [typedArray] at
/// [index] and returns the **previous** value.
@JS('Atomics.add')
external int atomicsAdd(JSInt32Array typedArray, int index, int value);

/// `Atomics.load`: atomically reads the element of [typedArray] at [index].
@JS('Atomics.load')
external int atomicsLoad(JSInt32Array typedArray, int index);

/// `Atomics.store`: atomically writes [value] into [typedArray] at [index]
/// and returns the value written.
@JS('Atomics.store')
external int atomicsStore(JSInt32Array typedArray, int index, int value);

/// Constructs `Int32Array` views over an arbitrary buffer — either a regular
/// `ArrayBuffer` or a [JSSharedArrayBuffer], which neither `package:web` nor
/// `dart:js_interop` can do directly.
@JS('Int32Array')
extension type JSInt32ArrayView._(JSInt32Array _) implements JSInt32Array {
  /// Creates a view of [buffer] starting at [byteOffset] (bytes) spanning
  /// [length] **elements** (not bytes). Omitting both views the whole buffer.
  external factory JSInt32ArrayView(
    JSObject buffer, [
    int byteOffset,
    int length,
  ]);
}

/// Constructs `Float64Array` views over an arbitrary buffer.
@JS('Float64Array')
extension type JSFloat64ArrayView._(JSFloat64Array _)
    implements JSFloat64Array {
  /// Creates a view of [buffer] starting at [byteOffset] (bytes) spanning
  /// [length] **elements** (not bytes). Omitting both views the whole buffer.
  external factory JSFloat64ArrayView(
    JSObject buffer, [
    int byteOffset,
    int length,
  ]);
}

/// Constructs `Uint8Array` views over an arbitrary buffer.
@JS('Uint8Array')
extension type JSUint8ArrayView._(JSUint8Array _) implements JSUint8Array {
  /// Creates a view of [buffer] starting at [byteOffset] spanning [length]
  /// bytes. Omitting both views the whole buffer.
  external factory JSUint8ArrayView(
    JSObject buffer, [
    int byteOffset,
    int length,
  ]);
}

/// `WebAssembly.validate`: returns whether [bytes] form a structurally valid
/// wasm module under the features the engine supports.
///
/// Only call when [webAssemblyNamespace] is non-null.
@JS('WebAssembly.validate')
external bool webAssemblyValidate(JSUint8Array bytes);

/// `structuredClone`: deep-copies [value] using the structured clone
/// algorithm. Available in both window and worker scopes.
@JS()
external JSAny? structuredClone(JSAny? value);

/// Options literal for [structuredCloneWithTransfer].
extension type StructuredCloneOptions._(JSObject _) implements JSObject {
  /// Creates the object literal `{transfer: [...]}`.
  external factory StructuredCloneOptions({
    required JSArray<JSObject> transfer,
  });
}

/// `structuredClone` with a transfer list: buffers named in [options] are
/// **moved** into the clone, detaching the originals — the same semantics a
/// transfer-enabled `postMessage` applies.
@JS('structuredClone')
external JSAny? structuredCloneWithTransfer(
  JSAny? value,
  StructuredCloneOptions options,
);

/// A plain JavaScript object used as a string-keyed record, with typed
/// indexed access so no `dart:js_interop_unsafe` is needed.
@JS('Object')
extension type JSRecord._(JSObject _) implements JSObject {
  /// Creates an empty plain object (`{}`).
  external factory JSRecord();

  /// Reads property [key]; absent properties read as `null`.
  external JSAny? operator [](String key);

  /// Writes property [key].
  external void operator []=(String key, JSAny? value);
}

/// `Object.keys`: the own enumerable string keys of [object].
@JS('Object.keys')
external JSArray<JSString> objectKeys(JSObject object);

/// `ArrayBuffer.isView`: whether [value] is a typed-array or `DataView` view
/// over some buffer.
@JS('ArrayBuffer.isView')
external bool arrayBufferIsView(JSAny? value);

/// A JavaScript `Set`, used for reference-identity deduplication of JS
/// objects (Dart `identical` is not reliable for JS values under dart2wasm).
@JS('Set')
extension type JSSet._(JSObject _) implements JSObject {
  /// Creates an empty `Set`.
  external factory JSSet();

  /// Whether [value] is already in the set (SameValueZero comparison).
  external bool has(JSAny? value);

  /// Adds [value] to the set.
  external void add(JSAny? value);
}

/// The wire form of a protocol envelope: a plain JS object created as an
/// object literal so it survives `postMessage` structured cloning.
///
/// Field semantics are defined by `Envelope` in
/// `src/concurrency/message_protocol.dart`; absent fields read as `null`.
extension type WireEnvelope._(JSObject _) implements JSObject {
  /// Creates the object literal `{kind, id, task, payload, ...}`.
  external factory WireEnvelope({
    required String kind,
    int? id,
    String? task,
    JSAny? payload,
    String? errorMessage,
    String? errorStack,
    String? errorType,
    int? protocol,
  });

  /// Envelope kind discriminator (`ready`/`task`/`result`/`error`/...).
  external String get kind;

  /// Request id correlating tasks with results/errors.
  external int? get id;

  /// Task name, set on `task` envelopes.
  external String? get task;

  /// Encoded payload, set on `task`/`result` envelopes.
  external JSAny? get payload;

  /// Human-readable error description, set on error envelopes.
  external String? get errorMessage;

  /// Remote stack trace string, set on error envelopes when available.
  external String? get errorStack;

  /// Remote `runtimeType` string, set on error envelopes when available.
  external String? get errorType;

  /// Protocol version, set on `ready` envelopes.
  external int? get protocol;
}
