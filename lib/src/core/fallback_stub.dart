/// Non-web implementations of every conditionally-imported symbol.
///
/// This is the **default** branch of all `if (dart.library.js_interop)`
/// conditional imports/exports in the package, so it must stay free of any
/// web-only types and must never throw from capability/detection paths —
/// off-web callers get graceful degradation, not crashes.
library;

/// Not on the web.
bool detectIsWeb() => false;

/// Cross-origin isolation is a web concept; `false` everywhere else.
bool detectCrossOriginIsolated() => false;

/// WasmGC support is a web concept; `false` everywhere else.
bool detectWasmGcSupport() => false;
