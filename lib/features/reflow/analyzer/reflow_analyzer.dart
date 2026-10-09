// Smart Reading Mode analyzer.
//
// Turns positioned, low-level page content (lines, spans, images) into a
// semantic DocStructure: headings, paragraphs, lists, tables, images, quotes.
// Everything runs offline and purely geometrically/typographically.

import 'dart:math' as math;

import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/core/models/raw_page_content.dart';

/// Switches for optional analysis stages.
class ReflowOptions {
  const ReflowOptions({this.removeHeadersFooters = true, this.detectTables = true, this.includeImages = true});

  final bool removeHeadersFooters;
  final bool detectTables;
  final bool includeImages;
}

// ---------------------------------------------------------------------------
// Regular expressions & small text helpers
// ---------------------------------------------------------------------------

final RegExp _letterRe = RegExp(r'\p{L}', unicode: true);
final RegExp _lowerStartRe = RegExp('^[\\s"“‘(\\[]*\\p{Ll}', unicode: true);
final RegExp _hyphenEndRe = RegExp(r'\p{L}[-‐]$', unicode: true);
final RegExp _sentenceEndRe = RegExp('[.!?:;…]["\'”’)\\]]*\$');
final RegExp _periodEndRe = RegExp(r'[.,;]$');
final RegExp _wsRe = RegExp(r'\s+');

final RegExp _bulletRe = RegExp('^\\s*([•◦▪▫‣●○■□►▸▹➢➤✓✔·])\\s*');
final RegExp _dashBulletRe = RegExp(r'^\s*([\-–—*])\s+');
final RegExp _numberedRe = RegExp(
  r'^\s*((?:\d{1,3}|[a-zA-Z]|[ivxlcdm]{2,6}|[IVXLCDM]{2,6})[.)]|\((?:\d{1,3}|[a-zA-Z]|[ivxlcdm]{2,6}|[IVXLCDM]{2,6})\))\s+(?=\S)',
);
final RegExp _numberedHeadingRe = RegExp(r'^\s*(\d+(\.\d+)*\.?|[IVXLC]+\.|[A-Z]\.)\s+\S');
final RegExp _captionRe = RegExp(r'^\s*(?:(?:figure|table)(?![a-z])|fig\.)', caseSensitive: false);

final RegExp _pageNumRe1 = RegExp(r'^[\s\-–—|]*\d{1,4}[\s\-–—|]*$');
final RegExp _pageNumRe2 = RegExp(r'^(page|p\.|pg\.?)\s*\d{1,4}(\s*(of|/)\s*\d{1,4})?$', caseSensitive: false);
final RegExp _pageNumRe3 = RegExp(r'^\d{1,4}\s*(of|/)\s*\d{1,4}$', caseSensitive: false);
final RegExp _romanRe = RegExp(r'^(?=[mdclxvi])m{0,4}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$');

bool _endsSentence(String text) => _sentenceEndRe.hasMatch(text.trimRight());

bool _startsLowercase(String text) => _lowerStartRe.hasMatch(text);

double _median(List<double> values) {
  if (values.isEmpty) return double.nan;
  final s = List<double>.of(values)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

double _percentile(List<double> values, double q) {
  final s = List<double>.of(values)..sort();
  return s[((s.length - 1) * q).floor()];
}

double _roundHalf(double v) => (v * 2).roundToDouble() / 2;

bool _sameStyle(TextSpanData a, TextSpanData b) =>
    a.bold == b.bold && a.italic == b.italic && a.underline == b.underline && a.link == b.link;

/// Appends [s] to [out], merging with the previous span when the style is
/// equal and collapsing double spaces at the junction.
void _appendSpan(List<TextSpanData> out, TextSpanData s) {
  var text = s.text;
  if (text.isEmpty) return;
  if (out.isNotEmpty && out.last.text.endsWith(' ') && text.startsWith(' ')) {
    text = text.substring(1);
    if (text.isEmpty) return;
  }
  if (out.isNotEmpty && _sameStyle(out.last, s)) {
    out[out.length - 1] = out.last.copyWith(text: out.last.text + text);
  } else {
    out.add(text == s.text ? s : s.copyWith(text: text));
  }
}

/// Trims leading whitespace of the first span and trailing whitespace of the
/// last span, dropping spans that become empty.
List<TextSpanData> _trimSpans(List<TextSpanData> spans) {
  final out = List<TextSpanData>.of(spans);
  while (out.isNotEmpty) {
    final t = out.first.text.trimLeft();
    if (t.isEmpty) {
      out.removeAt(0);
    } else {
      out[0] = out.first.copyWith(text: t);
      break;
    }
  }
  while (out.isNotEmpty) {
    final t = out.last.text.trimRight();
    if (t.isEmpty) {
      out.removeLast();
    } else {
      out[out.length - 1] = out.last.copyWith(text: t);
      break;
    }
  }
  return out;
}

/// Removes the first [n] characters from a span list.
List<TextSpanData> _dropChars(List<TextSpanData> spans, int n) {
  final out = <TextSpanData>[];
  var remaining = n;
  for (final s in spans) {
    if (remaining <= 0) {
      out.add(s);
    } else if (s.text.length <= remaining) {
      remaining -= s.text.length;
    } else {
      out.add(s.copyWith(text: s.text.substring(remaining)));
      remaining = 0;
    }
  }
  return _trimSpans(out);
}

String _tailText(List<TextSpanData> spans, int chars) {
  final b = StringBuffer();
  for (var i = math.max(0, spans.length - 3); i < spans.length; i++) {
    b.write(spans[i].text);
  }
  final s = b.toString();
  return s.length <= chars ? s : s.substring(s.length - chars);
}

void _removeLastChar(List<TextSpanData> out) {
  final t = out.last.text;
  if (t.length <= 1) {
    out.removeLast();
  } else {
    out[out.length - 1] = out.last.copyWith(text: t.substring(0, t.length - 1));
  }
}

/// Joins visual lines into one run of spans: de-hyphenates words broken
/// across lines and inserts a single space between other lines.
List<TextSpanData> _joinLines(Iterable<List<TextSpanData>> lines) {
  final out = <TextSpanData>[];
  for (final raw in lines) {
    final line = _trimSpans(raw);
    if (line.isEmpty) continue;
    if (out.isNotEmpty) {
      final tail = _tailText(out, 2);
      final head = line.first.text;
      if (tail.endsWith('­')) {
        _removeLastChar(out);
      } else if (_hyphenEndRe.hasMatch(tail)) {
        // "exam-" + "ple" -> "example"; "Franco-" + "Prussian" stays hyphenated.
        if (_startsLowercase(head)) _removeLastChar(out);
      } else {
        final prev = out.last;
        final next = line.first;
        _appendSpan(out, _sameStyle(prev, next) ? prev.copyWith(text: ' ') : const TextSpanData(' '));
      }
    }
    for (final s in line) {
      _appendSpan(out, s);
    }
  }
  return _trimSpans(out);
}

String _normalizeWs(String s) => s.replaceAll(_wsRe, ' ');

// ---------------------------------------------------------------------------
// Document statistics
// ---------------------------------------------------------------------------

/// Document-wide typographic statistics used to interpret individual pages.
class DocumentStats {
  DocumentStats({
    required this.bodyFontSize,
    required this.headingSizes,
    required this.lineSpacing,
    required this.repeatedMarginTexts,
    required this.pageCount,
    this.textLeft,
    this.textRight,
    this.options = const ReflowOptions(),
  });

  /// Character-weighted mode of all span font sizes (rounded to 0.5pt).
  final double bodyFontSize;

  /// Distinct heading font sizes (≥ body × 1.15), largest first. Index 0 is H1.
  final List<double> headingSizes;

  /// Typical baseline-to-baseline distance of body text, in points.
  final double lineSpacing;

  /// Normalized texts (see [normalizeMarginText]) of header/footer lines that
  /// repeat across pages.
  final Set<String> repeatedMarginTexts;

  final int pageCount;

  /// Median left/right edge of body text across pages (null when unknown).
  final double? textLeft, textRight;

  final ReflowOptions options;

  /// Fraction of the page height considered header/footer territory.
  static const double marginFraction = 0.08;

  static const double headingRatio = 1.15;

  /// Builds statistics for [pages].
  factory DocumentStats.fromPages(List<RawPageContent> pages, {ReflowOptions options = const ReflowOptions()}) {
    // Body font size: character-weighted mode.
    final weights = <double, int>{};
    for (final page in pages) {
      for (final line in page.lines) {
        for (final span in line.spans) {
          final n = span.text.trim().length;
          if (n == 0 || span.fontSize <= 0) continue;
          final key = _roundHalf(span.fontSize);
          weights[key] = (weights[key] ?? 0) + n;
        }
      }
    }
    var body = 10.0;
    if (weights.isNotEmpty) {
      var best = weights.entries.first;
      for (final e in weights.entries) {
        if (e.value > best.value || (e.value == best.value && e.key < best.key)) best = e;
      }
      body = best.key;
    }

    // Repeated header/footer texts.
    final counts = <String, int>{};
    for (final page in pages) {
      final seen = <String>{};
      for (final line in page.lines) {
        if (!isInMargin(line, page)) continue;
        final n = normalizeMarginText(line.text);
        if (n.isNotEmpty) seen.add(n);
      }
      for (final s in seen) {
        counts[s] = (counts[s] ?? 0) + 1;
      }
    }
    final threshold = math.max(2, (pages.length * 0.4).ceil());
    final repeated = {
      for (final e in counts.entries)
        if (e.value >= threshold) e.key,
    };

    // Heading sizes.
    final candidates = <double>[];
    for (final page in pages) {
      for (final line in page.lines) {
        final t = line.text.trim();
        if (t.isEmpty || t.length > 250 || !_letterRe.hasMatch(t)) continue;
        if (isInMargin(line, page) && (repeated.contains(normalizeMarginText(t)) || isPageNumberText(t))) continue;
        final s = _roundHalf(line.fontSize);
        if (s >= body * headingRatio - 0.01) candidates.add(s);
      }
    }
    candidates.sort((a, b) => b.compareTo(a));
    final headingSizes = <double>[];
    for (final s in candidates) {
      if (headingSizes.isEmpty || headingSizes.last - s > 0.6) headingSizes.add(s);
    }

    // Typical line pitch for body-sized lines.
    final pitches = <double>[];
    for (final page in pages) {
      final bodyLines = page.lines.where((l) => l.text.trim().isNotEmpty && (l.fontSize - body).abs() <= 0.6).toList()
        ..sort((a, b) => a.y0.compareTo(b.y0));
      for (var i = 0; i < bodyLines.length; i++) {
        final a = bodyLines[i];
        for (var j = i + 1; j < bodyLines.length; j++) {
          final b = bodyLines[j];
          final d = b.y0 - a.y0;
          if (d < 0.5 * body) continue;
          if (d > 3 * body) break;
          if (math.min(a.x1, b.x1) > math.max(a.x0, b.x0)) {
            pitches.add(d);
            break;
          }
        }
      }
    }
    // A low percentile rather than the median: paragraph and heading gaps
    // only ever make pitches larger, so the tight end is the line pitch.
    final pitch = pitches.isEmpty ? body * 1.2 : _percentile(pitches, 0.35);

    // Typical text extent of single-column pages, used for pages that have
    // too few lines to reveal the column width on their own.
    final lefts = <double>[], rights = <double>[];
    for (final page in pages) {
      final bodyLines = page.lines.where((l) => l.text.trim().isNotEmpty && (l.fontSize - body).abs() <= 0.6);
      if (bodyLines.length < 3) continue;
      lefts.add(bodyLines.map((l) => l.x0).reduce(math.min));
      rights.add(bodyLines.map((l) => l.x1).reduce(math.max));
    }

    return DocumentStats(
      bodyFontSize: body,
      headingSizes: headingSizes,
      lineSpacing: pitch,
      repeatedMarginTexts: repeated,
      pageCount: pages.length,
      textLeft: lefts.isEmpty ? null : _median(lefts),
      textRight: rights.isEmpty ? null : _median(rights),
      options: options,
    );
  }

  /// Heading level (1..6) for a line of [size] points, or null if the size is
  /// not a heading size.
  int? headingLevelForSize(double size) {
    if (headingSizes.isEmpty || size < bodyFontSize * headingRatio - 0.01) return null;
    var best = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < headingSizes.length; i++) {
      final d = (headingSizes[i] - size).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = i;
      }
    }
    return math.min(best + 1, 6);
  }

  /// Level used for bold body-size headings: one below the smallest size level.
  int get boldHeadingLevel => math.min(headingSizes.length + 1, 6);

  /// Expected baseline pitch for text of [size] points.
  double expectedPitch(double size) => lineSpacing * (size / bodyFontSize);

  static bool isInMargin(RawTextLine line, RawPageContent page) {
    if (page.height <= 0) return false;
    final cy = (line.y0 + line.y1) / 2;
    return cy < page.height * marginFraction || cy > page.height * (1 - marginFraction);
  }

  /// Lower-cased, whitespace-collapsed text with digits replaced by '#'.
  static String normalizeMarginText(String text) =>
      _normalizeWs(text.trim().toLowerCase().replaceAll(RegExp(r'\d'), '#'));

  /// Whether [text] is a standalone page number such as `12`, `- 12 -`,
  /// `Page 3 of 10`, `3/10` or a roman numeral.
  static bool isPageNumberText(String text) {
    final t = _normalizeWs(text.trim());
    if (t.isEmpty) return false;
    if (_pageNumRe1.hasMatch(t) || _pageNumRe2.hasMatch(t) || _pageNumRe3.hasMatch(t)) return true;
    final core = t.replaceAll(RegExp(r'^[\s\-–—|]+|[\s\-–—|]+$'), '');
    if (core.isEmpty || core.length > 7) return false;
    final isLower = core == core.toLowerCase();
    final isUpper = core == core.toUpperCase();
    if (!isLower && !isUpper) return false;
    return _romanRe.hasMatch(core.toLowerCase());
  }

  bool isRepeatedMarginLine(RawTextLine line, RawPageContent page) =>
      isInMargin(line, page) && repeatedMarginTexts.contains(normalizeMarginText(line.text));
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Analyzes all [pages] and returns the reflowable document structure.
DocStructure analyzeDocument(List<RawPageContent> pages, {ReflowOptions options = const ReflowOptions()}) {
  final stats = DocumentStats.fromPages(pages, options: options);
  final blocks = <DocBlock>[];
  for (final page in pages) {
    _appendWithContinuation(blocks, analyzePage(page, stats));
  }
  final headings = blocks.whereType<HeadingBlock>();
  String? title;
  if (headings.isNotEmpty) {
    title = (headings.where((h) => h.level == 1).firstOrNull ?? headings.first).text;
  }
  return DocStructure(blocks: blocks, title: title);
}

/// Merges a paragraph continuing across the page break, then appends.
void _appendWithContinuation(List<DocBlock> blocks, List<DocBlock> pageBlocks) {
  final next = List<DocBlock>.of(pageBlocks);
  if (blocks.isNotEmpty && blocks.last is ParagraphBlock) {
    final prev = blocks.last as ParagraphBlock;
    if (!_endsSentence(prev.text)) {
      var k = 0;
      while (k < next.length && next[k] is ImageBlock) {
        k++;
      }
      if (k < next.length && next[k] is ParagraphBlock) {
        final cont = next[k] as ParagraphBlock;
        final prevTail = _tailText(prev.spans, 2);
        if (_startsLowercase(cont.text) || _hyphenEndRe.hasMatch(prevTail)) {
          blocks[blocks.length - 1] = ParagraphBlock(
            spans: _joinLines([prev.spans, cont.spans]),
            pageNumber: prev.pageNumber,
          );
          next.removeAt(k);
        }
      }
    }
  }
  blocks.addAll(next);
}

/// Analyzes a single page using document-wide [stats].
List<DocBlock> analyzePage(RawPageContent page, DocumentStats stats) => _PageAnalyzer(page, stats).run();

// ---------------------------------------------------------------------------
// Page items
// ---------------------------------------------------------------------------

class _Cell {
  _Cell(this.spans) : x0 = spans.first.x0, x1 = spans.last.x1;

  final List<RawTextSpan> spans;
  final double x0;
  final double x1;

  String get text => _normalizeWs(spans.map((s) => s.text).join(' ')).trim();

  bool get bold {
    var total = 0, b = 0;
    for (final s in spans) {
      final n = s.text.trim().length;
      total += n;
      if (s.bold) b += n;
    }
    return total > 0 && b * 2 > total;
  }
}

/// A positioned piece of page content: a (possibly partial) text line or an image.
class _Item {
  _Item.text(List<RawTextSpan> spans, this.y0, this.y1)
    : spans = List.of(spans)..sort((a, b) => a.x0.compareTo(b.x0)),
      image = null,
      x0 = spans.map((s) => s.x0).reduce(math.min),
      x1 = spans.map((s) => s.x1).reduce(math.max);

  _Item.image(RawImage img) : spans = const [], image = img, x0 = img.x0, x1 = img.x1, y0 = img.y0, y1 = img.y1;

  final List<RawTextSpan> spans;
  final RawImage? image;
  final double x0, x1, y0, y1;

  /// Horizontal extent of the column this item was placed in.
  double colX0 = 0, colX1 = 0;

  bool get isImage => image != null;
  double get width => x1 - x0;
  double get height => y1 - y0;
  double get cy => (y0 + y1) / 2;
  double get colWidth => colX1 - colX0;

  /// Horizontal intervals covered by ink.
  List<(double, double)> get segments => isImage ? [(x0, x1)] : [for (final s in spans) (s.x0, s.x1)];

  late final List<TextSpanData> textSpans = _buildTextSpans();
  late final String text = spansToText(textSpans);
  late final double fontSize = _dominantSize();
  late final bool bold = _majority((s) => s.bold);
  late final bool italic = _majority((s) => s.italic);
  late final List<_Cell> cells = _buildCells();

  int get charCount => text.trim().length;

  List<TextSpanData> _buildTextSpans() {
    final out = <TextSpanData>[];
    RawTextSpan? prev;
    for (final s in spans) {
      var t = _normalizeWs(s.text);
      if (t.isEmpty) continue;
      if (prev != null && out.isNotEmpty) {
        final gap = s.x0 - prev.x1;
        final size = math.max(s.fontSize, prev.fontSize);
        if (gap > 0.15 * size && !out.last.text.endsWith(' ') && !t.startsWith(' ')) t = ' $t';
      }
      _appendSpan(out, TextSpanData(t, bold: s.bold, italic: s.italic));
      prev = s;
    }
    return _trimSpans(out);
  }

  double _dominantSize() {
    if (spans.isEmpty) return 0;
    final w = <double, int>{};
    for (final s in spans) {
      w[s.fontSize] = (w[s.fontSize] ?? 0) + math.max(1, s.text.trim().length);
    }
    return w.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  bool _majority(bool Function(RawTextSpan) test) {
    var total = 0, yes = 0;
    for (final s in spans) {
      final n = s.text.trim().length;
      total += n;
      if (test(s)) yes += n;
    }
    return total > 0 && yes * 2 > total;
  }

  List<_Cell> _buildCells() {
    final cells = <_Cell>[];
    var current = <RawTextSpan>[];
    for (final s in spans) {
      if (s.text.trim().isEmpty) continue;
      if (current.isNotEmpty && s.x0 - current.last.x1 > 0.7 * math.max(s.fontSize, current.last.fontSize)) {
        cells.add(_Cell(current));
        current = [];
      }
      current.add(s);
    }
    if (current.isNotEmpty) cells.add(_Cell(current));
    return cells;
  }
}

class _Split {
  _Split(this.left, this.right, this.spanning);

  final List<_Item> left;
  final List<_Item> right;
  final List<_Item> spanning;
}

class _ListMarker {
  _ListMarker(this.marker, this.ordered, this.length, {required this.glyph});

  final String marker;
  final bool ordered;

  /// Number of characters (marker + following whitespace) to drop.
  final int length;

  /// True for typographic bullets (•, ◦, ...) which are never wrapped text.
  final bool glyph;
}

class _ListBuilder {
  _ListBuilder(this.first, this.marker, this.textX) : markerX = first.x0 {
    lines.add(first);
  }

  final _Item first;
  final _ListMarker marker;
  final double markerX;
  final double textX;
  final List<_Item> lines = [];
}

/// Intermediate block with geometry, used for page-level post-processing.
class _Blk {
  _Blk(this.block, this.y0, this.y1, {required this.colX0, this.markerX});

  DocBlock block;
  final double y0, y1;
  final double colX0;
  final double? markerX;
}

class _TableRun {
  _TableRun(this.end, this.block);

  final int end;
  final TableBlock block;
}

// ---------------------------------------------------------------------------
// Page analyzer
// ---------------------------------------------------------------------------

class _PageAnalyzer {
  _PageAnalyzer(this.page, this.stats);

  final RawPageContent page;
  final DocumentStats stats;

  double get body => stats.bodyFontSize;

  List<DocBlock> run() {
    final options = stats.options;
    var lines = page.lines.where((l) => l.spans.isNotEmpty && l.text.trim().isNotEmpty).toList();

    if (options.removeHeadersFooters && lines.isNotEmpty) {
      final top = lines.reduce((a, b) => a.y0 <= b.y0 ? a : b);
      final bottom = lines.reduce((a, b) => a.y1 >= b.y1 ? a : b);
      lines = lines.where((l) {
        final t = l.text;
        if (DocumentStats.isInMargin(l, page) &&
            (stats.repeatedMarginTexts.contains(DocumentStats.normalizeMarginText(t)) ||
                DocumentStats.isPageNumberText(t))) {
          return false;
        }
        if ((identical(l, top) || identical(l, bottom)) && DocumentStats.isPageNumberText(t)) {
          final cy = (l.y0 + l.y1) / 2;
          if (cy < page.height * 0.15 || cy > page.height * 0.85) return false;
        }
        return true;
      }).toList();
    }

    final items = <_Item>[];
    for (final l in lines) {
      final spans = l.spans.where((s) => s.text.isNotEmpty).toList();
      if (spans.isNotEmpty) items.add(_Item.text(spans, l.y0, l.y1));
    }
    final hasText = items.isNotEmpty;

    if (options.includeImages) {
      final pageArea = page.width * page.height;
      for (final img in page.images) {
        final bytes = img.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        if (img.width < 24 || img.height < 24) continue;
        if (pageArea > 0) {
          final ix = math.max(0.0, math.min(img.x1, page.width) - math.max(img.x0, 0.0));
          final iy = math.max(0.0, math.min(img.y1, page.height) - math.max(img.y0, 0.0));
          if (ix * iy / pageArea > 0.9 && hasText) continue; // scanned background
        }
        items.add(_Item.image(img));
      }
    }
    if (items.isEmpty) return const [];

    final textItems = items.where((i) => !i.isImage);
    final extentSource = textItems.isNotEmpty ? textItems : items;
    var ex0 = extentSource.map((i) => i.x0).reduce(math.min);
    var ex1 = extentSource.map((i) => i.x1).reduce(math.max);
    final tl = stats.textLeft, tr = stats.textRight;
    if (tl != null && tr != null && tl < ex1 && tr > ex0 && tr <= page.width) {
      ex0 = math.min(ex0, tl);
      ex1 = math.max(ex1, tr);
    }
    final ordered = _order(items, ex0, ex1, 0);
    return _buildBlocks(ordered);
  }

  // ------------------------------------------------------------ reading order

  List<_Item> _order(List<_Item> items, double ex0, double ex1, int depth) {
    if (items.isEmpty) return items;
    if (items.length == 1 || depth > 8) return _leaf(items, ex0, ex1);
    final split = _findGutter(items);
    if (split == null) {
      final bands = _bands(items);
      if (bands.length > 1) {
        return [for (final b in bands) ..._order(b, ex0, ex1, depth + 1)];
      }
      return _leaf(items, ex0, ex1);
    }

    (double, double) extent(List<_Item> side) {
      final src = side.where((i) => !i.isImage).isNotEmpty ? side.where((i) => !i.isImage) : side;
      return (src.map((i) => i.x0).reduce(math.min), src.map((i) => i.x1).reduce(math.max));
    }

    final (lx0, lx1) = extent(split.left);
    final (rx0, rx1) = extent(split.right);
    final sides = <_Item, int>{};
    for (final i in split.left) {
      sides[i] = -1;
    }
    for (final i in split.right) {
      sides[i] = 1;
    }
    for (final i in split.spanning) {
      sides[i] = 0;
    }
    final all = [...split.left, ...split.right, ...split.spanning]..sort((a, b) => a.y0.compareTo(b.y0));

    final result = <_Item>[];
    var runL = <_Item>[], runR = <_Item>[];
    void flushRun() {
      result.addAll(_order(runL, lx0, lx1, depth + 1));
      result.addAll(_order(runR, rx0, rx1, depth + 1));
      runL = [];
      runR = [];
    }

    for (final it in all) {
      final side = sides[it]!;
      if (side == 0) {
        flushRun();
        it.colX0 = ex0;
        it.colX1 = ex1;
        result.add(it);
      } else if (side < 0) {
        runL.add(it);
      } else {
        runR.add(it);
      }
    }
    flushRun();
    return result;
  }

  /// Orders a single-column region top to bottom, merging fragments that sit
  /// on the same visual row.
  List<_Item> _leaf(List<_Item> items, double ex0, double ex1) {
    final sorted = List<_Item>.of(items)..sort((a, b) => a.y0.compareTo(b.y0));
    final rows = <List<_Item>>[];
    for (final it in sorted) {
      if (!it.isImage && rows.isNotEmpty) {
        final ref = rows.last.first;
        if (!ref.isImage &&
            (ref.cy - it.cy).abs() < 0.35 * math.min(ref.height, it.height) &&
            rows.last.every((r) => !r.isImage)) {
          rows.last.add(it);
          continue;
        }
      }
      rows.add([it]);
    }
    final out = <_Item>[];
    for (final row in rows) {
      _Item item;
      if (row.length == 1) {
        item = row.first;
      } else {
        item = _Item.text(
          [for (final r in row) ...r.spans],
          row.map((r) => r.y0).reduce(math.min),
          row.map((r) => r.y1).reduce(math.max),
        );
      }
      item.colX0 = ex0;
      item.colX1 = ex1;
      out.add(item);
    }
    return out;
  }

  /// Splits items into horizontal bands separated by vertical whitespace.
  List<List<_Item>> _bands(List<_Item> items) {
    final sorted = List<_Item>.of(items)..sort((a, b) => a.y0.compareTo(b.y0));
    final bands = <List<_Item>>[];
    var maxY = double.negativeInfinity;
    for (final it in sorted) {
      if (bands.isEmpty || it.y0 - maxY > 0.8 * body) {
        bands.add([it]);
      } else {
        bands.last.add(it);
      }
      maxY = math.max(maxY, it.y1);
    }
    return bands;
  }

  /// Finds a vertical whitespace gutter using an x-coverage histogram over the
  /// spans of [items]. Lines crossing the gutter (full-width titles, abstracts,
  /// figures) are allowed up to 75% of the items and are returned as
  /// `spanning`; the side-by-side validation in [_evaluateGutter] is what
  /// rejects single-column text and tables.
  _Split? _findGutter(List<_Item> items) {
    final minX = items.map((i) => i.x0).reduce(math.min);
    final maxX = items.map((i) => i.x1).reduce(math.max);
    final n = (maxX - minX).round();
    if (n < 16 * body) return null;
    final counts = List<int>.filled(n, 0);
    for (final it in items) {
      for (final (a, b) in it.segments) {
        final s = (a - minX).round().clamp(0, n);
        final e = (b - minX).round().clamp(0, n);
        for (var k = s; k < e; k++) {
          counts[k]++;
        }
      }
    }
    final maxK = (items.length * 0.75).floor();
    final ks = counts.toSet().where((c) => c <= maxK).toList()..sort();
    final minGutter = math.max(6.0, body);
    for (final k in ks) {
      final runs = <(int, int)>[];
      var i = 0;
      while (i < n) {
        if (counts[i] <= k) {
          var j = i;
          while (j < n && counts[j] <= k) {
            j++;
          }
          if (i > 0 && j < n && j - i >= minGutter) runs.add((i, j));
          i = j;
        } else {
          i++;
        }
      }
      runs.sort((a, b) => (b.$2 - b.$1).compareTo(a.$2 - a.$1));
      for (final (a, b) in runs) {
        final split = _evaluateGutter(items, minX + a, minX + b);
        if (split != null) return split;
      }
    }
    return null;
  }

  _Split? _evaluateGutter(List<_Item> items, double g0, double g1) {
    const tol = 0.5;
    final left = <_Item>[], right = <_Item>[], spanning = <_Item>[];
    for (final it in items) {
      if (it.isImage) {
        if (it.x1 <= g0 + tol) {
          left.add(it);
        } else if (it.x0 >= g1 - tol) {
          right.add(it);
        } else {
          spanning.add(it);
        }
        continue;
      }
      final l = <RawTextSpan>[], r = <RawTextSpan>[];
      var crosses = false;
      final mid = (g0 + g1) / 2;
      for (final s in it.spans) {
        if (s.x1 <= g0 + tol) {
          l.add(s);
        } else if (s.x0 >= g1 - tol) {
          r.add(s);
        } else if ((s.x0 + s.x1) / 2 < mid && s.x1 < g1 + body * 0.5 && s.x0 < g0 - 2 * body) {
          l.add(s); // a justified line poking slightly into the gutter
        } else if ((s.x0 + s.x1) / 2 >= mid && s.x0 > g0 - body * 0.5 && s.x1 > g1 + 2 * body) {
          r.add(s);
        } else {
          crosses = true;
          break;
        }
      }
      if (crosses) {
        spanning.add(it);
        continue;
      }
      if (l.isNotEmpty && r.isEmpty) {
        left.add(it);
      } else if (r.isNotEmpty && l.isEmpty) {
        right.add(it);
      } else {
        left.add(_Item.text(l, it.y0, it.y1));
        right.add(_Item.text(r, it.y0, it.y1));
      }
    }
    final lt = left.where((i) => !i.isImage).toList();
    final rt = right.where((i) => !i.isImage).toList();
    if (lt.length < 3 || rt.length < 3) return null;

    bool textLike(List<_Item> side) {
      final avgChars = side.fold<int>(0, (a, i) => a + i.charCount) / side.length;
      if (avgChars < 12) return false;
      final w = side.map((i) => i.x1).reduce(math.max) - side.map((i) => i.x0).reduce(math.min);
      if (w < 8 * body) return false;
      final wide = side.where((i) => i.width >= 0.6 * w).length;
      return wide >= 0.4 * side.length;
    }

    if (!textLike(lt) || !textLike(rt)) return null;

    // The two sides must sit next to each other, not stacked vertically.
    final ly0 = lt.map((i) => i.y0).reduce(math.min), ly1 = lt.map((i) => i.y1).reduce(math.max);
    final ry0 = rt.map((i) => i.y0).reduce(math.min), ry1 = rt.map((i) => i.y1).reduce(math.max);
    final lInR = lt.where((i) => i.cy >= ry0 && i.cy <= ry1).length;
    final rInL = rt.where((i) => i.cy >= ly0 && i.cy <= ly1).length;
    if (lInR < 2 || rInL < 2) return null;
    return _Split(left, right, spanning);
  }

  // ------------------------------------------------------------ block building

  double _pitch(double size) => stats.expectedPitch(size);

  bool _sameColumn(_Item a, _Item b) => (a.colX0 - b.colX0).abs() <= 1 && (a.colX1 - b.colX1).abs() <= 1;

  bool _sizeClose(double a, double b) => (a - b).abs() <= math.max(0.6, a * 0.08);

  bool _isCentered(_Item it) {
    final em = it.fontSize;
    final colCenter = (it.colX0 + it.colX1) / 2;
    return (it.x0 + it.x1) / 2 - colCenter < em && colCenter - (it.x0 + it.x1) / 2 < em && it.x0 - it.colX0 > 2 * em;
  }

  _ListMarker? _matchListMarker(String text) {
    var m = _bulletRe.firstMatch(text);
    if (m != null && m.end < text.length) return _ListMarker(m.group(1)!, false, m.end, glyph: true);
    m = _dashBulletRe.firstMatch(text);
    if (m != null && m.end < text.length) return _ListMarker(m.group(1)!, false, m.end, glyph: false);
    m = _numberedRe.firstMatch(text);
    if (m != null) return _ListMarker(m.group(1)!, true, m.end, glyph: false);
    return null;
  }

  double _textStartX(_Item it, _ListMarker m) {
    // Marker drawn as its own span (common with symbol fonts / tab stops).
    final firstText = it.spans.first.text.trim();
    if (it.spans.length > 1 && firstText.isNotEmpty && m.marker.startsWith(firstText.trim())) {
      final idx = it.spans.indexWhere((s) => s.x0 > it.spans.first.x1 - 0.1 && s.text.trim().isNotEmpty);
      if (idx > 0 && firstText == m.marker) return it.spans[idx].x0;
    }
    final len = it.text.length;
    if (len == 0) return it.x0;
    return it.x0 + it.width * (m.length / len);
  }

  /// Whether a paragraph whose last line is [p] (paragraph so far: [para])
  /// continues with line [n].
  bool _canJoin(List<_Item> para, _Item n) {
    if (n.isImage || para.isEmpty) return false;
    final p = para.last;
    final size = p.fontSize;
    if (!_sizeClose(size, n.fontSize)) return false;
    final em = size;
    // A line directly below the previous one, left-aligned with it and
    // horizontally contained in it, continues the same flow even when the two
    // were assigned different column extents (e.g. the short last line of a
    // full-width paragraph sitting above a two-column body).
    final stacked =
        n.y0 > p.y0 && n.y0 - p.y0 <= _pitch(size) * 1.45 && (n.x0 - p.x0).abs() <= 0.6 * em && n.x1 <= p.x1 + 0.6 * em;
    if (!_sameColumn(p, n) && !stacked) {
      // Paragraph flowing from the bottom of one column to the top of the next.
      if (_endsSentence(p.text)) return false;
      if (n.x0 - n.colX0 > 0.8 * em) return false;
      if (n.y0 >= p.y0) return false;
      return true;
    }
    final pitch = n.y0 - p.y0;
    if (pitch <= 0.3 * size || pitch > _pitch(size) * 1.45) return false;
    final dx = n.x0 - p.x0;
    final tol = 0.6 * em;
    var edgeOk = false;
    if (dx.abs() <= tol) {
      edgeOk = true;
    } else if (dx < -tol &&
        para.length == 1 &&
        -dx <= 5 * em &&
        p.italic == n.italic &&
        (n.x0 - n.colX0).abs() <= tol) {
      edgeOk = true; // first-line indent
    } else if (_isCentered(p) && _isCentered(n)) {
      edgeOk = true;
    }
    if (!edgeOk) return false;
    final shortBy = p.colX1 - p.x1;
    if (shortBy > math.max(3 * em, 0.12 * p.colWidth) && _endsSentence(p.text)) return false;
    return true;
  }

  bool _listAccepts(_ListBuilder li, _Item n) {
    if (n.isImage) return false;
    final last = li.lines.last;
    if (!_sizeClose(last.fontSize, n.fontSize) || !_sameColumn(last, n)) return false;
    final em = last.fontSize;
    final pitch = n.y0 - last.y0;
    if (pitch <= 0.3 * em || pitch > _pitch(em) * 1.45) return false;
    if (n.x0 >= li.markerX + 0.4 * em && n.x0 <= li.textX + 2 * em) return true;
    if ((n.x0 - li.markerX).abs() < 0.4 * em && !_endsSentence(last.text) && last.colX1 - last.x1 < 3 * em) {
      return true;
    }
    return false;
  }

  /// Level of the heading most recently recognized by [_headingEnd].
  int _headingLevel = 1;

  bool _headingStyleContinues(_Item a, _Item b) {
    if (b.isImage || !_sameColumn(a, b)) return false;
    if ((a.fontSize - b.fontSize).abs() > 0.5 || a.bold != b.bold) return false;
    final pitch = b.y0 - a.y0;
    if (pitch <= 0.3 * a.fontSize || pitch > 2.0 * a.fontSize) return false;
    if (_bulletRe.hasMatch(b.text)) return false;
    return true;
  }

  bool _followedBySpacing(List<_Item> items, int j) {
    final it = items[j];
    if (j + 1 >= items.length) return true;
    final next = items[j + 1];
    if (next.isImage || !_sameColumn(it, next)) return true;
    final pitch = next.y0 - it.y0;
    if (pitch < 0 || pitch > 1.3 * _pitch(it.fontSize)) return true;
    if (next.fontSize > it.fontSize + 0.5) return true;
    if (!next.bold && it.width < 0.7 * it.colWidth) return true;
    return false;
  }

  /// If a heading starts at item [i], returns the index of its last line
  /// (consecutive same-style lines are merged) and sets [_headingLevel].
  int? _headingEnd(List<_Item> items, int i, bool listContext) {
    final it = items[i];
    final text = it.text.trim();
    if (!_letterRe.hasMatch(text) || _bulletRe.hasMatch(text)) return null;
    if (listContext && _matchListMarker(text) != null) return null;
    final level = stats.headingLevelForSize(it.fontSize);
    if (level != null) {
      var j = i;
      var chars = it.charCount;
      while (j + 1 < items.length && _headingStyleContinues(items[j], items[j + 1])) {
        if (chars + items[j + 1].charCount > 250) break;
        j++;
        chars += items[j].charCount;
      }
      if (chars > 250) return null;
      _headingLevel = level;
      return j;
    }
    final size = it.fontSize;
    if (!it.bold || size < body * 0.9 || size >= body * DocumentStats.headingRatio) return null;
    if (text.length >= 80) return null;
    var j = i;
    var chars = it.charCount;
    while (j + 1 < items.length && j - i < 2 && _headingStyleContinues(items[j], items[j + 1])) {
      final next = items[j + 1];
      if (next.text.trim().length >= 80 || _periodEndRe.hasMatch(items[j].text.trim())) break;
      if ((next.y0 - items[j].y0) > 1.3 * _pitch(size)) break;
      j++;
      chars += next.charCount;
    }
    if (chars > 160) return null;
    if (_periodEndRe.hasMatch(items[j].text.trim())) return null;
    // A numbered list item in bold is a heading only when it looks like a section number.
    if (_matchListMarker(text) != null && !_numberedHeadingRe.hasMatch(text)) return null;
    if (!_followedBySpacing(items, j)) return null;
    _headingLevel = stats.boldHeadingLevel;
    return j;
  }

  List<DocBlock> _buildBlocks(List<_Item> items) {
    final pageNo = page.pageNumber;
    final tables = stats.options.detectTables ? _detectTables(items) : const <int, _TableRun>{};
    final out = <_Blk>[];
    var para = <_Item>[];
    _ListBuilder? li;
    final deferred = <_Item>[];

    void flush() {
      if (para.isNotEmpty) {
        out.add(_paragraphBlk(para));
        para = [];
      }
      if (li != null) {
        out.add(_listBlk(li!));
        li = null;
      }
      for (final img in deferred) {
        final b = _imageBlk(img);
        if (b != null) out.add(b);
      }
      deferred.clear();
    }

    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final table = tables[i];
      if (table != null) {
        flush();
        final rows = items.sublist(i, table.end + 1);
        out.add(
          _Blk(
            table.block,
            rows.map((r) => r.y0).reduce(math.min),
            rows.map((r) => r.y1).reduce(math.max),
            colX0: it.colX0,
          ),
        );
        i = table.end;
        continue;
      }
      if (it.isImage) {
        if (para.isNotEmpty || li != null) {
          final k = items.indexWhere((x) => !x.isImage, i + 1);
          if (k > 0 && !tables.containsKey(k)) {
            final joins = para.isNotEmpty ? _canJoin(para, items[k]) : _listAccepts(li!, items[k]);
            if (joins) {
              deferred.add(it);
              continue;
            }
          }
        }
        flush();
        final b = _imageBlk(it);
        if (b != null) out.add(b);
        continue;
      }

      final listContext = li != null || (out.isNotEmpty && out.last.block is ListItemBlock);
      final hEnd = _headingEnd(items, i, listContext);
      if (hEnd != null) {
        flush();
        final group = items.sublist(i, hEnd + 1);
        out.add(
          _Blk(
            HeadingBlock(level: _headingLevel, spans: _joinLines(group.map((g) => g.textSpans)), pageNumber: pageNo),
            group.first.y0,
            group.last.y1,
            colX0: it.colX0,
          ),
        );
        i = hEnd;
        continue;
      }

      final marker = _matchListMarker(it.text);
      if (marker != null) {
        var wrapped = false;
        if (!marker.glyph && para.isNotEmpty) {
          final p = para.last;
          wrapped =
              _sameColumn(p, it) &&
              !_endsSentence(p.text) &&
              (it.x0 - p.x0).abs() <= 0.6 * p.fontSize &&
              p.colX1 - p.x1 < 3 * p.fontSize &&
              _canJoin(para, it);
        }
        if (!wrapped) {
          flush();
          li = _ListBuilder(it, marker, _textStartX(it, marker));
          continue;
        }
      }

      if (li != null) {
        if (_listAccepts(li!, it)) {
          li!.lines.add(it);
          continue;
        }
        flush();
      }

      if (para.isNotEmpty && _canJoin(para, it)) {
        para.add(it);
      } else {
        flush();
        para = [it];
      }
    }
    flush();

    _assignListIndents(out);
    _attachCaptions(out);
    return [for (final b in out) b.block];
  }

  _Blk _paragraphBlk(List<_Item> lines) {
    final spans = _joinLines(lines.map((l) => l.textSpans));
    final y0 = lines.map((l) => l.y0).reduce(math.min);
    final y1 = lines.map((l) => l.y1).reduce(math.max);
    final first = lines.first;
    final text = spansToText(spans);
    if (!_captionRe.hasMatch(text) && first.colWidth > 20 * body) {
      final leftIndent = lines.map((l) => l.x0).reduce(math.min) - first.colX0;
      final rightIndent = first.colX1 - lines.map((l) => l.x1).reduce(math.max);
      final italicChars = lines.where((l) => l.italic).fold<int>(0, (a, l) => a + l.charCount);
      final totalChars = lines.fold<int>(0, (a, l) => a + l.charCount);
      final smaller = first.fontSize < body - 0.5;
      // Block quotes are indented on both sides by a modest amount; centered
      // short lines (bylines, subtitles) have much larger indents.
      if (leftIndent >= 1.5 * body &&
          leftIndent <= 0.25 * first.colWidth &&
          rightIndent >= 1.5 * body &&
          (italicChars * 2 > totalChars || smaller)) {
        return _Blk(
          QuoteBlock(spans: spans, pageNumber: page.pageNumber),
          y0,
          y1,
          colX0: first.colX0,
        );
      }
    }
    return _Blk(
      ParagraphBlock(spans: spans, pageNumber: page.pageNumber),
      y0,
      y1,
      colX0: first.colX0,
    );
  }

  _Blk _listBlk(_ListBuilder li) {
    final firstSpans = _dropChars(li.first.textSpans, li.marker.length);
    final spans = _joinLines([firstSpans, for (final l in li.lines.skip(1)) l.textSpans]);
    return _Blk(
      ListItemBlock(spans: spans, ordered: li.marker.ordered, marker: li.marker.marker, pageNumber: page.pageNumber),
      li.lines.first.y0,
      li.lines.last.y1,
      colX0: li.first.colX0,
      markerX: li.markerX,
    );
  }

  _Blk? _imageBlk(_Item it) {
    final img = it.image!;
    final bytes = img.bytes;
    if (bytes == null) return null;
    return _Blk(
      ImageBlock(
        bytes: bytes,
        width: img.pixelWidth > 0 ? img.pixelWidth : img.width.round(),
        height: img.pixelHeight > 0 ? img.pixelHeight : img.height.round(),
        pageNumber: page.pageNumber,
      ),
      img.y0,
      img.y1,
      colX0: it.colX0,
    );
  }

  void _assignListIndents(List<_Blk> out) {
    var i = 0;
    while (i < out.length) {
      if (out[i].block is! ListItemBlock) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < out.length && out[j + 1].block is ListItemBlock && (out[j + 1].colX0 - out[i].colX0).abs() <= 1) {
        j++;
      }
      final xs = [for (var k = i; k <= j; k++) out[k].markerX!]..sort();
      final levels = <double>[];
      for (final x in xs) {
        if (levels.isEmpty || x - levels.last > 0.6 * body) levels.add(x);
      }
      for (var k = i; k <= j; k++) {
        final b = out[k].block as ListItemBlock;
        var level = 0;
        for (var l = 0; l < levels.length; l++) {
          if (out[k].markerX! >= levels[l] - 0.6 * body) level = l;
        }
        out[k].block = ListItemBlock(
          spans: b.spans,
          ordered: b.ordered,
          marker: b.marker,
          indent: level,
          pageNumber: b.pageNumber,
        );
      }
      i = j + 1;
    }
  }

  void _attachCaptions(List<_Blk> out) {
    final maxDist = 3 * stats.lineSpacing;
    String? captionOf(_Blk b) {
      final block = b.block;
      if (block is! ParagraphBlock) return null;
      final t = block.text;
      if (t.length > 400 || !_captionRe.hasMatch(t)) return null;
      return t;
    }

    for (var i = 0; i < out.length; i++) {
      final img = out[i].block;
      if (img is! ImageBlock || img.caption != null) continue;
      int? capIdx;
      if (i + 1 < out.length) {
        final c = out[i + 1];
        final d = c.y0 - out[i].y1;
        final followedByTable = i + 2 < out.length && out[i + 2].block is TableBlock;
        final cap = captionOf(c);
        if (cap != null && d >= -2 && d <= maxDist && !(followedByTable && cap.toLowerCase().startsWith('table'))) {
          capIdx = i + 1;
        }
      }
      if (capIdx == null && i > 0) {
        final c = out[i - 1];
        final d = out[i].y0 - c.y1;
        if (captionOf(c) != null && d >= -2 && d <= maxDist) capIdx = i - 1;
      }
      if (capIdx == null) continue;
      final caption = captionOf(out[capIdx])!;
      out[i].block = ImageBlock(
        bytes: img.bytes,
        width: img.width,
        height: img.height,
        caption: caption,
        pageNumber: img.pageNumber,
      );
      out.removeAt(capIdx);
      if (capIdx < i) i--;
    }
  }

  // ------------------------------------------------------------ tables

  bool _isTableCandidate(_Item it) {
    if (it.isImage) return false;
    final cells = it.cells;
    if (cells.length < 2) return false;
    if (cells.length == 2 && _matchListMarker('${cells.first.text} x') != null && cells.first.text.length <= 5) {
      return false; // bullet / number drawn as a separate span
    }
    return true;
  }

  bool _rowCompatible(_Item a, _Item b) {
    if (a.isImage || b.isImage || !_sameColumn(a, b)) return false;
    final pitch = b.y0 - a.y0;
    if (pitch <= 0.3 * a.fontSize || pitch > 3 * _pitch(a.fontSize)) return false;
    final ratio = a.fontSize / b.fontSize;
    return ratio > 0.7 && ratio < 1.43;
  }

  Map<int, _TableRun> _detectTables(List<_Item> items) {
    final result = <int, _TableRun>{};
    var i = 0;
    while (i < items.length) {
      if (!_isTableCandidate(items[i])) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < items.length) {
        final next = items[j + 1];
        if (!_rowCompatible(items[j], next)) break;
        if (_isTableCandidate(next)) {
          j++;
          continue;
        }
        // Wrapped cell text on its own line inside the table.
        if (j + 2 < items.length &&
            next.x0 > items[i].x0 + next.fontSize &&
            _isTableCandidate(items[j + 2]) &&
            _rowCompatible(next, items[j + 2])) {
          j++;
          continue;
        }
        break;
      }
      if (j > i) {
        final block = _buildTable(items.sublist(i, j + 1));
        if (block != null) {
          result[i] = _TableRun(j, block);
          i = j + 1;
          continue;
        }
      }
      i++;
    }
    return result;
  }

  TableBlock? _buildTable(List<_Item> rows) {
    final em = rows.first.fontSize;
    final intervals = [
      for (final r in rows)
        for (final c in r.cells) (c.x0, c.x1),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final cols = <(double, double)>[];
    for (final (a, b) in intervals) {
      if (cols.isNotEmpty && a <= cols.last.$2 + 0.25 * em) {
        cols[cols.length - 1] = (cols.last.$1, math.max(cols.last.$2, b));
      } else {
        cols.add((a, b));
      }
    }
    final c = cols.length;
    if (c < 2) return null;

    int colOf(_Cell cell) {
      for (var k = 0; k < c; k++) {
        if (cell.x0 >= cols[k].$1 - 0.5 && cell.x1 <= cols[k].$2 + 0.5) return k;
      }
      return 0;
    }

    final grid = <List<String>>[];
    final styleRows = <_Item>[];
    for (final r in rows) {
      final cells = List<String>.filled(c, '');
      for (final cell in r.cells) {
        final k = colOf(cell);
        cells[k] = cells[k].isEmpty ? cell.text : '${cells[k]} ${cell.text}';
      }
      final isContinuation = r.cells.length < 2 && grid.isNotEmpty;
      if (isContinuation) {
        final prev = grid.last;
        for (var k = 0; k < c; k++) {
          if (cells[k].isEmpty) continue;
          prev[k] = prev[k].isEmpty ? cells[k] : '${prev[k]} ${cells[k]}';
        }
      } else {
        grid.add(cells);
        styleRows.add(r);
      }
    }
    if (grid.length < 2) return null;
    final filled = grid.fold<int>(0, (a, r) => a + r.where((s) => s.isNotEmpty).length);
    if (grid.length == 2 && filled < 2 * c) return null;
    if (filled < 0.6 * grid.length * c) return null;
    for (var k = 0; k < c; k++) {
      final used = grid.where((r) => r[k].isNotEmpty).length;
      if (used < math.min(2, grid.length)) return null;
    }
    // Two long prose cells per row: a two-column page layout, not a table.
    if (c == 2) {
      final avg = grid.fold<int>(0, (a, r) => a + r[0].length + r[1].length) / (2 * grid.length);
      if (avg >= 25) return null;
    }

    String styleKey(_Item it) => '${it.bold}|${it.italic}|${it.fontSize.round()}';
    var hasHeader = false;
    if (styleRows.length >= 2) {
      final firstKey = styleKey(styleRows.first);
      final others = styleRows.skip(1).map(styleKey).toList();
      final sameAsFirst = others.where((k) => k == firstKey).length;
      hasHeader = sameAsFirst * 2 < others.length || (sameAsFirst == 0);
      if (!hasHeader && styleRows.first.cells.every((cell) => cell.bold) && !styleRows.skip(1).every((r) => r.bold)) {
        hasHeader = true;
      }
    }
    return TableBlock(rows: grid, hasHeader: hasHeader, pageNumber: page.pageNumber);
  }
}
