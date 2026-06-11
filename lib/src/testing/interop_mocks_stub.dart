/// Non-web stubs of the JS-interop testing helpers.
///
/// Default branch of the conditional export in
/// `package:wasmforge/testing.dart`: same names and signatures as the web
/// versions, but the bodies explain that these helpers need a browser. On the
/// VM, use `CapabilityOverrides`, `FakeSharedBuffer`, and
/// `FakeWorkerTransport` instead.
library;

import '../concurrency/message_protocol.dart';

/// Web-only fake JS environment; on non-web platforms every method throws
/// [UnsupportedError] with guidance.
///
/// On the web (under `dart test -p chrome`) this installs capability
/// overrides plus a fake `SharedArrayBuffer` allocator so the real web code
/// paths run without cross-origin isolation.
class FakeJsEnvironment {
  /// Describes the environment to simulate.
  FakeJsEnvironment({
    this.crossOriginIsolated = false,
    this.sharedArrayBuffer = false,
    this.wasmGc = false,
  });

  /// Simulated `crossOriginIsolated` value.
  final bool crossOriginIsolated;

  /// Whether `SharedBuffer` allocation should work.
  final bool sharedArrayBuffer;

  /// Simulated WasmGC support.
  final bool wasmGc;

  /// Web-only; throws [UnsupportedError] here.
  void install() => throw UnsupportedError(
        'FakeJsEnvironment is web-only (dart test -p chrome). In VM tests use '
        'setCapabilityOverridesForTesting and FakeSharedBuffer from '
        'package:wasmforge/testing.dart instead.',
      );

  /// Web-only; throws [UnsupportedError] here.
  void uninstall() => throw UnsupportedError(
        'FakeJsEnvironment is web-only (dart test -p chrome).',
      );
}

/// Web-only loopback transport; throws [UnsupportedError] here.
///
/// On the web it round-trips every payload through the real JS codec and
/// `structuredClone`, executing tasks from [registry] in-page. In VM tests
/// use `FakeWorkerTransport` instead.
WorkerTransport createJsLoopbackTransport(TaskRegistry registry) =>
    throw UnsupportedError(
      'createJsLoopbackTransport is web-only (dart test -p chrome). In VM '
      'tests use FakeWorkerTransport from package:wasmforge/testing.dart.',
    );
