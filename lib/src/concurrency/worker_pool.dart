/// A pool of task-running workers with FIFO queueing, back-pressure, and
/// graceful degradation off the web.
///
/// The pool itself is **pure Dart**: all scheduling, queueing, and error
/// handling runs over the [WorkerTransport] abstraction and is unit-testable
/// on the VM. Real Web Workers come from the platform factory resolved via a
/// conditional import.
library;

import 'dart:async';
import 'dart:collection';

import '../core/fallback_stub.dart'
    if (dart.library.js_interop) 'wasm_worker.dart' as platform;
import 'inline_transport.dart';
import 'message_protocol.dart';

/// Spawn-time configuration handed to the platform transport factory.
final class WorkerPoolConfig {
  /// Creates the configuration passed through to platform worker spawning.
  const WorkerPoolConfig({
    required this.workerEntrypoint,
    this.bootstrapUri,
    this.moduleUri,
  });

  /// The compiled worker artifact: a `.wasm` (dart2wasm, spawned through the
  /// bootstrap as a module worker) or a `.js` (dart2js, spawned directly as a
  /// classic worker). Relative URIs resolve against the page URL.
  final Uri workerEntrypoint;

  /// Location of `wasmforge_worker_bootstrap.js`; defaults to
  /// `wasmforge_worker_bootstrap.js` next to the page.
  final Uri? bootstrapUri;

  /// The dart2wasm JS runtime module; defaults to [workerEntrypoint] with its
  /// `.wasm` extension replaced by `.mjs`.
  final Uri? moduleUri;
}

/// Off-main-thread compute over a fixed-size set of workers.
///
/// Tasks submitted with [compute] are queued FIFO and dispatched one at a
/// time per worker. On the web, workers are real Web Workers running a
/// compiled Dart entrypoint (see `runWorker` and the README's worker build
/// guide). Off the web the pool degrades gracefully: construction never
/// throws, [ready] completes, and tasks either run in-process (when
/// [WorkerPool.new]'s `inlineFallback` registry is provided) or fail with a
/// descriptive [UnsupportedError].
class WorkerPool {
  /// Creates a pool of [size] workers running [workerEntrypoint].
  ///
  /// [bootstrapUri]/[moduleUri] override the bootstrap location and the
  /// dart2wasm `.mjs` runtime (see [WorkerPoolConfig]). [maxPendingTasks]
  /// bounds the *queued* (not in-flight) task count — when full, [compute]
  /// fails fast with [WorkerQueueFullException]. [readyTimeout] applies per
  /// worker spawn. [inlineFallback] supplies the task registry used to run
  /// tasks in-process on non-web platforms. [onWorkerError] observes worker
  /// spawn failures and crashes (the pool keeps going while any worker
  /// survives).
  WorkerPool({
    required Uri workerEntrypoint,
    int size = 4,
    Uri? bootstrapUri,
    Uri? moduleUri,
    int? maxPendingTasks,
    Duration? readyTimeout,
    TaskRegistry? inlineFallback,
    void Function(Object error, StackTrace stackTrace)? onWorkerError,
  }) : this.custom(
          platform.createPlatformTransportFactory(
                WorkerPoolConfig(
                  workerEntrypoint: workerEntrypoint,
                  bootstrapUri: bootstrapUri,
                  moduleUri: moduleUri,
                ),
              ) ??
              _inlineFactoryFor(inlineFallback),
          size: size,
          maxPendingTasks: maxPendingTasks,
          readyTimeout: readyTimeout,
          onWorkerError: onWorkerError,
        );

  /// Creates a pool over a caller-supplied [transportFactory] — the seam for
  /// tests (`FakeWorkerTransport`) and custom transports. Pass `null` to get
  /// the degraded "unsupported" pool the default constructor produces off the
  /// web without an `inlineFallback`.
  WorkerPool.custom(
    WorkerTransportFactory? transportFactory, {
    int size = 4,
    int? maxPendingTasks,
    Duration? readyTimeout,
    void Function(Object error, StackTrace stackTrace)? onWorkerError,
  })  : _transportFactory = transportFactory,
        _maxPendingTasks = maxPendingTasks,
        _readyTimeout = readyTimeout,
        _onWorkerError = onWorkerError {
    if (size < 1) {
      throw ArgumentError.value(size, 'size', 'must be at least 1');
    }
    final max = _maxPendingTasks;
    if (max != null && max < 1) {
      throw ArgumentError.value(max, 'maxPendingTasks', 'must be at least 1');
    }
    final factory = _transportFactory;
    if (factory == null) {
      _ready = Future<void>.value();
      return;
    }
    for (var i = 0; i < size; i++) {
      _spawnWorker(i, factory);
    }
    _ready = _awaitWorkersReady();
    _ready.ignore();
  }

  static WorkerTransportFactory? _inlineFactoryFor(TaskRegistry? registry) =>
      registry == null ? null : ((int _) => InlineWorkerTransport(registry));

  final WorkerTransportFactory? _transportFactory;
  final int? _maxPendingTasks;
  final Duration? _readyTimeout;
  final void Function(Object error, StackTrace stackTrace)? _onWorkerError;

  final List<_PoolWorker> _workers = <_PoolWorker>[];
  final Queue<_PendingTask> _queue = Queue<_PendingTask>();
  final Map<int, _PendingTask> _inFlight = <int, _PendingTask>{};
  late final Future<void> _ready;
  int _nextTaskId = 0;
  bool _disposed = false;

  /// Completes when at least one worker is accepting tasks; fails with
  /// [WorkerSpawnException] only when **every** worker failed to come up.
  /// Always completes successfully in inline-fallback and unsupported modes.
  Future<void> get ready => _ready;

  /// Number of live workers (decreases when workers crash; the pool does not
  /// respawn in this version).
  int get size => _workers.length;

  /// Number of tasks waiting in the queue (excludes in-flight tasks).
  int get pendingTaskCount => _queue.length;

  /// Runs the task registered as [task] in a worker, passing [payload], and
  /// completes with its result cast to [R].
  ///
  /// [payload] and the result must use the protocol's supported type table
  /// (see `assertEncodablePayload`); violations fail fast with
  /// [ArgumentError]. With [transferBuffers], every `ArrayBuffer` reachable
  /// from the payload is **moved** to the worker (zero-copy) and becomes
  /// unusable on this side. Failures surface as [WorkerTaskException]
  /// (handler errors and crashes), [WorkerQueueFullException]
  /// (back-pressure), [WorkerPoolDisposedException], [WorkerSpawnException]
  /// (no live workers), or [UnsupportedError] (non-web without a fallback).
  Future<R> compute<T, R>(
    String task,
    T payload, {
    bool transferBuffers = false,
  }) {
    if (_disposed) {
      return Future<R>.error(WorkerPoolDisposedException());
    }
    if (_transportFactory == null) {
      return Future<R>.error(
        UnsupportedError(
          'This WorkerPool has no platform worker support (non-web platform) '
          'and no inlineFallback registry was provided. On the web, point '
          'workerEntrypoint at a compiled worker; elsewhere pass '
          'inlineFallback: TaskRegistry(...) to run tasks in-process.',
        ),
      );
    }
    if (_workers.isEmpty) {
      return Future<R>.error(
        WorkerSpawnException(
          'No live workers remain in this pool (all spawns failed or all '
          'workers crashed); create a new WorkerPool.',
        ),
      );
    }
    try {
      assertEncodablePayload(payload);
    } on Object catch (error, stackTrace) {
      return Future<R>.error(error, stackTrace);
    }
    final max = _maxPendingTasks;
    if (max != null && _queue.length >= max) {
      return Future<R>.error(WorkerQueueFullException(maxPendingTasks: max));
    }
    final pending = _PendingTask(_nextTaskId++, task, payload, transferBuffers);
    _queue.add(pending);
    _pump();
    return pending.completer.future.then<R>((value) {
      if (value is R) {
        return value;
      }
      throw WorkerTaskException(
        taskName: task,
        message: 'compute<$T, $R>() received a result of type '
            '${value.runtimeType}, which is not $R.',
      );
    });
  }

  /// Disposes the pool: fails queued and in-flight tasks with
  /// [WorkerPoolDisposedException], terminates every worker, and makes
  /// subsequent [compute] calls fail fast. Idempotent.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final error = WorkerPoolDisposedException();
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.completeError(error);
    }
    for (final pending in _inFlight.values.toList()) {
      pending.completer.completeError(error);
    }
    _inFlight.clear();
    final workers = _workers.toList();
    _workers.clear();
    for (final worker in workers) {
      await worker.subscription?.cancel();
    }
    await Future.wait(workers.map((worker) => worker.transport.terminate()));
  }

  void _spawnWorker(int index, WorkerTransportFactory factory) {
    final _PoolWorker worker;
    try {
      worker = _PoolWorker(index, factory(index));
    } on Object catch (error, stackTrace) {
      _onWorkerError?.call(error, stackTrace);
      return;
    }
    _workers.add(worker);
    worker.subscription = worker.transport.messages.listen(
      (envelope) => _onWorkerMessage(worker, envelope),
      onError: (Object error, StackTrace stackTrace) {
        _onWorkerError?.call(error, stackTrace);
        _removeWorker(worker, error: error, stackTrace: stackTrace);
      },
      onDone: () {
        if (!_disposed && _workers.contains(worker)) {
          _removeWorker(
            worker,
            error: StateError('worker message stream closed unexpectedly'),
          );
        }
      },
    );
  }

  Future<void> _awaitWorkersReady() async {
    Object? firstError;
    await Future.wait(
      _workers.toList().map((worker) async {
        try {
          var readyFuture = worker.transport.ready;
          final timeout = _readyTimeout;
          if (timeout != null) {
            readyFuture = readyFuture.timeout(
              timeout,
              onTimeout: () => throw WorkerSpawnException(
                'worker #${worker.index} did not become ready within '
                '$timeout',
              ),
            );
          }
          await readyFuture;
          worker.becameReady = true;
        } on Object catch (error, stackTrace) {
          firstError ??= error;
          _onWorkerError?.call(error, stackTrace);
          _removeWorker(worker, error: error, stackTrace: stackTrace);
        }
      }),
    );
    if (_disposed) {
      return;
    }
    if (_workers.isEmpty) {
      throw WorkerSpawnException(
        'No worker in the pool became ready.',
        cause: firstError,
      );
    }
  }

  void _onWorkerMessage(_PoolWorker worker, Envelope envelope) {
    if (envelope.kind != EnvelopeKind.result &&
        envelope.kind != EnvelopeKind.error) {
      return;
    }
    final id = envelope.id;
    final pending = id == null ? null : _inFlight.remove(id);
    if (pending == null) {
      // Late reply for a task that was requeued, disposed, or failed — drop.
      return;
    }
    if (identical(worker.current, pending)) {
      worker.current = null;
    }
    if (envelope.kind == EnvelopeKind.result) {
      pending.completer.complete(envelope.payload);
    } else {
      pending.completer.completeError(
        WorkerTaskException(
          taskName: pending.taskName,
          message: envelope.errorMessage ?? 'unknown worker error',
          remoteStackTrace: envelope.errorStack,
          remoteErrorType: envelope.errorType,
        ),
      );
    }
    _pump();
  }

  void _removeWorker(
    _PoolWorker worker, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_workers.remove(worker)) {
      return;
    }
    unawaited(worker.subscription?.cancel());
    worker.subscription = null;
    unawaited(worker.transport.terminate());
    final pending = worker.current;
    worker.current = null;
    if (pending != null) {
      _inFlight.remove(pending.id);
      if (!worker.becameReady && !_disposed && _workers.isNotEmpty) {
        // The transport buffers sends until ready, so this task was never
        // delivered — safe to hand to a surviving worker.
        _queue.addFirst(pending);
      } else {
        pending.completer.completeError(
          WorkerTaskException(
            taskName: pending.taskName,
            message: error?.toString() ?? 'worker terminated',
            workerCrashed: true,
          ),
          stackTrace,
        );
      }
    }
    if (_workers.isEmpty && !_disposed) {
      final spawnError = WorkerSpawnException(
        'All workers in the pool have terminated.',
        cause: error,
      );
      while (_queue.isNotEmpty) {
        _queue.removeFirst().completer.completeError(spawnError);
      }
    } else {
      _pump();
    }
  }

  void _pump() {
    if (_disposed) {
      return;
    }
    for (final worker in _workers) {
      if (_queue.isEmpty) {
        return;
      }
      if (worker.current != null) {
        continue;
      }
      final pending = _queue.removeFirst();
      worker.current = pending;
      _inFlight[pending.id] = pending;
      try {
        worker.transport.send(
          Envelope.task(
            id: pending.id,
            task: pending.taskName,
            payload: pending.payload,
          ),
          transferBuffers: pending.transferBuffers,
        );
      } on Object catch (error, stackTrace) {
        _inFlight.remove(pending.id);
        worker.current = null;
        pending.completer.completeError(
          WorkerTaskException(
            taskName: pending.taskName,
            message: 'failed to send task to worker: $error',
          ),
          stackTrace,
        );
      }
    }
  }
}

final class _PoolWorker {
  _PoolWorker(this.index, this.transport);

  final int index;
  final WorkerTransport transport;
  StreamSubscription<Envelope>? subscription;
  _PendingTask? current;
  bool becameReady = false;
}

final class _PendingTask {
  _PendingTask(this.id, this.taskName, this.payload, this.transferBuffers);

  final int id;
  final String taskName;
  final Object? payload;
  final bool transferBuffers;
  final Completer<Object?> completer = Completer<Object?>();
}
