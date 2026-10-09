import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/native/pdf_engine.dart';
import '../../../core/services.dart';
import '../../common/dialogs.dart';
import '../viewer_screen.dart';
import '../viewer_state.dart';
import '../widgets/color_palette.dart';
import '../widgets/navigator_sheet.dart';
import '../widgets/selection_box.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Saves pending ink strokes as Ink annotations (one per page).
Future<void> commitInk(ViewerHost host) async {
  final vs = host.viewerState;
  if (vs.pendingStrokes.isEmpty) return;
  final strokes = List<InkStroke>.from(vs.pendingStrokes);
  vs.pendingStrokes.clear();
  vs.changed();
  final author = AppServices.instance.settings.authorName;
  final annots = <Map<String, Object?>>[];
  final byPage = <int, List<InkStroke>>{};
  for (final s in strokes) {
    byPage.putIfAbsent(s.page, () => []).add(s);
  }
  for (final e in byPage.entries) {
    final first = e.value.first;
    annots.add({
      'type': 'ink',
      'page': e.key,
      'paths': [
        for (final s in e.value)
          [
            for (final p in s.points) ...[p.dx, p.dy],
          ],
      ],
      'color': colorToInt(first.color),
      'strokeWidth': first.width,
      'opacity': first.opacity,
      'author': author,
    });
  }
  await host.edit(
    'Add drawing',
    (i, o) => PdfEngine.instance.addAnnotations(i, o, annots, password: host.session.password),
  );
}

Future<void> deleteAnnotation(ViewerHost host, AnnotInfo a) async {
  host.viewerState.select(null);
  await host.edit(
    'Delete ${a.typeLabel.toLowerCase()}',
    (i, o) => PdfEngine.instance.deleteAnnotations(i, o, [(page: a.page, id: a.id)], password: host.session.password),
  );
}

/// Per-page interaction layer for comment tools.
class CommentLayer extends StatefulWidget {
  const CommentLayer({super.key, required this.host, required this.page, required this.scale, required this.size});

  final ViewerHost host;
  final PdfPage page;
  final double scale;
  final Size size;

  @override
  State<CommentLayer> createState() => _CommentLayerState();
}

final _wordChar = RegExp(r"[\p{L}\p{N}_\-’']", unicode: true);

class _CommentLayerState extends State<CommentLayer> {
  InkStroke? _current;
  Offset? _dragStart;
  Offset? _dragEnd;
  PdfPageText? _text;
  List<Rect> _markupPreview = const [];
  (int, int)? _markupRange;

  ViewerHost get host => widget.host;
  ViewerState get vs => host.viewerState;
  int get pageIndex => widget.page.pageNumber - 1;

  Offset _toPage(Offset local) => local / widget.scale;

  @override
  void initState() {
    super.initState();
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

  Future<PdfPageText?> _ensureText() async => _text ??= await widget.page.loadStructuredText();

  AnnotInfo? _hit(Offset p) {
    final list = host.annotations.where((a) => a.page == pageIndex && !a.isLink).toList().reversed;
    for (final a in list) {
      if (a.rect.inflate(6).contains(p)) return a;
    }
    return null;
  }

  // ---------------------------------------------------------------- taps

  Future<void> _onTapUp(TapUpDetails d) async {
    final p = _toPage(d.localPosition);
    switch (vs.commentTool) {
      case CommentTool.select:
        final a = _hit(p);
        vs.select(a);
        if (a != null) _showAnnotationActions(a);
      case CommentTool.note:
        final text = await showTextInputDialog(
          context,
          title: 'Add note',
          hint: 'Comment',
          confirmLabel: 'Post',
          maxLines: 5,
        );
        if (text == null) return;
        await host.edit(
          'Add note',
          (i, o) => PdfEngine.instance.addAnnotations(i, o, [
            {
              'type': 'note',
              'page': pageIndex,
              'x': p.dx - 11,
              'y': p.dy - 11,
              'contents': text,
              'color': colorToInt(vs.color),
              'author': AppServices.instance.settings.authorName,
            },
          ], password: host.session.password),
        );
      case CommentTool.freeText:
        final text = await showTextInputDialog(
          context,
          title: 'Add text',
          hint: 'Type here',
          confirmLabel: 'Add',
          maxLines: 6,
        );
        if (text == null || text.trim().isEmpty) return;
        final lines = text.split('\n');
        final longest = lines.fold<int>(0, (m, l) => math.max(m, l.length));
        final w = math.min(widget.page.width - p.dx - 4, math.max(60.0, longest * vs.fontSize * 0.55 + 8));
        final h =
            (lines.length + (longest * vs.fontSize * 0.55 > w ? (longest * vs.fontSize * 0.55 / w).ceil() : 0)) *
                vs.fontSize *
                1.25 +
            8;
        await host.edit(
          'Add text',
          (i, o) => PdfEngine.instance.addAnnotations(i, o, [
            {
              'type': 'freetext',
              'page': pageIndex,
              'rect': [p.dx, p.dy, p.dx + w, p.dy + h],
              'text': text,
              'fontSize': vs.fontSize,
              'color': colorToInt(vs.inkColor),
              'author': AppServices.instance.settings.authorName,
            },
          ], password: host.session.password),
        );
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- drags

  void _onPanStart(DragStartDetails d) {
    final p = _toPage(d.localPosition);
    final tool = vs.commentTool;
    if (tool == CommentTool.ink) {
      _current = InkStroke(pageIndex, vs.inkColor, vs.strokeWidth, vs.opacity)..points.add(p);
    } else {
      _dragStart = p;
      _dragEnd = p;
    }
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final p = _toPage(d.localPosition);
    final tool = vs.commentTool;
    if (tool == CommentTool.ink) {
      _current?.points.add(p);
    } else {
      _dragEnd = p;
      if (tool.isTextMarkup) _updateMarkupPreview();
    }
    setState(() {});
  }

  Future<void> _onPanEnd(DragEndDetails d) async {
    final tool = vs.commentTool;
    if (tool == CommentTool.ink) {
      final s = _current;
      _current = null;
      if (s != null && s.points.isNotEmpty) {
        vs.pendingStrokes.add(s);
        vs.changed();
      }
      return;
    }
    final a = _dragStart;
    final b = _dragEnd;
    _dragStart = null;
    _dragEnd = null;
    if (a == null || b == null) return;
    if (tool.isTextMarkup) {
      final rects = _markupPreview;
      setState(() => _markupPreview = const []);
      if (rects.isEmpty) return;
      await _commitMarkup(tool, rects);
      return;
    }
    final rect = Rect.fromPoints(a, b);
    if (rect.width < 3 && rect.height < 3) {
      setState(() {});
      return;
    }
    final author = AppServices.instance.settings.authorName;
    final Map<String, Object?> annot = switch (tool) {
      CommentTool.rect ||
      CommentTool.ellipse => {'type': tool.annotationType, 'rect': rectToList(rect), 'strokeWidth': vs.strokeWidth},
      _ => {
        'type': tool.annotationType,
        'points': [a.dx, a.dy, b.dx, b.dy],
        'strokeWidth': vs.strokeWidth,
      },
    };
    annot.addAll({'page': pageIndex, 'color': colorToInt(vs.inkColor), 'opacity': vs.opacity, 'author': author});
    await host.edit(
      'Add ${tool.label.toLowerCase()}',
      (i, o) => PdfEngine.instance.addAnnotations(i, o, [annot], password: host.session.password),
    );
  }

  Future<void> _updateMarkupPreview() async {
    final text = await _ensureText();
    final a = _dragStart, b = _dragEnd;
    if (text == null || a == null || b == null) return;
    int? nearest(Offset p) {
      int? best;
      var bestD = double.infinity;
      for (var i = 0; i < text.charRects.length; i++) {
        final r = text.charRects[i].toRect(page: widget.page);
        if (r.width <= 0) continue;
        final dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0.0);
        final dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0.0);
        final dist = dx * dx + dy * dy * 4;
        if (dist < bestD) {
          bestD = dist;
          best = i;
        }
      }
      return bestD < 900 ? best : null;
    }

    final i0 = nearest(a), i1 = nearest(b);
    if (i0 == null || i1 == null) {
      setState(() => _markupPreview = const []);
      return;
    }
    var s = math.min(i0, i1), e = math.max(i0, i1) + 1;
    // Snap to whole words like Acrobat.
    bool isWord(int i) => i >= 0 && i < text.fullText.length && _wordChar.hasMatch(text.fullText[i]);
    while (isWord(s - 1)) {
      s--;
    }
    while (isWord(e)) {
      e++;
    }
    if (_markupRange == (s, e)) return;
    _markupRange = (s, e);
    final range = PdfPageTextRange(pageText: text, start: s, end: e);
    if (!mounted) return;
    setState(() => _markupPreview = lineRectsForRange(range, widget.page));
  }

  Future<void> _commitMarkup(CommentTool tool, List<Rect> rects) async {
    _markupRange = null;
    final color = tool == CommentTool.highlight ? vs.color : vs.inkColor;
    await host.edit(
      'Add ${tool.label.toLowerCase()}',
      (i, o) => PdfEngine.instance.addAnnotations(i, o, [
        {
          'type': tool.annotationType,
          'page': pageIndex,
          'rects': rects.map(rectToList).toList(),
          'color': colorToInt(color),
          'opacity': 1.0,
          'author': AppServices.instance.settings.authorName,
        },
      ], password: host.session.password),
    );
  }

  // ---------------------------------------------------------------- selection actions

  Future<void> _showAnnotationActions(AnnotInfo a) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(a.icon, color: a.color),
              title: Text(a.typeLabel),
              subtitle: Text(
                [if (a.author != null) a.author!, if (a.contents?.isNotEmpty == true) a.contents!].join(' · '),
                maxLines: 2,
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Symbols.edit_note),
              title: Text(a.type == 'FreeText' ? 'Edit text' : 'Edit comment'),
              onTap: () => Navigator.pop(ctx, 'comment'),
            ),
            ListTile(
              leading: const Icon(Symbols.palette),
              title: const Text('Change color'),
              onTap: () => Navigator.pop(ctx, 'color'),
            ),
            ListTile(
              leading: const Icon(Symbols.open_with),
              title: const Text('Move or resize'),
              subtitle: const Text('Drag the box or its corners'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: Icon(Symbols.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'comment':
        if (a.type == 'Text') {
          vs.select(null);
          await showNoteDialog(host, a);
        } else {
          final text = await showTextInputDialog(
            context,
            title: a.type == 'FreeText' ? 'Edit text' : 'Comment',
            initial: a.contents ?? '',
            maxLines: 6,
          );
          vs.select(null);
          if (text == null) return;
          await host.edit(
            'Edit comment',
            (i, o) => PdfEngine.instance.updateAnnotation(
              i,
              o,
              page: a.page,
              id: a.id,
              contents: text,
              password: host.session.password,
            ),
          );
        }
      case 'color':
        Color? chosen;
        await showStyleSheet(context, color: a.color ?? vs.color, onColor: (c) => chosen = c);
        vs.select(null);
        if (chosen != null) {
          await host.edit(
            'Change color',
            (i, o) => PdfEngine.instance.updateAnnotation(
              i,
              o,
              page: a.page,
              id: a.id,
              color: chosen,
              password: host.session.password,
            ),
          );
        }
      case 'delete':
        await deleteAnnotation(host, a);
      case 'move':
        break; // keep selected; SelectionBox handles dragging
      default:
        vs.select(null);
    }
  }

  Future<void> _moveSelected(AnnotInfo a, Rect rect) async {
    vs.select(null);
    await host.edit(
      'Move ${a.typeLabel.toLowerCase()}',
      (i, o) => PdfEngine.instance.updateAnnotation(
        i,
        o,
        page: a.page,
        id: a.id,
        rect: rect,
        password: host.session.password,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tool = vs.commentTool;
    final s = widget.scale;
    final selected = vs.selectedAnnotation;
    final strokes = [...vs.pendingStrokes.where((e) => e.page == pageIndex), ?_current];
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CommentPainter(
                scale: s,
                strokes: strokes,
                tool: tool,
                dragStart: _dragStart,
                dragEnd: _dragEnd,
                color: vs.inkColor,
                width: vs.strokeWidth,
                markup: _markupPreview,
                markupColor: tool == CommentTool.highlight ? vs.color.withValues(alpha: 0.4) : vs.inkColor,
              ),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: tool == CommentTool.select ? HitTestBehavior.deferToChild : HitTestBehavior.opaque,
              onTapUp: _onTapUp,
              onPanStart: tool.isDrag || tool.isTextMarkup ? _onPanStart : null,
              onPanUpdate: tool.isDrag || tool.isTextMarkup ? _onPanUpdate : null,
              onPanEnd: tool.isDrag || tool.isTextMarkup ? _onPanEnd : null,
              child: tool == CommentTool.select
                  ? Stack(
                      children: [
                        for (final a in host.annotations.where((a) => a.page == pageIndex && !a.isLink))
                          Positioned.fromRect(
                            rect: scaleRect(a.rect.inflate(4), s),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                vs.select(a);
                                _showAnnotationActions(a);
                              },
                            ),
                          ),
                      ],
                    )
                  : const SizedBox.expand(),
            ),
          ),
          if (selected != null && selected.page == pageIndex)
            SelectionBox(
              key: ValueKey(selected.id),
              rect: selected.rect,
              scale: s,
              keepAspect: selected.type == 'Stamp',
              onChanged: (r) => _moveSelected(selected, r),
            ),
        ],
      ),
    );
  }
}

class _CommentPainter extends CustomPainter {
  _CommentPainter({
    required this.scale,
    required this.strokes,
    required this.tool,
    required this.dragStart,
    required this.dragEnd,
    required this.color,
    required this.width,
    required this.markup,
    required this.markupColor,
  });

  final double scale;
  final List<InkStroke> strokes;
  final CommentTool tool;
  final Offset? dragStart;
  final Offset? dragEnd;
  final Color color;
  final double width;
  final List<Rect> markup;
  final Color markupColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color.withValues(alpha: s.opacity)
        ..strokeWidth = s.width * scale
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = s.points[i] * scale;
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (s.points.length == 1) path.lineTo(s.points[0].dx * scale + 0.1, s.points[0].dy * scale);
      canvas.drawPath(path, paint);
    }
    for (final r in markup) {
      final rr = scaleRect(r, scale);
      if (tool == CommentTool.highlight) {
        canvas.drawRect(rr, Paint()..color = markupColor);
      } else {
        final y = tool == CommentTool.strikeout ? rr.center.dy : rr.bottom - 1;
        canvas.drawLine(
          Offset(rr.left, y),
          Offset(rr.right, y),
          Paint()
            ..color = markupColor
            ..strokeWidth = 2,
        );
      }
    }
    final a = dragStart, b = dragEnd;
    if (a == null || b == null || tool.isTextMarkup) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width * scale
      ..style = PaintingStyle.stroke;
    final pa = a * scale, pb = b * scale;
    switch (tool) {
      case CommentTool.rect:
        canvas.drawRect(Rect.fromPoints(pa, pb), paint);
      case CommentTool.ellipse:
        canvas.drawOval(Rect.fromPoints(pa, pb), paint);
      case CommentTool.line:
      case CommentTool.arrow:
        canvas.drawLine(pa, pb, paint);
        if (tool == CommentTool.arrow) {
          final ang = math.atan2(pb.dy - pa.dy, pb.dx - pa.dx);
          final len = math.max(8.0, width * 4) * scale;
          for (final d in [math.pi * 5 / 6, -math.pi * 5 / 6]) {
            canvas.drawLine(pb, pb + Offset(math.cos(ang + d), math.sin(ang + d)) * len, paint);
          }
        }
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _CommentPainter old) => true;
}

/// Bottom toolbar for comment mode (Acrobat's commenting bar).
class CommentToolbar extends StatelessWidget {
  const CommentToolbar({super.key, required this.host});

  final ViewerHost host;

  static const _tools = [
    CommentTool.select,
    CommentTool.note,
    CommentTool.highlight,
    CommentTool.underline,
    CommentTool.strikeout,
    CommentTool.squiggly,
    CommentTool.freeText,
    CommentTool.ink,
    CommentTool.rect,
    CommentTool.ellipse,
    CommentTool.line,
    CommentTool.arrow,
  ];

  @override
  Widget build(BuildContext context) {
    final vs = host.viewerState;
    final scheme = Theme.of(context).colorScheme;
    final tool = vs.commentTool;
    final settings = AppServices.instance.settings;
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tool != CommentTool.select)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Row(
                  children: [
                    Text(tool.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (tool.isDrag)
                      IconButton(
                        tooltip: vs.panLocked ? 'Scroll the page' : 'Draw',
                        icon: Icon(vs.panLocked ? Symbols.pan_tool : Symbols.edit),
                        onPressed: vs.togglePanLock,
                      ),
                    if (tool != CommentTool.note)
                      InkWell(
                        onTap: () => showStyleSheet(
                          context,
                          color: tool == CommentTool.highlight ? vs.color : vs.inkColor,
                          onColor: (c) {
                            if (tool == CommentTool.highlight) {
                              vs.color = c;
                              settings.annotationColor = c.toARGB32();
                            } else {
                              vs.inkColor = c;
                              settings.inkColor = c.toARGB32();
                            }
                            vs.changed();
                          },
                          width: tool.isDrag ? vs.strokeWidth : null,
                          onWidth: (w) {
                            vs.strokeWidth = w;
                            settings.inkWidth = w;
                            vs.changed();
                          },
                          opacity: tool.isDrag ? vs.opacity : null,
                          onOpacity: (o) {
                            vs.opacity = o;
                            vs.changed();
                          },
                          fontSize: tool == CommentTool.freeText ? vs.fontSize : null,
                          onFontSize: (f) {
                            vs.fontSize = f;
                            vs.changed();
                          },
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: tool == CommentTool.highlight ? vs.color : vs.inkColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.black26),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Symbols.tune, size: 18),
                            ],
                          ),
                        ),
                      ),
                    if (vs.pendingStrokes.isNotEmpty) ...[
                      TextButton(
                        onPressed: () {
                          vs.pendingStrokes.removeLast();
                          vs.changed();
                        },
                        child: const Text('Undo stroke'),
                      ),
                      FilledButton.icon(
                        onPressed: () => commitInk(host),
                        icon: const Icon(Symbols.check),
                        label: const Text('Save'),
                      ),
                    ],
                  ],
                ),
              ),
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final t in _tools)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                      child: Tooltip(
                        message: t.label,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            if (vs.pendingStrokes.isNotEmpty && t != CommentTool.ink) await commitInk(host);
                            vs.commentTool = t;
                          },
                          child: Container(
                            width: 48,
                            decoration: BoxDecoration(
                              color: t == tool ? scheme.primary.withValues(alpha: 0.14) : null,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(t.icon, color: t == tool ? scheme.primary : scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
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

/// Lists all comments; tapping navigates, long-press deletes.
Future<void> showCommentsList(ViewerHost host) async {
  host.refreshAnnotations();
  await showModalBottomSheet<void>(
    context: host.context,
    isScrollControlled: true,
    builder: (ctx) {
      final annots = host.annotations.where((a) => !a.isLink).toList();
      return SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [Text('Comments (${annots.length})', style: Theme.of(ctx).textTheme.titleMedium)]),
            ),
            const Divider(),
            Expanded(
              child: annots.isEmpty
                  ? const Center(child: Text('No comments yet'))
                  : ListView(
                      children: [
                        for (final a in annots)
                          ListTile(
                            leading: Icon(a.icon, color: a.color),
                            title: Text(
                              a.contents?.isNotEmpty == true ? a.contents! : a.typeLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('Page ${a.page + 1}${a.author != null ? ' · ${a.author}' : ''}'),
                            onTap: () {
                              Navigator.pop(ctx);
                              host.controller.goToPage(pageNumber: a.page + 1);
                            },
                            trailing: IconButton(
                              icon: const Icon(Symbols.delete_outline),
                              onPressed: () {
                                Navigator.pop(ctx);
                                deleteAnnotation(host, a);
                              },
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      );
    },
  );
}
