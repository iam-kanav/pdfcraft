import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:pdfcraft/core/models/doc_structure.dart';

import 'convert_utils.dart';

/// Builds an Office Open XML word-processing document (.docx) from [doc].
///
/// The output opens in Microsoft Word, LibreOffice and Google Docs. Page
/// setup is A4 portrait with 1 inch margins.
Uint8List buildDocx(DocStructure doc, {String? title, String? author}) {
  return _DocxWriter(doc, title: title ?? doc.title, author: author).build();
}

// Page geometry in twips (1/20 pt). A4 = 210 x 297 mm.
const int _pageWidthTw = 11906;
const int _pageHeightTw = 16838;
const int _marginTw = 1440;
const int _textWidthTw = _pageWidthTw - 2 * _marginTw;
const int _textHeightTw = _pageHeightTw - 2 * _marginTw;

// English Metric Units: 914400 per inch, 1440 twips per inch, 96 px per inch.
const int _emuPerTwip = 635;
const int _emuPerPixel = 9525;
const int _maxImageWidthEmu = _textWidthTw * _emuPerTwip;
// Leave room for a caption line below images that fill a whole page.
const int _maxImageHeightEmu = (_textHeightTw - 720) * _emuPerTwip;

const String _nsW =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const String _nsR =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const String _nsWp =
    'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const String _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const String _nsPic =
    'http://schemas.openxmlformats.org/drawingml/2006/picture';
const String _relBase =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

const String _xmlDecl =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

/// Numbering ids: abstract 0 = bullets, abstract 1 = ordered.
const int _bulletAbstractId = 0;
const int _orderedAbstractId = 1;
const int _bulletNumId = 1;

class _Rel {
  _Rel(this.id, this.type, this.target, {this.external = false});
  final String id;
  final String type;
  final String target;
  final bool external;
}

class _Media {
  _Media(this.path, this.bytes, this.ext);
  final String path;
  final Uint8List bytes;
  final String ext;
}

class _DocxWriter {
  _DocxWriter(this.doc, {this.title, this.author});

  final DocStructure doc;
  final String? title;
  final String? author;

  final List<_Rel> _rels = [];
  final List<_Media> _media = [];
  final Map<String, String> _hyperlinkRelIds = {};
  int _nextRelId = 1;
  int _drawingId = 1;

  /// Extra w:num ids for ordered lists that restart numbering at 1.
  final List<int> _orderedNumIds = [];
  int _nextNumId = 2;

  String _addRel(String type, String target, {bool external = false}) {
    final id = 'rId${_nextRelId++}';
    _rels.add(_Rel(id, type, target, external: external));
    return id;
  }

  Uint8List build() {
    _addRel('$_relBase/styles', 'styles.xml');
    _addRel('$_relBase/numbering', 'numbering.xml');
    _addRel('$_relBase/settings', 'settings.xml');
    _addRel('$_relBase/fontTable', 'fontTable.xml');

    final body = _buildBody();
    final documentXml =
        '$_xmlDecl<w:document xmlns:w="$_nsW" xmlns:r="$_nsR" xmlns:wp="$_nsWp" '
        'xmlns:a="$_nsA" xmlns:pic="$_nsPic"><w:body>$body'
        '<w:sectPr><w:pgSz w:w="$_pageWidthTw" w:h="$_pageHeightTw"/>'
        '<w:pgMar w:top="$_marginTw" w:right="$_marginTw" w:bottom="$_marginTw" w:left="$_marginTw" '
        'w:header="708" w:footer="708" w:gutter="0"/><w:cols w:space="708"/><w:docGrid w:linePitch="360"/>'
        '</w:sectPr></w:body></w:document>';

    final archive = Archive();
    void add(String name, String content) =>
        archive.addFile(ArchiveFile.string(name, content));

    add('[Content_Types].xml', _contentTypes());
    add('_rels/.rels', _rootRels());
    add('docProps/core.xml', _coreXml());
    add('docProps/app.xml', _appXml());
    add('word/document.xml', documentXml);
    add('word/styles.xml', _stylesXml);
    add('word/numbering.xml', _numberingXml());
    add('word/settings.xml', _settingsXml);
    add('word/fontTable.xml', _fontTableXml);
    add('word/_rels/document.xml.rels', _documentRels());
    for (final m in _media) {
      archive.addFile(ArchiveFile.bytes('word/${m.path}', m.bytes));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  // ---------------------------------------------------------------- body

  String _buildBody() {
    final sb = StringBuffer();
    // Ordered list numbering state: nesting level -> w:numId.
    final orderedNums = <int, int>{};
    DocBlock? previous;

    for (final block in doc.blocks) {
      if (block is! ListItemBlock) orderedNums.clear();
      // Word merges directly adjacent tables; separate them with an empty
      // paragraph.
      if (block is TableBlock && previous is TableBlock) sb.write('<w:p/>');

      switch (block) {
        case HeadingBlock():
          final level = block.level.clamp(1, 6);
          sb.write(_paragraph(block.spans, style: 'Heading$level'));
        case ParagraphBlock():
          sb.write(_paragraph(block.spans));
        case QuoteBlock():
          sb.write(_paragraph(block.spans, style: 'Quote'));
        case ListItemBlock():
          final level = block.indent.clamp(0, 8);
          orderedNums.removeWhere((k, _) => k > level);
          int numId;
          if (block.ordered) {
            numId = orderedNums[level] ?? _newOrderedNum();
            orderedNums[level] = numId;
          } else {
            orderedNums.remove(level);
            numId = _bulletNumId;
          }
          sb.write(
            _paragraph(
              block.spans,
              style: 'ListParagraph',
              numPr:
                  '<w:numPr><w:ilvl w:val="$level"/><w:numId w:val="$numId"/></w:numPr>',
            ),
          );
        case ImageBlock():
          sb.write(_image(block));
        case TableBlock():
          sb.write(_table(block));
        case PageBreakBlock():
          sb.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      }
      previous = block;
    }
    // A table must not be the last body element before sectPr in Word.
    if (previous is TableBlock || previous == null) sb.write('<w:p/>');
    return sb.toString();
  }

  int _newOrderedNum() {
    final id = _nextNumId++;
    _orderedNumIds.add(id);
    return id;
  }

  String _paragraph(List<TextSpanData> spans, {String? style, String? numPr}) {
    final sb = StringBuffer('<w:p>');
    if (style != null || numPr != null) {
      sb.write('<w:pPr>');
      if (style != null) sb.write('<w:pStyle w:val="$style"/>');
      if (numPr != null) sb.write(numPr);
      sb.write('</w:pPr>');
    }
    sb.write(_runs(spans));
    sb.write('</w:p>');
    return sb.toString();
  }

  String _runs(List<TextSpanData> spans, {bool forceBold = false}) {
    final sb = StringBuffer();
    for (final span in mergeSpans(spans)) {
      final link = span.link;
      if (link != null && link.isNotEmpty) {
        final relId = _hyperlinkRelIds.putIfAbsent(
          link,
          () => _addRel('$_relBase/hyperlink', link, external: true),
        );
        sb.write('<w:hyperlink r:id="$relId" w:history="1">');
        sb.write(_run(span, hyperlink: true, forceBold: forceBold));
        sb.write('</w:hyperlink>');
      } else {
        sb.write(_run(span, forceBold: forceBold));
      }
    }
    return sb.toString();
  }

  String _run(
    TextSpanData span, {
    bool hyperlink = false,
    bool forceBold = false,
  }) {
    final rPr = StringBuffer();
    if (hyperlink) rPr.write('<w:rStyle w:val="Hyperlink"/>');
    if (span.bold || forceBold) rPr.write('<w:b/><w:bCs/>');
    if (span.italic) rPr.write('<w:i/><w:iCs/>');
    if (span.underline) rPr.write('<w:u w:val="single"/>');
    final sb = StringBuffer('<w:r>');
    if (rPr.isNotEmpty) sb.write('<w:rPr>$rPr</w:rPr>');
    sb.write(_runContent(span.text));
    sb.write('</w:r>');
    return sb.toString();
  }

  /// Text with tabs and line breaks converted to w:tab / w:br elements.
  String _runContent(String text) {
    final sb = StringBuffer();
    final buf = StringBuffer();
    void flush() {
      if (buf.isEmpty) return;
      sb.write('<w:t xml:space="preserve">${xmlEscape(buf.toString())}</w:t>');
      buf.clear();
    }

    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (var i = 0; i < normalized.length; i++) {
      final c = normalized[i];
      if (c == '\n') {
        flush();
        sb.write('<w:br/>');
      } else if (c == '\t') {
        flush();
        sb.write('<w:tab/>');
      } else {
        buf.write(c);
      }
    }
    flush();
    return sb.toString();
  }

  String _image(ImageBlock block) {
    final bytes = normalizeToPngOrJpeg(block.bytes);
    if (bytes == null) {
      final caption = block.caption;
      return caption == null || caption.isEmpty
          ? ''
          : _paragraph([TextSpanData(caption)], style: 'Caption');
    }
    final kind = detectImageKind(bytes);
    final ext = kind == ImageKind.jpeg ? 'jpeg' : 'png';
    final index = _media.length + 1;
    final path = 'media/image$index.$ext';
    _media.add(_Media(path, bytes, ext));
    final relId = _addRel('$_relBase/image', path);

    var pxW = block.width;
    var pxH = block.height;
    if (pxW <= 0 || pxH <= 0) {
      final size = readImageSize(bytes);
      pxW = size?.width ?? 300;
      pxH = size?.height ?? 200;
    }
    var cx = pxW * _emuPerPixel;
    var cy = pxH * _emuPerPixel;
    if (cx > _maxImageWidthEmu) {
      cy = (cy * _maxImageWidthEmu / cx).round();
      cx = _maxImageWidthEmu;
    }
    if (cy > _maxImageHeightEmu) {
      cx = (cx * _maxImageHeightEmu / cy).round();
      cy = _maxImageHeightEmu;
    }
    if (cx < 1) cx = 1;
    if (cy < 1) cy = 1;

    final id = _drawingId++;
    final descr = xmlEscape(block.caption ?? '');
    final sb = StringBuffer(
      '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>',
    );
    sb.write('<wp:inline distT="0" distB="0" distL="0" distR="0">');
    sb.write('<wp:extent cx="$cx" cy="$cy"/>');
    sb.write('<wp:effectExtent l="0" t="0" r="0" b="0"/>');
    sb.write('<wp:docPr id="$id" name="Picture $id" descr="$descr"/>');
    sb.write(
      '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>',
    );
    sb.write('<a:graphic><a:graphicData uri="$_nsPic"><pic:pic>');
    sb.write(
      '<pic:nvPicPr><pic:cNvPr id="$id" name="image$index.$ext" descr="$descr"/><pic:cNvPicPr/></pic:nvPicPr>',
    );
    sb.write(
      '<pic:blipFill><a:blip r:embed="$relId"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>',
    );
    sb.write(
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>',
    );
    sb.write('<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>');
    sb.write(
      '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>',
    );
    final caption = block.caption;
    if (caption != null && caption.isNotEmpty) {
      sb.write(_paragraph([TextSpanData(caption)], style: 'Caption'));
    }
    return sb.toString();
  }

  String _table(TableBlock table) {
    final rows = table.rows.where((r) => r.isNotEmpty).toList();
    if (rows.isEmpty) return '';
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final colWidth = (_textWidthTw / cols).floor();
    const border = 'w:val="single" w:sz="4" w:space="0" w:color="808080"';

    final sb = StringBuffer('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/>');
    sb.write('<w:tblW w:w="${colWidth * cols}" w:type="dxa"/>');
    sb.write(
      '<w:tblBorders><w:top $border/><w:left $border/><w:bottom $border/><w:right $border/>'
      '<w:insideH $border/><w:insideV $border/></w:tblBorders>',
    );
    sb.write('<w:tblLayout w:type="fixed"/>');
    sb.write(
      '<w:tblLook w:val="04A0" w:firstRow="${table.hasHeader ? 1 : 0}" w:lastRow="0" '
      'w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>',
    );
    sb.write('</w:tblPr><w:tblGrid>');
    for (var c = 0; c < cols; c++) {
      sb.write('<w:gridCol w:w="$colWidth"/>');
    }
    sb.write('</w:tblGrid>');

    for (var r = 0; r < rows.length; r++) {
      final header = table.hasHeader && r == 0;
      sb.write('<w:tr>');
      if (header) sb.write('<w:trPr><w:tblHeader/></w:trPr>');
      for (var c = 0; c < cols; c++) {
        final text = c < rows[r].length ? rows[r][c] : '';
        sb.write('<w:tc><w:tcPr><w:tcW w:w="$colWidth" w:type="dxa"/>');
        if (header) {
          sb.write('<w:shd w:val="clear" w:color="auto" w:fill="E7E6E6"/>');
        }
        sb.write('</w:tcPr>');
        // One paragraph per line of cell text; a cell needs at least one.
        for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
          sb.write('<w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>');
          if (line.isNotEmpty) {
            sb.write(_run(TextSpanData(line, bold: header)));
          }
          sb.write('</w:p>');
        }
        sb.write('</w:tc>');
      }
      sb.write('</w:tr>');
    }
    sb.write('</w:tbl>');
    return sb.toString();
  }

  // ------------------------------------------------------------- parts

  String _contentTypes() {
    final exts = _media.map((m) => m.ext).toSet();
    final sb = StringBuffer(_xmlDecl);
    sb.write(
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    );
    sb.write(
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    );
    sb.write('<Default Extension="xml" ContentType="application/xml"/>');
    if (exts.contains('png')) {
      sb.write('<Default Extension="png" ContentType="image/png"/>');
    }
    if (exts.contains('jpeg')) {
      sb.write('<Default Extension="jpeg" ContentType="image/jpeg"/>');
    }
    const wml =
        'application/vnd.openxmlformats-officedocument.wordprocessingml';
    sb.write(
      '<Override PartName="/word/document.xml" ContentType="$wml.document.main+xml"/>',
    );
    sb.write(
      '<Override PartName="/word/styles.xml" ContentType="$wml.styles+xml"/>',
    );
    sb.write(
      '<Override PartName="/word/numbering.xml" ContentType="$wml.numbering+xml"/>',
    );
    sb.write(
      '<Override PartName="/word/settings.xml" ContentType="$wml.settings+xml"/>',
    );
    sb.write(
      '<Override PartName="/word/fontTable.xml" ContentType="$wml.fontTable+xml"/>',
    );
    sb.write(
      '<Override PartName="/docProps/core.xml" '
      'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
    );
    sb.write(
      '<Override PartName="/docProps/app.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
    );
    sb.write('</Types>');
    return sb.toString();
  }

  String _rootRels() =>
      '$_xmlDecl<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="$_relBase/officeDocument" Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
      'Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" Type="$_relBase/extended-properties" Target="docProps/app.xml"/>'
      '</Relationships>';

  String _documentRels() {
    final sb = StringBuffer(_xmlDecl);
    sb.write(
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    );
    for (final r in _rels) {
      sb.write(
        '<Relationship Id="${r.id}" Type="${r.type}" Target="${xmlEscape(r.target)}"',
      );
      if (r.external) sb.write(' TargetMode="External"');
      sb.write('/>');
    }
    sb.write('</Relationships>');
    return sb.toString();
  }

  String _coreXml() {
    final now = DateTime.now().toUtc();
    final stamp = '${now.toIso8601String().split('.').first}Z';
    final sb = StringBuffer(_xmlDecl);
    sb.write(
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );
    if (title != null && title!.isNotEmpty) {
      sb.write('<dc:title>${xmlEscape(title!)}</dc:title>');
    }
    if (author != null && author!.isNotEmpty) {
      sb.write('<dc:creator>${xmlEscape(author!)}</dc:creator>');
      sb.write('<cp:lastModifiedBy>${xmlEscape(author!)}</cp:lastModifiedBy>');
    }
    sb.write(
      '<dcterms:created xsi:type="dcterms:W3CDTF">$stamp</dcterms:created>',
    );
    sb.write(
      '<dcterms:modified xsi:type="dcterms:W3CDTF">$stamp</dcterms:modified>',
    );
    sb.write('</cp:coreProperties>');
    return sb.toString();
  }

  String _appXml() =>
      '$_xmlDecl<Properties '
      'xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
      '<Application>PDFCraft</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>'
      '<LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc>'
      '<HyperlinksChanged>false</HyperlinksChanged><AppVersion>1.0000</AppVersion></Properties>';

  String _numberingXml() {
    final sb = StringBuffer(_xmlDecl);
    sb.write('<w:numbering xmlns:w="$_nsW">');

    // Bullets.
    sb.write(
      '<w:abstractNum w:abstractNumId="$_bulletAbstractId"><w:multiLevelType w:val="hybridMultilevel"/>',
    );
    // Plain Unicode bullets in common fonts (Symbol/Wingdings private-use
    // glyphs are not portable across Word, LibreOffice and Google Docs).
    const bullets = ['•', 'o', '▪'];
    const bulletFonts = ['Arial', 'Courier New', 'Arial'];
    for (var l = 0; l < 9; l++) {
      final glyph = bullets[l % 3];
      final font = bulletFonts[l % 3];
      sb.write(
        '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
        '<w:lvlText w:val="$glyph"/><w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="${720 * (l + 1)}" w:hanging="360"/></w:pPr>'
        '<w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:cs="$font" w:hint="default"/></w:rPr></w:lvl>',
      );
    }
    sb.write('</w:abstractNum>');

    // Ordered: decimal, lowerLetter, lowerRoman repeating.
    sb.write(
      '<w:abstractNum w:abstractNumId="$_orderedAbstractId"><w:multiLevelType w:val="hybridMultilevel"/>',
    );
    const fmts = ['decimal', 'lowerLetter', 'lowerRoman'];
    for (var l = 0; l < 9; l++) {
      final fmt = fmts[l % 3];
      sb.write(
        '<w:lvl w:ilvl="$l"><w:start w:val="1"/><w:numFmt w:val="$fmt"/>'
        '<w:lvlText w:val="%${l + 1}."/><w:lvlJc w:val="${fmt == 'lowerRoman' ? 'right' : 'left'}"/>'
        '<w:pPr><w:ind w:left="${720 * (l + 1)}" w:hanging="360"/></w:pPr></w:lvl>',
      );
    }
    sb.write('</w:abstractNum>');

    sb.write(
      '<w:num w:numId="$_bulletNumId"><w:abstractNumId w:val="$_bulletAbstractId"/></w:num>',
    );
    for (final id in _orderedNumIds) {
      sb.write(
        '<w:num w:numId="$id"><w:abstractNumId w:val="$_orderedAbstractId"/>',
      );
      for (var l = 0; l < 9; l++) {
        sb.write(
          '<w:lvlOverride w:ilvl="$l"><w:startOverride w:val="1"/></w:lvlOverride>',
        );
      }
      sb.write('</w:num>');
    }
    sb.write('</w:numbering>');
    return sb.toString();
  }
}

String _headingStyle(int level) {
  const sizes = [32, 28, 26, 24, 22, 22];
  const colors = ['1F3864', '2F5496', '2F5496', '2F5496', '2F5496', '1F3763'];
  final italic = level >= 4 ? '<w:i/><w:iCs/>' : '';
  return '<w:style w:type="paragraph" w:styleId="Heading$level"><w:name w:val="heading $level"/>'
      '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/>'
      '${level > 1 ? '<w:unhideWhenUsed/>' : ''}<w:qFormat/>'
      '<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="${level == 1 ? 360 : 240}" w:after="120"/>'
      '<w:outlineLvl w:val="${level - 1}"/></w:pPr>'
      '<w:rPr><w:b/><w:bCs/>$italic<w:color w:val="${colors[level - 1]}"/>'
      '<w:sz w:val="${sizes[level - 1]}"/><w:szCs w:val="${sizes[level - 1]}"/></w:rPr></w:style>';
}

final String _stylesXml = () {
  const font =
      '<w:rFonts w:ascii="Calibri" w:eastAsia="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>';
  final sb = StringBuffer(_xmlDecl);
  sb.write('<w:styles xmlns:w="$_nsW">');
  sb.write(
    '<w:docDefaults><w:rPrDefault><w:rPr>$font<w:sz w:val="22"/><w:szCs w:val="22"/>'
    '<w:lang w:val="en-US" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
    '</w:docDefaults>',
  );
  sb.write(
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>',
  );
  sb.write(
    '<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">'
    '<w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>',
  );
  sb.write(
    '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
    '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>'
    '<w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>'
    '<w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>',
  );
  sb.write(
    '<w:style w:type="numbering" w:default="1" w:styleId="NoList"><w:name w:val="No List"/>'
    '<w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/></w:style>',
  );
  sb.write(
    '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
    '<w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/>'
    '<w:pPr><w:spacing w:after="240" w:line="240" w:lineRule="auto"/><w:contextualSpacing/></w:pPr>'
    '<w:rPr><w:spacing w:val="-10"/><w:kern w:val="28"/><w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr></w:style>',
  );
  for (var l = 1; l <= 6; l++) {
    sb.write(_headingStyle(l));
  }
  sb.write(
    '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>'
    '<w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>'
    '<w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>',
  );
  sb.write(
    '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>'
    '<w:next w:val="Normal"/><w:uiPriority w:val="29"/><w:qFormat/>'
    '<w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="A5A5A5"/></w:pBdr>'
    '<w:spacing w:before="120" w:after="120"/><w:ind w:left="567" w:right="567"/></w:pPr>'
    '<w:rPr><w:color w:val="404040"/></w:rPr></w:style>',
  );
  sb.write(
    '<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/>'
    '<w:next w:val="Normal"/><w:uiPriority w:val="35"/><w:unhideWhenUsed/><w:qFormat/>'
    '<w:pPr><w:spacing w:after="200" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/></w:pPr>'
    '<w:rPr><w:color w:val="44546A"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>',
  );
  sb.write(
    '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
    '<w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/>'
    '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>',
  );
  sb.write(
    '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>'
    '<w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/>'
    '<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>'
    '<w:tblPr><w:tblBorders>'
    '<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    '<w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    '<w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
    '</w:tblBorders></w:tblPr></w:style>',
  );
  sb.write('</w:styles>');
  return sb.toString();
}();

const String _settingsXml =
    '$_xmlDecl<w:settings xmlns:w="$_nsW">'
    '<w:zoom w:percent="100"/><w:defaultTabStop w:val="720"/>'
    '<w:characterSpacingControl w:val="doNotCompress"/>'
    '<w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" '
    'w:val="15"/></w:compat></w:settings>';

const String _fontTableXml =
    '$_xmlDecl<w:fonts xmlns:w="$_nsW">'
    '<w:font w:name="Calibri"><w:panose1 w:val="020F0502020204030204"/><w:charset w:val="00"/>'
    '<w:family w:val="swiss"/><w:pitch w:val="variable"/></w:font>'
    '<w:font w:name="Arial"><w:panose1 w:val="020B0604020202020204"/><w:charset w:val="00"/>'
    '<w:family w:val="swiss"/><w:pitch w:val="variable"/></w:font>'
    '<w:font w:name="Courier New"><w:panose1 w:val="02070309020205020404"/><w:charset w:val="00"/>'
    '<w:family w:val="modern"/><w:pitch w:val="fixed"/></w:font>'
    '<w:font w:name="Times New Roman"><w:panose1 w:val="02020603050405020304"/><w:charset w:val="00"/>'
    '<w:family w:val="roman"/><w:pitch w:val="variable"/></w:font>'
    '</w:fonts>';
