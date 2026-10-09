import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/library/library_store.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import 'file_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

/// First-page thumbnail of a PDF, cached on disk.
class DocThumbnail extends StatefulWidget {
  const DocThumbnail({super.key, required this.path, this.width = 44, this.height = 56, this.page = 1});

  final String path;
  final double width;
  final double height;
  final int page;

  @override
  State<DocThumbnail> createState() => _DocThumbnailState();
}

class _DocThumbnailState extends State<DocThumbnail> {
  Future<File?>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DocThumbnail old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.page != widget.page) _load();
  }

  void _load() {
    _future = AppServices.instance.thumbnails.get(widget.path, page: widget.page);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<File?>(
        future: _future,
        builder: (context, snap) {
          final f = snap.data;
          if (f != null) return Image.file(f, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true);
          // A finished load without an image means the file couldn't be rendered (usually encrypted).
          final failed = snap.connectionState == ConnectionState.done;
          return Center(
            child: Icon(
              failed ? Symbols.lock : Symbols.picture_as_pdf,
              color: scheme.outline,
              size: widget.width * 0.45,
            ),
          );
        },
      ),
    );
  }
}

/// List row for a document (Acrobat-style: small thumbnail, name, "PDF · date · size", overflow).
class DocListTile extends StatelessWidget {
  const DocListTile({
    super.key,
    required this.path,
    this.subtitle,
    this.onTap,
    this.showRecentActions = false,
    this.onChanged,
    this.selected = false,
    this.onLongPress,
  });

  final String path;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showRecentActions;
  final VoidCallback? onChanged;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryStore>();
    final theme = Theme.of(context);
    final file = File(path);
    final stat = file.existsSync() ? file.statSync() : null;
    final starred = lib.isStarred(path);
    final rec = lib.peek(path);
    final inLibrary = AppServices.instance.files.isInLibrary(path);
    final sub =
        subtitle ??
        [
          'PDF',
          if (rec?.lastOpened != null) formatRelativeDate(rec!.lastOpened!) else if (stat != null) formatRelativeDate(stat.modified),
          if (stat != null) formatBytes(stat.size),
        ].join('  ·  ');
    final secondary = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            selected
                ? SizedBox(width: 36, height: 44, child: Icon(Symbols.check_circle, fill: 1, color: theme.colorScheme.primary))
                : DocThumbnail(path: path, width: 36, height: 44),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(baseName(path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                      ),
                      if (starred) ...[const SizedBox(width: 6), Icon(Symbols.star, fill: 1, size: 16, color: theme.colorScheme.primary)],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(inLibrary ? Symbols.smartphone : Symbols.folder, size: 14, color: secondary),
                      const SizedBox(width: 4),
                      Expanded(child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: secondary))),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'More',
              icon: const Icon(Symbols.more_vert),
              onPressed: () => showFileActions(context, path, fromRecents: showRecentActions, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
  }
}

class FolderTile extends StatelessWidget {
  const FolderTile({super.key, required this.path, required this.itemCount, this.onTap, this.onMore});

  final String path;
  final int itemCount;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            const SizedBox(width: 36, height: 44, child: Icon(Symbols.folder, size: 30)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(path), style: const TextStyle(fontSize: 16)),
                  Text(itemCount == 1 ? '1 item' : '$itemCount items', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (onMore != null) IconButton(icon: const Icon(Symbols.more_vert), onPressed: onMore),
          ],
        ),
      ),
    );
  }
}

/// Acrobat-style empty state: grey line illustration, bold title, secondary message.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, weight: 200, color: t.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
            const SizedBox(height: 16),
            Text(title, style: t.textTheme.titleSmall?.copyWith(fontSize: 17), textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
