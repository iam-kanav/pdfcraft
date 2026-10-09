import 'dart:typed_data';

/// A format-neutral, semantic representation of document content.
///
/// Produced by the smart-reading analyzer (from PDF page content) and by
/// document importers (DOCX, Markdown, plain text). Consumed by the reading
/// mode renderer, the DOCX/HTML/Markdown exporters and the PDF builder.
class DocStructure {
  DocStructure({required this.blocks, this.title});

  final List<DocBlock> blocks;
  final String? title;

  /// Plain text of all blocks, separated by blank lines.
  String get plainText => blocks.map((b) => b.plainText).where((t) => t.isNotEmpty).join('\n\n');

  Iterable<HeadingBlock> get headings => blocks.whereType<HeadingBlock>();
}

sealed class DocBlock {
  const DocBlock({this.pageNumber});

  /// 1-based source page number when the block originates from a PDF.
  final int? pageNumber;

  String get plainText;
}

/// Horizontal alignment of a block as laid out in the source document.
enum BlockAlign { start, center, end }

/// A run of text with uniform styling.
class TextSpanData {
  const TextSpanData(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.link,
    this.color,
    this.fontFamily,
    this.sizeRatio = 1.0,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final String? link;

  /// Original text color (ARGB), or null for the default ink color.
  final int? color;

  /// Original font family class: 'serif', 'sans' or 'mono' (null = unknown).
  final String? fontFamily;

  /// Size relative to the block's dominant size (1.0 = same; e.g. 0.7 for footnote marks).
  final double sizeRatio;

  bool sameStyleAs(TextSpanData o) =>
      bold == o.bold &&
      italic == o.italic &&
      underline == o.underline &&
      strike == o.strike &&
      link == o.link &&
      color == o.color &&
      fontFamily == o.fontFamily &&
      sizeRatio == o.sizeRatio;

  TextSpanData copyWith({String? text}) => TextSpanData(
    text ?? this.text,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    link: link,
    color: color,
    fontFamily: fontFamily,
    sizeRatio: sizeRatio,
  );

  @override
  String toString() => 'Span(${bold ? 'b' : ''}${italic ? 'i' : ''}${underline ? 'u' : ''}"$text")';
}

String spansToText(List<TextSpanData> spans) => spans.map((s) => s.text).join();

class HeadingBlock extends DocBlock {
  const HeadingBlock({required this.level, required this.spans, this.align = BlockAlign.start, super.pageNumber});

  /// 1 (largest) .. 6.
  final int level;
  final List<TextSpanData> spans;
  final BlockAlign align;

  String get text => spansToText(spans);

  @override
  String get plainText => text;

  @override
  String toString() => 'H$level("$text")';
}

class ParagraphBlock extends DocBlock {
  const ParagraphBlock({required this.spans, this.align = BlockAlign.start, super.pageNumber});

  final List<TextSpanData> spans;
  final BlockAlign align;

  String get text => spansToText(spans);

  @override
  String get plainText => text;

  @override
  String toString() => 'P("${text.length > 40 ? '${text.substring(0, 40)}…' : text}")';
}

class ListItemBlock extends DocBlock {
  const ListItemBlock({required this.spans, this.ordered = false, this.marker, this.indent = 0, super.pageNumber});

  final List<TextSpanData> spans;
  final bool ordered;

  /// Original marker text, e.g. "1." or "•".
  final String? marker;
  final int indent;

  String get text => spansToText(spans);

  @override
  String get plainText => '${marker ?? (ordered ? '1.' : '•')} $text';

  @override
  String toString() => 'LI("$text")';
}

class ImageBlock extends DocBlock {
  const ImageBlock({required this.bytes, required this.width, required this.height, this.caption, super.pageNumber});

  /// Encoded image (PNG or JPEG).
  final Uint8List bytes;

  /// Pixel size of the image.
  final int width;
  final int height;
  final String? caption;

  @override
  String get plainText => caption ?? '';

  @override
  String toString() => 'IMG(${width}x$height)';
}

class TableBlock extends DocBlock {
  const TableBlock({required this.rows, this.hasHeader = false, super.pageNumber});

  /// Row-major cell texts. All rows have the same number of cells.
  final List<List<String>> rows;
  final bool hasHeader;

  int get columnCount => rows.isEmpty ? 0 : rows.first.length;

  @override
  String get plainText => rows.map((r) => r.join('\t')).join('\n');

  @override
  String toString() => 'TABLE(${rows.length}x$columnCount)';
}

class QuoteBlock extends DocBlock {
  const QuoteBlock({required this.spans, super.pageNumber});

  final List<TextSpanData> spans;

  String get text => spansToText(spans);

  @override
  String get plainText => text;
}

class PageBreakBlock extends DocBlock {
  const PageBreakBlock({super.pageNumber});

  @override
  String get plainText => '';
}
