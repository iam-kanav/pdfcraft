import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/library/file_service.dart';
import '../../core/library/library_store.dart';
import '../../core/native/platform_bridge.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../common/doc_widgets.dart';
import '../common/file_actions.dart';
import '../common/open_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Files tab: browse the local library folders and PDFs elsewhere on the device.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> with WidgetsBindingObserver {
  final _files = AppServices.instance.files;
  late Directory _dir = _files.root;
  List<FileEntry> _entries = [];
  SortField _sort = SortField.date;
  bool _desc = true;
  bool _loading = true;
  bool _deviceMode = false;
  bool _rootMode = true;
  bool? _hasAccess;
  List<({String path, int size, DateTime modified})> _device = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (_deviceMode) return _loadDevice();
    final entries = await _files.list(_dir, sort: _sort, descending: _desc);
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  Future<void> _loadDevice() async {
    setState(() => _loading = true);
    final ok = await PlatformBridge.instance.hasAllFilesAccess();
    final list = ok ? await PlatformBridge.instance.scanDevicePdfs() : <({String path, int size, DateTime modified})>[];
    final sorted = [...list]
      ..sort((a, b) {
        final r = switch (_sort) {
          SortField.name => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()),
          SortField.date => a.modified.compareTo(b.modified),
          SortField.size => a.size.compareTo(b.size),
        };
        return _desc ? -r : r;
      });
    if (mounted) {
      setState(() {
        _hasAccess = ok;
        _device = sorted;
        _loading = false;
      });
    }
  }

  void _open(Directory d) {
    setState(() {
      _dir = d;
      _loading = true;
    });
    _load();
  }

  bool get _atRoot => p.equals(_dir.path, _files.root.path);

  void _enterLibrary(Directory d) {
    setState(() {
      _rootMode = false;
      _deviceMode = false;
      _dir = d;
      _loading = true;
    });
    _load();
  }

  void _back() {
    if (_deviceMode) {
      setState(() {
        _deviceMode = false;
        _rootMode = true;
      });
    } else if (_atRoot) {
      setState(() => _rootMode = true);
    } else {
      _open(_dir.parent);
    }
  }

  Future<void> _newFolder() async {
    final name = await showTextInputDialog(context, title: 'New folder', hint: 'Folder name', confirmLabel: 'Create');
    if (name == null || name.trim().isEmpty) return;
    await _files.createFolder(_dir, name.trim());
    _load();
  }

  Future<void> _import() async {
    final picked = await pickPdfsFromDevice(context, multiple: true, import: false);
    for (final f in picked) {
      await _files.import(f, into: _dir);
    }
    if (picked.isNotEmpty && mounted)
      showSnack(context, 'Imported ${picked.length} file${picked.length == 1 ? '' : 's'}');
    _load();
  }

  Future<void> _folderActions(FileEntry e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Symbols.drive_file_move_outline),
              title: const Text('Move'),
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
      case 'rename':
        await renameFile(context, e.path);
      case 'move':
        await moveFile(context, e.path);
      case 'delete':
        await deleteFile(context, e.path);
    }
    _load();
  }

  Widget _sortMenu() => PopupMenuButton<String>(
    tooltip: 'Sort',
    icon: const Icon(Symbols.sort),
    onSelected: (v) {
      setState(() {
        if (v == 'dir') {
          _desc = !_desc;
        } else {
          _sort = SortField.values.byName(v);
        }
      });
      _load();
    },
    itemBuilder: (_) => [
      for (final f in SortField.values)
        CheckedPopupMenuItem(
          value: f.name,
          checked: _sort == f,
          child: Text(switch (f) {
            SortField.name => 'Name',
            SortField.date => 'Date modified',
            SortField.size => 'Size',
          }),
        ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem(value: 'dir', checked: _desc, child: const Text('Descending')),
    ],
  );

  @override
  Widget build(BuildContext context) {
    context.watch<LibraryStore>();
    final theme = Theme.of(context);
    if (_rootMode) {
      Widget loc(IconData icon, String title, VoidCallback onTap, {String? subtitle, bool chevron = true}) => Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: Icon(icon),
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: chevron ? const Icon(Symbols.chevron_right) : null,
            onTap: onTap,
          ),
          const Divider(indent: 16, endIndent: 16),
        ],
      );
      return Scaffold(
        appBar: AppBar(toolbarHeight: 8),
        body: ListView(
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 16), child: Text('Files', style: theme.textTheme.headlineSmall)),
            loc(Symbols.smartphone, 'On this device', () {
              setState(() {
                _rootMode = false;
                _deviceMode = true;
              });
              _loadDevice();
            }),
            loc(Symbols.folder, 'My Files', () => _enterLibrary(_files.root), subtitle: 'Files stored in PDFCraft'),
            loc(Symbols.document_scanner, 'Scans', () => _enterLibrary(_files.scansDir)),
            loc(Symbols.swap_horiz, 'Converted', () => _enterLibrary(_files.convertedDir)),
            loc(Symbols.folder_open, 'Browse more files', () => pickAndOpenPdf(context), chevron: false),
          ],
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text(_deviceMode ? 'On this device' : (_atRoot ? 'My Files' : p.basename(_dir.path))),
          actions: [
            _sortMenu(),
            if (!_deviceMode) ...[
              IconButton(tooltip: 'New folder', icon: const Icon(Symbols.create_new_folder), onPressed: _newFolder),
              IconButton(tooltip: 'Import files', icon: const Icon(Symbols.upload_file), onPressed: _import),
            ],
          ],
        ),
        body: RefreshIndicator(onRefresh: _load, child: _deviceMode ? _deviceList() : _libraryList()),
      ),
    );
  }

  Widget _libraryList() {
    return ListView(
      children: [
        if (!_atRoot)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('My Files / ${p.relative(_dir.path, from: _files.root.path)}', style: Theme.of(context).textTheme.bodySmall),
          ),
        if (_loading)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: EmptyState(icon: Symbols.folder_open, title: 'This folder is empty', message: 'Import, scan or create PDFs to fill it.'),
          )
        else
          for (final e in _entries)
            if (e.isDirectory)
              FolderTile(path: e.path, itemCount: e.childCount, onTap: () => _open(Directory(e.path)), onMore: () => _folderActions(e))
            else
              DocListTile(
                path: e.path,
                subtitle: 'PDF  ·  ${formatRelativeDate(e.modified)}  ·  ${formatBytes(e.size)}',
                onTap: () => openDocument(context, e.path),
                onChanged: _load,
              ),
        const SizedBox(height: 96),
      ],
    );
  }

  Widget _deviceList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_hasAccess == false) {
      return ListView(
        children: [
          EmptyState(
            icon: Symbols.folder_special,
            title: 'Allow access to find PDFs',
            message:
                'PDFCraft needs "All files access" to list PDFs stored anywhere on this device. Files never leave your phone.',
            action: FilledButton(
              onPressed: PlatformBridge.instance.requestAllFilesAccess,
              child: const Text('Allow access'),
            ),
          ),
        ],
      );
    }
    if (_device.isEmpty)
      return ListView(
        children: const [EmptyState(icon: Symbols.search_off, title: 'No PDFs found on this device')],
      );
    return ListView.builder(
      itemCount: _device.length,
      itemBuilder: (context, i) {
        final d = _device[i];
        return DocListTile(
          path: d.path,
          subtitle: '${formatRelativeDate(d.modified)} · ${formatBytes(d.size)} · ${p.dirname(d.path).split('/').last}',
          onTap: () => openDocument(context, d.path),
          onChanged: _loadDevice,
        );
      },
    );
  }
}
