import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/library/file_service.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import 'doc_widgets.dart';
import 'open_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Picks one or more PDFs from recents / the library / the device.
Future<List<String>> pickDocuments(
  BuildContext context, {
  bool multiple = false,
  String title = 'Select a file',
}) async {
  final r = await Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      builder: (_) => _DocumentPickerScreen(multiple: multiple, title: title),
    ),
  );
  return r ?? const [];
}

Future<String?> pickDocument(BuildContext context, {String title = 'Select a file'}) async {
  final r = await pickDocuments(context, title: title);
  return r.isEmpty ? null : r.first;
}

class _DocumentPickerScreen extends StatefulWidget {
  const _DocumentPickerScreen({required this.multiple, required this.title});

  final bool multiple;
  final String title;

  @override
  State<_DocumentPickerScreen> createState() => _DocumentPickerScreenState();
}

class _DocumentPickerScreenState extends State<_DocumentPickerScreen> {
  final _selected = <String>[];
  List<String> _all = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = AppServices.instance;
    final recents = services.library.recents.map((r) => r.path).toList();
    final library = <String>[];
    await for (final e in services.files.root.list(recursive: true, followLinks: false)) {
      if (e is File && e.path.toLowerCase().endsWith('.pdf') && !p.basename(e.path).startsWith('.')) {
        library.add(e.path);
      }
    }
    final entries = library.map((f) => FileEntry.fromEntity(File(f))).whereType<FileEntry>().toList();
    final sorted = FileService.sortEntries(entries, SortField.date, true).map((e) => e.path);
    setState(() => _all = {...recents, ...sorted}.toList());
  }

  void _toggle(String path) {
    if (!widget.multiple) {
      Navigator.pop(context, [path]);
      return;
    }
    setState(() => _selected.contains(path) ? _selected.remove(path) : _selected.add(path));
  }

  @override
  Widget build(BuildContext context) {
    final items = _query.isEmpty
        ? _all
        : _all.where((f) => p.basename(f).toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.multiple && _selected.isNotEmpty ? '${_selected.length} selected' : widget.title),
        actions: [
          if (widget.multiple)
            TextButton(
              onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected),
              child: const Text('Done'),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(22),
              ),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Symbols.search),
                  hintText: 'Search files',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 11),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Symbols.folder_open)),
            title: const Text('Browse device…'),
            subtitle: const Text('Downloads, Drive and other storage'),
            onTap: () async {
              final picked = await pickPdfsFromDevice(context, multiple: widget.multiple);
              if (picked.isEmpty || !context.mounted) return;
              if (!widget.multiple) {
                Navigator.pop(context, picked);
              } else {
                setState(() {
                  _all = {...picked, ..._all}.toList();
                  _selected.addAll(picked.where((f) => !_selected.contains(f)));
                });
              }
            },
          ),
          const Divider(),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('No PDF files yet')),
            ),
          for (final f in items)
            ListTile(
              leading: _selected.contains(f)
                  ? const SizedBox(width: 44, height: 56, child: Icon(Symbols.check_circle, size: 30))
                  : DocThumbnail(path: f),
              title: Text(p.basename(f), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(formatBytes(File(f).existsSync() ? File(f).lengthSync() : 0)),
              selected: _selected.contains(f),
              trailing: widget.multiple && _selected.contains(f) ? Text('${_selected.indexOf(f) + 1}') : null,
              onTap: () => _toggle(f),
            ),
        ],
      ),
    );
  }
}
