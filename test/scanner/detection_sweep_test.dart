// Deterministic randomized robustness sweeps for the document detector.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/features/scanner/processing/edge_detector.dart';
import 'package:pdfcraft/features/scanner/processing/geometry.dart';

import 'synthetic.dart';

bool _inFrame(Quad q, int w, int h) => q.points.every((p) => p.x >= 4 && p.y >= 4 && p.x <= w - 4 && p.y <= h - 4);

void main() {
  test('random pages on flat, striped, blotchy and unevenly lit desks', () {
    final rnd = Random(42);
    final failures = <String>[];
    var cases = 0;
    while (cases < 40) {
      final w = 640 + rnd.nextInt(400), h = 480 + rnd.nextInt(300);
      final pw = w * (0.4 + 0.35 * rnd.nextDouble());
      final ph = h * (0.45 + 0.35 * rnd.nextDouble());
      final base = rotatedRect(
        w * (0.4 + 0.2 * rnd.nextDouble()),
        h * (0.4 + 0.2 * rnd.nextDouble()),
        pw,
        ph,
        (rnd.nextDouble() - 0.5) * 70,
      );
      // Jitter the corners to simulate perspective.
      final jit = 0.15 * min(pw, ph);
      final truth = Quad.orderPoints([
        for (final p in base.points)
          Point(p.x + (rnd.nextDouble() - 0.5) * 2 * jit, p.y + (rnd.nextDouble() - 0.5) * 2 * jit),
      ]);
      if (!_inFrame(truth, w, h)) continue;
      final kind = cases % 4;
      final bg = 40 + rnd.nextInt(110);
      final paper = min(255, bg + 30 + rnd.nextInt(120));
      final phase = rnd.nextDouble() * 10;
      final c = Canvas(w, h)
        ..fill((x, y) {
          var v = bg.toDouble();
          if (kind == 1) v += 30 * sin(y * 0.2 + 2 * sin(x * 0.01) + phase);
          if (kind == 2) {
            v += 20 * sin(x * 0.05 + phase) * cos(y * 0.06) + 12 * sin((x - y) * 0.3);
          }
          return ((v * 1.1).round(), v.round(), (v * 0.8).round());
        });
      c.fillPolygon(truth.points, solid(paper, paper, paper - 5));
      drawFakeText(c, truth, rnd, lines: 8 + rnd.nextInt(12));
      if (kind == 3) {
        final gx = rnd.nextDouble(), gy = rnd.nextDouble();
        c.applyLighting((x, y) => 1.1 - 0.5 * ((x / w - gx).abs() + (y / h - gy).abs()) / 2);
      }
      c.addNoise(rnd, 3 + rnd.nextDouble() * 12);

      final found = detectDocumentQuad(c.toImage());
      final tol = 0.03 * sqrt(w * w + h * h);
      final err = found == null ? double.infinity : maxCornerError(found, truth);
      if (err >= tol) {
        failures.add(
          'case $cases (kind $kind, bg $bg, paper $paper): '
          'error $err, found $found, truth $truth',
        );
      }
      cases++;
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('portrait photos with strong perspective and lighting falloff', () {
    final rnd = Random(77);
    final failures = <String>[];
    var cases = 0;
    const w = 900, h = 1200;
    while (cases < 25) {
      final topW = w * (0.3 + 0.3 * rnd.nextDouble());
      final botW = w * (0.6 + 0.35 * rnd.nextDouble());
      final top = h * (0.05 + 0.2 * rnd.nextDouble());
      final bot = h * (0.75 + 0.22 * rnd.nextDouble());
      final cx = w / 2 + (rnd.nextDouble() - 0.5) * w * 0.15;
      final skew = (rnd.nextDouble() - 0.5) * w * 0.2;
      final truth = Quad.orderPoints([
        Point(cx - topW / 2 + skew, top),
        Point(cx + topW / 2 + skew, top + (rnd.nextDouble() - 0.5) * 60),
        Point(cx + botW / 2, bot),
        Point(cx - botW / 2, bot + (rnd.nextDouble() - 0.5) * 60),
      ]);
      if (!_inFrame(truth, w, h)) continue;
      final bg = 50 + rnd.nextInt(100);
      final paper = min(250, bg + 40 + rnd.nextInt(100));
      final c = Canvas(w, h)..fill(solid(bg, (bg * 0.9).round(), (bg * 0.8).round()));
      c.fillPolygon(truth.points, solid(paper));
      drawFakeText(c, truth, rnd, lines: 20);
      final gx = rnd.nextDouble(), gy = rnd.nextDouble();
      c.applyLighting((x, y) => 1.15 - 0.6 * ((x / w - gx).abs() + (y / h - gy).abs()) / 2);
      c.addNoise(rnd, 4 + rnd.nextDouble() * 10);

      final found = detectDocumentQuad(c.toImage());
      final tol = 0.03 * sqrt(w * w + h * h);
      final err = found == null ? double.infinity : maxCornerError(found, truth);
      if (err >= tol) failures.add('case $cases: error $err, found $found');
      cases++;
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('no detections on document-free textured scenes', () {
    final rnd = Random(9);
    final hits = <String>[];
    for (var t = 0; t < 24; t++) {
      final w = 640 + rnd.nextInt(400), h = 480 + rnd.nextInt(300);
      final kind = t % 4;
      final phase = rnd.nextDouble() * 10;
      final base = 60 + rnd.nextInt(120);
      final c = Canvas(w, h)
        ..fill((x, y) {
          var v = base.toDouble();
          if (kind == 0) v += 30 * sin(y * 0.2 + 2 * sin(x * 0.01) + phase);
          if (kind == 1) {
            v += 20 * sin(x * 0.05 + phase) * cos(y * 0.06) + 12 * sin((x - y) * 0.3);
          }
          if (kind == 2) v += 80 * (x / w - 0.5) + 40 * (y / h - 0.5);
          if (kind == 3) v += 25 * sin(x * 0.02 + phase) + 25 * sin(y * 0.03);
          return ((v * 1.1).round(), v.round(), (v * 0.8).round());
        });
      c.addNoise(rnd, 2 + rnd.nextDouble() * 15);
      final q = detectDocumentQuad(c.toImage());
      if (q != null) hits.add('scene $t (kind $kind): $q');
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
