import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../core/native/pdf_engine.dart';
import '../../core/services.dart';
import '../../core/session/document_session.dart';
import '../../core/util/format.dart';
import '../common/dialogs.dart';
import 'protect_screen.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Document properties with editable metadata (title, author, subject, keywords).
class PropertiesScreen extends StatefulWidget {
  const PropertiesScreen({super.key, required this.path, this.session});

  final String path;
  final DocumentSession? session;

  @override
  State<PropertiesScreen> createState() => _PropertiesScreenState();
}

class _PropertiesScreenState extends State<PropertiesScreen> {
  late final DocumentSession _session = widget.session ?? AppServices.instance.newSession(widget.path);
  DocumentInfo? _info;
  Object? _error;
  final _title = TextEditingController();
  final _author = TextEditingController();
  final _subject = TextEditingController();
  final _keywords = TextEditingController();
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await PdfEngine.instance.info(_session.path, password: _session.password);
      _title.text = info.title ?? '';
      _author.text = info.author ?? '';
      _subject.text = info.subject ?? '';
      _keywords.text = info.keywords ?? '';
      setState(() {
        _info = info;
        _error = null;
        _dirty = false;
      });
    } on PdfEngineException catch (e) {
      if (e.isPasswordError && mounted) {
        final pw = await askPassword(context, fileName: _session.name);
        if (pw != null) {
          _session.password = pw;
          return _load();
        }
      }
      setState(() => _error = e);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    try {
      await _session.apply(
        'Edit properties',
        (i, o) => PdfEngine.instance.setMetadata(i, o, {
          'title': _title.text,
          'author': _author.text,
          'subject': _subject.text,
          'keywords': _keywords.text,
        }, password: _session.password),
      );
      if (mounted) showSnack(context, 'Properties saved');
      _load();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _strip() async {
    final ok = await confirmDialog(
      context,
      title: 'Remove all metadata?',
      message: 'Title, author, subject, keywords, creator and XMP metadata are deleted.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    await _session.apply(
      'Remove metadata',
      (i, o) => PdfEngine.instance.setMetadata(
        i,
        o,
        {'title': null, 'author': null, 'subject': null, 'keywords': null, 'creator': null, 'producer': null},
        password: _session.password,
        stripXmp: true,
      ),
    );
    _load();
  }

  Widget _row(String label, String? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        Expanded(child: SelectableText(value == null || value.isEmpty ? '—' : value)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final df = DateFormat.yMMMd().add_jm();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Document properties'),
        actions: [if (_dirty) TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: _error != null
          ? Center(child: Text(friendlyError(_error!)))
          : info == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Description', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final (c, l) in [
                  (_title, 'Title'),
                  (_author, 'Author'),
                  (_subject, 'Subject'),
                  (_keywords, 'Keywords'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: c,
                      decoration: InputDecoration(labelText: l),
                      onChanged: (_) => setState(() => _dirty = true),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _strip,
                  icon: const Icon(Symbols.cleaning_services),
                  label: const Text('Remove all metadata'),
                ),
                const Divider(height: 32),
                Text('File', style: Theme.of(context).textTheme.titleSmall),
                _row('Name', p.basename(_session.path)),
                _row('Location', p.dirname(_session.path)),
                _row('Size', formatBytes(File(_session.path).lengthSync())),
                _row('Pages', '${info.pageCount}'),
                if (info.pages.isNotEmpty)
                  _row(
                    'Page size',
                    '${(info.pages.first.width / 72 * 25.4).toStringAsFixed(0)} × ${(info.pages.first.height / 72 * 25.4).toStringAsFixed(0)} mm (${info.pages.first.width.round()} × ${info.pages.first.height.round()} pt)',
                  ),
                _row('PDF version', info.version.toStringAsFixed(1)),
                _row('Created', info.created == null ? null : df.format(info.created!)),
                _row('Modified', info.modified == null ? null : df.format(info.modified!)),
                _row('Application', info.creator),
                _row('PDF producer', info.producer),
                _row('Form fields', '${info.fieldCount}'),
                const Divider(height: 32),
                Text('Security', style: Theme.of(context).textTheme.titleSmall),
                _row(
                  'Encryption',
                  info.encrypted ? (info.keyLength >= 256 ? 'AES-256' : '${info.keyLength}-bit') : 'None',
                ),
                for (final e in {
                  'print': 'Printing',
                  'copy': 'Copying',
                  'modify': 'Editing',
                  'annotate': 'Commenting',
                  'fillForms': 'Form filling',
                  'assemble': 'Page assembly',
                }.entries)
                  _row(e.value, info.permissions[e.key] == false ? 'Not allowed' : 'Allowed'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => ProtectScreen(session: _session)));
                    _load();
                  },
                  icon: const Icon(Symbols.lock_outline),
                  label: const Text('Security settings'),
                ),
              ],
            ),
    );
  }
}
