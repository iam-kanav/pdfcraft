/// Automatic document boundary detection.
///
/// Pipeline (all on a downscaled "paperness" map whose longest side is
/// [kDetectionSize] px):
///
/// 1. Feature map: luminance minus part of the chroma (paper is bright and
///    neutral, desks are often darker and/or colored), Gaussian blur.
/// 2. Canny edges: Sobel gradients, non-maximum suppression, adaptive double
///    threshold (Otsu on edge strengths + noise floor), hysteresis.
/// 3. Candidate quads from two independent strategies:
///    * Hough lines (orientation-aware voting); every 4-line combination that
///      forms a plausible convex quad (image borders count as lines so pages
///      that leave the frame still work).
///    * Regions: Otsu-thresholded bright/dark blobs and edge-enclosed areas,
///      reduced to their maximum-area inscribed quad of the convex hull.
/// 4. Every candidate is refined (sub-pixel edge search along each side and
///    a robust total-least-squares line fit) and scored by how well each side
///    is supported by a consistent contrast step and by Canny edges with a
///    matching orientation; area is a secondary factor.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'geometry.dart';
import 'raster.dart';

/// Longest side of the analysis image used by [detectDocumentQuad].
const int kDetectionSize = 384;

/// Minimum fraction of the image a detected document must cover.
const double kMinDocumentArea = 0.15;

/// Detects the document in [image] and returns its corners in the original
/// image's continuous pixel coordinates (see [Quad]), or null when no
/// plausible document is found.
Quad? detectDocumentQuad(img.Image image) {
  if (image.width < 16 || image.height < 16) return null;
  final small = fitRaster(Raster.fromImage(image), kDetectionSize);
  final detector = DocumentDetector(paperFeatureMap(small), small.width, small.height);
  final q = detector.detect();
  if (q == null) return null;
  return q
      .translate(0.5, 0.5)
      .scale(image.width / small.width, image.height / small.height)
      .clampTo(image.width, image.height);
}

/// Builds a binary Canny edge map (1 channel, 255 = edge) of [small] using
/// the same feature map and thresholds as the detector. Intended for
/// analysis-sized images (a few hundred px).
img.Image buildEdgeMap(img.Image small) {
  final r = Raster.fromImage(small);
  final a = EdgeAnalysis(paperFeatureMap(r), r.width, r.height);
  final out = Uint8List(r.width * r.height);
  for (var i = 0; i < out.length; i++) {
    out[i] = a.edges[i] != 0 ? 255 : 0;
  }
  return Raster(r.width, r.height, 1, out).toImage();
}

/// Per-pixel "paperness": luma minus half the chroma (max - min channel).
Float32List paperFeatureMap(Raster r) {
  final n = r.width * r.height;
  final nc = r.channels;
  final d = r.data;
  final out = Float32List(n);
  for (var i = 0, j = 0; i < n; i++, j += nc) {
    final red = d[j], g = d[j + 1], b = d[j + 2];
    final mx = math.max(red, math.max(g, b));
    final mn = math.min(red, math.min(g, b));
    out[i] = 0.299 * red + 0.587 * g + 0.114 * b - 0.5 * (mx - mn);
  }
  return out;
}

/// Gradient and Canny edge analysis of a single-channel float plane.
class EdgeAnalysis {
  /// Blurs [feature] and computes gradients and Canny edges.
  EdgeAnalysis(Float32List feature, this.width, this.height, {double sigma = 1.4})
    : g = gaussianBlurF32(feature, width, height, sigma) {
    final w = width, h = height, n = w * h;
    gx = Float32List(n);
    gy = Float32List(n);
    mag = Float32List(n);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final dx = (g[i - w + 1] + 2 * g[i + 1] + g[i + w + 1]) - (g[i - w - 1] + 2 * g[i - 1] + g[i + w - 1]);
        final dy = (g[i + w - 1] + 2 * g[i + w] + g[i + w + 1]) - (g[i - w - 1] + 2 * g[i - w] + g[i - w + 1]);
        gx[i] = dx / 8;
        gy[i] = dy / 8;
        mag[i] = math.sqrt(dx * dx + dy * dy) / 8;
      }
    }
    _canny();
    contrastThreshold = _estimateContrastThreshold();
  }

  /// Plane width.
  final int width;

  /// Plane height.
  final int height;

  /// Blurred feature plane.
  final Float32List g;

  /// Horizontal derivative (gray levels per pixel).
  late final Float32List gx;

  /// Vertical derivative (gray levels per pixel).
  late final Float32List gy;

  /// Gradient magnitude.
  late final Float32List mag;

  /// Canny edge pixels (1 = edge).
  late final Uint8List edges;

  /// Non-maximum-suppressed gradient magnitude (0 off ridges).
  late final Float32List nms;

  /// Canny high threshold.
  late final double high;

  /// Canny low threshold.
  late final double low;

  /// Minimum intensity step across a side for it to count as supported.
  late final double contrastThreshold;

  void _canny() {
    final w = width, h = height, n = w * h;
    final nms = this.nms = Float32List(n);
    var maxMag = 0.0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final m = mag[i];
        if (m < 0.5) continue;
        final ax = gx[i].abs(), ay = gy[i].abs();
        double n1, n2;
        if (ay <= ax * 0.41421356) {
          n1 = mag[i - 1];
          n2 = mag[i + 1];
        } else if (ay >= ax * 2.41421356) {
          n1 = mag[i - w];
          n2 = mag[i + w];
        } else if (gx[i] * gy[i] > 0) {
          n1 = mag[i - w - 1];
          n2 = mag[i + w + 1];
        } else {
          n1 = mag[i - w + 1];
          n2 = mag[i + w - 1];
        }
        if (m >= n1 && m > n2) {
          nms[i] = m;
          if (m > maxMag) maxMag = m;
        }
      }
    }

    // Thresholds: Otsu over the strengths of the NMS ridges, bounded below
    // by a noise floor derived from the median gradient magnitude.
    final hist = List<double>.filled(256, 0);
    final scale = maxMag > 0 ? 255 / maxMag : 0.0;
    for (var i = 0; i < n; i++) {
      final m = nms[i];
      if (m > 0) hist[(m * scale).floor().clamp(0, 255)]++;
    }
    final otsu = maxMag > 0 ? (otsuThreshold(hist) + 0.5) / scale : 0.0;
    final median = _medianOf(mag, step: 3);
    high = math.max(math.max(0.6 * otsu, 3.0 * median), 2.0);
    low = 0.4 * high;

    final e = Uint8List(n);
    final stack = Int32List(n);
    var sp = 0;
    for (var i = 0; i < n; i++) {
      if (nms[i] >= high && e[i] == 0) {
        e[i] = 1;
        stack[sp++] = i;
        while (sp > 0) {
          final p = stack[--sp];
          final px = p % w, py = p ~/ w;
          for (var dy = -1; dy <= 1; dy++) {
            final yy = py + dy;
            if (yy < 0 || yy >= h) continue;
            for (var dx = -1; dx <= 1; dx++) {
              final xx = px + dx;
              if (xx < 0 || xx >= w) continue;
              final q = yy * w + xx;
              if (e[q] == 0 && nms[q] >= low) {
                e[q] = 1;
                stack[sp++] = q;
              }
            }
          }
        }
      }
    }
    edges = e;
  }

  /// Contrast threshold relative to the texture/noise level: three times the
  /// median absolute difference between pixels 4 px apart, at least 8.
  double _estimateContrastThreshold() {
    final w = width, h = height;
    final diffs = <double>[];
    for (var y = 0; y < h - 4; y += 2) {
      for (var x = 0; x < w - 4; x += 2) {
        final i = y * w + x;
        diffs.add((g[i] - g[i + 4]).abs());
        diffs.add((g[i] - g[i + 4 * w]).abs());
      }
    }
    if (diffs.isEmpty) return 8;
    diffs.sort();
    return math.max(8.0, 3.0 * diffs[diffs.length ~/ 2]);
  }

  /// Bilinear sample of [plane] with clamp-to-edge.
  double sample(Float32List plane, double x, double y) {
    final w = width, h = height;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > w - 1) x = (w - 1).toDouble();
    if (y > h - 1) y = (h - 1).toDouble();
    final x0 = x.toInt(), y0 = y.toInt();
    final x1 = x0 < w - 1 ? x0 + 1 : x0;
    final y1 = y0 < h - 1 ? y0 + 1 : y0;
    final fx = x - x0, fy = y - y0;
    final a = plane[y0 * w + x0], b = plane[y0 * w + x1];
    final c = plane[y1 * w + x0], d = plane[y1 * w + x1];
    final top = a + (b - a) * fx;
    final bot = c + (d - c) * fx;
    return top + (bot - top) * fy;
  }

  static double _medianOf(Float32List data, {int step = 1}) {
    final vals = <double>[];
    for (var i = 0; i < data.length; i += step) {
      vals.add(data[i]);
    }
    if (vals.isEmpty) return 0;
    vals.sort();
    return vals[vals.length ~/ 2];
  }
}

/// A line in normal form `x * nx + y * ny = rho` (unit normal).
class _Line {
  _Line(this.nx, this.ny, this.rho, {this.border = false});

  factory _Line.through(math.Point<double> p, math.Point<double> q, {bool border = false}) {
    final dx = q.x - p.x, dy = q.y - p.y;
    final len = math.sqrt(dx * dx + dy * dy);
    final nx = dy / len, ny = -dx / len;
    return _Line(nx, ny, nx * p.x + ny * p.y, border: border);
  }

  final double nx, ny, rho;
  final bool border;

  math.Point<double>? intersect(_Line o) {
    final det = nx * o.ny - ny * o.nx;
    // Reject nearly parallel lines (< ~10 degrees apart).
    if (det.abs() < 0.17) return null;
    return math.Point((rho * o.ny - ny * o.rho) / det, (nx * o.rho - rho * o.nx) / det);
  }
}

class _Scored {
  _Scored(this.quad, this.score, this.valid);
  final Quad quad;
  final double score;
  final bool valid;
}

/// Document detector working on an analysis-sized feature plane.
///
/// Coordinates used and returned by this class are pixel-centre index
/// coordinates of the analysis plane.
class DocumentDetector {
  /// Prepares the gradient/edge analysis for [feature] (`width x height`).
  DocumentDetector(Float32List feature, this.width, this.height) : analysis = EdgeAnalysis(feature, width, height);

  /// Plane width.
  final int width;

  /// Plane height.
  final int height;

  /// Underlying gradient and edge analysis.
  final EdgeAnalysis analysis;

  static const int _maxLines = 24;
  static const int _maxLinesPerOrientation = 8;

  double get _imageArea => (width - 1.0) * (height - 1.0);

  /// Returns the best document quad or null.
  Quad? detect() {
    if (width < 16 || height < 16) return null;
    final candidates = <Quad>[..._houghCandidates(), ..._regionCandidates()];
    _Scored? best;
    for (final c in candidates) {
      for (final q in [c, _refine(c)]) {
        if (q == null) continue;
        final s = _score(q, full: true);
        if (!s.valid) continue;
        if (best == null || s.score > best.score) best = s;
      }
    }
    return best?.quad;
  }

  // -------------------------------------------------------------------------
  // Hough lines
  // -------------------------------------------------------------------------

  List<_Line> _houghLines() {
    final a = analysis;
    final w = width, h = height;
    const nTheta = 180;
    const spread = 10; // +/- degrees of orientation tolerance.
    final diag = math.sqrt(w * w + h * h);
    final offset = diag.ceil();
    final nRho = 2 * offset + 1;
    final acc = Float32List(nTheta * nRho);
    final cosT = Float64List(nTheta), sinT = Float64List(nTheta);
    for (var t = 0; t < nTheta; t++) {
      cosT[t] = math.cos(t * math.pi / nTheta);
      sinT[t] = math.sin(t * math.pi / nTheta);
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        // Vote with every ridge pixel above the low threshold: document
        // sides crossing textured or similar-looking backgrounds are often
        // fragmented and would be lost by hysteresis.
        if (a.nms[i] < a.low) continue;
        var ang = math.atan2(a.gy[i], a.gx[i]);
        if (ang < 0) ang += math.pi;
        final bin = (ang * nTheta / math.pi).round();
        final weight = math.min(a.mag[i] / a.high, 2.0);
        for (var d = -spread; d <= spread; d++) {
          final t = (bin + d) % nTheta;
          final tt = t < 0 ? t + nTheta : t;
          final rho = (x * cosT[tt] + y * sinT[tt]).round() + offset;
          acc[tt * nRho + rho] += weight;
        }
      }
    }

    final minVotes = 0.07 * math.min(w, h);
    final peaks = <(double, int, int)>[];
    for (var t = 0; t < nTheta; t++) {
      for (var r = 1; r < nRho - 1; r++) {
        final v = acc[t * nRho + r];
        if (v < minVotes) continue;
        var isMax = true;
        for (var dt = -1; dt <= 1 && isMax; dt++) {
          final tt = t + dt;
          if (tt < 0 || tt >= nTheta) continue;
          for (var dr = -1; dr <= 1; dr++) {
            if (dt == 0 && dr == 0) continue;
            final o = acc[tt * nRho + r + dr];
            if (o > v || (o == v && (dt < 0 || (dt == 0 && dr < 0)))) {
              isMax = false;
              break;
            }
          }
        }
        if (isMax) peaks.add((v, t, r - offset));
      }
    }
    peaks.sort((p, q) => q.$1.compareTo(p.$1));

    final kept = <(int, int)>[];
    final lines = <_Line>[];
    for (final p in peaks) {
      final t = p.$2, r = p.$3;
      var similar = false;
      for (final k in kept) {
        final dt = (t - k.$1).abs();
        if ((dt <= 6 && (r - k.$2).abs() <= 8) || (dt >= nTheta - 6 && (r + k.$2).abs() <= 8)) {
          similar = true;
          break;
        }
      }
      if (similar) continue;
      // Cap lines per orientation so repetitive textures (wood grain, tiles,
      // ruled lines) cannot crowd out the document's other sides.
      var sameOrientation = 0;
      for (final k in kept) {
        final dt = (t - k.$1).abs();
        if (math.min(dt, nTheta - dt) <= 10) sameOrientation++;
      }
      if (sameOrientation >= _maxLinesPerOrientation) continue;
      kept.add((t, r));
      lines.add(_Line(cosT[t], sinT[t], r.toDouble()));
      if (lines.length >= _maxLines) break;
    }
    return lines;
  }

  List<Quad> _houghCandidates() {
    final lines = [
      ..._houghLines(),
      // Image borders let documents that leave the frame still form quads.
      _Line(1, 0, 0, border: true),
      _Line(1, 0, width - 1.0, border: true),
      _Line(0, 1, 0, border: true),
      _Line(0, 1, height - 1.0, border: true),
    ];
    final n = lines.length;
    final scored = <_Scored>[];
    void consider(_Line p1, _Line p2, _Line q1, _Line q2) {
      final c1 = p1.intersect(q1);
      final c2 = q1.intersect(p2);
      final c3 = p2.intersect(q2);
      final c4 = q2.intersect(p1);
      if (c1 == null || c2 == null || c3 == null || c4 == null) return;
      final quad = Quad.orderPoints([c1, c2, c3, c4]);
      if (!_plausibleGeometry(quad)) return;
      final s = _score(quad, full: false);
      if (s.score > 0) scored.add(s);
    }

    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        for (var k = j + 1; k < n; k++) {
          for (var l = k + 1; l < n; l++) {
            final borders =
                (lines[i].border ? 1 : 0) +
                (lines[j].border ? 1 : 0) +
                (lines[k].border ? 1 : 0) +
                (lines[l].border ? 1 : 0);
            if (borders > 2) continue;
            consider(lines[i], lines[j], lines[k], lines[l]);
            consider(lines[i], lines[k], lines[j], lines[l]);
            consider(lines[i], lines[l], lines[j], lines[k]);
          }
        }
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [for (final s in scored.take(25)) s.quad];
  }

  // -------------------------------------------------------------------------
  // Region-based candidates (fallback strategy)
  // -------------------------------------------------------------------------

  List<Quad> _regionCandidates() {
    final w = width, h = height, n = w * h;
    final a = analysis;
    final out = <Quad>[];

    // (a) Thresholds of the paperness map: Otsu (both polarities), plus a
    //     second Otsu split of the bright class (page brighter than a
    //     bright, textured desk) and of the dark class (dark page on a
    //     light desk).
    final hist = List<double>.filled(256, 0);
    for (var i = 0; i < n; i++) {
      hist[a.g[i].round().clamp(0, 255)]++;
    }
    final t1 = otsuThreshold(hist);
    final upper = [for (var i = 0; i < 256; i++) i > t1 ? hist[i] : 0.0];
    final lower = [for (var i = 0; i < 256; i++) i <= t1 ? hist[i] : 0.0];
    final splits = <(int, bool)>[(t1, true), (t1, false), (otsuThreshold(upper), true), (otsuThreshold(lower), false)];
    for (final (t, bright) in splits) {
      var mask = Uint8List(n);
      var on = 0;
      for (var i = 0; i < n; i++) {
        final v = a.g[i].round().clamp(0, 255);
        final m = bright ? v > t : v <= t;
        if (m) {
          mask[i] = 1;
          on++;
        }
      }
      if (on < 0.1 * n) continue;
      mask = _morph(mask, 1, erode: true);
      mask = _morph(mask, 1, erode: false);
      mask = _morph(mask, 2, erode: false);
      mask = _morph(mask, 2, erode: true);
      out.addAll(_componentQuads(mask, 2, 0.1));
    }

    // (b) Areas enclosed by Canny edges.
    final enclosed = _morph(a.edges, 1, erode: false);
    for (var i = 0; i < n; i++) {
      enclosed[i] = enclosed[i] == 0 ? 1 : 0;
    }
    out.addAll(_componentQuads(enclosed, 3, 0.08));
    return out;
  }

  /// Binary 3x3 erosion/dilation repeated [iterations] times.
  Uint8List _morph(Uint8List src, int iterations, {required bool erode}) {
    final w = width, h = height;
    var cur = src;
    for (var it = 0; it < iterations; it++) {
      final next = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          var res = erode ? 1 : 0;
          for (var dy = -1; dy <= 1; dy++) {
            final yy = (y + dy).clamp(0, h - 1);
            for (var dx = -1; dx <= 1; dx++) {
              final xx = (x + dx).clamp(0, w - 1);
              final v = cur[yy * w + xx];
              if (erode && v == 0) res = 0;
              if (!erode && v != 0) res = 1;
            }
          }
          next[y * w + x] = res;
        }
      }
      cur = next;
    }
    return cur;
  }

  /// Quads for the [maxCount] largest 4-connected components of [mask]
  /// covering at least [minFrac] of the image.
  List<Quad> _componentQuads(Uint8List mask, int maxCount, double minFrac) {
    final w = width, h = height, n = w * h;
    final labels = Int32List(n);
    final stack = Int32List(n);
    final comps = <(int, int)>[]; // (area, label)
    var next = 0;
    for (var i = 0; i < n; i++) {
      if (mask[i] == 0 || labels[i] != 0) continue;
      next++;
      var area = 0;
      var sp = 0;
      stack[sp++] = i;
      labels[i] = next;
      while (sp > 0) {
        final p = stack[--sp];
        area++;
        final x = p % w, y = p ~/ w;
        if (x > 0 && mask[p - 1] != 0 && labels[p - 1] == 0) {
          labels[p - 1] = next;
          stack[sp++] = p - 1;
        }
        if (x < w - 1 && mask[p + 1] != 0 && labels[p + 1] == 0) {
          labels[p + 1] = next;
          stack[sp++] = p + 1;
        }
        if (y > 0 && mask[p - w] != 0 && labels[p - w] == 0) {
          labels[p - w] = next;
          stack[sp++] = p - w;
        }
        if (y < h - 1 && mask[p + w] != 0 && labels[p + w] == 0) {
          labels[p + w] = next;
          stack[sp++] = p + w;
        }
      }
      if (area >= minFrac * n) comps.add((area, next));
    }
    comps.sort((a, b) => b.$1.compareTo(a.$1));
    final quads = <Quad>[];
    for (final c in comps.take(maxCount)) {
      final label = c.$2;
      final pts = <math.Point<int>>[];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = y * w + x;
          if (labels[i] != label) continue;
          if (x == 0 ||
              y == 0 ||
              x == w - 1 ||
              y == h - 1 ||
              labels[i - 1] != label ||
              labels[i + 1] != label ||
              labels[i - w] != label ||
              labels[i + w] != label) {
            pts.add(math.Point(x, y));
          }
        }
      }
      final hull = _convexHull(pts);
      final q = _maxAreaQuad(hull);
      if (q != null) quads.add(q);
    }
    return quads;
  }

  // -------------------------------------------------------------------------
  // Scoring
  // -------------------------------------------------------------------------

  bool _plausibleGeometry(Quad q) {
    if (!q.isConvex) return false;
    if (q.area < (kMinDocumentArea - 0.02) * _imageArea) return false;
    final margin = 0.04 * math.max(width, height);
    for (final p in q.points) {
      if (p.x < -margin || p.y < -margin || p.x > width - 1 + margin || p.y > height - 1 + margin) {
        return false;
      }
    }
    for (final ang in q.interiorAngles) {
      if (ang < 30 || ang > 150) return false;
    }
    return true;
  }

  bool _isBorderSide(math.Point<double> p, math.Point<double> q) {
    const tol = 2.5;
    final r = width - 1.0, b = height - 1.0;
    return (p.x.abs() < tol && q.x.abs() < tol) ||
        (p.y.abs() < tol && q.y.abs() < tol) ||
        ((p.x - r).abs() < tol && (q.x - r).abs() < tol) ||
        ((p.y - b).abs() < tol && (q.y - b).abs() < tol);
  }

  /// Scores [q]: per side, the fraction of samples showing a contrast step
  /// (and, when [full], a Canny edge of matching orientation) with the
  /// quad's dominant polarity (document brighter or darker than its
  /// surroundings on every side). Sides lying on the image border get a
  /// fixed neutral support.
  _Scored _score(Quad q, {required bool full}) {
    if (!_plausibleGeometry(q)) return _Scored(q, 0, false);
    final a = analysis;
    final w = width, h = height;
    final pts = q.points;
    const delta = 3.0;
    const borderSupport = 0.55;
    final t = a.contrastThreshold;
    final isBorder = List<bool>.filled(4, false);
    final counts = List<int>.filled(4, 1);
    // [inside brighter, inside darker] per side, for contrast and edges.
    final stepPos = List<int>.filled(4, 0), stepNeg = List<int>.filled(4, 0);
    final edgePos = List<int>.filled(4, 0), edgeNeg = List<int>.filled(4, 0);
    var borders = 0;
    for (var s = 0; s < 4; s++) {
      final p = pts[s], e = pts[(s + 1) % 4];
      if (_isBorderSide(p, e)) {
        isBorder[s] = true;
        borders++;
        continue;
      }
      final dx = e.x - p.x, dy = e.y - p.y;
      final len = math.sqrt(dx * dx + dy * dy);
      final nx = dy / len, ny = -dx / len; // outward normal (clockwise quad)
      final count = full ? (len / 2).round().clamp(12, 120) : 12;
      counts[s] = count;
      for (var k = 0; k < count; k++) {
        final tt = 0.06 + 0.88 * (k + 0.5) / count;
        final x = p.x + dx * tt, y = p.y + dy * tt;
        if (x < 0 || y < 0 || x > w - 1 || y > h - 1) continue;
        final inside = a.sample(a.g, x - nx * delta, y - ny * delta);
        final outside = a.sample(a.g, x + nx * delta, y + ny * delta);
        final d = inside - outside;
        if (d > t) stepPos[s]++;
        if (d < -t) stepNeg[s]++;
        if (!full) continue;
        final xi = x.round(), yi = y.round();
        var hitPos = false, hitNeg = false;
        for (var oy = -1; oy <= 1; oy++) {
          final yy = yi + oy;
          if (yy < 0 || yy >= h) continue;
          for (var ox = -1; ox <= 1; ox++) {
            final xx = xi + ox;
            if (xx < 0 || xx >= w) continue;
            final i = yy * w + xx;
            if (a.edges[i] == 0) continue;
            // The gradient points towards the brighter side.
            final proj = a.gx[i] * nx + a.gy[i] * ny;
            if (proj <= -0.85 * a.mag[i]) hitPos = true;
            if (proj >= 0.85 * a.mag[i]) hitNeg = true;
          }
        }
        if (hitPos) edgePos[s]++;
        if (hitNeg) edgeNeg[s]++;
      }
    }
    if (borders > 2) return _Scored(q, 0, false);

    // Dominant polarity over all real sides.
    var balance = 0.0;
    for (var s = 0; s < 4; s++) {
      if (isBorder[s]) continue;
      balance += (stepPos[s] - stepNeg[s]) / counts[s];
    }
    final brighter = balance >= 0;

    final sides = <double>[];
    var minReal = 1.0;
    for (var s = 0; s < 4; s++) {
      if (isBorder[s]) {
        sides.add(borderSupport);
        continue;
      }
      final n = counts[s];
      final contrast = (brighter ? stepPos[s] : stepNeg[s]) / n;
      final edge = (brighter ? edgePos[s] : edgeNeg[s]) / n;
      final support = full ? 0.5 * (contrast + edge) : contrast;
      sides.add(support);
      if (support < minReal) minReal = support;
    }
    var mean = 0.0;
    var minAll = 1.0;
    for (final v in sides) {
      mean += v;
      if (v < minAll) minAll = v;
    }
    mean /= 4;
    final areaFrac = q.area / _imageArea;
    final score = mean * minAll * math.pow(areaFrac, 0.3);
    // Sides on the image border carry no evidence, so the remaining sides
    // must be convincing on their own.
    final minRealRequired = borders == 0 ? 0.45 : (borders == 1 ? 0.55 : 0.65);
    final valid = minReal >= minRealRequired && mean >= 0.55 && areaFrac >= kMinDocumentArea;
    return _Scored(q, score, valid);
  }

  // -------------------------------------------------------------------------
  // Refinement
  // -------------------------------------------------------------------------

  /// Re-fits every non-border side to the strongest nearby edge with
  /// sub-pixel accuracy, then intersects adjacent sides.
  Quad? _refine(Quad quad) {
    var q = quad;
    for (final radius in [4.0, 2.0]) {
      final pts = q.points;
      final lines = <_Line>[];
      for (var s = 0; s < 4; s++) {
        final p = pts[s], e = pts[(s + 1) % 4];
        if (_isBorderSide(p, e)) {
          lines.add(_Line.through(p, e, border: true));
          continue;
        }
        lines.add(_fitSide(p, e, radius) ?? _Line.through(p, e));
      }
      final corners = <math.Point<double>>[];
      for (var s = 0; s < 4; s++) {
        final c = lines[(s + 3) % 4].intersect(lines[s]);
        if (c == null) return null;
        corners.add(c);
      }
      final next = Quad.orderPoints(corners);
      if (!_plausibleGeometry(next)) return null;
      q = next;
    }
    return q;
  }

  _Line? _fitSide(math.Point<double> p, math.Point<double> e, double radius) {
    final a = analysis;
    final dx = e.x - p.x, dy = e.y - p.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 8) return null;
    final nx = dy / len, ny = -dx / len;
    final count = (len / 1.5).round();

    // Dominant sign of the derivative across the side.
    var signSum = 0.0;
    for (var k = 0; k < count; k++) {
      final tt = 0.1 + 0.8 * (k + 0.5) / count;
      final x = p.x + dx * tt, y = p.y + dy * tt;
      signSum += a.sample(a.gx, x, y) * nx + a.sample(a.gy, x, y) * ny;
    }
    final sgn = signSum >= 0 ? 1.0 : -1.0;

    final xs = <double>[], ys = <double>[], ws = <double>[];
    const step = 0.5;
    final steps = (radius / step).round();
    final prof = Float64List(2 * steps + 1);
    for (var k = 0; k < count; k++) {
      final tt = 0.1 + 0.8 * (k + 0.5) / count;
      final bx = p.x + dx * tt, by = p.y + dy * tt;
      if (bx < 1 || by < 1 || bx > width - 2 || by > height - 2) continue;
      var bestI = -1;
      var bestV = 0.0;
      for (var j = -steps; j <= steps; j++) {
        final x = bx + nx * j * step, y = by + ny * j * step;
        final v = sgn * (a.sample(a.gx, x, y) * nx + a.sample(a.gy, x, y) * ny);
        prof[j + steps] = v;
        if (v > bestV) {
          bestV = v;
          bestI = j + steps;
        }
      }
      if (bestI <= 0 || bestI >= prof.length - 1 || bestV < a.low) continue;
      final l = prof[bestI - 1], c = prof[bestI], r = prof[bestI + 1];
      final den = l - 2 * c + r;
      final sub = den.abs() > 1e-9 ? (0.5 * (l - r) / den).clamp(-0.5, 0.5) : 0;
      final off = (bestI - steps + sub) * step;
      xs.add(bx + nx * off);
      ys.add(by + ny * off);
      ws.add(bestV);
    }
    if (xs.length < math.max(8, (0.35 * count).round())) return null;
    var line = _fitLine(xs, ys, ws);
    if (line == null) return null;
    // One round of outlier rejection.
    final res = <double>[for (var i = 0; i < xs.length; i++) (xs[i] * line.nx + ys[i] * line.ny - line.rho).abs()];
    final sorted = List.of(res)..sort();
    final cut = math.max(0.75, 2.5 * sorted[sorted.length ~/ 2]);
    final fx = <double>[], fy = <double>[], fw = <double>[];
    for (var i = 0; i < xs.length; i++) {
      if (res[i] <= cut) {
        fx.add(xs[i]);
        fy.add(ys[i]);
        fw.add(ws[i]);
      }
    }
    if (fx.length < math.max(8, (0.3 * count).round())) return null;
    line = _fitLine(fx, fy, fw);
    if (line == null) return null;
    // Keep the original orientation convention; reject large rotations.
    final dot = line.nx * nx + line.ny * ny;
    if (dot.abs() < math.cos(8 * math.pi / 180)) return null;
    return line;
  }

  /// Weighted total-least-squares line fit.
  static _Line? _fitLine(List<double> xs, List<double> ys, List<double> ws) {
    var sw = 0.0, mx = 0.0, my = 0.0;
    for (var i = 0; i < xs.length; i++) {
      sw += ws[i];
      mx += ws[i] * xs[i];
      my += ws[i] * ys[i];
    }
    if (sw <= 0) return null;
    mx /= sw;
    my /= sw;
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (var i = 0; i < xs.length; i++) {
      final dx = xs[i] - mx, dy = ys[i] - my;
      sxx += ws[i] * dx * dx;
      syy += ws[i] * dy * dy;
      sxy += ws[i] * dx * dy;
    }
    // Direction = principal eigenvector of the covariance matrix.
    final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    final dirX = math.cos(theta), dirY = math.sin(theta);
    final nx = -dirY, ny = dirX;
    return _Line(nx, ny, nx * mx + ny * my);
  }

  // -------------------------------------------------------------------------
  // Hull utilities
  // -------------------------------------------------------------------------

  static List<math.Point<double>> _convexHull(List<math.Point<int>> pts) {
    if (pts.length < 3) {
      return [for (final p in pts) math.Point(p.x.toDouble(), p.y.toDouble())];
    }
    final s = List.of(pts)..sort((a, b) => a.x != b.x ? a.x - b.x : a.y - b.y);
    int cross(math.Point<int> o, math.Point<int> a, math.Point<int> b) =>
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    final lower = <math.Point<int>>[];
    for (final p in s) {
      while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final upper = <math.Point<int>>[];
    for (final p in s.reversed) {
      while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return [
      for (final p in [...lower, ...upper]) math.Point(p.x.toDouble(), p.y.toDouble()),
    ];
  }

  /// Maximum-area quadrilateral with vertices on the convex [hull].
  static Quad? _maxAreaQuad(List<math.Point<double>> hull) {
    if (hull.length < 4) return null;
    var pts = hull;
    // Visvalingam-style reduction to keep the O(k^3) search cheap.
    while (pts.length > 48) {
      var minA = double.infinity;
      var minI = 0;
      for (var i = 0; i < pts.length; i++) {
        final a = _tri(pts[(i - 1 + pts.length) % pts.length], pts[i], pts[(i + 1) % pts.length]);
        if (a < minA) {
          minA = a;
          minI = i;
        }
      }
      pts = List.of(pts)..removeAt(minI);
    }
    final k = pts.length;
    var best = -1.0;
    List<int>? bestIdx;
    for (var i = 0; i < k; i++) {
      for (var j = i + 2; j < k; j++) {
        if (k - (j - i) < 2) continue;
        var b1 = -1.0, bi = -1;
        for (var m = i + 1; m < j; m++) {
          final a = _tri(pts[i], pts[m], pts[j]);
          if (a > b1) {
            b1 = a;
            bi = m;
          }
        }
        var b2 = -1.0, bj = -1;
        for (var m = j + 1; m < i + k; m++) {
          final mm = m % k;
          final a = _tri(pts[j], pts[mm], pts[i]);
          if (a > b2) {
            b2 = a;
            bj = mm;
          }
        }
        if (bi < 0 || bj < 0) continue;
        if (b1 + b2 > best) {
          best = b1 + b2;
          bestIdx = [i, bi, j, bj];
        }
      }
    }
    if (bestIdx == null) return null;
    return Quad.orderPoints([for (final i in bestIdx) pts[i]]);
  }

  static double _tri(math.Point<double> a, math.Point<double> b, math.Point<double> c) =>
      ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() / 2;
}
