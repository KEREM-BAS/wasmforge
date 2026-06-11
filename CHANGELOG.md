# Changelog

## 0.1.0

Initial release.

- Core interop layer: typed `package:web` / `dart:js_interop` access,
  capability detection (`isWeb`, `isCrossOriginIsolated`, `supportsWasmGc`),
  and conditional-import fallbacks so the package is importable everywhere.
- Concurrency module: `WorkerPool` for off-main-thread compute in Web Workers
  (dart2wasm worker entrypoints, with a dart2js fallback path) and
  `SharedBuffer` over `SharedArrayBuffer` + `Atomics`, capability-gated with
  automatic message-passing fallback when cross-origin isolation is
  unavailable.
- Public testing toolkit (`package:wasmforge/testing.dart`): pure-Dart fakes
  usable in VM unit tests plus JS-interop mocks for browser tests.
