import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../../core/library/library_store.dart';
import '../../../core/native/pdf_engine.dart';
import '../../common/dialogs.dart';
import '../viewer_screen.dart';
import '../viewer_state.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Thumbnails, bookmarks, outline and comments in a tabbed sheet.
Future<void> showNavigatorSheet(BuildContext context, ViewerHost host, {required int currentPage, int initialTab = 0}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.88,
      child: _NavigatorSheet(host: host, currentPage: currentPage, initialTab: initialTab),
    ),
  );
}

class _NavigatorSheet extends StatefulWidget {
  const _NavigatorSheet({required this.host, required this.currentPage, required this.initialTab});

  final ViewerHost host;
  final int currentPage;
  final int initialTab;

  @override
  State<_NavigatorSheet> createState() => _NavigatorSheetState();
}

class _NavigatorSheetState extends State<_NavigatorSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this, initialIndex: widget.initialTab);
  Future<List<PdfOutlineNode>>? _outline;

  @override
  void initState() {
    super.initState();
    _outline = widget.host.document?.loadOutline();
  }

  void _go(int page) {
    Navigator.pop(context);
    widget.host.controller.goToPage(pageNumber: page);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Pages'),
            Tab(text: 'Bookmarks'),
            Tab(text: 'Outline'),
            Tab(text: 'Comments'),
          ],
        ),
        Expanded(
          child: TabBarView(controller: _tabs, children: [_thumbnails(), _bookmarks(), _outlineView(), _comments()]),
        ),
      ],
    );
  }

  Widget _thumbnails() {
    final doc = widget.host.document;
    if (doc == null) return const SizedBox();
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        childAspectRatio: 0.66,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: doc.pages.length,
      itemBuilder: (context, i) {
        final selected = i + 1 == widget.currentPage;
        return InkWell(
          onTap: () => _go(i + 1),
          borderRadius: BorderRadius.circular(8),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                      width: 2.5,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: PdfPageView(document: doc, pageNumber: i + 1, maximumDpi: 60),
                ),
              ),
              const SizedBox(height: 4),
              Text('${i + 1}', style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
            ],
          ),
        );
      },
    );
  }

  Widget _bookmarks() {
    final lib = context.watch<LibraryStore>();
    final path = widget.host.session.path;
    final marks = lib.peek(path)?.bookmarks ?? const [];
    return Column(
      children: [
        ListTile(
          leading: const Icon(Symbols.bookmark_add),
          title: Text('Bookmark page ${widget.currentPage}'),
          onTap: () async {
            final label = await showTextInputDialog(
              context,
              title: 'Add bookmark',
              initial: 'Page ${widget.currentPage}',
              confirmLabel: 'Add',
            );
            if (label != null) {
              lib.addBookmark(
                path,
                widget.currentPage,
                label.trim().isEmpty ? 'Page ${widget.currentPage}' : label.trim(),
              );
            }
          },
        ),
        const Divider(),
        Expanded(
          child: marks.isEmpty
              ? const Center(child: Text('No bookmarks yet'))
              : ListView(
                  children: [
                    for (final b in marks)
                      ListTile(
                        leading: const Icon(Symbols.bookmark),
                        title: Text(b.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('Page ${b.page}'),
                        onTap: () => _go(b.page),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'rename') {
                              final l = await showTextInputDialog(context, title: 'Rename bookmark', initial: b.label);
                              if (l != null && l.trim().isNotEmpty) lib.renameBookmark(path, b.page, l.trim());
                            } else {
                              lib.removeBookmark(path, b.page);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _outlineView() {
    return FutureBuilder<List<PdfOutlineNode>>(
      future: _outline,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final nodes = snap.data ?? const [];
        if (nodes.isEmpty) return const Center(child: Text('This document has no outline'));
        return ListView(
          children: [for (final n in nodes) _OutlineTile(node: n, depth: 0, onTap: _goDest)],
        );
      },
    );
  }

  void _goDest(PdfDest? dest) {
    if (dest == null) return;
    Navigator.pop(context);
    widget.host.controller.goToDest(dest);
  }

  Widget _comments() {
    final annots = widget.host.annotations.where((a) => !a.isLink).toList();
    if (annots.isEmpty) return const Center(child: Text('No comments'));
    return ListView(
      children: [
        for (final a in annots)
          ListTile(
            leading: Icon(a.icon, color: a.color),
            title: Text(
              a.contents?.isNotEmpty == true ? a.contents! : a.typeLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${a.typeLabel} · Page ${a.page + 1}${a.author != null ? ' · ${a.author}' : ''}'),
            onTap: () {
              Navigator.pop(context);
              widget.host.controller.goToPage(pageNumber: a.page + 1);
            },
          ),
      ],
    );
  }
}

class _OutlineTile extends StatelessWidget {
  const _OutlineTile({required this.node, required this.depth, required this.onTap});

  final PdfOutlineNode node;
  final int depth;
  final void Function(PdfDest?) onTap;

  @override
  Widget build(BuildContext context) {
    final pad = EdgeInsets.only(left: 16.0 + depth * 16, right: 16);
    if (node.children.isEmpty) {
      return ListTile(
        contentPadding: pad,
        dense: true,
        title: Text(node.title),
        onTap: () => onTap(node.dest),
        trailing: Text('${node.dest?.pageNumber ?? ''}'),
      );
    }
    return ExpansionTile(
      tilePadding: pad,
      title: InkWell(onTap: () => onTap(node.dest), child: Text(node.title)),
      children: [for (final c in node.children) _OutlineTile(node: c, depth: depth + 1, onTap: onTap)],
    );
  }
}

/// Shows (and allows editing/deleting) a sticky note's text.
Future<void> showNoteDialog(ViewerHost host, AnnotInfo a) async {
  final context = host.context;
  final controller = TextEditingController(text: a.contents ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(a.author ?? 'Note'),
      content: TextField(
        controller: controller,
        maxLines: 6,
        minLines: 3,
        decoration: const InputDecoration(hintText: 'Add a comment'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, '__delete__'), child: const Text('Delete')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
  if (result == null) return;
  final pw = host.session.password;
  final engine = PdfEngine.instance;
  if (result == '__delete__') {
    await host.edit('Delete note', (i, o) => engine.deleteAnnotations(i, o, [(page: a.page, id: a.id)], password: pw));
  } else if (result != a.contents) {
    await host.edit(
      'Edit note',
      (i, o) => engine.updateAnnotation(i, o, page: a.page, id: a.id, contents: result, password: pw),
    );
  }
}
