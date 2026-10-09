import 'dart:async';

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
      const batch = 6;
      for (var i = 0; i < _total && !_disposed; i += batch) {
        final pages = [for (var k = i; k < (i + batch).clamp(0, _total); k++) k];
        _raw.addAll(await PdfEngine.instance.extractPages(widget.path, password: widget.password, pages: pages));
        if (_disposed) return;
        setState(() => _doc = analyzeDocument(List.of(_raw)));
      }
    } catch (e) {
      if (!_disposed) setState(() => _error = e);
    } finally {
      if (!_disposed) setState(() => _loading = false);
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
            ? Center(child: Text('No headings found', style: TextStyle(color: settings.colors.text)))
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
    final sentences = RegExp(r'[^.!?]+[.!?]*').allMatches(text).map((m) => m.group(0)!.trim()).where((s) => s.isNotEmpty);
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
        appBarTheme: Theme.of(context).appBarTheme.copyWith(backgroundColor: colors.surface, foregroundColor: colors.text, titleTextStyle: TextStyle(color: colors.text, fontSize: 18, fontWeight: FontWeight.w600)),
        iconTheme: IconThemeData(color: colors.text),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  autofocus: true,
                  style: TextStyle(color: colors.text),
                  decoration: InputDecoration(hintText: 'Find in text', filled: false, border: InputBorder.none, hintStyle: TextStyle(color: colors.secondaryText)),
                  onChanged: (v) => setState(() => _query = v.trim().isEmpty ? null : v.trim()),
                )
              : const Text('Smart reading'),
          actions: [
            IconButton(
              tooltip: 'Search',
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _query = null;
              }),
            ),
            IconButton(tooltip: 'Outline', icon: const Icon(Icons.toc), onPressed: () => _openOutline(settings)),
            IconButton(tooltip: 'Read aloud', icon: Icon(_speaking ? Icons.stop_circle_outlined : Icons.record_voice_over_outlined), onPressed: _toggleSpeak),
            IconButton(tooltip: 'Text & theme', icon: const Icon(Icons.text_format), onPressed: () => ReadingSettingsSheet.show(context, settings)),
          ],
          bottom: _loading
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: _total == 0 ? null : _raw.length / _total, minHeight: 3, color: colors.accent),
                )
              : null,
        ),
        body: _error != null
            ? Center(child: Text(friendlyError(_error!), style: TextStyle(color: colors.text)))
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
