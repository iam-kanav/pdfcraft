import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// A worksheet cell.
class XlsxCell {
  const XlsxCell(this.text, {this.bold = false, this.wrap = false});

  final String text;
  final bool bold;
  final bool wrap;
}

class XlsxSheet {
  XlsxSheet(this.name, this.rows);

  final String name;
  final List<List<XlsxCell>> rows;
}

final _numberRe = RegExp(r'^-?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$');

/// Converts a document structure into worksheets: a "Content" sheet with every block in
/// reading order (tables laid out as grids) plus one sheet per table.
List<XlsxSheet> structureToSheets(DocStructure doc) {
  final content = <List<XlsxCell>>[];
  final tables = <XlsxSheet>[];
  for (final b in doc.blocks) {
    switch (b) {
      case HeadingBlock h:
        if (content.isNotEmpty) content.add(const []);
        content.add([XlsxCell(h.text, bold: true)]);
      case ParagraphBlock p:
        content.add([XlsxCell(p.text, wrap: true)]);
      case QuoteBlock q:
        content.add([XlsxCell(q.text, wrap: true)]);
      case ListItemBlock l:
        content.add([XlsxCell('${'  ' * l.indent}${l.ordered ? (l.marker ?? '1.') : '•'} ${l.text}', wrap: true)]);
      case TableBlock t:
        final grid = [
          for (var r = 0; r < t.rows.length; r++) [for (final c in t.rows[r]) XlsxCell(c, bold: t.hasHeader && r == 0)],
        ];
        content
          ..add(const [])
          ..addAll(grid)
          ..add(const []);
        tables.add(XlsxSheet('Table ${tables.length + 1}', grid));
      case ImageBlock im:
        if (im.caption != null && im.caption!.isNotEmpty) content.add([XlsxCell('[Image] ${im.caption}')]);
      case PageBreakBlock():
        break;
    }
  }
  return [XlsxSheet('Content', content), ...tables];
}

String _colName(int index) {
  var n = index + 1;
  final sb = StringBuffer();
  while (n > 0) {
    final r = (n - 1) % 26;
    sb.write(String.fromCharCode(65 + r));
    n = (n - 1) ~/ 26;
  }
  return sb.toString().split('').reversed.join();
}

String _safeSheetName(String name, Set<String> used) {
  var n = name.replaceAll(RegExp(r'[\[\]\*\?/\\:]'), ' ').trim();
  if (n.isEmpty) n = 'Sheet';
  if (n.length > 31) n = n.substring(0, 31);
  var candidate = n;
  var i = 2;
  while (used.contains(candidate.toLowerCase())) {
    final suffix = ' ($i)';
    candidate = (n.length + suffix.length > 31 ? n.substring(0, 31 - suffix.length) : n) + suffix;
    i++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}

/// Builds a valid .xlsx workbook (inline strings, numeric cells, bold header style, wrapped text).
Uint8List buildXlsx(List<XlsxSheet> sheets, {String? title}) {
  if (sheets.isEmpty) sheets = [XlsxSheet('Sheet1', const [])];
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  final used = <String>{};
  final names = [for (final s in sheets) _safeSheetName(s.name, used)];
  add('[Content_Types].xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${[for (var i = 0; i < sheets.length; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>''');
  add('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>''');
  add('docProps/core.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>${xmlEscape(title ?? '')}</dc:title><dc:creator>PDFCraft</dc:creator></cp:coreProperties>''');
  add('xl/workbook.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${[for (var i = 0; i < sheets.length; i++) '<sheet name="${xmlEscape(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets></workbook>''');
  add('xl/_rels/workbook.xml.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${[for (var i = 0; i < sheets.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''');
  // Style 0: default, 1: bold, 2: wrapped, 3: bold+wrapped.
  add('xl/styles.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>''');

  for (var i = 0; i < sheets.length; i++) {
    final rows = sheets[i].rows;
    final widths = <int, int>{};
    final sb = StringBuffer('<sheetData>');
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (row.isEmpty) continue;
      sb.write('<row r="${r + 1}">');
      for (var c = 0; c < row.length; c++) {
        final cell = row[c];
        final text = stripInvalidXmlChars(cell.text);
        if (text.isEmpty) continue;
        final ref = '${_colName(c)}${r + 1}';
        final style = (cell.bold ? 1 : 0) + (cell.wrap ? 2 : 0);
        final sAttr = style == 0 ? '' : ' s="$style"';
        final longest = text.split('\n').fold<int>(0, (m, l) => l.length > m ? l.length : m);
        widths[c] = (widths[c] ?? 8) < longest ? longest : (widths[c] ?? 8);
        if (_numberRe.hasMatch(text.trim())) {
          sb.write('<c r="$ref"$sAttr><v>${text.trim().replaceAll(',', '')}</v></c>');
        } else {
          sb.write('<c r="$ref" t="inlineStr"$sAttr><is><t xml:space="preserve">${xmlEscape(text)}</t></is></c>');
        }
      }
      sb.write('</row>');
    }
    sb.write('</sheetData>');
    final cols = widths.isEmpty
        ? ''
        : '<cols>${[for (final e in (widths.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) '<col min="${e.key + 1}" max="${e.key + 1}" width="${(e.value.clamp(8, 90) + 2)}" customWidth="1"/>'].join()}</cols>';
    add('xl/worksheets/sheet${i + 1}.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">$cols$sb</worksheet>''');
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
