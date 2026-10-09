/// Scan enhancement filters (auto color, grayscale, black & white, ...).
///
/// All filters operate on raw byte buffers with separable / sliding-window
/// box filters, so they stay fast on multi-megapixel pages.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'raster.dart';

/// Enhancement applied to a scanned page.
enum ScanFilter {
  /// Unmodified colors.
  original('Original'),

  /// Lighting/white-balance correction with a contrast stretch.
  autoColor('Auto color'),

  /// Contrast-stretched luminance.
  grayscale('Grayscale'),

  /// Adaptive binarisation: black ink on pure white paper.
  blackWhite('Black & white'),

  /// Background flattened to pure white, ink colors kept saturated.
  whiteboard('Whiteboard'),

  /// Light vibrance and contrast boost for photos.
  photo('Photo');

  const ScanFilter(this.label);

  /// Human-readable name.
  final String label;

  /// Parses an enum [name] (e.g. `'blackWhite'`); unknown values map to
  /// [ScanFilter.original].
  static ScanFilter fromName(String? name) {
    for (final f in ScanFilter.values) {
      if (f.name == name) return f;
    }
    return ScanFilter.original;
  }
}

/// Applies [filter] to [src] and returns a new 8-bit RGB image of the same
/// size. [brightness] and [contrast] are in `[-1, 1]` (0 = unchanged) and
/// are applied on top of every filter.
img.Image applyScanFilter(
  img.Image src,
  ScanFilter filter, {
  double brightness = 0,
  double contrast = 0,
}) {
  // Without allowAlpha the raster is always 3-channel RGB.
  final r = Raster.fromImage(src);
  return Raster(
    r.width,
    r.height,
    3,
    filterRgb(r.data, r.width, r.height, filter, brightness, contrast),
  ).toImage();
}

/// Raw-buffer implementation of [applyScanFilter]. [rgb] is never modified;
/// a new interleaved RGB buffer is returned.
Uint8List filterRgb(
  Uint8List rgb,
  int w,
  int h,
  ScanFilter filter,
  double brightness,
  double contrast,
) {
  final lut = brightnessContrastLut(brightness, contrast);
  switch (filter) {
    case ScanFilter.original:
      final out = Uint8List.fromList(rgb);
      if (lut != null) _applyLut(out, lut);
      return out;
    case ScanFilter.grayscale:
      return _grayscale(rgb, w, h, lut);
    case ScanFilter.blackWhite:
      return _blackWhite(rgb, w, h, lut);
    case ScanFilter.autoColor:
      return _autoColor(rgb, w, h, lut);
    case ScanFilter.whiteboard:
      return _whiteboard(rgb, w, h, lut);
    case ScanFilter.photo:
      return _photo(rgb, w, h, lut);
  }
}

/// Rotates [src] clockwise by [quarterTurns] * 90 degrees (negative values
/// rotate counter-clockwise). Always returns a new image.
img.Image rotateImage(img.Image src, int quarterTurns) {
  final r = Raster.fromImage(src, allowAlpha: true);
  return rotateRaster(r, quarterTurns).toImage();
}

/// Raw-buffer implementation of [rotateImage].
Raster rotateRaster(Raster r, int quarterTurns) {
  final q = ((quarterTurns % 4) + 4) % 4;
  final w = r.width, h = r.height, nc = r.channels;
  final s = r.data;
  if (q == 0) return Raster(w, h, nc, Uint8List.fromList(s));
  final dw = q == 2 ? w : h;
  final dh = q == 2 ? h : w;
  final out = Uint8List(w * h * nc);
  var si = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int dx, dy;
      switch (q) {
        case 1: // 90 degrees clockwise
          dx = h - 1 - y;
          dy = x;
        case 2:
          dx = w - 1 - x;
          dy = h - 1 - y;
        default: // 270 degrees clockwise
          dx = y;
          dy = w - 1 - x;
      }
      var di = (dy * dw + dx) * nc;
      for (var c = 0; c < nc; c++) {
        out[di++] = s[si++];
      }
    }
  }
  return Raster(dw, dh, nc, out);
}

// ---------------------------------------------------------------------------
// Individual filters
// ---------------------------------------------------------------------------

Uint8List _grayscale(Uint8List rgb, int w, int h, Uint8List? lut) {
  final n = w * h;
  final l = lumaOf(rgb, n, 3);
  final hist = histogram(l);
  final stretch = _stretchLut(
    histogramPercentile(hist, 0.01),
    histogramPercentile(hist, 0.99),
  );
  final finalLut = _composeLut(stretch, lut);
  for (var i = 0; i < n; i++) {
    l[i] = finalLut[l[i]];
  }
  return grayToRgb(l);
}

Uint8List _blackWhite(Uint8List rgb, int w, int h, Uint8List? lut) {
  final n = w * h;
  final l = lumaOf(rgb, n, 3);
  // 1. Illumination normalisation: divide by the estimated paper level.
  final bg = _estimateBackground(l, w, h, 1);
  final normF = Float32List(n);
  for (var i = 0; i < n; i++) {
    final b = bg[i];
    final v = b < 8 ? 255.0 : l[i] * 255.0 / b;
    normF[i] = v >= 255 ? 255 : v;
  }
  // Half-strength 3x3 smoothing suppresses sensor noise before
  // thresholding without visibly thickening thin strokes.
  final smooth = boxBlurF32(normF, w, h, 1);
  final norm = Uint8List(n);
  for (var i = 0; i < n; i++) {
    norm[i] = clampByte(0.5 * (normF[i] + smooth[i]));
  }
  if (lut != null) _applyLut(norm, lut);

  // 2. Sauvola adaptive threshold using sliding box statistics.
  final radius = math.max(7, math.min(w, h) ~/ 50);
  final (mean, variance) = boxMeanVariance(norm, w, h, radius);
  const k = 0.25;
  const range = 128.0;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final v = norm[i];
    final m = mean[i];
    final t = m * (1 + k * (math.sqrt(variance[i]) / range - 1));
    // Near-paper pixels are always paper; anything darker than ~55% of the
    // paper level is always ink (prevents hollow bold strokes and blocks).
    out[i] = (v > t && v > 140) || v >= 235 ? 255 : 0;
  }
  // 3. Remove isolated single-pixel specks.
  for (var y = 1; y < h - 1; y++) {
    final row = y * w;
    for (var x = 1; x < w - 1; x++) {
      final i = row + x;
      if (out[i] == 0 &&
          out[i - 1] == 255 &&
          out[i + 1] == 255 &&
          out[i - w] == 255 &&
          out[i + w] == 255 &&
          out[i - w - 1] == 255 &&
          out[i - w + 1] == 255 &&
          out[i + w - 1] == 255 &&
          out[i + w + 1] == 255) {
        out[i] = 255;
      }
    }
  }
  return grayToRgb(out);
}

Uint8List _whiteboard(Uint8List rgb, int w, int h, Uint8List? lut) {
  final n = w * h;
  final bg = _estimateBackground(rgb, w, h, 3);
  final out = Uint8List(n * 3);
  // Normalise each channel by its own background (removes color cast and
  // shading), push near-white to white and boost ink saturation.
  const white = 232.0;
  const sat = 1.5;
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    var r = _ratio(rgb[j], bg[j]);
    var g = _ratio(rgb[j + 1], bg[j + 1]);
    var b = _ratio(rgb[j + 2], bg[j + 2]);
    r = r * 255 / white;
    g = g * 255 / white;
    b = b * 255 / white;
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    // Darken ink slightly with a gamma curve to keep strokes bold.
    final yy = y >= 255 ? 255.0 : 255.0 * math.pow(y / 255.0, 1.3);
    final gain = y > 1 ? yy / y : 1.0;
    out[j] = clampByte((y + (r - y) * sat) * gain);
    out[j + 1] = clampByte((y + (g - y) * sat) * gain);
    out[j + 2] = clampByte((y + (b - y) * sat) * gain);
  }
  if (lut != null) _applyLut(out, lut);
  return out;
}

/// Paper luminance targeted by the auto color lighting correction.
const double _paperTarget = 242;

Uint8List _autoColor(Uint8List rgb, int w, int h, Uint8List? lut) {
  final n = w * h;
  final bg = _estimateBackground(rgb, w, h, 3);

  // Global white balance from the brightest background areas.
  final bgLuma = lumaOf(bg, n, 3);
  final cut = histogramPercentile(histogram(bgLuma), 0.8);
  var sr = 0.0, sg = 0.0, sb = 0.0, cnt = 0;
  for (var i = 0, j = 0; i < n; i += 7, j += 21) {
    if (bgLuma[i] >= cut) {
      sr += bg[j];
      sg += bg[j + 1];
      sb += bg[j + 2];
      cnt++;
    }
  }
  var wbR = 1.0, wbG = 1.0, wbB = 1.0;
  if (cnt > 0 && sr > 0 && sg > 0 && sb > 0) {
    final pr = sr / cnt, pg = sg / cnt, pb = sb / cnt;
    final pl = 0.299 * pr + 0.587 * pg + 0.114 * pb;
    wbR = (pl / pr).clamp(0.6, 1.6);
    wbG = (pl / pg).clamp(0.6, 1.6);
    wbB = (pl / pb).clamp(0.6, 1.6);
  }

  // Lighting correction (local luminance gain) + white balance.
  final tmp = Uint8List(n * 3);
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    final bl = bgLuma[i];
    final gain = bl < 8 ? 1.0 : (_paperTarget / bl).clamp(0.85, 3.0);
    tmp[j] = clampByte(rgb[j] * wbR * gain);
    tmp[j + 1] = clampByte(rgb[j + 1] * wbG * gain);
    tmp[j + 2] = clampByte(rgb[j + 2] * wbB * gain);
  }

  // Contrast stretch on luminance percentiles, same mapping for all
  // channels to preserve hue.
  // The white point never exceeds the paper target, so paper ends up white
  // instead of noisy; the gain is limited to avoid amplifying noise.
  final lumHist = histogram(lumaOf(tmp, n, 3));
  final hi = math.min(histogramPercentile(lumHist, 0.99), _paperTarget.round());
  final lo = math.min(histogramPercentile(lumHist, 0.01), hi - 102);
  _applyLut(tmp, _stretchLut(lo, hi));

  // Mild unsharp mask.
  final out = _unsharp(tmp, w, h, 0.6);
  if (lut != null) _applyLut(out, lut);
  return out;
}

Uint8List _photo(Uint8List rgb, int w, int h, Uint8List? lut) {
  final n = w * h;
  // Gentle S-curve for contrast.
  final curve = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    final x = v / 255.0;
    final s = x * x * (3 - 2 * x);
    curve[v] = clampByte(255 * (x + 0.35 * (s - x)));
  }
  final finalLut = _composeLut(curve, lut);
  final out = Uint8List(n * 3);
  for (var j = 0; j < n * 3; j += 3) {
    final r = rgb[j], g = rgb[j + 1], b = rgb[j + 2];
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    // Vibrance: boost low-saturation pixels more than saturated ones.
    final satNow = mx == 0 ? 0.0 : (mx - mn) / mx;
    final f = 1.0 + 0.4 * (1 - satNow);
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    out[j] = finalLut[clampByte(y + (r - y) * f)];
    out[j + 1] = finalLut[clampByte(y + (g - y) * f)];
    out[j + 2] = finalLut[clampByte(y + (b - y) * f)];
  }
  return out;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Estimates the slowly varying paper background of an interleaved buffer
/// with [nc] channels.
///
/// Works on a ~200 px copy. Two estimates are combined per channel:
/// * a local one (morphological closing + box blur) that follows shadows
///   and removes text, and
/// * a global, robustly fitted quadratic lighting surface that ignores
///   regions darker than the paper (iteratively re-weighted).
/// The local estimate is used where it agrees with the surface; where it is
/// much darker (large photos, color blocks, bold bars) the surface is used,
/// so such regions keep their color instead of being bleached.
/// The result is bilinearly upscaled to full size.
Uint8List _estimateBackground(Uint8List src, int w, int h, int nc) {
  final (sw, sh) = fitWithin(w, h, 200);
  final small = resizeArea(src, w, h, nc, sw, sh);
  final n = sw * sh;
  final result = Uint8List(n * nc);
  final plane = Float32List(n);
  for (var c = 0; c < nc; c++) {
    for (var i = 0; i < n; i++) {
      plane[i] = small[i * nc + c].toDouble();
    }
    var local = rankFilterF32(plane, sw, sh, 3, true);
    local = rankFilterF32(local, sw, sh, 2, false);
    local = boxBlurF32(local, sw, sh, 3);
    final surface = _fitLightingSurface(local, sw, sh);
    final blended = Float32List(n);
    for (var i = 0; i < n; i++) {
      final f = surface[i];
      final l = local[i];
      if (f <= 1) {
        blended[i] = l;
        continue;
      }
      // Weight 1 when local >= 85% of the surface, 0 below 70%.
      final wgt = ((l / f - 0.7) / 0.15).clamp(0.0, 1.0);
      blended[i] = wgt * l + (1 - wgt) * f;
    }
    final smooth = boxBlurF32(blended, sw, sh, 2);
    for (var i = 0; i < n; i++) {
      result[i * nc + c] = clampByte(smooth[i]);
    }
  }
  if (sw == w && sh == h) return result;
  return resizeBilinear(result, sw, sh, nc, w, h);
}

/// Robust least-squares fit of `a + bx + cy + dx^2 + exy + fy^2` to the
/// paper samples of [plane]; samples clearly darker than the current fit
/// are discarded on each iteration. Returns the evaluated surface.
Float32List _fitLightingSurface(Float32List plane, int w, int h) {
  final xs = <double>[], ys = <double>[], vs = <double>[];
  final step = math.max(1, math.min(w, h) ~/ 40);
  for (var y = 0; y < h; y += step) {
    for (var x = 0; x < w; x += step) {
      xs.add(2 * x / math.max(1, w - 1) - 1);
      ys.add(2 * y / math.max(1, h - 1) - 1);
      vs.add(plane[y * w + x]);
    }
  }
  final keep = List<bool>.filled(vs.length, true);
  var coef = List<double>.filled(6, 0);
  // Start from the bright half so dark objects do not drag the first fit.
  final sorted = List.of(vs)..sort();
  final median = sorted[sorted.length ~/ 2];
  for (var i = 0; i < vs.length; i++) {
    keep[i] = vs[i] >= median;
  }
  for (var iter = 0; iter < 5; iter++) {
    final fit = _solveQuadratic(xs, ys, vs, keep);
    if (fit == null) break;
    coef = fit;
    var changed = false;
    for (var i = 0; i < vs.length; i++) {
      final f = _evalQuadratic(coef, xs[i], ys[i]);
      final k = vs[i] >= f - math.max(8.0, 0.1 * f);
      if (k != keep[i]) changed = true;
      keep[i] = k;
    }
    if (!changed) break;
  }
  final out = Float32List(w * h);
  if (coef.every((c) => c == 0)) {
    out.fillRange(0, out.length, median);
    return out;
  }
  for (var y = 0; y < h; y++) {
    final ny = 2 * y / math.max(1, h - 1) - 1;
    for (var x = 0; x < w; x++) {
      final nx = 2 * x / math.max(1, w - 1) - 1;
      out[y * w + x] = _evalQuadratic(coef, nx, ny).clamp(1.0, 255.0);
    }
  }
  return out;
}

double _evalQuadratic(List<double> c, double x, double y) =>
    c[0] + c[1] * x + c[2] * y + c[3] * x * x + c[4] * x * y + c[5] * y * y;

List<double>? _solveQuadratic(
  List<double> xs,
  List<double> ys,
  List<double> vs,
  List<bool> keep,
) {
  // Normal equations (6x6) solved by Gaussian elimination.
  final a = List.generate(6, (_) => List<double>.filled(7, 0));
  var count = 0;
  for (var i = 0; i < vs.length; i++) {
    if (!keep[i]) continue;
    count++;
    final x = xs[i], y = ys[i];
    final b = [1.0, x, y, x * x, x * y, y * y];
    for (var r = 0; r < 6; r++) {
      for (var c = 0; c < 6; c++) {
        a[r][c] += b[r] * b[c];
      }
      a[r][6] += b[r] * vs[i];
    }
  }
  if (count < 12) return null;
  for (var col = 0; col < 6; col++) {
    var piv = col;
    for (var r = col + 1; r < 6; r++) {
      if (a[r][col].abs() > a[piv][col].abs()) piv = r;
    }
    if (a[piv][col].abs() < 1e-9) return null;
    final t = a[piv];
    a[piv] = a[col];
    a[col] = t;
    for (var r = col + 1; r < 6; r++) {
      final f = a[r][col] / a[col][col];
      for (var c = col; c < 7; c++) {
        a[r][c] -= f * a[col][c];
      }
    }
  }
  final x = List<double>.filled(6, 0);
  for (var r = 5; r >= 0; r--) {
    var v = a[r][6];
    for (var c = r + 1; c < 6; c++) {
      v -= a[r][c] * x[c];
    }
    x[r] = v / a[r][r];
  }
  return x;
}

double _ratio(int v, int bg) {
  if (bg < 8) return v.toDouble();
  return v * 255.0 / bg;
}

Uint8List _unsharp(Uint8List rgb, int w, int h, double amount) {
  final n = w * h;
  final out = Uint8List(n * 3);
  final plane = Float32List(n);
  for (var c = 0; c < 3; c++) {
    for (var i = 0; i < n; i++) {
      plane[i] = rgb[i * 3 + c].toDouble();
    }
    final blur = boxBlurF32(plane, w, h, 1);
    for (var i = 0; i < n; i++) {
      final v = plane[i];
      out[i * 3 + c] = clampByte(v + amount * (v - blur[i]));
    }
  }
  return out;
}

Uint8List _stretchLut(int lo, int hi) {
  final lut = Uint8List(256);
  if (hi - lo < 16) {
    // Too little range to stretch safely; keep identity.
    for (var v = 0; v < 256; v++) {
      lut[v] = v;
    }
    return lut;
  }
  final scale = 255.0 / (hi - lo);
  for (var v = 0; v < 256; v++) {
    lut[v] = clampByte((v - lo) * scale);
  }
  return lut;
}

Uint8List _composeLut(Uint8List first, Uint8List? second) {
  if (second == null) return first;
  final out = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    out[v] = second[first[v]];
  }
  return out;
}

void _applyLut(Uint8List data, Uint8List lut) {
  for (var i = 0; i < data.length; i++) {
    data[i] = lut[data[i]];
  }
}
