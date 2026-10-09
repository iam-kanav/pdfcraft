import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/native/pdf_engine.dart';
import '../../core/pdf_render.dart';
import '../../core/session/document_session.dart';
import '../common/dialogs.dart';
import 'ocr_service.dart';
import 'package:material_symbols_icons/symbols.dart';

/// "Recognize text": adds an invisible OCR text layer so scanned pages become searchable and selectable.
class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key, required this.session});

  final DocumentSession session;

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> {
  bool _skipText = true;
  bool _running = false;
  String _status = '';
  double? _progress;
  String? _text;
  int _wordCount = 0;
  bool _cancel = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _cancel = false;
      _progress = 0;
      _text = null;
    });
    final s = widget.session;
    final ocr = OcrService();
    final doc = await openPdf(s.path, password: s.password);
    final results = <OcrPageResult>[];
    try {
      final pages = doc.pages;
      for (var i = 0; i < pages.length; i++) {
        if (_cancel) break;
        setState(() {
          _status = 'Recognizing page ${i + 1} of ${pages.length}…';
          _progress = i / pages.length;
        });
        if (_skipText && await OcrService.pageHasText(pages[i])) continue;
        results.add(await ocr.recognizePage(pages[i]));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      await doc.dispose();
      await ocr.close();
    }
    if (_cancel || !mounted) {
      setState(() => _running = false);
      return;
    }
    final withWords = results.where((r) => r.words.isNotEmpty).toList();
    _wordCount = withWords.fold(0, (a, r) => a + r.words.length);
    _text = results.map((r) => '— Page ${r.pageIndex + 1} —\n${r.text}').join('\n\n');
    if (withWords.isEmpty) {
      setState(() {
        _running = false;
        _progress = null;
        _status = results.isEmpty ? 'All pages already contain text.' : 'No text was found on the scanned pages.';
      });
      return;
    }
    setState(() => _status = 'Adding searchable text layer…');
    try {
      await s.apply(
        'Recognize text',
        (i, o) => PdfEngine.instance.addOcrLayer(i, o, {
          for (final r in withWords) r.pageIndex: [for (final w in r.words) (text: w.text, rect: w.rect)],
        }, password: s.password),
      );
      _status =
          'Done: $_wordCount words on ${withWords.length} page${withWords.length == 1 ? '' : 's'} are now searchable.';
    } catch (e) {
      _status = 'Failed: ${friendlyError(e)}';
    }
    if (mounted) {
      setState(() {
        _running = false;
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recognize text (OCR)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Symbols.offline_bolt),
            title: Text('Runs entirely on this device'),
            subtitle: Text(
              'Latin-script languages (English, Spanish, French, German, …). Text becomes searchable and selectable; the page looks unchanged.',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _skipText,
            onChanged: _running ? null : (v) => setState(() => _skipText = v),
            title: const Text('Skip pages that already have text'),
          ),
          const SizedBox(height: 12),
          if (!_running)
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Symbols.document_scanner),
              label: const Text('Recognize text'),
            )
          else
            OutlinedButton(onPressed: () => setState(() => _cancel = true), child: const Text('Cancel')),
          if (_progress != null) ...[const SizedBox(height: 16), LinearProgressIndicator(value: _progress)],
          if (_status.isNotEmpty) ...[const SizedBox(height: 12), Text(_status)],
          if (_text != null && _text!.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Recognized text', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _text!));
                    showSnack(context, 'Copied');
                  },
                  icon: const Icon(Symbols.content_copy, size: 18),
                  label: const Text('Copy'),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(_text!),
            ),
          ],
        ],
      ),
    );
  }
}
