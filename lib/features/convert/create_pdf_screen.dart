import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import '../../core/file_picking.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;

import '../../core/services.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../common/open_actions.dart';
import '../scanner/scanner_screen.dart';
import 'convert_service.dart';
import 'engine/convert_engine.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Create a PDF from images, documents (Word, text, Markdown, Excel) or a scan.
class CreatePdfScreen extends StatefulWidget {
  const CreatePdfScreen({super.key, this.initialImages = const []});

  final List<String> initialImages;

  @override
  State<CreatePdfScreen> createState() => _CreatePdfScreenState();
}

class _CreatePdfScreenState extends State<CreatePdfScreen> {
  late final List<String> _images = [...widget.initialImages];
  var _pageSize = ImagePageSize.a4;
  var _orientation = PdfPageOrientationMode.auto;
  double _margin = 18;
  bool _busy = false;
  final _name = TextEditingController(text: 'Images ${DateTime.now().toIso8601String().substring(0, 10)}');

  Future<void> _addImages() async {
    final r = await pickLocalFiles(type: FileType.image, multiple: true);
    setState(() => _images.addAll(r.map((f) => f.path)));
  }

  Future<void> _fromDocument() async {
    final r = await pickLocalFile(type: FileType.custom, extensions: ConvertService.documentExtensions);
    if (r == null || !mounted) return;
    final path = r.path;
    final name = r.name;
    final out = await runWithProgress(context, 'Converting ${p.basename(name)}…', () async {
      final bytes = await ConvertService.documentToPdf(path, title: p.basenameWithoutExtension(name));
      final target = AppServices.instance.files.outputPath('${sanitizeFileName(p.basenameWithoutExtension(name))}.pdf');
      await File(target).writeAsBytes(bytes);
      return target;
    });
    if (out != null && mounted) {
      Navigator.pop(context);
      await openDocument(context, out);
    }
  }

  Future<void> _createFromImages() async {
    if (_images.isEmpty) return;
    setState(() => _busy = true);
    try {
      final bytes = <Uint8List>[for (final f in _images) await File(f).readAsBytes()];
      final pdf = await buildPdfFromImages(
        bytes,
        pageSize: _pageSize,
        orientation: _orientation,
        margin: _pageSize == ImagePageSize.fitImage ? 0 : _margin,
        title: _name.text,
      );
      final out = AppServices.instance.files.outputPath(
        '${sanitizeFileName(_name.text.trim().isEmpty ? 'Images' : _name.text.trim())}.pdf',
      );
      await File(out).writeAsBytes(pdf);
      if (!mounted) return;
      Navigator.pop(context);
      await openDocument(context, out);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _blank() async {
    final out = await runWithProgress(context, 'Creating…', () async {
      final doc = pw.Document(title: 'Blank', creator: 'PDFCraft')
        ..addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.SizedBox()));
      final bytes = await doc.save();
      final target = AppServices.instance.files.outputPath('Blank.pdf');
      await File(target).writeAsBytes(bytes);
      return target;
    });
    if (out != null && mounted) {
      Navigator.pop(context);
      await openDocument(context, out);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create PDF')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SourceCard(
                  icon: Symbols.document_scanner,
                  label: 'Scan',
                  onTap: () =>
                      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ScannerScreen())),
                ),
                const SizedBox(width: 8),
                _SourceCard(
                  icon: Symbols.description,
                  label: 'Document',
                  subtitle: 'Word, text, Markdown, Excel',
                  onTap: _fromDocument,
                ),
                const SizedBox(width: 8),
                _SourceCard(icon: Symbols.note_add, label: 'Blank', onTap: _blank),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'From images',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _addImages,
                icon: const Icon(Symbols.add_photo_alternate),
                label: const Text('Add'),
              ),
            ],
          ),
          if (_images.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: _addImages,
                  icon: const Icon(Symbols.image),
                  label: const Text('Choose images'),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 150,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _images.length,
                onReorderItem: (a, b) => setState(() {
                  _images.insert(b, _images.removeAt(a));
                }),
                itemBuilder: (context, i) => Padding(
                  key: ValueKey('${_images[i]}#$i'),
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(_images[i]),
                          width: 100,
                          height: 140,
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(28, 28),
                          ),
                          iconSize: 16,
                          onPressed: () => setState(() => _images.removeAt(i)),
                          icon: const Icon(Symbols.close),
                        ),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: CircleAvatar(radius: 11, child: Text('${i + 1}', style: const TextStyle(fontSize: 11))),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ImagePageSize>(
              initialValue: _pageSize,
              decoration: const InputDecoration(labelText: 'Page size'),
              items: const [
                DropdownMenuItem(value: ImagePageSize.a4, child: Text('A4')),
                DropdownMenuItem(value: ImagePageSize.letter, child: Text('US Letter')),
                DropdownMenuItem(value: ImagePageSize.fitImage, child: Text('Fit to image')),
              ],
              onChanged: (v) => setState(() => _pageSize = v!),
            ),
            if (_pageSize != ImagePageSize.fitImage) ...[
              const SizedBox(height: 12),
              SegmentedButton<PdfPageOrientationMode>(
                segments: const [
                  ButtonSegment(value: PdfPageOrientationMode.auto, label: Text('Auto')),
                  ButtonSegment(value: PdfPageOrientationMode.portrait, label: Text('Portrait')),
                  ButtonSegment(value: PdfPageOrientationMode.landscape, label: Text('Landscape')),
                ],
                selected: {_orientation},
                onSelectionChanged: (v) => setState(() => _orientation = v.first),
              ),
              const SizedBox(height: 8),
              Text('Margin: ${_margin.round()} pt'),
              Slider(value: _margin, min: 0, max: 72, onChanged: (v) => setState(() => _margin = v)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _createFromImages,
              icon: const Icon(Symbols.picture_as_pdf),
              label: Text(_busy ? 'Creating…' : 'Create PDF (${_images.length} page${_images.length == 1 ? '' : 's'})'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.icon, required this.label, required this.onTap, this.subtitle});

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 30, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (subtitle != null)
                Text(subtitle!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    ),
  );
}
