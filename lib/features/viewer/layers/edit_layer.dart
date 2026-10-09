import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import '../../../core/file_picking.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/native/pdf_engine.dart';
import '../../common/dialogs.dart';
import '../../tools/stamp_dialogs.dart';
import '../viewer_screen.dart';
import '../viewer_state.dart';
import '../widgets/color_palette.dart';
import '../widgets/selection_box.dart';

class _PageObjects {
  _PageObjects(this.texts, this.images);

  final List<Map<String, dynamic>> texts;
  final List<Map<String, dynamic>> images;
}

final _cache = <String, Future<_PageObjects>>{};

Future<_PageObjects> _loadObjects(ViewerHost host, int pageIndex) {
  final key = '${host.session.path}#${host.session.revision}#$pageIndex';
  if (_cache.length > 40) _cache.clear();
  return _cache.putIfAbsent(key, () async {
    final engine = PdfEngine.instance;
    final pw = host.session.password;
    final texts = await engine.getTextBlocks(host.session.path, pageIndex, password: pw);
    final images = await engine.getImageObjects(host.session.path, pageIndex, password: pw);
    return _PageObjects(texts, images);
  });
}

/// Per-page layer for "Edit PDF": edit existing text and images, add new content.
class EditLayer extends StatefulWidget {
  const EditLayer({super.key, required this.host, required this.page, required this.scale, required this.size});

  final ViewerHost host;
  final PdfPage page;
  final double scale;
  final Size size;

  @override
  State<EditLayer> createState() => _EditLayerState();
}

class _EditLayerState extends State<EditLayer> {
  late Future<_PageObjects> _objects;
  Offset? _dragStart;
  Offset? _dragEnd;
  int? _movingImage;

  ViewerHost get host => widget.host;
  ViewerState get vs => host.viewerState;
  int get pageIndex => widget.page.pageNumber - 1;
  String? get pw => host.session.password;

  @override
  void initState() {
    super.initState();
    _objects = _loadObjects(host, pageIndex);
    vs.addListener(_changed);
  }

  @override
  void dispose() {
    vs.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Offset _toPage(Offset local) => local / widget.scale;

  // ------------------------------------------------------------ text editing

  Future<void> _editText(Map<String, dynamic> block) async {
    final result = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TextBlockEditor(block: block),
    );
    if (result == null) return;
    final edit = {'id': block['id'], ...result};
    await host.edit(result['text'] == '' ? 'Delete text' : 'Edit text', (i, o) => PdfEngine.instance.editTextBlocks(i, o, pageIndex, [edit], password: pw));
  }

  // ------------------------------------------------------------ images

  Future<void> _imageActions(Map<String, dynamic> img) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text('Image ${img['pw']}×${img['ph']} px')),
            const Divider(),
            if (img['inline'] != true) ...[
              ListTile(leading: const Icon(Icons.open_with), title: const Text('Move or resize'), onTap: () => Navigator.pop(ctx, 'move')),
              ListTile(leading: const Icon(Icons.find_replace), title: const Text('Replace image'), onTap: () => Navigator.pop(ctx, 'replace')),
            ],
            ListTile(leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error), title: const Text('Delete image'), onTap: () => Navigator.pop(ctx, 'delete')),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final id = img['id'] as int;
    switch (action) {
      case 'move':
        setState(() => _movingImage = id);
      case 'replace':
        final path = await _pickImage();
        if (path == null) return;
        await host.edit('Replace image', (i, o) => PdfEngine.instance.editImage(i, o, page: pageIndex, id: id, action: 'replace', imagePath: path, password: pw));
      case 'delete':
        await host.edit('Delete image', (i, o) => PdfEngine.instance.editImage(i, o, page: pageIndex, id: id, action: 'delete', password: pw));
    }
  }

  Future<String?> _pickImage() async {
    final r = await pickLocalFile(type: FileType.image);
    return r?.path;
  }

  Future<Size?> _imageSize(String path) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final frame = await codec.getNextFrame();
    final s = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    return s;
  }

  // ------------------------------------------------------------ add content

  Future<void> _onTapUp(TapUpDetails d) async {
    final p = _toPage(d.localPosition);
    switch (vs.editTool) {
      case EditTool.select:
        final objs = await _objects;
        for (final t in objs.texts) {
          if (listToRect(t['rect'] as List).inflate(3).contains(p)) return _editText(t);
        }
        for (final img in objs.images.reversed) {
          if (listToRect(img['rect'] as List).contains(p)) return _imageActions(img);
        }
      case EditTool.addText:
        final r = await showModalBottomSheet<Map<String, Object?>>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => const _TextBlockEditor(block: null),
        );
        if (r == null || (r['text'] as String).trim().isEmpty) return;
        final fontSize = (r['fontSize'] as num?)?.toDouble() ?? 12;
        await host.edit('Add text', (i, o) => PdfEngine.instance.addContent(i, o, [
          {
            'type': 'text',
            'page': pageIndex,
            'x': p.dx,
            'y': p.dy - fontSize / 2,
            'width': widget.page.width - p.dx - 24,
            ...r,
          },
        ], password: pw));
        vs.editTool = EditTool.select;
      case EditTool.addImage:
        final path = await _pickImage();
        if (path == null) return;
        final size = await _imageSize(path);
        if (size == null) return;
        final w = math.min(200.0, widget.page.width * 0.6);
        final h = w * size.height / size.width;
        final rect = Rect.fromLTWH(p.dx - w / 2, p.dy - h / 2, w, h);
        await host.edit('Add image', (i, o) => PdfEngine.instance.addContent(i, o, [
          {'type': 'image', 'page': pageIndex, 'rect': rectToList(rect), 'imagePath': path},
        ], password: pw));
        vs.editTool = EditTool.select;
      default:
        break;
    }
  }

  void _onPanStart(DragStartDetails d) => setState(() => _dragStart = _dragEnd = _toPage(d.localPosition));
  void _onPanUpdate(DragUpdateDetails d) => setState(() => _dragEnd = _toPage(d.localPosition));

  Future<void> _onPanEnd(DragEndDetails d) async {
    final a = _dragStart, b = _dragEnd;
    setState(() => _dragStart = _dragEnd = null);
    if (a == null || b == null || (a - b).distance < 4) return;
    final tool = vs.editTool;
    if (tool == EditTool.link) {
      await _addLink(Rect.fromPoints(a, b));
      return;
    }
    final item = <String, Object?>{
      'page': pageIndex,
      'strokeColor': colorToInt(vs.inkColor),
      'strokeWidth': vs.strokeWidth,
      'opacity': vs.opacity,
    };
    switch (tool) {
      case EditTool.rect:
        item.addAll({'type': 'rect', 'rect': rectToList(Rect.fromPoints(a, b))});
      case EditTool.ellipse:
        item.addAll({'type': 'ellipse', 'rect': rectToList(Rect.fromPoints(a, b))});
      case EditTool.line:
        item.addAll({'type': 'line', 'points': [a.dx, a.dy, b.dx, b.dy]});
      case EditTool.arrow:
        item.addAll({'type': 'arrow', 'points': [a.dx, a.dy, b.dx, b.dy]});
      default:
        return;
    }
    await host.edit('Add shape', (i, o) => PdfEngine.instance.addContent(i, o, [item], password: pw));
  }

  Future<void> _addLink(Rect rect) async {
    final count = host.document?.pages.length ?? 1;
    final urlCtl = TextEditingController(text: 'https://');
    final pageCtl = TextEditingController();
    var toPage = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add link'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('Web page')), ButtonSegment(value: true, label: Text('Page'))],
                selected: {toPage},
                onSelectionChanged: (v) => setState(() => toPage = v.first),
              ),
              const SizedBox(height: 12),
              if (!toPage)
                TextField(controller: urlCtl, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL'))
              else
                TextField(controller: pageCtl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Page number (1–$count)')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final annot = <String, Object?>{'type': 'link', 'page': pageIndex, 'rect': rectToList(rect)};
    if (toPage) {
      final n = int.tryParse(pageCtl.text.trim());
      if (n == null || n < 1 || n > count) {
        if (mounted) showSnack(context, 'Invalid page number', error: true);
        return;
      }
      annot['targetPage'] = n - 1;
    } else {
      final url = urlCtl.text.trim();
      if (url.isEmpty || url == 'https://') return;
      annot['url'] = url.contains('://') || url.startsWith('mailto:') ? url : 'https://$url';
    }
    await host.edit('Add link', (i, o) => PdfEngine.instance.addAnnotations(i, o, [annot], password: pw));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    final tool = vs.editTool;
    final isDrag = tool == EditTool.rect || tool == EditTool.ellipse || tool == EditTool.line || tool == EditTool.arrow || tool == EditTool.link;
    final links = host.annotations.where((a) => a.page == pageIndex && a.isLink).toList();
    return Positioned.fill(
      child: FutureBuilder<_PageObjects>(
        future: _objects,
        builder: (context, snap) {
          final objs = snap.data;
          return Stack(
            children: [
              if (objs != null && tool == EditTool.select) ...[
                for (final t in objs.texts)
                  Positioned.fromRect(
                    rect: scaleRect(listToRect(t['rect'] as List).inflate(2), s),
                    child: IgnorePointer(
                      child: Container(decoration: BoxDecoration(border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.6)))),
                    ),
                  ),
                for (final img in objs.images)
                  Positioned.fromRect(
                    rect: scaleRect(listToRect(img['rect'] as List), s),
                    child: IgnorePointer(
                      child: Container(decoration: BoxDecoration(border: Border.all(color: const Color(0xFF8B5CF6), width: 1.5))),
                    ),
                  ),
              ],
              for (final l in links)
                Positioned.fromRect(
                  rect: scaleRect(l.rect, s),
                  child: GestureDetector(
                    onLongPress: () => _linkActions(l),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.teal, width: 1), color: Colors.teal.withValues(alpha: 0.08)),
                    ),
                  ),
                ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: _onTapUp,
                  onPanStart: isDrag ? _onPanStart : null,
                  onPanUpdate: isDrag ? _onPanUpdate : null,
                  onPanEnd: isDrag ? _onPanEnd : null,
                ),
              ),
              if (_dragStart != null && _dragEnd != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _ShapePreview(tool, _dragStart! * s, _dragEnd! * s, vs.inkColor, vs.strokeWidth * s)),
                  ),
                ),
              if (_movingImage != null && objs != null)
                SelectionBox(
                  rect: listToRect(objs.images.firstWhere((i) => i['id'] == _movingImage)['rect'] as List),
                  scale: s,
                  color: const Color(0xFF8B5CF6),
                  onChanged: (r) async {
                    final id = _movingImage!;
                    setState(() => _movingImage = null);
                    await host.edit('Move image', (i, o) => PdfEngine.instance.editImage(i, o, page: pageIndex, id: id, action: 'move', rect: r, password: pw));
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _linkActions(AnnotInfo l) async {
    final del = await confirmDialog(
      context,
      title: 'Remove link?',
      message: l.url ?? (l.targetPage != null ? 'Go to page ${l.targetPage! + 1}' : null),
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!del) return;
    await host.edit('Remove link', (i, o) => PdfEngine.instance.deleteAnnotations(i, o, [(page: l.page, id: l.id)], password: pw));
  }
}

class _ShapePreview extends CustomPainter {
  _ShapePreview(this.tool, this.a, this.b, this.color, this.width);

  final EditTool tool;
  final Offset a, b;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = tool == EditTool.link ? Colors.teal : color
      ..style = PaintingStyle.stroke
      ..strokeWidth = tool == EditTool.link ? 1.5 : width;
    switch (tool) {
      case EditTool.rect:
      case EditTool.link:
        canvas.drawRect(Rect.fromPoints(a, b), paint);
      case EditTool.ellipse:
        canvas.drawOval(Rect.fromPoints(a, b), paint);
      default:
        canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ShapePreview old) => true;
}

/// Bottom sheet to edit (or create) a block of text.
class _TextBlockEditor extends StatefulWidget {
  const _TextBlockEditor({required this.block});

  final Map<String, dynamic>? block;

  @override
  State<_TextBlockEditor> createState() => _TextBlockEditorState();
}

class _TextBlockEditorState extends State<_TextBlockEditor> {
  late final _text = TextEditingController(text: widget.block?['text'] as String? ?? '');
  late double _size = (widget.block?['fontSize'] as num?)?.toDouble().clamp(4, 96).toDouble() ?? 12;
  late bool _bold = widget.block?['bold'] as bool? ?? false;
  late bool _italic = widget.block?['italic'] as bool? ?? false;
  late bool _serif = widget.block?['serif'] as bool? ?? false;
  late Color _color = widget.block?['color'] == null ? Colors.black : Color(widget.block!['color'] as int);

  @override
  Widget build(BuildContext context) {
    final isNew = widget.block == null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(isNew ? 'Add text' : 'Edit text', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (!isNew && widget.block!['fontName'] != null)
                Text('Original font: ${widget.block!['fontName']}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                style: TextStyle(fontWeight: _bold ? FontWeight.bold : null, fontStyle: _italic ? FontStyle.italic : null, fontFamily: _serif ? 'serif' : null, color: _color),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton.filledTonal(isSelected: _bold, onPressed: () => setState(() => _bold = !_bold), icon: const Icon(Icons.format_bold)),
                  IconButton.filledTonal(isSelected: _italic, onPressed: () => setState(() => _italic = !_italic), icon: const Icon(Icons.format_italic)),
                  const SizedBox(width: 6),
                  ChoiceChip(label: const Text('Serif'), selected: _serif, onSelected: (v) => setState(() => _serif = v)),
                  const Spacer(),
                  Text('${_size.round()} pt'),
                ],
              ),
              Slider(value: _size, min: 4, max: 96, onChanged: (v) => setState(() => _size = v)),
              Wrap(
                children: [
                  for (final c in const [Colors.black, Color(0xFF374151), Color(0xFFE11D48), Color(0xFF2563EB), Color(0xFF16A34A), Color(0xFFF59E0B), Colors.white])
                    ColorDot(color: c, selected: c.toARGB32() == _color.toARGB32(), onTap: () => setState(() => _color = c), size: 26),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (!isNew)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: () => Navigator.pop(context, {'text': ''}),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, {
                      'text': _text.text,
                      'fontSize': _size,
                      'bold': _bold,
                      'italic': _italic,
                      'serif': _serif,
                      'color': colorToInt(_color),
                    }),
                    child: Text(isNew ? 'Add' : 'Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom toolbar for Edit PDF mode.
class EditToolbar extends StatelessWidget {
  const EditToolbar({super.key, required this.host});

  final ViewerHost host;

  @override
  Widget build(BuildContext context) {
    final vs = host.viewerState;
    final scheme = Theme.of(context).colorScheme;
    Widget tool(EditTool t, IconData icon, String label) {
      final sel = vs.editTool == t;
      return _ToolButton(icon: icon, label: label, selected: sel, onTap: () => vs.editTool = sel ? EditTool.select : t);
    }

    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      switch (vs.editTool) {
                        EditTool.select => 'Tap text or an image to edit it',
                        EditTool.addText => 'Tap where to add text',
                        EditTool.addImage => 'Tap where to place an image',
                        EditTool.link => 'Drag to draw the link area',
                        _ => 'Drag on the page to draw',
                      },
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (vs.editTool == EditTool.rect || vs.editTool == EditTool.ellipse || vs.editTool == EditTool.line || vs.editTool == EditTool.arrow)
                    IconButton(
                      icon: const Icon(Icons.palette_outlined),
                      onPressed: () => showStyleSheet(
                        context,
                        color: vs.inkColor,
                        onColor: (c) {
                          vs.inkColor = c;
                          vs.changed();
                        },
                        width: vs.strokeWidth,
                        onWidth: (w) {
                          vs.strokeWidth = w;
                          vs.changed();
                        },
                        opacity: vs.opacity,
                        onOpacity: (o) {
                          vs.opacity = o;
                          vs.changed();
                        },
                      ),
                    ),
                  if (vs.panLocked || vs.editTool != EditTool.select)
                    IconButton(tooltip: vs.panLocked ? 'Scroll' : 'Draw', icon: Icon(vs.panLocked ? Icons.pan_tool_outlined : Icons.edit), onPressed: vs.togglePanLock),
                ],
              ),
            ),
            SizedBox(
              height: 70,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  tool(EditTool.addText, Icons.title, 'Add text'),
                  tool(EditTool.addImage, Icons.add_photo_alternate_outlined, 'Add image'),
                  tool(EditTool.rect, Icons.crop_square, 'Rectangle'),
                  tool(EditTool.ellipse, Icons.circle_outlined, 'Oval'),
                  tool(EditTool.line, Icons.horizontal_rule, 'Line'),
                  tool(EditTool.arrow, Icons.arrow_right_alt, 'Arrow'),
                  tool(EditTool.link, Icons.link, 'Link'),
                  _ToolButton(icon: Icons.water_drop_outlined, label: 'Watermark', onTap: () => showWatermarkDialog(context, session: host.session)),
                  _ToolButton(icon: Icons.format_list_numbered, label: 'Page no.', onTap: () => showPageNumbersDialog(context, session: host.session)),
                  _ToolButton(icon: Icons.layers_clear_outlined, label: 'Remove marks', onTap: () => showRemoveArtifactsDialog(context, session: host.session)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 70,
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        decoration: BoxDecoration(color: selected ? scheme.primary.withValues(alpha: 0.14) : null, borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: selected ? scheme.primary : scheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
