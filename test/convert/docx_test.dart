import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/convert/engine/docx_reader.dart';
import 'package:pdfcraft/features/convert/engine/docx_writer.dart';
import 'package:xml/xml.dart';

import 'test_helpers.dart';

DocStructure richDoc(Uint8List png, Uint8List jpeg) => DocStructure(
  title: 'Round Trip & <Test>',
  blocks: [
    const HeadingBlock(level: 1, spans: [TextSpanData('Grüße – 你好')]),
    const ParagraphBlock(
      spans: [
        TextSpanData('Plain '),
        TextSpanData('bold', bold: true),
        TextSpanData(' and '),
        TextSpanData('italic', italic: true),
        TextSpanData(' and '),
        TextSpanData('under', underline: true),
        TextSpanData(' '),
        TextSpanData('all three', bold: true, italic: true, underline: true),
        TextSpanData(' see '),
        TextSpanData('the link', link: 'https://example.com/a?b=1&c=2'),
        TextSpanData(' and '),
        TextSpanData(
          'bold link',
          bold: true,
          link: 'mailto:someone@example.com',
        ),
        TextSpanData(' <tags> & "quotes"\ttab\nsecond line'),
      ],
    ),
    const HeadingBlock(
      level: 2,
      spans: [TextSpanData('Level two '), TextSpanData('emph', italic: true)],
    ),
    const HeadingBlock(level: 3, spans: [TextSpanData('Level three')]),
    const HeadingBlock(level: 4, spans: [TextSpanData('Level four')]),
    const HeadingBlock(level: 5, spans: [TextSpanData('Level five')]),
    const HeadingBlock(level: 6, spans: [TextSpanData('Level six')]),
    const ListItemBlock(spans: [TextSpanData('bullet one')]),
    const ListItemBlock(
      spans: [TextSpanData('nested '), TextSpanData('bullet', bold: true)],
      indent: 1,
    ),
    const ListItemBlock(
      spans: [TextSpanData('nested ordered')],
      ordered: true,
      indent: 1,
    ),
    const ListItemBlock(spans: [TextSpanData('ordered one')], ordered: true),
    const ListItemBlock(spans: [TextSpanData('ordered two')], ordered: true),
    const QuoteBlock(
      spans: [
        TextSpanData('A wise quote, '),
        TextSpanData('emphasised', italic: true),
      ],
    ),
    ImageBlock(
      bytes: png,
      width: 40,
      height: 20,
      caption: 'Figure 1: red & blue',
    ),
    ImageBlock(bytes: jpeg, width: 2000, height: 1000),
    const TableBlock(
      rows: [
        ['Name', 'Qty', 'Note'],
        ['Äpfel', '3', 'fresh & <crisp>'],
        ['Birnen', '', 'multi\nline'],
      ],
      hasHeader: true,
    ),
    const TableBlock(
      rows: [
        ['a', 'b'],
        ['c', 'd'],
      ],
    ),
    const PageBreakBlock(),
    const ParagraphBlock(
      spans: [TextSpanData('After break: Ελληνικά, Кириллица.')],
    ),
    const ParagraphBlock(
      spans: [TextSpanData('Bad\u0001chars￿removed\u{1F600}ok')],
    ),
  ],
);

void main() {
  final png = makePng(40, 20);
  final jpeg = makeJpeg(2000, 1000);

  group('DOCX writer', () {
    final bytes = buildDocx(richDoc(png, jpeg), author: 'Tester');
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toList();

    test('contains all required parts and every XML part parses', () {
      expect(names.first, '[Content_Types].xml');
      for (final part in [
        '[Content_Types].xml',
        '_rels/.rels',
        'docProps/core.xml',
        'docProps/app.xml',
        'word/document.xml',
        'word/styles.xml',
        'word/numbering.xml',
        'word/_rels/document.xml.rels',
        'word/settings.xml',
        'word/fontTable.xml',
        'word/media/image1.png',
        'word/media/image2.jpeg',
      ]) {
        expect(names, contains(part));
      }
      for (final f in archive.files.where(
        (f) => f.name.endsWith('.xml') || f.name.endsWith('.rels'),
      )) {
        expect(
          () => XmlDocument.parse(utf8.decode(f.readBytes()!)),
          returnsNormally,
          reason: f.name,
        );
      }
    });

    String part(String name) =>
        utf8.decode(archive.findFile(name)!.readBytes()!);

    test('content types, relationships and styles are declared', () {
      final ct = part('[Content_Types].xml');
      expect(ct, contains('Extension="png" ContentType="image/png"'));
      expect(ct, contains('Extension="jpeg" ContentType="image/jpeg"'));
      expect(ct, contains('/word/numbering.xml'));
      final rels = part('word/_rels/document.xml.rels');
      expect(
        rels,
        contains(
          'Target="https://example.com/a?b=1&amp;c=2" TargetMode="External"',
        ),
      );
      expect(rels, contains('media/image1.png'));
      final styles = part('word/styles.xml');
      for (final id in [
        'Normal',
        'Title',
        'Heading1',
        'Heading6',
        'ListParagraph',
        'Quote',
        'TableGrid',
      ]) {
        expect(styles, contains('w:styleId="$id"'));
      }
      expect(styles, contains('<w:outlineLvl w:val="5"/>'));
      final numbering = part('word/numbering.xml');
      expect(numbering, contains('w:val="bullet"'));
      expect(numbering, contains('w:val="decimal"'));
      final core = part('docProps/core.xml');
      expect(core, contains('Round Trip &amp; &lt;Test&gt;'));
      expect(core, contains('<dc:creator>Tester</dc:creator>'));
    });

    test('images are sized in EMU, capped at text width, aspect preserved', () {
      final doc = XmlDocument.parse(part('word/document.xml'));
      final extents = doc.descendantElements
          .where((e) => e.name.qualified == 'wp:extent')
          .toList();
      expect(extents, hasLength(2));
      expect(extents[0].getAttribute('cx'), '${40 * 9525}');
      expect(extents[0].getAttribute('cy'), '${20 * 9525}');
      final cx = int.parse(extents[1].getAttribute('cx')!);
      final cy = int.parse(extents[1].getAttribute('cy')!);
      expect(cx, (11906 - 2 * 1440) * 635);
      expect((cx / cy - 2).abs(), lessThan(0.001));
      expect(doc.toXmlString(), contains('xml:space="preserve"'));
      expect(doc.toXmlString(), contains('<w:br w:type="page"/>'));
    });
  });

  group('DOCX round trip', () {
    test('parseDocx(buildDocx(doc)) preserves the structure', () {
      final original = richDoc(png, jpeg);
      final parsed = parseDocx(buildDocx(original));
      expect(parsed.title, 'Round Trip & <Test>');

      final expected = original.blocks.map(describe).toList();
      // Invalid XML characters are stripped by the writer.
      expected[expected.length - 1] = [
        'P',
        ['"Badcharsremoved\u{1F600}ok"'],
      ];
      expect(parsed.blocks.map(describe).toList(), expected);

      final images = parsed.blocks.whereType<ImageBlock>().toList();
      expect(images[0].bytes, png);
      expect(images[1].bytes, jpeg);
      expect(images[0].width, 40);
      expect(images[0].height, 20);
      expect(images[0].caption, 'Figure 1: red & blue');
      // The large image was scaled down to the text width (~602 px at 96 dpi).
      expect(images[1].width, closeTo(602, 1));
      expect(images[1].height, closeTo(301, 1));

      final lists = parsed.blocks.whereType<ListItemBlock>().toList();
      expect(lists.map((l) => l.marker).toList(), ['•', '◦', 'a.', '1.', '2.']);

      final para = parsed.blocks[1] as ParagraphBlock;
      final link = para.spans.firstWhere((s) => s.text == 'the link');
      expect(link.link, 'https://example.com/a?b=1&c=2');
      expect(link.underline, isFalse);
      expect(para.text, contains('\ttab\nsecond line'));
    });

    test('ordered lists separated by other content restart numbering', () {
      final doc = DocStructure(
        blocks: const [
          ListItemBlock(spans: [TextSpanData('a')], ordered: true),
          ListItemBlock(spans: [TextSpanData('b')], ordered: true),
          ParagraphBlock(spans: [TextSpanData('between')]),
          ListItemBlock(spans: [TextSpanData('c')], ordered: true),
        ],
      );
      final parsed = parseDocx(buildDocx(doc));
      expect(
        parsed.blocks.whereType<ListItemBlock>().map((l) => l.marker).toList(),
        ['1.', '2.', '1.'],
      );
    });

    test('empty document is still valid', () {
      final bytes = buildDocx(DocStructure(blocks: const []));
      expect(parseDocx(bytes).blocks, isEmpty);
    });
  });

  group('DOCX reader (Word-style input)', () {
    test(
      'handles style names, overrides, numbering, merged cells, fields and unknown elements',
      () {
        final parsed = parseDocx(_wordLikeDocx(png));
        final d = parsed.blocks.map(describe).toList();
        expect(d, [
          [
            'H',
            1,
            ['"Doc Title"'],
          ],
          [
            'H',
            2,
            ['"Kapitel"'],
          ],
          [
            'H',
            3,
            ['"Outline heading"'],
          ],
          [
            'P',
            ['B"Bold by style "', '"not bold"'],
          ],
          [
            'P',
            [
              'B"strong char style"',
              '" plain "',
              'I"italic"',
              '"\tafter tab\nline2"',
            ],
          ],
          [
            'P',
            ['"before break"'],
          ],
          ['BR'],
          [
            'P',
            ['"after break"'],
          ],
          [
            'LI',
            false,
            0,
            ['"Bullet item"'],
          ],
          [
            'LI',
            true,
            1,
            ['"Decimal sub item"'],
          ],
          [
            'LI',
            true,
            1,
            ['"Decimal sub item 2"'],
          ],
          [
            'P',
            ['"Field link: "', '<https://dart.dev>"Dart"'],
          ],
          ['IMG', png.length, null],
          [
            'P',
            ['"Choice text"'],
          ],
          [
            'Q',
            ['"Intense"'],
          ],
          [
            'T',
            true,
            [
              ['H1', 'H2', 'H3'],
              ['span', '', 'x'],
              ['', 'y', 'z'],
            ],
          ],
        ]);
        final lists = parsed.blocks.whereType<ListItemBlock>().toList();
        expect(lists.map((l) => l.marker).toList(), ['•', '1.1', '1.2']);
        final img = parsed.blocks.whereType<ImageBlock>().single;
        expect(img.width, 100);
        expect(img.height, 50);
      },
    );

    test('rejects non-zip input with FormatException', () {
      expect(
        () => parseDocx(Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException,
      );
    });
  });

  group('external validation', () {
    final hasTextutil = File('/usr/bin/textutil').existsSync();
    test(
      'macOS textutil (Cocoa OOXML importer) reads the generated DOCX',
      () async {
        final dir = await Directory.systemTemp.createTemp('pdfcraft_textutil');
        try {
          final input = File('${dir.path}/doc.docx')
            ..writeAsBytesSync(buildDocx(richDoc(png, jpeg)));
          final r = await Process.run('/usr/bin/textutil', [
            '-convert',
            'txt',
            '-stdout',
            input.path,
          ]);
          expect(r.exitCode, 0, reason: '${r.stderr}');
          final text = r.stdout as String;
          for (final s in [
            'Grüße – 你好',
            'all three',
            'the link',
            'Level six',
            'nested bullet',
            'A wise quote',
            'Figure 1: red & blue',
            'fresh & <crisp>',
            'Ελληνικά, Кириллица',
          ]) {
            expect(text, contains(s));
          }
        } finally {
          await dir.delete(recursive: true);
        }
      },
      skip: hasTextutil ? false : 'textutil is only available on macOS',
    );

    final soffice = findSoffice();
    test(
      'LibreOffice converts the generated DOCX to PDF',
      () async {
        final dir = await Directory.systemTemp.createTemp('pdfcraft_docx');
        try {
          final input = File('${dir.path}/roundtrip.docx')
            ..writeAsBytesSync(buildDocx(richDoc(png, jpeg)));
          final r = await Process.run(soffice!, [
            '--headless',
            '--convert-to',
            'pdf',
            '--outdir',
            dir.path,
            input.path,
          ]);
          expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
          final pdf = File('${dir.path}/roundtrip.pdf');
          expect(pdf.existsSync(), isTrue);
          expect(pdf.lengthSync(), greaterThan(1000));
        } finally {
          await dir.delete(recursive: true);
        }
      },
      skip: soffice == null ? 'LibreOffice (soffice) is not installed' : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

/// A hand-written package resembling what MS Word produces, exercising the
/// reader's style resolution and robustness.
Uint8List _wordLikeDocx(Uint8List png) {
  const w =
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" '
      'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
      'xmlns:x="urn:unknown"';
  const styles =
      '<?xml version="1.0" encoding="UTF-8"?><w:styles $w>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Standard"><w:name w:val="Normal"/></w:style>'
      '<w:style w:type="paragraph" w:styleId="Titel"><w:name w:val="Title"/></w:style>'
      // German Word: id "berschrift2", name "heading 2".
      '<w:style w:type="paragraph" w:styleId="berschrift2"><w:name w:val="heading 2"/>'
      '<w:rPr><w:b/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Emphatic"><w:name w:val="Emphatic"/>'
      '<w:rPr><w:b/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="IntenseQuote"><w:name w:val="Intense Quote"/></w:style>'
      '<w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
      '<w:rPr><w:u w:val="single"/></w:rPr></w:style>'
      '</w:styles>';
  const numbering =
      '<?xml version="1.0" encoding="UTF-8"?><w:numbering $w>'
      '<w:abstractNum w:abstractNumId="7">'
      '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val=""/></w:lvl>'
      '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2"/></w:lvl>'
      '</w:abstractNum>'
      '<w:num w:numId="3"><w:abstractNumId w:val="7"/></w:num>'
      '</w:numbering>';
  const rels =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '<Relationship Id="rIdN" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="/word/numbering.xml"/>'
      '<Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/pic.png"/>'
      '<Relationship Id="rIdH" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>'
      '</Relationships>';
  const body =
      '<w:p><w:pPr><w:pStyle w:val="Titel"/></w:pPr><w:r><w:t>Doc Title</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:pStyle w:val="berschrift2"/></w:pPr><w:r><w:t>Kapitel</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:r><w:t>Outline heading</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:pStyle w:val="Emphatic"/></w:pPr><w:r><w:t xml:space="preserve">Bold by style </w:t></w:r>'
      '<w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>not bold</w:t></w:r></w:p>'
      '<w:p><w:proofErr w:type="spellStart"/><w:r><w:rPr><w:rStyle w:val="Strong"/></w:rPr><w:t>strong char style</w:t></w:r>'
      '<w:bookmarkStart w:id="0" w:name="x"/><w:r><w:t xml:space="preserve"> plain </w:t></w:r>'
      '<w:r><w:rPr><w:i w:val="true"/></w:rPr><w:t>italic</w:t></w:r><x:unknown><w:r><w:t>ignored</w:t></w:r></x:unknown>'
      '<w:r><w:tab/><w:t>after tab</w:t><w:br/><w:t>line2</w:t></w:r>'
      '<w:del><w:r><w:delText>deleted</w:delText></w:r></w:del><w:commentRangeStart w:id="1"/></w:p>'
      '<w:p><w:r><w:t>before break</w:t><w:br w:type="page"/><w:t>after break</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Bullet item</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Decimal sub item</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Decimal sub item 2</w:t></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">Field link: </w:t></w:r>'
      '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> HYPERLINK "https://dart.dev" </w:instrText></w:r>'
      '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>Dart</w:t></w:r>'
      '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
      '<w:p><w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="1" '
      'behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>'
      '<wp:extent cx="952500" cy="476250"/><wp:docPr id="1" name="P"/><a:graphic><a:graphicData '
      'uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:blipFill>'
      '<a:blip r:embed="rIdImg"/></pic:blipFill><pic:spPr><a:xfrm><a:ext cx="1" cy="1"/></a:xfrm></pic:spPr>'
      '</pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>'
      '<mc:AlternateContent><mc:Choice Requires="w14"><w:p><w:r><w:t>Choice text</w:t></w:r></w:p></mc:Choice>'
      '<mc:Fallback><w:p><w:r><w:t>Fallback text</w:t></w:r></w:p></mc:Fallback></mc:AlternateContent>'
      '<w:p><w:pPr><w:pStyle w:val="IntenseQuote"/></w:pPr><w:r><w:t>Intense</w:t></w:r></w:p>'
      '<w:p/>'
      '<w:tbl><w:tblPr/><w:tblGrid><w:gridCol/><w:gridCol/><w:gridCol/></w:tblGrid>'
      '<w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:t>H1</w:t></w:r></w:p></w:tc>'
      '<w:tc><w:p><w:r><w:t>H2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>H3</w:t></w:r></w:p></w:tc></w:tr>'
      '<w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>span</w:t></w:r></w:p></w:tc>'
      '<w:tc><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc></w:tr>'
      '<w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc><w:tc><w:p><w:r><w:t>y</w:t></w:r></w:p></w:tc>'
      '<w:tc><w:p><w:r><w:t>z</w:t></w:r></w:p><w:p/></w:tc></w:tr>'
      '</w:tbl>'
      '<w:sectPr><w:headerReference w:type="default" r:id="rIdH"/></w:sectPr>';
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '<?xml version="1.0"?><Types/>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
            'Target="word/document.xml"/></Relationships>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'word/document.xml',
        '<?xml version="1.0" encoding="UTF-8"?><w:document $w><w:body>$body</w:body></w:document>',
      ),
    )
    ..addFile(ArchiveFile.string('word/styles.xml', styles))
    ..addFile(ArchiveFile.string('word/numbering.xml', numbering))
    ..addFile(ArchiveFile.string('word/_rels/document.xml.rels', rels))
    ..addFile(
      ArchiveFile.string(
        'word/header1.xml',
        '<w:hdr $w><w:p><w:r><w:t>HEADER</w:t></w:r></w:p></w:hdr>',
      ),
    )
    ..addFile(ArchiveFile.bytes('word/media/pic.png', png));
  return ZipEncoder().encodeBytes(archive);
}
