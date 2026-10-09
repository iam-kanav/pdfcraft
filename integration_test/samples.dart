import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfcraft/core/pdf_render.dart';

/// Builds sample documents used by the on-device tests.
class Samples {
  Samples(this.dir);

  final Directory dir;

  Future<pw.Font> _font(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/$name.ttf'));

  Uint8List testImage({int w = 240, int h = 160}) {
    final im = img.Image(width: w, height: h);
    img.fill(im, color: img.ColorRgb8(30, 120, 200));
    img.fillRect(im, x1: 20, y1: 20, x2: w - 20, y2: h - 20, color: img.ColorRgb8(250, 200, 40));
    return Uint8List.fromList(img.encodePng(im));
  }

  /// 3 pages: a heading, paragraphs (one containing SECRET), an image on page 1.
  Future<String> textDoc({String name = 'sample.pdf', int pages = 3}) async {
    final regular = await _font('NotoSans-Regular');
    final bold = await _font('NotoSans-Bold');
    final doc = pw.Document(title: 'Sample', author: 'Tester');
    final image = pw.MemoryImage(testImage());
    for (var i = 1; i <= pages; i++) {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Chapter $i Heading', style: pw.TextStyle(font: bold, fontSize: 24)),
              pw.SizedBox(height: 16),
              pw.Text(
                'Hello World page $i. This is the first paragraph of sample text used for testing.',
                style: pw.TextStyle(font: regular, fontSize: 12),
              ),
              pw.SizedBox(height: 12),
              pw.Text(
                'The account number is SECRET123 and must be hidden.',
                style: pw.TextStyle(font: regular, fontSize: 12),
              ),
              pw.SizedBox(height: 12),
              if (i == 1) pw.Image(image, width: 200, height: 133),
              pw.SizedBox(height: 12),
              pw.Text('Closing remarks for page $i.', style: pw.TextStyle(font: regular, fontSize: 12)),
            ],
          ),
        ),
      );
    }
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(await doc.save());
    return f.path;
  }

  /// Colored, decorated, mixed-font, aligned and linked text (smart reading fidelity).
  Future<String> formattedDoc({String name = 'formatting.pdf'}) async {
    final sans = await _font('NotoSans-Regular');
    final sansBold = await _font('NotoSans-Bold');
    final serif = await _font('NotoSerif-Regular');
    final serifItalic = await _font('NotoSerif-Italic');
    final mono = pw.Font.courier();
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        build: (c) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Center(child: pw.Text('Formatting Showcase', style: pw.TextStyle(font: sansBold, fontSize: 26, color: PdfColor.fromHex('#1D4ED8')))),
            pw.SizedBox(height: 6),
            pw.Center(child: pw.Text('A centered subtitle line', style: pw.TextStyle(font: serifItalic, fontSize: 13))),
            pw.SizedBox(height: 18),
            pw.RichText(
              text: pw.TextSpan(
                style: pw.TextStyle(font: serif, fontSize: 12),
                children: [
                  const pw.TextSpan(text: 'This paragraph mixes '),
                  pw.TextSpan(text: 'red words', style: pw.TextStyle(color: PdfColor.fromHex('#DC2626'))),
                  const pw.TextSpan(text: ', '),
                  const pw.TextSpan(text: 'underlined text', style: pw.TextStyle(decoration: pw.TextDecoration.underline)),
                  const pw.TextSpan(text: ', '),
                  const pw.TextSpan(text: 'struck text', style: pw.TextStyle(decoration: pw.TextDecoration.lineThrough)),
                  const pw.TextSpan(text: ' and '),
                  pw.TextSpan(text: 'monospaced code', style: pw.TextStyle(font: mono)),
                  const pw.TextSpan(text: ' inside ordinary serif prose that wraps over more than one line of the page.'),
                ],
              ),
            ),
            pw.SizedBox(height: 14),
            pw.UrlLink(destination: 'https://example.com/docs', child: pw.Text('Visit the documentation', style: pw.TextStyle(font: sans, fontSize: 12))),
            pw.SizedBox(height: 14),
            pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Signed, The Team', style: pw.TextStyle(font: sans, fontSize: 12))),
          ],
        ),
      ),
    );
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(await doc.save());
    return f.path;
  }

  /// A one-page AcroForm with a text field, a checkbox.
  Future<String> formDoc({String name = 'form.pdf'}) async {
    final regular = await _font('NotoSans-Regular');
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Application form', style: pw.TextStyle(font: regular, fontSize: 20)),
            pw.SizedBox(height: 20),
            pw.Row(
              children: [
                pw.Text('Name: ', style: pw.TextStyle(font: regular)),
                pw.TextField(name: 'name', width: 200, height: 20),
              ],
            ),
            pw.SizedBox(height: 20),
            pw.Row(
              children: [
                pw.Text('Agree: ', style: pw.TextStyle(font: regular)),
                pw.Checkbox(name: 'agree', value: false),
              ],
            ),
          ],
        ),
      ),
    );
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(await doc.save());
    return f.path;
  }
}

/// Full text of every page (via PDFium).
Future<List<String>> pageTexts(String path, {String? password}) async {
  final doc = await openPdf(path, password: password);
  try {
    return [for (final p in doc.pages) (await p.loadText())?.fullText ?? ''];
  } finally {
    await doc.dispose();
  }
}
