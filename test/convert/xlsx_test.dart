import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/features/convert/engine/xlsx_reader.dart';

const _ns =
    'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
const _relNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

Uint8List buildXlsx({bool date1904 = false}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="$_relNs/officeDocument" Target="xl/workbook.xml"/></Relationships>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/workbook.xml',
        '<?xml version="1.0"?><workbook $_ns><workbookPr${date1904 ? ' date1904="1"' : ''}/><sheets>'
            '<sheet name="Data &amp; Stuff" sheetId="1" r:id="rId1"/>'
            '<sheet name="Second" sheetId="2" r:id="rId2"/>'
            '<sheet name="Secret" sheetId="3" state="veryHidden" r:id="rId3"/>'
            '<sheet name="Empty" sheetId="4" r:id="rId4"/>'
            '</sheets></workbook>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="$_relNs/worksheet" Target="worksheets/sheet1.xml"/>'
            '<Relationship Id="rId2" Type="$_relNs/worksheet" Target="/xl/worksheets/sheet2.xml"/>'
            '<Relationship Id="rId3" Type="$_relNs/worksheet" Target="worksheets/sheet3.xml"/>'
            '<Relationship Id="rId4" Type="$_relNs/worksheet" Target="worksheets/sheet4.xml"/>'
            '<Relationship Id="rId5" Type="$_relNs/sharedStrings" Target="sharedStrings.xml"/>'
            '<Relationship Id="rId6" Type="$_relNs/styles" Target="styles.xml"/>'
            '</Relationships>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/sharedStrings.xml',
        '<?xml version="1.0"?><sst $_ns count="4" uniqueCount="4">'
            '<si><t>Name</t></si>'
            '<si><t>Value</t></si>'
            '<si><r><rPr><b/></rPr><t>Rich </t></r><r><t xml:space="preserve">text &amp; more</t></r>'
            '<rPh sb="0" eb="1"><t>PHONETIC</t></rPh></si>'
            '<si><t>Ünïcødé 你好</t></si>'
            '</sst>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/styles.xml',
        '<?xml version="1.0"?><styleSheet $_ns><numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts>'
            '<cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="10"/><xf numFmtId="164"/>'
            '<xf numFmtId="4"/></cellXfs></styleSheet>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet1.xml',
        '<?xml version="1.0"?><worksheet $_ns><dimension ref="A1:D5"/><sheetData>'
            '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
            '<row r="2"><c r="A2" t="inlineStr"><is><t>Inline</t></is></c><c r="B2"><v>42</v></c>'
            '<c r="C2"><v>3.5</v></c></row>'
            '<row r="3"><c r="A3" t="s"><v>2</v></c><c r="B3" t="b"><v>1</v></c><c r="C3" t="b"><v>0</v></c></row>'
            '<row r="4"><c r="A4" t="str"><f>A1&amp;"x"</f><v>Namex</v></c><c r="B4" t="e"><v>#DIV/0!</v></c>'
            '<c r="C4"><v>0.1</v></c><c r="D4"><v>1E-3</v></c></row>'
            '<row r="5"><c r="A5" t="s"><v>3</v></c><c r="B5" s="1"><v>45292</v></c><c r="C5" s="2"><v>0.1234</v></c>'
            '<c r="D5" s="3"><v>45292.5</v></c></row>'
            '<row r="6"><c r="A6" s="4"><v>1234567.891</v></c><c r="B6"/><c r="E6" t="s"/></row>'
            '<row r="9"><c r="A9"><v></v></c></row>'
            '</sheetData></worksheet>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet2.xml',
        // Sparse: A1 and C3 only; second row has no r attributes.
        '<?xml version="1.0"?><worksheet $_ns><sheetData>'
            '<row r="1"><c r="A1" t="inlineStr"><is><r><t>rich</t></r><r><t>-inline</t></r></is></c></row>'
            '<row><c><v>7</v></c><c><v>8</v></c></row>'
            '<row r="3"><c r="C3" t="inlineStr"><is><t>far</t></is></c></row>'
            '<row r="20"/>'
            '</sheetData></worksheet>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet3.xml',
        '<?xml version="1.0"?><worksheet $_ns><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet4.xml',
        '<?xml version="1.0"?><worksheet $_ns><sheetData/></worksheet>',
      ),
    );
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  test('columnIndex converts letters', () {
    expect(columnIndex('A'), 0);
    expect(columnIndex('Z'), 25);
    expect(columnIndex('AA'), 26);
    expect(columnIndex('az'), 51);
    expect(columnIndex('XFD'), 16383);
  });

  test('parses sheets, value types, formats and places cells by reference', () {
    final sheets = parseXlsx(buildXlsx());
    expect(sheets.map((s) => s.name).toList(), [
      'Data & Stuff',
      'Second',
      'Empty',
    ]);

    final t1 = sheets[0].table;
    expect(t1.rows, [
      ['Name', 'Value', '', ''],
      ['Inline', '42', '3.5', ''],
      ['Rich text & more', 'TRUE', 'FALSE', ''],
      ['Namex', '#DIV/0!', '0.1', '0.001'],
      ['Ünïcødé 你好', '2024-01-01', '12.34%', '2024-01-01'],
      ['1,234,567.89', '', '', ''],
    ]);
    expect(t1.hasHeader, isTrue);

    final t2 = sheets[1].table;
    expect(t2.rows, [
      ['rich-inline', '', ''],
      ['7', '8', ''],
      ['', '', 'far'],
    ]);
    expect(t2.columnCount, 3);
    expect(t2.hasHeader, isFalse);

    expect(sheets[2].table.rows, isEmpty);
  });

  test('date1904 workbooks shift dates', () {
    final t1 = parseXlsx(buildXlsx(date1904: true))[0].table;
    expect(t1.rows[4][1], '2028-01-02');
  });

  test('xlsxToStructure yields heading + table per sheet', () {
    final doc = xlsxToStructure(buildXlsx());
    expect(doc.blocks.map((b) => b.runtimeType).toList(), [
      HeadingBlock,
      TableBlock,
      HeadingBlock,
      TableBlock,
      HeadingBlock,
    ]);
    expect((doc.blocks.first as HeadingBlock).text, 'Data & Stuff');
  });

  test('invalid data throws FormatException', () {
    expect(
      () => parseXlsx(Uint8List.fromList([0, 1, 2])),
      throwsFormatException,
    );
    final noWorkbook = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile.string('a.txt', 'x')),
    );
    expect(() => parseXlsx(noWorkbook), throwsFormatException);
  });
}
