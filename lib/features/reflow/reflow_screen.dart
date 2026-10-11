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
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await PdfEngine.instance.info(widget.path, password: widget.password);
      _total = info.pageCount;
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
          await PdfEngine.instance.extractPages(
            widget.path,
            password: widget.password,
            pages: [for (var k = from; k < to; k++) k],
          ),
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
    } catch (e) {
      if (!_disposed) setState(() => _error = e);
    } finally {
      if (!_disposed) setState(() => _loading = false);
    }
  }

  Future<void> _analyze() async {
    final pages = List.of(_raw);
    try {
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
            : ReflowView(
                doc: doc,
                settings: settings,
                controller: _scroll,
                reflowController: _reflow,
                highlightQuery: _query,
                onOpenPage: (page) => Navigator.pop(context, page),
                onLinkTap: (link) async {
                  final ok = await confirmDialog(context, title: 'Open link?', message: link, confirmLabel: 'Open');
                  if (ok) await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
                },
              ),
      ),
    );
  }
}

/// Top-level so the isolate closure captures only [pages].
Future<DocStructure> _analyzeInBackground(List<RawPageContent> pages) => Isolate.run(() => analyzeDocument(pages));
