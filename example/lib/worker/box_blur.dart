/// Separable box-blur kernels over RGBA8888 pixel data.
///
/// Pure Dart, O(pixels) via sliding-window sums — runs identically on the
/// main thread and inside workers. Edges are clamped.
library;

import 'dart:typed_data';

/// Horizontal pass: blurs rows `[startRow, endRow)` of [src] into the same
/// rows of [dst]. Other rows of [dst] are untouched.
void boxBlurHorizontalRgba({
  required Uint8List src,
  required Uint8List dst,
  required int width,
  required int height,
  required int startRow,
  required int endRow,
  required int radius,
}) {
  final window = 2 * radius + 1;
  final lastX = width - 1;
  for (var y = startRow; y < endRow; y++) {
    final rowOffset = y * width * 4;
    var sumR = 0, sumG = 0, sumB = 0, sumA = 0;
    for (var cx = -radius; cx <= radius; cx++) {
      final px = rowOffset + cx.clamp(0, lastX) * 4;
      sumR += src[px];
      sumG += src[px + 1];
      sumB += src[px + 2];
      sumA += src[px + 3];
    }
    for (var x = 0; x < width; x++) {
      final out = rowOffset + x * 4;
      dst[out] = sumR ~/ window;
      dst[out + 1] = sumG ~/ window;
      dst[out + 2] = sumB ~/ window;
      dst[out + 3] = sumA ~/ window;
      final removePx = rowOffset + (x - radius).clamp(0, lastX) * 4;
      final addPx = rowOffset + (x + radius + 1).clamp(0, lastX) * 4;
      sumR += src[addPx] - src[removePx];
      sumG += src[addPx + 1] - src[removePx + 1];
      sumB += src[addPx + 2] - src[removePx + 2];
      sumA += src[addPx + 3] - src[removePx + 3];
    }
  }
}

/// Vertical pass: blurs rows `[startRow, endRow)` of [src] into the same
/// rows of [dst], reading up to [radius] rows beyond the band (clamped to the
/// image). Safe for band-parallel use: bands only **write** their own rows.
void boxBlurVerticalRgba({
  required Uint8List src,
  required Uint8List dst,
  required int width,
  required int height,
  required int startRow,
  required int endRow,
  required int radius,
}) {
  final window = 2 * radius + 1;
  final rowBytes = width * 4;
  final lastY = height - 1;
  final sums = Int32List(rowBytes);
  for (var cy = startRow - radius; cy <= startRow + radius; cy++) {
    final rowOffset = cy.clamp(0, lastY) * rowBytes;
    for (var i = 0; i < rowBytes; i++) {
      sums[i] += src[rowOffset + i];
    }
  }
  for (var y = startRow; y < endRow; y++) {
    final rowOffset = y * rowBytes;
    for (var i = 0; i < rowBytes; i++) {
      dst[rowOffset + i] = sums[i] ~/ window;
    }
    final removeOffset = (y - radius).clamp(0, lastY) * rowBytes;
    final addOffset = (y + radius + 1).clamp(0, lastY) * rowBytes;
    for (var i = 0; i < rowBytes; i++) {
      sums[i] += src[addOffset + i] - src[removeOffset + i];
    }
  }
}

/// Copy-mode kernel: runs both passes over a band+halo [slab] and returns
/// the blurred band rows (`[bandStartInSlab, bandStartInSlab + bandRows)`).
///
/// The slab must contain [radius] halo rows on each side of the band except
/// where the band touches the image edge (there the slab edge *is* the image
/// edge, so clamping matches the full-image result exactly).
Uint8List blurBandWithHalo({
  required Uint8List slab,
  required int width,
  required int slabRows,
  required int bandStartInSlab,
  required int bandRows,
  required int radius,
}) {
  final tmp = Uint8List(slab.length);
  boxBlurHorizontalRgba(
    src: slab,
    dst: tmp,
    width: width,
    height: slabRows,
    startRow: 0,
    endRow: slabRows,
    radius: radius,
  );
  final blurred = Uint8List(slab.length);
  boxBlurVerticalRgba(
    src: tmp,
    dst: blurred,
    width: width,
    height: slabRows,
    startRow: bandStartInSlab,
    endRow: bandStartInSlab + bandRows,
    radius: radius,
  );
  final rowBytes = width * 4;
  return Uint8List.view(
    blurred.buffer,
    bandStartInSlab * rowBytes,
    bandRows * rowBytes,
  );
}
