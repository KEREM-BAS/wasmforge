/// WASM-native building blocks for Flutter Web with graceful fallback to
/// JavaScript builds and non-web platforms.
///
/// The core is pure Dart (`package:web` + `dart:js_interop` only), compiles
/// under dart2wasm, and degrades gracefully everywhere else: importing this
/// library never throws off the web.
library;

/// The version of the wasmforge package, kept in sync with `pubspec.yaml`.
const String wasmforgeVersion = '0.1.0';
