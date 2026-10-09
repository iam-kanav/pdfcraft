import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfcraft/features/scanner/processing/filters.dart';
import 'package:pdfcraft/features/scanner/processing/geometry.dart';

import 'synthetic.dart';

/// A synthetic page plus a mask of where ink was drawn.
class _Page {
  _Page(this.canvas, this.ink);
  final Canvas canvas;
  final Uint8List ink; // 1 = ink pixel
}

_Page _makePage(
  int w,
  int h, {
  required Rgb paper,
  required List<Rgb> inks,
  required double Function(int x, int y) lighting,
  double noise = 3,
  int seed = 1,
}) {
  final page = Quad.full(w, h);
  final canvas = Canvas(w, h)..fill(solid(paper.$1, paper.$2, paper.$3));
  final mask = Canvas(w, h);
  for (var i = 0; i < inks.length; i++) {
    // Same layout in the page and in the mask.
    final band = Quad.fromList([
      Point(0.0, h * i / inks.length),
      Point(w.toDouble(), h * i / inks.length),
      Point(w.toDouble(), h * (i + 1) / inks.length),
      Point(0.0, h * (i + 1) / inks.length),
    ]);
    drawFakeText(canvas, band, Random(seed + i), lines: 10, color: inks[i], thickness: 4);
    drawFakeText(mask, band, Random(seed + i), lines: 10, color: (255, 255, 255), thickness: 4);
  }
  expect(page.area, w * h);
  canvas.applyLighting(lighting);
  canvas.addNoise(Random(seed), noise);
  final ink = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    ink[i] = mask.data[i * 3] > 127 ? 1 : 0;
  }
  return _Page(canvas, ink);
}

/// Pixels farther than [r] px from any ink (Chebyshev distance).
Uint8List _farFromInk(Uint8List ink, int w, int h, int r) {
  final near = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (ink[y * w + x] == 0) continue;
      for (var dy = -r; dy <= r; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -r; dx <= r; dx++) {
          final xx = x + dx;
          if (xx >= 0 && xx < w) near[yy * w + xx] = 1;
        }
      }
    }
  }
  return Uint8List.fromList([for (final v in near) v == 0 ? 1 : 0]);
}

/// Ink pixels whose 4-neighbourhood is entirely ink (stroke cores).
Uint8List _inkCore(Uint8List ink, int w, int h) {
  final core = Uint8List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      if (ink[i] == 1 && ink[i - 1] == 1 && ink[i + 1] == 1 && ink[i - w] == 1 && ink[i + w] == 1) {
        core[i] = 1;
      }
    }
  }
  return core;
}

double _lumaMean(img.Image im) {
  final b = im.getBytes();
  var s = 0.0;
  for (var i = 0; i < b.length; i += 3) {
    s += 0.299 * b[i] + 0.587 * b[i + 1] + 0.114 * b[i + 2];
  }
  return s / (b.length / 3);
}

double _lumaStd(img.Image im) {
  final b = im.getBytes();
  final m = _lumaMean(im);
  var s = 0.0;
  for (var i = 0; i < b.length; i += 3) {
    final l = 0.299 * b[i] + 0.587 * b[i + 1] + 0.114 * b[i + 2];
    s += (l - m) * (l - m);
  }
  return sqrt(s / (b.length / 3));
}

void main() {
  test('labels', () {
    expect(ScanFilter.values.map((f) => f.label).toList(), [
      'Original',
      'Auto color',
      'Grayscale',
      'Black & white',
      'Whiteboard',
      'Photo',
    ]);
    expect(ScanFilter.fromName('blackWhite'), ScanFilter.blackWhite);
    expect(ScanFilter.fromName('bogus'), ScanFilter.original);
  });

  group('blackWhite', () {
    test('unevenly lit page becomes black ink on pure white', () {
      const w = 900, h = 1200;
      final page = _makePage(
        w,
        h,
        paper: (232, 228, 215),
        inks: [(35, 35, 45), (60, 40, 120)],
        // Strong falloff: corner at ~45% brightness, plus a soft shadow.
        lighting: (x, y) => 1.05 - 0.6 * (x / w * 0.5 + y / h * 0.5) - (x < w * 0.3 ? 0.12 : 0.0),
      );
      final out = applyScanFilter(page.canvas.toImage(), ScanFilter.blackWhite);
      expect(out.width, w);
      expect(out.height, h);
      final bytes = out.getBytes();
      final bg = _farFromInk(page.ink, w, h, 3);
      final core = _inkCore(page.ink, w, h);
      var bgTotal = 0, bgWhite = 0, coreTotal = 0, coreBlack = 0;
      for (var i = 0; i < w * h; i++) {
        final v = bytes[i * 3];
        expect(v == 0 || v == 255, isTrue);
        if (bg[i] == 1) {
          bgTotal++;
          if (v == 255) bgWhite++;
        }
        if (core[i] == 1) {
          coreTotal++;
          if (v == 0) coreBlack++;
        }
      }
      expect(bgWhite / bgTotal, greaterThan(0.95), reason: 'background white ratio ${bgWhite / bgTotal}');
      expect(coreBlack / coreTotal, greaterThan(0.9), reason: 'ink black ratio ${coreBlack / coreTotal}');
    });

    test('brightness lightens the binarised result', () {
      const w = 300, h = 400;
      final page = _makePage(w, h, paper: (220, 220, 220), inks: [(90, 90, 90)], lighting: (x, y) => 1.0);
      final dark = applyScanFilter(page.canvas.toImage(), ScanFilter.blackWhite, brightness: -0.4);
      final light = applyScanFilter(page.canvas.toImage(), ScanFilter.blackWhite, brightness: 0.6);
      expect(_lumaMean(light), greaterThanOrEqualTo(_lumaMean(dark)));
    });
  });

  test('whiteboard flattens a gradient background and keeps ink colors', () {
    const w = 800, h = 600;
    final page = _makePage(
      w,
      h,
      paper: (225, 230, 228),
      inks: [(200, 30, 30), (30, 60, 190)],
      lighting: (x, y) => 0.5 + 0.5 * x / w,
      seed: 5,
    );
    final input = page.canvas.toImage();
    final out = applyScanFilter(input, ScanFilter.whiteboard);
    final bytes = out.getBytes();
    final bg = _farFromInk(page.ink, w, h, 4);
    final core = _inkCore(page.ink, w, h);
    var bgTotal = 0, bgBright = 0;
    var redSum = 0.0, redCount = 0, blueSum = 0.0, blueCount = 0;
    for (var i = 0; i < w * h; i++) {
      final r = bytes[i * 3], g = bytes[i * 3 + 1], b = bytes[i * 3 + 2];
      if (bg[i] == 1) {
        bgTotal++;
        if (r >= 240 && g >= 240 && b >= 240) bgBright++;
      }
      if (core[i] == 1) {
        if (i ~/ w < h ~/ 2) {
          redSum += r - g;
          redCount++;
        } else {
          blueSum += b - r;
          blueCount++;
        }
      }
    }
    expect(bgBright / bgTotal, greaterThan(0.95));
    // The input's dark left side was ~half as bright as the right side.
    expect(redSum / redCount, greaterThan(100));
    expect(blueSum / blueCount, greaterThan(100));
  });

  group('autoColor', () {
    test('stretches a low-contrast image', () {
      const w = 400, h = 300;
      final c = Canvas(w, h)..fill(solid(150, 148, 145));
      drawFakeText(c, Quad.full(w, h), Random(2), color: (105, 104, 102), thickness: 5);
      c.addNoise(Random(2), 2);
      final input = c.toImage();
      final out = applyScanFilter(input, ScanFilter.autoColor);
      expect(out.width, w);
      expect(out.height, h);
      expect(_lumaStd(out), greaterThan(2 * _lumaStd(input)));
      // Paper becomes (near) white.
      expect(out.getPixel(3, 3).r, greaterThan(230));
    });

    test('removes a yellow color cast from the paper', () {
      const w = 400, h = 300;
      final c = Canvas(w, h)..fill(solid(225, 210, 150));
      drawFakeText(c, Quad.full(w, h), Random(3));
      final out = applyScanFilter(c.toImage(), ScanFilter.autoColor);
      final p = out.getPixel(5, 5);
      expect((p.r - p.b).abs(), lessThan(20));
      expect(p.g, greaterThan(225));
    });
  });

  test('grayscale is neutral and contrast stretched', () {
    final c = Canvas(200, 100)..fill((x, y) => (100 + x ~/ 4, 120 + x ~/ 4, 80 + x ~/ 4));
    final out = applyScanFilter(c.toImage(), ScanFilter.grayscale);
    var lo = 255, hi = 0;
    for (var y = 0; y < 100; y += 7) {
      for (var x = 0; x < 200; x++) {
        final p = out.getPixel(x, y);
        expect(p.r, p.g);
        expect(p.g, p.b);
        lo = min(lo, p.r.toInt());
        hi = max(hi, p.r.toInt());
      }
    }
    expect(hi - lo, greaterThan(240));
  });

  test('photo boosts saturation and keeps size', () {
    final c = Canvas(120, 80)..fill((x, y) => (150, 120, 100));
    final out = applyScanFilter(c.toImage(), ScanFilter.photo);
    final p = out.getPixel(10, 10);
    expect(p.r - p.b, greaterThan(50));
  });

  test('every filter preserves the size and outputs RGB', () {
    final rgba = img.Image(width: 123, height: 77, numChannels: 4);
    img.fill(rgba, color: img.ColorRgba8(180, 170, 160, 255));
    for (final f in ScanFilter.values) {
      final out = applyScanFilter(rgba, f);
      expect(out.width, 123, reason: f.name);
      expect(out.height, 77, reason: f.name);
      expect(out.numChannels, 3, reason: f.name);
    }
  });

  test('original is unchanged without adjustments', () {
    final rnd = Random(4);
    final c = Canvas(50, 40)..fill((_, _) => (rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)));
    final src = c.toImage();
    final out = applyScanFilter(src, ScanFilter.original);
    expect(out.getBytes(), src.getBytes());
    expect(identical(out, src), isFalse);
  });

  test('brightness and contrast are monotonic', () {
    final c = Canvas(256, 64)..fill((x, y) => (x, x, x));
    final src = c.toImage();
    for (final f in [ScanFilter.original, ScanFilter.grayscale, ScanFilter.autoColor, ScanFilter.photo]) {
      final means = [
        for (final b in [-0.6, -0.2, 0.0, 0.3, 0.7]) _lumaMean(applyScanFilter(src, f, brightness: b)),
      ];
      for (var i = 1; i < means.length; i++) {
        expect(means[i], greaterThan(means[i - 1]), reason: '${f.name} $means');
      }
      final stds = [
        for (final k in [-0.8, -0.3, 0.0, 0.4]) _lumaStd(applyScanFilter(src, f, contrast: k)),
      ];
      for (var i = 1; i < stds.length; i++) {
        expect(stds[i], greaterThan(stds[i - 1]), reason: '${f.name} $stds');
      }
    }
  });

  group('rotateImage', () {
    img.Image numbered() {
      // 3x2 image whose red channel encodes the pixel index.
      final im = img.Image(width: 3, height: 2);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 3; x++) {
          im.setPixelRgb(x, y, y * 3 + x, 0, 0);
        }
      }
      return im;
    }

    List<List<int>> grid(img.Image im) => [
      for (var y = 0; y < im.height; y++) [for (var x = 0; x < im.width; x++) im.getPixel(x, y).r.toInt()],
    ];

    test('quarter turns clockwise', () {
      final src = numbered();
      // 0 1 2
      // 3 4 5
      expect(grid(rotateImage(src, 1)), [
        [3, 0],
        [4, 1],
        [5, 2],
      ]);
      expect(grid(rotateImage(src, 2)), [
        [5, 4, 3],
        [2, 1, 0],
      ]);
      expect(grid(rotateImage(src, 3)), [
        [2, 5],
        [1, 4],
        [0, 3],
      ]);
      expect(grid(rotateImage(src, -1)), grid(rotateImage(src, 3)));
      expect(grid(rotateImage(src, 4)), grid(src));
      expect(grid(rotateImage(rotateImage(src, 1), 1)), grid(rotateImage(src, 2)));
    });

    test('matches package:image copyRotate', () {
      final rnd = Random(8);
      final c = Canvas(31, 17)..fill((_, _) => (rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)));
      final src = c.toImage();
      expect(rotateImage(src, 1).getBytes(), img.copyRotate(src, angle: 90).getBytes());
      expect(rotateImage(src, 3).getBytes(), img.copyRotate(src, angle: 270).getBytes());
    });
  });
}
