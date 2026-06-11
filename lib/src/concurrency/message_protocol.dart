/// The structured-clone-safe message protocol spoken between a `WorkerPool`
/// and worker entrypoints, plus the transport abstraction the pool runs on.
///
/// This library is **pure Dart** — no `dart:js_interop`, no `package:web` —
/// so every piece of protocol logic (validation, transfer collection,
/// dispatch, exceptions) is unit-testable on the VM. Only the JS value
/// conversion lives elsewhere (`src/core/interop_casts.dart`, web-only).
library;

import 'dart:async';
import 'dart:typed_data';

import 'shared_buffer.dart';

/// Version of the wire protocol; workers report it in their `ready` envelope
/// and pools reject a mismatch.
const int protocolVersion = 1;

/// Discriminator for [Envelope] messages.
enum EnvelopeKind {
  /// Worker booted, registered its handlers, and is accepting tasks.
  ready('ready'),

  /// Main thread → worker: run a task.
  task('task'),

  /// Worker → main thread: a task completed successfully.
  result('result'),

  /// Worker → main thread: a task handler threw.
  error('error'),

  /// Worker bootstrap failed before the Dart runtime started.
  bootError('boot-error');

  const EnvelopeKind(this.wire);

  /// The string used on the wire for this kind.
  final String wire;

  /// Parses a wire string back into a kind, or `null` when unknown.
  static EnvelopeKind? fromWire(String wire) {
    for (final kind in values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    return null;
  }
}

/// One protocol message.
///
/// The Dart-side mirror of the plain JS object that actually crosses
/// `postMessage` (see `WireEnvelope` in `src/core/js_bindings.dart`).
/// [payload] holds Dart values here; encoding to JS happens at the transport
/// boundary.
final class Envelope {
  const Envelope._({
    required this.kind,
    this.id,
    this.task,
    this.payload,
    this.errorMessage,
    this.errorStack,
    this.errorType,
    this.protocol,
  });

  /// A worker's "booted and listening" announcement.
  const Envelope.ready({int protocol = protocolVersion})
      : this._(kind: EnvelopeKind.ready, protocol: protocol);

  /// A task request.
  const Envelope.task({
    required int id,
    required String task,
    Object? payload,
  }) : this._(kind: EnvelopeKind.task, id: id, task: task, payload: payload);

  /// A successful task result.
  const Envelope.result({required int id, Object? payload})
      : this._(kind: EnvelopeKind.result, id: id, payload: payload);

  /// A failed task.
  const Envelope.error({
    required int id,
    required String errorMessage,
    String? errorStack,
    String? errorType,
  }) : this._(
          kind: EnvelopeKind.error,
          id: id,
          errorMessage: errorMessage,
          errorStack: errorStack,
          errorType: errorType,
        );

  /// A bootstrap-level failure (no task id — the worker never came up).
  const Envelope.bootError({required String errorMessage, String? errorStack})
      : this._(
          kind: EnvelopeKind.bootError,
          errorMessage: errorMessage,
          errorStack: errorStack,
        );

  /// Message discriminator.
  final EnvelopeKind kind;

  /// Correlates a task with its result/error. Set on
  /// [EnvelopeKind.task]/[EnvelopeKind.result]/[EnvelopeKind.error].
  final int? id;

  /// Task name; set on [EnvelopeKind.task].
  final String? task;

  /// Task input or result value; set on [EnvelopeKind.task] and
  /// [EnvelopeKind.result].
  final Object? payload;

  /// Human-readable error description; set on error kinds.
  final String? errorMessage;

  /// Remote stack trace, when available; set on error kinds.
  final String? errorStack;

  /// Remote error `runtimeType` string, when available.
  final String? errorType;

  /// Wire protocol version; set on [EnvelopeKind.ready].
  final int? protocol;

  @override
  String toString() {
    final fields = <String>[
      if (id != null) 'id: $id',
      if (task != null) 'task: $task',
      if (errorMessage != null) 'error: $errorMessage',
      if (protocol != null) 'protocol: $protocol',
    ];
    return 'Envelope.${kind.name}(${fields.join(', ')})';
  }
}

/// Signature of an untyped task handler stored in a [TaskRegistry].
typedef TaskHandler = FutureOr<Object?> Function(Object? payload);

/// Named task handlers, registered by a worker entrypoint (or supplied to a
/// pool's inline fallback) and dispatched by task name.
final class TaskRegistry {
  final Map<String, TaskHandler> _handlers = <String, TaskHandler>{};

  /// Registers [handler] under [name].
  ///
  /// The payload arriving from the wire is cast to [T] before the handler
  /// runs; a wrong [T] surfaces as an error envelope for that task. Throws
  /// [ArgumentError] when [name] is already registered.
  void register<T, R>(String name, FutureOr<R> Function(T payload) handler) {
    if (_handlers.containsKey(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'A task with this name is already registered',
      );
    }
    _handlers[name] = (Object? payload) => handler(payload as T);
  }

  /// Whether a handler named [name] exists.
  bool contains(String name) => _handlers.containsKey(name);

  /// All registered task names.
  Iterable<String> get taskNames => _handlers.keys;

  /// Runs the handler registered under [name].
  ///
  /// Throws [UnknownTaskException] when no such handler exists; handler
  /// errors propagate to the caller.
  Future<Object?> dispatch(String name, Object? payload) async {
    final handler = _handlers[name];
    if (handler == null) {
      throw UnknownTaskException(name, knownTasks: taskNames.toList());
    }
    return await handler(payload);
  }
}

/// The pipe a `WorkerPool` drives: something that can carry [Envelope]s to a
/// task executor and stream replies back.
///
/// Implementations: the real Web Worker transport
/// (`src/concurrency/wasm_worker.dart`, web-only), the in-process
/// `InlineWorkerTransport` (non-web fallback), and the scriptable
/// `FakeWorkerTransport` (`package:wasmforge/testing.dart`).
abstract interface class WorkerTransport {
  /// Completes when the executor is accepting tasks; fails with
  /// [WorkerSpawnException] when it never came up.
  Future<void> get ready;

  /// Sends a task [envelope]. When [transferBuffers] is `true`, every
  /// `ArrayBuffer` reachable from the payload is **moved** (zero-copy) rather
  /// than cloned, detaching it on the sending side.
  void send(Envelope envelope, {bool transferBuffers = false});

  /// Result/error envelopes coming back. A stream **error** means the
  /// executor itself died (crash, not task failure).
  Stream<Envelope> get messages;

  /// Tears the executor down; safe to call more than once.
  Future<void> terminate();
}

/// Creates the transport for worker number [workerIndex] of a pool.
typedef WorkerTransportFactory = WorkerTransport Function(int workerIndex);

/// A task failed inside the worker (or crashed it).
final class WorkerTaskException implements Exception {
  /// Creates the exception surfaced to `WorkerPool.compute` callers.
  WorkerTaskException({
    required this.taskName,
    required this.message,
    this.remoteStackTrace,
    this.remoteErrorType,
    this.workerCrashed = false,
  });

  /// Name of the task that failed.
  final String taskName;

  /// Human-readable failure description from the worker.
  final String message;

  /// The worker-side stack trace, when one was captured.
  final String? remoteStackTrace;

  /// The worker-side error `runtimeType` string, when available.
  final String? remoteErrorType;

  /// `true` when the worker itself died instead of replying with a protocol
  /// error (the pool removes such workers).
  final bool workerCrashed;

  @override
  String toString() {
    final crashed = workerCrashed ? ', worker crashed' : '';
    final type = remoteErrorType == null ? '' : ' [$remoteErrorType]';
    final stack = remoteStackTrace == null
        ? ''
        : '\nRemote stack trace:\n$remoteStackTrace';
    return 'WorkerTaskException(task "$taskName"$crashed)$type: '
        '$message$stack';
  }
}

/// `compute` was called while the pending-task queue is at its configured
/// `maxPendingTasks` limit — the pool's explicit back-pressure signal.
final class WorkerQueueFullException implements Exception {
  /// Creates the exception with the limit that was hit.
  WorkerQueueFullException({required this.maxPendingTasks});

  /// The configured queue limit.
  final int maxPendingTasks;

  @override
  String toString() =>
      'WorkerQueueFullException: the pool already has $maxPendingTasks '
      'pending tasks. Await earlier results before submitting more, or raise '
      'maxPendingTasks.';
}

/// The pool was disposed — pending and in-flight tasks fail with this, and so
/// does any `compute` call made afterwards.
final class WorkerPoolDisposedException implements Exception {
  /// Creates the exception.
  WorkerPoolDisposedException();

  @override
  String toString() => 'WorkerPoolDisposedException: the WorkerPool was '
      'disposed before this task completed.';
}

/// A worker failed to spawn or never reported ready.
final class WorkerSpawnException implements Exception {
  /// Creates the exception with a human-readable [message].
  WorkerSpawnException(this.message, {this.cause});

  /// What went wrong.
  final String message;

  /// The underlying error, when one was captured.
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (cause: $cause)';
    return 'WorkerSpawnException: $message$suffix';
  }
}

/// A task envelope named a task the worker's registry does not contain.
final class UnknownTaskException implements Exception {
  /// Creates the exception for [taskName], listing the [knownTasks].
  UnknownTaskException(this.taskName, {required this.knownTasks});

  /// The unregistered task name that was requested.
  final String taskName;

  /// Task names that are registered.
  final List<String> knownTasks;

  @override
  String toString() =>
      'UnknownTaskException: no handler registered for "$taskName" '
      '(registered: ${knownTasks.isEmpty ? '<none>' : knownTasks.join(', ')}).';
}

/// Validates that [payload] only contains values the wire codec supports.
///
/// The authoritative type table: `null`, `bool`, `int` within ±2^53 - 1,
/// `double`, `String`, `Int8List`, `Uint8List`, `Int16List`, `Uint16List`,
/// `Int32List`, `Uint32List`, `Float32List`, `Float64List`, `ByteData`,
/// `ByteBuffer`, [SharedBuffer], plus `List` and `Map<String, Object?>` of
/// the above. Throws [ArgumentError] naming the offending runtime type and
/// its path inside the payload.
void assertEncodablePayload(Object? payload) => _validate(payload, r'$');

/// Largest integer magnitude that survives a JS `number` round trip
/// (2^53 - 1). Mirrored by the web codec in `src/core/interop_casts.dart`.
///
/// The guard only fires on backends with true 64-bit integers (VM and
/// dart2wasm); under dart2js, `int` already is a JS number, so out-of-range
/// values lost their precision at creation and pass through unchanged.
const int maxSafePayloadInteger = 9007199254740991;

/// `true` on JS backends, where `int` and `double` are the same JS numbers.
final bool _intsAreJsNumbers = identical(1.0, 1);

void _validate(Object? value, String path) {
  switch (value) {
    case null:
    case bool():
    case double():
    case String():
      return;
    case final int v:
      // On dart2js, int IS a JS number: precision beyond 2^53 was already
      // gone at value-creation time, so the guard would reject values that
      // are perfectly fine on the wire. It protects true 64-bit ints
      // (dart2wasm/VM) from silent precision loss.
      if (_intsAreJsNumbers) {
        return;
      }
      if (v > maxSafePayloadInteger || v < -maxSafePayloadInteger) {
        throw ArgumentError(
          'Integer $v at $path exceeds ±2^53 - 1 and cannot cross the worker '
          'boundary without precision loss. Send it as a String or split it.',
        );
      }
      return;
    case Int8List():
    case Uint8List():
    case Int16List():
    case Uint16List():
    case Int32List():
    case Uint32List():
    case Float32List():
    case Float64List():
    case ByteData():
    case ByteBuffer():
    case SharedBuffer():
      return;
    case final List<Object?> v:
      for (var i = 0; i < v.length; i++) {
        _validate(v[i], '$path[$i]');
      }
      return;
    case final Map<Object?, Object?> v:
      for (final entry in v.entries) {
        final key = entry.key;
        if (key is! String) {
          throw ArgumentError(
            'Map key ${entry.key} (${entry.key.runtimeType}) at $path is not '
            'a String; only Map<String, Object?> crosses the worker boundary.',
          );
        }
        _validate(entry.value, '$path.$key');
      }
      return;
    default:
      throw ArgumentError(
        'Unsupported payload value of type ${value.runtimeType} at $path. '
        'Supported: null, bool, int, double, String, typed data, ByteBuffer, '
        'SharedBuffer, List, and Map<String, Object?> thereof.',
      );
  }
}

/// Collects the `ByteBuffer`s reachable from [payload] that would be **moved**
/// by a transfer-enabled send: every typed-data buffer and raw `ByteBuffer`,
/// identity-deduplicated, excluding [SharedBuffer] memory (shared, never
/// transferred).
///
/// Pure mirror of the JS-side collection in `src/core/interop_casts.dart`,
/// used by the in-process transports and VM tests.
List<ByteBuffer> collectTransferableBuffers(Object? payload) {
  final seen = <ByteBuffer>{};
  final result = <ByteBuffer>[];
  _collectBuffers(payload, seen, result);
  return result;
}

void _collectBuffers(
  Object? value,
  Set<ByteBuffer> seen,
  List<ByteBuffer> result,
) {
  switch (value) {
    case SharedBuffer():
      return; // Shared memory is shared, not transferred.
    case final TypedData v:
      if (seen.add(v.buffer)) {
        result.add(v.buffer);
      }
      return;
    case final ByteBuffer v:
      if (seen.add(v)) {
        result.add(v);
      }
      return;
    case final List<Object?> v:
      for (final element in v) {
        _collectBuffers(element, seen, result);
      }
      return;
    case final Map<Object?, Object?> v:
      for (final element in v.values) {
        _collectBuffers(element, seen, result);
      }
      return;
    default:
      return;
  }
}

/// Deep-copies [payload] with the same semantics the structured clone
/// algorithm applies to protocol payloads: containers and typed data are
/// copied, [SharedBuffer]s are passed through **by reference** (their memory
/// is shared), and unsupported values throw [ArgumentError].
///
/// Used by the in-process transports (and available from
/// `package:wasmforge/testing.dart`) so off-browser code sees the same
/// pass-by-value behavior a real worker boundary imposes. Transfer-induced
/// detachment is *not* simulated.
Object? simulateStructuredClone(Object? payload) => _clone(payload, r'$');

Object? _clone(Object? value, String path) {
  switch (value) {
    case null:
    case bool():
    case int():
    case double():
    case String():
      return value;
    case SharedBuffer():
      return value; // Shared by reference, like a real SharedArrayBuffer.
    case final Int8List v:
      return Int8List.fromList(v);
    case final Uint8List v:
      return Uint8List.fromList(v);
    case final Int16List v:
      return Int16List.fromList(v);
    case final Uint16List v:
      return Uint16List.fromList(v);
    case final Int32List v:
      return Int32List.fromList(v);
    case final Uint32List v:
      return Uint32List.fromList(v);
    case final Float32List v:
      return Float32List.fromList(v);
    case final Float64List v:
      return Float64List.fromList(v);
    case final ByteData v:
      final bytes = Uint8List.fromList(
        Uint8List.view(v.buffer, v.offsetInBytes, v.lengthInBytes),
      );
      return bytes.buffer.asByteData();
    case final ByteBuffer v:
      return Uint8List.fromList(v.asUint8List()).buffer;
    case final List<Object?> v:
      return <Object?>[
        for (var i = 0; i < v.length; i++) _clone(v[i], '$path[$i]'),
      ];
    case final Map<Object?, Object?> v:
      final copy = <String, Object?>{};
      for (final entry in v.entries) {
        final key = entry.key;
        if (key is! String) {
          throw ArgumentError(
            'Map key ${entry.key} (${entry.key.runtimeType}) at $path is not '
            'a String; only Map<String, Object?> crosses the worker boundary.',
          );
        }
        copy[key] = _clone(entry.value, '$path.$key');
      }
      return copy;
    default:
      throw ArgumentError(
        'Unsupported payload value of type ${value.runtimeType} at $path. '
        'Supported: null, bool, int, double, String, typed data, ByteBuffer, '
        'SharedBuffer, List, and Map<String, Object?> thereof.',
      );
  }
}
