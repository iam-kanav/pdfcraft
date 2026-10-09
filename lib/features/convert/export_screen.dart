import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/native/pdf_engine.dart';
import '../../core/services.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../common/open_actions.dart';
import 'convert_service.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Export a PDF to Word, text, HTML, Markdown or images — fully offline.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.path, this.password});

  final String path;
  final String? password;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  var _format = ExportFormat.word;
  final _range = TextEditingController();
  double _dpi = 150;
  double? _progress;
  String? _result;
  int? _pageCount;

  @override
  void initState() {
    super.initState();
    PdfEngine.instance
        .info(widget.path, password: widget.password)
        .then((i) {
          if (mounted) setState(() => _pageCount = i.pageCount);
        })
        .catchError((Object e) {
          if (mounted) showSnack(context, friendlyError(e), error: true);
        });
  }

  Future<void> _export() async {
    List<int>? pages;
    if (_range.text.trim().isNotEmpty) {
      try {
        pages = parsePageRanges(_range.text, _pageCount ?? 1).map((e) => e - 1).toList();
      } on FormatException catch (e) {
        showSnack(context, e.message, error: true);
        return;
      }
    }
    setState(() {
      _progress = 0;
      _result = null;
    });
    try {
      final out = await ConvertService.exportPdf(
        widget.path,
        _format,
        AppServices.instance.files.convertedDir.path,
        password: widget.password,
        pages: pages,
        dpi: _dpi,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
      );
      if (mounted) setState(() => _result = out);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Export PDF')),
      body: RadioGroup<ExportFormat>(
        groupValue: _format,
        onChanged: (v) => setState(() => _format = v!),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(p.basename(widget.path), style: Theme.of(context).textTheme.titleSmall),
            if (_pageCount != null) Text('$_pageCount pages', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            for (final f in ExportFormat.values)
              RadioListTile<ExportFormat>(
                value: f,
                enabled: !busy,
                title: Text(f.label),
                subtitle: Text(f.description),
                secondary: Icon(switch (f) {
                  ExportFormat.word => Symbols.description,
                ExportFormat.excel => Symbols.table_chart,
                ExportFormat.powerpoint => Symbols.slideshow,
                  ExportFormat.text => Symbols.notes,
                  ExportFormat.html => Symbols.html,
                  ExportFormat.markdown => Symbols.text_snippet,
                  _ => Symbols.image,
                }),
              ),
            if (_format.isImage) ...[
              Text('Resolution: ${_dpi.round()} dpi'),
              Slider(
                value: _dpi,
                min: 72,
                max: 300,
                divisions: 19,
                onChanged: busy ? null : (v) => setState(() => _dpi = v),
              ),
            ],
            TextField(
              controller: _range,
              enabled: !busy,
              decoration: const InputDecoration(labelText: 'Pages (optional)', hintText: 'All pages, or e.g. 1-3, 7'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : _export,
              icon: const Icon(Symbols.ios_share),
              label: Text(busy ? 'Exporting…' : 'Export'),
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            ],
            if (_result != null) ...[
              const SizedBox(height: 20),
              Card(
                child: ListTile(
                  leading: const Icon(Symbols.check_circle, color: Colors.green),
                  title: Text(p.basename(_result!)),
                  subtitle: Text('${formatBytes(File(_result!).lengthSync())} · saved in My Files/Converted'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => shareFiles([_result!]),
                      icon: const Icon(Symbols.share),
                      label: const Text('Share'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => saveCopyToDownloads(context, _result!),
                      icon: const Icon(Symbols.download),
                      label: const Text('Downloads'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
