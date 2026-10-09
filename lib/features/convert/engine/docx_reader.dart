import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// Parses a .docx (Office Open XML word-processing) file into a
/// [DocStructure].
///
/// Reads the main document body only: headers, footers, comments, footnotes
/// and text boxes are ignored. Unknown elements are skipped. Throws a
/// [FormatException] when the data is not a readable .docx package.
DocStructure parseDocx(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw FormatException('Not a valid DOCX (zip) file: $e');
  }
  return _DocxReader(archive).read();
}

// --------------------------------------------------------------- helpers

String _local(XmlElement e) => e.name.local;

/// Attribute lookup by local name, independent of the namespace prefix.
String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

XmlElement? _child(XmlElement? e, String local) {
  if (e == null) return null;
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

String? _childVal(XmlElement? e, String local) {
  final c = _child(e, local);
  return c == null ? null : _attr(c, 'val');
}

/// OOXML on/off property: present without w:val means "on".
bool? _onOff(XmlElement? e) {
  if (e == null) return null;
  final v = _attr(e, 'val')?.toLowerCase();
  if (v == null) return true;
  return !(v == '0' || v == 'false' || v == 'off' || v == 'none');
}

bool? _underline(XmlElement? e) {
  if (e == null) return null;
  final v = _attr(e, 'val')?.toLowerCase();
  if (v == null) return true;
  return v != 'none' && v != '0' && v != 'false';
}

class _RunProps {
  const _RunProps({this.bold, this.italic, this.underline});
  final bool? bold;
  final bool? italic;
  final bool? underline;

  static const empty = _RunProps();

  _RunProps overlay(_RunProps o) => _RunProps(
    bold: o.bold ?? bold,
    italic: o.italic ?? italic,
    underline: o.underline ?? underline,
  );

  static _RunProps fromRPr(XmlElement? rPr) {
    if (rPr == null) return empty;
    return _RunProps(
      bold: _onOff(_child(rPr, 'b')),
      italic: _onOff(_child(rPr, 'i')),
      underline: _underline(_child(rPr, 'u')),
    );
  }
}

class _Style {
  _Style(this.id, this.type);
  final String id;
  final String type;
  String? name;
  String? basedOn;
  int? outlineLvl;
  String? numId;
  int? ilvl;
  _RunProps runProps = _RunProps.empty;
}

class _Level {
  _Level({required this.numFmt, required this.lvlText, required this.start});
  final String numFmt;
  final String lvlText;
  final int start;
}

class _AbstractNum {
  final Map<int, _Level> levels = {};
  String? numStyleLink;
}

class _Num {
  _Num(this.abstractId);
  final String abstractId;
  final Map<int, int> startOverrides = {};
  final Map<int, _Level> levelOverrides = {};
}

sealed class _Inline {}

class _TextInline extends _Inline {
  _TextInline(this.span);
  final TextSpanData span;
}

class _PageBreakInline extends _Inline {}

class _ImageInline extends _Inline {
  _ImageInline(this.block);
  final ImageBlock block;
}

class _Field {
  bool inResult = false;
  final StringBuffer instr = StringBuffer();
  String? link;
}

enum _ParaKind { paragraph, heading, list, quote, caption }

final RegExp _headingName = RegExp(
  r'^heading\s*([1-9])$',
  caseSensitive: false,
);
final RegExp _hyperlinkInstr = RegExp(
  r'HYPERLINK\s+"([^"]+)"',
  caseSensitive: false,
);
final RegExp _hyperlinkInstrBare = RegExp(
  r'HYPERLINK\s+(\S+)',
  caseSensitive: false,
);

class _DocxReader {
  _DocxReader(this.archive) {
    for (final f in archive.files) {
      if (f.isFile) _files[f.name.replaceAll('\\', '/').toLowerCase()] = f;
    }
  }

  final Archive archive;
  final Map<String, ArchiveFile> _files = {};
  final Map<String, ({String type, String target, bool external})> _rels = {};
  final Map<String, _Style> _styles = {};
  String? _defaultParaStyle;
  final Map<String, _AbstractNum> _abstractNums = {};
  final Map<String, _Num> _nums = {};
  final Map<String, List<int?>> _listCounters = {};
  final List<_Field> _fields = [];
  final List<DocBlock> _blocks = [];
  String _mainDir = 'word';

  Uint8List? _bytes(String path) {
    var key = path.replaceAll('\\', '/');
    if (key.startsWith('/')) key = key.substring(1);
    return _files[key.toLowerCase()]?.readBytes();
  }

  XmlDocument? _xml(String path) {
    final b = _bytes(path);
    if (b == null) return null;
    try {
      return XmlDocument.parse(_decodeUtf(b));
    } catch (_) {
      return null;
    }
  }

  String _decodeUtf(Uint8List b) {
    // UTF-16 parts exist in the wild (with BOM).
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      final codes = <int>[];
      for (var i = 2; i + 1 < b.length; i += 2) {
        codes.add(b[i] | (b[i + 1] << 8));
      }
      return String.fromCharCodes(codes);
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      final codes = <int>[];
      for (var i = 2; i + 1 < b.length; i += 2) {
        codes.add((b[i] << 8) | b[i + 1]);
      }
      return String.fromCharCodes(codes);
    }
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

  DocStructure read() {
    var mainPath = 'word/document.xml';
    final rootRels = _xml('_rels/.rels');
    if (rootRels != null) {
      for (final r in rootRels.rootElement.childElements) {
        final type = _attr(r, 'Type') ?? '';
        final target = _attr(r, 'Target');
        if (target != null && type.endsWith('/officeDocument')) {
          mainPath = _resolve('', target);
          break;
        }
      }
    }
    final document =
        _xml(mainPath) ??
        (mainPath == 'word/document.xml' ? null : _xml('word/document.xml'));
    if (document == null) {
      throw const FormatException(
        'DOCX package has no readable main document part',
      );
    }
    _mainDir = p.posix.dirname(mainPath);
    final relsPath = p.posix.join(
      _mainDir,
      '_rels',
      '${p.posix.basename(mainPath)}.rels',
    );

    String? stylesPath;
    String? numberingPath;
    final rels = _xml(relsPath);
    if (rels != null) {
      for (final r in rels.rootElement.childElements) {
        final id = _attr(r, 'Id');
        final type = _attr(r, 'Type') ?? '';
        final target = _attr(r, 'Target');
        if (id == null || target == null) continue;
        final external =
            (_attr(r, 'TargetMode') ?? '').toLowerCase() == 'external';
        _rels[id] = (type: type, target: target, external: external);
        if (type.endsWith('/styles')) stylesPath = _resolve(_mainDir, target);
        if (type.endsWith('/numbering')) {
          numberingPath = _resolve(_mainDir, target);
        }
      }
    }
    _parseStyles(_xml(stylesPath ?? 'word/styles.xml'));
    _parseNumbering(_xml(numberingPath ?? 'word/numbering.xml'));

    final body = document.rootElement.childElements
        .where((e) => _local(e) == 'body')
        .firstOrNull;
    if (body != null) _walkBody(body);

    return DocStructure(blocks: _blocks, title: _readTitle());
  }

  String? _readTitle() {
    final core = _xml('docProps/core.xml');
    if (core == null) return null;
    for (final e in core.rootElement.childElements) {
      if (_local(e) == 'title') {
        final t = e.innerText.trim();
        return t.isEmpty ? null : t;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- styles

  void _parseStyles(XmlDocument? doc) {
    if (doc == null) return;
    for (final s in doc.rootElement.childElements.where(
      (e) => _local(e) == 'style',
    )) {
      final id = _attr(s, 'styleId');
      if (id == null) continue;
      final style = _Style(id, _attr(s, 'type') ?? 'paragraph');
      style.name = _childVal(s, 'name');
      style.basedOn = _childVal(s, 'basedOn');
      final pPr = _child(s, 'pPr');
      final outline = int.tryParse(_childVal(pPr, 'outlineLvl') ?? '');
      style.outlineLvl = outline;
      final numPr = _child(pPr, 'numPr');
      if (numPr != null) {
        style.numId = _childVal(numPr, 'numId');
        style.ilvl = int.tryParse(_childVal(numPr, 'ilvl') ?? '');
      }
      style.runProps = _RunProps.fromRPr(_child(s, 'rPr'));
      _styles[id] = style;
      final isDefault = (_attr(s, 'default') ?? '').toLowerCase();
      if (style.type == 'paragraph' &&
          (isDefault == '1' || isDefault == 'true' || isDefault == 'on')) {
        _defaultParaStyle = id;
      }
    }
  }

  /// Style chain from [id] up through basedOn ancestors.
  List<_Style> _chain(String? id) {
    final out = <_Style>[];
    final seen = <String>{};
    var cur = id;
    while (cur != null && seen.add(cur)) {
      final s = _styles[cur];
      if (s == null) break;
      out.add(s);
      cur = s.basedOn;
    }
    return out;
  }

  int? _styleHeadingLevel(String? id) {
    if (id != null && _styles[id] == null) {
      // Style ids without a styles.xml entry: still honour conventional ids.
      final m = RegExp(
        r'^heading([1-9])$',
        caseSensitive: false,
      ).firstMatch(id);
      if (m != null) return int.parse(m.group(1)!).clamp(1, 6);
      if (id.toLowerCase() == 'title') return 1;
      return null;
    }
    for (final s in _chain(id)) {
      final name = s.name ?? '';
      var m = _headingName.firstMatch(name);
      m ??= RegExp(r'^heading([1-9])$', caseSensitive: false).firstMatch(s.id);
      if (m != null) return int.parse(m.group(1)!).clamp(1, 6);
      if (name.toLowerCase() == 'title' || s.id.toLowerCase() == 'title') {
        return 1;
      }
      final o = s.outlineLvl;
      if (o != null) return o <= 5 ? o + 1 : (o <= 8 ? 6 : null);
    }
    return null;
  }

  bool _styleMatches(String? id, bool Function(String nameOrId) test) {
    for (final s in _chain(id)) {
      if (test(s.id.toLowerCase()) || test((s.name ?? '').toLowerCase())) {
        return true;
      }
    }
    return id != null && _styles[id] == null && test(id.toLowerCase());
  }

  _RunProps _styleRunProps(String? id) {
    var props = _RunProps.empty;
    for (final s in _chain(id).reversed) {
      props = props.overlay(s.runProps);
    }
    return props;
  }

  ({String numId, int ilvl})? _styleNumPr(String? id) {
    String? numId;
    int? ilvl;
    for (final s in _chain(id)) {
      numId ??= s.numId;
      ilvl ??= s.ilvl;
    }
    if (numId == null) return null;
    return (numId: numId, ilvl: ilvl ?? 0);
  }

  // ----------------------------------------------------------- numbering

  _Level _parseLevel(XmlElement lvl) => _Level(
    numFmt: _childVal(lvl, 'numFmt') ?? 'decimal',
    lvlText: _childVal(lvl, 'lvlText') ?? '',
    start: int.tryParse(_childVal(lvl, 'start') ?? '') ?? 1,
  );

  void _parseNumbering(XmlDocument? doc) {
    if (doc == null) return;
    for (final e in doc.rootElement.childElements) {
      if (_local(e) == 'abstractNum') {
        final id = _attr(e, 'abstractNumId');
        if (id == null) continue;
        final abs = _AbstractNum();
        abs.numStyleLink = _childVal(e, 'numStyleLink');
        for (final lvl in e.childElements.where((c) => _local(c) == 'lvl')) {
          final ilvl = int.tryParse(_attr(lvl, 'ilvl') ?? '');
          if (ilvl != null) abs.levels[ilvl] = _parseLevel(lvl);
        }
        _abstractNums[id] = abs;
      } else if (_local(e) == 'num') {
        final id = _attr(e, 'numId');
        final absId = _childVal(e, 'abstractNumId');
        if (id == null || absId == null) continue;
        final num = _Num(absId);
        for (final o in e.childElements.where(
          (c) => _local(c) == 'lvlOverride',
        )) {
          final ilvl = int.tryParse(_attr(o, 'ilvl') ?? '');
          if (ilvl == null) continue;
          final start = int.tryParse(_childVal(o, 'startOverride') ?? '');
          if (start != null) num.startOverrides[ilvl] = start;
          final lvl = _child(o, 'lvl');
          if (lvl != null) num.levelOverrides[ilvl] = _parseLevel(lvl);
        }
        _nums[id] = num;
      }
    }
  }

  _AbstractNum? _abstractFor(_Num num, [int depth = 0]) {
    final abs = _abstractNums[num.abstractId];
    if (abs == null) return null;
    final link = abs.numStyleLink;
    if (link != null && abs.levels.isEmpty && depth < 4) {
      final linkedNumId = _styleNumPr(link)?.numId;
      final linked = linkedNumId == null ? null : _nums[linkedNumId];
      if (linked != null) return _abstractFor(linked, depth + 1) ?? abs;
    }
    return abs;
  }

  _Level? _level(String numId, int ilvl) {
    final num = _nums[numId];
    if (num == null) return null;
    return num.levelOverrides[ilvl] ?? _abstractFor(num)?.levels[ilvl];
  }

  /// Advances list counters and returns the rendered marker.
  String _nextMarker(String numId, int ilvl) {
    final num = _nums[numId]!;
    final key = num.startOverrides.isNotEmpty
        ? 'n$numId'
        : 'a${num.abstractId}';
    final counters = _listCounters.putIfAbsent(
      key,
      () => List<int?>.filled(9, null),
    );
    final lvl = _level(numId, ilvl);
    final start = num.startOverrides[ilvl] ?? lvl?.start ?? 1;
    counters[ilvl] = counters[ilvl] == null ? start : counters[ilvl]! + 1;
    for (var i = ilvl + 1; i < 9; i++) {
      counters[i] = null;
    }
    if (lvl == null) return '${counters[ilvl]}.';
    if (lvl.numFmt == 'bullet') return _bulletText(lvl.lvlText);
    var text = lvl.lvlText;
    if (text.isEmpty) text = '%${ilvl + 1}.';
    return text.replaceAllMapped(RegExp(r'%([1-9])'), (m) {
      final li = int.parse(m.group(1)!) - 1;
      final l = _level(numId, li);
      final n = counters[li] ?? num.startOverrides[li] ?? l?.start ?? 1;
      return _formatNumber(n, l?.numFmt ?? 'decimal');
    });
  }

  String _bulletText(String lvlText) {
    if (lvlText.isEmpty) return '•';
    final r = lvlText.runes.first;
    if (r >= 0xE000 && r <= 0xF8FF) return '•';
    if (lvlText == 'o') return '◦';
    return lvlText;
  }

  String _formatNumber(int n, String fmt) {
    switch (fmt) {
      case 'lowerLetter':
        return formatListNumber(n, ListNumberFormat.lowerLetter);
      case 'upperLetter':
        return formatListNumber(n, ListNumberFormat.upperLetter);
      case 'lowerRoman':
        return formatListNumber(n, ListNumberFormat.lowerRoman);
      case 'upperRoman':
        return formatListNumber(n, ListNumberFormat.upperRoman);
      case 'decimalZero':
        return n < 10 ? '0$n' : '$n';
      default:
        return '$n';
    }
  }

  // ---------------------------------------------------------------- body

  void _walkBody(XmlElement container) {
    for (final e in container.childElements) {
      try {
        switch (_local(e)) {
          case 'p':
            _paragraph(e);
          case 'tbl':
            final t = _table(e);
            if (t != null) _blocks.add(t);
          case 'sdt':
            final content = _child(e, 'sdtContent');
            if (content != null) _walkBody(content);
          case 'customXml' || 'ins' || 'moveTo':
            _walkBody(e);
          case 'AlternateContent':
            final choice = _child(e, 'Choice') ?? _child(e, 'Fallback');
            if (choice != null) _walkBody(choice);
          default:
            break;
        }
      } catch (_) {
        // Skip malformed elements instead of failing the whole import.
      }
    }
  }

  void _paragraph(XmlElement para) {
    final pPr = _child(para, 'pPr');
    final styleId = _childVal(pPr, 'pStyle') ?? _defaultParaStyle;

    int? headingLevel;
    final directOutline = int.tryParse(_childVal(pPr, 'outlineLvl') ?? '');
    if (directOutline != null) {
      headingLevel = directOutline <= 5 ? directOutline + 1 : null;
    } else {
      headingLevel = _styleHeadingLevel(styleId);
    }

    ({String numId, int ilvl})? numPr;
    final directNumPr = _child(pPr, 'numPr');
    if (directNumPr != null) {
      final numId =
          _childVal(directNumPr, 'numId') ?? _styleNumPr(styleId)?.numId;
      final ilvl =
          int.tryParse(_childVal(directNumPr, 'ilvl') ?? '') ??
          _styleNumPr(styleId)?.ilvl ??
          0;
      if (numId != null) numPr = (numId: numId, ilvl: ilvl.clamp(0, 8));
    } else {
      numPr = _styleNumPr(styleId);
    }
    if (numPr != null &&
        (numPr.numId == '0' || !_nums.containsKey(numPr.numId))) {
      numPr = null;
    }
    _Level? listLevel;
    if (numPr != null) {
      listLevel = _level(numPr.numId, numPr.ilvl);
      if (listLevel != null && listLevel.numFmt == 'none') numPr = null;
    }

    _ParaKind kind;
    if (headingLevel != null) {
      kind = _ParaKind.heading;
    } else if (numPr != null) {
      kind = _ParaKind.list;
    } else if (_styleMatches(
      styleId,
      (s) => s == 'quote' || s == 'intense quote' || s == 'intensequote',
    )) {
      kind = _ParaKind.quote;
    } else if (_styleMatches(styleId, (s) => s == 'caption')) {
      kind = _ParaKind.caption;
    } else {
      kind = _ParaKind.paragraph;
    }

    if (_onOff(_child(pPr, 'pageBreakBefore')) == true) _addPageBreak();

    // Heading formatting comes from the heading style itself; only direct
    // formatting is meaningful for span styles there.
    final base = kind == _ParaKind.heading
        ? _RunProps.empty
        : _styleRunProps(styleId);
    final inlines = <_Inline>[];
    _walkInline(para, base, null, inlines);

    var first = true;
    var buffer = <TextSpanData>[];
    void flush() {
      final spans = _trimSpans(mergeSpans(buffer));
      buffer = [];
      if (spans.isEmpty) return;
      final k = first
          ? kind
          : (kind == _ParaKind.quote ? kind : _ParaKind.paragraph);
      first = false;
      switch (k) {
        case _ParaKind.heading:
          _blocks.add(HeadingBlock(level: headingLevel!, spans: spans));
        case _ParaKind.list:
          final ordered = listLevel != null && listLevel.numFmt != 'bullet';
          _blocks.add(
            ListItemBlock(
              spans: spans,
              ordered: ordered,
              marker: _nextMarker(numPr!.numId, numPr.ilvl),
              indent: numPr.ilvl,
            ),
          );
        case _ParaKind.quote:
          _blocks.add(QuoteBlock(spans: spans));
        case _ParaKind.caption:
          final last = _blocks.isEmpty ? null : _blocks.last;
          if (last is ImageBlock && last.caption == null) {
            _blocks[_blocks.length - 1] = ImageBlock(
              bytes: last.bytes,
              width: last.width,
              height: last.height,
              caption: spansToText(spans),
            );
          } else {
            _blocks.add(ParagraphBlock(spans: spans));
          }
        case _ParaKind.paragraph:
          _blocks.add(ParagraphBlock(spans: spans));
      }
    }

    for (final inline in inlines) {
      switch (inline) {
        case _TextInline():
          buffer.add(inline.span);
        case _PageBreakInline():
          flush();
          _addPageBreak();
        case _ImageInline():
          flush();
          _blocks.add(inline.block);
      }
    }
    flush();
  }

  void _addPageBreak() {
    if (_blocks.isEmpty || _blocks.last is PageBreakBlock) return;
    _blocks.add(const PageBreakBlock());
  }

  List<TextSpanData> _trimSpans(List<TextSpanData> spans) {
    final out = List<TextSpanData>.of(spans);
    while (out.isNotEmpty) {
      final t = out.first.text.replaceFirst(RegExp(r'^\s+'), '');
      if (t.isEmpty) {
        out.removeAt(0);
      } else {
        out[0] = out.first.copyWith(text: t);
        break;
      }
    }
    while (out.isNotEmpty) {
      final t = out.last.text.replaceFirst(RegExp(r'\s+$'), '');
      if (t.isEmpty) {
        out.removeLast();
      } else {
        out[out.length - 1] = out.last.copyWith(text: t);
        break;
      }
    }
    return out;
  }

  /// Walks paragraph-level content (runs, hyperlinks, fields, ...).
  void _walkInline(
    XmlElement parent,
    _RunProps base,
    String? link,
    List<_Inline> out,
  ) {
    for (final e in parent.childElements) {
      switch (_local(e)) {
        case 'r':
          _run(e, base, link, out);
        case 'hyperlink':
          String? target;
          final rid = _attr(e, 'id');
          if (rid != null) {
            final rel = _rels[rid];
            if (rel != null) target = rel.target;
          }
          _walkInline(e, base, target ?? link, out);
        case 'fldSimple':
          final instr = _attr(e, 'instr') ?? '';
          _walkInline(e, base, _fieldLink(instr) ?? link, out);
        case 'sdt':
          final content = _child(e, 'sdtContent');
          if (content != null) _walkInline(content, base, link, out);
        case 'ins' || 'moveTo' || 'smartTag' || 'customXml' || 'dir' || 'bdo':
          _walkInline(e, base, link, out);
        case 'AlternateContent':
          final choice = _child(e, 'Choice') ?? _child(e, 'Fallback');
          if (choice != null) _walkInline(choice, base, link, out);
        case 'oMath' || 'oMathPara':
          final text = e.descendantElements
              .where((d) => _local(d) == 't')
              .map((d) => d.innerText)
              .join();
          if (text.isNotEmpty) out.add(_TextInline(_span(text, base, link)));
        default:
          break; // pPr, bookmarks, proofErr, del, moveFrom, comments, ...
      }
    }
  }

  String? _fieldLink(String instr) {
    final m =
        _hyperlinkInstr.firstMatch(instr) ??
        _hyperlinkInstrBare.firstMatch(instr);
    if (m == null) return null;
    final url = m.group(1)!;
    if (url.startsWith(r'\')) return null; // switch, e.g. \l (local anchor)
    return url;
  }

  String? get _activeFieldLink {
    for (final f in _fields.reversed) {
      if (f.link != null) return f.link;
    }
    return null;
  }

  bool get _inFieldInstruction => _fields.isNotEmpty && !_fields.last.inResult;

  TextSpanData _span(String text, _RunProps props, String? link) =>
      TextSpanData(
        text,
        bold: props.bold ?? false,
        italic: props.italic ?? false,
        underline: props.underline ?? false,
        link: link,
      );

  void _run(XmlElement r, _RunProps base, String? link, List<_Inline> out) {
    final rPr = _child(r, 'rPr');
    final effectiveLink = link ?? _activeFieldLink;
    var charProps = _styleRunProps(_childVal(rPr, 'rStyle'));
    if (effectiveLink != null) {
      // Links are conventionally underlined by the Hyperlink character style;
      // that is presentation, not an underline span.
      charProps = _RunProps(bold: charProps.bold, italic: charProps.italic);
    }
    final props = base.overlay(charProps).overlay(_RunProps.fromRPr(rPr));

    final text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      if (!_inFieldInstruction) {
        out.add(_TextInline(_span(text.toString(), props, effectiveLink)));
      }
      text.clear();
    }

    void handle(XmlElement c) {
      switch (_local(c)) {
        case 't':
          text.write(c.innerText);
        case 'tab' || 'ptab':
          text.write('\t');
        case 'br':
          final type = _attr(c, 'type');
          if (type == 'page') {
            flushText();
            if (!_inFieldInstruction) out.add(_PageBreakInline());
          } else {
            text.write('\n');
          }
        case 'cr':
          text.write('\n');
        case 'noBreakHyphen':
          text.write('-');
        case 'sym':
          final code = int.tryParse(_attr(c, 'char') ?? '', radix: 16);
          if (code != null) {
            var cp = code;
            if (cp >= 0xF000 && cp <= 0xF0FF) cp -= 0xF000;
            if (cp >= 0x20) text.writeCharCode(cp);
          }
        case 'fldChar':
          flushText();
          final type = _attr(c, 'fldCharType');
          if (type == 'begin') {
            _fields.add(_Field());
          } else if (type == 'separate' && _fields.isNotEmpty) {
            final f = _fields.last;
            f.inResult = true;
            f.link = _fieldLink(f.instr.toString());
          } else if (type == 'end' && _fields.isNotEmpty) {
            _fields.removeLast();
          }
        case 'instrText':
          if (_fields.isNotEmpty) _fields.last.instr.write(c.innerText);
        case 'drawing':
          flushText();
          final img = _drawingImage(c);
          if (img != null && !_inFieldInstruction) out.add(_ImageInline(img));
        case 'pict' || 'object':
          flushText();
          final img = _vmlImage(c);
          if (img != null && !_inFieldInstruction) out.add(_ImageInline(img));
        case 'AlternateContent':
          final choice = _child(c, 'Choice');
          final fallback = _child(c, 'Fallback');
          final before = out.length;
          final textBefore = text.length;
          if (choice != null) choice.childElements.forEach(handle);
          if (out.length == before &&
              text.length == textBefore &&
              fallback != null) {
            fallback.childElements.forEach(handle);
          }
        default:
          break; // rPr, delText, lastRenderedPageBreak, footnoteReference, ...
      }
    }

    r.childElements.forEach(handle);
    flushText();
  }

  ImageBlock? _imageFromRel(String? relId, int? cx, int? cy) {
    if (relId == null) return null;
    final rel = _rels[relId];
    if (rel == null || rel.external) return null;
    final raw = _bytes(_resolve(_mainDir, rel.target));
    if (raw == null) return null;
    final bytes = normalizeToPngOrJpeg(raw);
    if (bytes == null) return null;
    var w = cx ?? 0;
    var h = cy ?? 0;
    if (w <= 0 || h <= 0) {
      final size = readImageSize(bytes);
      if (size == null) return null;
      w = size.width;
      h = size.height;
    }
    return ImageBlock(bytes: bytes, width: w, height: h);
  }

  ImageBlock? _drawingImage(XmlElement drawing) {
    XmlElement? blip;
    XmlElement? extent;
    for (final d in drawing.descendantElements) {
      final n = _local(d);
      if (n == 'blip' && blip == null) blip = d;
      if (n == 'extent' && extent == null) extent = d;
    }
    if (blip == null) return null;
    int? px(String? emu) {
      final v = int.tryParse(emu ?? '');
      return v == null ? null : (v / 9525).round();
    }

    final cx = extent == null ? null : px(_attr(extent, 'cx'));
    final cy = extent == null ? null : px(_attr(extent, 'cy'));
    return _imageFromRel(_attr(blip, 'embed'), cx, cy);
  }

  ImageBlock? _vmlImage(XmlElement pict) {
    XmlElement? imageData;
    XmlElement? shape;
    for (final d in pict.descendantElements) {
      if (_local(d) == 'imagedata' && imageData == null) imageData = d;
      if (_local(d) == 'shape' && shape == null) shape = d;
    }
    if (imageData == null) return null;
    int? w;
    int? h;
    final style = shape == null ? null : _attr(shape, 'style');
    if (style != null) {
      double? dim(String key) {
        final m = RegExp(
          '(?:^|;)\\s*$key\\s*:\\s*([0-9.]+)\\s*(pt|px|in|cm|mm)?',
          caseSensitive: false,
        ).firstMatch(style);
        if (m == null) return null;
        final v = double.tryParse(m.group(1)!);
        if (v == null) return null;
        switch ((m.group(2) ?? 'px').toLowerCase()) {
          case 'pt':
            return v * 96 / 72;
          case 'in':
            return v * 96;
          case 'cm':
            return v * 96 / 2.54;
          case 'mm':
            return v * 96 / 25.4;
          default:
            return v;
        }
      }

      w = dim('width')?.round();
      h = dim('height')?.round();
    }
    return _imageFromRel(_attr(imageData, 'id'), w, h);
  }

  // -------------------------------------------------------------- tables

  Iterable<XmlElement> _flatChildren(XmlElement e, String local) sync* {
    for (final c in e.childElements) {
      final n = _local(c);
      if (n == local) {
        yield c;
      } else if (n == 'sdt') {
        final content = _child(c, 'sdtContent');
        if (content != null) yield* _flatChildren(content, local);
      } else if (n == 'customXml' || n == 'ins' || n == 'moveTo') {
        yield* _flatChildren(c, local);
      }
    }
  }

  TableBlock? _table(XmlElement tbl) {
    final rows = <List<String>>[];
    var header = false;
    var firstRowBold = true;
    var firstRowHasText = false;
    for (final tr in _flatChildren(tbl, 'tr')) {
      final trPr = _child(tr, 'trPr');
      final cells = <String>[];
      final before = int.tryParse(_childVal(trPr, 'gridBefore') ?? '') ?? 0;
      for (var i = 0; i < before; i++) {
        cells.add('');
      }
      final isFirst = rows.isEmpty;
      for (final tc in _flatChildren(tr, 'tc')) {
        final span =
            int.tryParse(_childVal(_child(tc, 'tcPr'), 'gridSpan') ?? '') ?? 1;
        final inlines = <TextSpanData>[];
        cells.add(_cellText(tc, inlines));
        if (isFirst) {
          for (final s in inlines) {
            if (s.text.trim().isEmpty) continue;
            firstRowHasText = true;
            if (!s.bold) firstRowBold = false;
          }
        }
        for (var i = 1; i < span; i++) {
          cells.add('');
        }
      }
      final after = int.tryParse(_childVal(trPr, 'gridAfter') ?? '') ?? 0;
      for (var i = 0; i < after; i++) {
        cells.add('');
      }
      if (isFirst) header = _onOff(_child(trPr, 'tblHeader')) == true;
      rows.add(cells);
    }
    if (rows.isEmpty) return null;
    final width = rows
        .map((r) => r.length)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (width == 0) return null;
    for (final r in rows) {
      while (r.length < width) {
        r.add('');
      }
    }
    if (!header && rows.length > 1 && firstRowHasText && firstRowBold) {
      header = true;
    }
    return TableBlock(rows: rows, hasHeader: header);
  }

  String _cellText(XmlElement tc, List<TextSpanData> spansOut) {
    final parts = <String>[];
    for (final c in tc.childElements) {
      final n = _local(c);
      if (n == 'p') {
        final pPr = _child(c, 'pPr');
        final styleId = _childVal(pPr, 'pStyle') ?? _defaultParaStyle;
        final inlines = <_Inline>[];
        _walkInline(c, _styleRunProps(styleId), null, inlines);
        final spans = inlines
            .whereType<_TextInline>()
            .map((i) => i.span)
            .toList();
        spansOut.addAll(spans);
        parts.add(spansToText(spans).trimRight());
      } else if (n == 'tbl') {
        final nested = _table(c);
        if (nested != null) {
          parts.add(nested.rows.map((r) => r.join('\t')).join('\n'));
        }
      } else if (n == 'sdt') {
        final content = _child(c, 'sdtContent');
        if (content != null) parts.add(_cellText(content, spansOut));
      }
    }
    // Drop trailing empty paragraphs (Word cells always end with one).
    while (parts.isNotEmpty && parts.last.isEmpty) {
      parts.removeLast();
    }
    return parts.join('\n');
  }
}
