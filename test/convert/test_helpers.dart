import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/convert/engine/pdf_builder.dart';

/// Loads the bundled Noto Sans family from disk.
Future<PdfFontSet> loadTestFonts() =>
    PdfFontSet.load((path) async => ByteData.sublistView(File(path).readAsBytesSync()));

Uint8List makePng(int w, int h, {int r = 200, int g = 40, int b = 40}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  img.fillRect(image, x1: 0, y1: 0, x2: w ~/ 2, y2: h ~/ 2, color: img.ColorRgb8(20, 20, 220));
  return img.encodePng(image);
}

Uint8List makeJpeg(int w, int h, {int? exifOrientation}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(30, 160, 60));
  if (exifOrientation != null) {
    image.exif.imageIfd.orientation = exifOrientation;
  }
  return img.encodeJpg(image, quality: 85);
}

/// Uncompressed PDF inspection helpers.
String pdfText(Uint8List bytes) => latin1.decode(bytes);

int pdfPageCount(Uint8List bytes) => RegExp(r'/Type\s*/Page(?![A-Za-z])').allMatches(pdfText(bytes)).length;

List<({double width, double height})> pdfMediaBoxes(Uint8List bytes) =>
    RegExp(r'/MediaBox\s*\[\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s*\]')
        .allMatches(pdfText(bytes))
        .map(
          (m) => (
            width: double.parse(m.group(3)!) - double.parse(m.group(1)!),
            height: double.parse(m.group(4)!) - double.parse(m.group(2)!),
          ),
        )
        .toList();

void expectValidPdfEnvelope(Uint8List bytes) {
  final head = latin1.decode(bytes.sublist(0, 5));
  expect(head, '%PDF-');
  final tail = latin1.decode(bytes.sublist(bytes.length - 8)).trim();
  expect(tail.endsWith('%%EOF'), isTrue, reason: 'tail was "$tail"');
}

/// Comparable description of a block for structural equality checks.
Object describe(DocBlock b) => switch (b) {
  HeadingBlock() => ['H', b.level, b.spans.map(describeSpan).toList()],
  ParagraphBlock() => ['P', b.spans.map(describeSpan).toList()],
  QuoteBlock() => ['Q', b.spans.map(describeSpan).toList()],
  ListItemBlock() => ['LI', b.ordered, b.indent, b.spans.map(describeSpan).toList()],
  ImageBlock() => ['IMG', b.bytes.length, b.caption],
  TableBlock() => ['T', b.hasHeader, b.rows],
  PageBreakBlock() => ['BR'],
};

String describeSpan(TextSpanData s) =>
    '${s.bold ? 'B' : ''}${s.italic ? 'I' : ''}${s.underline ? 'U' : ''}${s.link != null ? '<${s.link}>' : ''}"${s.text}"';

/// Finds a LibreOffice executable, or null when not installed.
String? findSoffice() {
  const candidates = [
    '/Applications/LibreOffice.app/Contents/MacOS/soffice',
    '/usr/bin/soffice',
    '/usr/local/bin/soffice',
    '/opt/homebrew/bin/soffice',
    '/usr/bin/libreoffice',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  try {
    final r = Process.runSync('which', ['soffice']);
    final path = (r.stdout as String).trim();
    if (r.exitCode == 0 && path.isNotEmpty) return path;
  } catch (_) {}
  return null;
}

/// Python with pypdf, used as an optional external PDF validator.
bool hasPypdf() {
  try {
    final r = Process.runSync('python3', ['-c', 'import pypdf']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
