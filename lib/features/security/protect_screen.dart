import 'package:flutter/material.dart';

import '../../core/native/pdf_engine.dart';
import '../../core/session/document_session.dart';
import '../common/dialogs.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Password protection: open password, permissions password and restrictions.
class ProtectScreen extends StatefulWidget {
  const ProtectScreen({super.key, required this.session});

  final DocumentSession session;

  @override
  State<ProtectScreen> createState() => _ProtectScreenState();
}

class _ProtectScreenState extends State<ProtectScreen> {
  DocumentInfo? _info;
  bool _requireOpen = true;
  bool _restrict = false;
  final _open = TextEditingController();
  final _openConfirm = TextEditingController();
  final _owner = TextEditingController();
  bool _allowPrint = true;
  bool _allowCopy = false;
  bool _allowEdit = false;
  bool _allowComments = true;
  bool _allowForms = true;
  bool _aes256 = true;
  bool _busy = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PdfEngine.instance.info(widget.session.path, password: widget.session.password);
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _protect() async {
    if (_requireOpen) {
      if (_open.text.length < 4) return showSnack(context, 'Use a password with at least 4 characters', error: true);
      if (_open.text != _openConfirm.text) return showSnack(context, 'Passwords do not match', error: true);
    }
    if (_restrict && _owner.text.length < 4)
      return showSnack(context, 'Set a permissions password (4+ characters)', error: true);
    if (!_requireOpen && !_restrict) return showSnack(context, 'Choose at least one protection option', error: true);
    if (_requireOpen && _restrict && _open.text == _owner.text) {
      return showSnack(context, 'The permissions password must differ from the open password', error: true);
    }
    setState(() => _busy = true);
    final s = widget.session;
    final userPw = _requireOpen ? _open.text : '';
    try {
      await s.apply(
        'Protect',
        (i, o) => PdfEngine.instance.protect(
          i,
          o,
          password: s.password,
          userPassword: userPw,
          ownerPassword: _restrict ? _owner.text : null,
          keyLength: _aes256 ? 256 : 128,
          permissions: _restrict
              ? {
                  'print': _allowPrint,
                  'printHigh': _allowPrint,
                  'copy': _allowCopy,
                  'extractAccessibility': true,
                  'modify': _allowEdit,
                  'assemble': _allowEdit,
                  'annotate': _allowComments,
                  'fillForms': _allowForms || _allowComments,
                }
              : const {},
        ),
        newPassword: () => userPw.isEmpty ? (_restrict ? _owner.text : null) : userPw,
      );
      if (!mounted) return;
      showSnack(context, 'Document protected');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await confirmDialog(
      context,
      title: 'Remove security?',
      message: 'Anyone will be able to open, print and edit this document.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    final s = widget.session;
    try {
      await s.apply(
        'Remove security',
        (i, o) => PdfEngine.instance.removeSecurity(i, o, password: s.password),
        newPassword: () => null,
      );
      if (!mounted) return;
      showSnack(context, 'Security removed');
      _load();
    } on PdfEngineException catch (e) {
      if (!mounted) return;
      if (e.isPermissionError) {
        final pw = await showTextInputDialog(
          context,
          title: 'Permissions password',
          obscure: true,
          confirmLabel: 'Unlock',
        );
        if (pw == null) return;
        s.password = pw;
        return _remove();
      }
      showSnack(context, e.message, error: true);
    }
  }

  Widget _pwField(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      obscureText: _obscure,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Symbols.visibility : Symbols.visibility_off),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('Protect PDF')),
      body: info == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (info.encrypted)
                  Card(
                    child: ListTile(
                      leading: const Icon(Symbols.lock, color: Colors.green),
                      title: Text(
                        'Protected with ${info.keyLength >= 256
                            ? 'AES-256'
                            : info.keyLength == 128
                            ? '128-bit'
                            : '${info.keyLength}-bit'} encryption',
                      ),
                      subtitle: Text(_permSummary(info.permissions)),
                      trailing: TextButton(onPressed: _remove, child: const Text('Remove')),
                    ),
                  ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _requireOpen,
                  onChanged: (v) => setState(() => _requireOpen = v),
                  title: const Text('Require a password to open'),
                ),
                if (_requireOpen) ...[_pwField(_open, 'Open password'), _pwField(_openConfirm, 'Confirm password')],
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _restrict,
                  onChanged: (v) => setState(() => _restrict = v),
                  title: const Text('Restrict editing and printing'),
                  subtitle: const Text('A permissions password is needed to change these'),
                ),
                if (_restrict) ...[
                  _pwField(_owner, 'Permissions password'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowPrint,
                    onChanged: (v) => setState(() => _allowPrint = v!),
                    title: const Text('Allow printing'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowCopy,
                    onChanged: (v) => setState(() => _allowCopy = v!),
                    title: const Text('Allow copying text and images'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowEdit,
                    onChanged: (v) => setState(() => _allowEdit = v!),
                    title: const Text('Allow editing and page changes'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowComments,
                    onChanged: (v) => setState(() => _allowComments = v!),
                    title: const Text('Allow comments'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _allowForms,
                    onChanged: (v) => setState(() => _allowForms = v!),
                    title: const Text('Allow filling forms and signing'),
                  ),
                ],
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _aes256,
                  onChanged: (v) => setState(() => _aes256 = v),
                  title: const Text('AES-256 encryption'),
                  subtitle: const Text('Turn off for 128-bit (compatible with very old readers)'),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _protect,
                  icon: const Icon(Symbols.lock_outline),
                  label: Text(_busy ? 'Encrypting…' : 'Protect'),
                ),
              ],
            ),
    );
  }

  String _permSummary(Map<String, bool> p) {
    final denied = [
      if (p['print'] == false) 'printing',
      if (p['copy'] == false) 'copying',
      if (p['modify'] == false) 'editing',
      if (p['annotate'] == false) 'comments',
    ];
    return denied.isEmpty ? 'No restrictions' : 'Restricted: ${denied.join(', ')}';
  }
}
