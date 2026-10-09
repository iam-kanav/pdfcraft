import 'package:pdfcraft/core/models/doc_structure.dart';

/// Parses plain text into a [DocStructure].
///
/// Paragraphs are separated by blank lines; single line breaks inside a
/// paragraph are kept as `\n`. Lines starting with a bullet (`-`, `*`, `+`,
/// `•`, ...) or a number (`1.`, `2)`) become list items, with nesting taken
/// from the leading indentation; non-marker lines directly following a list
/// item continue that item. Form feeds become page breaks.
DocStructure parsePlainText(String text) {
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (t.startsWith('﻿')) t = t.substring(1);
  final blocks = <DocBlock>[];
  final pages = t.split('\f');
  for (var p = 0; p < pages.length; p++) {
    if (p > 0 && blocks.isNotEmpty && blocks.last is! PageBreakBlock) {
      blocks.add(const PageBreakBlock());
    }
    _parsePage(pages[p], blocks);
  }
  while (blocks.isNotEmpty && blocks.last is PageBreakBlock) {
    blocks.removeLast();
  }
  return DocStructure(blocks: blocks);
}

final RegExp _bullet = RegExp(r'^([ \t]*)([-*+•‣◦▪▫●○■□–·⁃])[ \t]+(\S.*)$');
final RegExp _numbered = RegExp(
  r'^([ \t]*)(\d{1,4}|[a-zA-Z])([.)])[ \t]+(\S.*)$',
);

int _indentWidth(String ws) {
  var w = 0;
  for (final c in ws.split('')) {
    w += c == '\t' ? 4 : 1;
  }
  return w;
}

void _parsePage(String page, List<DocBlock> blocks) {
  final lines = page.split('\n');
  final para = <String>[];
  _Item? item;
  final indents = <int>[];

  void flushPara() {
    if (para.isEmpty) return;
    final text = para.join('\n');
    para.clear();
    if (text.trim().isNotEmpty) {
      blocks.add(ParagraphBlock(spans: [TextSpanData(text)]));
    }
  }

  void flushItem() {
    final it = item;
    if (it == null) return;
    item = null;
    blocks.add(
      ListItemBlock(
        spans: [TextSpanData(it.lines.join('\n'))],
        ordered: it.ordered,
        marker: it.marker,
        indent: it.level,
      ),
    );
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flushPara();
      flushItem();
      indents.clear();
      continue;
    }
    final b = _bullet.firstMatch(line);
    final n = b == null ? _numbered.firstMatch(line) : null;
    // A single letter followed by "." is only a list marker inside a list
    // (avoids treating "A. Smith wrote..." paragraphs as lists).
    final isLetterMarker = n != null && int.tryParse(n.group(2)!) == null;
    if (b != null || (n != null && (!isLetterMarker || item != null))) {
      flushPara();
      flushItem();
      final ws = (b ?? n)!.group(1)!;
      final width = _indentWidth(ws);
      while (indents.isNotEmpty && width < indents.last + 2) {
        indents.removeLast();
      }
      final level = indents.length;
      indents.add(width);
      item = _Item(
        ordered: n != null,
        marker: n != null ? '${n.group(2)}${n.group(3)}' : b!.group(2)!,
        level: level,
        lines: [(b != null ? b.group(3) : n!.group(4))!],
      );
      continue;
    }
    if (item != null) {
      item!.lines.add(line.trim());
    } else {
      para.add(line);
    }
  }
  flushPara();
  flushItem();
}

class _Item {
  _Item({
    required this.ordered,
    required this.marker,
    required this.level,
    required this.lines,
  });
  final bool ordered;
  final String marker;
  final int level;
  final List<String> lines;
}
