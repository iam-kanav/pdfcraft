/// Isolate-friendly entry points of the scanner image pipeline.
///
/// Every function takes and returns only sendable values (`Uint8List`, `num`,
/// `String`, `List`, `Map`) so the UI can run them off the main thread:
///
/// ```dart
/// final result = await Isolate.run(() => detectQuadFromBytes(bytes));
/// final jpeg = await Isolate.run(() => processScanBytes(request));
/// ```
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'edge_detector.dart';
import 'filters.dart';
import 'geometry.dart';
import 'perspective.dart';
import 'raster.dart';

/// Parameters for [processScanBytes]. All fields are sendable.
class ScanRequest {
  /// Creates a request.
  ScanRequest({
    required this.imageBytes,
    this.quad,
    this.filter = 'original',
    this.rotation = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.maxDimension = 2400,
    this.jpegQuality = 88,
  });

  /// Encoded source photo (JPEG/PNG/...). EXIF orientation is honoured.
  Uint8List imageBytes;

  /// Document corners ([Quad.toJson]) in the coordinates of the
  /// orientation-corrected image (as returned by [detectQuadFromBytes]).
  /// Null keeps the whole image.
  Map<String, dynamic>? quad;

  /// [ScanFilter] name, e.g. `'blackWhite'`. Unknown names mean original.
  String filter;

  /// Clockwise rotation applied after filtering: degrees (multiples of 90,
  /// e.g. 90, 180, 270, -90) or, for values in -3..3, quarter turns.
  int rotation;

  /// Brightness adjustment in `[-1, 1]`.
  double brightness;

  /// Contrast adjustment in `[-1, 1]`.
  double contrast;

  /// Longest side of the output image in pixels.
  int maxDimension;

  /// JPEG quality (1-100).
  int jpegQuality;
}

/// Decodes [encoded], bakes its EXIF orientation and detects the document.
///
/// Returns `{'quad': quad.toJson(), 'width': w, 'height': h}` (coordinates
/// relative to the oriented `w x h` image) or null when the bytes cannot be
/// decoded or no document is found.
Future<Map<String, dynamic>?> detectQuadFromBytes(Uint8List encoded) async {
  final image = decodeOriented(encoded);
  if (image == null) return null;
  final quad = detectDocumentQuad(image);
  if (quad == null) return null;
  return {'quad': quad.toJson(), 'width': image.width, 'height': image.height};
}

/// Runs the full scan pipeline and returns JPEG bytes:
/// decode + bake orientation -> perspective warp (if a quad is given) ->
/// downscale to `maxDimension` -> filter -> rotate -> JPEG encode.
///
/// (Downscaling happens before filtering; the result is equivalent and
/// filtering fewer pixels is considerably faster.)
/// Throws [FormatException] when the image cannot be decoded.
Future<Uint8List> processScanBytes(ScanRequest r) async {
  final image = decodeOriented(r.imageBytes);
  if (image == null) {
    throw const FormatException('Unsupported or corrupt image data');
  }
  final maxDim = r.maxDimension < 1 ? 1 : r.maxDimension;
  var raster = Raster.fromImage(image);

  if (r.quad != null) {
    final quad = Quad.fromJson(r.quad!).clampTo(image.width, image.height);
    if (quad.isConvex && quad.area >= 16) {
      final (natW, natH) = warpOutputSize(quad);
      final (w, h) = fitWithin(natW, natH, maxDim);
      // Warp straight to the target size unless that would alias badly; in
      // that case warp at native size and area-downscale afterwards.
      raster = (natW > w * 1.5 || natH > h * 1.5)
          ? warpRaster(raster, quad, natW, natH)
          : warpRaster(raster, quad, w, h);
    }
  }
  raster = fitRaster(raster, maxDim);

  final filter = ScanFilter.fromName(r.filter);
  final filtered = filterRgb(raster.data, raster.width, raster.height, filter, r.brightness, r.contrast);
  var out = Raster(raster.width, raster.height, 3, filtered);

  final turns = _quarterTurns(r.rotation);
  if (turns != 0) out = rotateRaster(out, turns);

  return img.encodeJpg(out.toImage(), quality: r.jpegQuality.clamp(1, 100));
}

/// Decodes [encoded] (EXIF orientation applied) and returns a JPEG whose
/// longest side is at most [maxDim].
Future<Uint8List> makeThumbnail(Uint8List encoded, {int maxDim = 400}) async {
  final image = decodeOriented(encoded);
  if (image == null) {
    throw const FormatException('Unsupported or corrupt image data');
  }
  final small = fitRaster(Raster.fromImage(image), maxDim < 1 ? 1 : maxDim);
  return img.encodeJpg(small.toImage(), quality: 80);
}

/// Decodes an encoded image and applies its EXIF orientation.
img.Image? decodeOriented(Uint8List encoded) {
  img.Image? image;
  try {
    image = img.decodeImage(encoded);
  } on Object {
    return null;
  }
  if (image == null) return null;
  if (image.exif.imageIfd.hasOrientation && image.exif.imageIfd.orientation != 1) {
    image = img.bakeOrientation(image);
  }
  return image;
}

int _quarterTurns(int rotation) {
  if (rotation >= -3 && rotation <= 3) return rotation;
  return (rotation / 90).round();
}
