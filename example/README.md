# wasmforge example — 4K box blur off the UI thread

A Flutter Web app that blurs a 3840×2160 RGBA image on a `WorkerPool` while a
fps meter proves the UI thread stays at full frame rate, with a timing
comparison between:

- **shared memory** — pixels live in `SharedBuffer`s (`SharedArrayBuffer`),
  workers blur row bands in place, zero pixel copying, progress reported via
  `Atomics`;
- **message passing** — each band is copied and transferred per task (the
  fallback wasmforge uses automatically when the page is not cross-origin
  isolated);
- **main thread** — the same kernel inline, freezing the UI (for contrast).

## Run it

```sh
# 1. Compile the worker entrypoint + stage the bootstrap (once per change
#    to lib/worker/):
bash tool/build_worker.sh

# 2. Dev loop — Flutter's dev server is cross-origin isolated by default
#    for --wasm, so the shared-memory path is live:
flutter run -d chrome --wasm

# 3. Release build + serving with COOP/COEP headers:
flutter build web --wasm
dart run tool/serve.dart build/web 8080
```

If the capability card shows `isCrossOriginIsolated: false`, the host is not
sending the COOP/COEP headers — the shared-memory button disables itself and
the message-passing path still works. See the wasmforge README for the
deployment guide.
