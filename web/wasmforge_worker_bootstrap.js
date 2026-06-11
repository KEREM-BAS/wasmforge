// wasmforge worker bootstrap.
//
// Spawned by wasmforge's WorkerPool as a MODULE worker:
//   new Worker('wasmforge_worker_bootstrap.js?wasm=<url>&mjs=<url>',
//              {type: 'module'})
//
// It dynamically imports the dart2wasm-generated JS runtime (the .mjs file
// emitted next to the .wasm by `dart compile wasm`), compiles + instantiates
// the wasm module, and invokes the Dart main(), which is expected to call
// wasmforge's runWorker() and post a {kind: 'ready'} envelope.
//
// Supports both the modern runtime API (Dart >= ~3.6: compileStreaming ->
// CompiledApp -> InstantiatedApp.invokeMain) and the deprecated legacy
// exports (instantiate/invoke) of older SDKs.

const params = new URL(self.location.href).searchParams;
const wasmParam = params.get('wasm');
const mjsParam = params.get('mjs');

try {
  if (!wasmParam || !mjsParam) {
    throw new Error(
      "missing 'wasm' or 'mjs' query parameter on the bootstrap URL");
  }
  const wasmUrl = new URL(wasmParam, self.location.href);
  const mjsUrl = new URL(mjsParam, self.location.href);

  const runtime = await import(mjsUrl.href);
  if (runtime.compileStreaming !== undefined) {
    // Modern API: CompiledApp -> InstantiatedApp.
    const app = await runtime.compileStreaming(fetch(wasmUrl));
    const instance = await app.instantiate({});
    instance.invokeMain();
  } else if (runtime.instantiate !== undefined) {
    // Legacy API of older SDKs.
    const module = await WebAssembly.compileStreaming(fetch(wasmUrl));
    const instance = await runtime.instantiate(module, {});
    await runtime.invoke(instance);
  } else {
    throw new Error(
      'unrecognized dart2wasm runtime module shape: ' + mjsUrl.href);
  }
  // Dart main() is now running; runWorker() posts {kind: 'ready'}.
} catch (e) {
  self.postMessage({
    kind: 'boot-error',
    errorMessage: String(e),
    errorStack: (e && e.stack) || '',
  });
}
