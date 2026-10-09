import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../core/models/doc_structure.dart';
import '../../core/models/raw_page_content.dart';
import '../../core/native/pdf_engine.dart';
import '../../core/pdf_render.dart';
import '../reflow/analyzer/reflow_analyzer.dart';
import 'engine/convert_engine.dart';

enum ExportFormat {
  word('Microsoft Word', '.docx', 'Editable document with headings, lists, tables and images'),
  excel('Microsoft Excel', '.xlsx', 'Tables and text as spreadsheet cells'),
  powerpoint('Microsoft PowerPoint', '.pptx', 'One slide per page with editable text boxes'),
  text('Plain text', '.txt', 'Text only'),
  html('Web page (HTML)', '.html', 'Single file with embedded images'),
  markdown('Markdown', '.zip', 'Markdown with an images folder (zipped)'),
  png('PNG images', '.zip', 'One lossless image per page'),
  jpeg('JPEG images', '.zip', 'One compressed image per page');

  const ExportFormat(this.label, this.extension, this.description);

  final String label;
  final String extension;
  final String description;

  bool get isImage => this == ExportFormat.png || this == ExportFormat.jpeg;
}

/// Offline conversions between PDF and other formats.
class ConvertService {
  static final _fonts = <bool, Future<PdfFontSet>>{};

  static Future<PdfFontSet> fonts({bool serif = false}) =>
      _fonts.putIfAbsent(serif, () => PdfFontSet.load(rootBundle.load, serif: serif));

  /// Extracts positioned content in batches and analyzes it into a semantic structure.
  static Future<DocStructure> pdfToStructure(
    String path, {
    String? password,
    List<int>? pages,
    bool images = true,
    void Function(double progress)? onProgress,
  }) async {
    final info = await PdfEngine.instance.info(path, password: password);
    final targets = pages ?? [for (var i = 0; i < info.pageCount; i++) i];
    final raw = <RawPageContent>[];
    const batch = 8;
    for (var i = 0; i < targets.length; i += batch) {
      final chunk = targets.sublist(i, (i + batch).clamp(0, targets.length));
      raw.addAll(await PdfEngine.instance.extractPages(path, password: password, pages: chunk, images: images));
      onProgress?.call((i + chunk.length) / targets.length * 0.9);
    }
    final doc = analyzeDocument(raw, options: ReflowOptions(includeImages: images));
    onProgress?.call(1);
    return doc;
  }

  /// Exports [path] to [format] in [outDir]. Returns the created file path.
  static Future<String> exportPdf(
    String path,
    ExportFormat format,
    String outDir, {
    String? password,
    List<int>? pages,
    double dpi = 150,
    void Function(double)? onProgress,
  }) async {
    final base = p.basenameWithoutExtension(path);
    await Directory(outDir).create(recursive: true);
    String out(String ext) {
      var candidate = p.join(outDir, '$base$ext');
      var n = 2;
      while (File(candidate).existsSync()) {
        candidate = p.join(outDir, '$base ($n)$ext');
        n++;
      }
      return candidate;
    }

    if (format.isImage) {
      final doc = await openPdf(path, password: password);
      try {
        final archive = Archive();
        final targets = pages ?? [for (var i = 0; i < doc.pages.length; i++) i];
        for (var k = 0; k < targets.length; k++) {
          final i = targets[k];
          final img = await renderPageImage(doc.pages[i], dpi: dpi);
          if (img == null) continue;
          Uint8List bytes;
          if (format == ExportFormat.png) {
            bytes = (await imageToPng(img))!;
          } else {
            final rgba = (await img.toByteData())!.buffer.asUint8List();
            bytes = await _encodeJpeg(rgba, img.width, img.height);
          }
          img.dispose();
          final name =
              '${base}_page${(i + 1).toString().padLeft(3, '0')}.${format == ExportFormat.png ? 'png' : 'jpg'}';
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
          onProgress?.call((k + 1) / targets.length);
        }
        if (archive.length == 1) {
          final f = archive.files.first;
          final target = out(p.extension(f.name));
          await File(target).writeAsBytes(f.content as List<int>);
          return target;
        }
        final target = out('.zip');
        await File(target).writeAsBytes(ZipEncoder().encode(archive));
        return target;
      } finally {
        await doc.dispose();
      }
    }

    if (format == ExportFormat.powerpoint) {
      final target = out('.pptx');
      await File(target).writeAsBytes(await _pdfToPptx(path, password: password, pages: pages, onProgress: onProgress));
      return target;
    }

    final structure = await pdfToStructure(
      path,
      password: password,
      pages: pages,
      images: format != ExportFormat.text,
      onProgress: (v) => onProgress?.call(v * 0.9),
    );
    final title = structure.title ?? base;
    String target;
    switch (format) {
      case ExportFormat.word:
        target = out('.docx');
        await File(target).writeAsBytes(buildDocx(structure, title: title));
      case ExportFormat.excel:
        target = out('.xlsx');
        await File(target).writeAsBytes(buildXlsx(structureToSheets(structure), title: title));
      case ExportFormat.text:
        target = out('.txt');
        await File(target).writeAsString(structureToPlainText(structure));
      case ExportFormat.html:
        target = out('.html');
        await File(target).writeAsString(buildHtml(structure, title: title));
      case ExportFormat.markdown:
        final md = buildMarkdownWithImages(structure);
        if (md.images.isEmpty) {
          target = out('.md');
          await File(target).writeAsString(md.markdown);
        } else {
          final archive = Archive();
          final mdBytes = utf8.encode(md.markdown);
          archive.addFile(ArchiveFile('$base.md', mdBytes.length, mdBytes));
          for (final e in md.images.entries) {
            archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
          }
          target = out('.zip');
          await File(target).writeAsBytes(ZipEncoder().encode(archive));
        }
      default:
        throw StateError('Unsupported format');
    }
    onProgress?.call(1);
    return target;
  }

  /// Editable slides: page artwork (with text removed) as the background and the page's
  /// text blocks as real text boxes at their original positions.
  static Future<Uint8List> _pdfToPptx(
    String path, {
    String? password,
    List<int>? pages,
    void Function(double)? onProgress,
  }) async {
    final engine = PdfEngine.instance;
    final dir = await Directory.systemTemp.createTemp('pptx');
    try {
      final stripped = p.join(dir.path, 'notext.pdf');
      await engine.stripText(path, stripped, password: password);
      final bg = await openPdf(stripped, password: password);
      try {
        final targets = pages ?? [for (var i = 0; i < bg.pages.length; i++) i];
        final slides = <SlideSpec>[];
        for (var k = 0; k < targets.length; k++) {
          final i = targets[k];
          final page = bg.pages[i];
          final img = await renderPageImage(page, dpi: 144);
          final png = img == null ? null : await imageToPng(img);
          img?.dispose();
          final blocks = await engine.getTextBlocks(path, i, password: password);
          slides.add(
            SlideSpec(
              widthPt: page.width,
              heightPt: page.height,
              background: png,
              textBoxes: [
                for (final b in blocks)
                  () {
                    final r = b['rect'] as List;
                    final left = (r[0] as num).toDouble(), top = (r[1] as num).toDouble();
                    return SlideTextBox(
                      left: left,
                      top: top,
                      width: (r[2] as num).toDouble() - left,
                      height: (r[3] as num).toDouble() - top,
                      lines: [for (final l in b['lines'] as List) (l as Map)['text'] as String],
                      fontSize: (b['fontSize'] as num).toDouble(),
                      bold: b['bold'] as bool? ?? false,
                      italic: b['italic'] as bool? ?? false,
                      serif: b['serif'] as bool? ?? false,
                      color: b['color'] as int? ?? 0xFF000000,
                    );
                  }(),
              ],
            ),
          );
          onProgress?.call((k + 1) / targets.length);
        }
        return buildPptx(slides, title: p.basenameWithoutExtension(path));
      } finally {
        await bg.dispose();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }

  static Future<Uint8List> _encodeJpeg(Uint8List rgba, int w, int h) => _jpeg(rgba, w, h);

  /// Converts a supported document to a PDF. Returns PDF bytes.
  static Future<Uint8List> documentToPdf(String path, {String? title}) async {
    final ext = p.extension(path).toLowerCase();
    final bytes = await File(path).readAsBytes();
    final DocStructure doc = switch (ext) {
      '.docx' => parseDocx(bytes),
      '.md' || '.markdown' => parseMarkdown(utf8.decode(bytes, allowMalformed: true)),
      '.txt' || '.text' || '.log' || '.csv' => parsePlainText(utf8.decode(bytes, allowMalformed: true)),
      '.xlsx' => xlsxToStructure(bytes),
      _ => throw FormatException('Unsupported file type: $ext'),
    };
    final fonts = await ConvertService.fonts();
    return buildPdfFromStructure(
      doc,
      fonts: fonts,
      title: title ?? p.basenameWithoutExtension(path),
      pageNumbers: false,
    );
  }

  static const documentExtensions = ['docx', 'txt', 'md', 'markdown', 'xlsx', 'csv'];
}

Future<Uint8List> _jpeg(Uint8List rgba, int w, int h) => compute(_encodeJpegIsolate, (rgba, w, h));

Uint8List _encodeJpegIsolate((Uint8List, int, int) a) {
  final image = img.Image.fromBytes(width: a.$2, height: a.$3, bytes: a.$1.buffer, numChannels: 4);
  return img.encodeJpg(image, quality: 88);
}
