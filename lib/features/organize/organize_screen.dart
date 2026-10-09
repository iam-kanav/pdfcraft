import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../core/library/file_service.dart';
import '../../core/native/pdf_engine.dart';
import '../../core/pdf_render.dart';
import '../../core/session/document_session.dart';
import '../common/dialogs.dart';
import '../common/open_actions.dart';
import 'crop_screen.dart';
import 'split_screen.dart';

class _PageItem {
  _PageItem({this.file, this.index = 0, this.blank = false, this.size});

  static int _ids = 0;
  final int id = _ids++;

  /// null = page of the document being organized.
  final String? file;
  final int index;
  final bool blank;
  final Size? size;
  int rotation = 0;

  PageSpec toSpec() {
    if (blank) return PageSpec.blank(width: size!.width, height: size!.height);
    if (file != null) return PageSpec.fromFile(file, index, rotate: rotation);
    return PageSpec.page(index, rotate: rotation);
  }
}

/// Acrobat-style "Organize pages": thumbnails grid with reorder/rotate/delete/insert/extract.
class OrganizeScreen extends StatefulWidget {
  const OrganizeScreen({super.key, required this.session});

  final DocumentSession session;

  @override
  State<OrganizeScreen> createState() => _OrganizeScreenState();
}

class _OrganizeScreenState extends State<OrganizeScreen> {
  PdfDocument? _doc;
  final _others = <String, PdfDocument>{};
  List<_PageItem> _items = [];
  final _selected = <int>{};
  bool _dirty = false;
  bool _saving = false;
  int _loadedRevision = -1;

  DocumentSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _doc?.dispose();
    for (final d in _others.values) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final old = _doc;
    try {
      final doc = await openPdf(s.path, password: s.password);
      setState(() {
        _doc = doc;
        _items = [for (var i = 0; i < doc.pages.length; i++) _PageItem(index: i)];
        _selected.clear();
        _dirty = false;
        _loadedRevision = s.revision;
      });
      await old?.dispose();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  List<_PageItem> get _selectedItems => _items.where((i) => _selected.contains(i.id)).toList();

  void _rotate(int delta) {
    final targets = _selected.isEmpty ? _items : _selectedItems;
    setState(() {
      for (final t in targets) {
        t.rotation = (t.rotation + delta) % 360;
      }
      _dirty = true;
    });
  }

  void _delete() {
    if (_selected.length >= _items.length) {
      showSnack(context, 'A document must keep at least one page', error: true);
      return;
    }
    setState(() {
      _items.removeWhere((i) => _selected.contains(i.id));
      _selected.clear();
      _dirty = true;
    });
  }

  void _duplicate() {
    setState(() {
      final out = <_PageItem>[];
      for (final i in _items) {
        out.add(i);
        if (_selected.contains(i.id)) {
          out.add(_PageItem(file: i.file, index: i.index, blank: i.blank, size: i.size)..rotation = i.rotation);
        }
      }
      _items = out;
      _dirty = true;
    });
  }

  int get _insertAt {
    if (_selected.isEmpty) return _items.length;
    return _items.lastIndexWhere((i) => _selected.contains(i.id)) + 1;
  }

  Future<void> _insertBlank() async {
    final ref = _items.isNotEmpty && !_items.first.blank && _doc != null && _items.first.file == null ? _doc!.pages[_items.first.index] : null;
    final size = ref != null ? Size(ref.width, ref.height) : const Size(595.28, 841.89);
    setState(() {
      _items.insert(_insertAt, _PageItem(blank: true, size: size));
      _dirty = true;
    });
  }

  Future<void> _insertFromFile() async {
    final files = await pickPdfsFromDevice(context, multiple: true, import: false);
    if (files.isEmpty) return;
    var at = _insertAt;
    for (final f in files) {
      try {
        final d = _others[f] ??= await openPdf(f);
        final newItems = [for (var i = 0; i < d.pages.length; i++) _PageItem(file: f, index: i)];
        setState(() {
          _items.insertAll(at, newItems);
          at += newItems.length;
          _dirty = true;
        });
      } catch (e) {
        if (mounted) showSnack(context, 'Could not open ${p.basename(f)}: ${friendlyError(e)}', error: true);
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await s.apply('Organize pages', (i, o) => PdfEngine.instance.organize(i, o, [for (final it in _items) it.toSpec()], password: s.password));
      if (!mounted) return;
      showSnack(context, 'Pages saved');
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _extract() async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    final out = FileService.uniquePath(p.dirname(s.path), '${p.basenameWithoutExtension(s.path)}_pages.pdf');
    final ok = await runWithProgress(context, 'Extracting pages…', () => PdfEngine.instance.organize(s.path, out, [for (final it in items) it.toSpec()], password: s.password));
    if (ok == null || !mounted) return;
    showSnack(context, 'Extracted ${items.length} page${items.length == 1 ? '' : 's'} to ${p.basename(out)}', action: SnackBarAction(label: 'Open', onPressed: () => openDocument(context, out)));
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return confirmDialog(context, title: 'Discard changes?', message: 'Your page changes have not been saved.', confirmLabel: 'Discard', destructive: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loadedRevision != -1 && _loadedRevision != s.revision && !_dirty && !_saving) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final selCount = _selected.length;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(selCount == 0 ? 'Organize pages' : '$selCount selected'),
          actions: [
            if (selCount > 0) IconButton(tooltip: 'Clear selection', icon: const Icon(Icons.deselect), onPressed: () => setState(_selected.clear)),
            if (selCount == 0)
              IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all), onPressed: () => setState(() => _selected.addAll(_items.map((e) => e.id)))),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'split':
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SplitScreen(path: s.path, password: s.password)));
                  case 'crop':
                    if (_dirty) {
                      showSnack(context, 'Save your page changes first');
                      return;
                    }
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CropScreen(session: s, initialPage: _selected.isEmpty ? 0 : _items.indexWhere((i) => _selected.contains(i.id)))));
                    _load();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'crop', child: ListTile(leading: Icon(Icons.crop), title: Text('Crop pages'))),
                PopupMenuItem(value: 'split', child: ListTile(leading: Icon(Icons.call_split), title: Text('Split document'))),
              ],
            ),
          ],
        ),
        body: _doc == null
            ? const Center(child: CircularProgressIndicator())
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, childAspectRatio: 0.62, mainAxisSpacing: 12, crossAxisSpacing: 12),
                itemCount: _items.length,
                itemBuilder: (context, i) => _cell(i),
              ),
        bottomNavigationBar: _bottomBar(selCount),
        floatingActionButton: _dirty
            ? FloatingActionButton.extended(
                onPressed: _saving ? null : _save,
                icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined),
                label: const Text('Save'),
                shape: const StadiumBorder(),
              )
            : null,
      ),
    );
  }

  Widget _thumb(_PageItem item) {
    if (item.blank) return Container(color: Colors.white);
    final doc = item.file == null ? _doc : _others[item.file];
    if (doc == null) return const SizedBox();
    final page = doc.pages[item.index];
    final rot = PdfPageRotation.values[((page.rotation.index * 90 + item.rotation) % 360) ~/ 90];
    return PdfPageView(key: ValueKey('${item.file}#${item.index}#${item.rotation}'), document: doc, pageNumber: item.index + 1, rotationOverride: rot, maximumDpi: 60);
  }

  Widget _cell(int i) {
    final item = _items[i];
    final selected = _selected.contains(item.id);
    final scheme = Theme.of(context).colorScheme;
    final tile = Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 3 : 1),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: _thumb(item),
                ),
              ),
              if (selected) Positioned(right: 6, top: 6, child: Icon(Icons.check_circle, color: scheme.primary)),
              if (item.file != null)
                Positioned(left: 6, top: 6, child: Icon(Icons.add_circle, size: 18, color: scheme.tertiary)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('${i + 1}', style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
      ],
    );
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != i,
      onAcceptWithDetails: (d) => setState(() {
        final moved = _items.removeAt(d.data);
        _items.insert(i, moved);
        _dirty = true;
      }),
      builder: (context, candidates, _) => LongPressDraggable<int>(
        data: i,
        feedback: SizedBox(width: 110, height: 160, child: Opacity(opacity: 0.85, child: Material(elevation: 6, child: _thumb(item)))),
        childWhenDragging: Opacity(opacity: 0.3, child: tile),
        child: GestureDetector(
          onTap: () => setState(() => selected ? _selected.remove(item.id) : _selected.add(item.id)),
          child: Container(
            decoration: candidates.isNotEmpty ? BoxDecoration(border: Border(left: BorderSide(color: scheme.primary, width: 4))) : null,
            child: tile,
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(int selCount) {
    final has = selCount > 0;
    Widget act(IconData icon, String label, VoidCallback? onTap) => Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: onTap == null ? Theme.of(context).disabledColor : null),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 11, color: onTap == null ? Theme.of(context).disabledColor : null)),
            ],
          ),
        ),
      ),
    );
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            act(Icons.rotate_left, 'Left', () => _rotate(270)),
            act(Icons.rotate_right, 'Right', () => _rotate(90)),
            act(Icons.delete_outline, 'Delete', has ? _delete : null),
            act(Icons.copy_all_outlined, 'Duplicate', has ? _duplicate : null),
            act(Icons.output, 'Extract', has ? _extract : null),
            PopupMenuButton<String>(
              tooltip: 'Insert',
              onSelected: (v) => v == 'blank' ? _insertBlank() : _insertFromFile(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'blank', child: Text('Blank page')),
                PopupMenuItem(value: 'file', child: Text('Pages from a file')),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.note_add_outlined), SizedBox(height: 2), Text('Insert', style: TextStyle(fontSize: 11))]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
