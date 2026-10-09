import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfcraft/core/models/raw_page_content.dart';

/// Approximate glyph advance used by the synthetic fixtures (half an em).
double advance(String text, double size) => text.length * size * 0.5;

/// A single span starting at [x]; [x1] overrides the estimated right edge.
RawTextSpan sp(String text, double x, {double size = 10, bool bold = false, bool italic = false, double? x1}) =>
    RawTextSpan(text: text, fontSize: size, bold: bold, italic: italic, x0: x, x1: x1 ?? x + advance(text, size));

/// Consecutive spans laid out left to right without gaps. Each part is
/// `(text, flags)` where flags may contain `b` (bold) and/or `i` (italic).
/// When [right] is given, the last span is stretched to end there (justified).
List<RawTextSpan> seq(List<(String, String)> parts, {double x = 72, double size = 10, double? right}) {
  final out = <RawTextSpan>[];
  var cx = x;
  for (var k = 0; k < parts.length; k++) {
    final (text, flags) = parts[k];
    final isLast = k == parts.length - 1;
    final x1 = isLast && right != null ? right : cx + advance(text, size);
    out.add(sp(text, cx, size: size, bold: flags.contains('b'), italic: flags.contains('i'), x1: x1));
    cx = x1;
  }
  return out;
}

/// A line made of [spans] whose top is at [y].
RawTextLine ln(List<RawTextSpan> spans, double y) {
  final size = spans.map((s) => s.fontSize).reduce(math.max);
  return RawTextLine(
    spans: spans,
    x0: spans.map((s) => s.x0).reduce(math.min),
    y0: y,
    x1: spans.map((s) => s.x1).reduce(math.max),
    y1: y + size,
  );
}

/// A single-span text line. [right] stretches the line to a justified edge.
RawTextLine tl(
  String text,
  double y, {
  double x = 72,
  double size = 10,
  bool bold = false,
  bool italic = false,
  double? right,
}) => ln([sp(text, x, size: size, bold: bold, italic: italic, x1: right)], y);

/// A line centered on [center].
RawTextLine centered(
  String text,
  double y, {
  double center = 306,
  double size = 10,
  bool bold = false,
  bool italic = false,
}) {
  final w = advance(text, size);
  return tl(text, y, x: center - w / 2, size: size, bold: bold, italic: italic);
}

RawPageContent page(
  int n,
  List<RawTextLine> lines, {
  List<RawImage> images = const [],
  double w = 612,
  double h = 792,
}) => RawPageContent(pageNumber: n, width: w, height: h, lines: lines, images: images);

/// A valid 1x1 transparent PNG.
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

RawImage img(double x0, double y0, double x1, double y1, {int pw = 0, int ph = 0}) =>
    RawImage(x0: x0, y0: y0, x1: x1, y1: y1, bytes: tinyPng, pixelWidth: pw, pixelHeight: ph);
