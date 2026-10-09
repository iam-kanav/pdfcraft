import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/native/pdf_engine.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../convert/engine/images_to_pdf.dart';
import '../convert/ocr_service.dart';
import 'processing/filters.dart';
import 'processing/geometry.dart';
import 'processing/scan_pipeline.dart';
import 'scanner_screen.dart';
import 'package:material_symbols_icons/symbols.dart';

/// One captured page with its crop quad, filter and rotation.
class ScanPage {
  ScanPage._(this.original, this.width, this.height, this.quad, this.detected);

  final Uint8List original;
  final int width;
  final int height;
  Quad quad;
  final bool detected;
  ScanFilter filter = ScanFilter.autoColor;
  int rotation = 0;
  Uint8List? processed;
  late Uint8List thumbnail;

  static Future<ScanPage> create(Uint8List bytes) async {
    final det = await Isolate.run(() => detectQuadFromBytes(bytes));
    int w, h;
    Quad quad;
    if (det != null) {
      w = det['width'] as int;
      h = det['height'] as int;
      quad = Quad.fromJson((det['quad'] as Map).cast<String, dynamic>());
    } else {
      final size = await Isolate.run(() {
        final im = decodeOriented(bytes);
        if (im == null) throw const FormatException('Unsupported image');
        return (im.width, im.height);
      });
      w = size.$1;
      h = size.$2;
      quad = Quad.full(w.toDouble(), h.toDouble());
    }
    final page = ScanPage._(bytes, w, h, quad, det != null);
    await page.reprocess();
    return page;
  }

  Future<void> reprocess() async {
    final req = ScanRequest(imageBytes: original, quad: quad.toJson(), filter: filter.name, rotation: rotation);
    processed = await Isolate.run(() => processScanBytes(req));
    final out = processed!;
    thumbnail = await Isolate.run(() => makeThumbnail(out, maxDim: 360));
  }
}

class ScanReviewScreen extends StatefulWidget {
  const ScanReviewScreen({super.key, required this.pages});

  final List<ScanPage> pages;

  @override
  State<ScanReviewScreen> createState() => _ScanReviewScreenState();
}

class _ScanReviewScreenState extends State<ScanReviewScreen> {
  late final List<ScanPage> _pages = widget.pages;
  final _pager = PageController();
  int _index = 0;
  bool _working = false;

  ScanPage get _page => _pages[_index];

  Future<void> _update(Future<void> Function() change) async {
    setState(() => _working = true);
    try {
      await change();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _crop() async {
    final q = await Navigator.of(context).push<Quad>(MaterialPageRoute(builder: (_) => CropQuadScreen(page: _page)));
    if (q == null) return;
    await _update(() async {
      _page.quad = q;
      await _page.reprocess();
    });
  }

  Future<void> _addPages() async {
    final r = await Navigator.of(
      context,
    ).push<List<ScanPage>>(MaterialPageRoute(builder: (_) => ScannerScreen(existing: _pages)));
    if (r != null) {
      setState(() {
        _pages
          ..clear()
          ..addAll(r);
      });
    }
  }

  Future<void> _save() async {
    final name = TextEditingController(
      text: 'Scan ${DateTime.now().toIso8601String().substring(0, 16).replaceAll('T', ' ').replaceAll(':', '.')}',
    );
    var ocr = true;
    var size = ImagePageSize.fitImage;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Save scan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ImagePageSize>(
                initialValue: size,
                decoration: const InputDecoration(labelText: 'Page size'),
                items: const [
                  DropdownMenuItem(value: ImagePageSize.fitImage, child: Text('Fit to scan')),
                  DropdownMenuItem(value: ImagePageSize.a4, child: Text('A4')),
                  DropdownMenuItem(value: ImagePageSize.letter, child: Text('US Letter')),
                ],
                onChanged: (v) => setState(() => size = v!),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: ocr,
                onChanged: (v) => setState(() => ocr = v!),
                title: const Text('Recognize text (OCR)'),
                subtitle: const Text('Makes the PDF searchable'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final services = AppServices.instance;
    final out = services.files.outputPath(
      '${sanitizeFileName(name.text.trim().isEmpty ? 'Scan' : name.text.trim())}.pdf',
      dir: services.files.scansDir,
    );
    final saved = await runWithProgress(context, ocr ? 'Saving and recognizing text…' : 'Saving…', () async {
      final images = [for (final pg in _pages) pg.processed!];
      final pdf = await buildPdfFromImages(
        images,
        pageSize: size,
        margin: size == ImagePageSize.fitImage ? 0 : 18,
        title: name.text,
      );
      await File(out).writeAsBytes(pdf, flush: true);
      if (ocr) await _ocr(out, images, size);
      return out;
    });
    if (saved == null || !mounted) return;
    // The scanner replaces itself with the viewer for the saved file.
    Navigator.pop(context, saved);
  }

  /// OCRs the processed scan images and adds an invisible text layer to [pdfPath].
  Future<void> _ocr(String pdfPath, List<Uint8List> images, ImagePageSize size) async {
    final info = await PdfEngine.instance.info(pdfPath);
    final ocr = OcrService();
    final pages = <int, List<({String text, Rect rect})>>{};
    try {
      for (var i = 0; i < images.length; i++) {
        final tmp = File(AppServices.instance.tempPath('scan_ocr_$i.jpg'));
        await tmp.writeAsBytes(images[i]);
        final dims = await Isolate.run(() {
          final im = decodeOriented(images[i]);
          return (im!.width, im.height);
        });
        final page = info.pages[i];
        // Where the image sits on the page (centered and fitted inside margins).
        final margin = size == ImagePageSize.fitImage ? 0.0 : 18.0;
        final availW = page.width - margin * 2, availH = page.height - margin * 2;
        final scale = math.min(availW / dims.$1, availH / dims.$2);
        final offX = (page.width - dims.$1 * scale) / 2, offY = (page.height - dims.$2 * scale) / 2;
        final (words, _) = await ocr.recognizeImageFile(tmp.path);
        pages[i] = [
          for (final w in words)
            (
              text: w.text,
              rect: Rect.fromLTRB(
                offX + w.rect.left * scale,
                offY + w.rect.top * scale,
                offX + w.rect.right * scale,
                offY + w.rect.bottom * scale,
              ),
            ),
        ];
        await tmp.delete();
      }
    } finally {
      await ocr.close();
    }
    if (pages.values.every((l) => l.isEmpty)) return;
    final tmpOut = '$pdfPath.ocr';
    await PdfEngine.instance.addOcrLayer(pdfPath, tmpOut, pages);
    await File(tmpOut).rename(pdfPath);
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review')),
        body: Center(
          child: FilledButton.icon(
            onPressed: _addPages,
            icon: const Icon(Symbols.add_a_photo),
            label: const Text('Scan a page'),
          ),
        ),
      );
    }
    _index = _index.clamp(0, _pages.length - 1);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _pages);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.pop(context, _pages)),
          title: Text('Page ${_index + 1} of ${_pages.length}'),
          actions: [
            FilledButton(onPressed: _working ? null : _save, child: const Text('Save PDF')),
            const SizedBox(width: 12),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pager,
                    itemCount: _pages.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: InteractiveViewer(
                        child: Image.memory(_pages[i].processed!, fit: BoxFit.contain, gaplessPlayback: true),
                      ),
                    ),
                  ),
                  if (_working) const Center(child: CircularProgressIndicator()),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final f in ScanFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(f.label),
                        selected: _page.filter == f,
                        onSelected: _working
                            ? null
                            : (_) => _update(() async {
                                _page.filter = f;
                                await _page.reprocess();
                              }),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 92,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: _pages.length,
                onReorderItem: (a, b) => setState(() {
                  _pages.insert(b, _pages.removeAt(a));
                }),
                itemBuilder: (context, i) => GestureDetector(
                  key: ObjectKey(_pages[i]),
                  onTap: () => _pager.jumpToPage(i),
                  child: Container(
                    width: 56,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: i == _index ? Theme.of(context).colorScheme.primary : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: Image.memory(_pages[i].thumbnail, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Action(icon: Symbols.add_a_photo, label: 'Add', onTap: _working ? null : _addPages),
                  _Action(icon: Symbols.crop, label: 'Crop', onTap: _working ? null : _crop),
                  _Action(
                    icon: Symbols.rotate_right,
                    label: 'Rotate',
                    onTap: _working
                        ? null
                        : () => _update(() async {
                            _page.rotation = (_page.rotation + 90) % 360;
                            await _page.reprocess();
                          }),
                  ),
                  _Action(
                    icon: Symbols.delete_outline,
                    label: 'Delete',
                    onTap: _working
                        ? null
                        : () => setState(() {
                            _pages.removeAt(_index);
                            if (_index >= _pages.length) _index = math.max(0, _pages.length - 1);
                          }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}

/// Adjust the four document corners on the original photo.
class CropQuadScreen extends StatefulWidget {
  const CropQuadScreen({super.key, required this.page});

  final ScanPage page;

  @override
  State<CropQuadScreen> createState() => _CropQuadScreenState();
}

class _CropQuadScreenState extends State<CropQuadScreen> {
  late List<Offset> _pts = _fromQuad(widget.page.quad);
  Uint8List? _preview;

  List<Offset> _fromQuad(Quad q) => [for (final pt in q.points) Offset(pt.x, pt.y)];

  @override
  void initState() {
    super.initState();
    final bytes = widget.page.original;
    Isolate.run(() => makeThumbnail(bytes, maxDim: 1600)).then((v) {
      if (mounted) setState(() => _preview = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(color: Colors.white),
        title: const Text('Adjust corners'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _pts = _fromQuad(Quad.full(page.width.toDouble(), page.height.toDouble()))),
            child: const Text('Full page', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () {
              final q = Quad.orderPoints([for (final o in _pts) math.Point(o.dx, o.dy)]);
              if (!q.isConvex || q.area < 100) {
                showSnack(context, 'The corners must form a convex shape', error: true);
                return;
              }
              Navigator.pop(context, q);
            },
            child: const Text('Done', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _preview == null
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: AspectRatio(
                  aspectRatio: page.width / page.height,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final s = c.maxWidth / page.width;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(child: Image.memory(_preview!, fit: BoxFit.fill)),
                          Positioned.fill(child: CustomPaint(painter: _CornersPainter([for (final o in _pts) o * s]))),
                          for (var i = 0; i < 4; i++)
                            Positioned(
                              left: _pts[i].dx * s - 22,
                              top: _pts[i].dy * s - 22,
                              child: GestureDetector(
                                onPanUpdate: (d) => setState(() {
                                  final np = _pts[i] + d.delta / s;
                                  _pts[i] = Offset(
                                    np.dx.clamp(0, page.width.toDouble()),
                                    np.dy.clamp(0, page.height.toDouble()),
                                  );
                                }),
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  alignment: Alignment.center,
                                  child: Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white.withValues(alpha: 0.4),
                                      border: Border.all(color: const Color(0xFF3B82F6), width: 3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

class _CornersPainter extends CustomPainter {
  _CornersPainter(this.pts);

  final List<Offset> pts;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(pts, true);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), path),
      Paint()..color = Colors.black45,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF3B82F6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CornersPainter old) => true;
}
