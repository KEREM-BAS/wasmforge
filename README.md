# wasmforge

WASM-native building blocks for Flutter Web: typed JS interop, capability
detection, and off-main-thread compute via Web Workers + `SharedArrayBuffer`,
with graceful fallbacks everywhere.

> Status: v0.1 under construction. Sections below are filled in as the
> corresponding modules land.

## Why

- Compiles under **dart2wasm** (no `dart:html` anywhere) and runs on the
  skwasm renderer, while remaining compatible with CanvasKit/JS builds.
- Pure Dart core (`package:web` + `dart:js_interop` only) — usable from any
  Flutter Web app and unit-testable off-browser.
- Every browser API sits behind an interface with shipped mocks
  (`package:wasmforge/testing.dart`), so downstream code tests on the VM.

## Quickstart

_To be written (P4)._

## Running compute in a worker

_To be written (P4): worker entrypoint, build step, `WorkerPool` usage._

## SharedArrayBuffer and cross-origin isolation

_To be written (P4): COOP/COEP deployment guide._

## Testing your code that uses wasmforge

_To be written (P4)._

## License

MIT — see [LICENSE](LICENSE).
