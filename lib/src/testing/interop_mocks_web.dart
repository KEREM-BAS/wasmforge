/// Web implementations of the JS-interop testing helpers.
///
/// Web-only: reached exclusively through the `if (dart.library.js_interop)`
/// conditional export in `package:wasmforge/testing.dart`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../concurrency/message_protocol.dart';
import '../concurrency/shared_buffer_web.dart';
import '../core/capabilities.dart';
import '../core/interop_casts.dart';
import '../core/js_bindings.dart';

/// Simulates a JS environment for browser tests: installs capability
/// overrides and (optionally) a fake `SharedArrayBuffer` allocator so the
/// real `SharedBuffer` web code path runs in a test server context without
/// cross-origin isolation.
///
/// The fake allocator hands out plain `ArrayBuffer`s — `Atomics.add/load/
/// store` are specified to work on those too, so the entire view/atomics
/// implementation is exercised for real. Always pair [install] with
/// [uninstall] (e.g. in `setUp`/`tearDown`).
class FakeJsEnvironment {
  /// Describes the environment to simulate.
  FakeJsEnvironment({
    this.crossOriginIsolated = false,
    this.sharedArrayBuffer = false,
    this.wasmGc = false,
  });

  /// Simulated `crossOriginIsolated` value.
  final bool crossOriginIsolated;

  /// Whether `SharedBuffer` allocation should work.
  final bool sharedArrayBuffer;

  /// Simulated WasmGC support.
  final bool wasmGc;

  /// Installs the simulated environment process-wide.
  void install() {
    setCapabilityOverridesForTesting(
      CapabilityOverrides(
        isWeb: true,
        crossOriginIsolated: crossOriginIsolated,
        wasmGc: wasmGc,
      ),
    );
    if (sharedArrayBuffer) {
      debugSharedBufferFactory = _allocatePlainBuffer;
      debugForceSharedBufferUnsupported = false;
    } else {
      debugSharedBufferFactory = null;
      debugForceSharedBufferUnsupported = true;
    }
  }

  /// Reverts everything [install] changed.
  void uninstall() {
    clearCapabilityOverrides();
    debugSharedBufferFactory = null;
    debugForceSharedBufferUnsupported = false;
  }

  static JSObject _allocatePlainBuffer(int byteLength) =>
      Uint8List(byteLength).buffer.toJS;
}

/// Creates a [WorkerTransport] that round-trips every payload through the
/// **real** JS codec and the browser's `structuredClone`, then executes tasks
/// from [registry] in-page.
///
/// This is the highest-fidelity mock short of spawning a real worker: it
/// proves payloads survive encoding, structured cloning (including transfer
/// detachment when `transferBuffers` is set), and decoding. Caveat: with
/// [FakeJsEnvironment]'s plain-`ArrayBuffer` shared buffers, structured
/// cloning copies the fake buffer (a real `SharedArrayBuffer` would share).
WorkerTransport createJsLoopbackTransport(TaskRegistry registry) =>
    _JsLoopbackTransport(registry);

final class _JsLoopbackTransport implements WorkerTransport {
  _JsLoopbackTransport(this._registry);

  final TaskRegistry _registry;
  final StreamController<Envelope> _messages = StreamController<Envelope>();
  bool _terminated = false;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  void send(Envelope envelope, {bool transferBuffers = false}) {
    if (_terminated) {
      throw StateError('send() after terminate() on the loopback transport');
    }
    if (envelope.kind != EnvelopeKind.task) {
      throw ArgumentError.value(
        envelope.kind,
        'envelope',
        'the loopback transport only accepts task envelopes',
      );
    }
    final id = envelope.id!;
    final task = envelope.task!;
    // Encode and clone NOW (synchronously), like a real postMessage would —
    // including genuine transfer-list detachment.
    final encoded = encodePayloadValue(envelope.payload);
    final JSAny? wired;
    if (transferBuffers) {
      wired = structuredCloneWithTransfer(
        encoded,
        StructuredCloneOptions(transfer: collectJsTransferables(encoded)),
      );
    } else {
      wired = structuredClone(encoded);
    }
    scheduleMicrotask(() async {
      Envelope reply;
      try {
        final result = await _registry.dispatch(
          task,
          decodePayloadValue(wired),
        );
        final wiredResult = structuredClone(encodePayloadValue(result));
        reply =
            Envelope.result(id: id, payload: decodePayloadValue(wiredResult));
      } on Object catch (error, stackTrace) {
        reply = Envelope.error(
          id: id,
          errorMessage: error.toString(),
          errorStack: stackTrace.toString(),
          errorType: error.runtimeType.toString(),
        );
      }
      if (!_terminated) {
        _messages.add(reply);
      }
    });
  }

  @override
  Future<void> terminate() async {
    if (_terminated) {
      return;
    }
    _terminated = true;
    // Not awaited: close()'s future only completes once a listener has
    // received the done event, which never happens for a never-listened
    // stream.
    unawaited(_messages.close());
  }
}
