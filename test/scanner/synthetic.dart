// Synthetic test-scene generation for the scanner processing tests.
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfcraft/features/scanner/processing/geometry.dart';

/// RGB color triple.
typedef Rgb = (int, int, int);

/// Per-pixel color function.
typedef Shader = Rgb Function(int x, int y);

/// A mutable RGB canvas backed by a raw byte buffer.
class Canvas {
  Canvas(this.width, this.height) : data = Uint8List(width * height * 3);

  final int width;
  final int height;
  final Uint8List data;

  void set(int x, int y, Rgb c) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = (y * width + x) * 3;
    data[i] = c.$1.clamp(0, 255);
    data[i + 1] = c.$2.clamp(0, 255);
    data[i + 2] = c.$3.clamp(0, 255);
  }

  Rgb get(int x, int y) {
    final i = (y * width + x) * 3;
    return (data[i], data[i + 1], data[i + 2]);
  }

  void fill(Shader shader) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        set(x, y, shader(x, y));
      }
    }
  }

  /// Scanline fill of a simple polygon (pixel centres inside are painted).
  void fillPolygon(List<Point<double>> poly, Shader shader) {
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in poly) {
      minY = min(minY, p.y);
      maxY = max(maxY, p.y);
    }
    final y0 = max(0, minY.floor());
    final y1 = min(height - 1, maxY.ceil());
    for (var y = y0; y <= y1; y++) {
      final yc = y + 0.5;
      final xs = <double>[];
      for (var i = 0; i < poly.length; i++) {
        final a = poly[i], b = poly[(i + 1) % poly.length];
        if ((a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc)) {
          xs.add(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x));
        }
      }
      xs.sort();
      for (var k = 0; k + 1 < xs.length; k += 2) {
        final xa = max(0, (xs[k] - 0.5).ceil());
        final xb = min(width - 1, (xs[k + 1] - 0.5).floor());
        for (var x = xa; x <= xb; x++) {
          set(x, y, shader(x, y));
        }
      }
    }
  }

  /// Darkens a thick line segment (used for "text" strokes).
  void stroke(Point<double> a, Point<double> b, double thickness, Rgb c) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final len = sqrt(dx * dx + dy * dy);
    final nx = -dy / len * thickness / 2, ny = dx / len * thickness / 2;
    fillPolygon([
      Point(a.x + nx, a.y + ny),
      Point(b.x + nx, b.y + ny),
      Point(b.x - nx, b.y - ny),
      Point(a.x - nx, a.y - ny),
    ], (_, _) => c);
  }

  /// Adds zero-mean Gaussian noise with standard deviation [sigma].
  void addNoise(Random rnd, double sigma) {
    for (var i = 0; i < data.length; i++) {
      final u1 = max(1e-12, rnd.nextDouble()), u2 = rnd.nextDouble();
      final n = sqrt(-2 * log(u1)) * cos(2 * pi * u2) * sigma;
      data[i] = (data[i] + n).round().clamp(0, 255);
    }
  }

  /// Multiplies every pixel by `gain(x, y)`.
  void applyLighting(double Function(int x, int y) gain) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final g = gain(x, y);
        final i = (y * width + x) * 3;
        for (var c = 0; c < 3; c++) {
          data[i + c] = (data[i + c] * g).round().clamp(0, 255);
        }
      }
    }
  }

  img.Image toImage() => img.Image.fromBytes(width: width, height: height, bytes: data.buffer, numChannels: 3);
}

/// Solid color shader.
Shader solid(int v, [int? g, int? b]) {
  final c = (v, g ?? v, b ?? v);
  return (_, _) => c;
}

/// Rectangle of size [w] x [h] centred at ([cx], [cy]) rotated by [deg]
/// degrees, as a quad in tl, tr, br, bl order.
Quad rotatedRect(double cx, double cy, double w, double h, double deg) {
  final a = deg * pi / 180;
  final ca = cos(a), sa = sin(a);
  Point<double> p(double x, double y) => Point(cx + x * ca - y * sa, cy + x * sa + y * ca);
  return Quad.orderPoints([p(-w / 2, -h / 2), p(w / 2, -h / 2), p(w / 2, h / 2), p(-w / 2, h / 2)]);
}

/// Draws a few lines of fake text inside [paper] (in the paper's own
/// coordinate frame, mapped through a homography).
void drawFakeText(Canvas c, Quad paper, Random rnd, {int lines = 12, Rgb color = (30, 30, 40), double thickness = 3}) {
  final h = computeHomography([
    const Point(0.0, 0.0),
    const Point(1.0, 0.0),
    const Point(1.0, 1.0),
    const Point(0.0, 1.0),
  ], paper.points);
  for (var i = 0; i < lines; i++) {
    final v = 0.12 + 0.76 * i / max(1, lines - 1);
    var u = 0.1;
    while (u < 0.88) {
      final wordLen = 0.04 + rnd.nextDouble() * 0.12;
      final end = min(0.9, u + wordLen);
      c.stroke(applyHomography(h, Point(u, v)), applyHomography(h, Point(end, v)), thickness, color);
      u = end + 0.025;
    }
  }
}

/// Largest distance between corresponding corners of [a] and [b].
double maxCornerError(Quad a, Quad b) {
  var m = 0.0;
  for (var i = 0; i < 4; i++) {
    m = max(m, a.points[i].distanceTo(b.points[i]));
  }
  return m;
}
