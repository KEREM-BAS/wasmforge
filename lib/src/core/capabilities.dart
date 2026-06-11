/// Capability detection with graceful non-web fallback.
///
/// All getters are safe to call on every platform and never throw: off the
/// web (or when a feature is missing) they simply report `false`.
library;

import 'fallback_stub.dart' if (dart.library.js_interop) 'capabilities_web.dart'
    as impl;

/// Test-only overrides consulted before real platform detection.
///
/// Install via [setCapabilityOverridesForTesting] (re-exported by
/// `package:wasmforge/testing.dart`); `null` fields defer to real detection.
class CapabilityOverrides {
  /// Creates a set of overrides; any field left `null` keeps real detection.
  const CapabilityOverrides({
    this.isWeb,
    this.crossOriginIsolated,
    this.wasmGc,
  });

  /// Forced value for [isWeb], or `null` to detect.
  final bool? isWeb;

  /// Forced value for [isCrossOriginIsolated], or `null` to detect.
  final bool? crossOriginIsolated;

  /// Forced value for [supportsWasmGc], or `null` to detect.
  final bool? wasmGc;
}

CapabilityOverrides? _overrides;

/// Installs capability [overrides] for tests; pass `null` to remove them.
///
/// Not exported by the main library — import
/// `package:wasmforge/testing.dart` to use it.
void setCapabilityOverridesForTesting(CapabilityOverrides? overrides) {
  _overrides = overrides;
}

/// Removes any overrides installed by [setCapabilityOverridesForTesting].
void clearCapabilityOverrides() => _overrides = null;

/// Whether the program is running on the web (compiled by dart2js or
/// dart2wasm). `false` on the Dart VM and all non-web platforms.
bool get isWeb => _overrides?.isWeb ?? impl.detectIsWeb();

/// Whether the current context is cross-origin isolated, i.e. whether
/// `SharedArrayBuffer` is usable.
///
/// Requires the host to serve COOP/COEP headers — see the README section
/// "SharedArrayBuffer and cross-origin isolation". Always `false` off the
/// web; never throws.
bool get isCrossOriginIsolated =>
    _overrides?.crossOriginIsolated ?? impl.detectCrossOriginIsolated();

/// Whether the JavaScript engine supports WasmGC (required to run dart2wasm
/// output), feature-detected via `WebAssembly.validate`.
///
/// Always `false` off the web; never throws.
bool get supportsWasmGc => _overrides?.wasmGc ?? impl.detectWasmGcSupport();

/// An immutable snapshot of all detected capabilities, handy for logging or
/// rendering a diagnostics view.
class CapabilityMatrix {
  /// Creates a snapshot with explicit values.
  const CapabilityMatrix({
    required this.isWeb,
    required this.isCrossOriginIsolated,
    required this.supportsWasmGc,
  });

  /// Snapshot of the top-level `isWeb` getter.
  final bool isWeb;

  /// Snapshot of the top-level `isCrossOriginIsolated` getter.
  final bool isCrossOriginIsolated;

  /// Snapshot of the top-level `supportsWasmGc` getter.
  final bool supportsWasmGc;

  @override
  String toString() => 'CapabilityMatrix(isWeb: $isWeb, '
      'isCrossOriginIsolated: $isCrossOriginIsolated, '
      'supportsWasmGc: $supportsWasmGc)';
}

/// Detects the current [CapabilityMatrix] (honoring any test overrides).
CapabilityMatrix detectCapabilityMatrix() => CapabilityMatrix(
      isWeb: isWeb,
      isCrossOriginIsolated: isCrossOriginIsolated,
      supportsWasmGc: supportsWasmGc,
    );
