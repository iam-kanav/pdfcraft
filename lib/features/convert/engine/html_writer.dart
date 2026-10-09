import 'dart:convert';

import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// Builds a standalone, responsive HTML5 document from [doc]. CSS is
/// embedded and images are inlined as base64 data URIs, so the file has no
/// external dependencies.
String buildHtml(DocStructure doc, {String? title}) {
  final pageTitle = title ?? doc.title ?? _firstHeading(doc) ?? 'Document';
  final sb = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html>')
    ..writeln('<head>')
    ..writeln('<meta charset="utf-8">')
    ..writeln('<meta name="viewport" content="width=device-width, initial-scale=1">')
    ..writeln('<meta name="generator" content="PDFCraft">')
    ..writeln('<title>${escapeHtml(pageTitle)}</title>')
    ..writeln('<style>')
    ..writeln(_css)
    ..writeln('</style>')
    ..writeln('</head>')
    ..writeln('<body>')
    ..writeln('<main>');

  final lists = _ListWriter(sb);
  var imageIndex = 0;
  for (final block in doc.blocks) {
    if (block is! ListItemBlock) lists.closeAll();
    switch (block) {
      case HeadingBlock():
        final l = block.level.clamp(1, 6);
        sb.writeln('<h$l${_alignAttr(block.align)}>${_spans(block.spans)}</h$l>');
      case ParagraphBlock():
        sb.writeln('<p${_alignAttr(block.align)}>${_spans(block.spans)}</p>');
      case QuoteBlock():
        sb.writeln('<blockquote><p>${_spans(block.spans)}</p></blockquote>');
      case ListItemBlock():
        lists.item(block);
      case ImageBlock():
        imageIndex++;
        sb.writeln(_image(block, imageIndex));
      case TableBlock():
        sb.writeln(_table(block));
      case PageBreakBlock():
        sb.writeln('<div class="page-break" aria-hidden="true"></div>');
    }
  }
  lists.closeAll();
  sb
    ..writeln('</main>')
    ..writeln('</body>')
    ..writeln('</html>');
  return sb.toString();
}

String? _firstHeading(DocStructure doc) {
  for (final h in doc.headings) {
    final t = h.text.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// Escapes text for HTML element content and attribute values.
String escapeHtml(String text) {
  final s = stripInvalidXmlChars(text);
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    switch (c) {
      case '&':
        sb.write('&amp;');
      case '<':
        sb.write('&lt;');
      case '>':
        sb.write('&gt;');
      case '"':
        sb.write('&quot;');
      case "'":
        sb.write('&#39;');
      default:
        sb.write(c);
    }
  }
  return sb.toString();
}

String _textWithBreaks(String text) =>
    escapeHtml(text.replaceAll('\r\n', '\n')).replaceAll('\n', '<br>\n').replaceAll('\t', '&emsp;');

/// Only links with a safe scheme (or relative links) are emitted as hrefs.
String? _safeHref(String? link) {
  if (link == null) return null;
  final l = link.trim();
  if (l.isEmpty) return null;
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(l)?.group(1)?.toLowerCase();
  if (scheme == null) return l;
  const allowed = {'http', 'https', 'mailto', 'tel', 'ftp'};
  return allowed.contains(scheme) ? l : null;
}

String _alignAttr(BlockAlign a) => switch (a) {
  BlockAlign.center => ' style="text-align:center"',
  BlockAlign.end => ' style="text-align:right"',
  BlockAlign.start => '',
};

String _spans(List<TextSpanData> spans) {
  final sb = StringBuffer();
  for (final s in mergeSpans(spans)) {
    var inner = _textWithBreaks(s.text);
    final css = [
      if (s.color != null) 'color:#${hexRgb(s.color!)}',
      if (s.fontFamily == 'serif') 'font-family:Georgia,serif',
      if (s.fontFamily == 'mono') 'font-family:monospace',
      if (s.sizeRatio != 1.0) 'font-size:${(s.sizeRatio * 100).round()}%',
    ];
    if (css.isNotEmpty) inner = '<span style="${css.join(';')}">$inner</span>';
    if (s.strike) inner = '<s>$inner</s>';
    if (s.underline) inner = '<u>$inner</u>';
    if (s.italic) inner = '<em>$inner</em>';
    if (s.bold) inner = '<strong>$inner</strong>';
    final href = _safeHref(s.link);
    if (href != null) {
      final external = href.startsWith('http://') || href.startsWith('https://');
      inner = '<a href="${escapeHtml(href)}"${external ? ' rel="noopener noreferrer"' : ''}>$inner</a>';
    }
    sb.write(inner);
  }
  return sb.toString();
}

String _image(ImageBlock block, int index) {
  final kind = detectImageKind(block.bytes);
  final mime = switch (kind) {
    ImageKind.png => 'image/png',
    ImageKind.jpeg => 'image/jpeg',
    ImageKind.gif => 'image/gif',
    ImageKind.webp => 'image/webp',
    ImageKind.bmp => 'image/bmp',
    _ => null,
  };
  final caption = block.caption;
  final alt = escapeHtml(caption ?? 'Image $index');
  if (mime == null) {
    return caption == null ? '' : '<p class="caption">${escapeHtml(caption)}</p>';
  }
  final size = block.width > 0 && block.height > 0 ? ' width="${block.width}" height="${block.height}"' : '';
  final sb = StringBuffer('<figure>');
  sb.write('<img src="data:$mime;base64,${base64Encode(block.bytes)}" alt="$alt"$size loading="lazy">');
  if (caption != null && caption.isNotEmpty) {
    sb.write('<figcaption>${escapeHtml(caption)}</figcaption>');
  }
  sb.write('</figure>');
  return sb.toString();
}

String _table(TableBlock table) {
  final rows = table.rows;
  if (rows.isEmpty) return '';
  final sb = StringBuffer('<div class="table-wrap"><table>\n');
  var start = 0;
  if (table.hasHeader) {
    sb.write('<thead><tr>');
    for (final c in rows.first) {
      sb.write('<th scope="col">${_textWithBreaks(c)}</th>');
    }
    sb.write('</tr></thead>\n');
    start = 1;
  }
  sb.write('<tbody>\n');
  for (var r = start; r < rows.length; r++) {
    sb.write('<tr>');
    for (final c in rows[r]) {
      sb.write('<td>${_textWithBreaks(c)}</td>');
    }
    sb.write('</tr>\n');
  }
  sb.write('</tbody></table></div>');
  return sb.toString();
}

class _OpenList {
  _OpenList(this.ordered);
  final bool ordered;
  bool liOpen = false;
}

/// Groups consecutive list items into properly nested ul/ol elements.
class _ListWriter {
  _ListWriter(this.sb);
  final StringBuffer sb;
  final List<_OpenList> _stack = [];

  void _open(bool ordered, int? start) {
    if (ordered) {
      sb.write(start != null && start != 1 ? '<ol start="$start">' : '<ol>');
    } else {
      sb.write('<ul>');
    }
    sb.writeln();
    _stack.add(_OpenList(ordered));
  }

  void _close() {
    final l = _stack.removeLast();
    if (l.liOpen) sb.writeln('</li>');
    sb.writeln(l.ordered ? '</ol>' : '</ul>');
  }

  void closeAll() {
    while (_stack.isNotEmpty) {
      _close();
    }
  }

  void item(ListItemBlock item) {
    var level = item.indent < 0 ? 0 : item.indent;
    // Never skip a nesting level: a list must live inside an <li>.
    if (level > _stack.length) level = _stack.length;
    while (_stack.length > level + 1) {
      _close();
    }
    if (_stack.length == level + 1 && _stack.last.ordered != item.ordered) {
      _close();
    }
    if (_stack.length == level + 1) {
      if (_stack.last.liOpen) sb.writeln('</li>');
    } else {
      int? start;
      if (item.ordered) {
        final m = RegExp(r'^(\d+)').firstMatch(item.marker ?? '');
        if (m != null) start = int.tryParse(m.group(1)!);
      }
      _open(item.ordered, start);
    }
    sb.write('<li>${_spans(item.spans)}');
    _stack.last.liOpen = true;
  }
}

const String _css = '''
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
body {
  margin: 0;
  padding: 1.5rem 1rem 3rem;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Noto Sans", Helvetica, Arial, sans-serif;
  font-size: 1.0625rem;
  line-height: 1.65;
  color: #1f2328;
  background: #ffffff;
  overflow-wrap: break-word;
}
main { max-width: 46rem; margin: 0 auto; }
h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.6em; font-weight: 650; }
h1 { font-size: 2em; }
h2 { font-size: 1.55em; }
h3 { font-size: 1.3em; }
h4 { font-size: 1.12em; }
h5 { font-size: 1em; }
h6 { font-size: 0.92em; color: #57606a; }
main > :first-child { margin-top: 0; }
p { margin: 0 0 1em; }
a { color: #0969da; text-decoration: underline; }
ul, ol { margin: 0 0 1em; padding-left: 1.75em; }
li { margin: 0.25em 0; }
li > ul, li > ol { margin: 0.25em 0 0; }
blockquote {
  margin: 0 0 1em;
  padding: 0.25em 1em;
  border-left: 4px solid #d0d7de;
  color: #57606a;
}
blockquote p { margin: 0.5em 0; }
figure { margin: 1.5em 0; text-align: center; }
img { max-width: 100%; height: auto; }
figcaption, .caption { font-size: 0.9em; color: #57606a; margin-top: 0.5em; text-align: center; }
.table-wrap { overflow-x: auto; margin: 0 0 1.25em; -webkit-overflow-scrolling: touch; }
table { border-collapse: collapse; width: 100%; font-size: 0.95em; }
th, td { border: 1px solid #d0d7de; padding: 0.45em 0.75em; text-align: left; vertical-align: top; }
thead th { background: #f6f8fa; font-weight: 650; }
tbody tr:nth-child(even) td { background: #fbfcfd; }
.page-break { break-after: page; page-break-after: always; height: 0; border: 0; margin: 2em 0; border-top: 1px dashed #d0d7de; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  a { color: #4493f8; }
  blockquote, h6, figcaption, .caption { color: #9198a1; }
  blockquote { border-left-color: #3d444d; }
  th, td { border-color: #3d444d; }
  thead th { background: #151b23; }
  tbody tr:nth-child(even) td { background: #10151c; }
  .page-break { border-top-color: #3d444d; }
}
@media print {
  body { padding: 0; font-size: 11pt; color: #000; background: #fff; }
  main { max-width: none; }
  .page-break { border: 0; margin: 0; }
  a { color: inherit; }
}
@media (max-width: 480px) {
  body { font-size: 1rem; padding: 1rem 0.85rem 2rem; }
  h1 { font-size: 1.7em; }
  h2 { font-size: 1.4em; }
}''';
