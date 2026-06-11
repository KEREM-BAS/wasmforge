@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

TaskRegistry _mathRegistry() => TaskRegistry()
  ..register<int, int>('double', (n) => n * 2)
  ..register<String, String>('echo', (s) => s);

void main() {
  group('WorkerPool over fake transports', () {
    test('ready completes and compute round-trips typed results', () async {
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(registry: _mathRegistry()),
        size: 2,
      );
      await pool.ready;
      expect(pool.size, 2);
      expect(await pool.compute<int, int>('double', 21), 42);
      expect(await pool.compute<String, String>('echo', 'hi'), 'hi');
      await pool.dispose();
    });

    test('queues FIFO and runs one task per worker at a time', () async {
      final transports = <FakeWorkerTransport>[];
      final pool = WorkerPool.custom(
        (_) {
          final transport = FakeWorkerTransport(
            registry: _mathRegistry(),
            taskLatency: const Duration(milliseconds: 20),
          );
          transports.add(transport);
          return transport;
        },
        size: 2,
      );
      await pool.ready;

      final results = <int>[];
      final futures = <Future<void>>[
        for (var i = 0; i < 5; i++)
          pool.compute<int, int>('double', i).then(results.add),
      ];
      // Two workers, five tasks: exactly two dispatched immediately.
      final dispatched = transports.fold<int>(
        0,
        (sum, t) => sum + t.sentEnvelopes.length,
      );
      expect(dispatched, 2);
      expect(pool.pendingTaskCount, 3);

      await Future.wait(futures);
      expect(results, [0, 2, 4, 6, 8]); // FIFO completion order.
      expect(pool.pendingTaskCount, 0);
      await pool.dispose();
    });

    test('maxPendingTasks signals back-pressure immediately', () async {
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(
          registry: _mathRegistry(),
          taskLatency: const Duration(milliseconds: 50),
        ),
        size: 1,
        maxPendingTasks: 2,
      );
      await pool.ready;

      final accepted = <Future<int>>[
        pool.compute<int, int>('double', 1), // in-flight
        pool.compute<int, int>('double', 2), // queued (1/2)
        pool.compute<int, int>('double', 3), // queued (2/2)
      ];
      expect(
        pool.compute<int, int>('double', 4),
        throwsA(
          isA<WorkerQueueFullException>().having(
            (e) => e.maxPendingTasks,
            'maxPendingTasks',
            2,
          ),
        ),
      );
      expect(await Future.wait(accepted), [2, 4, 6]);
      await pool.dispose();
    });

    test('invalid payloads fail fast without reaching a worker', () async {
      final transport = FakeWorkerTransport(registry: _mathRegistry());
      final pool = WorkerPool.custom((_) => transport, size: 1);
      await pool.ready;
      await expectLater(
        pool.compute<Object, int>('double', DateTime(2026)),
        throwsArgumentError,
      );
      expect(transport.sentEnvelopes, isEmpty);
      await pool.dispose();
    });

    test('worker task failures surface as WorkerTaskException', () async {
      final transport = FakeWorkerTransport(registry: _mathRegistry())
        ..failNextTask('injected failure');
      final pool = WorkerPool.custom((_) => transport, size: 1);
      await pool.ready;
      await expectLater(
        pool.compute<int, int>('double', 1),
        throwsA(
          isA<WorkerTaskException>()
              .having((e) => e.taskName, 'taskName', 'double')
              .having((e) => e.message, 'message', 'injected failure')
              .having((e) => e.remoteErrorType, 'type', 'ScriptedFailure')
              .having((e) => e.workerCrashed, 'workerCrashed', isFalse),
        ),
      );
      // The pool recovers for the next task.
      expect(await pool.compute<int, int>('double', 2), 4);
      await pool.dispose();
    });

    test('remote stack traces ride along on handler errors', () async {
      final registry = TaskRegistry()
        ..register<Object?, Object?>('boom', (_) => throw StateError('bad'));
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(registry: registry),
        size: 1,
      );
      await expectLater(
        pool.compute<Object?, Object?>('boom', null),
        throwsA(
          isA<WorkerTaskException>()
              .having((e) => e.remoteErrorType, 'type', 'StateError')
              .having((e) => e.remoteStackTrace, 'stack', isNotNull)
              .having((e) => e.toString(), 'toString', contains('bad')),
        ),
      );
      await pool.dispose();
    });

    test('a crashed worker fails its in-flight task and shrinks the pool',
        () async {
      final transports = <FakeWorkerTransport>[];
      final errors = <Object>[];
      final pool = WorkerPool.custom(
        (_) {
          final transport = FakeWorkerTransport(
            registry: _mathRegistry(),
            taskLatency: const Duration(seconds: 10), // never replies in time
          );
          transports.add(transport);
          return transport;
        },
        size: 2,
        onWorkerError: (error, _) => errors.add(error),
      );
      await pool.ready;

      final doomed = pool.compute<int, int>('double', 1);
      // Attach the expectation BEFORE the error fires so the failure is
      // never an unhandled async error.
      final doomedFails = expectLater(
        doomed,
        throwsA(
          isA<WorkerTaskException>()
              .having((e) => e.workerCrashed, 'workerCrashed', isTrue)
              .having((e) => e.message, 'message', contains('worker died')),
        ),
      );
      transports.first.crash('worker died');
      await doomedFails;
      expect(pool.size, 1);
      expect(errors, isNotEmpty);
      await pool.dispose();
    });

    test('when every worker dies, queued tasks and new computes fail',
        () async {
      final transports = <FakeWorkerTransport>[];
      final pool = WorkerPool.custom(
        (_) {
          final transport = FakeWorkerTransport(
            registry: _mathRegistry(),
            taskLatency: const Duration(seconds: 10),
          );
          transports.add(transport);
          return transport;
        },
        size: 1,
      );
      await pool.ready;

      final inFlight = pool.compute<int, int>('double', 1);
      final queued = pool.compute<int, int>('double', 2);
      final inFlightFails = expectLater(
        inFlight,
        throwsA(
          isA<WorkerTaskException>().having(
            (e) => e.workerCrashed,
            'workerCrashed',
            isTrue,
          ),
        ),
      );
      final queuedFails = expectLater(
        queued,
        throwsA(isA<WorkerSpawnException>()),
      );
      transports.single.crash('the only worker died');
      await inFlightFails;
      await queuedFails;
      expect(pool.size, 0);
      await expectLater(
        pool.compute<int, int>('double', 3),
        throwsA(isA<WorkerSpawnException>()),
      );
      await pool.dispose();
    });

    test('partial spawn failure degrades the pool but ready succeeds',
        () async {
      final errors = <Object>[];
      final pool = WorkerPool.custom(
        (index) => index == 0
            ? FakeWorkerTransport(failSpawn: true)
            : FakeWorkerTransport(registry: _mathRegistry()),
        size: 2,
        onWorkerError: (error, _) => errors.add(error),
      );
      await pool.ready;
      expect(pool.size, 1);
      expect(errors.single, isA<WorkerSpawnException>());
      expect(await pool.compute<int, int>('double', 5), 10);
      await pool.dispose();
    });

    test('a task assigned to a never-ready worker is requeued, not lost',
        () async {
      final pool = WorkerPool.custom(
        (index) => index == 0
            ? FakeWorkerTransport(
                failSpawn: true,
                readyDelay: const Duration(milliseconds: 30),
                clonePayloads: false,
              )
            : FakeWorkerTransport(
                registry: _mathRegistry(),
                readyDelay: const Duration(milliseconds: 10),
              ),
        size: 2,
      );
      // Submit before anything is ready: worker #0 gets the task first.
      final result = pool.compute<int, int>('double', 21);
      await pool.ready;
      expect(pool.size, 1);
      expect(await result, 42);
      await pool.dispose();
    });

    test('ready fails with WorkerSpawnException when all spawns fail',
        () async {
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(failSpawn: true),
        size: 2,
      );
      await expectLater(pool.ready, throwsA(isA<WorkerSpawnException>()));
      expect(pool.size, 0);
      await pool.dispose();
    });

    test('readyTimeout fails workers that never report ready', () async {
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(
          readyDelay: const Duration(seconds: 30),
        ),
        size: 1,
        readyTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        pool.ready,
        throwsA(
          isA<WorkerSpawnException>().having(
            (e) => e.toString(),
            'toString',
            contains('did not become ready'),
          ),
        ),
      );
      await pool.dispose();
    });

    test('mismatched result type surfaces as WorkerTaskException', () async {
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(registry: _mathRegistry()),
        size: 1,
      );
      await expectLater(
        pool.compute<String, int>('echo', 'not an int'),
        throwsA(
          isA<WorkerTaskException>().having(
            (e) => e.message,
            'message',
            contains('is not int'),
          ),
        ),
      );
      await pool.dispose();
    });

    test('dispose fails queued + in-flight tasks and blocks new ones',
        () async {
      final pool = WorkerPool.custom(
        (_) => FakeWorkerTransport(
          registry: _mathRegistry(),
          taskLatency: const Duration(seconds: 10),
        ),
        size: 1,
      );
      await pool.ready;
      final inFlight = pool.compute<int, int>('double', 1);
      final queued = pool.compute<int, int>('double', 2);
      final inFlightFails = expectLater(
        inFlight,
        throwsA(isA<WorkerPoolDisposedException>()),
      );
      final queuedFails = expectLater(
        queued,
        throwsA(isA<WorkerPoolDisposedException>()),
      );
      await pool.dispose();
      await pool.dispose(); // idempotent
      await inFlightFails;
      await queuedFails;
      await expectLater(
        pool.compute<int, int>('double', 3),
        throwsA(isA<WorkerPoolDisposedException>()),
      );
    });

    test('constructor validates size and maxPendingTasks', () {
      expect(
        () => WorkerPool.custom((_) => FakeWorkerTransport(), size: 0),
        throwsArgumentError,
      );
      expect(
        () => WorkerPool.custom(
          (_) => FakeWorkerTransport(),
          maxPendingTasks: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('WorkerPool platform fallback on the VM', () {
    test('default constructor never throws; unsupported compute explains',
        () async {
      final pool = WorkerPool(workerEntrypoint: Uri.parse('w.wasm'));
      await pool.ready; // completes normally
      await expectLater(
        pool.compute<int, int>('double', 1),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('inlineFallback'),
          ),
        ),
      );
      await pool.dispose();
    });

    test('inlineFallback runs tasks in-process with clone semantics', () async {
      final pool = WorkerPool(
        workerEntrypoint: Uri.parse('w.wasm'),
        size: 2,
        inlineFallback: _mathRegistry(),
      );
      await pool.ready;
      expect(pool.size, 2);
      expect(await pool.compute<int, int>('double', 8), 16);
      await pool.dispose();
    });

    test('runWorker is a harmless no-op off the web', () async {
      await runWorker(TaskRegistry()); // must not throw
    });
  });
}
