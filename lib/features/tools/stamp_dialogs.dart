import 'package:file_picker/file_picker.dart';
import '../../core/file_picking.dart';
import 'package:flutter/material.dart';

import '../../core/native/pdf_engine.dart';
import '../../core/session/document_session.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../viewer/widgets/color_palette.dart';
import 'package:material_symbols_icons/symbols.dart';

Future<int> _pageCount(DocumentSession s) async =>
    (await PdfEngine.instance.info(s.path, password: s.password)).pageCount;

/// Adds a text or image watermark (tagged so it can be removed later).
Future<void> showWatermarkDialog(BuildContext context, {required DocumentSession session}) async {
  final count = await _pageCount(session);
  if (!context.mounted) return;
  final text = TextEditingController(text: 'CONFIDENTIAL');
  final pages = TextEditingController();
  String? imagePath;
  var useImage = false;
  var size = 54.0;
  var opacity = 0.25;
  var rotation = 45.0;
  var color = const Color(0xFFE11D48);
  var position = 'center';
  var layer = 'over';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Add watermark',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Text')),
                    ButtonSegment(value: true, label: Text('Image')),
                  ],
                  selected: {useImage},
                  onSelectionChanged: (v) => setState(() => useImage = v.first),
                ),
                const SizedBox(height: 12),
                if (!useImage) ...[
                  TextField(
                    controller: text,
                    decoration: const InputDecoration(labelText: 'Text'),
                  ),
                  Wrap(
                    children: [
                      for (final c in kAnnotationColors)
                        ColorDot(color: c, selected: c == color, onTap: () => setState(() => color = c), size: 24),
                    ],
                  ),
                  Text('Size ${size.round()} pt'),
                  Slider(value: size, min: 12, max: 120, onChanged: (v) => setState(() => size = v)),
                ] else
                  OutlinedButton.icon(
                    onPressed: () async {
                      final r = await pickLocalFile(type: FileType.image);
                      setState(() => imagePath = r?.path);
                    },
                    icon: const Icon(Symbols.image),
                    label: Text(imagePath == null ? 'Choose image' : 'Image selected'),
                  ),
                Text('Opacity ${(opacity * 100).round()}%'),
                Slider(value: opacity, min: 0.05, max: 1, onChanged: (v) => setState(() => opacity = v)),
                Text('Rotation ${rotation.round()}°'),
                Slider(
                  value: rotation,
                  min: -90,
                  max: 90,
                  divisions: 36,
                  onChanged: (v) => setState(() => rotation = v),
                ),
                DropdownButtonFormField<String>(
                  initialValue: position,
                  decoration: const InputDecoration(labelText: 'Position'),
                  items: const [
                    DropdownMenuItem(value: 'center', child: Text('Center')),
                    DropdownMenuItem(value: 'tile', child: Text('Tiled')),
                    DropdownMenuItem(value: 'top', child: Text('Top')),
                    DropdownMenuItem(value: 'bottom', child: Text('Bottom')),
                  ],
                  onChanged: (v) => setState(() => position = v!),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Behind page content'),
                  value: layer == 'under',
                  onChanged: (v) => setState(() => layer = v ? 'under' : 'over'),
                ),
                TextField(
                  controller: pages,
                  decoration: InputDecoration(labelText: 'Pages (blank = all)', hintText: 'e.g. 1-3, 5'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply watermark')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  List<int>? pageList;
  try {
    if (pages.text.trim().isNotEmpty) pageList = parsePageRanges(pages.text, count).map((p) => p - 1).toList();
  } on FormatException catch (e) {
    showSnack(context, e.message, error: true);
    return;
  }
  if (useImage && imagePath == null) {
    showSnack(context, 'Choose an image first', error: true);
    return;
  }
  await _apply(
    context,
    session,
    'Add watermark',
    (i, o) => PdfEngine.instance.watermark(
      i,
      o,
      password: session.password,
      text: useImage ? null : text.text,
      imagePath: useImage ? imagePath : null,
      fontSize: size,
      color: color,
      opacity: opacity,
      rotation: rotation,
      position: position,
      layer: layer,
      pages: pageList,
    ),
  );
}

/// Adds page numbers / header-footer text.
Future<void> showPageNumbersDialog(BuildContext context, {required DocumentSession session}) async {
  final count = await _pageCount(session);
  if (!context.mounted) return;
  var format = 'Page {n} of {N}';
  final custom = TextEditingController(text: 'Page {n} of {N}');
  final pages = TextEditingController();
  final start = TextEditingController(text: '1');
  var position = 'bottom-center';
  var size = 10.0;
  const formats = ['{n}', 'Page {n}', 'Page {n} of {N}', '{n} / {N}', '- {n} -'];
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Page numbers & header/footer',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final f in formats)
                      ChoiceChip(
                        label: Text(f.replaceAll('{n}', '1').replaceAll('{N}', '$count')),
                        selected: format == f,
                        onSelected: (_) => setState(() {
                          format = f;
                          custom.text = f;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: custom,
                  decoration: const InputDecoration(
                    labelText: 'Text',
                    helperText: '{n} = number, {N} = total. Any text works for headers/footers.',
                  ),
                  onChanged: (v) => format = v,
                ),
                const SizedBox(height: 12),
                const Text('Position'),
                const SizedBox(height: 6),
                _PositionGrid(value: position, onChanged: (v) => setState(() => position = v)),
                Text('Font size ${size.round()} pt'),
                Slider(value: size, min: 6, max: 24, divisions: 18, onChanged: (v) => setState(() => size = v)),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: start,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Start at'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: pages,
                        decoration: InputDecoration(labelText: 'Pages (blank = all)', hintText: '1-$count'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  List<int>? pageList;
  try {
    if (pages.text.trim().isNotEmpty) pageList = parsePageRanges(pages.text, count).map((p) => p - 1).toList();
  } on FormatException catch (e) {
    showSnack(context, e.message, error: true);
    return;
  }
  await _apply(
    context,
    session,
    'Add page numbers',
    (i, o) => PdfEngine.instance.pageNumbers(
      i,
      o,
      password: session.password,
      format: custom.text.trim().isEmpty ? format : custom.text,
      position: position,
      fontSize: size,
      startNumber: int.tryParse(start.text.trim()) ?? 1,
      pages: pageList,
    ),
  );
}

class _PositionGrid extends StatelessWidget {
  const _PositionGrid({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(String v) => Expanded(
      child: GestureDetector(
        onTap: () => onChanged(v),
        child: Container(
          height: 28,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value == v ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
    return Container(
      width: 180,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(children: [cell('top-left'), cell('top-center'), cell('top-right')]),
          const SizedBox(height: 60),
          Row(children: [cell('bottom-left'), cell('bottom-center'), cell('bottom-right')]),
        ],
      ),
    );
  }
}

/// Removes watermarks / headers / footers previously added (tagged as pagination artifacts).
Future<void> showRemoveArtifactsDialog(BuildContext context, {required DocumentSession session}) async {
  final kinds = <String>{'Watermark'};
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove page marks'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final k in const ['Watermark', 'Header', 'Footer'])
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: kinds.contains(k),
                title: Text(
                  k == 'Header'
                      ? 'Headers (incl. top page numbers)'
                      : k == 'Footer'
                      ? 'Footers (incl. bottom page numbers)'
                      : 'Watermarks',
                ),
                onChanged: (v) => setState(() => v == true ? kinds.add(k) : kinds.remove(k)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: kinds.isEmpty ? null : () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final n = await _apply(
    context,
    session,
    'Remove page marks',
    (i, o) => PdfEngine.instance.removeArtifacts(i, o, password: session.password, kinds: kinds.toList()),
  );
  if (context.mounted && n != null) {
    showSnack(
      context,
      n == 0 ? 'No tagged watermarks, headers or footers found' : 'Removed $n item${n == 1 ? '' : 's'}',
    );
  }
}

Future<T?> _apply<T>(
  BuildContext context,
  DocumentSession session,
  String label,
  Future<T> Function(String, String) op,
) async {
  try {
    final r = await session.apply(label, op);
    if (context.mounted) showSnack(context, '$label: done');
    return r;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return null;
  }
}
