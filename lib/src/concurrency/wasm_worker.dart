/// The real Web Worker transport and the worker-side entrypoint runtime.
///
/// Web-only: reached exclusively through `if (dart.library.js_interop)`
/// conditional imports/exports.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../core/interop_casts.dart';
import '../core/js_bindings.dart';
import 'message_protocol.dart';
import 'worker_pool.dart';

/// Test hook: when set, [WebWorkerTransport] obtains its `Worker` from this
/// factory instead of constructing a real one. [options] is `null` when a
/// classic (dart2js) worker would be spawned.
web.Worker Function(String url, web.WorkerOptions? options)? debugWorkerFactory;

/// Platform factory consumed by `WorkerPool` through its conditional import:
/// spawns real Web Workers per [config].
WorkerTransportFactory? createPlatformTransportFactory(
  WorkerPoolConfig config,
) =>
    (int workerIndex) =>
        WebWorkerTransport.spawn(config: config, workerIndex: workerIndex);

/// [WorkerTransport] over a real `Worker`.
///
/// dart2wasm entrypoints (`.wasm`) are spawned as **module** workers through
/// `wasmforge_worker_bootstrap.js`, with the wasm and `.mjs` runtime URLs
/// passed in the bootstrap's query string. A `.js` entrypoint (dart2js
/// fallback) is spawned directly as a classic worker. All sends are buffered
/// until the worker's `ready` envelope arrives — module evaluation is
/// asynchronous, so the protocol never relies on browser-side message
/// buffering.
final class WebWorkerTransport implements WorkerTransport {
  /// Spawns worker number [workerIndex] per [config].
  WebWorkerTransport.spawn({
    required WorkerPoolConfig config,
    required int workerIndex,
  }) {
    final entrypoint = Uri.base.resolveUri(config.workerEntrypoint);
    if (entrypoint.path.endsWith('.js')) {
      // dart2js fallback: the compiled JS runs main() on load in a classic
      // worker — no bootstrap needed.
      _worker = _createWorker(entrypoint.toString(), null);
    } else {
      final moduleUri = config.moduleUri != null
          ? Uri.base.resolveUri(config.moduleUri!)
          : entrypoint.replace(path: _swapToMjs(entrypoint.path));
      final bootstrapUri = Uri.base.resolveUri(
        config.bootstrapUri ?? Uri(path: 'wasmforge_worker_bootstrap.js'),
      );
      final spawnUri = bootstrapUri.replace(
        queryParameters: <String, String>{
          ...bootstrapUri.queryParameters,
          'wasm': entrypoint.toString(),
          'mjs': moduleUri.toString(),
        },
      );
      _worker = _createWorker(
        spawnUri.toString(),
        web.WorkerOptions(type: 'module', name: 'wasmforge-$workerIndex'),
      );
    }
    _worker.onmessage = ((web.MessageEvent event) {
      _handleMessage(event.data);
    }).toJS;
    _worker.onerror = _handleErrorEvent.toJS;
  }

  static String _swapToMjs(String path) => path.endsWith('.wasm')
      ? '${path.substring(0, path.length - 5)}.mjs'
      : '$path.mjs';

  static web.Worker _createWorker(String url, web.WorkerOptions? options) {
    final factory = debugWorkerFactory;
    if (factory != null) {
      return factory(url, options);
    }
    return options == null
        ? web.Worker(url.toJS)
        : web.Worker(url.toJS, options);
  }

  late final web.Worker _worker;
  final Completer<void> _readyCompleter = Completer<void>();
  final StreamController<Envelope> _messages = StreamController<Envelope>();
  final List<(Envelope, bool)> _preReadyBuffer = <(Envelope, bool)>[];
  bool _isReady = false;
  bool _terminated = false;

  @override
  Future<void> get ready => _readyCompleter.future;

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  void send(Envelope envelope, {bool transferBuffers = false}) {
    if (_terminated) {
      throw StateError('send() after terminate() on WebWorkerTransport');
    }
    if (envelope.kind != EnvelopeKind.task) {
      throw ArgumentError.value(
        envelope.kind,
        'envelope',
        'WebWorkerTransport only accepts task envelopes',
      );
    }
    if (!_isReady) {
      _preReadyBuffer.add((envelope, transferBuffers));
      return;
    }
    _postEnvelope(envelope, transferBuffers);
  }

  void _postEnvelope(Envelope envelope, bool transferBuffers) {
    final payload = encodePayloadValue(envelope.payload);
    final wire = WireEnvelope(
      kind: envelope.kind.wire,
      id: envelope.id,
      task: envelope.task,
      payload: payload,
    );
    if (transferBuffers) {
      _worker.postMessage(wire, collectJsTransferables(payload));
    } else {
      _worker.postMessage(wire);
    }
  }

  void _handleMessage(JSAny? data) {
    if (_terminated || data == null || !data.isA<JSObject>()) {
      return;
    }
    final kindValue = (data as JSRecord)['kind'];
    if (kindValue == null || !kindValue.isA<JSString>()) {
      return;
    }
    final kind = EnvelopeKind.fromWire((kindValue as JSString).toDart);
    final wire = data as WireEnvelope;
    switch (kind) {
      case EnvelopeKind.ready:
        final remoteProtocol = wire.protocol;
        if (remoteProtocol != protocolVersion) {
          _failBoot(
            WorkerSpawnException(
              'worker speaks protocol $remoteProtocol, this pool speaks '
              '$protocolVersion — recompile the worker against the same '
              'wasmforge version',
            ),
          );
          return;
        }
        if (!_readyCompleter.isCompleted) {
          _readyCompleter.complete();
          _isReady = true;
          final buffered = List.of(_preReadyBuffer);
          _preReadyBuffer.clear();
          for (final (envelope, transferBuffers) in buffered) {
            _postEnvelope(envelope, transferBuffers);
          }
        }
      case EnvelopeKind.result:
        final id = wire.id;
        if (id == null) {
          return;
        }
        final Object? decoded;
        try {
          decoded = decodePayloadValue(wire.payload);
        } on Object catch (error, stackTrace) {
          _messages.add(
            Envelope.error(
              id: id,
              errorMessage: 'failed to decode worker result: $error',
              errorStack: stackTrace.toString(),
              errorType: 'ResultDecodeError',
            ),
          );
          return;
        }
        _messages.add(Envelope.result(id: id, payload: decoded));
      case EnvelopeKind.error:
        final id = wire.id;
        if (id == null) {
          return;
        }
        _messages.add(
          Envelope.error(
            id: id,
            errorMessage: wire.errorMessage ?? 'unknown worker error',
            errorStack: wire.errorStack,
            errorType: wire.errorType,
          ),
        );
      case EnvelopeKind.bootError:
        final stack = wire.errorStack;
        _failBoot(
          WorkerSpawnException(
            'worker bootstrap failed: '
            '${wire.errorMessage ?? 'unknown'}'
            '${stack == null ? '' : '\n$stack'}',
          ),
        );
      case EnvelopeKind.task || null:
        return; // The main thread never receives task envelopes.
    }
  }

  void _failBoot(WorkerSpawnException error) {
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(error);
    } else {
      _messages.addError(error);
    }
  }

  void _handleErrorEvent(web.Event event) {
    var message = 'Worker fired an error event';
    if (event.isA<web.ErrorEvent>()) {
      final errorEvent = event as web.ErrorEvent;
      message = 'Worker error: ${errorEvent.message} '
          '(${errorEvent.filename}:${errorEvent.lineno})';
    }
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(WorkerSpawnException(message));
    } else {
      _messages.addError(StateError(message));
    }
  }

  @override
  Future<void> terminate() async {
    if (_terminated) {
      return;
    }
    _terminated = true;
    _worker.terminate();
    // Not awaited: close()'s future only completes once a listener has
    // received the done event, which never happens for a never-listened
    // stream.
    unawaited(_messages.close());
  }
}

/// Runs a worker entrypoint: registers [registry]'s handlers against the
/// dedicated worker scope's message port, announces readiness, and serves
/// task envelopes until the worker is terminated.
///
/// Call this from the `main()` of a worker entrypoint compiled with
/// `dart compile wasm` (or `dart compile js` for the fallback path):
///
/// ```dart
/// import 'package:wasmforge/wasmforge.dart';
///
/// void main() {
///   runWorker(
///     TaskRegistry()..register<int, int>('double', (n) => n * 2),
///   );
/// }
/// ```
///
/// With [transferResults] (the default), `ArrayBuffer`s reachable from a
/// task's result are **moved** to the main thread rather than copied —
/// don't return views over buffers the worker intends to keep using.
///
/// Throws [StateError] when called outside a dedicated worker scope. On
/// non-web platforms the conditional export swaps in a no-op that returns
/// immediately, so importing a worker entrypoint file in VM tests is
/// harmless.
Future<void> runWorker(
  TaskRegistry registry, {
  bool transferResults = true,
}) async {
  if (!globalContext.instanceOfString('DedicatedWorkerGlobalScope')) {
    throw StateError(
      'runWorker() must be called from a worker entrypoint executing inside '
      'a dedicated Web Worker (spawn it via WorkerPool).',
    );
  }
  final scope = globalContext as web.DedicatedWorkerGlobalScope;
  scope.onmessage = ((web.MessageEvent event) {
    _handleScopeMessage(scope, registry, event.data, transferResults);
  }).toJS;
  scope.postMessage(
    WireEnvelope(kind: EnvelopeKind.ready.wire, protocol: protocolVersion),
  );
}

void _handleScopeMessage(
  web.DedicatedWorkerGlobalScope scope,
  TaskRegistry registry,
  JSAny? data,
  bool transferResults,
) {
  if (data == null || !data.isA<JSObject>()) {
    return;
  }
  final kindValue = (data as JSRecord)['kind'];
  if (kindValue == null || !kindValue.isA<JSString>()) {
    return;
  }
  if (EnvelopeKind.fromWire((kindValue as JSString).toDart) !=
      EnvelopeKind.task) {
    return;
  }
  final wire = data as WireEnvelope;
  final id = wire.id;
  final task = wire.task;
  if (id == null || task == null) {
    return;
  }
  unawaited(
    Future<void>(() async {
      try {
        final payload = decodePayloadValue(wire.payload);
        final result = await registry.dispatch(task, payload);
        final encoded = encodePayloadValue(result);
        final reply = WireEnvelope(
          kind: EnvelopeKind.result.wire,
          id: id,
          payload: encoded,
        );
        if (transferResults) {
          scope.postMessage(reply, collectJsTransferables(encoded));
        } else {
          scope.postMessage(reply);
        }
      } on Object catch (error, stackTrace) {
        scope.postMessage(
          WireEnvelope(
            kind: EnvelopeKind.error.wire,
            id: id,
            errorMessage: error.toString(),
            errorStack: stackTrace.toString(),
            errorType: error.runtimeType.toString(),
          ),
        );
      }
    }),
  );
}
