import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/native/pdf_engine.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../common/doc_widgets.dart';
import '../common/document_picker.dart';
import '../common/open_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Combine several PDFs into one, in a user-chosen order.
class CombineScreen extends StatefulWidget {
  const CombineScreen({super.key, this.initial = const []});

  final List<String> initial;

  @override
  State<CombineScreen> createState() => _CombineScreenState();
}

class _CombineScreenState extends State<CombineScreen> {
  late final List<String> _files = [...widget.initial];
  final _passwords = <String, String>{};
  final _name = TextEditingController(text: 'Combined');
  bool _busy = false;

  Future<void> _add() async {
    final picked = await pickDocuments(context, multiple: true, title: 'Add files');
    setState(() => _files.addAll(picked));
  }

  Future<void> _combine() async {
    if (_files.length < 2) {
      showSnack(context, 'Add at least two files', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final specs = <PageSpec>[];
      for (var k = 0; k < _files.length; k++) {
        final f = _files[k];
        DocumentInfo info;
        while (true) {
          try {
            info = await PdfEngine.instance.info(f, password: _passwords[f]);
            break;
          } on PdfEngineException catch (e) {
            if (!e.isPasswordError || !mounted) rethrow;
            final pw = await askPassword(context, fileName: p.basename(f), wrong: _passwords.containsKey(f));
            if (pw == null) throw StateError('Password required for ${p.basename(f)}');
            _passwords[f] = pw;
          }
        }
        for (var i = 0; i < info.pageCount; i++) {
          specs.add(k == 0 ? PageSpec.page(i) : PageSpec.fromFile(f, i, password: _passwords[f]));
        }
      }
      final out = AppServices.instance.files.outputPath(
        '${sanitizeFileName(_name.text.trim().isEmpty ? 'Combined' : _name.text.trim())}.pdf',
      );
      final first = _files.first;
      // The first file's security must not leak into the result; organize keeps it otherwise.
      final tmp = AppServices.instance.tempPath('first.pdf');
      if (_passwords[first] != null) {
        await PdfEngine.instance.removeSecurity(first, tmp, password: _passwords[first]);
      } else {
        await File(first).copy(tmp);
      }
      await PdfEngine.instance.organize(tmp, out, specs);
      if (!mounted) return;
      Navigator.pop(context);
      await openDocument(context, out);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Combine files')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Output file name', suffixText: '.pdf'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Drag to reorder. Pages are combined top to bottom.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: _files.isEmpty
                ? EmptyState(
                    icon: Symbols.merge_type,
                    title: 'Add files to combine',
                    action: FilledButton.icon(
                      onPressed: _add,
                      icon: const Icon(Symbols.add),
                      label: const Text('Add files'),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: _files.length,
                    onReorderItem: (a, b) => setState(() {
                      _files.insert(b, _files.removeAt(a));
                    }),
                    itemBuilder: (context, i) {
                      final f = _files[i];
                      return ListTile(
                        key: ValueKey('$f#$i'),
                        leading: DocThumbnail(path: f),
                        title: Text(p.basename(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(formatBytes(File(f).lengthSync())),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Symbols.close),
                              onPressed: () => setState(() => _files.removeAt(i)),
                            ),
                            ReorderableDragStartListener(index: i, child: const Icon(Symbols.drag_handle)),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Symbols.add),
                label: const Text('Add files'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || _files.length < 2 ? null : _combine,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Symbols.merge_type),
                  label: Text(_busy ? 'Combining…' : 'Combine ${_files.length} files'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
