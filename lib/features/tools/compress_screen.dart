import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/library/file_service.dart';
import '../../core/native/pdf_engine.dart';
import '../../core/session/document_session.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../common/open_actions.dart';
import 'package:material_symbols_icons/symbols.dart';

enum CompressLevel {
  low('Low', 'Best quality, smaller savings', 220, 0.85),
  medium('Medium', 'Good balance of quality and size', 150, 0.7),
  high('High', 'Smallest file, lower image quality', 96, 0.5);

  const CompressLevel(this.label, this.description, this.dpi, this.quality);

  final String label;
  final String description;
  final double dpi;
  final double quality;
}

class CompressScreen extends StatefulWidget {
  const CompressScreen({super.key, required this.session});

  final DocumentSession session;

  @override
  State<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends State<CompressScreen> {
  var _level = CompressLevel.medium;
  var _grayscale = false;
  var _saveCopy = false;
  ({int before, int after, int images})? _result;
  String? _outPath;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final s = widget.session;
    try {
      if (_saveCopy) {
        final out = FileService.uniquePath(p.dirname(s.path), '${p.basenameWithoutExtension(s.path)}_compressed.pdf');
        final r = await PdfEngine.instance.compress(
          s.path,
          out,
          password: s.password,
          dpi: _level.dpi,
          quality: _level.quality,
          grayscale: _grayscale,
        );
        setState(() {
          _result = r;
          _outPath = out;
        });
      } else {
        final r = await s.apply(
          'Compress',
          (i, o) => PdfEngine.instance.compress(
            i,
            o,
            password: s.password,
            dpi: _level.dpi,
            quality: _level.quality,
            grayscale: _grayscale,
          ),
        );
        setState(() {
          _result = r;
          _outPath = s.path;
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = File(widget.session.path).lengthSync();
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Compress PDF')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Symbols.picture_as_pdf, size: 36),
            title: Text(widget.session.name),
            subtitle: Text('Current size: ${formatBytes(r?.before ?? size)}'),
          ),
          const SizedBox(height: 8),
          for (final l in CompressLevel.values)
            RadioListTile<CompressLevel>(
              value: l,
              groupValue: _level,
              onChanged: _running ? null : (v) => setState(() => _level = v!),
              title: Text(l.label),
              subtitle: Text('${l.description} · images at ${l.dpi.round()} dpi'),
            ),
          SwitchListTile(
            value: _grayscale,
            onChanged: _running ? null : (v) => setState(() => _grayscale = v),
            title: const Text('Convert images to grayscale'),
          ),
          SwitchListTile(
            value: _saveCopy,
            onChanged: _running ? null : (v) => setState(() => _saveCopy = v),
            title: const Text('Save as a new file'),
            subtitle: const Text('Keep the original unchanged'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Symbols.compress),
            label: Text(_running ? 'Compressing…' : 'Compress'),
          ),
          if (r != null) ...[
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.after < r.before
                          ? 'Reduced by ${(100 - r.after * 100 / r.before).toStringAsFixed(0)}%'
                          : 'This file is already well optimized',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${formatBytes(r.before)} → ${formatBytes(r.after)} · ${r.images} image${r.images == 1 ? '' : 's'} re-encoded',
                    ),
                    if (_outPath != null && _outPath != widget.session.path) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          OutlinedButton(onPressed: () => openDocument(context, _outPath!), child: const Text('Open')),
                          const SizedBox(width: 8),
                          OutlinedButton(onPressed: () => shareFiles([_outPath!]), child: const Text('Share')),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
