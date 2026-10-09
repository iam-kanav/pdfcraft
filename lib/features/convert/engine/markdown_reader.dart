import 'dart:convert';
import 'dart:typed_data';

import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// Parses Markdown (CommonMark + GitHub tables) into a [DocStructure].
///
/// Supported: ATX and setext headings, paragraphs (soft-wrapped lines are
/// joined, hard breaks kept as `\n`), `**bold**`/`__bold__`,
/// `*italic*`/`_italic_`, inline HTML `<b> <strong> <i> <em> <u> <br>`,
/// inline/reference/auto links, nested `-`/`*`/`+` and `1.`/`1)` lists,
/// `>` quotes, GFM pipe tables, fenced and indented code blocks (emitted as
/// paragraphs preserving their lines) and page-break markers. Horizontal
/// rules are ignored.
///
/// Images (`![alt](src)`) are resolved through [images] (keyed by the
/// referenced path, as produced by `buildMarkdownWithImages`) or from
/// `data:` URIs; unresolvable images are dropped.
DocStructure parseMarkdown(String md, {Map<String, Uint8List>? images}) {
  var text = md.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.startsWith('﻿')) text = text.substring(1);
  final lines = text.split('\n').map(_expandTabs).toList();
  final refs = <String, String>{};
  final kept = _extractReferenceDefinitions(lines, refs);
  final ctx = _Ctx(refs, images ?? const {});
  final blocks = _BlockParser(kept, ctx).parse();
  return DocStructure(blocks: blocks);
}

class _Ctx {
  _Ctx(this.refs, this.images);
  final Map<String, String> refs;
  final Map<String, Uint8List> images;
}

String _expandTabs(String line) {
  if (!line.contains('\t')) return line;
  final sb = StringBuffer();
  var col = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '\t') {
      final n = 4 - (col % 4);
      sb.write(' ' * n);
      col += n;
    } else {
      sb.write(c);
      col++;
    }
  }
  return sb.toString();
}

String _normalizeLabel(String label) =>
    label.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

final RegExp _refDef = RegExp(
  r'''^ {0,3}\[([^\]]+)\]:\s*(?:<([^>]*)>|(\S+))(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*$''',
);
final RegExp _fenceOpen = RegExp(r'^( {0,3})(`{3,}|~{3,})(.*)$');

List<String> _extractReferenceDefinitions(
  List<String> lines,
  Map<String, String> refs,
) {
  final out = <String>[];
  String? fence;
  var prevBlank = true;
  for (final line in lines) {
    final f = _fenceOpen.firstMatch(line);
    if (fence == null &&
        f != null &&
        !(f.group(2)!.startsWith('`') && f.group(3)!.contains('`'))) {
      fence = f.group(2)!;
      out.add(line);
      prevBlank = false;
      continue;
    }
    if (fence != null) {
      final t = line.trim();
      if (t.startsWith(fence[0] * fence.length) &&
          t.replaceAll(fence[0], '').isEmpty) {
        fence = null;
      }
      out.add(line);
      continue;
    }
    final m = prevBlank ? _refDef.firstMatch(line) : null;
    if (m != null) {
      refs.putIfAbsent(
        _normalizeLabel(m.group(1)!),
        () => (m.group(2) ?? m.group(3))!,
      );
      continue;
    }
    prevBlank = line.trim().isEmpty;
    out.add(line);
  }
  return out;
}

// ------------------------------------------------------------- blocks

final RegExp _atx = RegExp(
  r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$',
);
final RegExp _hr = RegExp(
  r'^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$',
);
final RegExp _setext1 = RegExp(r'^ {0,3}=+[ \t]*$');
final RegExp _setext2 = RegExp(r'^ {0,3}-+[ \t]*$');
final RegExp _bulletItem = RegExp(r'^( *)([-*+])( +|$)(.*)$');
final RegExp _orderedItem = RegExp(r'^( *)(\d{1,9})([.)])( +|$)(.*)$');
final RegExp _quoteLine = RegExp(r'^ {0,3}> ?(.*)$');
final RegExp _pageBreak = RegExp(
  r'^\s*(?:<div\b[^>]*page-break[^>]*>\s*(?:</div>)?|\\pagebreak|\\newpage|<!--\s*pagebreak\s*-->)\s*$',
  caseSensitive: false,
);
final RegExp _tableSeparator = RegExp(
  r'^ {0,3}\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$',
);

class _PendingItem {
  _PendingItem({
    required this.ordered,
    required this.marker,
    required this.level,
    required this.contentIndent,
  });
  final bool ordered;
  final String marker;
  final int level;
  final int contentIndent;

  /// Paragraphs of the item; each is a list of raw lines.
  final List<List<String>> paragraphs = [[]];
}

class _BlockParser {
  _BlockParser(this.lines, this.ctx);

  final List<String> lines;
  final _Ctx ctx;
  final List<DocBlock> out = [];
  final List<String> _para = [];
  _PendingItem? _item;
  bool _blankAfterItem = false;
  final List<int> _listStack = []; // marker indents of open list levels

  int _indentOf(String l) => l.length - l.trimLeft().length;

  List<DocBlock> parse() {
    var i = 0;
    while (i < lines.length) {
      i = _line(i);
    }
    _flushPara();
    _endList();
    return out;
  }

  bool _isTableStart(int i) {
    if (i + 1 >= lines.length) return false;
    final header = lines[i];
    final sep = lines[i + 1];
    if (!header.contains('|') ||
        !_tableSeparator.hasMatch(sep) ||
        !sep.contains('-')) {
      return false;
    }
    if (_indentOf(header) > 3) return false;
    final hc = _splitRow(header).length;
    final sc = _splitRow(sep).length;
    return hc == sc && (sep.contains('|') || hc == 1) && sep.contains('|');
  }

  bool _isListLine(String l) =>
      _bulletItem.hasMatch(l) || _orderedItem.hasMatch(l);

  /// True if [l] starts a block that interrupts a paragraph or lazy
  /// continuation.
  bool _startsBlock(int i) {
    final l = lines[i];
    if (l.trim().isEmpty) return true;
    if (_indentOf(l) > 3 && _item == null) return false;
    return _atx.hasMatch(l) ||
        _hr.hasMatch(l) ||
        _quoteLine.hasMatch(l) ||
        _fenceOpen.hasMatch(l) ||
        _pageBreak.hasMatch(l) ||
        _isTableStart(i) ||
        _interruptingListItem(l);
  }

  bool _interruptingListItem(String l) {
    final b = _bulletItem.firstMatch(l);
    if (b != null) return b.group(4)!.trim().isNotEmpty && !_hr.hasMatch(l);
    final o = _orderedItem.firstMatch(l);
    if (o != null) {
      if (o.group(5)!.trim().isEmpty) return false;
      // An ordered item only interrupts a plain paragraph when it starts at 1.
      return _item != null || o.group(2) == '1';
    }
    return false;
  }

  int _line(int i) {
    final line = lines[i];
    final trimmed = line.trim();
    final indent = _indentOf(line);

    if (trimmed.isEmpty) {
      _flushPara();
      if (_item != null) _blankAfterItem = true;
      return i + 1;
    }

    // Continuation paragraph inside a list item (indented after a blank).
    final item = _item;
    if (item != null &&
        _blankAfterItem &&
        indent >= item.contentIndent &&
        !_isListLine(line)) {
      item.paragraphs.add([line.trimLeft()]);
      _blankAfterItem = false;
      return i + 1;
    }

    // Lazy continuation of a list item's current paragraph.
    if (item != null &&
        !_blankAfterItem &&
        !_startsBlock(i) &&
        !_isListLine(line)) {
      item.paragraphs.last.add(line.trimLeft());
      return i + 1;
    }

    // Setext heading underline.
    if (_para.isNotEmpty &&
        indent <= 3 &&
        (_setext1.hasMatch(line) || _setext2.hasMatch(line))) {
      final level = _setext1.hasMatch(line) ? 1 : 2;
      final text = _para.join('\n');
      _para.clear();
      _addTextBlocks(
        _parseInline(text),
        (spans) => HeadingBlock(level: level, spans: _singleLine(spans)),
      );
      return i + 1;
    }

    // Fenced code.
    final fence = indent <= 3 || _item != null
        ? _fenceOpen.firstMatch(line.trimLeft())
        : null;
    if (fence != null &&
        !(fence.group(2)!.startsWith('`') && fence.group(3)!.contains('`'))) {
      _flushPara();
      _endList();
      final marker = fence.group(2)!;
      final code = <String>[];
      var j = i + 1;
      while (j < lines.length) {
        final t = lines[j].trim();
        if (t.length >= marker.length &&
            t.startsWith(marker[0] * marker.length) &&
            t.replaceAll(marker[0], '').isEmpty) {
          j++;
          break;
        }
        var l = lines[j];
        var strip = indent;
        while (strip > 0 && l.startsWith(' ')) {
          l = l.substring(1);
          strip--;
        }
        code.add(l);
        j++;
      }
      while (code.isNotEmpty && code.last.trim().isEmpty) {
        code.removeLast();
      }
      if (code.isNotEmpty) {
        out.add(ParagraphBlock(spans: [TextSpanData(code.join('\n'))]));
      }
      return j;
    }

    // Page break marker.
    if (_pageBreak.hasMatch(line)) {
      _flushPara();
      _endList();
      out.add(const PageBreakBlock());
      return i + 1;
    }

    // ATX heading.
    final atx = indent <= 3 ? _atx.firstMatch(line) : null;
    if (atx != null) {
      _flushPara();
      _endList();
      final level = atx.group(1)!.length;
      final content = atx.group(2) ?? '';
      _addTextBlocks(
        _parseInline(content),
        (spans) => HeadingBlock(level: level, spans: spans),
      );
      return i + 1;
    }

    // Thematic break (ignored).
    if (_hr.hasMatch(line)) {
      _flushPara();
      _endList();
      return i + 1;
    }

    // Block quote.
    if (indent <= 3 && _quoteLine.hasMatch(line)) {
      _flushPara();
      _endList();
      final inner = <String>[];
      var j = i;
      while (j < lines.length) {
        final m = _quoteLine.firstMatch(lines[j]);
        if (m != null) {
          inner.add(m.group(1)!);
        } else if (lines[j].trim().isNotEmpty &&
            inner.isNotEmpty &&
            inner.last.trim().isNotEmpty &&
            !_startsBlock(j)) {
          inner.add(lines[j]); // lazy continuation
        } else {
          break;
        }
        j++;
      }
      final nested = _BlockParser(inner, ctx).parse();
      for (final b in nested) {
        switch (b) {
          case HeadingBlock():
            out.add(QuoteBlock(spans: b.spans));
          case ParagraphBlock():
            out.add(QuoteBlock(spans: b.spans));
          case QuoteBlock():
            out.add(b);
          case ListItemBlock():
            out.add(
              QuoteBlock(
                spans: [TextSpanData('${b.marker ?? '•'} '), ...b.spans],
              ),
            );
          case TableBlock():
            out.add(QuoteBlock(spans: [TextSpanData(b.plainText)]));
          case ImageBlock():
            out.add(b);
          case PageBreakBlock():
            break;
        }
      }
      return j;
    }

    // GFM table.
    if (_isTableStart(i)) {
      _flushPara();
      _endList();
      return _table(i);
    }

    // List item.
    final bullet = _bulletItem.firstMatch(line);
    final ordered = bullet == null ? _orderedItem.firstMatch(line) : null;
    if ((bullet != null || ordered != null) &&
        (_para.isEmpty || _interruptingListItem(line))) {
      _flushPara();
      _finishItem();
      final markerIndent = bullet != null
          ? bullet.group(1)!.length
          : ordered!.group(1)!.length;
      final markerText = bullet != null
          ? bullet.group(2)!
          : '${ordered!.group(2)}${ordered.group(3)}';
      final spacing =
          (bullet != null ? bullet.group(3) : ordered!.group(4))!.length;
      final content = (bullet != null ? bullet.group(4) : ordered!.group(5))!;
      if (_blankAfterItem &&
          _listStack.isNotEmpty &&
          markerIndent < _listStack.first) {
        _endList();
      }
      while (_listStack.isNotEmpty && markerIndent < _listStack.last + 2) {
        _listStack.removeLast();
      }
      final level = _listStack.length;
      _listStack.add(markerIndent);
      final contentIndent =
          markerIndent +
          markerText.length +
          (spacing == 0 || spacing > 4 ? 1 : spacing);
      _item = _PendingItem(
        ordered: ordered != null,
        marker: ordered != null ? markerText : '•',
        level: level,
        contentIndent: contentIndent,
      );
      _item!.paragraphs.last.add(content.trimLeft());
      _blankAfterItem = false;
      return i + 1;
    }

    // Indented code block.
    if (indent >= 4 && _para.isEmpty && _item == null) {
      final code = <String>[];
      var j = i;
      while (j < lines.length &&
          (lines[j].trim().isEmpty || _indentOf(lines[j]) >= 4)) {
        code.add(lines[j].length >= 4 ? lines[j].substring(4) : '');
        j++;
      }
      while (code.isNotEmpty && code.last.trim().isEmpty) {
        code.removeLast();
      }
      out.add(ParagraphBlock(spans: [TextSpanData(code.join('\n'))]));
      return j;
    }

    // Paragraph text. A non-indented line after a blank ends any open list.
    if (_item != null) _endList();
    _para.add(line.trimLeft());
    return i + 1;
  }

  List<TextSpanData> _singleLine(List<TextSpanData> spans) =>
      spans.map((s) => s.copyWith(text: s.text.replaceAll('\n', ' '))).toList();

  int _table(int i) {
    final header = _splitRow(lines[i]);
    final cols = header.length;
    final rows = <List<String>>[header.map(_cellText).toList()];
    var j = i + 2;
    while (j < lines.length) {
      final l = lines[j];
      if (l.trim().isEmpty || !l.contains('|')) break;
      if (_atx.hasMatch(l) ||
          _quoteLine.hasMatch(l) ||
          _fenceOpen.hasMatch(l)) {
        break;
      }
      final cells = _splitRow(l).map(_cellText).toList();
      while (cells.length < cols) {
        cells.add('');
      }
      rows.add(cells.sublist(0, cols));
      j++;
    }
    var hasHeader = true;
    if (rows.first.every((c) => c.trim().isEmpty)) {
      rows.removeAt(0);
      hasHeader = false;
    }
    if (rows.isNotEmpty) out.add(TableBlock(rows: rows, hasHeader: hasHeader));
    return j;
  }

  String _cellText(String raw) {
    final items = _parseInline(raw.trim());
    return items.whereType<TextSpanData>().map((s) => s.text).join();
  }

  void _flushPara() {
    if (_para.isEmpty) return;
    final text = _para.join('\n');
    _para.clear();
    _addTextBlocks(_parseInline(text), (spans) => ParagraphBlock(spans: spans));
  }

  /// Emits text blocks, splitting around images.
  void _addTextBlocks(
    List<Object> items,
    DocBlock Function(List<TextSpanData>) make,
  ) {
    var buf = <TextSpanData>[];
    void flush() {
      final spans = _trim(mergeSpans(buf));
      buf = [];
      if (spans.isNotEmpty) out.add(make(spans));
    }

    for (final it in items) {
      if (it is TextSpanData) {
        buf.add(it);
      } else if (it is ImageBlock) {
        flush();
        out.add(it);
      }
    }
    flush();
  }

  void _finishItem() {
    final item = _item;
    if (item == null) return;
    _item = null;
    final spans = <TextSpanData>[];
    final images = <ImageBlock>[];
    for (final para in item.paragraphs) {
      if (para.isEmpty) continue;
      final items = _parseInline(para.join('\n'));
      final paraSpans = _trim(mergeSpans(items.whereType<TextSpanData>()));
      images.addAll(items.whereType<ImageBlock>());
      if (paraSpans.isEmpty) continue;
      if (spans.isNotEmpty) spans.add(const TextSpanData('\n'));
      spans.addAll(paraSpans);
    }
    out.add(
      ListItemBlock(
        spans: mergeSpans(spans),
        ordered: item.ordered,
        marker: item.marker,
        indent: item.level,
      ),
    );
    out.addAll(images);
  }

  void _endList() {
    _finishItem();
    _listStack.clear();
    _blankAfterItem = false;
  }

  List<Object> _parseInline(String text) => _InlineParser.parse(ctx, text);
}

List<TextSpanData> _trim(List<TextSpanData> spans) {
  final out = List<TextSpanData>.of(spans);
  while (out.isNotEmpty) {
    final t = out.first.text.replaceFirst(RegExp(r'^[ \t\n]+'), '');
    if (t.isEmpty) {
      out.removeAt(0);
    } else {
      out[0] = out.first.copyWith(text: t);
      break;
    }
  }
  while (out.isNotEmpty) {
    final t = out.last.text.replaceFirst(RegExp(r'[ \t\n]+$'), '');
    if (t.isEmpty) {
      out.removeLast();
    } else {
      out[out.length - 1] = out.last.copyWith(text: t);
      break;
    }
  }
  return out;
}

/// Splits a table row on unescaped pipes that are not inside code spans.
List<String> _splitRow(String line) {
  var l = line.trim();
  if (l.startsWith('|')) l = l.substring(1);
  if (l.endsWith('|') && !l.endsWith(r'\|')) l = l.substring(0, l.length - 1);
  final cells = <String>[];
  final sb = StringBuffer();
  var inCode = 0;
  for (var i = 0; i < l.length; i++) {
    final c = l[i];
    if (c == r'\' && i + 1 < l.length && l[i + 1] == '|') {
      sb.write(r'\|');
      i++;
    } else if (c == '`') {
      var n = 0;
      while (i < l.length && l[i] == '`') {
        n++;
        i++;
      }
      i--;
      sb.write('`' * n);
      inCode = inCode == 0 ? n : (inCode == n ? 0 : inCode);
    } else if (c == '|' && inCode == 0) {
      cells.add(sb.toString().trim());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  cells.add(sb.toString().trim());
  return cells;
}

// ------------------------------------------------------------- inlines

sealed class _Node {}

class _Text extends _Node {
  _Text(this.text);
  String text;
}

class _Delim extends _Node {
  _Delim(this.char, this.count, this.canOpen, this.canClose) : orig = count;
  final String char;
  int count;
  final int orig;
  final bool canOpen;
  final bool canClose;
}

class _Emph extends _Node {
  _Emph(this.strong, this.children);
  final bool strong;
  final List<_Node> children;
}

class _Link extends _Node {
  _Link(this.url, this.children);
  final String url;
  final List<_Node> children;
}

class _Tag extends _Node {
  _Tag(this.kind, this.open);
  final String kind; // b, i, u
  final bool open;
}

class _HardBreak extends _Node {}

class _Img extends _Node {
  _Img(this.alt, this.src);
  final String alt;
  final String src;
}

final RegExp _ws = RegExp(r'\s');
final RegExp _punct = RegExp(r'[\p{P}\p{S}]', unicode: true);
const String _asciiPunct = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

bool _isWs(String c) => _ws.hasMatch(c);
bool _isPunctChar(String c) => _punct.hasMatch(c);

const Map<String, String> _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'bull': '•',
  'middot': '·',
  'deg': '°',
  'euro': '€',
  'pound': '£',
  'yen': '¥',
  'cent': '¢',
  'sect': '§',
  'para': '¶',
  'times': '×',
  'divide': '÷',
  'plusmn': '±',
  'laquo': '«',
  'raquo': '»',
  'shy': '',
  'larr': '←',
  'rarr': '→',
  'uarr': '↑',
  'darr': '↓',
  'harr': '↔',
  'le': '≤',
  'ge': '≥',
  'ne': '≠',
  'infin': '∞',
  'micro': 'µ',
  'frac12': '½',
  'frac14': '¼',
  'frac34': '¾',
  'emsp': ' ',
  'ensp': ' ',
  'thinsp': ' ',
};

class _InlineParser {
  _InlineParser(this.ctx, this._s);
  final _Ctx ctx;
  final String _s;
  final List<_Node> _nodes = [];
  final StringBuffer _buf = StringBuffer();

  /// Parses [text] into spans ([TextSpanData]) and resolved [ImageBlock]s.
  static List<Object> parse(_Ctx ctx, String text) {
    final parser = _InlineParser(ctx, text);
    final out = <Object>[];
    parser._flatten(parser._run(), _Style(), null, out);
    return out;
  }

  List<_Node> _run() {
    _scan();
    _flushText();
    _processEmphasis(_nodes);
    return _nodes;
  }

  List<_Node> _sub(String text) => _InlineParser(ctx, text)._run();

  void _flushText() {
    if (_buf.isEmpty) return;
    _nodes.add(_Text(_buf.toString()));
    _buf.clear();
  }

  void _add(_Node n) {
    _flushText();
    _nodes.add(n);
  }

  void _scan() {
    final s = _s;
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      switch (c) {
        case r'\':
          if (i + 1 < s.length && s[i + 1] == '\n') {
            _add(_HardBreak());
            i += 2;
            while (i < s.length && s[i] == ' ') {
              i++;
            }
            continue;
          }
          if (i + 1 < s.length && _asciiPunct.contains(s[i + 1])) {
            _buf.write(s[i + 1]);
            i += 2;
            continue;
          }
          _buf.write(c);
          i++;
        case '`':
          var n = 0;
          while (i + n < s.length && s[i + n] == '`') {
            n++;
          }
          final close = _findBacktickRun(s, i + n, n);
          if (close < 0) {
            _buf.write('`' * n);
            i += n;
          } else {
            var code = s.substring(i + n, close).replaceAll('\n', ' ');
            if (code.length >= 2 &&
                code.startsWith(' ') &&
                code.endsWith(' ') &&
                code.trim().isNotEmpty) {
              code = code.substring(1, code.length - 1);
            }
            _buf.write(code);
            i = close + n;
          }
        case '*' || '_':
          var n = 0;
          while (i + n < s.length && s[i + n] == c) {
            n++;
          }
          final before = i == 0 ? ' ' : s[i - 1];
          final after = i + n >= s.length ? ' ' : s[i + n];
          final left =
              !_isWs(after) &&
              (!_isPunctChar(after) || _isWs(before) || _isPunctChar(before));
          final right =
              !_isWs(before) &&
              (!_isPunctChar(before) || _isWs(after) || _isPunctChar(after));
          final bool canOpen;
          final bool canClose;
          if (c == '*') {
            canOpen = left;
            canClose = right;
          } else {
            canOpen = left && (!right || _isPunctChar(before));
            canClose = right && (!left || _isPunctChar(after));
          }
          if (canOpen || canClose) {
            _add(_Delim(c, n, canOpen, canClose));
          } else {
            _buf.write(c * n);
          }
          i += n;
        case '!':
          if (i + 1 < s.length && s[i + 1] == '[') {
            final link = _tryLink(i + 1);
            if (link != null) {
              final altNodes = _sub(s.substring(i + 2, link.textEnd));
              final alt = StringBuffer();
              _plain(altNodes, alt);
              _add(_Img(alt.toString(), link.url));
              i = link.end;
              continue;
            }
          }
          _buf.write(c);
          i++;
        case '[':
          final link = _tryLink(i);
          if (link != null) {
            final children = _sub(s.substring(i + 1, link.textEnd));
            _add(_Link(link.url, children));
            i = link.end;
          } else {
            _buf.write(c);
            i++;
          }
        case '<':
          final consumed = _tryAngle(i);
          if (consumed > 0) {
            i += consumed;
          } else {
            _buf.write(c);
            i++;
          }
        case '&':
          final m = RegExp(
            r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});',
          ).matchAsPrefix(s, i);
          String? decoded;
          if (m != null) {
            final e = m.group(1)!;
            if (e.startsWith('#x') || e.startsWith('#X')) {
              final v = int.tryParse(e.substring(2), radix: 16);
              if (v != null && v > 0 && v <= 0x10FFFF) {
                decoded = String.fromCharCode(v);
              }
            } else if (e.startsWith('#')) {
              final v = int.tryParse(e.substring(1));
              if (v != null && v > 0 && v <= 0x10FFFF) {
                decoded = String.fromCharCode(v);
              }
            } else {
              decoded = _entities[e];
            }
          }
          if (decoded != null) {
            _buf.write(decoded);
            i += m!.end - m.start;
          } else {
            _buf.write(c);
            i++;
          }
        case '\n':
          // Hard break: two or more trailing spaces; otherwise soft break.
          final current = _buf.toString();
          final stripped = current.replaceFirst(RegExp(r' +$'), '');
          final hard = current.length - stripped.length >= 2;
          _buf
            ..clear()
            ..write(stripped);
          if (hard) {
            _add(_HardBreak());
          } else {
            _buf.write(' ');
          }
          i++;
          while (i < s.length && s[i] == ' ') {
            i++;
          }
        case 'h' || 'w' || 'H' || 'W':
          final prev = i == 0 ? ' ' : s[i - 1];
          final url = (_isWs(prev) || '(*_~'.contains(prev))
              ? _matchBareUrl(i)
              : null;
          if (url != null) {
            final href = url.toLowerCase().startsWith('www.')
                ? 'http://$url'
                : url;
            _add(_Link(href, [_Text(url)]));
            i += url.length;
          } else {
            _buf.write(c);
            i++;
          }
        default:
          _buf.write(c);
          i++;
      }
    }
  }

  int _findBacktickRun(String s, int from, int n) {
    var i = from;
    while (i < s.length) {
      if (s[i] == '`') {
        var m = 0;
        while (i + m < s.length && s[i + m] == '`') {
          m++;
        }
        if (m == n) return i;
        i += m;
      } else {
        i++;
      }
    }
    return -1;
  }

  String? _matchBareUrl(int i) {
    final m = RegExp(
      r'(?:https?://|www\.)[^\s<]+',
      caseSensitive: false,
    ).matchAsPrefix(_s, i);
    if (m == null) return null;
    var url = m.group(0)!;
    while (url.isNotEmpty) {
      final last = url[url.length - 1];
      if ('?!.,:*_~\'"'.contains(last)) {
        url = url.substring(0, url.length - 1);
      } else if (last == ')' &&
          '('.allMatches(url).length < ')'.allMatches(url).length) {
        url = url.substring(0, url.length - 1);
      } else {
        break;
      }
    }
    final minLen = url.toLowerCase().startsWith('www.') ? 5 : 9;
    return url.length < minLen ? null : url;
  }

  /// Parses `[text](dest "title")`, `[text][ref]`, `[text][]` or `[ref]`
  /// starting at the `[` at [start].
  ({int textEnd, int end, String url})? _tryLink(int start) {
    final s = _s;
    var depth = 0;
    var i = start;
    var close = -1;
    while (i < s.length) {
      final c = s[i];
      if (c == r'\') {
        i += 2;
        continue;
      }
      if (c == '`') {
        var n = 0;
        while (i + n < s.length && s[i + n] == '`') {
          n++;
        }
        final e = _findBacktickRun(s, i + n, n);
        i = e < 0 ? i + n : e + n;
        continue;
      }
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) {
          close = i;
          break;
        }
      }
      i++;
    }
    if (close < 0) return null;
    final text = s.substring(start + 1, close);
    var j = close + 1;
    if (j < s.length && s[j] == '(') {
      j++;
      while (j < s.length && _isWs(s[j])) {
        j++;
      }
      String dest;
      if (j < s.length && s[j] == '<') {
        final e = s.indexOf('>', j + 1);
        if (e < 0) return null;
        dest = s.substring(j + 1, e);
        j = e + 1;
      } else {
        final sb = StringBuffer();
        var parens = 0;
        while (j < s.length) {
          final c = s[j];
          if (c == r'\' && j + 1 < s.length && _asciiPunct.contains(s[j + 1])) {
            sb.write(s[j + 1]);
            j += 2;
            continue;
          }
          if (_isWs(c)) break;
          if (c == '(') parens++;
          if (c == ')') {
            if (parens == 0) break;
            parens--;
          }
          sb.write(c);
          j++;
        }
        dest = sb.toString();
      }
      while (j < s.length && _isWs(s[j])) {
        j++;
      }
      if (j < s.length && (s[j] == '"' || s[j] == "'" || s[j] == '(')) {
        final q = s[j] == '(' ? ')' : s[j];
        final e = s.indexOf(q, j + 1);
        if (e < 0) return null;
        j = e + 1;
        while (j < s.length && _isWs(s[j])) {
          j++;
        }
      }
      if (j >= s.length || s[j] != ')') return null;
      return (textEnd: close, end: j + 1, url: _decodeEntitiesInUrl(dest));
    }
    // Reference links.
    if (j < s.length && s[j] == '[') {
      final e = s.indexOf(']', j + 1);
      if (e >= 0) {
        final label = s.substring(j + 1, e);
        final url = ctx.refs[_normalizeLabel(label.isEmpty ? text : label)];
        if (url != null) return (textEnd: close, end: e + 1, url: url);
        return null;
      }
    }
    final url = ctx.refs[_normalizeLabel(text)];
    if (url != null) return (textEnd: close, end: close + 1, url: url);
    return null;
  }

  String _decodeEntitiesInUrl(String url) => url.replaceAll('&amp;', '&');

  /// Handles autolinks, inline HTML tags and comments. Returns the number of
  /// characters consumed, or 0 when `<` is literal.
  int _tryAngle(int i) {
    final s = _s;
    final auto = RegExp(
      r'<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*)>',
    ).matchAsPrefix(s, i);
    if (auto != null) {
      final url = auto.group(1)!;
      _add(_Link(url, [_Text(url)]));
      return auto.end - auto.start;
    }
    final email = RegExp(
      r'<([A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9-]+)*)>',
    ).matchAsPrefix(s, i);
    if (email != null) {
      final addr = email.group(1)!;
      _add(_Link('mailto:$addr', [_Text(addr)]));
      return email.end - email.start;
    }
    if (s.startsWith('<!--', i)) {
      final e = s.indexOf('-->', i + 4);
      if (e >= 0) return e + 3 - i;
    }
    final tag = RegExp(
      r'''<(/?)([A-Za-z][A-Za-z0-9-]*)(?:\s+[^<>]*?)?\s*(/?)>''',
    ).matchAsPrefix(s, i);
    if (tag != null) {
      final closing = tag.group(1) == '/';
      final name = tag.group(2)!.toLowerCase();
      switch (name) {
        case 'b' || 'strong':
          _add(_Tag('b', !closing));
        case 'i' || 'em' || 'cite':
          _add(_Tag('i', !closing));
        case 'u' || 'ins':
          _add(_Tag('u', !closing));
        case 'br':
          _add(_HardBreak());
        default:
          break; // other tags are dropped, their text content is kept
      }
      return tag.end - tag.start;
    }
    return 0;
  }

  void _processEmphasis(List<_Node> nodes) {
    var c = 0;
    while (c < nodes.length) {
      final closer = nodes[c];
      if (closer is! _Delim || !closer.canClose || closer.count == 0) {
        c++;
        continue;
      }
      _Delim? opener;
      var o = c - 1;
      while (o >= 0) {
        final n = nodes[o];
        if (n is _Delim && n.char == closer.char && n.canOpen && n.count > 0) {
          final ruleOf3 =
              (n.canClose || closer.canOpen) &&
              (n.orig + closer.orig) % 3 == 0 &&
              !(n.orig % 3 == 0 && closer.orig % 3 == 0);
          if (!ruleOf3) {
            opener = n;
            break;
          }
        }
        o--;
      }
      if (opener == null) {
        c++;
        continue;
      }
      final use = closer.count >= 2 && opener.count >= 2 ? 2 : 1;
      opener.count -= use;
      closer.count -= use;
      final inner = nodes.sublist(o + 1, c);
      nodes.replaceRange(o + 1, c, [_Emph(use == 2, inner)]);
      c = o + 2;
      if (opener.count == 0) {
        nodes.removeAt(o);
        c--;
      }
      if (closer.count == 0) nodes.removeAt(c);
    }
  }

  void _plain(List<_Node> nodes, StringBuffer sb) {
    for (final n in nodes) {
      switch (n) {
        case _Text():
          sb.write(n.text);
        case _Delim():
          sb.write(n.char * n.count);
        case _Emph():
          _plain(n.children, sb);
        case _Link():
          _plain(n.children, sb);
        case _HardBreak():
          sb.write(' ');
        case _Img():
          sb.write(n.alt);
        case _Tag():
          break;
      }
    }
  }

  void _flatten(List<_Node> nodes, _Style st, String? link, List<Object> out) {
    for (final n in nodes) {
      switch (n) {
        case _Text():
          out.add(st.span(n.text, link));
        case _Delim():
          if (n.count > 0) out.add(st.span(n.char * n.count, link));
        case _Emph():
          if (n.strong) {
            st.bold++;
          } else {
            st.italic++;
          }
          _flatten(n.children, st, link, out);
          if (n.strong) {
            st.bold--;
          } else {
            st.italic--;
          }
        case _Link():
          _flatten(n.children, st, n.url, out);
        case _Tag():
          final d = n.open ? 1 : -1;
          switch (n.kind) {
            case 'b':
              st.htmlBold = (st.htmlBold + d).clamp(0, 99);
            case 'i':
              st.htmlItalic = (st.htmlItalic + d).clamp(0, 99);
            case 'u':
              st.underline = (st.underline + d).clamp(0, 99);
          }
        case _HardBreak():
          out.add(st.span('\n', link));
        case _Img():
          final img = _resolveImage(n);
          if (img != null) out.add(img);
      }
    }
  }

  ImageBlock? _resolveImage(_Img n) {
    Uint8List? bytes;
    final src = n.src.trim();
    if (src.startsWith('data:')) {
      final comma = src.indexOf(',');
      if (comma > 0 && src.substring(0, comma).contains(';base64')) {
        try {
          bytes = base64Decode(
            src.substring(comma + 1).replaceAll(RegExp(r'\s'), ''),
          );
        } catch (_) {
          bytes = null;
        }
      }
    } else {
      final candidates = <String>{src, Uri.decodeFull(src)};
      for (final c in List.of(candidates)) {
        if (c.startsWith('./')) candidates.add(c.substring(2));
      }
      for (final c in candidates) {
        bytes = ctx.images[c];
        if (bytes != null) break;
      }
    }
    if (bytes == null) return null;
    final normalized = normalizeToPngOrJpeg(bytes);
    if (normalized == null) return null;
    final size = readImageSize(normalized);
    if (size == null) return null;
    final alt = n.alt.trim();
    final caption =
        alt.isEmpty ||
            RegExp(r'^image[ -]?\d+$', caseSensitive: false).hasMatch(alt)
        ? null
        : alt;
    return ImageBlock(
      bytes: normalized,
      width: size.width,
      height: size.height,
      caption: caption,
    );
  }
}

class _Style {
  int bold = 0;
  int italic = 0;
  int htmlBold = 0;
  int htmlItalic = 0;
  int underline = 0;

  TextSpanData span(String text, String? link) => TextSpanData(
    text,
    bold: bold + htmlBold > 0,
    italic: italic + htmlItalic > 0,
    underline: underline > 0,
    link: link,
  );
}
