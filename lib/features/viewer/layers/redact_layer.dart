import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/native/pdf_engine.dart';
import '../../common/dialogs.dart';
import '../viewer_screen.dart';
import '../viewer_state.dart';
import '../widgets/selection_box.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Per-page layer for marking redaction areas.
class RedactLayer extends StatefulWidget {
  const RedactLayer({super.key, required this.host, required this.page, required this.scale, required this.size});

  final ViewerHost host;
  final PdfPage page;
  final double scale;
  final Size size;

  @override
  State<RedactLayer> createState() => _RedactLayerState();
}

class _RedactLayerState extends State<RedactLayer> {
  Offset? _a, _b;

  ViewerState get vs => widget.host.viewerState;
  int get pageIndex => widget.page.pageNumber - 1;

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

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    final marks = vs.redactions[pageIndex] ?? const <Rect>[];
    return Positioned.fill(
      child: Stack(
        children: [
          if (vs.redactByArea)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => setState(() => _a = _b = d.localPosition / s),
                onPanUpdate: (d) => setState(() => _b = d.localPosition / s),
                onPanEnd: (_) {
                  final a = _a, b = _b;
                  setState(() => _a = _b = null);
                  if (a == null || b == null) return;
                  final r = Rect.fromPoints(a, b);
                  if (r.width < 3 || r.height < 3) return;
                  vs.redactions.putIfAbsent(pageIndex, () => []).add(r);
                  vs.changed();
                },
              ),
            ),
          for (var i = 0; i < marks.length; i++)
            Positioned.fromRect(
              rect: scaleRect(marks[i], s),
              child: GestureDetector(
                onTap: () {
                  marks.removeAt(i);
                  vs.changed();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.18),
                    border: Border.all(color: Colors.red, width: 1.5),
                  ),
                  child: const Align(
                    alignment: Alignment.topRight,
                    child: Icon(Symbols.close, size: 12, color: Colors.red),
                  ),
                ),
              ),
            ),
          if (_a != null && _b != null)
            Positioned.fromRect(
              rect: scaleRect(Rect.fromPoints(_a!, _b!), s),
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.red, width: 1.5),
                    color: Colors.red.withValues(alpha: 0.1),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class RedactToolbar extends StatelessWidget {
  const RedactToolbar({super.key, required this.host});

  final ViewerHost host;

  Future<void> _searchAndMark(BuildContext context) async {
    final q = await showTextInputDialog(
      context,
      title: 'Find text to redact',
      hint: 'Word, phrase, or e-mail',
      confirmLabel: 'Find',
    );
    if (q == null || q.trim().isEmpty) return;
    final doc = host.document;
    if (doc == null) return;
    final vs = host.viewerState;
    final matches = await runWithProgress(context, 'Searching…', () async {
      var n = 0;
      for (final page in doc.pages) {
        final text = await page.loadStructuredText();
        await for (final m in text.allMatches(q.trim(), caseInsensitive: true)) {
          final rects = lineRectsForRange(m, page);
          vs.redactions.putIfAbsent(page.pageNumber - 1, () => []).addAll(rects.map((r) => r.inflate(1)));
          n++;
        }
      }
      return n;
    });
    vs.changed();
    if (context.mounted && matches != null)
      showSnack(context, matches == 0 ? 'No matches found' : 'Marked $matches occurrence${matches == 1 ? '' : 's'}');
  }

  Future<void> _apply(BuildContext context) async {
    final vs = host.viewerState;
    var overlay = '';
    var removeMeta = true;
    var color = Colors.black;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Apply ${vs.redactionCount} redaction${vs.redactionCount == 1 ? '' : 's'}?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Text, images and drawings under the marked areas are permanently removed from the file. This cannot be undone after you leave the document.',
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(labelText: 'Overlay text (optional)', hintText: 'e.g. REDACTED'),
                  onChanged: (v) => overlay = v,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Fill'),
                    const SizedBox(width: 12),
                    for (final c in const [Colors.black, Colors.white, Color(0xFF991B1B)])
                      GestureDetector(
                        onTap: () => setState(() => color = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color == c ? Colors.blue : Colors.black26,
                              width: color == c ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: removeMeta,
                  onChanged: (v) => setState(() => removeMeta = v ?? true),
                  title: const Text('Also remove document metadata'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Redact')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final areas = {
      for (final e in vs.redactions.entries)
        if (e.value.isNotEmpty) e.key: List<Rect>.from(e.value),
    };
    final result = await host.edit(
      'Redact',
      (i, o) => PdfEngine.instance.redact(
        i,
        o,
        areas,
        password: host.session.password,
        fill: color,
        overlayText: overlay.trim().isEmpty ? null : overlay.trim(),
        removeMetadata: removeMeta,
      ),
    );
    if (result != null) {
      vs.redactions.clear();
      vs.changed();
      if (context.mounted) {
        showSnack(
          context,
          'Redacted: ${result['glyphs']} characters, ${result['images']} images, ${result['paths']} graphics, ${result['annotations']} annotations',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vs = host.viewerState;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, icon: Icon(Symbols.crop_free), label: Text('Area')),
                        ButtonSegment(value: false, icon: Icon(Symbols.text_fields), label: Text('Text')),
                      ],
                      selected: {vs.redactByArea},
                      onSelectionChanged: (v) => vs.setRedactByArea(v.first),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Find & mark',
                    onPressed: () => _searchAndMark(context),
                    icon: const Icon(Symbols.manage_search),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      vs.redactionCount == 0
                          ? (vs.redactByArea
                                ? 'Drag over content to mark it'
                                : 'Select text, then choose "Mark for redaction"')
                          : '${vs.redactionCount} area${vs.redactionCount == 1 ? '' : 's'} marked · tap a mark to remove it',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (vs.redactionCount > 0)
                    TextButton(
                      onPressed: () {
                        vs.redactions.clear();
                        vs.changed();
                      },
                      child: const Text('Clear'),
                    ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.black),
                    onPressed: vs.redactionCount == 0 ? null : () => _apply(context),
                    child: const Text('Apply'),
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
