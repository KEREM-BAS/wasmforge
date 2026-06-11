/// Non-web implementations of every conditionally-imported symbol.
///
/// This is the **default** branch of all `if (dart.library.js_interop)`
/// conditional imports/exports in the package, so it must stay free of any
/// web-only types and must never throw from capability/detection paths —
/// off-web callers get graceful degradation, not crashes.
library;

import '../concurrency/message_protocol.dart';
import '../concurrency/shared_buffer.dart';
import '../concurrency/worker_pool.dart';

/// Not on the web.
bool detectIsWeb() => false;

/// Cross-origin isolation is a web concept; `false` everywhere else.
bool detectCrossOriginIsolated() => false;

/// WasmGC support is a web concept; `false` everywhere else.
bool detectWasmGcSupport() => false;

/// Shared memory is unavailable off the web.
bool platformSharedBufferSupported() => false;

/// Shared memory is unavailable off the web — `null`, never a throw.
SharedBuffer? tryAllocateSharedBuffer(int byteLength) => null;

/// No platform workers off the web — `WorkerPool` falls back to its inline
/// registry or to descriptive `UnsupportedError`s, never a crash.
WorkerTransportFactory? createPlatformTransportFactory(
  WorkerPoolConfig config,
) =>
    null;

/// Non-web no-op so a worker entrypoint file can be imported (e.g. by VM
/// tests) without crashing; the web implementation lives in
/// `src/concurrency/wasm_worker.dart`.
Future<void> runWorker(
  TaskRegistry registry, {
  bool transferResults = true,
}) async {}
