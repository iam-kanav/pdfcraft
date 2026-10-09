import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// The four faces of a font family used for PDF output, plus optional
/// fallback fonts for glyphs missing from the primary family.
class PdfFontSet {
  const PdfFontSet({
    required this.regular,
    required this.bold,
    required this.italic,
    required this.boldItalic,
    this.fallback = const [],
  });

  /// Creates a font set from TrueType font data.
  factory PdfFontSet.fromBytes({
    required ByteData regular,
    required ByteData bold,
    required ByteData italic,
    required ByteData boldItalic,
    List<ByteData> fallback = const [],
  }) => PdfFontSet(
    regular: pw.Font.ttf(regular),
    bold: pw.Font.ttf(bold),
    italic: pw.Font.ttf(italic),
    boldItalic: pw.Font.ttf(boldItalic),
    fallback: fallback.map(pw.Font.ttf).toList(),
  );

  /// Loads the bundled Noto Sans (or Noto Serif when [serif]) family using
  /// [loader], e.g. `PdfFontSet.load(rootBundle.load)` in the app or a
  /// file-based loader in tests.
  static Future<PdfFontSet> load(
    Future<ByteData> Function(String path) loader, {
    bool serif = false,
    String directory = 'assets/fonts',
  }) async {
    final family = serif ? 'NotoSerif' : 'NotoSans';
    final faces = await Future.wait([
      for (final face in const ['Regular', 'Bold', 'Italic', 'BoldItalic']) loader('$directory/$family-$face.ttf'),
    ]);
    return PdfFontSet.fromBytes(regular: faces[0], bold: faces[1], italic: faces[2], boldItalic: faces[3]);
  }

  final pw.Font regular;
  final pw.Font bold;
  final pw.Font italic;
  final pw.Font boldItalic;
  final List<pw.Font> fallback;
}

/// Renders [doc] to a PDF using `pw.MultiPage`.
///
/// Headings, paragraphs and quotes use spanning rich text so they flow
/// across pages; very long list items are split into a bulleted first part
/// and a page-spanning continuation. When [pageNumbers] is true a
/// "n / total" footer is added. [compress] can be disabled to produce
/// uncompressed (inspectable) PDF output.
Future<Uint8List> buildPdfFromStructure(
  DocStructure doc, {
  required PdfFontSet fonts,
  PdfPageFormat format = PdfPageFormat.a4,
  double margin = 56,
  double baseFontSize = 11,
  String? title,
  String? author,
  bool pageNumbers = true,
  bool compress = true,
}) async {
  final docTitle = title ?? doc.title;
  final pdf = pw.Document(
    title: docTitle,
    author: author,
    creator: 'PDFCraft',
    producer: 'PDFCraft',
    compress: compress,
  );
  final builder = _PdfBuilder(
    fonts: fonts,
    format: format,
    margin: margin,
    base: baseFontSize,
    pageNumbers: pageNumbers,
  );
  final widgets = builder.build(doc);

  pdf.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(pageFormat: format, margin: pw.EdgeInsets.all(margin), theme: builder.theme),
      maxPages: 1000000,
      footer: pageNumbers ? builder.footer : null,
      build: (_) => widgets,
    ),
  );
  return pdf.save();
}

const PdfColor _linkColor = PdfColor.fromInt(0xFF1155CC);
const PdfColor _quoteColor = PdfColor.fromInt(0xFF4A4A4A);
const PdfColor _quoteBorder = PdfColor.fromInt(0xFFB0B0B0);
const PdfColor _tableBorder = PdfColor.fromInt(0xFF9E9E9E);
const PdfColor _headerFill = PdfColor.fromInt(0xFFE8E8E8);
const PdfColor _captionColor = PdfColor.fromInt(0xFF5F6368);

class _PdfBuilder {
  _PdfBuilder({
    required this.fonts,
    required this.format,
    required this.margin,
    required this.base,
    required this.pageNumbers,
  }) {
    final t = pw.ThemeData.withFont(
      base: fonts.regular,
      bold: fonts.bold,
      italic: fonts.italic,
      boldItalic: fonts.boldItalic,
      fontFallback: fonts.fallback,
    );
    theme = t.copyWith(
      defaultTextStyle: t.defaultTextStyle.copyWith(fontSize: base, lineSpacing: base * 0.3),
    );
  }

  final PdfFontSet fonts;
  final PdfPageFormat format;
  final double margin;
  final double base;
  final bool pageNumbers;
  late final pw.ThemeData theme;

  double get contentWidth => format.width - 2 * margin;
  double get contentHeight => format.height - 2 * margin - (pageNumbers ? base * 2.5 : 0);

  /// Characters of a list item's first (non-spanning) part: a conservative
  /// 40% of what fits on one page, so the row never overflows a page.
  int get _chunkChars => math.max(80, (0.4 * (contentWidth / (base * 0.55)) * (contentHeight / (base * 1.5))).floor());

  pw.Widget footer(pw.Context context) => pw.Container(
    alignment: pw.Alignment.center,
    margin: pw.EdgeInsets.only(top: base),
    child: pw.Text(
      '${context.pageNumber} / ${context.pagesCount}',
      style: pw.TextStyle(fontSize: base * 0.8, color: PdfColors.grey600),
    ),
  );

  List<pw.Widget> build(DocStructure doc) {
    final out = <pw.Widget>[];
    final counter = ListCounter();
    var lastWasBreak = true; // suppress leading page breaks
    for (final block in doc.blocks) {
      if (block is! ListItemBlock) counter.reset();
      switch (block) {
        case HeadingBlock():
          out.add(_heading(block));
        case ParagraphBlock():
          final spans = _textSpans(block.spans);
          if (spans.isEmpty) continue;
          out.add(
            pw.Padding(
              padding: pw.EdgeInsets.only(bottom: base * 0.65),
              child: pw.RichText(
                text: pw.TextSpan(children: spans),
                overflow: pw.TextOverflow.span,
              ),
            ),
          );
        case ListItemBlock():
          out.addAll(_listItem(block, counter.next(block)));
        case QuoteBlock():
          out.addAll(_quote(block));
        case ImageBlock():
          final w = _image(block);
          if (w != null) out.add(w);
        case TableBlock():
          final w = _table(block);
          if (w != null) out.add(w);
        case PageBreakBlock():
          if (!lastWasBreak) out.add(pw.NewPage());
          lastWasBreak = true;
          continue;
      }
      lastWasBreak = false;
    }
    if (out.isEmpty || out.every((w) => w is pw.NewPage)) {
      out.add(pw.SizedBox(height: 1));
    }
    // A trailing NewPage would produce an empty last page.
    while (out.length > 1 && out.last is pw.NewPage) {
      out.removeLast();
    }
    return out;
  }

  // ------------------------------------------------------------- text

  /// Removes control characters the fonts cannot draw; tabs become spaces.
  String _clean(String s) {
    final t = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\t', '    ');
    final sb = StringBuffer();
    for (final r in t.runes) {
      if (r == 0x0A ||
          (r >= 0x20 && r != 0x7F && !(r >= 0x80 && r < 0xA0) && r != 0xFEFF && !(r >= 0xD800 && r <= 0xDFFF))) {
        sb.writeCharCode(r);
      }
    }
    return sb.toString();
  }

  List<pw.InlineSpan> _textSpans(List<TextSpanData> spans, {bool forceBold = false}) {
    final out = <pw.InlineSpan>[];
    for (final s in mergeSpans(spans)) {
      final text = _clean(s.text);
      if (text.isEmpty) continue;
      final link = s.link;
      final hasLink = link != null && link.trim().isNotEmpty;
      out.add(
        pw.TextSpan(
          text: text,
          style: pw.TextStyle(
            fontWeight: s.bold || forceBold ? pw.FontWeight.bold : pw.FontWeight.normal,
            fontStyle: s.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
            decoration: s.underline || hasLink ? pw.TextDecoration.underline : pw.TextDecoration.none,
            color: hasLink ? _linkColor : null,
          ),
          annotation: hasLink ? pw.AnnotationUrl(link.trim()) : null,
        ),
      );
    }
    return out;
  }

  pw.Widget _heading(HeadingBlock h) {
    const scale = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0];
    final level = h.level.clamp(1, 6);
    final size = base * scale[level - 1];
    final spans = _textSpans(
      h.spans.map((s) => s.copyWith(text: s.text.replaceAll('\n', ' '))).toList(),
      forceBold: true,
    );
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: size * (level <= 2 ? 0.9 : 0.7), bottom: size * 0.45),
      child: pw.RichText(
        text: pw.TextSpan(
          style: pw.TextStyle(
            fontSize: size,
            lineSpacing: size * 0.15,
            color: level >= 6 ? PdfColors.grey800 : PdfColors.black,
          ),
          children: spans,
        ),
        overflow: pw.TextOverflow.span,
      ),
    );
  }

  /// Splits spans so that the first part has at most [maxChars] characters,
  /// preferring a sentence or word boundary.
  (List<TextSpanData>, List<TextSpanData>) _splitSpans(List<TextSpanData> spans, int maxChars) {
    final text = spansToText(spans);
    if (text.length <= maxChars) return (spans, const []);
    var cut = -1;
    for (final sep in const ['\n', '. ', '; ', ', ', ' ']) {
      final idx = text.lastIndexOf(sep, maxChars);
      if (idx > maxChars ~/ 2) {
        cut = idx + sep.length;
        break;
      }
    }
    if (cut < 0) cut = maxChars;
    final first = <TextSpanData>[];
    final rest = <TextSpanData>[];
    var pos = 0;
    for (final s in spans) {
      final end = pos + s.text.length;
      if (end <= cut) {
        first.add(s);
      } else if (pos >= cut) {
        rest.add(s);
      } else {
        first.add(s.copyWith(text: s.text.substring(0, cut - pos)));
        rest.add(s.copyWith(text: s.text.substring(cut - pos)));
      }
      pos = end;
    }
    final trimmedRest = List<TextSpanData>.of(rest);
    if (trimmedRest.isNotEmpty) {
      trimmedRest[0] = trimmedRest[0].copyWith(text: trimmedRest[0].text.replaceFirst(RegExp(r'^[ \n]+'), ''));
    }
    return (first, trimmedRest);
  }

  List<pw.Widget> _listItem(ListItemBlock item, int number) {
    final level = item.indent.clamp(0, 8);
    final marker = listMarker(item, number);
    final indent = level * base * 1.6;
    final markerWidth = item.ordered ? math.max(base * 1.8, base * 0.62 * (marker.length + 1)) : base * 1.3;
    final (first, rest) = _splitSpans(item.spans, _chunkChars);
    final widgets = <pw.Widget>[
      pw.Padding(
        padding: pw.EdgeInsets.only(left: indent, bottom: rest.isEmpty ? base * 0.3 : 0),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: markerWidth,
              child: pw.Text(marker, textAlign: item.ordered ? pw.TextAlign.left : pw.TextAlign.center),
            ),
            pw.Expanded(
              child: pw.RichText(text: pw.TextSpan(children: _textSpans(first))),
            ),
          ],
        ),
      ),
    ];
    if (rest.isNotEmpty) {
      widgets.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(left: indent + markerWidth, bottom: base * 0.3),
          child: pw.RichText(
            text: pw.TextSpan(children: _textSpans(rest)),
            overflow: pw.TextOverflow.span,
          ),
        ),
      );
    }
    return widgets;
  }

  List<pw.Widget> _quote(QuoteBlock q) {
    final spans = _textSpans(q.spans);
    if (spans.isEmpty) return const [];
    return [
      pw.Container(
        margin: pw.EdgeInsets.only(left: base * 0.5, top: base * 0.2, bottom: base * 0.8),
        padding: pw.EdgeInsets.only(left: base * 0.9, top: base * 0.15, bottom: base * 0.15),
        decoration: const pw.BoxDecoration(
          border: pw.Border(left: pw.BorderSide(color: _quoteBorder, width: 3)),
        ),
        child: pw.RichText(
          text: pw.TextSpan(
            style: const pw.TextStyle(color: _quoteColor),
            children: spans,
          ),
          // Lets long quotes (and their border) continue on the next page.
          overflow: pw.TextOverflow.span,
        ),
      ),
    ];
  }

  pw.Widget? _image(ImageBlock block) {
    final bytes = normalizeToPngOrJpeg(block.bytes);
    if (bytes == null) return _caption(block.caption);
    final pw.ImageProvider provider;
    try {
      provider = pw.MemoryImage(bytes);
    } catch (_) {
      return _caption(block.caption);
    }
    final iw = (provider.width ?? block.width).toDouble();
    final ih = (provider.height ?? block.height).toDouble();
    if (iw <= 0 || ih <= 0) return _caption(block.caption);
    // Pixel sizes are treated as 96 dpi; never wider than the text column.
    final naturalW = block.width > 0 ? block.width * 72 / 96 : iw * 72 / 96;
    var w = math.min(contentWidth, naturalW);
    var h = w * ih / iw;
    final maxH = contentHeight * 0.85;
    if (h > maxH) {
      h = maxH;
      w = h * iw / ih;
    }
    final caption = _caption(block.caption);
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(vertical: base * 0.5),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Center(
            child: pw.Image(provider, width: w, height: h, fit: pw.BoxFit.contain),
          ),
          ?caption,
        ],
      ),
    );
  }

  pw.Widget? _caption(String? caption) {
    if (caption == null || caption.trim().isEmpty) return null;
    var text = _clean(caption).replaceAll('\n', ' ');
    if (text.length > 400) text = '${text.substring(0, 400)}…';
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: base * 0.35),
      child: pw.Text(
        text,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(fontSize: base * 0.85, fontStyle: pw.FontStyle.italic, color: _captionColor),
      ),
    );
  }

  pw.Widget? _table(TableBlock table) {
    final rows = table.rows.where((r) => r.isNotEmpty).toList();
    if (rows.isEmpty) return null;
    final cols = rows.map((r) => r.length).reduce(math.max);
    final fontSize = cols <= 4
        ? base * 0.95
        : cols <= 6
        ? base * 0.85
        : cols <= 9
        ? base * 0.72
        : math.max(base * 0.55, 5.0);
    final padding = pw.EdgeInsets.symmetric(horizontal: fontSize * 0.45, vertical: fontSize * 0.3);

    // Column weights from content length so narrow columns stay narrow.
    final widths = <int, pw.TableColumnWidth>{};
    for (var c = 0; c < cols; c++) {
      var maxLen = 1;
      for (final r in rows) {
        if (c < r.length) {
          final longestLine = r[c].split('\n').fold<int>(0, (m, l) => math.max(m, l.length));
          maxLen = math.max(maxLen, longestLine);
        }
      }
      widths[c] = pw.FlexColumnWidth(maxLen.clamp(3, 40).toDouble());
    }

    // A single row must fit on one page; cap pathological cell sizes.
    final maxCellChars = (contentWidth * contentHeight / (fontSize * fontSize) / cols).floor().clamp(200, 4000);
    final maxCellLines = math.max(3, (contentHeight / (fontSize * 1.6)).floor() - 4);
    String cellText(String s) {
      var t = _clean(s);
      final lines = t.split('\n');
      if (lines.length > maxCellLines) {
        t = '${lines.take(maxCellLines).join('\n')}…';
      }
      return t.length > maxCellChars ? '${t.substring(0, maxCellChars)}…' : t;
    }

    final tableRows = <pw.TableRow>[];
    for (var r = 0; r < rows.length; r++) {
      final header = table.hasHeader && r == 0;
      tableRows.add(
        pw.TableRow(
          repeat: header,
          decoration: header ? const pw.BoxDecoration(color: _headerFill) : null,
          children: [
            for (var c = 0; c < cols; c++)
              pw.Padding(
                padding: padding,
                child: pw.Text(
                  cellText(c < rows[r].length ? rows[r][c] : ''),
                  style: pw.TextStyle(
                    fontSize: fontSize,
                    fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: base * 0.3, bottom: base * 0.9),
      child: pw.Table(
        border: pw.TableBorder.all(color: _tableBorder, width: 0.6),
        columnWidths: widths,
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.top,
        children: tableRows,
      ),
    );
  }
}
