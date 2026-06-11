/// Web implementations of capability detection.
///
/// Web-only: reached exclusively through `if (dart.library.js_interop)`
/// conditional imports.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'js_bindings.dart';

/// On the web by definition.
bool detectIsWeb() => true;

/// Reads `globalThis.crossOriginIsolated`; an absent property (older engines,
/// insecure contexts) reports `false` rather than throwing.
bool detectCrossOriginIsolated() => crossOriginIsolated?.toDart ?? false;

/// Minimal wasm module declaring a WasmGC struct type, from the
/// wasm-feature-detect project's `gc` probe. Engines without WasmGC fail to
/// validate it.
const List<int> _gcProbeModule = [
  0x00, 0x61, 0x73, 0x6d, // \0asm magic
  0x01, 0x00, 0x00, 0x00, // version 1
  0x01, 0x05, 0x01, // type section, 5 bytes, 1 entry
  0x5f, 0x01, 0x78, 0x00, // struct type with one i8 field
];

bool? _wasmGcCache;

/// Feature-detects WasmGC support via `WebAssembly.validate`, caching the
/// result. Returns `false` (never throws) when WebAssembly is unavailable or
/// validation itself fails.
bool detectWasmGcSupport() => _wasmGcCache ??= _probeWasmGc();

bool _probeWasmGc() {
  if (webAssemblyNamespace == null) {
    return false;
  }
  try {
    return webAssemblyValidate(Uint8List.fromList(_gcProbeModule).toJS);
  } on Object {
    return false;
  }
}
