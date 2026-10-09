import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'package:pdfcraft/core/models/doc_structure.dart';

/// Maximum number of cells materialised per sheet; rows beyond this are
/// dropped to keep memory bounded on mobile devices.
const int _maxCellsPerSheet = 2000000;

/// Reads every worksheet of an .xlsx workbook as a rectangular table.
///
/// Values: shared strings (including rich text runs), inline strings,
/// numbers (with basic date / percent / fixed-decimal formatting), booleans
/// (`TRUE`/`FALSE`), formula string results and errors. Cells are placed by
/// their reference (A1, AA12, ...); empty trailing rows and columns are
/// trimmed. Throws [FormatException] for data that is not an xlsx package.
List<({String name, TableBlock table})> parseXlsx(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw FormatException('Not a valid XLSX (zip) file: $e');
  }
  return _XlsxReader(archive).read();
}

/// Converts a workbook into a document: a level-1 heading per sheet followed
/// by the sheet's table.
DocStructure xlsxToStructure(Uint8List bytes) {
  final blocks = <DocBlock>[];
  for (final sheet in parseXlsx(bytes)) {
    blocks.add(HeadingBlock(level: 1, spans: [TextSpanData(sheet.name)]));
    if (sheet.table.rows.isNotEmpty) blocks.add(sheet.table);
  }
  return DocStructure(blocks: blocks);
}

/// Converts a column name ("A", "Z", "AA") to a 0-based index.
int columnIndex(String letters) {
  var n = 0;
  for (final c in letters.toUpperCase().codeUnits) {
    n = n * 26 + (c - 0x40);
  }
  return n - 1;
}

final RegExp _cellRef = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+)$');

class _XlsxReader {
  _XlsxReader(this.archive) {
    for (final f in archive.files) {
      if (f.isFile) _files[f.name.replaceAll('\\', '/').toLowerCase()] = f;
    }
  }

  final Archive archive;
  final Map<String, ArchiveFile> _files = {};
  List<String> _shared = const [];
  List<int> _xfNumFmt = const [];
  final Map<int, String> _customFormats = {};
  bool _date1904 = false;

  String? _text(String path) {
    var key = path.replaceAll('\\', '/');
    if (key.startsWith('/')) key = key.substring(1);
    final f = _files[key.toLowerCase()];
    final b = f?.readBytes();
    if (b == null) return null;
    var start = 0;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      start = 3;
    }
    return const Utf8Decoder(allowMalformed: true).convert(b, start);
  }

  String _resolve(String baseDir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    return p.posix.normalize(p.posix.join(baseDir, target));
  }

  Map<String, ({String type, String target})> _rels(String relsPath) {
    final out = <String, ({String type, String target})>{};
    final xml = _text(relsPath);
    if (xml == null) return out;
    try {
      for (final r in XmlDocument.parse(xml).rootElement.childElements) {
        final id = _attr(r, 'Id');
        final target = _attr(r, 'Target');
        if (id != null && target != null) {
          out[id] = (type: _attr(r, 'Type') ?? '', target: target);
        }
      }
    } catch (_) {}
    return out;
  }

  List<({String name, TableBlock table})> read() {
    var workbookPath = 'xl/workbook.xml';
    for (final r in _rels('_rels/.rels').values) {
      if (r.type.endsWith('/officeDocument')) {
        workbookPath = _resolve('', r.target);
      }
    }
    final workbookXml = _text(workbookPath);
    if (workbookXml == null) {
      throw const FormatException('XLSX package has no workbook part');
    }
    final baseDir = p.posix.dirname(workbookPath);
    final rels = _rels(p.posix.join(baseDir, '_rels', '${p.posix.basename(workbookPath)}.rels'));

    for (final r in rels.values) {
      if (r.type.endsWith('/sharedStrings')) {
        _shared = _parseSharedStrings(_text(_resolve(baseDir, r.target)));
      }
      if (r.type.endsWith('/styles')) {
        _parseStyles(_text(_resolve(baseDir, r.target)));
      }
    }

    final XmlDocument workbook;
    try {
      workbook = XmlDocument.parse(workbookXml);
    } catch (e) {
      throw FormatException('Invalid workbook.xml: $e');
    }
    final pr = workbook.rootElement.descendantElements.where((e) => e.name.local == 'workbookPr').firstOrNull;
    final d1904 = pr == null ? null : _attr(pr, 'date1904');
    _date1904 = d1904 == '1' || d1904 == 'true';

    final result = <({String name, TableBlock table})>[];
    for (final sheet in workbook.rootElement.descendantElements.where((e) => e.name.local == 'sheet')) {
      if (_attr(sheet, 'state') == 'veryHidden') continue;
      final name = _attr(sheet, 'name') ?? 'Sheet${result.length + 1}';
      final rid = _attr(sheet, 'id');
      final rel = rid == null ? null : rels[rid];
      String? path;
      if (rel != null && rel.type.endsWith('/worksheet')) {
        path = _resolve(baseDir, rel.target);
      } else if (rel == null) {
        path = '$baseDir/worksheets/sheet${result.length + 1}.xml';
      }
      if (path == null) continue; // chartsheets, dialog sheets, ...
      final xml = _text(path);
      if (xml == null) continue;
      result.add((name: name, table: _parseSheet(xml)));
    }
    return result;
  }

  List<String> _parseSharedStrings(String? xml) {
    if (xml == null) return const [];
    final out = <String>[];
    StringBuffer? current;
    var inT = false;
    var phonetic = 0;
    for (final e in parseEvents(xml)) {
      if (e is XmlStartElementEvent) {
        switch (e.localName) {
          case 'si':
            current = StringBuffer();
            if (e.isSelfClosing) {
              out.add('');
              current = null;
            }
          case 'rPh':
            if (!e.isSelfClosing) phonetic++;
          case 't':
            inT = !e.isSelfClosing;
        }
      } else if (e is XmlEndElementEvent) {
        switch (e.localName) {
          case 'si':
            out.add(current?.toString() ?? '');
            current = null;
          case 'rPh':
            phonetic--;
          case 't':
            inT = false;
        }
      } else if (inT && phonetic == 0 && current != null) {
        if (e is XmlTextEvent) current.write(e.value);
        if (e is XmlCDATAEvent) current.write(e.value);
      }
    }
    return out;
  }

  void _parseStyles(String? xml) {
    if (xml == null) return;
    try {
      final root = XmlDocument.parse(xml).rootElement;
      for (final f in root.descendantElements.where((e) => e.name.local == 'numFmt')) {
        final id = int.tryParse(_attr(f, 'numFmtId') ?? '');
        final code = _attr(f, 'formatCode');
        if (id != null && code != null) _customFormats[id] = code;
      }
      final cellXfs = root.childElements.where((e) => e.name.local == 'cellXfs').firstOrNull;
      if (cellXfs != null) {
        _xfNumFmt = cellXfs.childElements
            .where((e) => e.name.local == 'xf')
            .map((xf) => int.tryParse(_attr(xf, 'numFmtId') ?? '') ?? 0)
            .toList();
      }
    } catch (_) {}
  }

  TableBlock _parseSheet(String xml) {
    final cells = <int, Map<int, String>>{};
    var maxRow = -1;
    var maxCol = -1;
    var row = -1;
    var col = -1;

    // Current cell state.
    var inCell = false;
    String? type;
    int? style;
    var cellRow = 0;
    var cellCol = 0;
    StringBuffer? capture;
    final value = StringBuffer();
    final inline = StringBuffer();
    var inInline = false;
    var phonetic = 0;
    var inSheetData = false;

    void endCell() {
      final raw = inInline ? inline.toString() : value.toString();
      final text = _cellValue(type, raw, style, inlineStr: type == 'inlineStr' || inline.isNotEmpty);
      if (text.isNotEmpty) {
        (cells[cellRow] ??= {})[cellCol] = text;
        maxRow = math.max(maxRow, cellRow);
        maxCol = math.max(maxCol, cellCol);
      }
      inCell = false;
    }

    for (final e in parseEvents(xml)) {
      if (e is XmlStartElementEvent) {
        switch (e.localName) {
          case 'sheetData':
            inSheetData = !e.isSelfClosing;
          case 'row' when inSheetData:
            final r = int.tryParse(_eventAttr(e, 'r') ?? '');
            row = r != null ? r - 1 : row + 1;
            col = -1;
          case 'c' when inSheetData:
            final ref = _eventAttr(e, 'r');
            final m = ref == null ? null : _cellRef.firstMatch(ref);
            if (m != null) {
              cellCol = columnIndex(m.group(1)!);
              cellRow = int.parse(m.group(2)!) - 1;
            } else {
              cellCol = col + 1;
              cellRow = row < 0 ? 0 : row;
            }
            col = cellCol;
            type = _eventAttr(e, 't');
            style = int.tryParse(_eventAttr(e, 's') ?? '');
            value.clear();
            inline.clear();
            inInline = false;
            inCell = true;
            if (e.isSelfClosing) inCell = false;
          case 'v' when inCell:
            capture = e.isSelfClosing ? null : value;
          case 'is' when inCell:
            inInline = true;
          case 'rPh':
            if (!e.isSelfClosing) phonetic++;
          case 't' when inCell && inInline:
            capture = e.isSelfClosing ? null : inline;
        }
      } else if (e is XmlEndElementEvent) {
        switch (e.localName) {
          case 'sheetData':
            inSheetData = false;
          case 'c' when inCell:
            endCell();
          case 'v' || 't':
            capture = null;
          case 'rPh':
            phonetic--;
        }
      } else if (capture != null && phonetic == 0) {
        if (e is XmlTextEvent) capture.write(e.value);
        if (e is XmlCDATAEvent) capture.write(e.value);
      }
    }

    if (maxRow < 0 || maxCol < 0) return const TableBlock(rows: []);
    var rowCount = maxRow + 1;
    final colCount = maxCol + 1;
    if (rowCount * colCount > _maxCellsPerSheet) {
      rowCount = math.max(1, _maxCellsPerSheet ~/ colCount);
    }
    final rows = List<List<String>>.generate(rowCount, (r) {
      final src = cells[r];
      return List<String>.generate(colCount, (c) => src?[c] ?? '');
    });
    // Trim trailing empty rows (possible after the row cap).
    while (rows.isNotEmpty && rows.last.every((c) => c.isEmpty)) {
      rows.removeLast();
    }
    // Header heuristic: a first row of text labels covering at least half of
    // the columns.
    final firstFilled = rows.isEmpty ? const <String>[] : rows.first.where((c) => c.trim().isNotEmpty).toList();
    final hasHeader =
        rows.length > 1 &&
        firstFilled.length * 2 >= colCount &&
        firstFilled.every((c) => double.tryParse(c.replaceAll(',', '').replaceAll('%', '')) == null);
    return TableBlock(rows: rows, hasHeader: hasHeader);
  }

  String _cellValue(String? type, String raw, int? style, {required bool inlineStr}) {
    switch (type) {
      case 's':
        final idx = int.tryParse(raw.trim());
        return idx != null && idx >= 0 && idx < _shared.length ? _shared[idx] : '';
      case 'inlineStr' || 'str' || 'e':
        return raw;
      case 'b':
        final v = raw.trim();
        return v == '1' || v.toLowerCase() == 'true' ? 'TRUE' : (v.isEmpty ? '' : 'FALSE');
      case 'd':
        return raw.trim();
      default:
        if (inlineStr) return raw;
        final v = raw.trim();
        if (v.isEmpty) return '';
        final number = double.tryParse(v);
        if (number == null) return v;
        return _formatNumber(number, style);
    }
  }

  String _formatNumber(double v, int? style) {
    final fmtId = style != null && style >= 0 && style < _xfNumFmt.length ? _xfNumFmt[style] : 0;
    final code = _customFormats[fmtId] ?? _builtinFormats[fmtId] ?? 'General';
    final section = _cleanFormat(code.split(';').first);

    if (_isDateFormat(fmtId, section)) {
      final dt = _serialToDate(v);
      if (dt != null) return _formatDate(dt, v, section);
    }
    if (section.contains('%')) {
      final decimals = RegExp(r'\.(0+)').firstMatch(section)?.group(1)?.length ?? 0;
      return '${(v * 100).toStringAsFixed(decimals)}%';
    }
    final fixed = RegExp(r'^[#,0]*0(\.(0+))?$').firstMatch(section.replaceAll(RegExp(r'[^#,0.]'), ''));
    if (fixed != null && section.isNotEmpty && !section.toUpperCase().contains('E')) {
      final decimals = fixed.group(2)?.length ?? 0;
      var s = v.toStringAsFixed(decimals);
      if (section.contains(',')) s = _thousands(s);
      return s;
    }
    return _general(v);
  }

  String _general(double v) {
    if (v.isNaN || v.isInfinite) return v.toString();
    if (v == v.truncateToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    final s = double.parse(v.toStringAsPrecision(15)).toString();
    return s;
  }

  String _thousands(String s) {
    final neg = s.startsWith('-');
    final body = neg ? s.substring(1) : s;
    final parts = body.split('.');
    final intPart = parts[0];
    final sb = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) sb.write(',');
      sb.write(intPart[i]);
    }
    return '${neg ? '-' : ''}$sb${parts.length > 1 ? '.${parts[1]}' : ''}';
  }

  /// Removes quoted literals, escapes and bracketed modifiers (colours,
  /// locales) from a format code section.
  String _cleanFormat(String code) => code
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .replaceAll(RegExp(r'\[(?![hms]+\])[^\]]*\]'), '')
      .replaceAll(RegExp(r'[_*].'), '')
      .trim();

  bool _isDateFormat(int id, String cleaned) {
    if ((id >= 14 && id <= 22) || (id >= 27 && id <= 36) || (id >= 45 && id <= 47) || (id >= 50 && id <= 58)) {
      return true;
    }
    if (id < 164 && !_customFormats.containsKey(id)) return false;
    final lower = cleaned.toLowerCase();
    if (lower == 'general') return false;
    return RegExp(r'[dmyhs]').hasMatch(lower);
  }

  DateTime? _serialToDate(double serial) {
    if (serial < 0 || serial > 2958465) return null;
    final DateTime base;
    if (_date1904) {
      base = DateTime.utc(1904, 1, 1);
    } else {
      // Excel's fictitious 1900-02-29 shifts serials below 61 by one day.
      base = serial < 61 ? DateTime.utc(1899, 12, 31) : DateTime.utc(1899, 12, 30);
    }
    final ms = (serial * 86400000).round();
    return base.add(Duration(milliseconds: ms));
  }

  String _formatDate(DateTime dt, double serial, String code) {
    String two(int n) => n.toString().padLeft(2, '0');
    final lower = code.toLowerCase();
    final hasDate = lower.contains('d') || lower.contains('y') || (lower.contains('m') && !lower.contains('h'));
    final hasTime = lower.contains('h') || lower.contains('s');
    final hasSeconds = lower.contains('s');
    final date = '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}';
    final time = '${two(dt.hour)}:${two(dt.minute)}${hasSeconds ? ':${two(dt.second)}' : ''}';
    if (hasDate && hasTime) return '$date $time';
    if (hasTime) return time;
    return date;
  }
}

String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

String? _eventAttr(XmlStartElementEvent e, String local) {
  for (final a in e.attributes) {
    if (a.localName == local) return a.value;
  }
  return null;
}

const Map<int, String> _builtinFormats = {
  0: 'General',
  1: '0',
  2: '0.00',
  3: '#,##0',
  4: '#,##0.00',
  9: '0%',
  10: '0.00%',
  11: '0.00E+00',
  12: '# ?/?',
  13: '# ??/??',
  14: 'yyyy-mm-dd',
  15: 'd-mmm-yy',
  16: 'd-mmm',
  17: 'mmm-yy',
  18: 'h:mm AM/PM',
  19: 'h:mm:ss AM/PM',
  20: 'h:mm',
  21: 'h:mm:ss',
  22: 'yyyy-mm-dd h:mm',
  37: '#,##0 ;(#,##0)',
  38: '#,##0 ;[Red](#,##0)',
  39: '#,##0.00;(#,##0.00)',
  40: '#,##0.00;[Red](#,##0.00)',
  45: 'mm:ss',
  46: '[h]:mm:ss',
  47: 'mmss.0',
  48: '##0.0E+0',
  49: '@',
};
