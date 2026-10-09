import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'convert_utils.dart';

/// Page size used when converting images to PDF.
enum ImagePageSize {
  /// Each page takes the image's aspect ratio; the longer side is 842 pt
  /// (A4 height) plus margins.
  fitImage,

  /// ISO A4, image centred and scaled to fit within the margins.
  a4,

  /// US Letter, image centred and scaled to fit within the margins.
  letter,
}

/// Page orientation for fixed page sizes ([ImagePageSize.a4] /
/// [ImagePageSize.letter]). Ignored for [ImagePageSize.fitImage].
enum PdfPageOrientationMode {
  /// Landscape for images wider than tall, portrait otherwise.
  auto,
  portrait,
  landscape,
}

/// Length of the longer page side for [ImagePageSize.fitImage], in points.
const double fitImageLongSide = 842;

/// Builds a PDF with one page per image.
///
/// JPEG data is embedded as-is (no recompression); its EXIF orientation is
/// applied through the PDF image transform. Other formats (PNG, WebP, BMP,
/// GIF, TIFF, ...) are decoded, their EXIF orientation baked in, and
/// embedded losslessly. Throws [ArgumentError] for an empty list and
/// [FormatException] if an image cannot be decoded.
Future<Uint8List> buildPdfFromImages(
  List<Uint8List> images, {
  ImagePageSize pageSize = ImagePageSize.fitImage,
  PdfPageOrientationMode orientation = PdfPageOrientationMode.auto,
  double margin = 0,
  String? title,
  bool compress = true,
}) async {
  if (images.isEmpty) {
    throw ArgumentError.value(images, 'images', 'must not be empty');
  }
  final pdf = pw.Document(
    title: title,
    creator: 'PDFCraft',
    producer: 'PDFCraft',
    compress: compress,
  );

  for (var i = 0; i < images.length; i++) {
    final provider = _provider(images[i], i);
    final iw = provider.width!.toDouble();
    final ih = provider.height!.toDouble();

    final PdfPageFormat pageFormat;
    double drawW;
    double drawH;
    if (pageSize == ImagePageSize.fitImage) {
      final scale = fitImageLongSide / (iw > ih ? iw : ih);
      drawW = iw * scale;
      drawH = ih * scale;
      pageFormat = PdfPageFormat(drawW + 2 * margin, drawH + 2 * margin);
    } else {
      final base = pageSize == ImagePageSize.a4
          ? PdfPageFormat.a4
          : PdfPageFormat.letter;
      final landscape = switch (orientation) {
        PdfPageOrientationMode.auto => iw > ih,
        PdfPageOrientationMode.portrait => false,
        PdfPageOrientationMode.landscape => true,
      };
      pageFormat = landscape ? base.landscape : base.portrait;
      final availW = pageFormat.width - 2 * margin;
      final availH = pageFormat.height - 2 * margin;
      if (availW <= 0 || availH <= 0) {
        throw ArgumentError.value(
          margin,
          'margin',
          'leaves no room for the image',
        );
      }
      final scale = (availW / iw) < (availH / ih) ? availW / iw : availH / ih;
      drawW = iw * scale;
      drawH = ih * scale;
    }

    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.all(margin),
        build: (_) => pw.Center(
          child: pw.Image(
            provider,
            width: drawW,
            height: drawH,
            fit: pw.BoxFit.contain,
          ),
        ),
      ),
    );
  }
  return pdf.save();
}

pw.ImageProvider _provider(Uint8List bytes, int index) {
  if (detectImageKind(bytes) == ImageKind.jpeg) {
    try {
      // Reads only the JPEG headers (size + EXIF orientation); the original
      // DCT data is embedded unchanged.
      final provider = pw.MemoryImage(bytes);
      if ((provider.width ?? 0) > 0 && (provider.height ?? 0) > 0) {
        return provider;
      }
    } catch (_) {
      // Fall through to a full decode for JPEGs pdf cannot parse.
    }
    try {
      final decoded = img.decodeJpg(bytes);
      if (decoded != null) {
        final oriented = img.bakeOrientation(decoded);
        oriented.exif = img.ExifData();
        return pw.MemoryImage(img.encodeJpg(oriented, quality: 92));
      }
    } catch (_) {}
    throw FormatException('Image ${index + 1} is not a decodable JPEG');
  }

  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) {
    throw FormatException(
      'Image ${index + 1} has an unsupported or corrupt format',
    );
  }
  final orientation = decoded.exif.imageIfd.orientation;
  if (orientation != null && orientation > 1) {
    decoded = img.bakeOrientation(decoded);
  }
  return pw.ImageImage(decoded);
}
