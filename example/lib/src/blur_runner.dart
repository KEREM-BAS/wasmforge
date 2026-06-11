/// Orchestrates the 4K blur across the [WorkerPool] in three modes:
/// shared-memory (SAB), message-passing (copy + transfer), and blocking
/// main-thread. Pure Dart — no Flutter imports.
library;

import 'dart:typed_data';

import 'package:wasmforge/wasmforge.dart';

import '../worker/blur_protocol.dart';
import '../worker/box_blur.dart';

/// A finished blur run.
typedef BlurResult = ({Uint8List pixels, Duration elapsed});

/// Drives the worker pool for the demo image.
class BlurRunner {
  /// Creates a runner for a `width`×`height` RGBA image.
  BlurRunner({
    required this.width,
    required this.height,
    this.radius = 8,
    this.bands = 16,
    this.poolSize = 4,
  });

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Box-blur radius.
  final int radius;

  /// Number of row bands (= tasks per pass).
  final int bands;

  /// Worker count.
  final int poolSize;

  WorkerPool? _pool;
  SharedBuffer? _progress;
  int _copyProgress = 0;

  /// Live workers in the pool (0 before [ensurePool]).
  int get liveWorkers => _pool?.size ?? 0;

  /// Completed band-passes of the current run (SAB mode reads the shared
  /// atomic counter that workers increment — a live Atomics demo).
  int get progressCount => _progress?.atomicLoad(0) ?? _copyProgress;

  /// Total band-passes in a full run (two passes over [bands] bands).
  int get totalSteps => bands * 2;

  /// Spawns the pool (idempotent) and completes when it is ready.
  Future<void> ensurePool() {
    final pool = _pool ??= WorkerPool(
      workerEntrypoint: Uri.parse('workers/blur_worker.wasm'),
      bootstrapUri: Uri.parse('workers/wasmforge_worker_bootstrap.js'),
      size: poolSize,
    );
    return pool.ready;
  }

  /// Shared-memory mode: pixels live in [SharedBuffer]s; workers blur row
  /// bands in place with **zero pixel copying** across the worker boundary.
  /// `Future.wait` is the barrier between the two passes.
  Future<BlurResult> runSharedMemory(Uint8List pixels) async {
    await ensurePool();
    final pool = _pool!;
    final src = SharedBuffer.allocate(pixels.length);
    final tmp = SharedBuffer.allocate(pixels.length);
    final out = SharedBuffer.allocate(pixels.length);
    final progress = SharedBuffer.allocate(64);
    _progress = progress;
    src.asUint8List().setAll(0, pixels);

    final stopwatch = Stopwatch()..start();
    await Future.wait(<Future<Object?>>[
      for (final (startRow, endRow) in _bandRanges())
        pool.compute<Map<String, Object?>, Object?>(
          blurHorizontalTask,
          <String, Object?>{
            keySrc: src,
            keyDst: tmp,
            keyWidth: width,
            keyHeight: height,
            keyStartRow: startRow,
            keyEndRow: endRow,
            keyRadius: radius,
            keyProgress: progress,
          },
        ),
    ]);
    await Future.wait(<Future<Object?>>[
      for (final (startRow, endRow) in _bandRanges())
        pool.compute<Map<String, Object?>, Object?>(
          blurVerticalTask,
          <String, Object?>{
            keySrc: tmp,
            keyDst: out,
            keyWidth: width,
            keyHeight: height,
            keyStartRow: startRow,
            keyEndRow: endRow,
            keyRadius: radius,
            keyProgress: progress,
          },
        ),
    ]);
    stopwatch.stop();
    // One copy out of shared memory so the image decoder gets plain bytes.
    final result = Uint8List.fromList(out.asUint8List());
    _progress = null;
    return (pixels: result, elapsed: stopwatch.elapsed);
  }

  /// Message-passing mode: each band+halo is **copied** into a fresh slab,
  /// transferred to a worker, blurred there, and the band transferred back.
  /// The timing difference vs [runSharedMemory] is the demo's point.
  Future<BlurResult> runCopy(Uint8List pixels) async {
    await ensurePool();
    final pool = _pool!;
    _progress = null;
    _copyProgress = 0;
    final rowBytes = width * 4;
    final out = Uint8List(pixels.length);

    final stopwatch = Stopwatch()..start();
    await Future.wait(<Future<void>>[
      for (final (startRow, endRow) in _bandRanges())
        () {
          final slabStart = (startRow - radius).clamp(0, height);
          final slabEnd = (endRow + radius).clamp(0, height);
          final slabRows = slabEnd - slabStart;
          // A real copy: the slab is then moved (transferred), so it must
          // not alias the source image.
          final slab = Uint8List.fromList(
            Uint8List.view(
              pixels.buffer,
              pixels.offsetInBytes + slabStart * rowBytes,
              slabRows * rowBytes,
            ),
          );
          return pool
              .compute<Map<String, Object?>, Uint8List>(
                blurBandCopyTask,
                <String, Object?>{
                  keySlab: slab,
                  keyWidth: width,
                  keySlabRows: slabRows,
                  keyBandStartInSlab: startRow - slabStart,
                  keyBandRows: endRow - startRow,
                  keyRadius: radius,
                },
                transferBuffers: true,
              )
              .then((band) {
                out.setRange(startRow * rowBytes, endRow * rowBytes, band);
                _copyProgress += 2; // counts as both passes of the band
              });
        }(),
    ]);
    stopwatch.stop();
    return (pixels: out, elapsed: stopwatch.elapsed);
  }

  /// Blocking mode: the same kernel inline on the UI thread — watch the fps
  /// meter stall.
  BlurResult runMainThread(Uint8List pixels) {
    final tmp = Uint8List(pixels.length);
    final out = Uint8List(pixels.length);
    final stopwatch = Stopwatch()..start();
    boxBlurHorizontalRgba(
      src: pixels,
      dst: tmp,
      width: width,
      height: height,
      startRow: 0,
      endRow: height,
      radius: radius,
    );
    boxBlurVerticalRgba(
      src: tmp,
      dst: out,
      width: width,
      height: height,
      startRow: 0,
      endRow: height,
      radius: radius,
    );
    stopwatch.stop();
    return (pixels: out, elapsed: stopwatch.elapsed);
  }

  Iterable<(int, int)> _bandRanges() sync* {
    final bandHeight = (height / bands).ceil();
    for (var start = 0; start < height; start += bandHeight) {
      final end = (start + bandHeight).clamp(0, height);
      yield (start, end);
    }
  }

  /// Tears down the pool.
  Future<void> dispose() async {
    await _pool?.dispose();
    _pool = null;
  }
}
