import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// Renders [doc] as readable plain text.
///
/// Headings are followed by a blank line (level 1 and 2 are underlined with
/// `=` / `-`), list items get indentation and running markers, quotes are
/// prefixed with `> `, tables are tab-separated rows, images become
/// `[Image: caption]` and links are written as `text (url)`.
String structureToPlainText(DocStructure doc) {
  final out = StringBuffer();
  final counter = ListCounter();
  var prevWasList = false;

  void separate({required bool isList}) {
    if (out.isEmpty) return;
    out.write(isList && prevWasList ? '\n' : '\n\n');
  }

  for (final block in doc.blocks) {
    final isList = block is ListItemBlock;
    if (!isList) counter.reset();
    switch (block) {
      case HeadingBlock():
        final text = _spansText(block.spans).replaceAll('\n', ' ').trim();
        if (text.isEmpty) continue;
        separate(isList: false);
        out.write(text);
        if (block.level <= 2) {
          out.write('\n');
          out.write((block.level == 1 ? '=' : '-') * text.runes.length.clamp(3, 80));
        }
      case ParagraphBlock():
        final text = _spansText(block.spans).trim();
        if (text.isEmpty) continue;
        separate(isList: false);
        out.write(text);
      case QuoteBlock():
        final text = _spansText(block.spans).trim();
        if (text.isEmpty) continue;
        separate(isList: false);
        out.write(text.split('\n').map((l) => '> $l').join('\n'));
      case ListItemBlock():
        separate(isList: true);
        final level = block.indent < 0 ? 0 : block.indent;
        final marker = listMarker(block, counter.next(block));
        final indent = '    ' * level;
        final hang = ' ' * (indent.length + marker.length + 1);
        final lines = _spansText(block.spans).trim().split('\n');
        out.write('$indent$marker ${lines.first}');
        for (final l in lines.skip(1)) {
          out.write('\n$hang$l');
        }
      case ImageBlock():
        separate(isList: false);
        final caption = block.caption?.trim();
        out.write(caption == null || caption.isEmpty ? '[Image]' : '[Image: $caption]');
      case TableBlock():
        if (block.rows.isEmpty) continue;
        separate(isList: false);
        out.write(
          block.rows.map((r) => r.map((c) => c.replaceAll(RegExp(r'[\t\r\n]+'), ' ').trim()).join('\t')).join('\n'),
        );
      case PageBreakBlock():
        continue;
    }
    prevWasList = isList;
  }
  if (out.isNotEmpty) out.write('\n');
  return out.toString();
}

String _spansText(List<TextSpanData> spans) {
  final sb = StringBuffer();
  for (final s in mergeSpans(spans)) {
    sb.write(stripInvalidXmlChars(s.text));
    final link = s.link;
    if (link != null && link.isNotEmpty) {
      final shown = s.text.trim();
      final bare = link.replaceFirst(RegExp(r'^(mailto:|https?://)'), '');
      if (shown != link && shown != bare) sb.write(' ($link)');
    }
  }
  return sb.toString();
}
