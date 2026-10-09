// Generates sample PDFs for manual testing: dart run tool/make_samples.dart <outDir>
import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<void> main(List<String> args) async {
  final out = Directory(args.isEmpty ? 'build/samples' : args.first)..createSync(recursive: true);
  pw.Font f(String n) => pw.Font.ttf(File('assets/fonts/$n.ttf').readAsBytesSync().buffer.asByteData());
  final regular = f('NotoSerif-Regular'), bold = f('NotoSans-Bold'), sans = f('NotoSans-Regular');
  const lorem =
      'Annual planning brings together finance, operations and product teams to agree on priorities for the coming year. '
      'This report summarises the key findings, the budget allocation and the risks we identified during the review process. '
      'Each section can be read independently, and the appendix lists the source data used for the analysis.';

  // 1) Multi-page report with headings, two columns, a table.
  final report = pw.Document(title: 'Quarterly Report', author: 'PDFCraft');
  report.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(48),
      header: (c) => pw.Text('Northwind Traders · Quarterly Report', style: pw.TextStyle(font: sans, fontSize: 8, color: PdfColors.grey600)),
      footer: (c) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('${c.pageNumber}', style: pw.TextStyle(font: sans, fontSize: 9))),
      build: (c) => [
        pw.Text('Quarterly Report', style: pw.TextStyle(font: bold, fontSize: 30, color: PdfColor.fromHex('#B91C1C'))),
        pw.SizedBox(height: 8),
        pw.Text('Prepared for the leadership team', style: pw.TextStyle(font: sans, fontSize: 14, color: PdfColors.grey700)),
        pw.SizedBox(height: 24),
        for (var s = 1; s <= 6; s++) ...[
          pw.Text('$s. ${['Overview', 'Revenue', 'Operations', 'Customers', 'Risks', 'Outlook'][s - 1]}', style: pw.TextStyle(font: bold, fontSize: 18)),
          pw.SizedBox(height: 8),
          for (var k = 0; k < 3; k++) pw.Padding(padding: const pw.EdgeInsets.only(bottom: 8), child: pw.Text(lorem, style: pw.TextStyle(font: regular, fontSize: 11, lineSpacing: 3))),
          if (s == 2)
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(font: bold, fontSize: 10),
              cellStyle: pw.TextStyle(font: sans, fontSize: 10),
              data: const [
                ['Region', 'Q1', 'Q2', 'Q3'],
                ['North', '1.2M', '1.4M', '1.6M'],
                ['South', '0.9M', '1.1M', '1.0M'],
                ['West', '2.1M', '2.0M', '2.4M'],
              ],
            ),
          pw.SizedBox(height: 12),
        ],
      ],
    ),
  );
  File('${out.path}/Quarterly Report.pdf').writeAsBytesSync(await report.save());

  // 2) Form
  final form = pw.Document(title: 'Registration Form');
  form.addPage(
    pw.Page(
      build: (c) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Event Registration', style: pw.TextStyle(font: bold, fontSize: 24)),
          pw.SizedBox(height: 24),
          for (final (label, name) in [('Full name', 'full_name'), ('Email', 'email'), ('Company', 'company')]) ...[
            pw.Text(label, style: pw.TextStyle(font: sans, fontSize: 11)),
            pw.SizedBox(height: 4),
            pw.TextField(name: name, width: 300, height: 22),
            pw.SizedBox(height: 16),
          ],
          pw.Row(children: [pw.Checkbox(name: 'newsletter', value: false), pw.SizedBox(width: 8), pw.Text('Subscribe to the newsletter', style: pw.TextStyle(font: sans))]),
          pw.SizedBox(height: 40),
          pw.Text('Signature', style: pw.TextStyle(font: sans, fontSize: 11)),
          pw.SizedBox(height: 40),
          pw.Container(width: 220, height: 1, color: PdfColors.black),
        ],
      ),
    ),
  );
  File('${out.path}/Registration Form.pdf').writeAsBytesSync(await form.save());
  stdout.writeln('Samples written to ${out.path}');
}
