import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/convert/engine/images_to_pdf.dart';
import 'package:pdfcraft/features/convert/engine/pdf_builder.dart';

import 'test_helpers.dart';

const _lorem =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor '
    'incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation '
    'ullamco laboris nisi ut aliquip ex ea commodo consequat. ';

DocStructure richDoc(Uint8List png, Uint8List jpeg) => DocStructure(
  blocks: [
    const HeadingBlock(level: 1, spans: [TextSpanData('Grüße – Ελληνικά – Кириллица')]),
    const ParagraphBlock(
      spans: [
        TextSpanData('Plain, '),
        TextSpanData('bold', bold: true),
        TextSpanData(', '),
        TextSpanData('italic', italic: true),
        TextSpanData(', '),
        TextSpanData('both', bold: true, italic: true),
        TextSpanData(', '),
        TextSpanData('underlined', underline: true),
        TextSpanData(' and a '),
        TextSpanData('link', link: 'https://example.com'),
        TextSpanData('.\tTabbed\nNew line. Control\u0007char.'),
      ],
    ),
    for (var l = 2; l <= 6; l++) HeadingBlock(level: l, spans: [TextSpanData('Heading level $l')]),
    const ListItemBlock(spans: [TextSpanData('Bullet')]),
    const ListItemBlock(spans: [TextSpanData('Nested bullet')], indent: 1),
    const ListItemBlock(spans: [TextSpanData('Nested number')], ordered: true, indent: 1),
    const ListItemBlock(spans: [TextSpanData('Number one')], ordered: true),
    const ListItemBlock(spans: [TextSpanData('Number two')], ordered: true),
    const QuoteBlock(spans: [TextSpanData('A quotation.')]),
    ImageBlock(bytes: png, width: 200, height: 100, caption: 'Caption'),
    ImageBlock(bytes: jpeg, width: 3000, height: 6000),
    const TableBlock(
      rows: [
        ['Name', 'Value'],
        ['α', '1'],
        ['β', '2\nlines'],
      ],
      hasHeader: true,
    ),
    TableBlock(rows: [List.generate(14, (i) => 'Column $i'), List.generate(14, (i) => '$i')], hasHeader: true),
    const PageBreakBlock(),
    const ParagraphBlock(spans: [TextSpanData('Missing glyphs: 你好 ✓ are tolerated.')]),
  ],
);

void main() {
  late PdfFontSet fonts;
  final png = makePng(200, 100);
  final jpeg = makeJpeg(300, 600);

  setUpAll(() async {
    fonts = await loadTestFonts();
  });

  group('buildPdfFromStructure', () {
    test('renders every block type with metadata', () async {
      final bytes = await buildPdfFromStructure(
        richDoc(png, jpeg),
        fonts: fonts,
        title: 'Rich Test Document',
        author: 'Tester',
        compress: false,
      );
      expectValidPdfEnvelope(bytes);
      final text = pdfText(bytes);
      bool has(String pattern) => RegExp(pattern).hasMatch(text);
      expect(has(r'/Title\s*\(Rich Test Document\)'), isTrue);
      expect(has(r'/Author\s*\(Tester\)'), isTrue);
      expect(has(r'/Creator\s*\(PDFCraft\)'), isTrue);
      expect(has(r'/URI\s*\(https://example\.com\)'), isTrue);
      expect(has(r'/FontFile2'), isTrue, reason: 'TrueType fonts must be embedded');
      expect(has(r'/BaseFont\s*/NotoSans-Regular'), isTrue);
      expect(has(r'/Helvetica'), isFalse);
      expect(has(r'/DCTDecode'), isTrue);
      // Explicit page break => at least 2 pages; the tall image gets its own.
      expect(pdfPageCount(bytes), greaterThanOrEqualTo(3));
    });

    test('compressed output is valid and smaller', () async {
      final doc = richDoc(png, jpeg);
      final compressed = await buildPdfFromStructure(doc, fonts: fonts, title: 'T');
      final plain = await buildPdfFromStructure(doc, fonts: fonts, title: 'T', compress: false);
      expectValidPdfEnvelope(compressed);
      expect(compressed.length, lessThan(plain.length));
    });

    test('long documents flow over many pages', () async {
      final doc = DocStructure(
        blocks: [
          for (var i = 0; i < 120; i++) ...[
            if (i % 20 == 0) HeadingBlock(level: 2, spans: [TextSpanData('Section ${i ~/ 20 + 1}')]),
            ParagraphBlock(spans: [TextSpanData('Paragraph $i. $_lorem')]),
          ],
        ],
      );
      final bytes = await buildPdfFromStructure(doc, fonts: fonts, compress: false);
      expectValidPdfEnvelope(bytes);
      expect(pdfPageCount(bytes), greaterThan(5));
    });

    test('single huge paragraph, list item, quote and table span pages', () async {
      final huge = _lorem * 120; // ~30k characters
      final doc = DocStructure(
        blocks: [
          ParagraphBlock(spans: [TextSpanData(huge), const TextSpanData(' bold tail', bold: true)]),
          ListItemBlock(spans: [TextSpanData(_lorem * 40)], ordered: true),
          QuoteBlock(spans: [TextSpanData(_lorem * 50)]),
          TableBlock(
            rows: [
              ['#', 'Text'],
              for (var i = 0; i < 150; i++) ['$i', 'Row $i'],
            ],
            hasHeader: true,
          ),
          TableBlock(
            rows: [
              ['huge cell', _lorem * 100],
              ['many lines', List.generate(300, (i) => 'line $i').join('\n')],
            ],
          ),
          HeadingBlock(level: 1, spans: [TextSpanData(_lorem * 40)]),
          ImageBlock(bytes: png, width: 200, height: 100, caption: _lorem * 30),
        ],
      );
      final bytes = await buildPdfFromStructure(doc, fonts: fonts, compress: false);
      expectValidPdfEnvelope(bytes);
      expect(pdfPageCount(bytes), greaterThan(12));
    });

    test('large base font on a small page still lays out long list items', () async {
      final doc = DocStructure(
        blocks: [
          ListItemBlock(spans: [TextSpanData(_lorem * 30)]),
          ListItemBlock(spans: [TextSpanData(_lorem * 30)], ordered: true, indent: 3),
        ],
      );
      final bytes = await buildPdfFromStructure(
        doc,
        fonts: fonts,
        format: PdfPageFormat.a6,
        margin: 20,
        baseFontSize: 24,
        compress: false,
      );
      expectValidPdfEnvelope(bytes);
      expect(pdfPageCount(bytes), greaterThan(20));
    });

    test('page breaks: leading, repeated and trailing breaks do not create blank pages', () async {
      final doc = DocStructure(
        blocks: const [
          PageBreakBlock(),
          ParagraphBlock(spans: [TextSpanData('one')]),
          PageBreakBlock(),
          PageBreakBlock(),
          ParagraphBlock(spans: [TextSpanData('two')]),
          PageBreakBlock(),
          ParagraphBlock(spans: [TextSpanData('three')]),
          PageBreakBlock(),
        ],
      );
      final bytes = await buildPdfFromStructure(doc, fonts: fonts, compress: false, pageNumbers: false);
      expect(pdfPageCount(bytes), 3);
    });

    test('empty document yields a single valid page; custom format is used', () async {
      final bytes = await buildPdfFromStructure(
        DocStructure(blocks: const []),
        fonts: fonts,
        format: PdfPageFormat.letter,
        compress: false,
      );
      expectValidPdfEnvelope(bytes);
      expect(pdfPageCount(bytes), 1);
      final box = pdfMediaBoxes(bytes).single;
      expect(box.width, closeTo(612, 0.5));
      expect(box.height, closeTo(792, 0.5));
    });

    test('pypdf reads the output and extracts Unicode text', () async {
      final bytes = await buildPdfFromStructure(richDoc(png, jpeg), fonts: fonts, title: 'Ext');
      final dir = await Directory.systemTemp.createTemp('pdfcraft_pdf');
      try {
        final f = File('${dir.path}/out.pdf')..writeAsBytesSync(bytes);
        final r = await Process.run('python3', [
          '-c',
          'import sys, pypdf\n'
              'r = pypdf.PdfReader(sys.argv[1], strict=True)\n'
              'print(len(r.pages)); print(r.metadata.title)\n'
              'print("".join(p.extract_text() for p in r.pages))',
          f.path,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final out = r.stdout as String;
        final lines = out.split('\n');
        expect(int.parse(lines[0]), greaterThanOrEqualTo(3));
        expect(lines[1], 'Ext');
        expect(out, contains('Ελληνικά'));
        expect(out, contains('Кириллица'));
        expect(out, contains('Grüße'));
      } finally {
        await dir.delete(recursive: true);
      }
    }, skip: hasPypdf() ? false : 'python3 with pypdf is not available');
  });

  group('buildPdfFromImages', () {
    final wide = makePng(300, 200);
    final tall = makeJpeg(100, 400);
    final rotated = makeJpeg(100, 50, exifOrientation: 6); // displays as 50x100

    test('fitImage: one page per image, long side 842pt, aspect kept, EXIF respected', () async {
      final bytes = await buildPdfFromImages([wide, tall, rotated], title: 'Scans', compress: false);
      expectValidPdfEnvelope(bytes);
      expect(pdfPageCount(bytes), 3);
      expect(RegExp(r'/Title\s*\(Scans\)').hasMatch(pdfText(bytes)), isTrue);
      final boxes = pdfMediaBoxes(bytes);
      expect(boxes[0].width, closeTo(842, 0.5));
      expect(boxes[0].height, closeTo(842 * 2 / 3, 0.5));
      expect(boxes[1].width, closeTo(210.5, 0.5));
      expect(boxes[1].height, closeTo(842, 0.5));
      expect(boxes[2].width, closeTo(421, 0.5));
      expect(boxes[2].height, closeTo(842, 0.5));
    });

    test('JPEG data is embedded without recompression', () async {
      final bytes = await buildPdfFromImages([tall], compress: false);
      final text = pdfText(bytes);
      expect(RegExp(r'/DCTDecode').hasMatch(text), isTrue);
      expect(text.contains(pdfText(tall)), isTrue, reason: 'original JPEG bytes should appear verbatim');
    });

    test('A4 auto orientation picks landscape for wide images', () async {
      final bytes = await buildPdfFromImages([wide, tall], pageSize: ImagePageSize.a4, margin: 20, compress: false);
      final boxes = pdfMediaBoxes(bytes);
      expect(boxes[0].width, closeTo(PdfPageFormat.a4.height, 0.5));
      expect(boxes[0].height, closeTo(PdfPageFormat.a4.width, 0.5));
      expect(boxes[1].width, closeTo(PdfPageFormat.a4.width, 0.5));
      expect(boxes[1].height, closeTo(PdfPageFormat.a4.height, 0.5));
    });

    test('forced orientation and Letter size', () async {
      final portrait = await buildPdfFromImages(
        [wide],
        pageSize: ImagePageSize.a4,
        orientation: PdfPageOrientationMode.portrait,
        compress: false,
      );
      final p = pdfMediaBoxes(portrait).single;
      expect(p.width, lessThan(p.height));
      final landscape = await buildPdfFromImages(
        [tall],
        pageSize: ImagePageSize.letter,
        orientation: PdfPageOrientationMode.landscape,
        compress: false,
      );
      final l = pdfMediaBoxes(landscape).single;
      expect(l.width, closeTo(792, 0.5));
      expect(l.height, closeTo(612, 0.5));
    });

    test('fitImage adds margins around the image', () async {
      final bytes = await buildPdfFromImages([wide], margin: 30, compress: false);
      final b = pdfMediaBoxes(bytes).single;
      expect(b.width, closeTo(842 + 60, 0.5));
      expect(b.height, closeTo(842 * 2 / 3 + 60, 0.5));
    });

    test('rejects empty input and undecodable data', () async {
      expect(() => buildPdfFromImages([]), throwsArgumentError);
      expect(() => buildPdfFromImages([Uint8List.fromList(List.filled(64, 7))]), throwsFormatException);
    });
  });
}
