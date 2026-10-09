import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfcraft/features/scanner/processing/geometry.dart';
import 'package:pdfcraft/features/scanner/processing/perspective.dart';

import 'synthetic.dart';

const _cols = 8;
const _rows = 6;

/// Renders an 8x6 checkerboard seen in perspective inside [quad].
Canvas _checkerScene(Quad quad, int w, int h) {
  final toUnit = computeHomography(quad.points, const [
    Point(0.0, 0.0),
    Point(1.0, 0.0),
    Point(1.0, 1.0),
    Point(0.0, 1.0),
  ]);
  final c = Canvas(w, h)..fill(solid(40, 90, 160));
  c.fillPolygon(quad.points, (x, y) {
    final p = applyHomography(toUnit, Point(x + 0.5, y + 0.5));
    final cx = (p.x * _cols).floor().clamp(0, _cols - 1);
    final cy = (p.y * _rows).floor().clamp(0, _rows - 1);
    return (cx + cy).isEven ? (250, 250, 250) : (10, 10, 10);
  });
  return c;
}

void main() {
  final quad = Quad.fromList(const [Point(180.0, 90.0), Point(760.0, 140.0), Point(850.0, 700.0), Point(90.0, 620.0)]);

  test('checkerboard is rectified with the expected cell colors', () {
    final src = _checkerScene(quad, 1000, 800).toImage();
    final out = warpPerspective(src, quad, outWidth: 800, outHeight: 600);
    expect(out.width, 800);
    expect(out.height, 600);
    const cellW = 800 / _cols, cellH = 600 / _rows;
    for (var cy = 0; cy < _rows; cy++) {
      for (var cx = 0; cx < _cols; cx++) {
        final expectWhite = (cx + cy).isEven;
        // Sample a 3x3 patch around the cell centre and near its corners.
        for (final (fx, fy) in [(0.5, 0.5), (0.2, 0.2), (0.8, 0.8), (0.2, 0.8)]) {
          final px = ((cx + fx) * cellW).floor();
          final py = ((cy + fy) * cellH).floor();
          final v = out.getPixel(px, py);
          if (expectWhite) {
            expect(v.r, greaterThan(230), reason: 'cell ($cx,$cy) at ($px,$py)');
          } else {
            expect(v.r, lessThan(30), reason: 'cell ($cx,$cy) at ($px,$py)');
          }
        }
      }
    }
    // Background must not leak in along the borders.
    for (var x = 2; x < 798; x += 13) {
      expect(out.getPixel(x, 1).b - out.getPixel(x, 1).r, lessThan(60));
      expect(out.getPixel(x, 598).b - out.getPixel(x, 598).r, lessThan(60));
    }
  });

  test('default size follows the longest opposite edges', () {
    final src = _checkerScene(quad, 1000, 800).toImage();
    final out = warpPerspective(src, quad);
    final expW = max(quad.tl.distanceTo(quad.tr), quad.bl.distanceTo(quad.br)).round();
    final expH = max(quad.tl.distanceTo(quad.bl), quad.tr.distanceTo(quad.br)).round();
    expect(out.width, expW);
    expect(out.height, expH);
    expect(out.numChannels, 3);
  });

  test('a single requested dimension keeps the aspect ratio', () {
    final src = _checkerScene(quad, 1000, 800).toImage();
    final (natW, natH) = warpOutputSize(quad);
    final out = warpPerspective(src, quad, outWidth: 400);
    expect(out.width, 400);
    expect(out.height, (400 * natH / natW).round());
    final out2 = warpPerspective(src, quad, outHeight: 300);
    expect(out2.height, 300);
    expect(out2.width, (300 * natW / natH).round());
  });

  test('output size is capped at 3000 px', () {
    final big = Quad.fromList(const [Point(0.0, 0.0), Point(6000.0, 0.0), Point(6000.0, 4000.0), Point(0.0, 4000.0)]);
    expect(warpOutputSize(big), (3000, 2000));
    expect(warpOutputSize(Quad.full(1200, 900)), (1200, 900));
  });

  test('full-image quad reproduces the source', () {
    final rnd = Random(3);
    final c = Canvas(64, 48)..fill((_, _) => (rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)));
    final src = c.toImage();
    final out = warpPerspective(src, Quad.full(64, 48));
    expect(out.width, 64);
    expect(out.height, 48);
    expect(out.getBytes(), src.getBytes());
  });

  test('RGBA input keeps its alpha channel', () {
    final src = img.Image(width: 40, height: 30, numChannels: 4);
    img.fill(src, color: img.ColorRgba8(200, 100, 50, 128));
    final out = warpPerspective(src, Quad.full(40, 30), outWidth: 20);
    expect(out.numChannels, 4);
    final p = out.getPixel(10, 7);
    expect([p.r, p.g, p.b, p.a], [200, 100, 50, 128]);
  });
}
