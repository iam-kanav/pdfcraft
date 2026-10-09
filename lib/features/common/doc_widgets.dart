import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/library/library_store.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import 'file_actions.dart';

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
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<File?>(
        future: _future,
        builder: (context, snap) {
          final f = snap.data;
          if (f != null) return Image.file(f, fit: BoxFit.cover, alignment: Alignment.topCenter, gaplessPlayback: true);
          return Center(
            child: Icon(Icons.picture_as_pdf, color: snap.connectionState == ConnectionState.done ? scheme.primary : scheme.outline, size: widget.width * 0.5),
          );
        },
      ),
    );
  }
}

/// List row for a document (Acrobat-style: thumbnail, name, date · size, star, overflow).
class DocListTile extends StatelessWidget {
  const DocListTile({super.key, required this.path, this.subtitle, this.onTap, this.showRecentActions = false, this.onChanged, this.selected = false, this.onLongPress});

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
    final file = File(path);
    final stat = file.existsSync() ? file.statSync() : null;
    final starred = lib.isStarred(path);
    final rec = lib.peek(path);
    final sub = subtitle ??
        [
          if (rec?.lastOpened != null) formatRelativeDate(rec!.lastOpened!) else if (stat != null) formatRelativeDate(stat.modified),
          if (stat != null) formatBytes(stat.size),
          if (rec?.pageCount != null) '${rec!.pageCount} pages',
        ].join(' · ');
    return ListTile(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selected
          ? const SizedBox(width: 44, height: 56, child: Icon(Icons.check_circle, size: 30))
          : DocThumbnail(path: path),
      title: Text(p.basename(path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (starred) Icon(Icons.star_rounded, color: Colors.amber.shade600, size: 20),
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onPressed: () => showFileActions(context, path, fromRecents: showRecentActions, onChanged: onChanged),
          ),
        ],
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
    return ListTile(
      onTap: onTap,
      leading: SizedBox(width: 44, height: 56, child: Icon(Icons.folder_rounded, size: 40, color: Colors.amber.shade700)),
      title: Text(p.basename(path), style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(itemCount == 1 ? '1 item' : '$itemCount items'),
      trailing: onMore == null ? null : IconButton(icon: const Icon(Icons.more_vert), onPressed: onMore),
    );
  }
}

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
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: t.colorScheme.primary.withValues(alpha: 0.08), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: t.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
