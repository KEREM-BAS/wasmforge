/// In-process [WorkerTransport]: runs tasks on the current isolate.
///
/// Pure Dart. This powers `WorkerPool`'s graceful non-web fallback (pass a
/// `TaskRegistry` as `inlineFallback`) and underpins the testing fakes. Task
/// payloads and results pass through [simulateStructuredClone] so code keeps
/// the same pass-by-value semantics a real worker boundary imposes.
library;

import 'dart:async';

import 'message_protocol.dart';

/// A [WorkerTransport] that dispatches task envelopes straight into a
/// [TaskRegistry] on the current isolate, one microtask later.
final class InlineWorkerTransport implements WorkerTransport {
  /// Creates a transport executing tasks from [registry].
  ///
  /// [clonePayloads] (default `true`) routes payloads and results through
  /// [simulateStructuredClone]; disable only when aliasing is intended.
  InlineWorkerTransport(this._registry, {bool clonePayloads = true})
      : _clonePayloads = clonePayloads;

  final TaskRegistry _registry;
  final bool _clonePayloads;
  final StreamController<Envelope> _messages = StreamController<Envelope>();
  bool _terminated = false;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<Envelope> get messages => _messages.stream;

  @override
  void send(Envelope envelope, {bool transferBuffers = false}) {
    if (_terminated) {
      throw StateError('send() after terminate() on InlineWorkerTransport');
    }
    if (envelope.kind != EnvelopeKind.task) {
      throw ArgumentError.value(
        envelope.kind,
        'envelope',
        'InlineWorkerTransport only accepts task envelopes',
      );
    }
    final id = envelope.id!;
    final task = envelope.task!;
    final payload = _clonePayloads
        ? simulateStructuredClone(envelope.payload)
        : envelope.payload;
    scheduleMicrotask(() async {
      Envelope reply;
      try {
        final result = await _registry.dispatch(task, payload);
        // A real worker would fail to encode an unsupported result — keep the
        // inline path equally honest.
        assertEncodablePayload(result);
        reply = Envelope.result(
          id: id,
          payload: _clonePayloads ? simulateStructuredClone(result) : result,
        );
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
