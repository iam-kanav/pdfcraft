import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/app_settings.dart';
import '../../core/native/pdf_engine.dart';
import '../../core/native/platform_bridge.dart';
import '../../core/services.dart';
import '../../core/session/document_session.dart';
import '../common/dialogs.dart';
import '../common/file_actions.dart';
import '../common/open_actions.dart';
import '../reflow/reflow_screen.dart';
import '../security/properties_screen.dart';
import 'layers/comment_layer.dart';
import 'layers/edit_layer.dart';
import 'layers/fill_sign_layer.dart';
import 'layers/redact_layer.dart';
import 'tts_controller.dart';
import 'viewer_state.dart';
import 'widgets/navigator_sheet.dart';
import 'widgets/search_bar.dart';
import 'widgets/tools_sheet.dart';
import 'widgets/view_settings_sheet.dart';

/// Shared handle given to mode layers so they can talk to the viewer.
class ViewerHost {
  ViewerHost(this._state);

  final _ViewerScreenState _state;

  DocumentSession get session => _state.session;
  PdfViewerController get controller => _state.controller;
  ViewerState get viewerState => _state.viewerState;
  PdfDocument? get document => _state.document;
  List<AnnotInfo> get annotations => _state.annotations;
  BuildContext get context => _state.context;

  /// Runs an engine edit through the session (undoable) and reloads the viewer.
  Future<T?> edit<T>(String label, Future<T> Function(String input, String out) op, {String? Function()? newPassword}) =>
      _state.runEdit(label, op, newPassword: newPassword);

  void refreshAnnotations() => _state.loadAnnotations();
  void setMode(ViewerMode mode) => _state.setMode(mode);
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.path, this.initialPage, this.password, this.initialMode = ViewerMode.read});

  final String path;
  final int? initialPage;
  final String? password;
  final ViewerMode initialMode;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final DocumentSession session;
  final controller = PdfViewerController();
  late final PdfTextSearcher searcher;
  late final ViewerState viewerState;
  late final ViewerHost host;
  late final TtsController tts;
  final _services = AppServices.instance;

  PdfDocument? document;
  int? pageNumber;
  bool chromeVisible = true;
  bool searching = false;
  List<AnnotInfo> annotations = [];
  Matrix4? _restoreMatrix;
  int _passwordAttempts = 0;
  bool _loadFailed = false;
  String? _loadError;
  Timer? _indicatorTimer;
  bool _showIndicator = false;

  @override
  void initState() {
    super.initState();
    final settings = _services.settings;
    session = DocumentSession(path: widget.path, password: widget.password, tempDir: Directory(p.join(_services.tempDir.path, 'session_${DateTime.now().microsecondsSinceEpoch}')));
    session.addListener(_onSession);
    searcher = PdfTextSearcher(controller)..addListener(_onSearch);
    viewerState = ViewerState(color: Color(settings.annotationColor), inkColor: Color(settings.inkColor), strokeWidth: settings.inkWidth)
      ..addListener(_onViewerState);
    host = ViewerHost(this);
    tts = TtsController(host: host)..addListener(() => setState(() {}));
    if (widget.initialMode != ViewerMode.read) viewerState.mode = widget.initialMode;
    if (settings.keepScreenOn) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    tts.dispose();
    searcher.removeListener(_onSearch);
    searcher.dispose();
    session.removeListener(_onSession);
    session.dispose();
    viewerState.dispose();
    super.dispose();
  }

  void _onSession() => setState(() {});
  void _onSearch() => setState(() {});
  void _onViewerState() => setState(() {});

  int get _revision => session.revision;

  Future<T?> runEdit<T>(String label, Future<T> Function(String input, String out) op, {String? Function()? newPassword}) async {
    if (session.isBusy) return null;
    if (controller.isReady) _restoreMatrix = controller.value.clone();
    try {
      final r = await session.apply(label, op, newPassword: newPassword);
      unawaited(loadAnnotations());
      return r;
    } on PdfEngineException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    return null;
  }

  Future<void> loadAnnotations() async {
    try {
      final list = await PdfEngine.instance.listAnnotations(session.path, password: session.password);
      if (mounted) setState(() => annotations = list.map(AnnotInfo.new).toList());
    } catch (_) {}
  }

  void setMode(ViewerMode m) {
    viewerState.mode = m;
    if (m != ViewerMode.read) {
      setState(() => chromeVisible = true);
      if (m == ViewerMode.comment || m == ViewerMode.fillSign) loadAnnotations();
    }
    controller.textSelectionDelegate.clearTextSelection();
  }

  Future<String?> _passwordProvider() async {
    if (_passwordAttempts == 0 && session.password != null) {
      _passwordAttempts++;
      return session.password;
    }
    if (!mounted) return null;
    final pw = await askPassword(context, fileName: session.name, wrong: _passwordAttempts > 1);
    _passwordAttempts++;
    if (pw != null) session.password = pw;
    return pw;
  }

  void _onViewerReady(PdfDocument doc, PdfViewerController c) {
    document = doc;
    _loadFailed = false;
    final lib = _services.library;
    lib.markOpened(session.path, pageCount: doc.pages.length);
    if (_restoreMatrix != null) {
      final m = _restoreMatrix!;
      _restoreMatrix = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (controller.isReady) controller.value = controller.makeMatrixInSafeRange(m);
      });
    }
    loadAnnotations();
    setState(() {});
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    setState(() {
      pageNumber = page;
      _showIndicator = true;
    });
    _services.library.setLastPage(session.path, page);
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showIndicator = false);
    });
  }

  int get _initialPage {
    if (widget.initialPage != null) return widget.initialPage!;
    return _services.library.peek(widget.path)?.lastPage ?? 1;
  }

  // ------------------------------------------------------------------ text selection menu

  void _customizeMenu(PdfViewerContextMenuBuilderParams params, List<ContextMenuButtonItem> items) {
    if (!params.textSelectionDelegate.hasSelectedText) return;
    if (viewerState.mode == ViewerMode.redact) {
      items.insert(0, ContextMenuButtonItem(label: 'Mark for redaction', onPressed: () => _markSelection(params, null)));
      return;
    }
    items.addAll([
      ContextMenuButtonItem(label: 'Highlight', onPressed: () => _markSelection(params, 'highlight')),
      ContextMenuButtonItem(label: 'Underline', onPressed: () => _markSelection(params, 'underline')),
      ContextMenuButtonItem(label: 'Strikethrough', onPressed: () => _markSelection(params, 'strikeout')),
      ContextMenuButtonItem(
        label: 'Read aloud',
        onPressed: () async {
          final text = await params.textSelectionDelegate.getSelectedText();
          params.dismissContextMenu();
          tts.speakText(text);
        },
      ),
    ]);
  }

  Future<void> _markSelection(PdfViewerContextMenuBuilderParams params, String? type) async {
    final ranges = await params.textSelectionDelegate.getSelectedTextRanges();
    params.dismissContextMenu();
    await params.textSelectionDelegate.clearTextSelection();
    final doc = document;
    if (doc == null) return;
    final byPage = <int, List<Rect>>{};
    for (final r in ranges) {
      final page = doc.pages[r.pageNumber - 1];
      byPage.putIfAbsent(r.pageNumber - 1, () => []).addAll(lineRectsForRange(r, page));
    }
    if (type == null) {
      for (final e in byPage.entries) {
        viewerState.redactions.putIfAbsent(e.key, () => []).addAll(e.value.map((r) => r.inflate(1)));
      }
      viewerState.changed();
      return;
    }
    await addMarkup(type, byPage);
  }

  Future<void> addMarkup(String type, Map<int, List<Rect>> byPage) async {
    final settings = _services.settings;
    final color = type == 'highlight' ? viewerState.color : (type == 'strikeout' ? const Color(0xFFE11D48) : const Color(0xFF2563EB));
    final annots = [
      for (final e in byPage.entries)
        if (e.value.isNotEmpty)
          {
            'type': type,
            'page': e.key,
            'rects': e.value.map(rectToList).toList(),
            'color': colorToInt(color),
            'opacity': type == 'highlight' ? 0.45 : 1.0,
            'author': settings.authorName,
          },
    ];
    if (annots.isEmpty) return;
    await runEdit('Add ${type == 'strikeout' ? 'strikethrough' : type}', (i, o) => PdfEngine.instance.addAnnotations(i, o, annots, password: session.password));
  }

  // ------------------------------------------------------------------ build

  PdfViewerParams _params(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final mode = viewerState.mode;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final horizontal = settings.scrollMode == PageScrollMode.singlePage;
    return PdfViewerParams(
      backgroundColor: dark ? const Color(0xFF0E0F11) : const Color(0xFFE9E9EC),
      margin: 10,
      pageDropShadow: const BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
      panEnabled: !viewerState.panLocked,
      scaleEnabled: !viewerState.panLocked,
      layoutPages: horizontal ? _horizontalLayout : null,
      onInteractionEnd: horizontal ? (_) => _snapToPage() : null,
      textSelectionParams: PdfTextSelectionParams(
        enabled: mode == ViewerMode.read || (mode == ViewerMode.comment && viewerState.commentTool == CommentTool.select) || mode == ViewerMode.redact,
      ),
      customizeContextMenuItems: _customizeMenu,
      matchTextColor: Colors.amber.withValues(alpha: 0.35),
      activeMatchTextColor: Colors.deepOrange.withValues(alpha: 0.5),
      pagePaintCallbacks: [searcher.pageTextMatchPaintCallback, tts.paintCallback],
      onViewerReady: _onViewerReady,
      onPageChanged: _onPageChanged,
      linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLinkTap),
      onGeneralTap: (context, c, details) {
        if (details.type == PdfViewerGeneralTapType.tap && mode == ViewerMode.read && details.tapOn == PdfViewerPart.background) {
          setState(() => chromeVisible = !chromeVisible);
          return true;
        }
        return false;
      },
      viewerOverlayBuilder: (context, size, handleLinkTap) => [
        if (!horizontal)
          PdfViewerScrollThumb(
            controller: controller,
            orientation: ScrollbarOrientation.right,
            thumbSize: const Size(46, 28),
            thumbBuilder: (context, thumbSize, page, c) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
              ),
              alignment: Alignment.center,
              child: Text(page?.toString() ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
      ],
      pageOverlaysBuilder: (context, rect, page) => _pageOverlays(context, rect, page),
      loadingBannerBuilder: (context, bytes, total) => const Center(child: CircularProgressIndicator()),
      errorBannerBuilder: (context, error, stack, ref) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_loadFailed) setState(() {
            _loadFailed = true;
            _loadError = error.toString();
          });
        });
        return const SizedBox.shrink();
      },
    );
  }

  PdfPageLayout _horizontalLayout(List<PdfPage> pages, PdfViewerParams params) {
    final height = pages.fold(0.0, (prev, page) => prev > page.height ? prev : page.height) + params.margin * 2;
    final layouts = <Rect>[];
    var x = params.margin;
    for (final page in pages) {
      layouts.add(Rect.fromLTWH(x, (height - page.height) / 2, page.width, page.height));
      x += page.width + params.margin * 2;
    }
    return PdfPageLayout(pageLayouts: layouts, documentSize: Size(x, height));
  }

  void _snapToPage() {
    final page = controller.pageNumber;
    if (page == null || controller.currentZoom > controller.minScale * 1.05) return;
    controller.goToPage(pageNumber: page, anchor: PdfPageAnchor.all);
  }

  void _onLinkTap(PdfLink link) {
    if (viewerState.mode != ViewerMode.read && viewerState.mode != ViewerMode.comment) return;
    final url = link.url;
    if (url != null) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Open link?'),
          content: Text(url.toString()),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url.toString()));
                Navigator.pop(ctx);
                showSnack(context, 'Link copied');
              },
              child: const Text('Copy'),
            ),
          ],
        ),
      );
    } else if (link.dest != null) {
      controller.goToDest(link.dest);
    }
  }

  List<Widget> _pageOverlays(BuildContext context, Rect rect, PdfPage page) {
    final scale = rect.width / page.width;
    final pageIndex = page.pageNumber - 1;
    switch (viewerState.mode) {
      case ViewerMode.read:
        return [
          for (final a in annotations.where((a) => a.page == pageIndex && a.type == 'Text'))
            Positioned.fromRect(
              rect: Rect.fromLTWH(a.rect.left * scale, a.rect.top * scale, a.rect.width * scale, a.rect.height * scale),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showNoteDialog(host, a),
              ),
            ),
        ];
      case ViewerMode.comment:
        return [CommentLayer(host: host, page: page, scale: scale, size: rect.size)];
      case ViewerMode.edit:
        return [EditLayer(key: ValueKey('edit$_revision-${page.pageNumber}'), host: host, page: page, scale: scale, size: rect.size)];
      case ViewerMode.fillSign:
        return [FillSignLayer(key: ValueKey('fill$_revision-${page.pageNumber}'), host: host, page: page, scale: scale, size: rect.size)];
      case ViewerMode.redact:
        return [RedactLayer(host: host, page: page, scale: scale, size: rect.size)];
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final mode = viewerState.mode;
    final showChrome = chromeVisible || mode != ViewerMode.read;
    Widget viewer = PdfViewer.file(
      session.path,
      key: ValueKey('viewer$_revision'),
      controller: controller,
      initialPageNumber: pageNumber ?? _initialPage,
      passwordProvider: _passwordProvider,
      firstAttemptByEmptyPassword: session.password == null,
      params: _params(context),
    );
    if (settings.nightPages) {
      viewer = ColorFiltered(colorFilter: const ColorFilter.matrix(_nightMatrix), child: viewer);
    }
    return PopScope(
      canPop: mode == ViewerMode.read && !searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (searching) {
          _closeSearch();
        } else if (mode != ViewerMode.read) {
          _exitMode();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: false,
        appBar: showChrome ? (searching ? _searchBar() : _appBar(mode)) : null,
        body: Stack(
          children: [
            Positioned.fill(child: _loadFailed ? _errorView() : viewer),
            if (session.isBusy)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text('${session.busyLabel}…'),
                      ],
                    ),
                  ),
                ),
              ),
            if (document != null && (_showIndicator || !showChrome) && mode == ViewerMode.read)
              Positioned(
                left: 12,
                top: 12,
                child: AnimatedOpacity(
                  opacity: _showIndicator ? 1 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: _PageChip(text: '${pageNumber ?? 1} / ${document!.pages.length}'),
                ),
              ),
            if (tts.active) Positioned(left: 12, right: 12, bottom: 12, child: TtsBar(tts: tts)),
          ],
        ),
        bottomNavigationBar: switch (mode) {
          ViewerMode.read => null,
          ViewerMode.comment => CommentToolbar(host: host),
          ViewerMode.edit => EditToolbar(host: host),
          ViewerMode.fillSign => FillSignToolbar(host: host),
          ViewerMode.redact => RedactToolbar(host: host),
        },
        floatingActionButton: mode == ViewerMode.read && showChrome && !tts.active && document != null
            ? FloatingActionButton(
                tooltip: 'Tools',
                onPressed: () => showViewerTools(context, host),
                child: const Icon(Icons.edit_outlined),
              )
            : null,
      ),
    );
  }

  static const _nightMatrix = <double>[
    -0.574, -1.43, -0.144, 0, 255, //
    -0.426, -1.43, -0.144, 0, 255, //
    -0.426, -1.43, 0.856, 0, 255, //
    0, 0, 0, 1, 0,
  ];

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          const Text('Unable to open this document', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(_loadError?.contains('assword') == true ? 'A valid password is required.' : 'The file may be damaged or not a PDF.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              _passwordAttempts = 0;
              setState(() => _loadFailed = false);
              session.markChanged();
            },
            child: const Text('Try again'),
          ),
        ],
      ),
    ),
  );

  void _exitMode() async {
    final vs = viewerState;
    if (vs.mode == ViewerMode.comment && vs.pendingStrokes.isNotEmpty) {
      await commitInk(host);
    }
    if (vs.mode == ViewerMode.redact && vs.redactionCount > 0) {
      final discard = await confirmDialog(context, title: 'Discard redaction marks?', message: 'You have marked areas that have not been redacted yet.', confirmLabel: 'Discard', destructive: true);
      if (!discard) return;
      vs.redactions.clear();
    }
    setMode(ViewerMode.read);
  }

  PreferredSizeWidget _appBar(ViewerMode mode) {
    if (mode != ViewerMode.read) {
      final title = switch (mode) {
        ViewerMode.comment => 'Comment',
        ViewerMode.edit => 'Edit PDF',
        ViewerMode.fillSign => 'Fill & Sign',
        ViewerMode.redact => 'Redact',
        ViewerMode.read => '',
      };
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.check), tooltip: 'Done', onPressed: _exitMode),
        title: Text(title),
        actions: [
          IconButton(
            tooltip: session.undoLabel == null ? 'Undo' : 'Undo ${session.undoLabel}',
            icon: const Icon(Icons.undo),
            onPressed: session.canUndo ? () => _undoRedo(true) : null,
          ),
          IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: session.canRedo ? () => _undoRedo(false) : null),
          if (mode == ViewerMode.comment)
            IconButton(tooltip: 'Comments list', icon: const Icon(Icons.forum_outlined), onPressed: () => showCommentsList(host)),
        ],
      );
    }
    final starred = context.watch<AppServices>().library.isStarred(session.path);
    return AppBar(
      title: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
      actions: [
        IconButton(
          tooltip: 'Smart reading mode',
          icon: const Icon(Icons.chrome_reader_mode_outlined),
          onPressed: () async {
            final page = await Navigator.of(context).push<int>(
              MaterialPageRoute(builder: (_) => ReflowScreen(path: session.path, password: session.password, startPage: pageNumber ?? 1)),
            );
            if (page != null && controller.isReady) controller.goToPage(pageNumber: page);
          },
        ),
        IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: () => setState(() => searching = true)),
        IconButton(
          tooltip: 'Pages & bookmarks',
          icon: const Icon(Icons.view_sidebar_outlined),
          onPressed: document == null ? null : () => showNavigatorSheet(context, host, currentPage: pageNumber ?? 1),
        ),
        PopupMenuButton<String>(
          onSelected: _onMenu,
          itemBuilder: (ctx) => [
            const PopupMenuItem(value: 'view', child: ListTile(leading: Icon(Icons.tune), title: Text('View settings'))),
            PopupMenuItem(
              value: 'bookmark',
              child: ListTile(
                leading: Icon(_services.library.isBookmarked(session.path, pageNumber ?? 1) ? Icons.bookmark : Icons.bookmark_border),
                title: Text(_services.library.isBookmarked(session.path, pageNumber ?? 1) ? 'Remove bookmark' : 'Bookmark this page'),
              ),
            ),
            const PopupMenuItem(value: 'tts', child: ListTile(leading: Icon(Icons.record_voice_over_outlined), title: Text('Read aloud'))),
            const PopupMenuItem(value: 'goto', child: ListTile(leading: Icon(Icons.low_priority), title: Text('Go to page'))),
            PopupMenuItem(value: 'star', child: ListTile(leading: Icon(starred ? Icons.star_rounded : Icons.star_border_rounded), title: Text(starred ? 'Unstar' : 'Star'))),
            const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_outlined), title: Text('Share'))),
            const PopupMenuItem(value: 'print', child: ListTile(leading: Icon(Icons.print_outlined), title: Text('Print'))),
            const PopupMenuItem(value: 'save', child: ListTile(leading: Icon(Icons.download_outlined), title: Text('Save a copy'))),
            const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename'))),
            const PopupMenuItem(value: 'props', child: ListTile(leading: Icon(Icons.info_outline), title: Text('Document properties'))),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _searchBar() => ViewerSearchBar(
    searcher: searcher,
    onClose: _closeSearch,
  );

  void _closeSearch() {
    searcher.resetTextSearch();
    setState(() => searching = false);
  }

  Future<void> _undoRedo(bool undo) async {
    if (controller.isReady) _restoreMatrix = controller.value.clone();
    if (undo) {
      await session.undo();
    } else {
      await session.redo();
    }
    loadAnnotations();
  }

  Future<void> _onMenu(String v) async {
    final page = pageNumber ?? 1;
    switch (v) {
      case 'view':
        showViewSettingsSheet(context);
      case 'bookmark':
        final lib = _services.library;
        if (lib.isBookmarked(session.path, page)) {
          lib.removeBookmark(session.path, page);
          showSnack(context, 'Bookmark removed');
        } else {
          final label = await _pageLabel(page);
          lib.addBookmark(session.path, page, label);
          if (mounted) showSnack(context, 'Page $page bookmarked');
        }
        setState(() {});
      case 'tts':
        tts.start(fromPage: page);
      case 'goto':
        final count = document?.pages.length ?? 1;
        final r = await showTextInputDialog(
          context,
          title: 'Go to page',
          hint: '1 – $count',
          confirmLabel: 'Go',
          validator: (s) {
            final n = int.tryParse(s.trim());
            return n == null || n < 1 || n > count ? 'Enter a number between 1 and $count' : null;
          },
        );
        if (r != null) controller.goToPage(pageNumber: int.parse(r.trim()));
      case 'star':
        _services.library.toggleStar(session.path);
        setState(() {});
      case 'share':
        shareFiles([session.path]);
      case 'print':
        PlatformBridge.instance.print(session.path, session.name);
      case 'save':
        saveCopyToDownloads(context, session.path);
      case 'rename':
        final newPath = await renameFile(context, session.path);
        if (newPath != null) session.updatePath(newPath);
      case 'props':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PropertiesScreen(path: session.path, session: session)));
    }
  }

  /// A short label for a bookmark: first line of text on the page.
  Future<String> _pageLabel(int page) async {
    try {
      final text = await document!.pages[page - 1].loadText();
      final line = text?.fullText.split('\n').map((s) => s.trim()).firstWhere((s) => s.length > 3, orElse: () => '') ?? '';
      if (line.isNotEmpty) return line.length > 60 ? '${line.substring(0, 60)}…' : line;
    } catch (_) {}
    return 'Page $page';
  }
}

class _PageChip extends StatelessWidget {
  const _PageChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(16)),
    child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
  );
}
