/// Testing toolkit for code that uses wasmforge.
///
/// Everything here works **without a browser** except the two JS-interop
/// helpers ([FakeJsEnvironment], [createJsLoopbackTransport]), which are real
/// only under a web compiler (`dart test -p chrome`) and throw
/// [UnsupportedError] with guidance elsewhere.
///
/// Typical VM unit test:
///
/// ```dart
/// import 'package:test/test.dart';
/// import 'package:wasmforge/testing.dart';
///
/// void main() {
///   tearDown(clearCapabilityOverrides);
///
///   test('my code falls back when not isolated', () {
///     setCapabilityOverridesForTesting(
///       const CapabilityOverrides(crossOriginIsolated: false),
///     );
///     // exercise code that checks isCrossOriginIsolated ...
///   });
/// }
/// ```
library;

export 'src/concurrency/message_protocol.dart' show simulateStructuredClone;
export 'src/core/capabilities.dart'
    show
        CapabilityOverrides,
        clearCapabilityOverrides,
        setCapabilityOverridesForTesting;
export 'src/testing/interop_mocks_stub.dart'
    if (dart.library.js_interop) 'src/testing/interop_mocks_web.dart'
    show FakeJsEnvironment, createJsLoopbackTransport;
export 'src/testing/mocks.dart' show FakeSharedBuffer, FakeWorkerTransport;
