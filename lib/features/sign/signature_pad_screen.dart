import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import '../../core/file_picking.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'signature_store.dart';

/// Create a signature or initials by drawing, typing, or importing an image.
/// Pops with the saved [SavedSignature].
class SignaturePadScreen extends StatefulWidget {
  const SignaturePadScreen({super.key, this.kind = SignatureKind.signature});

  final SignatureKind kind;

  @override
  State<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends State<SignaturePadScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this)..addListener(() => setState(() {}));
  final List<List<Offset>> _strokes = [];
  Color _ink = const Color(0xFF111827);
  final _typed = TextEditingController();
  Uint8List? _imported;
  bool _saving = false;

  bool get _hasContent => switch (_tabs.index) {
    0 => _strokes.any((s) => s.isNotEmpty),
    1 => _typed.text.trim().isNotEmpty,
    _ => _imported != null,
  };

  Future<Uint8List> _renderDrawn() async {
    final all = _strokes.expand((s) => s).toList();
    final minX = all.map((e) => e.dx).reduce(math.min) - 8;
    final minY = all.map((e) => e.dy).reduce(math.min) - 8;
    final maxX = all.map((e) => e.dx).reduce(math.max) + 8;
    final maxY = all.map((e) => e.dy).reduce(math.max) + 8;
    const scale = 3.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    canvas.translate(-minX, -minY);
    final paint = Paint()
      ..color = _ink
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in _strokes) {
      canvas.drawPath(_smooth(s), paint);
    }
    final pic = recorder.endRecording();
    final image = await pic.toImage(((maxX - minX) * scale).ceil(), ((maxY - minY) * scale).ceil());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<Uint8List> _renderTyped() async {
    final text = _typed.text.trim();
    final style = TextStyle(fontFamily: 'Signature', fontSize: 120, color: _ink);
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    tp.paint(canvas, const Offset(16, 8));
    final image = await recorder.endRecording().toImage((tp.width + 32).ceil(), (tp.height + 16).ceil());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Makes a light background transparent and crops to the ink.
  Uint8List _cleanImported(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('Unsupported image');
    var im = decoded.convert(numChannels: 4);
    if (im.width > 1600) im = img.copyResize(im, width: 1600);
    var minX = im.width, minY = im.height, maxX = 0, maxY = 0;
    for (final px in im) {
      final lum = 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
      if (lum > 200) {
        px.a = 0;
      } else {
        // Soft edge for anti-aliasing between ink and paper.
        px.a = lum > 150 ? ((200 - lum) / 50 * 255).round() : 255;
        minX = math.min(minX, px.x);
        minY = math.min(minY, px.y);
        maxX = math.max(maxX, px.x);
        maxY = math.max(maxY, px.y);
      }
    }
    if (maxX <= minX || maxY <= minY) throw const FormatException('No signature found in the image');
    final cropped = img.copyCrop(im, x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
    return Uint8List.fromList(img.encodePng(cropped));
  }

  Path _smooth(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts.first.dx, pts.first.dy);
    if (pts.length == 1) {
      path.lineTo(pts.first.dx + 0.1, pts.first.dy);
      return path;
    }
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = (pts[i] + pts[i + 1]) / 2;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final png = switch (_tabs.index) {
        0 => await _renderDrawn(),
        1 => await _renderTyped(),
        _ => _imported!,
      };
      final saved = await SignatureStore.shared().save(png, widget.kind);
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.kind == SignatureKind.signature ? 'Create signature' : 'Create initials';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Draw'), Tab(text: 'Type'), Tab(text: 'Image')]),
        actions: [
          TextButton(onPressed: _hasContent && !_saving ? _save : null, child: const Text('Done')),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [_drawTab(), _typeTab(), _imageTab()],
            ),
          ),
          if (_tabs.index != 2)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in const [Color(0xFF111827), Color(0xFF1D4ED8), Color(0xFFB91C1C)])
                      GestureDetector(
                        onTap: () => setState(() => _ink = c),
                        child: Container(
                          width: 32,
                          height: 32,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: _ink == c ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 3),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _drawTab() => Column(
    children: [
      Expanded(
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.black12)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: GestureDetector(
              onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
              onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
              child: CustomPaint(
                painter: _PadPainter(_strokes, _ink, _smooth),
                child: Stack(
                  children: [
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: 48,
                      child: Container(height: 1, color: Colors.black26),
                    ),
                    if (_strokes.isEmpty)
                      const Center(child: Text('Sign here', style: TextStyle(color: Colors.black38, fontSize: 18))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      TextButton.icon(onPressed: () => setState(_strokes.clear), icon: const Icon(Icons.clear), label: const Text('Clear')),
    ],
  );

  Widget _typeTab() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        TextField(
          controller: _typed,
          decoration: InputDecoration(hintText: widget.kind == SignatureKind.signature ? 'Your full name' : 'Your initials'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 24),
        Container(
          height: 140,
          width: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.black12)),
          child: FittedBox(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_typed.text.isEmpty ? 'Preview' : _typed.text, style: TextStyle(fontFamily: 'Signature', fontSize: 56, color: _typed.text.isEmpty ? Colors.black26 : _ink)),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _imageTab() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_imported != null)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 200),
              child: Image.memory(_imported!),
            )
          else
            const Text('Import a photo of your signature on white paper.\nThe background is removed automatically.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async {
              final r = await pickLocalFile(type: FileType.image);
              if (r == null) return;
              final path = r.path;
              try {
                final cleaned = _cleanImported(await File(path).readAsBytes());
                setState(() => _imported = cleaned);
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
              }
            },
            icon: const Icon(Icons.image_outlined),
            label: const Text('Choose image'),
          ),
        ],
      ),
    ),
  );
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color, this.smooth);

  final List<List<Offset>> strokes;
  final Color color;
  final Path Function(List<Offset>) smooth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      canvas.drawPath(smooth(s), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PadPainter old) => true;
}

/// Lets the user pick a saved signature (or create a new one).
Future<SavedSignature?> pickSignature(BuildContext context, SignatureKind kind) async {
  final store = SignatureStore.shared();
  return showModalBottomSheet<SavedSignature>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final saved = store.list(kind);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(kind == SignatureKind.signature ? 'Signatures' : 'Initials', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              for (final s in saved)
                ListTile(
                  title: Container(
                    height: 56,
                    alignment: Alignment.centerLeft,
                    color: Colors.white,
                    padding: const EdgeInsets.all(4),
                    child: Image.file(s.file, fit: BoxFit.contain),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await store.delete(s);
                      setState(() {});
                    },
                  ),
                  onTap: () => Navigator.pop(ctx, s),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(kind == SignatureKind.signature ? 'Create new signature' : 'Create new initials'),
                onTap: () async {
                  final created = await Navigator.of(ctx).push<SavedSignature>(MaterialPageRoute(builder: (_) => SignaturePadScreen(kind: kind)));
                  if (created != null && ctx.mounted) Navigator.pop(ctx, created);
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Pixel size of a PNG.
Future<Size> imageFileSize(File f) async {
  final codec = await ui.instantiateImageCodec(await f.readAsBytes());
  final frame = await codec.getNextFrame();
  final s = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  frame.image.dispose();
  return s;
}
