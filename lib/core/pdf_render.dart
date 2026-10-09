import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

/// Opens a document with an optional password (no prompting).
Future<PdfDocument> openPdf(String path, {String? password}) async {
  await pdfrxFlutterInitialize();
  return PdfDocument.openFile(
    path,
    passwordProvider: password == null ? null : () => password,
    firstAttemptByEmptyPassword: password == null,
    useProgressiveLoading: false,
  );
}

/// Renders a page to a [ui.Image] whose longest side is about [maxSide] pixels
/// (or at [dpi] when given).
Future<ui.Image?> renderPageImage(PdfPage page, {double? maxSide, double? dpi, int background = 0xFFFFFFFF}) async {
  final scale = dpi != null ? dpi / 72.0 : (maxSide! / (page.width > page.height ? page.width : page.height));
  final w = (page.width * scale).roundToDouble();
  final h = (page.height * scale).roundToDouble();
  final img = await page.render(fullWidth: w, fullHeight: h, width: w.toInt(), height: h.toInt(), backgroundColor: background);
  if (img == null) return null;
  try {
    return await img.createImage();
  } finally {
    img.dispose();
  }
}

Future<Uint8List?> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

/// Disk cache of first-page thumbnails keyed by path + size + mtime.
class ThumbnailCache {
  ThumbnailCache(this.dir);

  final Directory dir;
  final _inflight = <String, Future<File?>>{};
  int _running = 0;
  final _queue = <Completer<void>>[];

  String _key(String path, int page) {
    final st = File(path).statSync();
    return md5.convert('$path|$page|${st.size}|${st.modified.millisecondsSinceEpoch}'.codeUnits).toString();
  }

  Future<File?> get(String path, {int page = 1, double maxSide = 360, String? password}) {
    if (!File(path).existsSync()) return Future.value(null);
    final key = _key(path, page);
    final file = File(p.join(dir.path, '$key.png'));
    if (file.existsSync()) return Future.value(file);
    return _inflight.putIfAbsent(key, () async {
      try {
        await _acquire();
        try {
          final doc = await openPdf(path, password: password);
          try {
            if (page > doc.pages.length) return null;
            final img = await renderPageImage(doc.pages[page - 1], maxSide: maxSide);
            if (img == null) return null;
            final png = await imageToPng(img);
            img.dispose();
            if (png == null) return null;
            await dir.create(recursive: true);
            await file.writeAsBytes(png, flush: true);
            return file;
          } finally {
            await doc.dispose();
          }
        } finally {
          _release();
        }
      } catch (e) {
        debugPrint('thumbnail failed for $path: $e');
        return null;
      } finally {
        _inflight.remove(key);
      }
    });
  }

  Future<void> _acquire() async {
    if (_running < 2) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
    _running++;
  }

  void _release() {
    _running--;
    if (_queue.isNotEmpty) _queue.removeAt(0).complete();
  }
}
