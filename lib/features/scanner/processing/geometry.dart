/// Geometry primitives for the document scanner: quadrilaterals and
/// planar homographies.
///
/// Coordinate convention: continuous image coordinates where pixel `(i, j)`
/// covers `[i, i+1) x [j, j+1)`; the whole image is `[0, width] x [0, height]`.
library;

import 'dart:math';

/// A quadrilateral given by its four corners in clockwise image order
/// (top-left, top-right, bottom-right, bottom-left; y axis pointing down).
class Quad {
  /// Creates a quad from explicit corners.
  const Quad(this.tl, this.tr, this.br, this.bl);

  /// The quad covering the whole `width x height` image.
  factory Quad.full(num width, num height) => Quad(
    const Point(0.0, 0.0),
    Point(width.toDouble(), 0.0),
    Point(width.toDouble(), height.toDouble()),
    Point(0.0, height.toDouble()),
  );

  /// Creates a quad from 4 points given in `tl, tr, br, bl` order.
  ///
  /// Use [orderPoints] when the order is unknown.
  factory Quad.fromList(List<Point<num>> pts) {
    if (pts.length != 4) {
      throw ArgumentError.value(
        pts.length,
        'pts',
        'Quad needs exactly 4 points',
      );
    }
    return Quad(_toD(pts[0]), _toD(pts[1]), _toD(pts[2]), _toD(pts[3]));
  }

  /// Parses the map produced by [toJson]. Each corner may be encoded as
  /// `[x, y]` or `{'x': x, 'y': y}`.
  factory Quad.fromJson(Map<String, dynamic> json) {
    Point<double> parse(Object? v, String key) {
      if (v is List && v.length >= 2) {
        return Point((v[0] as num).toDouble(), (v[1] as num).toDouble());
      }
      if (v is Map) {
        return Point((v['x'] as num).toDouble(), (v['y'] as num).toDouble());
      }
      throw FormatException('Invalid quad corner "$key": $v');
    }

    return Quad(
      parse(json['tl'], 'tl'),
      parse(json['tr'], 'tr'),
      parse(json['br'], 'br'),
      parse(json['bl'], 'bl'),
    );
  }

  /// Top-left corner.
  final Point<double> tl;

  /// Top-right corner.
  final Point<double> tr;

  /// Bottom-right corner.
  final Point<double> br;

  /// Bottom-left corner.
  final Point<double> bl;

  /// Corners in `tl, tr, br, bl` order.
  List<Point<double>> get points => [tl, tr, br, bl];

  /// Same as [points] (a fresh, growable list).
  List<Point<double>> toList() => List.of(points);

  /// Serialises to a sendable map: `{'tl': [x, y], 'tr': ..., 'br': ..., 'bl': ...}`.
  Map<String, dynamic> toJson() => {
    'tl': [tl.x, tl.y],
    'tr': [tr.x, tr.y],
    'br': [br.x, br.y],
    'bl': [bl.x, bl.y],
  };

  /// Scales all corners by `(sx, sy)`.
  Quad scale(double sx, double sy) {
    Point<double> s(Point<double> p) => Point(p.x * sx, p.y * sy);
    return Quad(s(tl), s(tr), s(br), s(bl));
  }

  /// Translates all corners by `(dx, dy)`.
  Quad translate(double dx, double dy) {
    Point<double> t(Point<double> p) => Point(p.x + dx, p.y + dy);
    return Quad(t(tl), t(tr), t(br), t(bl));
  }

  /// Clamps every corner into `[0, width] x [0, height]`.
  Quad clampTo(num width, num height) {
    Point<double> c(Point<double> p) => Point(
      p.x.clamp(0.0, width.toDouble()),
      p.y.clamp(0.0, height.toDouble()),
    );
    return Quad(c(tl), c(tr), c(br), c(bl));
  }

  /// Absolute polygon area (shoelace formula).
  double get area {
    final p = points;
    var s = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = p[i];
      final b = p[(i + 1) % 4];
      s += a.x * b.y - b.x * a.y;
    }
    return s.abs() / 2;
  }

  /// Sum of the side lengths.
  double get perimeter {
    final p = points;
    var s = 0.0;
    for (var i = 0; i < 4; i++) {
      s += p[i].distanceTo(p[(i + 1) % 4]);
    }
    return s;
  }

  /// Average of the corners.
  Point<double> get centroid =>
      Point((tl.x + tr.x + br.x + bl.x) / 4, (tl.y + tr.y + br.y + bl.y) / 4);

  /// True when the quad is a strictly convex, non-self-intersecting polygon.
  bool get isConvex {
    final p = points;
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = p[i];
      final b = p[(i + 1) % 4];
      final c = p[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-9) return false;
      final s = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (s != sign) {
        return false;
      }
    }
    // With 4 vertices, consistent turn direction implies a simple polygon
    // unless the total turning is 720 degrees, which needs >= 5 vertices.
    return true;
  }

  /// Interior angles in degrees at `tl, tr, br, bl`.
  List<double> get interiorAngles {
    final p = points;
    return List.generate(4, (i) {
      final prev = p[(i + 3) % 4];
      final cur = p[i];
      final next = p[(i + 1) % 4];
      final ax = prev.x - cur.x, ay = prev.y - cur.y;
      final bx = next.x - cur.x, by = next.y - cur.y;
      final denom = sqrt(ax * ax + ay * ay) * sqrt(bx * bx + by * by);
      if (denom == 0) return 0.0;
      final c = ((ax * bx + ay * by) / denom).clamp(-1.0, 1.0);
      return acos(c) * 180 / pi;
    });
  }

  /// Orders 4 arbitrary points into `tl, tr, br, bl`.
  ///
  /// Points are sorted clockwise around their centroid; the point with the
  /// smallest `x + y` becomes the top-left corner.
  static Quad orderPoints(List<Point<num>> pts) {
    if (pts.length != 4) {
      throw ArgumentError.value(
        pts.length,
        'pts',
        'Quad needs exactly 4 points',
      );
    }
    final p = pts.map(_toD).toList();
    final cx = (p[0].x + p[1].x + p[2].x + p[3].x) / 4;
    final cy = (p[0].y + p[1].y + p[2].y + p[3].y) / 4;
    // atan2 grows clockwise on screen because y points down.
    p.sort(
      (a, b) => atan2(a.y - cy, a.x - cx).compareTo(atan2(b.y - cy, b.x - cx)),
    );
    var start = 0;
    var best = double.infinity;
    for (var i = 0; i < 4; i++) {
      final s = p[i].x + p[i].y;
      if (s < best - 1e-9) {
        best = s;
        start = i;
      }
    }
    return Quad(
      p[start],
      p[(start + 1) % 4],
      p[(start + 2) % 4],
      p[(start + 3) % 4],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Quad &&
      other.tl == tl &&
      other.tr == tr &&
      other.br == br &&
      other.bl == bl;

  @override
  int get hashCode => Object.hash(tl, tr, br, bl);

  @override
  String toString() {
    String f(Point<double> p) =>
        '(${p.x.toStringAsFixed(1)}, ${p.y.toStringAsFixed(1)})';
    return 'Quad(tl: ${f(tl)}, tr: ${f(tr)}, br: ${f(br)}, bl: ${f(bl)})';
  }

  static Point<double> _toD(Point<num> p) =>
      Point(p.x.toDouble(), p.y.toDouble());
}

/// Computes the homography `H` (3x3, row-major, `H[8] == 1`) that maps each
/// `src[i]` onto `dst[i]` (exactly 4 correspondences).
///
/// Coordinates are normalised (Hartley) before solving the 8x8 linear system
/// with Gaussian elimination and partial pivoting. Throws [ArgumentError]
/// for degenerate configurations (e.g. 3 collinear points).
List<double> computeHomography(List<Point<num>> src, List<Point<num>> dst) {
  if (src.length != 4 || dst.length != 4) {
    throw ArgumentError('computeHomography needs exactly 4 point pairs');
  }
  final ts = _normalization(src);
  final td = _normalization(dst);
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final s = _apply(ts, src[i].x.toDouble(), src[i].y.toDouble());
    final d = _apply(td, dst[i].x.toDouble(), dst[i].y.toDouble());
    final x = s.$1, y = s.$2, u = d.$1, v = d.$2;
    a[2 * i]
      ..[0] = x
      ..[1] = y
      ..[2] = 1
      ..[6] = -u * x
      ..[7] = -u * y
      ..[8] = u;
    a[2 * i + 1]
      ..[3] = x
      ..[4] = y
      ..[5] = 1
      ..[6] = -v * x
      ..[7] = -v * y
      ..[8] = v;
  }
  final h = _solve8(a);
  final hn = [...h, 1.0];
  // H = Td^-1 * Hn * Ts
  final res = _mul3(_inv3(td), _mul3(hn, ts));
  final s = res[8];
  if (s.abs() < 1e-15) {
    throw ArgumentError('Degenerate homography');
  }
  return [for (final v in res) v / s];
}

/// Applies homography [h] (row-major 3x3) to point [p].
Point<double> applyHomography(List<double> h, Point<num> p) {
  final x = p.x.toDouble();
  final y = p.y.toDouble();
  final w = h[6] * x + h[7] * y + h[8];
  return Point(
    (h[0] * x + h[1] * y + h[2]) / w,
    (h[3] * x + h[4] * y + h[5]) / w,
  );
}

/// Inverse of a homography (normalised so the last element is 1 when
/// possible).
List<double> invertHomography(List<double> h) {
  final inv = _inv3(h);
  final s = inv[8];
  if (s.abs() < 1e-15) return inv;
  return [for (final v in inv) v / s];
}

/// Similarity transform moving the centroid to the origin and scaling the
/// mean distance to sqrt(2).
List<double> _normalization(List<Point<num>> pts) {
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.x;
    cy += p.y;
  }
  cx /= pts.length;
  cy /= pts.length;
  var md = 0.0;
  for (final p in pts) {
    md += sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy));
  }
  md /= pts.length;
  final s = md < 1e-12 ? 1.0 : sqrt2 / md;
  return [s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1];
}

(double, double) _apply(List<double> m, double x, double y) {
  final w = m[6] * x + m[7] * y + m[8];
  return ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w);
}

/// Solves the 8x8 augmented system [a] (8 rows x 9 cols) in place.
List<double> _solve8(List<List<double>> a) {
  const n = 8;
  for (var col = 0; col < n; col++) {
    var pivot = col;
    var maxAbs = a[col][col].abs();
    for (var r = col + 1; r < n; r++) {
      final v = a[r][col].abs();
      if (v > maxAbs) {
        maxAbs = v;
        pivot = r;
      }
    }
    if (maxAbs < 1e-12) {
      throw ArgumentError('Degenerate point configuration for homography');
    }
    if (pivot != col) {
      final t = a[pivot];
      a[pivot] = a[col];
      a[col] = t;
    }
    final pr = a[col];
    final pv = pr[col];
    for (var r = col + 1; r < n; r++) {
      final row = a[r];
      final f = row[col] / pv;
      if (f == 0) continue;
      for (var c = col; c <= n; c++) {
        row[c] -= f * pr[c];
      }
    }
  }
  final x = List<double>.filled(n, 0);
  for (var r = n - 1; r >= 0; r--) {
    var s = a[r][n];
    for (var c = r + 1; c < n; c++) {
      s -= a[r][c] * x[c];
    }
    x[r] = s / a[r][r];
  }
  return x;
}

List<double> _mul3(List<double> a, List<double> b) {
  final r = List<double>.filled(9, 0);
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      var s = 0.0;
      for (var k = 0; k < 3; k++) {
        s += a[i * 3 + k] * b[k * 3 + j];
      }
      r[i * 3 + j] = s;
    }
  }
  return r;
}

List<double> _inv3(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final co0 = e * i - f * h;
  final co1 = -(d * i - f * g);
  final co2 = d * h - e * g;
  final det = a * co0 + b * co1 + c * co2;
  if (det.abs() < 1e-18) {
    throw ArgumentError('Matrix is not invertible');
  }
  final inv = 1 / det;
  return [
    co0 * inv,
    -(b * i - c * h) * inv,
    (b * f - c * e) * inv,
    co1 * inv,
    (a * i - c * g) * inv,
    -(a * f - c * d) * inv,
    co2 * inv,
    -(a * h - b * g) * inv,
    (a * e - b * d) * inv,
  ];
}
