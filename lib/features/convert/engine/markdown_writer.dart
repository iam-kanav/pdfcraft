import 'dart:typed_data';

import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// Result of [buildMarkdownWithImages]: the Markdown text plus the image
/// files it references, keyed by relative file name (e.g. `image-1.png`).
class MarkdownExport {
  const MarkdownExport({required this.markdown, required this.images});

  final String markdown;
  final Map<String, Uint8List> images;
}

/// Marker line used for page breaks; understood by [parseMarkdown] and
/// rendered by Markdown viewers that allow inline HTML.
const String markdownPageBreak =
    '<div style="page-break-after: always;"></div>';

/// Converts [doc] to GitHub-flavoured Markdown. Images are emitted as
/// references (`![image N](image-N.png)`); use [buildMarkdownWithImages] to
/// also get the image files.
String buildMarkdown(DocStructure doc) => buildMarkdownWithImages(doc).markdown;

/// Converts [doc] to Markdown and returns the referenced image files.
MarkdownExport buildMarkdownWithImages(DocStructure doc) {
  final out = <String>[];
  final images = <String, Uint8List>{};
  final counter = ListCounter();
  final listLines = <String>[];
  var prevListLevel = -1;

  void endList() {
    if (listLines.isNotEmpty) {
      out.add(listLines.join('\n'));
      listLines.clear();
    }
    counter.reset();
    prevListLevel = -1;
  }

  for (final block in doc.blocks) {
    if (block is! ListItemBlock) endList();
    switch (block) {
      case HeadingBlock():
        final level = block.level.clamp(1, 6);
        final spans = block.spans
            .map(
              (s) =>
                  s.copyWith(text: s.text.replaceAll(RegExp(r'[\r\n]+'), ' ')),
            )
            .toList();
        var text = _InlineWriter().write(spans);
        if (text.endsWith('#')) {
          text = '${text.substring(0, text.length - 1)}\\#';
        }
        if (text.trim().isEmpty) continue;
        out.add('${'#' * level} $text');
      case ParagraphBlock():
        final text = _InlineWriter().write(block.spans);
        if (text.trim().isNotEmpty) out.add(text);
      case QuoteBlock():
        final text = _InlineWriter().write(block.spans);
        if (text.trim().isNotEmpty) {
          out.add(
            text.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n'),
          );
        }
      case ListItemBlock():
        var level = block.indent < 0 ? 0 : block.indent;
        if (level > prevListLevel + 1) level = prevListLevel + 1;
        prevListLevel = level;
        final normalized = ListItemBlock(
          spans: block.spans,
          ordered: block.ordered,
          indent: level,
        );
        final number = counter.next(normalized);
        final marker = block.ordered ? '$number.' : '-';
        final indent = '    ' * level;
        final contIndent = ' ' * (indent.length + marker.length + 1);
        final text = _InlineWriter().write(block.spans);
        final lines = text.split('\n');
        final sb = StringBuffer('$indent$marker ${lines.first}');
        for (final l in lines.skip(1)) {
          sb.write('\n$contIndent$l');
        }
        listLines.add(sb.toString());
      case ImageBlock():
        final bytes = normalizeToPngOrJpeg(block.bytes);
        if (bytes == null) continue;
        final n = images.length + 1;
        final ext = detectImageKind(bytes) == ImageKind.jpeg ? 'jpg' : 'png';
        final name = 'image-$n.$ext';
        images[name] = bytes;
        final caption = block.caption;
        final alt = caption == null || caption.trim().isEmpty
            ? 'image $n'
            : escapeMarkdownText(
                caption.replaceAll(RegExp(r'\s+'), ' ').trim(),
              );
        out.add('![$alt]($name)');
      case TableBlock():
        final t = _table(block);
        if (t.isNotEmpty) out.add(t);
      case PageBreakBlock():
        out.add(markdownPageBreak);
    }
  }
  endList();
  final md = out.join('\n\n');
  return MarkdownExport(markdown: md.isEmpty ? '' : '$md\n', images: images);
}

final RegExp _entityLike = RegExp(
  r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);',
);

/// Escapes characters with inline Markdown meaning.
String escapeMarkdownText(String input, {bool escapePipes = false}) {
  final text = stripInvalidXmlChars(input);
  final sb = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    switch (c) {
      case r'\' || '`' || '*' || '_' || '[' || ']' || '<' || '>' || '~':
        sb.write('\\$c');
      case '|':
        sb.write(escapePipes ? r'\|' : c);
      case '&':
        sb.write(_entityLike.matchAsPrefix(text, i) != null ? r'\&' : c);
      default:
        sb.write(c);
    }
  }
  return sb.toString();
}

/// Escapes block-level syntax at the start of a line (headings, quotes,
/// list markers, setext underlines, fences, tables).
String _escapeLineStart(String line) {
  if (line.isEmpty) return line;
  final c = line[0];
  if (c == '#' || c == '>' || c == '=' || c == '+' || c == '-' || c == '|') {
    return '\\$line';
  }
  final m = RegExp(r'^(\d{1,9})([.)])').firstMatch(line);
  if (m != null) return '${m.group(1)}\\${line.substring(m.group(1)!.length)}';
  return line;
}

bool _isPunct(String ch) => RegExp(r'''[!-/:-@\[-`{-~ -⁯⸀-⹿]''').hasMatch(ch);

class _State {
  const _State(this.link, this.bold, this.italic, this.underline);
  final String? link;
  final bool bold;
  final bool italic;
  final bool underline;

  static const none = _State(null, false, false, false);
  static _State of(TextSpanData s) => _State(
    s.link != null && s.link!.isNotEmpty ? s.link : null,
    s.bold,
    s.italic,
    s.underline,
  );
}

/// Serialises spans to inline Markdown with properly nested emphasis.
/// Whitespace at span edges is moved outside of emphasis markers; groups
/// whose content starts or ends with punctuation use HTML tags because the
/// CommonMark flanking rules would not recognise `*` markers there.
class _InlineWriter {
  final StringBuffer _sb = StringBuffer();
  bool _lineStart = true;

  // Open markers in nesting order: link, bold, italic, underline.
  final List<(int kind, String close)> _open = [];
  _State _state = _State.none;

  void _emit(String s) {
    if (s.isEmpty) return;
    _sb.write(s);
    _lineStart = s.endsWith('\n');
  }

  void _emitText(String raw) {
    final lines = raw.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replaceAll('\t', '    ');
      if (i < lines.length - 1) line = line.trimRight();
      if (_lineStart) line = line.trimLeft();
      var escaped = escapeMarkdownText(line);
      if (_lineStart) escaped = _escapeLineStart(escaped);
      _emit(escaped);
      if (i < lines.length - 1) _emit('\\\n');
    }
  }

  int _depthFor(_State target) {
    var d = 0;
    final levels = [
      (_state.link == target.link && _state.link != null) ||
          (_state.link == null && target.link == null),
      _state.bold == target.bold,
      _state.italic == target.italic,
      _state.underline == target.underline,
    ];
    // Number of leading nesting levels (in order) that remain unchanged.
    for (final same in levels) {
      if (!same) break;
      d++;
    }
    return d;
  }

  void _closeTo(int keepLevels) {
    while (_open.isNotEmpty && _open.last.$1 >= keepLevels) {
      _emit(_open.removeLast().$2);
    }
    _state = _State(
      keepLevels > 0 ? _state.link : null,
      keepLevels > 1 ? _state.bold : false,
      keepLevels > 2 ? _state.italic : false,
      keepLevels > 3 ? _state.underline : false,
    );
  }

  String write(List<TextSpanData> input) {
    final spans = mergeSpans(input);
    var pending = '';
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      final m = RegExp(r'^(\s*)(.*?)(\s*)$', dotAll: true).firstMatch(s.text)!;
      final lead = m.group(1)!;
      final core = m.group(2)!;
      final trail = m.group(3)!;
      if (core.isEmpty) {
        pending += s.text;
        continue;
      }
      final target = _State.of(s);
      _closeTo(_depthFor(target));
      _emitText(pending + lead);
      pending = '';
      if (target.link != null && _state.link == null) {
        _emit('[');
        _open.add((0, '](${_linkDestination(target.link!)})'));
      }
      final groupText = _groupText(spans, i);
      if (target.bold && !_state.bold) {
        _openEmphasis(1, '**', '<strong>', '</strong>', groupText(1));
      }
      if (target.italic && !_state.italic) {
        _openEmphasis(2, '*', '<em>', '</em>', groupText(2));
      }
      if (target.underline && !_state.underline) {
        _emit('<u>');
        _open.add((3, '</u>'));
      }
      _state = target;
      _emitText(core);
      pending = trail;
    }
    _closeTo(0);
    _emitText(pending.trimRight());
    return _sb.toString().trimRight();
  }

  void _openEmphasis(
    int kind,
    String md,
    String htmlOpen,
    String htmlClose,
    String content,
  ) {
    final t = content.trim();
    final usesHtml = t.isEmpty || _isPunct(t[0]) || _isPunct(t[t.length - 1]);
    if (usesHtml) {
      _emit(htmlOpen);
      _open.add((kind, htmlClose));
    } else {
      _emit(md);
      _open.add((kind, md));
    }
  }

  /// Returns a function giving the text covered by an emphasis group of the
  /// given nesting level that starts at span [start].
  String Function(int) _groupText(List<TextSpanData> spans, int start) =>
      (int kind) {
        final first = _State.of(spans[start]);
        final sb = StringBuffer();
        for (var j = start; j < spans.length; j++) {
          final st = _State.of(spans[j]);
          final sameOuter =
              st.link == first.link && (kind < 2 || st.bold == first.bold);
          final inGroup = sameOuter && (kind == 1 ? st.bold : st.italic);
          if (!inGroup) {
            if (spans[j].text.trim().isEmpty) {
              sb.write(spans[j].text);
              continue;
            }
            break;
          }
          sb.write(spans[j].text);
        }
        return sb.toString();
      };
}

String _linkDestination(String url) {
  final u = url.trim();
  if (RegExp(r'[\s()<>]').hasMatch(u)) {
    return '<${u.replaceAll('<', '%3C').replaceAll('>', '%3E').replaceAll(' ', '%20').replaceAll('\n', '')}>';
  }
  return u;
}

String _table(TableBlock table) {
  final rows = table.rows.where((r) => r.isNotEmpty).toList();
  if (rows.isEmpty) return '';
  final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  String cell(String text) => escapeMarkdownText(
    text.replaceAll('\r\n', '\n').trim(),
    escapePipes: true,
  ).replaceAll('\n', '<br>');
  String row(List<String> r) {
    final cells = List<String>.generate(
      cols,
      (i) => i < r.length ? cell(r[i]) : '',
    );
    return '| ${cells.join(' | ')} |';
  }

  final lines = <String>[];
  var body = rows;
  if (table.hasHeader) {
    lines.add(row(rows.first));
    body = rows.sublist(1);
  } else {
    // GFM tables require a header row; an empty one marks "no header".
    lines.add('|${List.filled(cols, '   ').join('|')}|');
  }
  lines.add('|${List.filled(cols, ' --- ').join('|')}|');
  for (final r in body) {
    lines.add(row(r));
  }
  return lines.join('\n');
}
