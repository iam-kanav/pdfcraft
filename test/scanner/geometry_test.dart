import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/features/scanner/processing/geometry.dart';

void expectPointNear(Point<double> a, Point<double> b, [double tol = 1e-6]) {
  expect(a.distanceTo(b), lessThan(tol), reason: '$a != $b');
}

void main() {
  group('homography', () {
    test('maps the four source points exactly onto the destination', () {
      const src = [Point(12.0, 34.0), Point(980.0, 51.0), Point(1010.0, 1400.0), Point(-20.0, 1320.0)];
      const dst = [Point(0.0, 0.0), Point(800.0, 0.0), Point(800.0, 1100.0), Point(0.0, 1100.0)];
      final h = computeHomography(src, dst);
      expect(h, hasLength(9));
      expect(h[8], closeTo(1, 1e-12));
      for (var i = 0; i < 4; i++) {
        expectPointNear(applyHomography(h, src[i]), dst[i], 1e-6);
      }
    });

    test('round trip through the inverse mapping', () {
      final rnd = Random(1);
      const a = [Point(100.0, 120.0), Point(700.0, 90.0), Point(760.0, 640.0), Point(60.0, 600.0)];
      const b = [Point(0.0, 0.0), Point(1.0, 0.0), Point(1.0, 1.0), Point(0.0, 1.0)];
      final fwd = computeHomography(a, b);
      final back = computeHomography(b, a);
      final inv = invertHomography(fwd);
      for (var i = 0; i < 50; i++) {
        final p = Point(rnd.nextDouble() * 800, rnd.nextDouble() * 700);
        expectPointNear(applyHomography(back, applyHomography(fwd, p)), p, 1e-6);
        expectPointNear(applyHomography(inv, applyHomography(fwd, p)), p, 1e-6);
      }
    });

    test('identity and pure translation', () {
      const pts = [Point(0.0, 0.0), Point(10.0, 0.0), Point(10.0, 5.0), Point(0.0, 5.0)];
      final id = computeHomography(pts, pts);
      const expected = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
      for (var i = 0; i < 9; i++) {
        expect(id[i], closeTo(expected[i], 1e-9));
      }
      final moved = [for (final p in pts) Point(p.x + 3, p.y - 7)];
      final t = computeHomography(pts, moved);
      expectPointNear(applyHomography(t, const Point(4.0, 4.0)), const Point(7.0, -3.0));
    });

    test('rejects degenerate (collinear) configurations', () {
      const bad = [Point(0.0, 0.0), Point(1.0, 1.0), Point(2.0, 2.0), Point(3.0, 3.0)];
      const good = [Point(0.0, 0.0), Point(1.0, 0.0), Point(1.0, 1.0), Point(0.0, 1.0)];
      expect(() => computeHomography(bad, good), throwsArgumentError);
    });
  });

  group('Quad', () {
    const tl = Point(100.0, 80.0);
    const tr = Point(520.0, 110.0);
    const br = Point(560.0, 640.0);
    const bl = Point(70.0, 600.0);

    test('orderPoints handles every permutation', () {
      final pts = [tl, tr, br, bl];
      final perms = <List<int>>[];
      void permute(List<int> cur, List<int> rest) {
        if (rest.isEmpty) {
          perms.add(cur);
          return;
        }
        for (final r in rest) {
          permute([...cur, r], [...rest]..remove(r));
        }
      }

      permute([], [0, 1, 2, 3]);
      expect(perms, hasLength(24));
      for (final p in perms) {
        final q = Quad.orderPoints([for (final i in p) pts[i]]);
        expect(q, Quad(tl, tr, br, bl), reason: 'permutation $p');
      }
    });

    test('orderPoints on rotated rectangles', () {
      for (final deg in [-40, -20, 0, 15, 35]) {
        final a = deg * pi / 180;
        Point<double> rot(double x, double y) => Point(300 + x * cos(a) - y * sin(a), 300 + x * sin(a) + y * cos(a));
        final expected = [rot(-100, -150), rot(100, -150), rot(100, 150), rot(-100, 150)];
        final shuffled = [expected[2], expected[0], expected[3], expected[1]];
        final q = Quad.orderPoints(shuffled);
        for (var i = 0; i < 4; i++) {
          expectPointNear(q.points[i], expected[i]);
        }
      }
    });

    test('area, convexity, scale and full', () {
      final full = Quad.full(400, 300);
      expect(full.area, closeTo(120000, 1e-9));
      expect(full.isConvex, isTrue);
      expect(full.points, const [Point(0.0, 0.0), Point(400.0, 0.0), Point(400.0, 300.0), Point(0.0, 300.0)]);
      final scaled = full.scale(0.5, 2);
      expect(scaled.br, const Point(200.0, 600.0));
      expect(scaled.area, closeTo(120000, 1e-9));

      // Self-intersecting "bow tie" and concave quads are not convex.
      const bowTie = Quad(tl, br, tr, bl);
      expect(bowTie.isConvex, isFalse);
      const concave = Quad(Point(0.0, 0.0), Point(100.0, 0.0), Point(20.0, 20.0), Point(0.0, 100.0));
      expect(concave.isConvex, isFalse);
      expect(const Quad(tl, tr, br, bl).isConvex, isTrue);
    });

    test('JSON and list round trips', () {
      const q = Quad(tl, tr, br, bl);
      expect(Quad.fromJson(q.toJson()), q);
      expect(Quad.fromList(q.toList()), q);
      // Corners as {x, y} maps and integer values are accepted as well.
      final alt = Quad.fromJson({
        'tl': {'x': 100, 'y': 80},
        'tr': [520, 110],
        'br': [560.0, 640.0],
        'bl': {'x': 70.0, 'y': 600.0},
      });
      expect(alt, q);
      expect(() => Quad.fromJson({'tl': 'nope'}), throwsFormatException);
      expect(() => Quad.fromList(const [tl, tr, br]), throwsArgumentError);
    });

    test('interior angles of a rectangle are 90 degrees', () {
      for (final a in Quad.full(10, 20).interiorAngles) {
        expect(a, closeTo(90, 1e-9));
      }
    });
  });
}
