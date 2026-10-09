/// Low-level raster helpers shared by the scanner processing code.
///
/// Everything here works on raw interleaved `Uint8List` / `Float32List`
/// buffers so that the hot loops avoid the per-pixel object APIs of
/// `package:image`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A tightly packed, interleaved 8-bit raster (`width * height * channels`).
class Raster {
  /// Wraps [data] (not copied).
  Raster(this.width, this.height, this.channels, this.data)
    : assert(data.length >= width * height * channels);

  /// Allocates a zero-filled raster.
  Raster.alloc(this.width, this.height, this.channels)
    : data = Uint8List(width * height * channels);

  /// Returns a raster view of [src].
  ///
  /// When [src] already is an 8-bit image with 3 channels (or 4 channels and
  /// [allowAlpha] is true) without palette, the pixel buffer is shared with
  /// [src] (no copy), so callers must not modify it in place. Any other
  /// format is converted to 8-bit RGB.
  factory Raster.fromImage(img.Image src, {bool allowAlpha = false}) {
    final nc = src.numChannels;
    if (src.format == img.Format.uint8 &&
        !src.hasPalette &&
        (nc == 3 || (allowAlpha && nc == 4)) &&
        src.rowStride == src.width * nc) {
      return Raster(src.width, src.height, nc, src.toUint8List());
    }
    final converted = src.convert(format: img.Format.uint8, numChannels: 3);
    final bytes = converted.getBytes(order: img.ChannelOrder.rgb);
    return Raster(src.width, src.height, 3, bytes);
  }

  /// Pixel width.
  final int width;

  /// Pixel height.
  final int height;

  /// Number of interleaved channels (1, 3 or 4).
  final int channels;

  /// Pixel bytes, row-major, no row padding.
  final Uint8List data;

  /// Wraps the buffer into an [img.Image] (shares the buffer).
  img.Image toImage() => img.Image.fromBytes(
    width: width,
    height: height,
    bytes: data.buffer,
    bytesOffset: data.offsetInBytes,
    numChannels: channels,
  );
}

/// Rec. 601 luma of an interleaved RGB(A) buffer, as one byte per pixel.
Uint8List lumaOf(Uint8List rgb, int pixelCount, int channels) {
  final out = Uint8List(pixelCount);
  for (var i = 0, j = 0; i < pixelCount; i++, j += channels) {
    out[i] = (rgb[j] * 77 + rgb[j + 1] * 150 + rgb[j + 2] * 29 + 128) >> 8;
  }
  return out;
}

/// Expands a single-channel plane to interleaved RGB.
Uint8List grayToRgb(Uint8List gray) {
  final out = Uint8List(gray.length * 3);
  for (var i = 0, j = 0; i < gray.length; i++, j += 3) {
    final v = gray[i];
    out[j] = v;
    out[j + 1] = v;
    out[j + 2] = v;
  }
  return out;
}

/// Computes the size that fits `width x height` into a box whose longest
/// side is [maxSide], keeping the aspect ratio. Never upscales.
(int, int) fitWithin(int width, int height, int maxSide) {
  final longest = math.max(width, height);
  if (longest <= maxSide) return (width, height);
  final s = maxSide / longest;
  return (math.max(1, (width * s).round()), math.max(1, (height * s).round()));
}

/// Precomputed 1-D area-averaging (box) resampling weights.
class _AreaWeights {
  _AreaWeights(int srcLen, int dstLen)
    : start = Int32List(dstLen),
      count = Int32List(dstLen),
      offset = Int32List(dstLen) {
    final scale = srcLen / dstLen;
    final ws = <double>[];
    for (var d = 0; d < dstLen; d++) {
      final a = d * scale;
      final b = (d + 1) * scale;
      var i0 = a.floor();
      var i1 = b.ceil() - 1;
      if (i0 < 0) i0 = 0;
      if (i1 > srcLen - 1) i1 = srcLen - 1;
      if (i1 < i0) i1 = i0;
      start[d] = i0;
      count[d] = i1 - i0 + 1;
      offset[d] = ws.length;
      var total = 0.0;
      final first = ws.length;
      for (var i = i0; i <= i1; i++) {
        final w = math.min(b, i + 1.0) - math.max(a, i.toDouble());
        final ww = w > 0 ? w : 0.0;
        ws.add(ww);
        total += ww;
      }
      if (total <= 0) {
        ws[first] = 1;
        total = 1;
      }
      for (var k = first; k < ws.length; k++) {
        ws[k] /= total;
      }
    }
    weights = Float32List.fromList(ws);
  }

  final Int32List start;
  final Int32List count;
  final Int32List offset;
  late final Float32List weights;
}

/// Downscales an interleaved buffer with area averaging (anti-aliased).
///
/// Works for any target size but is intended for `dw <= sw`, `dh <= sh`;
/// use [resizeBuffer] to pick the right method automatically.
Uint8List resizeArea(Uint8List src, int sw, int sh, int nc, int dw, int dh) {
  final hx = _AreaWeights(sw, dw);
  final hy = _AreaWeights(sh, dh);
  final out = Uint8List(dw * dh * nc);
  final rowLen = dw * nc;
  final acc = Float32List(rowLen);
  var cacheA = Float32List(rowLen);
  var cacheB = Float32List(rowLen);
  var cacheARow = -1;
  var cacheBRow = -1;

  void resampleRow(int sy, Float32List dst) {
    final base = sy * sw * nc;
    for (var x = 0; x < dw; x++) {
      final s0 = hx.start[x];
      final cnt = hx.count[x];
      final off = hx.offset[x];
      final o = x * nc;
      for (var c = 0; c < nc; c++) {
        var sum = 0.0;
        var p = base + s0 * nc + c;
        for (var k = 0; k < cnt; k++, p += nc) {
          sum += src[p] * hx.weights[off + k];
        }
        dst[o + c] = sum;
      }
    }
  }

  for (var y = 0; y < dh; y++) {
    acc.fillRange(0, rowLen, 0);
    final s0 = hy.start[y];
    final cnt = hy.count[y];
    final off = hy.offset[y];
    for (var k = 0; k < cnt; k++) {
      final sy = s0 + k;
      Float32List row;
      if (sy == cacheARow) {
        row = cacheA;
      } else if (sy == cacheBRow) {
        row = cacheB;
      } else {
        // Evict the older cache entry (rows are visited in increasing order).
        final tmp = cacheA;
        cacheA = cacheB;
        cacheARow = cacheBRow;
        cacheB = tmp;
        cacheBRow = sy;
        resampleRow(sy, cacheB);
        row = cacheB;
      }
      final w = hy.weights[off + k];
      for (var i = 0; i < rowLen; i++) {
        acc[i] += row[i] * w;
      }
    }
    final o = y * rowLen;
    for (var i = 0; i < rowLen; i++) {
      final v = acc[i] + 0.5;
      out[o + i] = v >= 255 ? 255 : (v <= 0 ? 0 : v.toInt());
    }
  }
  return out;
}

/// Resizes an interleaved buffer with bilinear interpolation (pixel-center
/// aligned). Suitable for upscaling or mild downscaling.
Uint8List resizeBilinear(
  Uint8List src,
  int sw,
  int sh,
  int nc,
  int dw,
  int dh,
) {
  final out = Uint8List(dw * dh * nc);
  final sxScale = sw / dw;
  final syScale = sh / dh;
  final x0s = Int32List(dw);
  final x1s = Int32List(dw);
  final fxs = Float32List(dw);
  for (var x = 0; x < dw; x++) {
    var u = (x + 0.5) * sxScale - 0.5;
    if (u < 0) u = 0;
    if (u > sw - 1) u = (sw - 1).toDouble();
    final x0 = u.floor();
    x0s[x] = x0 * nc;
    x1s[x] = (x0 < sw - 1 ? x0 + 1 : x0) * nc;
    fxs[x] = u - x0;
  }
  var o = 0;
  for (var y = 0; y < dh; y++) {
    var v = (y + 0.5) * syScale - 0.5;
    if (v < 0) v = 0;
    if (v > sh - 1) v = (sh - 1).toDouble();
    final y0 = v.floor();
    final y1 = y0 < sh - 1 ? y0 + 1 : y0;
    final fy = v - y0;
    final r0 = y0 * sw * nc;
    final r1 = y1 * sw * nc;
    for (var x = 0; x < dw; x++) {
      final fx = fxs[x];
      final a = x0s[x];
      final b = x1s[x];
      for (var c = 0; c < nc; c++) {
        final top = src[r0 + a + c] + (src[r0 + b + c] - src[r0 + a + c]) * fx;
        final bot = src[r1 + a + c] + (src[r1 + b + c] - src[r1 + a + c]) * fx;
        out[o++] = (top + (bot - top) * fy + 0.5).toInt();
      }
    }
  }
  return out;
}

/// Resizes with area averaging when shrinking and bilinear otherwise.
Uint8List resizeBuffer(Uint8List src, int sw, int sh, int nc, int dw, int dh) {
  if (dw == sw && dh == sh) return Uint8List.fromList(src);
  if (dw <= sw && dh <= sh) return resizeArea(src, sw, sh, nc, dw, dh);
  return resizeBilinear(src, sw, sh, nc, dw, dh);
}

/// Resizes a raster so that its longest side is at most [maxSide].
Raster fitRaster(Raster r, int maxSide) {
  final (w, h) = fitWithin(r.width, r.height, maxSide);
  if (w == r.width && h == r.height) return r;
  return Raster(
    w,
    h,
    r.channels,
    resizeArea(r.data, r.width, r.height, r.channels, w, h),
  );
}

/// Separable box blur of a float plane with radius [r] (window `2r+1`),
/// clamp-to-edge borders. O(1) per pixel regardless of [r].
Float32List boxBlurF32(Float32List src, int w, int h, int r) {
  if (r <= 0) return Float32List.fromList(src);
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);
  final inv = 1.0 / (2 * r + 1);
  // Horizontal.
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var sum = 0.0;
    for (var k = -r; k <= r; k++) {
      sum += src[row + _clampI(k, 0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] = sum * inv;
      final add = _clampI(x + r + 1, 0, w - 1);
      final sub = _clampI(x - r, 0, w - 1);
      sum += src[row + add] - src[row + sub];
    }
  }
  // Vertical.
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    for (var k = -r; k <= r; k++) {
      sum += tmp[_clampI(k, 0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = sum * inv;
      final add = _clampI(y + r + 1, 0, h - 1);
      final sub = _clampI(y - r, 0, h - 1);
      sum += tmp[add * w + x] - tmp[sub * w + x];
    }
  }
  return out;
}

/// Box-filtered local mean and variance of an 8-bit plane, computed with
/// integer sliding-window sums (exact, O(1) per pixel).
///
/// Returns `(mean, variance)` planes.
(Float32List, Float32List) boxMeanVariance(Uint8List src, int w, int h, int r) {
  final n = w * h;
  final hs = Int32List(n);
  final hq = Int32List(n);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var s = 0;
    var q = 0;
    for (var k = -r; k <= r; k++) {
      final v = src[row + _clampI(k, 0, w - 1)];
      s += v;
      q += v * v;
    }
    for (var x = 0; x < w; x++) {
      hs[row + x] = s;
      hq[row + x] = q;
      final a = src[row + _clampI(x + r + 1, 0, w - 1)];
      final b = src[row + _clampI(x - r, 0, w - 1)];
      s += a - b;
      q += a * a - b * b;
    }
  }
  final mean = Float32List(n);
  final variance = Float32List(n);
  final area = (2 * r + 1) * (2 * r + 1);
  final inv = 1.0 / area;
  // Vertical pass over whole rows at a time (cache friendly).
  final colS = Float64List(w);
  final colQ = Float64List(w);
  for (var k = -r; k <= r; k++) {
    final row = _clampI(k, 0, h - 1) * w;
    for (var x = 0; x < w; x++) {
      colS[x] += hs[row + x];
      colQ[x] += hq[row + x];
    }
  }
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final m = colS[x] * inv;
      mean[row + x] = m;
      final v = colQ[x] * inv - m * m;
      variance[row + x] = v > 0 ? v : 0;
    }
    final addRow = _clampI(y + r + 1, 0, h - 1) * w;
    final subRow = _clampI(y - r, 0, h - 1) * w;
    for (var x = 0; x < w; x++) {
      colS[x] += hs[addRow + x] - hs[subRow + x];
      colQ[x] += hq[addRow + x] - hq[subRow + x];
    }
  }
  return (mean, variance);
}

/// Separable Gaussian blur of a float plane (clamp-to-edge borders).
/// Intended for small (analysis-sized) planes.
Float32List gaussianBlurF32(Float32List src, int w, int h, double sigma) {
  final radius = math.max(1, (sigma * 3).ceil());
  final kernel = Float32List(2 * radius + 1);
  var total = 0.0;
  for (var i = -radius; i <= radius; i++) {
    final v = math.exp(-(i * i) / (2 * sigma * sigma));
    kernel[i + radius] = v;
    total += v;
  }
  for (var i = 0; i < kernel.length; i++) {
    kernel[i] /= total;
  }
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var k = -radius; k <= radius; k++) {
        s += src[row + _clampI(x + k, 0, w - 1)] * kernel[k + radius];
      }
      tmp[row + x] = s;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var k = -radius; k <= radius; k++) {
        s += tmp[_clampI(y + k, 0, h - 1) * w + x] * kernel[k + radius];
      }
      out[y * w + x] = s;
    }
  }
  return out;
}

/// Grayscale morphological max (dilation, [isMax] true) or min (erosion)
/// filter with a square window of radius [r]. Separable; intended for small
/// planes.
Float32List rankFilterF32(Float32List src, int w, int h, int r, bool isMax) {
  if (r <= 0) return Float32List.fromList(src);
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final a = math.max(0, x - r);
      final b = math.min(w - 1, x + r);
      var m = src[row + a];
      for (var k = a + 1; k <= b; k++) {
        final v = src[row + k];
        if (isMax ? v > m : v < m) m = v;
      }
      tmp[row + x] = m;
    }
  }
  for (var y = 0; y < h; y++) {
    final a = math.max(0, y - r);
    final b = math.min(h - 1, y + r);
    for (var x = 0; x < w; x++) {
      var m = tmp[a * w + x];
      for (var k = a + 1; k <= b; k++) {
        final v = tmp[k * w + x];
        if (isMax ? v > m : v < m) m = v;
      }
      out[y * w + x] = m;
    }
  }
  return out;
}

/// 256-bin histogram of an 8-bit buffer, reading every [stride]-th byte
/// starting at [offset].
Int32List histogram(Uint8List data, {int offset = 0, int stride = 1}) {
  final hist = Int32List(256);
  for (var i = offset; i < data.length; i += stride) {
    hist[data[i]]++;
  }
  return hist;
}

/// Value below which [fraction] (0..1) of the histogram mass lies.
int histogramPercentile(Int32List hist, double fraction) {
  var total = 0;
  for (final c in hist) {
    total += c;
  }
  if (total == 0) return 0;
  final target = fraction * total;
  var acc = 0;
  for (var i = 0; i < hist.length; i++) {
    acc += hist[i];
    if (acc >= target) return i;
  }
  return hist.length - 1;
}

/// Otsu's threshold for a histogram (returns the bin index `t` such that
/// the classes are `<= t` and `> t`).
int otsuThreshold(List<num> hist) {
  var total = 0.0;
  var sumAll = 0.0;
  for (var i = 0; i < hist.length; i++) {
    total += hist[i];
    sumAll += i * hist[i];
  }
  if (total == 0) return hist.length ~/ 2;
  var wB = 0.0;
  var sumB = 0.0;
  var best = -1.0;
  var bestT = 0;
  for (var t = 0; t < hist.length; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sumAll - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      bestT = t;
    }
  }
  return bestT;
}

/// Builds a 256-entry lookup table applying brightness and contrast, both in
/// `[-1, 1]`. Returns null when both are (near) zero.
Uint8List? brightnessContrastLut(double brightness, double contrast) {
  final b = brightness.clamp(-1.0, 1.0);
  final c = contrast.clamp(-1.0, 1.0);
  if (b.abs() < 1e-4 && c.abs() < 1e-4) return null;
  final factor = c >= 0 ? 1 + 2 * c : 1 + c;
  final offset = b * 110;
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    lut[v] = clampByte((v - 127.5) * factor + 127.5 + offset);
  }
  return lut;
}

/// Rounds and clamps to `0..255`.
int clampByte(num v) {
  if (v <= 0) return 0;
  if (v >= 255) return 255;
  return (v + 0.5).toInt();
}

int _clampI(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
