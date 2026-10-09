import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'convert_utils.dart';

/// An editable text box positioned on a slide (coordinates in PDF points, top-left origin).
class SlideTextBox {
  const SlideTextBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.lines,
    required this.fontSize,
    this.bold = false,
    this.italic = false,
    this.serif = false,
    this.color = 0xFF000000,
  });

  final double left, top, width, height;
  final List<String> lines;
  final double fontSize;
  final bool bold, italic, serif;
  final int color;
}

class SlideSpec {
  const SlideSpec({required this.widthPt, required this.heightPt, this.background, this.textBoxes = const []});

  final double widthPt;
  final double heightPt;

  /// PNG of the page artwork (text removed) used as the slide background.
  final Uint8List? background;
  final List<SlideTextBox> textBoxes;
}

const _emuPerPt = 12700;
const _ns =
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';

/// Builds a .pptx with one slide per [SlideSpec]: background picture plus editable text boxes.
Uint8List buildPptx(List<SlideSpec> slides, {String? title}) {
  if (slides.isEmpty) throw ArgumentError('No slides');
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  void addBytes(String name, Uint8List bytes) => archive.addFile(ArchiveFile(name, bytes.length, bytes));

  // Presentation size follows the first page; other pages are scaled to fit.
  final cx = (slides.first.widthPt * _emuPerPt).round();
  final cy = (slides.first.heightPt * _emuPerPt).round();

  add(
    '[Content_Types].xml',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>${[for (var i = 0; i < slides.length; i++) '<Override PartName="/ppt/slides/slide${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'].join()}<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>''',
  );
  add(
    '_rels/.rels',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>''',
  );
  add(
    'docProps/core.xml',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>${xmlEscape(title ?? '')}</dc:title><dc:creator>PDFCraft</dc:creator></cp:coreProperties>''',
  );
  add(
    'ppt/presentation.xml',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation $_ns><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>${[for (var i = 0; i < slides.length; i++) '<p:sldId id="${256 + i}" r:id="rId${i + 2}"/>'].join()}</p:sldIdLst><p:sldSz cx="$cx" cy="$cy"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>''',
  );
  add(
    'ppt/_rels/presentation.xml.rels',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>${[for (var i = 0; i < slides.length; i++) '<Relationship Id="rId${i + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide${i + 1}.xml"/>'].join()}<Relationship Id="rId${slides.length + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/></Relationships>''',
  );
  const emptyTree =
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree>';
  add(
    'ppt/slideMasters/slideMaster1.xml',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster $_ns><p:cSld>$emptyTree</p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>''',
  );
  add(
    'ppt/slideMasters/_rels/slideMaster1.xml.rels',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>''',
  );
  add(
    'ppt/slideLayouts/slideLayout1.xml',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout $_ns type="blank" preserve="1"><p:cSld name="Blank">$emptyTree</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>''',
  );
  add(
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>''',
  );
  add('ppt/theme/theme1.xml', _theme);

  for (var i = 0; i < slides.length; i++) {
    final s = slides[i];
    final scale = [cx / (s.widthPt * _emuPerPt), cy / (s.heightPt * _emuPerPt)].reduce((a, b) => a < b ? a : b);
    int emu(double pt) => (pt * _emuPerPt * scale).round();
    final offX = ((cx - s.widthPt * _emuPerPt * scale) / 2).round();
    final offY = ((cy - s.heightPt * _emuPerPt * scale) / 2).round();
    final shapes = StringBuffer();
    var id = 2;
    if (s.background != null) {
      addBytes('ppt/media/image${i + 1}.png', s.background!);
      shapes.write(
        '<p:pic><p:nvPicPr><p:cNvPr id="${id++}" name="Page background"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
        '<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
        '<p:spPr><a:xfrm><a:off x="$offX" y="$offY"/><a:ext cx="${emu(s.widthPt)}" cy="${emu(s.heightPt)}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>',
      );
    }
    for (final t in s.textBoxes) {
      final face = t.serif ? 'Times New Roman' : 'Arial';
      final sz = (t.fontSize * scale * 100).round().clamp(100, 400000);
      final rgb = hexRgb(t.color);
      final paras = [
        for (final line in t.lines)
          '<a:p><a:pPr><a:lnSpc><a:spcPct val="100000"/></a:lnSpc></a:pPr><a:r><a:rPr lang="en-US" sz="$sz" b="${t.bold ? 1 : 0}" i="${t.italic ? 1 : 0}" dirty="0"><a:solidFill><a:srgbClr val="$rgb"/></a:solidFill><a:latin typeface="$face"/><a:cs typeface="$face"/></a:rPr><a:t>${xmlEscape(stripInvalidXmlChars(line))}</a:t></a:r></a:p>',
      ].join();
      shapes.write(
        '<p:sp><p:nvSpPr><p:cNvPr id="${id++}" name="Text ${id - 2}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
        '<p:spPr><a:xfrm><a:off x="${offX + emu(t.left)}" y="${offY + emu(t.top)}"/><a:ext cx="${emu(t.width + t.fontSize * 0.5)}" cy="${emu(t.height)}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
        '<p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0"><a:noAutofit/></a:bodyPr><a:lstStyle/>$paras</p:txBody></p:sp>',
      );
    }
    add(
      'ppt/slides/slide${i + 1}.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld $_ns><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>$shapes</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>''',
    );
    add(
      'ppt/slides/_rels/slide${i + 1}.xml.rels',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>${s.background != null ? '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image${i + 1}.png"/>' : ''}</Relationships>''',
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _theme = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="PDFCraft"><a:themeElements><a:clrScheme name="PDFCraft"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2328"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2><a:accent1><a:srgbClr val="1473E6"/></a:accent1><a:accent2><a:srgbClr val="EB1000"/></a:accent2><a:accent3><a:srgbClr val="2D9D78"/></a:accent3><a:accent4><a:srgbClr val="DA7B11"/></a:accent4><a:accent5><a:srgbClr val="6767EC"/></a:accent5><a:accent6><a:srgbClr val="C0398A"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="PDFCraft"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="PDFCraft"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>''';
