# wasmforge

WASM-native building blocks for Flutter Web: typed JS interop, capability
detection, and off-main-thread compute via Web Workers + `SharedArrayBuffer`,
with graceful fallbacks everywhere.

- **Compiles under dart2wasm.** No `dart:html`, no legacy `package:js` —
  only `package:web` + `dart:js_interop`. Runs on the skwasm renderer and
  stays compatible with CanvasKit/JS builds (and the dart2js compiler).
- **Pure Dart core.** The package has no Flutter dependency: use it from any
  Flutter Web app, plain Dart web app, or test it on the VM.
- **Graceful everywhere.** Importing wasmforge never throws off the web.
  Capability getters report `false`, `SharedBuffer.tryAllocate` returns
  `null`, and `WorkerPool` either runs your tasks in-process or fails with a
  descriptive error — never a crash.
- **Mockable by design.** Every browser API sits behind an interface;
  `package:wasmforge/testing.dart` ships pure-Dart fakes (VM) and JS-interop
  mocks (browser tests) so downstream code is unit-testable without a
  browser.

## Quickstart

```yaml
dependencies:
  wasmforge: ^0.1.0
```

```dart
import 'package:wasmforge/wasmforge.dart';

void main() {
  print(detectCapabilityMatrix());
  // CapabilityMatrix(isWeb: true, isCrossOriginIsolated: true,
  //                  supportsWasmGc: true)
}
```

| Getter | Meaning |
|---|---|
| `isWeb` | compiled by dart2js or dart2wasm |
| `isCrossOriginIsolated` | COOP/COEP headers present → `SharedArrayBuffer` usable |
| `supportsWasmGc` | the engine can run dart2wasm output (feature-detected via `WebAssembly.validate`) |

## Running compute in a worker

Dart code in a Web Worker is a **separately compiled program**. Three steps:

**1. Write a worker entrypoint** (no Flutter imports):

```dart
// lib/worker/my_worker.dart
import 'package:wasmforge/wasmforge.dart';

void main() {
  runWorker(
    TaskRegistry()
      ..register<List<Object?>, int>('sum', (values) =>
          values.cast<int>().fold<int>(0, (a, b) => a + b)),
  );
}
```

**2. Compile it and stage the bootstrap** (rerun when the worker changes):

```sh
dart compile wasm lib/worker/my_worker.dart \
    -o web/workers/my_worker.wasm --no-source-maps
dart run wasmforge:copy_bootstrap web/workers
```

This produces `my_worker.wasm` + `my_worker.mjs` (the Dart-generated JS
runtime) and copies `wasmforge_worker_bootstrap.js` next to them. Anything
under your app's `web/` directory ships with `flutter build web`.

**3. Spawn a pool and compute:**

```dart
final pool = WorkerPool(
  workerEntrypoint: Uri.parse('workers/my_worker.wasm'),
  bootstrapUri: Uri.parse('workers/wasmforge_worker_bootstrap.js'),
  size: 4,
);
await pool.ready;
final sum = await pool.compute<List<Object?>, int>('sum', [1, 2, 3]);
```

Tasks queue FIFO, one in-flight task per worker. `maxPendingTasks:` turns the
queue into explicit back-pressure (`WorkerQueueFullException`). Worker-side
failures arrive as `WorkerTaskException` with the remote stack trace; a
crashed worker fails only its in-flight task and the pool keeps going with
the survivors.

**Payloads** may contain `null`, `bool`, `int` (±2^53 − 1 on VM/wasm),
`double`, `String`, typed data, `ByteBuffer`, `SharedBuffer`, plus `List`s
and `Map<String, Object?>`s of those. Pass `transferBuffers: true` to **move**
(zero-copy) every `ArrayBuffer` in the payload instead of cloning — the
source becomes unusable afterwards (on dart2wasm, touching a detached
buffer throws). Workers transfer their results by default
(`runWorker(transferResults: false)` to opt out).

### dart2js fallback

If a target browser lacks WasmGC (`supportsWasmGc == false`), compile the
same entrypoint with dart2js and point the pool at the `.js` — it is spawned
directly as a classic worker, no bootstrap involved:

```sh
dart compile js lib/worker/my_worker.dart -o web/workers/my_worker.js -O2
```

```dart
final entrypoint = supportsWasmGc ? 'workers/my_worker.wasm' : 'workers/my_worker.js';
final pool = WorkerPool(workerEntrypoint: Uri.parse(entrypoint), ...);
```

### Non-web platforms

`WorkerPool` never throws at construction. Provide
`inlineFallback: myRegistry` to run the same tasks in-process (with
structured-clone semantics simulated), or omit it and `compute` fails with a
descriptive `UnsupportedError`.

## SharedBuffer: zero-copy shared memory

```dart
if (SharedBuffer.isSupported) {
  final shared = SharedBuffer.allocate(1 << 20);   // 1 MiB
  shared.asUint8List()[0] = 42;                    // a VIEW, not a copy
  shared.atomicAdd(0, 1);                          // Atomics on slot 0 (Int32)
  await pool.compute('fill', {'buffer': shared});  // shared, not cloned
} else {
  // Not cross-origin isolated: fall back to plain (copied) payloads.
}
```

A `SharedBuffer` anywhere in a task payload arrives in the worker as a view
of the **same memory**. `isSupported`/`tryAllocate` never throw anywhere;
`allocate` throws a documented `StateError` when shared memory is
unavailable.

## SharedArrayBuffer and cross-origin isolation

`SharedArrayBuffer` only exists on pages served with:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

When they are missing, wasmforge **detects and falls back** — `SharedBuffer`
reports unsupported and `WorkerPool` keeps working over `postMessage` +
structured clone. Nothing crashes.

- **Local development:** Flutter's dev server sends these headers by default
  for `flutter run --wasm` (skwasm). For `flutter build web` output, serve
  with any static server that adds the two headers — the example ships one
  (`example/tool/serve.dart`, zero dependencies).
- **Static hosts:** most hosts let you declare headers, e.g. Firebase
  Hosting:

  ```json
  {"hosting": {"headers": [{"source": "**", "headers": [
    {"key": "Cross-Origin-Opener-Policy", "value": "same-origin"},
    {"key": "Cross-Origin-Embedder-Policy", "value": "require-corp"}
  ]}]}}
  ```

- **Reverse proxies / CDNs:** behind Traefik, nginx, or Cloudflare the
  headers must be added **at the edge** (Traefik: a `headers` middleware with
  `customResponseHeaders`; Cloudflare: a Transform Rule / `_headers` file on
  Pages), or they will be stripped/absent even if your origin sends them.
- **Every subresource must cooperate.** Under `require-corp`, cross-origin
  scripts, fonts, images, and XHRs must carry CORS or
  `Cross-Origin-Resource-Policy` headers, or the browser blocks them and the
  page silently loses isolation (wasmforge then reports
  `isCrossOriginIsolated: false` and falls back). `COEP: credentialless` is a
  laxer alternative with narrower browser support.

## Testing your code that uses wasmforge

`package:wasmforge/testing.dart` works on the VM — no browser:

```dart
import 'package:test/test.dart';
import 'package:wasmforge/testing.dart';
import 'package:wasmforge/wasmforge.dart';

void main() {
  tearDown(clearCapabilityOverrides);

  test('my widget falls back when not isolated', () {
    setCapabilityOverridesForTesting(
      const CapabilityOverrides(isWeb: true, crossOriginIsolated: false),
    );
    expect(isCrossOriginIsolated, isFalse);
  });

  test('my task logic, through a fake pool', () async {
    final pool = WorkerPool.custom(
      (_) => FakeWorkerTransport(
        registry: TaskRegistry()..register<int, int>('double', (n) => n * 2),
      ),
    );
    expect(await pool.compute<int, int>('double', 21), 42);
  });
}
```

- `FakeWorkerTransport` — scriptable worker (latency, failures, crashes),
  pass-by-value payload semantics via `simulateStructuredClone`.
- `FakeSharedBuffer` — `SharedBuffer` over plain memory, identical atomic
  semantics, passed by reference through fakes.
- `CapabilityOverrides` — force any capability for a test.
- Browser tests (`dart test -p chrome`): `FakeJsEnvironment` simulates an
  isolated page (real code paths, no COOP/COEP needed) and
  `createJsLoopbackTransport` round-trips payloads through the real JS codec
  and `structuredClone`.

## Example app

[`example/`](example/) blurs a 3840×2160 image on a `WorkerPool` while an fps
meter proves the UI thread stays free, with live timings for the
shared-memory path vs the message-passing fallback (measured here: ~299 ms vs
~497 ms on 4 workers) and an on-screen capability matrix.

```sh
cd example
bash tool/build_worker.sh
flutter run -d chrome --wasm
```

## Browser support

| Need | Requirement |
|---|---|
| run dart2wasm output (app or worker) | WasmGC: Chromium 119+, Firefox 120+, Safari 26+ |
| module workers (the bootstrap) | Chrome 80+, Firefox 114+, Safari 15+ |
| `SharedBuffer` | cross-origin isolation (headers above) |
| everything older | dart2js build + `.js` worker fallback |

## Versioning and scope

v0.1 ships the interop core and the concurrency module. Storage, file/drag &
drop, BroadcastChannel tab messaging, and OAuth/JWT helpers are planned as
additional modules in later minor releases — the conditional-import core is
structured so they slot in without breaking changes.

## License

MIT — see [LICENSE](LICENSE).
