import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/native/pdf_engine.dart';
import '../../../core/services.dart';
import '../../../core/util/format.dart';
import '../../common/dialogs.dart';
import '../../sign/signature_pad_screen.dart';
import '../../sign/signature_store.dart';
import '../viewer_screen.dart';
import '../viewer_state.dart';
import '../widgets/color_palette.dart';
import '../widgets/selection_box.dart';
import 'comment_layer.dart';
import 'package:material_symbols_icons/symbols.dart';

final _fieldCache = <String, Future<List<Map<String, dynamic>>>>{};

Future<List<Map<String, dynamic>>> loadFields(ViewerHost host) {
  final key = '${host.session.path}#${host.session.revision}';
  if (_fieldCache.length > 10) _fieldCache.clear();
  return _fieldCache.putIfAbsent(
    key,
    () => PdfEngine.instance
        .listFields(host.session.path, password: host.session.password)
        .catchError((_) => <Map<String, dynamic>>[]),
  );
}

/// Places a signature/initials image as a stamp annotation inside [area] (fitted, centered).
Future<void> placeSignature(ViewerHost host, int pageIndex, SavedSignature sig, Rect area) async {
  final size = await imageFileSize(sig.file);
  final ar = size.width / size.height;
  var w = area.width, h = area.width / ar;
  if (h > area.height) {
    h = area.height;
    w = h * ar;
  }
  final rect = Rect.fromCenter(center: area.center, width: w, height: h);
  await host.edit(
    sig.kind == SignatureKind.signature ? 'Add signature' : 'Add initials',
    (i, o) => PdfEngine.instance.addAnnotations(i, o, [
      {
        'type': 'stamp',
        'page': pageIndex,
        'rect': rectToList(rect),
        'imagePath': sig.file.path,
        'name': sig.kind == SignatureKind.signature ? 'Signature' : 'Initials',
        'author': AppServices.instance.settings.authorName,
      },
    ], password: host.session.password),
  );
}

/// Per-page layer for Fill & Sign: interactive form fields plus free placement tools.
class FillSignLayer extends StatefulWidget {
  const FillSignLayer({super.key, required this.host, required this.page, required this.scale, required this.size});

  final ViewerHost host;
  final PdfPage page;
  final double scale;
  final Size size;

  @override
  State<FillSignLayer> createState() => _FillSignLayerState();
}

class _FillSignLayerState extends State<FillSignLayer> {
  late final Future<List<Map<String, dynamic>>> _fields = loadFields(widget.host);

  ViewerHost get host => widget.host;
  ViewerState get vs => host.viewerState;
  int get pageIndex => widget.page.pageNumber - 1;
  String? get pw => host.session.password;

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

  Future<void> _fill(String name, Object? value, String label) =>
      host.edit(label, (i, o) => PdfEngine.instance.fillForm(i, o, {name: value}, password: pw));

  Future<void> _onField(Map<String, dynamic> f) async {
    if (f['readOnly'] == true) {
      showSnack(context, 'This field is read-only');
      return;
    }
    final name = f['name'] as String;
    final label = humanizeFieldName((f['label'] as String?) ?? name);
    switch (f['type']) {
      case 'text':
        final maxLen = f['maxLen'] as int? ?? -1;
        final v = await showTextInputDialog(
          context,
          title: label,
          initial: f['value'] as String? ?? '',
          maxLines: f['multiline'] == true ? 6 : 1,
          validator: (s) => maxLen > 0 && s.length > maxLen ? 'Maximum $maxLen characters' : null,
        );
        if (v != null) await _fill(name, v, 'Fill field');
      case 'checkbox':
        await _fill(name, !(f['value'] as bool? ?? false), 'Toggle checkbox');
      case 'radio':
        await _fill(name, f['onValue'], 'Select option');
      case 'combo':
      case 'list':
        final options = (f['options'] as List?)?.cast<String>() ?? const [];
        final exports = (f['exportValues'] as List?)?.cast<String>() ?? options;
        final current = (f['value'] as List?)?.cast<String>() ?? const [];
        final chosen = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (f['editable'] == true)
                  ListTile(
                    leading: const Icon(Symbols.edit),
                    title: const Text('Custom value…'),
                    onTap: () async {
                      final v = await showTextInputDialog(ctx, title: label);
                      if (ctx.mounted) Navigator.pop(ctx, v);
                    },
                  ),
                for (var i = 0; i < options.length; i++)
                  ListTile(
                    title: Text(options[i]),
                    trailing:
                        current.contains(exports.length > i ? exports[i] : options[i]) || current.contains(options[i])
                        ? const Icon(Symbols.check)
                        : null,
                    onTap: () => Navigator.pop(ctx, exports.length > i ? exports[i] : options[i]),
                  ),
              ],
            ),
          ),
        );
        if (chosen != null) await _fill(name, chosen, 'Choose option');
      case 'signature':
        final sig = await pickSignature(context, SignatureKind.signature);
        if (sig != null) await placeSignature(host, pageIndex, sig, listToRect(f['rect'] as List).deflate(1));
      default:
        break;
    }
  }

  Future<void> _onTapUp(TapUpDetails d) async {
    final p = d.localPosition / widget.scale;
    final author = AppServices.instance.settings.authorName;
    final color = vs.inkColor;
    switch (vs.fillTool) {
      case FillTool.select:
        final hit = host.annotations
            .where((a) => a.page == pageIndex && !a.isLink && a.rect.inflate(4).contains(p))
            .toList();
        if (hit.isNotEmpty) {
          final a = hit.last;
          vs.select(a);
          final action = await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Symbols.open_with),
                    title: const Text('Move or resize'),
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
          if (action == 'delete') {
            await deleteAnnotation(host, a);
          } else if (action != 'move') {
            vs.select(null);
          }
        }
      case FillTool.text:
        final text = await showTextInputDialog(context, title: 'Add text', maxLines: 4, confirmLabel: 'Add');
        if (text == null || text.trim().isEmpty) return;
        final lines = text.split('\n');
        final longest = lines.fold<int>(0, (m, l) => math.max(m, l.length));
        final w = math.min(widget.page.width - p.dx - 2, longest * vs.fontSize * 0.58 + 10);
        final h = lines.length * vs.fontSize * 1.25 + 6;
        await host.edit(
          'Add text',
          (i, o) => PdfEngine.instance.addAnnotations(i, o, [
            {
              'type': 'freetext',
              'page': pageIndex,
              'rect': [p.dx, p.dy - h / 2, p.dx + w, p.dy + h / 2],
              'text': text,
              'fontSize': vs.fontSize,
              'color': colorToInt(color),
              'author': author,
            },
          ], password: pw),
        );
      case FillTool.check:
      case FillTool.cross:
      case FillTool.dot:
        final s = vs.fontSize * 0.8;
        final Map<String, Object?> annot = switch (vs.fillTool) {
          FillTool.check => {
            'type': 'ink',
            'paths': [
              [p.dx - s * 0.5, p.dy, p.dx - s * 0.15, p.dy + s * 0.4, p.dx + s * 0.55, p.dy - s * 0.45],
            ],
            'strokeWidth': math.max(1.5, s / 7),
          },
          FillTool.cross => {
            'type': 'ink',
            'paths': [
              [p.dx - s / 2, p.dy - s / 2, p.dx + s / 2, p.dy + s / 2],
              [p.dx - s / 2, p.dy + s / 2, p.dx + s / 2, p.dy - s / 2],
            ],
            'strokeWidth': math.max(1.5, s / 7),
          },
          _ => {
            'type': 'circle',
            'rect': [p.dx - s / 4, p.dy - s / 4, p.dx + s / 4, p.dy + s / 4],
            'fillColor': colorToInt(color),
            'strokeWidth': 0.5,
          },
        };
        annot.addAll({'page': pageIndex, 'color': colorToInt(color), 'author': author});
        await host.edit('Add mark', (i, o) => PdfEngine.instance.addAnnotations(i, o, [annot], password: pw));
      case FillTool.signature:
      case FillTool.initials:
        final kind = vs.fillTool == FillTool.signature ? SignatureKind.signature : SignatureKind.initials;
        final sig = await pickSignature(context, kind);
        if (sig == null) return;
        final w = kind == SignatureKind.signature ? 150.0 : 60.0;
        await placeSignature(host, pageIndex, sig, Rect.fromCenter(center: p, width: w, height: w));
        vs.fillTool = FillTool.select;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    final selected = vs.selectedAnnotation;
    return Positioned.fill(
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _fields,
        builder: (context, snap) {
          final fields = (snap.data ?? const [])
              .where((f) => f['page'] == pageIndex && f['hidden'] != true && f['type'] != 'button')
              .toList();
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(behavior: HitTestBehavior.translucent, onTapUp: _onTapUp),
              ),
              if (vs.fillTool == FillTool.select)
                for (final f in fields)
                  Positioned.fromRect(
                    rect: scaleRect(listToRect(f['rect'] as List), s),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _onField(f),
                      child: Container(
                        decoration: BoxDecoration(
                          color: (f['readOnly'] == true ? Colors.grey : const Color(0xFF3B82F6)).withValues(
                            alpha: 0.10,
                          ),
                          border: Border.all(
                            color: f['required'] == true
                                ? Colors.red.shade400
                                : const Color(0xFF3B82F6).withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ),
              if (selected != null && selected.page == pageIndex)
                SelectionBox(
                  key: ValueKey(selected.id),
                  rect: selected.rect,
                  scale: s,
                  keepAspect: selected.type == 'Stamp',
                  onChanged: (r) async {
                    vs.select(null);
                    await host.edit(
                      'Move',
                      (i, o) => PdfEngine.instance.updateAnnotation(
                        i,
                        o,
                        page: selected.page,
                        id: selected.id,
                        rect: r,
                        password: pw,
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class FillSignToolbar extends StatelessWidget {
  const FillSignToolbar({super.key, required this.host});

  final ViewerHost host;

  @override
  Widget build(BuildContext context) {
    final vs = host.viewerState;
    final scheme = Theme.of(context).colorScheme;
    Widget btn(FillTool t, Widget icon, String label) {
      final sel = vs.fillTool == t;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => vs.fillTool = sel ? FillTool.select : t,
        child: Container(
          width: 66,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          decoration: BoxDecoration(
            color: sel ? scheme.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme(
                data: IconThemeData(color: sel ? scheme.primary : scheme.onSurfaceVariant),
                child: icon,
              ),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 11, color: sel ? scheme.primary : scheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
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
                      vs.fillTool == FillTool.select
                          ? 'Tap a form field to fill it, or choose a tool'
                          : 'Tap on the page to place',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Color and size',
                    icon: Icon(Symbols.circle, fill: 1, color: vs.inkColor),
                    onPressed: () => showStyleSheet(
                      context,
                      color: vs.inkColor,
                      onColor: (c) {
                        vs.inkColor = c;
                        vs.changed();
                      },
                      fontSize: vs.fontSize,
                      onFontSize: (f) {
                        vs.fontSize = f;
                        vs.changed();
                      },
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'flatten') {
                        final ok = await confirmDialog(
                          context,
                          title: 'Flatten form?',
                          message:
                              'Field values, signatures and comments become part of the page and can no longer be edited.',
                          confirmLabel: 'Flatten',
                        );
                        if (ok) {
                          await host.edit(
                            'Flatten',
                            (i, o) => PdfEngine.instance.flatten(i, o, password: host.session.password),
                          );
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'flatten', child: Text('Flatten form and signatures')),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 70,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  btn(FillTool.text, const Icon(Symbols.text_fields), 'Text'),
                  btn(FillTool.check, const Icon(Symbols.check), 'Check'),
                  btn(FillTool.cross, const Icon(Symbols.close), 'Cross'),
                  btn(FillTool.dot, const Icon(Symbols.circle, fill: 1, size: 12), 'Dot'),
                  btn(FillTool.signature, const Icon(Symbols.draw), 'Sign'),
                  btn(FillTool.initials, const Icon(Symbols.short_text), 'Initials'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
