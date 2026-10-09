import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/convert/engine/convert_engine.dart';
import 'package:xml/xml.dart';

void main() {
  void expectValidXmlParts(Uint8List zip) {
    final archive = ZipDecoder().decodeBytes(zip);
    for (final f in archive.files.where((f) => f.name.endsWith('.xml') || f.name.endsWith('.rels'))) {
      expect(() => XmlDocument.parse(String.fromCharCodes(f.content as List<int>)), returnsNormally, reason: f.name);
    }
  }

  test('xlsx: content and per-table sheets with numbers, bold headers, escaping', () {
    final doc = DocStructure(blocks: [
      const HeadingBlock(level: 1, spans: [TextSpanData('Sales <2026>')]),
      const ParagraphBlock(spans: [TextSpanData('Totals & notes')]),
      const TableBlock(hasHeader: true, rows: [
        ['Region', 'Q1', 'Q2'],
        ['North', '1,200', '1.5'],
      ]),
    ]);
    final sheets = structureToSheets(doc);
    expect(sheets.map((s) => s.name), ['Content', 'Table 1']);
    final bytes = buildXlsx(sheets, title: 'Sales');
    expectValidXmlParts(bytes);
    final parsed = parseXlsx(bytes); // round trip through our reader
    expect(parsed.length, 2);
    final table = parsed[1].table.rows;
    expect(table[0], ['Region', 'Q1', 'Q2']);
    expect(table[1], ['North', '1200', '1.5']);
    final sheet1 = String.fromCharCodes(ZipDecoder().decodeBytes(bytes).findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(sheet1, contains('Sales &lt;2026&gt;'));
    File('${Directory.systemTemp.path}/pdfcraft_test.xlsx').writeAsBytesSync(bytes);
  });

  test('pptx: slides with background picture and editable text boxes', () {
    final bg = img.Image(width: 120, height: 160);
    img.fill(bg, color: img.ColorRgb8(240, 240, 255));
    final png = Uint8List.fromList(img.encodePng(bg));
    final bytes = buildPptx([
      SlideSpec(widthPt: 595, heightPt: 842, background: png, textBoxes: const [
        SlideTextBox(left: 72, top: 72, width: 300, height: 40, lines: ['Quarterly Report'], fontSize: 28, bold: true, color: 0xFFB91C1C),
        SlideTextBox(left: 72, top: 140, width: 450, height: 60, lines: ['First line', 'Second & line'], fontSize: 12, serif: true),
      ]),
      const SlideSpec(widthPt: 842, heightPt: 595, textBoxes: [SlideTextBox(left: 10, top: 10, width: 100, height: 20, lines: ['Landscape'], fontSize: 12)]),
    ], title: 'Deck');
    expectValidXmlParts(bytes);
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.findFile('ppt/slides/slide1.xml'), isNotNull);
    expect(archive.findFile('ppt/slides/slide2.xml'), isNotNull);
    expect(archive.findFile('ppt/media/image1.png'), isNotNull);
    final slide1 = String.fromCharCodes(archive.findFile('ppt/slides/slide1.xml')!.content as List<int>);
    expect(slide1, contains('<a:t>Quarterly Report</a:t>'));
    expect(slide1, contains('Second &amp; line'));
    expect(slide1, contains('B91C1C'));
    expect(slide1, contains('Times New Roman'));
    File('${Directory.systemTemp.path}/pdfcraft_test.pptx').writeAsBytesSync(bytes);
  });
}
