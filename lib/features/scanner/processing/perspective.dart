/// Perspective correction ("unwarping") of a document quad into a rectangle.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'geometry.dart';
import 'raster.dart';

/// Longest output side produced by [warpPerspective] when no explicit size
/// is requested.
const int kMaxWarpSide = 3000;

/// Output size `(width, height)` [warpPerspective] would choose for [quad]:
/// the longer of each pair of opposite edges, with the longest side capped
/// at [maxSide].
(int, int) warpOutputSize(Quad quad, {int maxSide = kMaxWarpSide}) {
  var w = math.max(quad.tl.distanceTo(quad.tr), quad.bl.distanceTo(quad.br));
  var h = math.max(quad.tl.distanceTo(quad.bl), quad.tr.distanceTo(quad.br));
  w = math.max(w, 1);
  h = math.max(h, 1);
  final longest = math.max(w, h);
  if (longest > maxSide) {
    final s = maxSide / longest;
    w *= s;
    h *= s;
  }
  return (math.max(1, w.round()), math.max(1, h.round()));
}

/// Maps the [quad] region of [src] onto an upright rectangle.
///
/// When neither [outWidth] nor [outHeight] is given the size comes from
/// [warpOutputSize]; when only one is given the other keeps the quad's
/// aspect ratio. Uses inverse mapping with bilinear interpolation and
/// clamp-to-edge sampling. The output has the same channel count as [src]
/// when it is an 8-bit RGB/RGBA image, RGB otherwise.
img.Image warpPerspective(img.Image src, Quad quad, {int? outWidth, int? outHeight}) {
  final raster = Raster.fromImage(src, allowAlpha: true);
  final (natW, natH) = warpOutputSize(quad);
  int dw, dh;
  if (outWidth != null && outHeight != null) {
    dw = outWidth;
    dh = outHeight;
  } else if (outWidth != null) {
    dw = outWidth;
    dh = math.max(1, (outWidth * natH / natW).round());
  } else if (outHeight != null) {
    dh = outHeight;
    dw = math.max(1, (outHeight * natW / natH).round());
  } else {
    dw = natW;
    dh = natH;
  }
  if (dw <= 0 || dh <= 0) {
    throw ArgumentError('Output size must be positive (got ${dw}x$dh)');
  }
  return warpRaster(raster, quad, dw, dh).toImage();
}

/// Raw-buffer implementation of [warpPerspective].
Raster warpRaster(Raster src, Quad quad, int dw, int dh) {
  final sw = src.width;
  final sh = src.height;
  final nc = src.channels;
  final s = src.data;
  final out = Uint8List(dw * dh * nc);

  // Homography from destination rectangle to the source quad.
  final h = computeHomography([
    const math.Point(0.0, 0.0),
    math.Point(dw.toDouble(), 0.0),
    math.Point(dw.toDouble(), dh.toDouble()),
    math.Point(0.0, dh.toDouble()),
  ], quad.points);
  final h0 = h[0], h1 = h[1], h2 = h[2];
  final h3 = h[3], h4 = h[4], h5 = h[5];
  final h6 = h[6], h7 = h[7], h8 = h[8];
  final maxX = (sw - 1).toDouble();
  final maxY = (sh - 1).toDouble();
  final rowStride = sw * nc;

  var o = 0;
  for (var y = 0; y < dh; y++) {
    final yc = y + 0.5;
    // Evaluate at the first pixel centre (x = 0.5), then step by one pixel.
    var nx = h0 * 0.5 + h1 * yc + h2;
    var ny = h3 * 0.5 + h4 * yc + h5;
    var nw = h6 * 0.5 + h7 * yc + h8;
    for (var x = 0; x < dw; x++) {
      final iw = 1.0 / nw;
      // Continuous source coordinates -> pixel-centre index space.
      var u = nx * iw - 0.5;
      var v = ny * iw - 0.5;
      nx += h0;
      ny += h3;
      nw += h6;
      if (u < 0) u = 0;
      if (u > maxX) u = maxX;
      if (v < 0) v = 0;
      if (v > maxY) v = maxY;
      final x0 = u.toInt();
      final y0 = v.toInt();
      final fx = u - x0;
      final fy = v - y0;
      final p00 = y0 * rowStride + x0 * nc;
      final p01 = x0 < sw - 1 ? p00 + nc : p00;
      final p10 = y0 < sh - 1 ? p00 + rowStride : p00;
      final p11 = x0 < sw - 1 ? p10 + nc : p10;
      final w00 = (1 - fx) * (1 - fy);
      final w01 = fx * (1 - fy);
      final w10 = (1 - fx) * fy;
      final w11 = fx * fy;
      for (var c = 0; c < nc; c++) {
        out[o++] = (s[p00 + c] * w00 + s[p01 + c] * w01 + s[p10 + c] * w10 + s[p11 + c] * w11 + 0.5).toInt();
      }
    }
  }
  return Raster(dw, dh, nc, out);
}
