/// Worker entrypoint for the blur demo — compiled separately from the app:
///
///   dart compile wasm lib/worker/blur_worker_main.dart \
///       -o web/workers/blur_worker.wasm --no-source-maps
///
/// (See `tool/build_worker.sh`.) This file must stay free of Flutter imports:
/// it runs inside a plain Web Worker.
library;

import 'dart:typed_data';

import 'package:wasmforge/wasmforge.dart';

import 'blur_protocol.dart';
import 'box_blur.dart';

void main() {
  runWorker(buildBlurRegistry());
}

/// The blur task handlers; also usable as a `WorkerPool.inlineFallback` so
/// the same registry serves non-web targets.
TaskRegistry buildBlurRegistry() => TaskRegistry()
  ..register<Map<String, Object?>, Object?>(blurHorizontalTask, _blurH)
  ..register<Map<String, Object?>, Object?>(blurVerticalTask, _blurV)
  ..register<Map<String, Object?>, Uint8List>(blurBandCopyTask, _blurBandCopy);

Object? _blurH(Map<String, Object?> payload) {
  boxBlurHorizontalRgba(
    src: (payload[keySrc]! as SharedBuffer).asUint8List(),
    dst: (payload[keyDst]! as SharedBuffer).asUint8List(),
    width: payload[keyWidth]! as int,
    height: payload[keyHeight]! as int,
    startRow: payload[keyStartRow]! as int,
    endRow: payload[keyEndRow]! as int,
    radius: payload[keyRadius]! as int,
  );
  (payload[keyProgress] as SharedBuffer?)?.atomicAdd(0, 1);
  return null;
}

Object? _blurV(Map<String, Object?> payload) {
  boxBlurVerticalRgba(
    src: (payload[keySrc]! as SharedBuffer).asUint8List(),
    dst: (payload[keyDst]! as SharedBuffer).asUint8List(),
    width: payload[keyWidth]! as int,
    height: payload[keyHeight]! as int,
    startRow: payload[keyStartRow]! as int,
    endRow: payload[keyEndRow]! as int,
    radius: payload[keyRadius]! as int,
  );
  (payload[keyProgress] as SharedBuffer?)?.atomicAdd(0, 1);
  return null;
}

Uint8List _blurBandCopy(Map<String, Object?> payload) => blurBandWithHalo(
  slab: payload[keySlab]! as Uint8List,
  width: payload[keyWidth]! as int,
  slabRows: payload[keySlabRows]! as int,
  bandStartInSlab: payload[keyBandStartInSlab]! as int,
  bandRows: payload[keyBandRows]! as int,
  radius: payload[keyRadius]! as int,
);
