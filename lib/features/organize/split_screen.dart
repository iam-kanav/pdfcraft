import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/library/file_service.dart';
import '../../core/native/pdf_engine.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import '../common/open_actions.dart';

enum SplitMode { everyN, ranges, single }

class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key, required this.path, this.password});

  final String path;
  final String? password;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  int? _count;
  var _mode = SplitMode.everyN;
  final _n = TextEditingController(text: '1');
  final _ranges = TextEditingController();
  List<String>? _outputs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    PdfEngine.instance.info(widget.path, password: widget.password).then((i) => setState(() => _count = i.pageCount)).catchError((Object e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    });
  }

  List<(int, int)> _computeRanges() {
    final count = _count!;
    switch (_mode) {
      case SplitMode.everyN:
        final n = int.tryParse(_n.text.trim()) ?? 0;
        if (n < 1) throw const FormatException('Enter a number of pages');
        return [for (var s = 1; s <= count; s += n) (s, (s + n - 1).clamp(1, count))];
      case SplitMode.single:
        return [for (var i = 1; i <= count; i++) (i, i)];
      case SplitMode.ranges:
        final out = <(int, int)>[];
        for (final part in _ranges.text.split(',')) {
          final t = part.trim();
          if (t.isEmpty) continue;
          final m = RegExp(r'^(\d+)\s*(?:-\s*(\d+))?$').firstMatch(t);
          if (m == null) throw FormatException('Invalid range "$t"');
          final a = int.parse(m.group(1)!), b = int.parse(m.group(2) ?? m.group(1)!);
          if (a < 1 || b > count || a > b) throw FormatException('Range "$t" is outside 1–$count');
          out.add((a, b));
        }
        if (out.isEmpty) throw const FormatException('Enter at least one range');
        return out;
    }
  }

  Future<void> _split() async {
    List<(int, int)> ranges;
    try {
      ranges = _computeRanges();
    } on FormatException catch (e) {
      showSnack(context, e.message, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final base = p.basenameWithoutExtension(widget.path);
      final dir = FileService.uniquePath(p.dirname(widget.path), '$base (split)');
      final outs = await PdfEngine.instance.split(widget.path, dir, sanitizeFileName(base), ranges, password: widget.password);
      setState(() => _outputs = outs);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    return Scaffold(
      appBar: AppBar(title: const Text('Split PDF')),
      body: count == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('${p.basename(widget.path)} · $count pages', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 12),
                RadioListTile(value: SplitMode.everyN, groupValue: _mode, onChanged: (v) => setState(() => _mode = v!), title: const Text('Split every N pages')),
                if (_mode == SplitMode.everyN)
                  Padding(
                    padding: const EdgeInsets.only(left: 56, right: 16),
                    child: TextField(controller: _n, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Pages per file')),
                  ),
                RadioListTile(value: SplitMode.ranges, groupValue: _mode, onChanged: (v) => setState(() => _mode = v!), title: const Text('Custom ranges')),
                if (_mode == SplitMode.ranges)
                  Padding(
                    padding: const EdgeInsets.only(left: 56, right: 16),
                    child: TextField(controller: _ranges, decoration: InputDecoration(labelText: 'Ranges', hintText: 'e.g. 1-3, 4-$count')),
                  ),
                RadioListTile(value: SplitMode.single, groupValue: _mode, onChanged: (v) => setState(() => _mode = v!), title: const Text('One file per page')),
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: _busy ? null : _split, icon: const Icon(Icons.call_split), label: Text(_busy ? 'Splitting…' : 'Split')),
                if (_outputs != null) ...[
                  const SizedBox(height: 16),
                  Text('Created ${_outputs!.length} files in "${p.basename(p.dirname(_outputs!.first))}"', style: Theme.of(context).textTheme.titleSmall),
                  for (final o in _outputs!)
                    ListTile(
                      leading: const Icon(Icons.picture_as_pdf),
                      title: Text(p.basename(o)),
                      subtitle: Text(formatBytes(File(o).lengthSync())),
                      onTap: () => openDocument(context, o),
                    ),
                ],
              ],
            ),
    );
  }
}
