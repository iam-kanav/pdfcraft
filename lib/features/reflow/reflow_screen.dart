import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/doc_structure.dart';
import '../../core/models/raw_page_content.dart';
import '../../core/native/pdf_engine.dart';
import '../common/dialogs.dart';
import 'analyzer/reflow_analyzer.dart';
import 'reading_settings.dart';
import 'reflow_cache.dart';
import 'widgets/reading_settings_sheet.dart';
import 'widgets/reflow_view.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Smart reading mode (Liquid Mode alternative): reflowed, restyled content.
/// Pops with a page number when the user asks to jump back to the original page.
class ReflowScreen extends StatefulWidget {
  const ReflowScreen({super.key, required this.path, this.password, this.startPage = 1});

  final String path;
  final String? password;
  final int startPage;

  @override
  State<ReflowScreen> createState() => _ReflowScreenState();
}

class _ReflowScreenState extends State<ReflowScreen> {
  final _raw = <RawPageContent>[];
  DocStructure? _doc;
  int _total = 0;
  bool _loading = true;
  Object? _error;
  String? _query;
  bool _searching = false;
  final _reflow = ReflowController();
  final _scroll = ScrollController();
  final _tts = FlutterTts();
  bool _speaking = false;
  bool _disposed = false;

  /// Number of pages in the analysis currently shown.
  int _analyzedPages = 0;

  /// Block to open at (the start page's), for a document loaded whole from
  /// the cache.
  int _initialBlock = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    _tts.stop();
    _scroll.dispose();
    _reflow.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Password-protected files aren't cached: that would store their text
    // unencrypted.
    final cache = widget.password == null ? await ReflowCache.open() : null;
    try {
      final cached = await cache?.read(widget.path);
      if (_disposed) return;
      if (cached != null) {
        setState(() {
          _doc = cached;
          _initialBlock = _firstBlockOnPage(cached, widget.startPage);
          _loading = false;
        });
        return;
      }
      final info = await PdfEngine.instance.info(widget.path, password: widget.password);
      _total = info.pageCount;
      // Start with the page being read so it shows first; earlier pages are
      // filled in last (the view keeps its place when they arrive).
      final start = math.max(0, math.min(widget.startPage - 1, _total - 1));
      final order = [for (var k = start; k < _total; k++) k, for (var k = 0; k < start; k++) k];
      // The analyzer looks at the whole document (repeated headers, body font
      // size), so every pass re-analyzes all loaded pages. Passes run in the
      // background while the next pages are extracted, and only once the page
      // count has doubled, which keeps the total work linear. A small first
      // batch gets text on screen quickly.
      Future<void>? pass;
      var nextPass = 1;
      while (_raw.length < _total && !_disposed) {
        final from = _raw.length;
        final to = math.min(from + (from == 0 ? 3 : 12), _total);
        _raw.addAll(
          await PdfEngine.instance.extractPages(widget.path, password: widget.password, pages: order.sublist(from, to)),
        );
        if (_disposed) return;
        setState(() {}); // Progress.
        if (pass == null && _raw.length >= nextPass) {
          nextPass = _raw.length * 2;
          pass = _analyze().whenComplete(() => pass = null);
        }
      }
      await pass;
      if (!_disposed && _analyzedPages < _raw.length) await _analyze();
      final doc = _doc;
      if (cache != null && doc != null && !_disposed && _analyzedPages == _total) {
        unawaited(cache.write(widget.path, doc));
      }
    } catch (e) {
      if (!_disposed) setState(() => _error = e);
    } finally {
      if (!_disposed) setState(() => _loading = false);
    }
  }

  /// Index of the first block from page [page] onwards.
  static int _firstBlockOnPage(DocStructure doc, int page) {
    final i = doc.blocks.indexWhere((b) => (b.pageNumber ?? 0) >= page);
    return i < 0 ? 0 : i;
  }

  ReadingProgress? _progress;

  ReadingProgress _progressFor(DocStructure doc) {
    final p = _progress;
    if (p != null && identical(p.doc, doc)) return p;
    return _progress = ReadingProgress(doc);
  }

  /// Page of the block at the top of the screen.
  int? get _currentPage {
    final top = _reflow.topBlock.value;
    final doc = _doc;
    if (top == null || doc == null || top >= doc.blocks.length) return null;
    return doc.blocks[top].pageNumber;
  }

  Future<void> _analyze() async {
    final pages = List.of(_raw);
    try {
      pages.sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
      final doc = await _analyzeInBackground(pages);
      if (_disposed || pages.length <= _analyzedPages) return;
      _analyzedPages = pages.length;
      setState(() => _doc = doc);
    } catch (e) {
      if (!_disposed) setState(() => _error = e);
    }
  }

  void _openOutline(ReadingSettings settings) {
    final doc = _doc;
    if (doc == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: settings.colors.surface,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: doc.headings.isEmpty
            ? Center(
                child: Text('No headings found', style: TextStyle(color: settings.colors.text)),
              )
            : ReflowOutline(
                doc: doc,
                settings: settings,
                onSelect: (i) {
                  Navigator.pop(ctx);
                  _reflow.jumpToBlock(i);
                },
              ),
      ),
    );
  }

  Future<void> _toggleSpeak() async {
    if (_speaking) {
      await _tts.stop();
      setState(() => _speaking = false);
      return;
    }
    final doc = _doc;
    if (doc == null) return;
    setState(() => _speaking = true);
    await _tts.awaitSpeakCompletion(true);
    final start = _reflow.firstVisibleBlock ?? 0;
    for (var i = start; i < doc.blocks.length && _speaking && !_disposed; i++) {
      final text = doc.blocks[i].plainText.trim();
      if (text.isEmpty) continue;
      unawaited(_reflow.jumpToBlock(i));
      for (final chunk in _chunks(text)) {
        if (!_speaking || _disposed) break;
        await _tts.speak(chunk);
      }
    }
    if (!_disposed) setState(() => _speaking = false);
  }

  Iterable<String> _chunks(String text) sync* {
    final sentences = RegExp(
      r'[^.!?]+[.!?]*',
    ).allMatches(text).map((m) => m.group(0)!.trim()).where((s) => s.isNotEmpty);
    final buf = StringBuffer();
    for (final s in sentences) {
      if (buf.length + s.length > 400 && buf.isNotEmpty) {
        yield buf.toString();
        buf.clear();
      }
      buf.write('$s ');
    }
    if (buf.isNotEmpty) yield buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReadingSettings>();
    final colors = settings.colors;
    final doc = _doc;
    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: colors.background,
        appBarTheme: Theme.of(context).appBarTheme.copyWith(
          backgroundColor: colors.background,
          foregroundColor: colors.text,
          iconTheme: IconThemeData(color: colors.text, weight: 300),
          actionsIconTheme: IconThemeData(color: colors.text, weight: 300),
          titleTextStyle: TextStyle(
            fontFamily: 'SourceSans',
            color: colors.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: IconThemeData(color: colors.text, weight: 300),
      ),
      // Back returns the page being read, so the page view opens there.
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.pop(context, _currentPage);
        },
        child: Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    autofocus: true,
                    style: TextStyle(color: colors.text),
                    decoration: InputDecoration(
                      hintText: 'Find in text',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintStyle: TextStyle(color: colors.secondaryText),
                    ),
                    onChanged: (v) => setState(() => _query = v.trim().isEmpty ? null : v.trim()),
                  )
                : const Text('Smart reading'),
            actions: [
              IconButton(
                tooltip: 'Search',
                icon: Icon(_searching ? Symbols.close : Symbols.search),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _query = null;
                }),
              ),
              IconButton(tooltip: 'Outline', icon: const Icon(Symbols.toc), onPressed: () => _openOutline(settings)),
              IconButton(
                tooltip: 'Read aloud',
                icon: Icon(_speaking ? Symbols.stop_circle : Symbols.record_voice_over),
                onPressed: _toggleSpeak,
              ),
              IconButton(
                tooltip: 'Text & theme',
                icon: const Icon(Symbols.text_format),
                onPressed: () => ReadingSettingsSheet.show(context, settings),
              ),
            ],
            bottom: _loading
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(3),
                    child: LinearProgressIndicator(
                      value: _total == 0 ? null : _raw.length / _total,
                      minHeight: 3,
                      color: colors.accent,
                    ),
                  )
                : null,
          ),
          body: _error != null
              ? Center(
                  child: Text(friendlyError(_error!), style: TextStyle(color: colors.text)),
                )
              : doc == null
              ? Center(child: CircularProgressIndicator(color: colors.accent))
              : doc.blocks.isEmpty && !_loading
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No text found. If this is a scanned document, run "Recognize text" first.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.text),
                    ),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: MediaQuery.removePadding(
                        context: context,
                        removeBottom: true,
                        child: ReflowView(
                          doc: doc,
                          initialBlock: _initialBlock,
                          settings: settings,
                          controller: _scroll,
                          reflowController: _reflow,
                          highlightQuery: _query,
                          onOpenPage: (page) => Navigator.pop(context, page),
                          onLinkTap: (link) async {
                            final ok = await confirmDialog(
                              context,
                              title: 'Open link?',
                              message: link,
                              confirmLabel: 'Open',
                            );
                            if (ok) await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
                          },
                        ),
                      ),
                    ),
                    _ProgressFooter(
                      progress: _progressFor(doc),
                      controller: _reflow,
                      loading: _loading,
                      colors: colors,
                      onTap: () => _openOutline(settings),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Top-level so the isolate closure captures only [pages].
Future<DocStructure> _analyzeInBackground(List<RawPageContent> pages) => Isolate.run(() => analyzeDocument(pages));

/// Where the reader is in a document: section, percentage and time left.
class ReadingProgress {
  ReadingProgress(this.doc) {
    final blocks = doc.blocks;
    final levels = blocks.whereType<HeadingBlock>().map((h) => h.level);
    // Sections are headings of the top two levels used, like chapters.
    final maxLevel = levels.isEmpty ? 0 : levels.reduce(math.min) + 1;
    final words = RegExp(r'\S+');
    int? section;
    var total = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i] case HeadingBlock h when h.level <= maxLevel && h.text.trim().isNotEmpty) section = i;
      _section.add(section);
      _wordsBefore.add(total);
      total += words.allMatches(blocks[i].plainText).length;
    }
    totalWords = total;
  }

  /// Average silent reading speed.
  static const wordsPerMinute = 230;

  final DocStructure doc;
  final _section = <int?>[];
  final _wordsBefore = <int>[];
  late final int totalWords;

  /// Heading of the section containing block [i].
  String? sectionAt(int i) {
    final h = i < _section.length ? _section[i] : null;
    return h == null ? null : (doc.blocks[h] as HeadingBlock).text.trim();
  }

  /// Fraction of the words before block [i].
  double fractionAt(int i) => totalWords == 0 || i >= _wordsBefore.length ? 0 : _wordsBefore[i] / totalWords;

  /// Minutes needed to read from block [i] to the end.
  int minutesLeftAt(int i) => i >= _wordsBefore.length ? 0 : ((totalWords - _wordsBefore[i]) / wordsPerMinute).ceil();

  /// "42% · about 25 min left".
  String describe(int i, {bool atEnd = false}) {
    if (atEnd) return '100%';
    final percent = (fractionAt(i) * 100).floor();
    final minutes = minutesLeftAt(i);
    final left = switch (minutes) {
      < 1 => 'less than a minute left',
      < 60 => 'about $minutes min left',
      _ => 'about ${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${minutes % 60} min'} left',
    };
    return '$percent% · $left';
  }
}

class _ProgressFooter extends StatelessWidget {
  const _ProgressFooter({
    required this.progress,
    required this.controller,
    required this.loading,
    required this.colors,
    required this.onTap,
  });

  final ReadingProgress progress;
  final ReflowController controller;
  final bool loading;
  final ReadingThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: colors.secondaryText, fontSize: 12.5);
    return Material(
      color: colors.background,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.paddingOf(context).bottom),
          child: ListenableBuilder(
            listenable: Listenable.merge([controller.topBlock, controller.position]),
            builder: (context, _) {
              final top = controller.topBlock.value ?? 0;
              final section = progress.sectionAt(top) ?? progress.doc.title;
              return Row(
                children: [
                  Expanded(
                    child: Text(section ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    loading ? 'Loading…' : progress.describe(top, atEnd: controller.position.value == 1),
                    style: style,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
