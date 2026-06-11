@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:test/test.dart';
import 'package:wasmforge/src/concurrency/wasm_worker.dart'
    show WebWorkerTransport, debugWorkerFactory;
import 'package:wasmforge/src/core/js_bindings.dart';
import 'package:wasmforge/src/testing/interop_mocks_web.dart' show MockWorker;
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';
import 'package:web/web.dart' as web;

void main() {
  tearDown(() {
    debugWorkerFactory = null;
    clearCapabilityOverrides();
  });

  group('spawn URL scheme', () {
    test('a .wasm entrypoint spawns a module worker via the bootstrap', () {
      String? spawnedUrl;
      web.WorkerOptions? spawnedOptions;
      final mock = MockWorker();
      debugWorkerFactory = (url, options) {
        spawnedUrl = url;
        spawnedOptions = options;
        return mock.asWorker();
      };
      WebWorkerTransport.spawn(
        config: WorkerPoolConfig(
          workerEntrypoint: Uri.parse('workers/job.wasm'),
        ),
        workerIndex: 3,
      );
      expect(spawnedUrl, contains('wasmforge_worker_bootstrap.js?'));
      final parsed = Uri.parse(spawnedUrl!);
      final wasmParam = Uri.parse(parsed.queryParameters['wasm']!);
      final mjsParam = Uri.parse(parsed.queryParameters['mjs']!);
      expect(wasmParam.isAbsolute, isTrue);
      expect(wasmParam.path, endsWith('workers/job.wasm'));
      expect(mjsParam.path, endsWith('workers/job.mjs'));
      expect(spawnedOptions, isNotNull);
      expect(spawnedOptions!.type, 'module');
    });

    test('a .js entrypoint spawns a classic worker directly', () {
      String? spawnedUrl;
      web.WorkerOptions? spawnedOptions = web.WorkerOptions();
      final mock = MockWorker();
      debugWorkerFactory = (url, options) {
        spawnedUrl = url;
        spawnedOptions = options;
        return mock.asWorker();
      };
      WebWorkerTransport.spawn(
        config: WorkerPoolConfig(workerEntrypoint: Uri.parse('workers/job.js')),
        workerIndex: 0,
      );
      expect(spawnedUrl, endsWith('workers/job.js'));
      expect(spawnedUrl, isNot(contains('bootstrap')));
      expect(spawnedOptions, isNull);
    });

    test('custom bootstrapUri and moduleUri are honored', () {
      String? spawnedUrl;
      final mock = MockWorker();
      debugWorkerFactory = (url, _) {
        spawnedUrl = url;
        return mock.asWorker();
      };
      WebWorkerTransport.spawn(
        config: WorkerPoolConfig(
          workerEntrypoint: Uri.parse('workers/job.wasm'),
          bootstrapUri: Uri.parse('assets/boot.js'),
          moduleUri: Uri.parse('runtime/custom.mjs'),
        ),
        workerIndex: 0,
      );
      final parsed = Uri.parse(spawnedUrl!);
      expect(parsed.path, endsWith('assets/boot.js'));
      expect(
        Uri.parse(parsed.queryParameters['mjs']!).path,
        endsWith('runtime/custom.mjs'),
      );
    });
  });

  group('protocol over a MockWorker', () {
    late MockWorker mock;
    late WebWorkerTransport transport;

    setUp(() {
      mock = MockWorker();
      debugWorkerFactory = (_, __) => mock.asWorker();
      transport = WebWorkerTransport.spawn(
        config: WorkerPoolConfig(workerEntrypoint: Uri.parse('job.wasm')),
        workerIndex: 0,
      );
    });

    test('sends are buffered until the ready envelope arrives', () async {
      transport.send(const Envelope.task(id: 1, task: 'work', payload: 5));
      expect(mock.postedMessages, isEmpty);

      mock.emitReady();
      await transport.ready;
      expect(mock.postedMessages, hasLength(1));
      final wire = mock.postedMessages.single! as WireEnvelope;
      expect(wire.kind, 'task');
      expect(wire.id, 1);
      expect(wire.task, 'work');

      transport.send(const Envelope.task(id: 2, task: 'work'));
      expect(mock.postedMessages, hasLength(2));
    });

    test('a protocol-version mismatch fails ready with guidance', () async {
      mock.emitReady(protocol: 99);
      await expectLater(
        transport.ready,
        throwsA(
          isA<WorkerSpawnException>().having(
            (e) => e.toString(),
            'toString',
            allOf(contains('protocol'), contains('recompile')),
          ),
        ),
      );
    });

    test('result envelopes decode through the real codec', () async {
      mock.emitReady();
      final replies = StreamQueue<Envelope>(transport.messages);
      mock.emitResult(7, 'done'.toJS);
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.result);
      expect(reply.id, 7);
      expect(reply.payload, 'done');
    });

    test('error envelopes carry remote details', () async {
      mock.emitReady();
      final replies = StreamQueue<Envelope>(transport.messages);
      mock.emitError(3, 'kaput',
          stack: 'remote stack', errorType: 'StateError');
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.error);
      expect(reply.errorMessage, 'kaput');
      expect(reply.errorStack, 'remote stack');
      expect(reply.errorType, 'StateError');
    });

    test('a boot-error envelope fails ready', () async {
      mock.emitBootError('404 on wasm');
      await expectLater(
        transport.ready,
        throwsA(
          isA<WorkerSpawnException>().having(
            (e) => e.toString(),
            'toString',
            contains('404 on wasm'),
          ),
        ),
      );
    });

    test('a worker error event before ready fails ready', () async {
      mock.emitWorkerError('script failed to load');
      await expectLater(
        transport.ready,
        throwsA(isA<WorkerSpawnException>()),
      );
    });

    test('transferBuffers posts a transfer array; plain sends do not',
        () async {
      mock.emitReady();
      await transport.ready;
      transport.send(
        Envelope.task(
          id: 1,
          task: 'work',
          payload: Uint8List.fromList([1, 2]),
        ),
        transferBuffers: true,
      );
      transport.send(const Envelope.task(id: 2, task: 'work', payload: 'x'));
      final transferArg = mock.postedTransfers[0];
      expect(transferArg, isNotNull);
      expect((transferArg! as JSArray<JSObject>).toDart, hasLength(1));
      expect(mock.postedTransfers[1], isNull);
    });

    test('terminate forwards to the worker and blocks further sends', () async {
      await transport.terminate();
      expect(mock.terminateCount, 1);
      expect(
        () => transport.send(const Envelope.task(id: 9, task: 'work')),
        throwsStateError,
      );
    });
  });

  group('WorkerPool over the JS loopback transport (in-browser)', () {
    test('computes through the real codec and structuredClone', () async {
      final registry = TaskRegistry()
        ..register<Map<String, Object?>, int>('sumBytes', (payload) {
          final bytes = payload['bytes']! as Uint8List;
          var sum = 0;
          for (final byte in bytes) {
            sum += byte;
          }
          return sum;
        });
      final pool = WorkerPool.custom(
        (_) => createJsLoopbackTransport(registry),
        size: 2,
      );
      await pool.ready;
      final result = await pool.compute<Map<String, Object?>, int>('sumBytes', {
        'bytes': Uint8List.fromList([1, 2, 3, 4]),
      });
      expect(result, 10);
      await pool.dispose();
    });

    test('transfer-enabled compute still delivers intact payloads', () async {
      final registry = TaskRegistry()
        ..register<Uint8List, int>('len', (bytes) => bytes.length);
      final pool = WorkerPool.custom(
        (_) => createJsLoopbackTransport(registry),
        size: 1,
      );
      final length = await pool.compute<Uint8List, int>(
        'len',
        Uint8List(8),
        transferBuffers: true,
      );
      expect(length, 8);
      await pool.dispose();
    });
  });

  group('runWorker guard', () {
    test('throws StateError when not inside a dedicated worker scope',
        () async {
      await expectLater(runWorker(TaskRegistry()), throwsStateError);
    });
  });
}
