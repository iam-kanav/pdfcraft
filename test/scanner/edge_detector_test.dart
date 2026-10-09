import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfcraft/features/scanner/processing/edge_detector.dart';
import 'package:pdfcraft/features/scanner/processing/geometry.dart';

import 'synthetic.dart';

const _w = 800;
const _h = 600;

/// Asserts that [found] matches [truth] within 3% of the image diagonal.
void expectQuadNear(Quad? found, Quad truth, int w, int h) {
  expect(found, isNotNull, reason: 'no document detected');
  final tol = 0.03 * sqrt(w * w + h * h);
  final err = maxCornerError(found!, truth);
  expect(
    err,
    lessThan(tol),
    reason:
        'corner error ${err.toStringAsFixed(1)} px > '
        '${tol.toStringAsFixed(1)} px\nfound: $found\ntruth: $truth',
  );
}

Canvas _scene(Quad paper, {Shader? background, Shader? paperShade}) {
  final c = Canvas(_w, _h)..fill(background ?? solid(70, 65, 60));
  c.fillPolygon(paper.points, paperShade ?? solid(235, 235, 230));
  return c;
}

void main() {
  group('detectDocumentQuad', () {
    test('axis-aligned white page on dark desk', () {
      final truth = Quad.fromList(const [
        Point(150.0, 100.0),
        Point(650.0, 100.0),
        Point(650.0, 520.0),
        Point(150.0, 520.0),
      ]);
      final c = _scene(truth);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('page rotated by 25 degrees', () {
      final truth = rotatedRect(400, 300, 430, 330, 25);
      final c = _scene(truth);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('page rotated by -15 degrees with text', () {
      final truth = rotatedRect(410, 290, 380, 480, -15);
      final c = _scene(truth);
      drawFakeText(c, truth, Random(3));
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('strong perspective trapezoid', () {
      final truth = Quad.fromList(const [
        Point(270.0, 110.0),
        Point(540.0, 120.0),
        Point(720.0, 540.0),
        Point(80.0, 520.0),
      ]);
      final c = _scene(truth);
      drawFakeText(c, truth, Random(4));
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('noise, uneven lighting and text', () {
      final truth = Quad.fromList(const [
        Point(190.0, 70.0),
        Point(610.0, 105.0),
        Point(640.0, 560.0),
        Point(140.0, 530.0),
      ]);
      final rnd = Random(7);
      final c = _scene(truth, background: solid(95, 85, 75), paperShade: solid(230, 228, 220));
      drawFakeText(c, truth, rnd, lines: 16);
      // Light falls off strongly towards the bottom-right corner.
      c.applyLighting((x, y) => 1.1 - 0.55 * (x / _w + y / _h) / 2);
      c.addNoise(rnd, 14);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('wood-like textured background', () {
      final truth = rotatedRect(395, 305, 360, 450, -18);
      final rnd = Random(11);
      final phase = List.generate(_h, (_) => rnd.nextDouble());
      Rgb wood(int x, int y) {
        final ring = sin(y * 0.22 + 2.5 * sin(x * 0.013) + phase[y] * 0.8);
        final grain = sin(x * 0.9 + y * 0.05) * 0.15;
        final v = 120 + 35 * ring + 20 * grain;
        return ((v * 1.15).round(), (v * 0.85).round(), (v * 0.55).round());
      }

      final c = _scene(truth, background: wood);
      drawFakeText(c, truth, rnd);
      c.addNoise(rnd, 6);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('gray textured background (blotches)', () {
      final truth = rotatedRect(400, 300, 470, 360, 8);
      final rnd = Random(5);
      final c = _scene(
        truth,
        background: (x, y) {
          final v = 105 + 25 * sin(x * 0.05) * cos(y * 0.07) + 15 * sin((x + y) * 0.21);
          return (v.round(), v.round(), v.round());
        },
      );
      drawFakeText(c, truth, rnd);
      c.addNoise(rnd, 10);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('low contrast: paper 200 on background 150', () {
      final truth = rotatedRect(390, 310, 450, 340, 12);
      final c = _scene(truth, background: solid(150), paperShade: solid(200));
      c.addNoise(Random(9), 4);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('page running off the bottom edge of the frame', () {
      // The page extends below the image; the visible part is a quad whose
      // bottom side lies on the image border.
      final page = Quad.fromList(const [
        Point(220.0, 150.0),
        Point(600.0, 160.0),
        Point(620.0, 700.0),
        Point(200.0, 690.0),
      ]);
      final c = _scene(page);
      // Intersections of the left/right sides with y = height.
      double xAt(Point<double> a, Point<double> b, double y) => a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x);
      final truth = Quad.fromList([
        page.tl,
        page.tr,
        Point(xAt(page.tr, page.br, _h.toDouble()), _h.toDouble()),
        Point(xAt(page.tl, page.bl, _h.toDouble()), _h.toDouble()),
      ]);
      expectQuadNear(detectDocumentQuad(c.toImage()), truth, _w, _h);
    });

    test('high resolution input maps back to original coordinates', () {
      const w = 3000, h = 2250;
      final truth = rotatedRect(1500, 1125, 1700, 1300, 20);
      final c = Canvas(w, h)..fill(solid(60, 60, 70));
      c.fillPolygon(truth.points, solid(240));
      final found = detectDocumentQuad(c.toImage());
      expectQuadNear(found, truth, w, h);
      // Accuracy should be far better than the 3% bound.
      expect(maxCornerError(found!, truth), lessThan(0.01 * sqrt(w * w + h * h)));
    });

    test('returns null for pure noise', () {
      final rnd = Random(1);
      final c = Canvas(_w, _h)
        ..fill((_, _) {
          final v = rnd.nextInt(256);
          return (v, v, v);
        });
      expect(detectDocumentQuad(c.toImage()), isNull);
    });

    test('returns null for colored noise and a uniform image', () {
      final rnd = Random(2);
      final noise = Canvas(_w, _h)..fill((_, _) => (rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)));
      expect(detectDocumentQuad(noise.toImage()), isNull);
      final flat = Canvas(_w, _h)..fill(solid(128));
      expect(detectDocumentQuad(flat.toImage()), isNull);
    });

    test('returns null when the paper is too small', () {
      final c = _scene(rotatedRect(400, 300, 160, 120, 10));
      expect(detectDocumentQuad(c.toImage()), isNull);
    });
  });

  group('buildEdgeMap', () {
    test('marks the page outline as edges', () {
      final truth = rotatedRect(200, 150, 220, 160, 0);
      final c = Canvas(400, 300)..fill(solid(60));
      c.fillPolygon(truth.points, solid(230));
      final edges = buildEdgeMap(c.toImage());
      expect(edges.width, 400);
      expect(edges.height, 300);
      expect(edges.numChannels, 1);
      var onBorder = 0, elsewhere = 0;
      for (var y = 0; y < 300; y++) {
        for (var x = 0; x < 400; x++) {
          if (edges.getPixel(x, y).r == 0) continue;
          final nearSide =
              ((x - 90).abs() <= 2 || (x - 310).abs() <= 2) && y >= 68 && y <= 232 ||
              ((y - 70).abs() <= 2 || (y - 230).abs() <= 2) && x >= 88 && x <= 312;
          if (nearSide) {
            onBorder++;
          } else {
            elsewhere++;
          }
        }
      }
      expect(onBorder, greaterThan(600));
      expect(elsewhere, lessThan(onBorder ~/ 20));
    });

    test('uniform image has no edges', () {
      final edges = buildEdgeMap(img.Image(width: 64, height: 48));
      expect(edges.getBytes().every((v) => v == 0), isTrue);
    });
  });
}
