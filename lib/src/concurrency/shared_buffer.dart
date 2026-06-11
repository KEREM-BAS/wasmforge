/// Shared-memory buffer backed by `SharedArrayBuffer` on the web, with
/// capability-gated allocation and graceful degradation everywhere else.
library;

import 'dart:typed_data';

import '../core/fallback_stub.dart'
    if (dart.library.js_interop) 'shared_buffer_web.dart' as impl;

/// A fixed-length block of memory that is **shared** (not copied) when sent
/// to a worker, with a small atomic-integer API on top.
///
/// Only usable when the page is cross-origin isolated (COOP/COEP headers —
/// see the README section "SharedArrayBuffer and cross-origin isolation").
/// Check [isSupported] or use [tryAllocate]; both never throw on any
/// platform. The typed-data accessors return **views**: writes through them
/// and through the atomic methods are visible to every agent holding the
/// buffer.
///
/// A `SharedBuffer` may be placed anywhere inside a `WorkerPool` task payload
/// and arrives in the worker as a view of the same memory.
abstract interface class SharedBuffer {
  /// Allocates [byteLength] bytes of shared memory.
  ///
  /// Throws a [StateError] when shared memory is unsupported here (non-web
  /// platform, or a web page that is not cross-origin isolated) and a
  /// [RangeError] for a negative [byteLength]. Prefer [tryAllocate] when the
  /// caller has a fallback path.
  factory SharedBuffer.allocate(int byteLength) {
    final buffer = SharedBuffer.tryAllocate(byteLength);
    if (buffer == null) {
      throw StateError(
        'SharedBuffer requires a cross-origin isolated web context, which '
        'makes SharedArrayBuffer available. Serve the page with '
        '"Cross-Origin-Opener-Policy: same-origin" and '
        '"Cross-Origin-Embedder-Policy: require-corp" (see the wasmforge '
        'README), or check SharedBuffer.isSupported / use '
        'SharedBuffer.tryAllocate and fall back to message passing.',
      );
    }
    return buffer;
  }

  /// Whether shared memory can be allocated here. `false` off the web and on
  /// non-isolated pages; never throws.
  static bool get isSupported => impl.platformSharedBufferSupported();

  /// Allocates [byteLength] bytes of shared memory, or returns `null` where
  /// unsupported — the never-throwing counterpart of [SharedBuffer.allocate].
  ///
  /// Still throws [RangeError] for a negative [byteLength], on every
  /// platform, since that is a caller bug rather than a platform limitation.
  static SharedBuffer? tryAllocate(int byteLength) {
    RangeError.checkNotNegative(byteLength, 'byteLength');
    return impl.tryAllocateSharedBuffer(byteLength);
  }

  /// Total length of the buffer, in bytes.
  int get byteLength;

  /// A signed 32-bit **view** over the buffer ([byteLength] ~/ 4 elements).
  Int32List asInt32List();

  /// A 64-bit float **view** over the buffer ([byteLength] ~/ 8 elements).
  Float64List asFloat64List();

  /// A byte **view** over the whole buffer.
  Uint8List asUint8List();

  /// Atomically adds [value] to the 32-bit element at [index] and returns
  /// the **previous** value. [index] is in `Int32` elements, not bytes.
  int atomicAdd(int index, int value);

  /// Atomically reads the 32-bit element at [index].
  int atomicLoad(int index);

  /// Atomically writes [value] to the 32-bit element at [index].
  void atomicStore(int index, int value);
}
