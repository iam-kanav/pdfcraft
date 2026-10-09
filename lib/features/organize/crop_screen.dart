import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/native/pdf_engine.dart';
import '../../core/pdf_render.dart';
import '../../core/session/document_session.dart';
import '../common/dialogs.dart';

/// Visual crop: drag the edges of the crop box, apply to one page or all pages.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.session, this.initialPage = 0});

  final DocumentSession session;
  final int initialPage;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  PdfDocument? _doc;
  late int _page = widget.initialPage;
  Rect? _crop; // display space of the page
  bool _allPages = false;

  @override
  void initState() {
    super.initState();
    openPdf(widget.session.path, password: widget.session.password).then((d) {
      if (!mounted) return;
      setState(() {
        _doc = d;
        _page = _page.clamp(0, d.pages.length - 1);
        _resetCrop();
      });
    });
  }

  @override
  void dispose() {
    _doc?.dispose();
    super.dispose();
  }

  void _resetCrop() {
    final pg = _doc!.pages[_page];
    _crop = Rect.fromLTWH(pg.width * 0.05, pg.height * 0.05, pg.width * 0.9, pg.height * 0.9);
  }

  Future<void> _apply() async {
    final doc = _doc!;
    final pg = doc.pages[_page];
    final crop = _crop!;
    final crops = <int, Rect>{};
    if (_allPages) {
      // Apply the same relative crop to every page.
      for (var i = 0; i < doc.pages.length; i++) {
        final q = doc.pages[i];
        crops[i] = Rect.fromLTRB(crop.left / pg.width * q.width, crop.top / pg.height * q.height, crop.right / pg.width * q.width, crop.bottom / pg.height * q.height);
      }
    } else {
      crops[_page] = crop;
    }
    final s = widget.session;
    try {
      await s.apply('Crop', (i, o) => PdfEngine.instance.crop(i, o, crops, password: s.password));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop pages'),
        actions: [TextButton(onPressed: doc == null ? null : _apply, child: const Text('Apply'))],
      ),
      body: doc == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final pg = doc.pages[_page];
                        final scale = (c.maxWidth / pg.width).clamp(0.0, c.maxHeight / pg.height);
                        final w = pg.width * scale, h = pg.height * scale;
                        final crop = _crop!;
                        Rect sc(Rect r) => Rect.fromLTRB(r.left * scale, r.top * scale, r.right * scale, r.bottom * scale);
                        void drag(String edge, Offset d) {
                          final dx = d.dx / scale, dy = d.dy / scale;
                          var r = _crop!;
                          r = Rect.fromLTRB(
                            edge.contains('l') ? (r.left + dx).clamp(0, r.right - 20) : r.left,
                            edge.contains('t') ? (r.top + dy).clamp(0, r.bottom - 20) : r.top,
                            edge.contains('r') ? (r.right + dx).clamp(r.left + 20, pg.width) : r.right,
                            edge.contains('b') ? (r.bottom + dy).clamp(r.top + 20, pg.height) : r.bottom,
                          );
                          setState(() => _crop = r);
                        }

                        final cr = sc(crop);
                        Widget handle(String edge, Alignment a) => Positioned(
                          left: cr.left + (a.x + 1) / 2 * cr.width - 16,
                          top: cr.top + (a.y + 1) / 2 * cr.height - 16,
                          child: GestureDetector(
                            onPanUpdate: (d) => drag(edge, d.delta),
                            child: Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              child: Container(width: 14, height: 14, decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3))),
                            ),
                          ),
                        );
                        return Center(
                          child: SizedBox(
                            width: w,
                            height: h,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(child: PdfPageView(document: doc, pageNumber: _page + 1)),
                                Positioned.fill(child: CustomPaint(painter: _ShadePainter(cr))),
                                handle('lt', Alignment.topLeft),
                                handle('rt', Alignment.topRight),
                                handle('lb', Alignment.bottomLeft),
                                handle('rb', Alignment.bottomRight),
                                handle('t', Alignment.topCenter),
                                handle('b', Alignment.bottomCenter),
                                handle('l', Alignment.centerLeft),
                                handle('r', Alignment.centerRight),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        IconButton(onPressed: _page > 0 ? () => setState(() => _page--) : null, icon: const Icon(Icons.chevron_left)),
                        Text('Page ${_page + 1} of ${doc.pages.length}'),
                        IconButton(onPressed: _page < doc.pages.length - 1 ? () => setState(() => _page++) : null, icon: const Icon(Icons.chevron_right)),
                        const Spacer(),
                        TextButton(onPressed: () => setState(_resetCrop), child: const Text('Reset')),
                        const Text('All pages'),
                        Switch(value: _allPages, onChanged: (v) => setState(() => _allPages = v)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ShadePainter extends CustomPainter {
  _ShadePainter(this.crop);

  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(crop);
    canvas.drawPath(path, shade);
    canvas.drawRect(crop, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _ShadePainter old) => old.crop != crop;
}
