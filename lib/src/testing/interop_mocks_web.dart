/// Web implementations of the JS-interop testing helpers.
///
/// Web-only: reached exclusively through the `if (dart.library.js_interop)`
/// conditional export in `package:wasmforge/testing.dart`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

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

/// A Dart-implemented `Worker` lookalike built with `@JSExport` +
/// [createJSInteropWrapper], for testing `WebWorkerTransport` without
/// spawning a real worker (inject it via `debugWorkerFactory` in
/// `src/concurrency/wasm_worker.dart`).
///
/// The wrapper object returned by [asWorker] exposes `postMessage`,
/// `terminate`, and assignable `onmessage`/`onerror` properties — the surface
/// the transport touches. The Dart side records what the transport posted and
/// can script incoming envelopes/events.
final class MockWorker {
  /// Messages the transport posted, in order.
  final List<JSAny?> postedMessages = <JSAny?>[];

  /// The transfer argument of each post (null when none), parallel to
  /// [postedMessages].
  final List<JSAny?> postedTransfers = <JSAny?>[];

  /// Number of `terminate()` calls.
  int terminateCount = 0;

  JSFunction? _onmessage;
  JSFunction? _onerror;

  /// The JS `postMessage` member.
  @JSExport('postMessage')
  void postMessage(JSAny? message, [JSAny? transfer]) {
    postedMessages.add(message);
    postedTransfers.add(transfer);
  }

  /// The JS `terminate` member.
  @JSExport('terminate')
  void terminate() {
    terminateCount += 1;
  }

  /// The JS `onmessage` property (set by the transport).
  @JSExport('onmessage')
  set onmessage(JSFunction? handler) => _onmessage = handler;

  /// The JS `onmessage` property getter.
  @JSExport('onmessage')
  JSFunction? get onmessage => _onmessage;

  /// The JS `onerror` property (set by the transport).
  @JSExport('onerror')
  set onerror(JSFunction? handler) => _onerror = handler;

  /// The JS `onerror` property getter.
  @JSExport('onerror')
  JSFunction? get onerror => _onerror;

  /// This mock as a `web.Worker` the transport can drive.
  web.Worker asWorker() => createJSInteropWrapper(this) as web.Worker;

  /// Delivers [wire] to the transport's `onmessage` handler as a
  /// `MessageEvent`.
  void emitEnvelope(WireEnvelope wire) {
    final event = web.MessageEvent(
      'message',
      web.MessageEventInit(data: wire),
    );
    _onmessage?.callAsFunction(null, event);
  }

  /// Emits a `ready` envelope (protocol defaults to the current version).
  void emitReady({int protocol = protocolVersion}) =>
      emitEnvelope(WireEnvelope(kind: 'ready', protocol: protocol));

  /// Emits a `result` envelope.
  void emitResult(int id, JSAny? payload) =>
      emitEnvelope(WireEnvelope(kind: 'result', id: id, payload: payload));

  /// Emits an `error` envelope.
  void emitError(
    int id,
    String message, {
    String? stack,
    String? errorType,
  }) =>
      emitEnvelope(
        WireEnvelope(
          kind: 'error',
          id: id,
          errorMessage: message,
          errorStack: stack,
          errorType: errorType,
        ),
      );

  /// Emits a `boot-error` envelope.
  void emitBootError(String message) =>
      emitEnvelope(WireEnvelope(kind: 'boot-error', errorMessage: message));

  /// Fires the worker-level `error` event on the transport.
  void emitWorkerError(String message) {
    final event = web.ErrorEvent('error', web.ErrorEventInit(message: message));
    _onerror?.callAsFunction(null, event);
  }
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
