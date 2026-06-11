@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:test/test.dart';
import 'package:wasmforge/src/concurrency/inline_transport.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

TaskRegistry _mathRegistry() => TaskRegistry()
  ..register<int, int>('double', (n) => n * 2)
  ..register<List<Object?>, int>(
    'sum',
    (values) => values.cast<int>().fold<int>(0, (a, b) => a + b),
  );

void main() {
  group('FakeWorkerTransport', () {
    test('completes ready and round-trips a task', () async {
      final transport = FakeWorkerTransport(registry: _mathRegistry());
      await transport.ready;
      final replies = StreamQueue<Envelope>(transport.messages);

      transport.send(const Envelope.task(id: 1, task: 'double', payload: 21));
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.result);
      expect(reply.id, 1);
      expect(reply.payload, 42);

      expect(transport.sentEnvelopes, hasLength(1));
      expect(transport.sentTransferFlags, [false]);
      await transport.terminate();
    });

    test('clones payloads at send time (pass-by-value semantics)', () async {
      final received = <Object?>[];
      final registry = TaskRegistry()
        ..register<List<Object?>, int>('capture', (payload) {
          received.add(payload);
          return payload.length;
        });
      final transport = FakeWorkerTransport(registry: registry);
      final replies = StreamQueue<Envelope>(transport.messages);

      final payload = <Object?>[
        Uint8List.fromList([1, 2, 3])
      ];
      transport.send(Envelope.task(id: 1, task: 'capture', payload: payload));
      // Mutating after send must not affect what the handler sees.
      (payload[0]! as Uint8List)[0] = 99;
      payload.add('extra');

      await replies.next;
      final captured = received.single! as List<Object?>;
      expect(captured, hasLength(1));
      expect(captured[0], Uint8List.fromList([1, 2, 3]));
      await transport.terminate();
    });

    test('failNextTask produces an error envelope, then recovers', () async {
      final transport = FakeWorkerTransport(registry: _mathRegistry())
        ..failNextTask('injected');
      final replies = StreamQueue<Envelope>(transport.messages);

      transport.send(const Envelope.task(id: 1, task: 'double', payload: 1));
      transport.send(const Envelope.task(id: 2, task: 'double', payload: 2));

      final first = await replies.next;
      expect(first.kind, EnvelopeKind.error);
      expect(first.errorMessage, 'injected');
      expect(first.errorType, 'ScriptedFailure');

      final second = await replies.next;
      expect(second.kind, EnvelopeKind.result);
      expect(second.payload, 4);
      await transport.terminate();
    });

    test('unknown tasks surface as error envelopes', () async {
      final transport = FakeWorkerTransport();
      final replies = StreamQueue<Envelope>(transport.messages);
      transport.send(const Envelope.task(id: 1, task: 'nope'));
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.error);
      expect(reply.errorMessage, contains('UnknownTaskException'));
      await transport.terminate();
    });

    test('crash() emits a stream error (worker death, not task error)', () {
      final transport = FakeWorkerTransport(registry: _mathRegistry());
      expect(transport.messages, emitsError('simulated death'));
      transport.crash('simulated death');
    });

    test('failSpawn fails ready with WorkerSpawnException', () {
      final transport = FakeWorkerTransport(failSpawn: true);
      expect(transport.ready, throwsA(isA<WorkerSpawnException>()));
    });

    test('readyDelay postpones readiness', () async {
      final transport = FakeWorkerTransport(
        readyDelay: const Duration(milliseconds: 50),
      );
      var done = false;
      unawaited(transport.ready.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(done, isFalse);
      await transport.ready;
      expect(done, isTrue);
    });

    test('terminate is idempotent and blocks further sends', () async {
      final transport = FakeWorkerTransport(registry: _mathRegistry());
      await transport.terminate();
      await transport.terminate();
      expect(transport.terminateCount, 2);
      expect(
        () => transport.send(const Envelope.task(id: 1, task: 'double')),
        throwsStateError,
      );
    });

    test('rejects non-task envelopes', () {
      final transport = FakeWorkerTransport();
      expect(
        () => transport.send(const Envelope.ready()),
        throwsArgumentError,
      );
    });
  });

  group('InlineWorkerTransport', () {
    test('round-trips tasks through the registry', () async {
      final transport = InlineWorkerTransport(_mathRegistry());
      await transport.ready;
      final replies = StreamQueue<Envelope>(transport.messages);
      transport.send(
        const Envelope.task(id: 5, task: 'sum', payload: <Object?>[1, 2, 3]),
      );
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.result);
      expect(reply.id, 5);
      expect(reply.payload, 6);
      await transport.terminate();
    });

    test('handler errors become error envelopes with remote details', () async {
      final registry = TaskRegistry()
        ..register<Object?, Object?>('boom', (_) => throw StateError('bad'));
      final transport = InlineWorkerTransport(registry);
      final replies = StreamQueue<Envelope>(transport.messages);
      transport.send(const Envelope.task(id: 1, task: 'boom'));
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.error);
      expect(reply.errorMessage, contains('bad'));
      expect(reply.errorType, 'StateError');
      expect(reply.errorStack, isNotNull);
      await transport.terminate();
    });

    test('unencodable results become error envelopes (codec honesty)',
        () async {
      final registry = TaskRegistry()
        ..register<Object?, Object?>('clock', (_) => DateTime(2026));
      final transport = InlineWorkerTransport(registry);
      final replies = StreamQueue<Envelope>(transport.messages);
      transport.send(const Envelope.task(id: 1, task: 'clock'));
      final reply = await replies.next;
      expect(reply.kind, EnvelopeKind.error);
      expect(reply.errorMessage, contains('DateTime'));
      await transport.terminate();
    });

    test('clonePayloads: false aliases payloads (opt-in)', () async {
      Object? seen;
      final registry = TaskRegistry()
        ..register<Object?, Object?>('capture', (payload) {
          seen = payload;
          return null;
        });
      final transport = InlineWorkerTransport(registry, clonePayloads: false);
      final replies = StreamQueue<Envelope>(transport.messages);
      final payload = Uint8List.fromList([1, 2, 3]);
      transport.send(Envelope.task(id: 1, task: 'capture', payload: payload));
      await replies.next;
      expect(seen, same(payload));
      await transport.terminate();
    });
  });
}
