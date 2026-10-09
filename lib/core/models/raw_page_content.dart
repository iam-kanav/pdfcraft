import 'dart:typed_data';

/// Low-level positioned content of a single PDF page, as extracted by the
/// native engine. Coordinates use a top-left origin in PDF points, in the
/// page's displayed (rotated) orientation.
class RawPageContent {
  RawPageContent({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.lines,
    this.images = const [],
  });

  final int pageNumber;
  final double width;
  final double height;

  /// Text lines in reading (content stream, then geometric) order.
  final List<RawTextLine> lines;
  final List<RawImage> images;

  factory RawPageContent.fromMap(Map<dynamic, dynamic> m) => RawPageContent(
    pageNumber: m['page'] as int,
    width: (m['width'] as num).toDouble(),
    height: (m['height'] as num).toDouble(),
    lines: [for (final l in (m['lines'] as List? ?? const [])) RawTextLine.fromMap(l as Map)],
    images: [for (final i in (m['images'] as List? ?? const [])) RawImage.fromMap(i as Map)],
  );
}

class RawTextLine {
  RawTextLine({required this.spans, required this.x0, required this.y0, required this.x1, required this.y1});

  final List<RawTextSpan> spans;

  /// Bounding box: (x0,y0) top-left, (x1,y1) bottom-right.
  final double x0, y0, x1, y1;

  String get text => spans.map((s) => s.text).join();
  double get width => x1 - x0;
  double get height => y1 - y0;

  /// Dominant (character-weighted) font size of the line.
  double get fontSize {
    if (spans.isEmpty) return 0;
    final weights = <double, int>{};
    for (final s in spans) {
      weights[s.fontSize] = (weights[s.fontSize] ?? 0) + s.text.trim().length;
    }
    return weights.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  bool get isBold {
    final total = spans.fold<int>(0, (a, s) => a + s.text.trim().length);
    final bold = spans.where((s) => s.bold).fold<int>(0, (a, s) => a + s.text.trim().length);
    return total > 0 && bold * 2 > total;
  }

  factory RawTextLine.fromMap(Map<dynamic, dynamic> m) => RawTextLine(
    spans: [for (final s in (m['spans'] as List)) RawTextSpan.fromMap(s as Map)],
    x0: (m['x0'] as num).toDouble(),
    y0: (m['y0'] as num).toDouble(),
    x1: (m['x1'] as num).toDouble(),
    y1: (m['y1'] as num).toDouble(),
  );
}

class RawTextSpan {
  RawTextSpan({
    required this.text,
    required this.fontSize,
    this.bold = false,
    this.italic = false,
    this.fontName = '',
    required this.x0,
    required this.x1,
  });

  final String text;
  final double fontSize;
  final bool bold;
  final bool italic;
  final String fontName;
  final double x0, x1;

  factory RawTextSpan.fromMap(Map<dynamic, dynamic> m) => RawTextSpan(
    text: m['text'] as String,
    fontSize: (m['size'] as num).toDouble(),
    bold: m['bold'] as bool? ?? false,
    italic: m['italic'] as bool? ?? false,
    fontName: m['font'] as String? ?? '',
    x0: (m['x0'] as num).toDouble(),
    x1: (m['x1'] as num).toDouble(),
  );
}

class RawImage {
  RawImage({required this.x0, required this.y0, required this.x1, required this.y1, this.bytes, this.pixelWidth = 0, this.pixelHeight = 0});

  final double x0, y0, x1, y1;

  /// PNG/JPEG encoded image data (may be null if extraction failed).
  final Uint8List? bytes;
  final int pixelWidth;
  final int pixelHeight;

  double get width => x1 - x0;
  double get height => y1 - y0;

  factory RawImage.fromMap(Map<dynamic, dynamic> m) => RawImage(
    x0: (m['x0'] as num).toDouble(),
    y0: (m['y0'] as num).toDouble(),
    x1: (m['x1'] as num).toDouble(),
    y1: (m['y1'] as num).toDouble(),
    bytes: m['bytes'] as Uint8List?,
    pixelWidth: m['pw'] as int? ?? 0,
    pixelHeight: m['ph'] as int? ?? 0,
  );
}
