/// Procedural test image: a colorful plasma with crisp shapes so the blur is
/// clearly visible. Pure Dart.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Generates a `width`×`height` RGBA8888 plasma image with hard-edged
/// circles (cheap: precomputed axis waves, O(pixels) combine).
Uint8List generatePlasmaRgba(int width, int height) {
  final pixels = Uint8List(width * height * 4);
  final colA = Float64List(width);
  final colB = Float64List(width);
  final rowA = Float64List(height);
  final rowB = Float64List(height);
  for (var x = 0; x < width; x++) {
    colA[x] = math.sin(x * 0.011);
    colB[x] = math.sin(x * 0.0033 + 1.7);
  }
  for (var y = 0; y < height; y++) {
    rowA[y] = math.sin(y * 0.013 + 0.6);
    rowB[y] = math.cos(y * 0.0041);
  }
  var i = 0;
  for (var y = 0; y < height; y++) {
    final ra = rowA[y];
    final rb = rowB[y];
    for (var x = 0; x < width; x++) {
      final v = colA[x] + ra + (colB[x] * rb);
      pixels[i] = (128 + 90 * v).clamp(0, 255).toInt();
      pixels[i + 1] = (128 + 90 * colB[x] * ra).clamp(0, 255).toInt();
      pixels[i + 2] = (128 - 90 * v * rb).clamp(0, 255).toInt();
      pixels[i + 3] = 255;
      i += 4;
    }
  }
  _stampCircles(pixels, width, height);
  return pixels;
}

void _stampCircles(Uint8List pixels, int width, int height) {
  final circles = <(double, double, double, int, int, int)>[
    (0.25, 0.30, 0.12, 255, 255, 255),
    (0.70, 0.25, 0.09, 10, 10, 10),
    (0.55, 0.65, 0.16, 255, 210, 40),
    (0.18, 0.75, 0.08, 40, 220, 255),
    (0.85, 0.70, 0.11, 255, 60, 120),
  ];
  for (final (cxF, cyF, rF, r, g, b) in circles) {
    final cx = (cxF * width).round();
    final cy = (cyF * height).round();
    final radius = (rF * height).round();
    final r2 = radius * radius;
    final yStart = (cy - radius).clamp(0, height - 1);
    final yEnd = (cy + radius).clamp(0, height - 1);
    for (var y = yStart; y <= yEnd; y++) {
      final dy = y - cy;
      final span = math.sqrt(math.max(0, r2 - dy * dy)).floor();
      final xStart = (cx - span).clamp(0, width - 1);
      final xEnd = (cx + span).clamp(0, width - 1);
      var p = (y * width + xStart) * 4;
      for (var x = xStart; x <= xEnd; x++) {
        pixels[p] = r;
        pixels[p + 1] = g;
        pixels[p + 2] = b;
        p += 4;
      }
    }
  }
}
