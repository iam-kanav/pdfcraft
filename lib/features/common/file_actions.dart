import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/library/file_service.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import '../security/properties_screen.dart';
import '../tools/tool_registry.dart';
import 'dialogs.dart';
import 'doc_widgets.dart';
import 'open_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Bottom sheet with actions for a document (Acrobat's file "…" menu).
Future<void> showFileActions(
  BuildContext context,
  String path, {
  bool fromRecents = false,
  VoidCallback? onChanged,
}) async {
  final services = AppServices.instance;
  final lib = services.library;
  final stat = File(path).statSync();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      void close() => Navigator.pop(ctx);
      final starred = lib.isStarred(path);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: DocThumbnail(path: path),
                title: Text(p.basename(path), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${formatBytes(stat.size)} · ${formatRelativeDate(stat.modified)}'),
              ),
              const Divider(),
              _action(ctx, Symbols.open_in_new, 'Open', () {
                close();
                openDocument(context, path);
              }),
              _action(ctx, Symbols.share, 'Share', () {
                close();
                shareFiles([path]);
              }),
              _action(
                ctx,
                starred ? Symbols.star_rounded : Symbols.star_border_rounded,
                starred ? 'Unstar' : 'Star',
                () {
                  close();
                  lib.toggleStar(path);
                },
              ),
              _action(ctx, Symbols.drive_file_rename_outline, 'Rename', () async {
                close();
                await renameFile(context, path);
                onChanged?.call();
              }),
              _action(ctx, Symbols.drive_file_move_outline, 'Move', () async {
                close();
                await moveFile(context, path);
                onChanged?.call();
              }),
              _action(ctx, Symbols.content_copy, 'Duplicate', () async {
                close();
                await services.files.duplicate(path);
                onChanged?.call();
                if (context.mounted) showSnack(context, 'Duplicated');
              }),
              _action(ctx, Symbols.download, 'Save a copy to Downloads', () {
                close();
                saveCopyToDownloads(context, path);
              }),
              _action(ctx, Symbols.info, 'Document properties', () {
                close();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => PropertiesScreen(path: path)));
              }),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Tools', style: Theme.of(ctx).textTheme.labelLarge),
              ),
              SizedBox(
                height: 92,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final t in ToolRegistry.fileTools)
                      ToolChip(
                        tool: t,
                        onTap: () {
                          close();
                          t.launch(context, path: path);
                        },
                      ),
                  ],
                ),
              ),
              const Divider(),
              if (fromRecents)
                _action(ctx, Symbols.history_toggle_off, 'Remove from recent', () {
                  close();
                  lib.removeFromRecents(path);
                  onChanged?.call();
                }),
              _action(ctx, Symbols.delete_outline, 'Delete', () async {
                close();
                await deleteFile(context, path);
                onChanged?.call();
              }, destructive: true),
            ],
          ),
        ),
      );
    },
  );
}

Widget _action(BuildContext ctx, IconData icon, String label, VoidCallback onTap, {bool destructive = false}) {
  final color = destructive ? Theme.of(ctx).colorScheme.error : null;
  return ListTile(
    dense: true,
    leading: Icon(icon, color: color),
    title: Text(label, style: TextStyle(color: color, fontSize: 15)),
    onTap: onTap,
  );
}

Future<String?> renameFile(BuildContext context, String path) async {
  final name = await showTextInputDialog(
    context,
    title: 'Rename',
    initial: p.basename(path),
    selectBaseName: true,
    validator: (v) => v.trim().isEmpty ? 'Name cannot be empty' : null,
  );
  if (name == null) return null;
  try {
    final newPath = await AppServices.instance.files.rename(path, name.trim());
    AppServices.instance.library.moved(path, newPath);
    return newPath;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return null;
  }
}

Future<String?> moveFile(BuildContext context, String path) async {
  final dest = await pickFolder(context, title: 'Move to');
  if (dest == null) return null;
  try {
    final newPath = await AppServices.instance.files.move(path, dest);
    AppServices.instance.library.moved(path, newPath);
    if (context.mounted) showSnack(context, 'Moved to ${p.basename(dest.path)}');
    return newPath;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return null;
  }
}

Future<bool> deleteFile(BuildContext context, String path) async {
  final isDir = FileSystemEntity.isDirectorySync(path);
  final ok = await confirmDialog(
    context,
    title: 'Delete ${isDir ? 'folder' : 'file'}?',
    message: '"${p.basename(path)}" will be permanently deleted${isDir ? ' with everything inside it' : ''}.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!ok) return false;
  try {
    await AppServices.instance.files.delete(path);
    AppServices.instance.library.deleted(path);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return false;
  }
}

/// Folder chooser inside the library.
Future<Directory?> pickFolder(BuildContext context, {String title = 'Choose folder'}) {
  return Navigator.of(context).push<Directory>(MaterialPageRoute(builder: (_) => _FolderPickerScreen(title: title)));
}

class _FolderPickerScreen extends StatefulWidget {
  const _FolderPickerScreen({required this.title});

  final String title;

  @override
  State<_FolderPickerScreen> createState() => _FolderPickerScreenState();
}

class _FolderPickerScreenState extends State<_FolderPickerScreen> {
  late Directory _dir = AppServices.instance.files.root;
  List<FileEntry> _folders = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await AppServices.instance.files.list(_dir, sort: SortField.name, descending: false);
    if (mounted) setState(() => _folders = entries.where((e) => e.isDirectory).toList());
  }

  @override
  Widget build(BuildContext context) {
    final files = AppServices.instance.files;
    final isRoot = p.equals(_dir.path, files.root.path);
    return PopScope(
      canPop: isRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() => _dir = _dir.parent);
          _load();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  isRoot ? 'My Files' : 'My Files / ${p.relative(_dir.path, from: files.root.path)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'New folder',
              icon: const Icon(Symbols.create_new_folder),
              onPressed: () async {
                final name = await showTextInputDialog(
                  context,
                  title: 'New folder',
                  hint: 'Folder name',
                  confirmLabel: 'Create',
                );
                if (name == null || name.trim().isEmpty) return;
                await files.createFolder(_dir, name.trim());
                _load();
              },
            ),
          ],
        ),
        body: ListView(
          children: [
            for (final f in _folders)
              FolderTile(
                path: f.path,
                itemCount: f.childCount,
                onTap: () {
                  setState(() => _dir = Directory(f.path));
                  _load();
                },
              ),
            if (_folders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No subfolders')),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(onPressed: () => Navigator.pop(context, _dir), child: const Text('Select this folder')),
          ),
        ),
      ),
    );
  }
}
