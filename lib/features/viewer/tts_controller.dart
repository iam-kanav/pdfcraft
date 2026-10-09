import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/services.dart';
import 'viewer_screen.dart';

/// A sentence-sized piece of page text to speak.
class TtsChunk {
  TtsChunk(this.page, this.start, this.end, this.text);

  final int page;
  final int start;
  final int end;
  final String text;
}

/// Splits [text] into sentence chunks (keeps character offsets).
List<TtsChunk> splitSentences(int page, String text, {int maxLength = 280}) {
  final chunks = <TtsChunk>[];
  final re = RegExp(r'[^.!?\n]+(?:[.!?]+["”’)]?|\n|$)');
  for (final m in re.allMatches(text)) {
    var s = m.start;
    final e = m.end;
    while (s < e) {
      var end = e;
      if (end - s > maxLength) {
        end = text.lastIndexOf(' ', s + maxLength);
        if (end <= s) end = s + maxLength;
      }
      final t = text.substring(s, end).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty && RegExp(r'\w').hasMatch(t)) chunks.add(TtsChunk(page, s, end, t));
      s = end;
    }
  }
  return chunks;
}

/// Read-aloud using the device's offline text-to-speech engine.
class TtsController extends ChangeNotifier {
  TtsController({required this.host});

  final ViewerHost host;
  final FlutterTts _tts = FlutterTts();
  bool active = false;
  bool playing = false;
  int _page = 1;
  List<TtsChunk> _chunks = [];
  int _index = 0;
  PdfPageRawText? _text;
  int _session = 0;
  bool _initialized = false;

  TtsChunk? get current => playing || active ? (_index < _chunks.length ? _chunks[_index] : null) : null;
  int get page => _page;

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    await _tts.awaitSpeakCompletion(true);
    final s = AppServices.instance.settings;
    await _tts.setSpeechRate(s.ttsRate);
    await _tts.setPitch(s.ttsPitch);
  }

  Future<void> applySettings() async {
    final s = AppServices.instance.settings;
    await _tts.setSpeechRate(s.ttsRate);
    await _tts.setPitch(s.ttsPitch);
  }

  Future<void> start({required int fromPage}) async {
    await _init();
    active = true;
    _page = fromPage;
    notifyListeners();
    await _loadPage(_page);
    _play();
  }

  /// Speaks arbitrary text (e.g. a selection) without page tracking.
  Future<void> speakText(String text) async {
    await _init();
    await stop();
    active = true;
    playing = true;
    _chunks = [];
    notifyListeners();
    final session = ++_session;
    for (final c in splitSentences(0, text)) {
      if (session != _session) return;
      await _tts.speak(c.text);
    }
    if (session == _session) {
      active = false;
      playing = false;
      notifyListeners();
    }
  }

  Future<void> _loadPage(int page) async {
    final doc = host.document;
    if (doc == null) return;
    _text = await doc.pages[page - 1].loadText();
    _chunks = splitSentences(page, _text?.fullText ?? '');
    _index = 0;
  }

  Future<void> _play() async {
    final session = ++_session;
    playing = true;
    notifyListeners();
    final doc = host.document;
    while (session == _session && doc != null) {
      if (_index >= _chunks.length) {
        if (_page >= doc.pages.length) break;
        _page++;
        await _loadPage(_page);
        if (session != _session) return;
        unawaited(host.controller.goToPage(pageNumber: _page));
        continue;
      }
      host.controller.invalidate();
      notifyListeners();
      final result = await _tts.speak(_chunks[_index].text);
      if (session != _session) return;
      if (result != 1) break;
      _index++;
    }
    if (session == _session) {
      playing = false;
      if (_index >= _chunks.length) active = false;
      host.controller.invalidate();
      notifyListeners();
    }
  }

  Future<void> pause() async {
    _session++;
    playing = false;
    await _tts.stop();
    notifyListeners();
  }

  Future<void> resume() async {
    if (!active) return;
    _play();
  }

  Future<void> skip(int delta) async {
    _session++;
    await _tts.stop();
    _index = (_index + delta).clamp(0, _chunks.isEmpty ? 0 : _chunks.length - 1);
    _play();
  }

  Future<void> stop() async {
    _session++;
    active = false;
    playing = false;
    await _tts.stop();
    try {
      host.controller.invalidate();
    } catch (_) {}
    notifyListeners();
  }

  /// Highlights the sentence being spoken.
  void paintCallback(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    final c = current;
    final text = _text;
    if (c == null || text == null || c.page != page.pageNumber) return;
    final paint = Paint()..color = const Color(0x5534A0FF);
    for (var i = c.start; i < c.end && i < text.charRects.length; i++) {
      final r = text.charRects[i].toRectInDocument(page: page, pageRect: pageRect);
      if (r.width > 0) canvas.drawRect(r.inflate(0.5), paint);
    }
  }

  @override
  void dispose() {
    _session++;
    _tts.stop();
    super.dispose();
  }
}

class TtsBar extends StatelessWidget {
  const TtsBar({super.key, required this.tts});

  final TtsController tts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(28),
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(Icons.record_voice_over, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(tts.current == null ? 'Read aloud' : 'Reading page ${tts.page}', maxLines: 1)),
            IconButton(tooltip: 'Previous sentence', icon: const Icon(Icons.skip_previous), onPressed: () => tts.skip(-1)),
            IconButton(
              tooltip: tts.playing ? 'Pause' : 'Play',
              icon: Icon(tts.playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 34, color: scheme.primary),
              onPressed: () => tts.playing ? tts.pause() : tts.resume(),
            ),
            IconButton(tooltip: 'Next sentence', icon: const Icon(Icons.skip_next), onPressed: () => tts.skip(1)),
            IconButton(tooltip: 'Stop', icon: const Icon(Icons.close), onPressed: tts.stop),
          ],
        ),
      ),
    );
  }
}
