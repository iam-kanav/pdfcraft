import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/reflow/analyzer/reflow_analyzer.dart';
import 'package:pdfcraft/features/reflow/reflow_cache.dart';
import 'package:pdfcraft/features/reflow/reflow_screen.dart';

import 'fixtures.dart';
import 'reflow_view_test.dart' show sampleDoc;

void main() {
  test('a cached document decodes to the same blocks, styles and images', () {
    final doc = DocStructure(
      title: 'Guide',
      blocks: [
        ...sampleDoc().blocks,
        const ParagraphBlock(
          spans: [
            TextSpanData('styled', bold: true, italic: true, underline: true, strike: true),
            TextSpanData(' link', link: 'https://example.com', color: 0xFF336699, fontFamily: 'serif', sizeRatio: 0.7),
          ],
          align: BlockAlign.center,
          pageNumber: 4,
        ),
        const ListItemBlock(spans: [TextSpanData('nested')], indent: 2, pageNumber: 4),
        const PageBreakBlock(pageNumber: 5),
      ],
    );
    final back = decodeDocStructure(encodeDocStructure(doc));
    expect(back.title, 'Guide');
    expect(back.blocks.map((b) => b.toString()), doc.blocks.map((b) => b.toString()));
    expect(back.blocks.map((b) => b.pageNumber), doc.blocks.map((b) => b.pageNumber));
    expect(back.blocks.map((b) => b.plainText), doc.blocks.map((b) => b.plainText));

    final image = back.blocks.whereType<ImageBlock>().single;
    expect(image.bytes, tinyPng);
    expect(image.caption, 'Figure 1: Pixel');
    final table = back.blocks.whereType<TableBlock>().single;
    expect(table.hasHeader, isTrue);
    final styled = (back.blocks[back.blocks.length - 3] as ParagraphBlock);
    expect(styled.align, BlockAlign.center);
    final a = styled.spans[0], b = styled.spans[1];
    expect([a.bold, a.italic, a.underline, a.strike], [true, true, true, true]);
    expect([b.link, b.color, b.fontFamily, b.sizeRatio], ['https://example.com', 0xFF336699, 'serif', 0.7]);
    final item = back.blocks.whereType<ListItemBlock>().last;
    expect(item.indent, 2);
  });

  test('the cache is keyed by file contents and keeps a limited number of entries', () async {
    final tmp = await Directory.systemTemp.createTemp('reflow_cache_test');
    addTearDown(() => tmp.delete(recursive: true));
    final cache = ReflowCache(Directory('${tmp.path}/cache'));
    final pdf = File('${tmp.path}/a.pdf')..writeAsStringSync('one');
    expect(await cache.read(pdf.path), isNull);
    await cache.write(pdf.path, sampleDoc());
    expect((await cache.read(pdf.path))!.blocks.length, sampleDoc().blocks.length);

    // Editing the file invalidates its entry.
    pdf.writeAsStringSync('two, longer');
    expect(await cache.read(pdf.path), isNull);

    for (var i = 0; i < ReflowCache.maxEntries + 3; i++) {
      final f = File('${tmp.path}/f$i.pdf')..writeAsStringSync('$i');
      await cache.write(f.path, sampleDoc());
    }
    final entries = cache.dir.listSync().where((e) => e.path.endsWith('.bin'));
    expect(entries.length, ReflowCache.maxEntries);
  });

  test('reading progress: section, percentage and time left', () {
    final words = List.filled(230, 'word').join(' ');
    final doc = DocStructure(
      blocks: [
        const HeadingBlock(level: 1, spans: [TextSpanData('Chapter 1')]),
        ParagraphBlock(spans: [TextSpanData(words)]),
        const HeadingBlock(level: 2, spans: [TextSpanData('Part A')]),
        ParagraphBlock(spans: [TextSpanData(words)]),
        const HeadingBlock(level: 3, spans: [TextSpanData('Detail')]),
        ParagraphBlock(spans: [TextSpanData(words)]),
        const HeadingBlock(level: 1, spans: [TextSpanData('Chapter 2')]),
        ParagraphBlock(spans: [TextSpanData(words)]),
      ],
    );
    final p = ReadingProgress(doc);
    expect(p.sectionAt(1), 'Chapter 1');
    expect(p.sectionAt(3), 'Part A');
    expect(p.sectionAt(5), 'Part A', reason: 'level 3 is below the two top levels');
    expect(p.sectionAt(7), 'Chapter 2');
    expect(p.describe(0), '0% · about 5 min left');
    expect(p.describe(7), '75% · about 1 min left');
    expect(p.describe(7, atEnd: true), '100%');
    expect(
      ReadingProgress(
        DocStructure(
          blocks: [
            ParagraphBlock(spans: [TextSpanData(List.filled(230 * 61, 'word').join(' '))]),
          ],
        ),
      ).describe(0),
      '0% · about 1 h 1 min left',
    );
  });

  test('a form value beside its label reads as one line', () {
    final doc = analyzeDocument([
      page(1, [
        tl('Application form', 72, size: 18, bold: true),
        ln([sp('Full name:', 72), sp('Jane Doe', 200)], 120),
        ln([sp('I agree to the terms', 72), sp('☑', 300)], 140),
      ]),
    ]);
    final text = doc.plainText;
    expect(text, contains('Full name:'));
    expect(text.indexOf('Jane Doe'), greaterThan(text.indexOf('Full name:')));
    expect(text, contains('☑'));
  });
}
