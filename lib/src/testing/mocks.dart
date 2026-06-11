/// Pure-Dart fakes for testing code that uses wasmforge — no browser, no
/// `dart:js_interop` required. Everything here runs on the VM.
///
/// Exported via `package:wasmforge/testing.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../concurrency/message_protocol.dart';
import '../concurrency/shared_buffer.dart';

/// A [SharedBuffer] backed by ordinary process memory, for VM tests.
///
/// Mirrors the web implementation's semantics: the `asXxxList()` accessors
/// are aliasing views over one allocation, and the atomic methods perform
/// (trivially atomic, single-threaded) 32-bit read-modify-write operations
/// with the same wrap-around and range-checking behavior.
///
/// `FakeWorkerTransport` passes instances **by reference**, simulating how a
/// real `SharedArrayBuffer` is shared rather than cloned. A fake buffer
/// cannot cross a *real* worker boundary.
final class FakeSharedBuffer implements SharedBuffer {
  /// Allocates [byteLength] bytes of zeroed fake-shared memory.
  FakeSharedBuffer(int byteLength) : _bytes = Uint8List(byteLength);

  final Uint8List _bytes;

  late final Int32List _atomicView = _bytes.buffer.asInt32List(
    0,
    _bytes.length ~/ 4,
  );

  @override
  int get byteLength => _bytes.length;

  @override
  Int32List asInt32List() => _bytes.buffer.asInt32List(0, _bytes.length ~/ 4);

  @override
  Float64List asFloat64List() =>
      _bytes.buffer.asFloat64List(0, _bytes.length ~/ 8);

  @override
  Uint8List asUint8List() => _bytes;

  @override
  int atomicAdd(int index, int value) {
    _checkIndex(index);
    final previous = _atomicView[index];
    _atomicView[index] = previous + value;
    return previous;
  }

  @override
  int atomicLoad(int index) {
    _checkIndex(index);
    return _atomicView[index];
  }

  @override
  void atomicStore(int index, int value) {
    _checkIndex(index);
    _atomicView[index] = value;
  }

  void _checkIndex(int index) {
    final length = _bytes.length ~/ 4;
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this, 'index', null, length);
    }
  }
}

/// A scriptable [WorkerTransport] for unit-testing pool/protocol logic on
/// the VM: executes tasks from a [TaskRegistry] in-process while letting the
/// test inject spawn failures, latency, task failures, and crashes — and
/// records everything that was sent.
final class FakeWorkerTransport implements WorkerTransport {
  /// Creates a fake transport.
  ///
  /// [registry] supplies task handlers (an empty registry makes every task
  /// fail with [UnknownTaskException], which is itself useful to test).
  /// [failSpawn] makes [ready] fail with [WorkerSpawnException]. [readyDelay]
  /// postpones readiness. [taskLatency] delays each reply. [clonePayloads]
  /// routes payloads/results through [simulateStructuredClone] (default).
  FakeWorkerTransport({
    TaskRegistry? registry,
    this.failSpawn = false,
    this.readyDelay,
    this.taskLatency,
    bool clonePayloads = true,
  })  : registry = registry ?? TaskRegistry(),
        _clonePayloads = clonePayloads;

  /// The registry tasks are dispatched into.
  final TaskRegistry registry;

  /// When `true`, [ready] fails with [WorkerSpawnException].
  final bool failSpawn;

  /// Delay before [ready] completes.
  final Duration? readyDelay;

  /// Delay before each task reply is emitted.
  final Duration? taskLatency;

  final bool _clonePayloads;

  /// Every envelope passed to [send], in order.
  final List<Envelope> sentEnvelopes = <Envelope>[];

  /// The `transferBuffers` flag of each [send], parallel to [sentEnvelopes].
  final List<bool> sentTransferFlags = <bool>[];

  /// Number of times [terminate] was called.
  int terminateCount = 0;

  final List<String> _scriptedFailures = <String>[];
  final StreamController<Envelope> _messages = StreamController<Envelope>();
  bool _terminated = false;

  late final Future<void> _ready = _buildReady();

  Future<void> _buildReady() async {
    if (readyDelay != null) {
      await Future<void>.delayed(readyDelay!);
    }
    if (failSpawn) {
      throw WorkerSpawnException(
        'FakeWorkerTransport was configured with failSpawn: true',
      );
    }
  }

  @override
  Future<void> get ready => _ready;

  @override
  Stream<Envelope> get messages => _messages.stream;

  /// Makes the next task fail with an error envelope carrying [message]
  /// (queues up if called repeatedly).
  void failNextTask([String message = 'scripted task failure']) {
    _scriptedFailures.add(message);
  }

  /// Simulates the worker dying: emits a stream **error** (not a protocol
  /// error envelope), which a pool treats as a crash of the in-flight task.
  void crash([Object error = 'FakeWorkerTransport.crash()']) {
    _messages.addError(error);
  }

  @override
  void send(Envelope envelope, {bool transferBuffers = false}) {
    if (_terminated) {
      throw StateError('send() after terminate() on FakeWorkerTransport');
    }
    if (envelope.kind != EnvelopeKind.task) {
      throw ArgumentError.value(
        envelope.kind,
        'envelope',
        'FakeWorkerTransport only accepts task envelopes',
      );
    }
    sentEnvelopes.add(envelope);
    sentTransferFlags.add(transferBuffers);
    final id = envelope.id!;
    final task = envelope.task!;
    final payload = _clonePayloads
        ? simulateStructuredClone(envelope.payload)
        : envelope.payload;
    final scriptedFailure =
        _scriptedFailures.isEmpty ? null : _scriptedFailures.removeAt(0);
    scheduleMicrotask(() async {
      if (taskLatency != null) {
        await Future<void>.delayed(taskLatency!);
      }
      Envelope reply;
      if (scriptedFailure != null) {
        reply = Envelope.error(
          id: id,
          errorMessage: scriptedFailure,
          errorType: 'ScriptedFailure',
        );
      } else {
        try {
          final result = await registry.dispatch(task, payload);
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
      }
      if (!_terminated) {
        _messages.add(reply);
      }
    });
  }

  @override
  Future<void> terminate() async {
    terminateCount += 1;
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
