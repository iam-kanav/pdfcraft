import 'dart:io';
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../core/pdf_render.dart';
import '../../core/services.dart';

class OcrWord {
  OcrWord(this.text, this.rect);

  final String text;

  /// Display-space rect in PDF points.
  final Rect rect;
}

class OcrPageResult {
  OcrPageResult(this.pageIndex, this.words, this.text);

  final int pageIndex;
  final List<OcrWord> words;
  final String text;
}

/// On-device OCR (ML Kit bundled Latin model — no network required).
class OcrService {
  OcrService() : _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;

  Future<void> close() => _recognizer.close();

  /// Recognizes text in an image file; [scaleX]/[scaleY] convert pixels to output units.
  Future<(List<OcrWord>, String)> recognizeImageFile(String path, {double scaleX = 1, double scaleY = 1}) async {
    final result = await _recognizer.processImage(InputImage.fromFilePath(path));
    final words = <OcrWord>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        for (final el in line.elements) {
          final r = el.boundingBox;
          words.add(
            OcrWord(el.text, Rect.fromLTRB(r.left * scaleX, r.top * scaleY, r.right * scaleX, r.bottom * scaleY)),
          );
        }
      }
    }
    return (words, result.text);
  }

  /// Renders and recognizes one PDF page.
  Future<OcrPageResult> recognizePage(PdfPage page, {double maxSide = 2400}) async {
    final image = await renderPageImage(page, maxSide: maxSide);
    if (image == null) return OcrPageResult(page.pageNumber - 1, const [], '');
    final png = await imageToPng(image);
    final w = image.width, h = image.height;
    image.dispose();
    final file = File(AppServices.instance.tempPath('ocr_${page.pageNumber}.png'));
    await file.writeAsBytes(png!);
    try {
      final (words, text) = await recognizeImageFile(file.path, scaleX: page.width / w, scaleY: page.height / h);
      return OcrPageResult(page.pageNumber - 1, words, text);
    } finally {
      try {
        await file.parent.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<bool> pageHasText(PdfPage page) async {
    final t = await page.loadText();
    return (t?.fullText.replaceAll(RegExp(r'\s'), '').length ?? 0) > 20;
  }

  static String tempName(String path) => p.basename(path);
}
