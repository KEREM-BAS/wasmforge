/// WASM-native building blocks for Flutter Web with graceful fallback to
/// JavaScript builds and non-web platforms.
///
/// The core is pure Dart (`package:web` + `dart:js_interop` only), compiles
/// under dart2wasm, and degrades gracefully everywhere else: importing this
/// library never throws off the web, and every capability getter simply
/// reports `false` where a feature is unavailable.
library;

export 'src/concurrency/message_protocol.dart'
    show
        Envelope,
        EnvelopeKind,
        TaskHandler,
        TaskRegistry,
        UnknownTaskException,
        WorkerPoolDisposedException,
        WorkerQueueFullException,
        WorkerSpawnException,
        WorkerTaskException,
        WorkerTransport,
        WorkerTransportFactory,
        assertEncodablePayload,
        collectTransferableBuffers,
        maxSafePayloadInteger,
        protocolVersion;
export 'src/concurrency/shared_buffer.dart' show SharedBuffer;
export 'src/core/capabilities.dart'
    show
        CapabilityMatrix,
        detectCapabilityMatrix,
        isCrossOriginIsolated,
        isWeb,
        supportsWasmGc;

/// The version of the wasmforge package, kept in sync with `pubspec.yaml`.
const String wasmforgeVersion = '0.1.0';
