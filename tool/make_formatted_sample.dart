// Formatting-rich sample for smart reading tests: dart run tool/make_formatted_sample.dart <out.pdf>
import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<void> main(List<String> args) async {
  pw.Font f(String n) => pw.Font.ttf(File('assets/fonts/$n.ttf').readAsBytesSync().buffer.asByteData());
  final sans = f('NotoSans-Regular'), sansBold = f('NotoSans-Bold'), serif = f('NotoSerif-Regular'), serifItalic = f('NotoSerif-Italic');
  final mono = pw.Font.courier();
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      build: (c) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Center(child: pw.Text('Formatting Showcase', style: pw.TextStyle(font: sansBold, fontSize: 26, color: PdfColor.fromHex('#1D4ED8')))),
          pw.SizedBox(height: 6),
          pw.Center(child: pw.Text('A centered subtitle line', style: pw.TextStyle(font: serifItalic, fontSize: 13, color: PdfColors.grey700))),
          pw.SizedBox(height: 18),
          pw.RichText(
            text: pw.TextSpan(
              style: pw.TextStyle(font: serif, fontSize: 12),
              children: [
                const pw.TextSpan(text: 'This paragraph mixes '),
                pw.TextSpan(text: 'red words', style: pw.TextStyle(color: PdfColor.fromHex('#DC2626'))),
                const pw.TextSpan(text: ', '),
                pw.TextSpan(text: 'underlined text', style: const pw.TextStyle(decoration: pw.TextDecoration.underline)),
                const pw.TextSpan(text: ', '),
                pw.TextSpan(text: 'struck text', style: const pw.TextStyle(decoration: pw.TextDecoration.lineThrough)),
                const pw.TextSpan(text: ' and '),
                pw.TextSpan(text: 'monospaced code', style: pw.TextStyle(font: mono)),
                const pw.TextSpan(text: ' inside ordinary serif prose that wraps over more than one line of the page.'),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.UrlLink(destination: 'https://example.com/docs', child: pw.Text('Visit the documentation', style: pw.TextStyle(font: sans, fontSize: 12, color: PdfColors.blue))),
          pw.SizedBox(height: 14),
          pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Signed, The Team', style: pw.TextStyle(font: sans, fontSize: 12))),
        ],
      ),
    ),
  );
  File(args.isEmpty ? 'build/samples/Formatting.pdf' : args.first).writeAsBytesSync(await doc.save());
}
