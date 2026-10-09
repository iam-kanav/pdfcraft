import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// An open document with undoable, file-backed edits.
///
/// Every edit is executed by an operation that reads [path] and writes a new file;
/// the previous version is kept as a snapshot for undo. Edits are saved to the
/// document immediately (like Acrobat's auto-save).
class DocumentSession extends ChangeNotifier {
  DocumentSession({required String path, this.password, required this.tempDir}) : _path = path;

  String _path;
  String? password;
  final Directory tempDir;

  int _revision = 0;
  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];
  String? _busyLabel;
  static const _maxUndo = 20;

  String get path => _path;
  String get name => p.basename(_path);

  /// Incremented every time the file content changes; viewers reload on change.
  int get revision => _revision;
  bool get canUndo => _undo.isNotEmpty && _busyLabel == null;
  bool get canRedo => _redo.isNotEmpty && _busyLabel == null;
  bool get isBusy => _busyLabel != null;
  String? get busyLabel => _busyLabel;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;

  void updatePath(String newPath) {
    _path = newPath;
    notifyListeners();
  }

  int _tmpCounter = 0;
  String newTempPath([String ext = '.pdf']) {
    tempDir.createSync(recursive: true);
    return p.join(tempDir.path, 'v${DateTime.now().microsecondsSinceEpoch}_${_tmpCounter++}$ext');
  }

  /// Runs [op] producing a new version of the document at `out`, then makes it current.
  /// If [newPassword] is provided it replaces the session password (e.g. after protecting).
  Future<T> apply<T>(
    String label,
    Future<T> Function(String input, String out) op, {
    String? Function()? newPassword,
  }) async {
    if (_busyLabel != null) throw StateError('Another operation is in progress');
    _busyLabel = label;
    notifyListeners();
    final out = newTempPath();
    try {
      final result = await op(_path, out);
      if (!await File(out).exists()) throw StateError('The operation produced no output');
      final snapshot = newTempPath();
      await File(_path).copy(snapshot);
      _undo.add(_Snapshot(snapshot, label, password));
      while (_undo.length > _maxUndo) {
        _deleteQuietly(_undo.removeAt(0).file);
      }
      for (final s in _redo) {
        _deleteQuietly(s.file);
      }
      _redo.clear();
      await _replaceWith(out);
      if (newPassword != null) password = newPassword();
      _revision++;
      return result;
    } finally {
      _deleteQuietly(out);
      _busyLabel = null;
      notifyListeners();
    }
  }

  Future<void> undo() async {
    if (!canUndo) return;
    final s = _undo.removeLast();
    final current = newTempPath();
    await File(_path).copy(current);
    _redo.add(_Snapshot(current, s.label, password));
    await _replaceWith(s.file);
    password = s.password;
    _deleteQuietly(s.file);
    _revision++;
    notifyListeners();
  }

  Future<void> redo() async {
    if (!canRedo) return;
    final s = _redo.removeLast();
    final current = newTempPath();
    await File(_path).copy(current);
    _undo.add(_Snapshot(current, s.label, password));
    await _replaceWith(s.file);
    password = s.password;
    _deleteQuietly(s.file);
    _revision++;
    notifyListeners();
  }

  /// Atomically replaces the document file (rename keeps any open readers on the old inode).
  Future<void> _replaceWith(String source) async {
    final staged = '${p.join(p.dirname(_path), '.${p.basename(_path)}')}.${DateTime.now().microsecondsSinceEpoch}.tmp';
    await File(source).copy(staged);
    await File(staged).rename(_path);
  }

  /// Marks the document as changed by an external writer (e.g. a full replacement).
  void markChanged() {
    _revision++;
    notifyListeners();
  }

  void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final s in [..._undo, ..._redo]) {
      _deleteQuietly(s.file);
    }
    super.dispose();
  }
}

class _Snapshot {
  _Snapshot(this.file, this.label, this.password);

  final String file;
  final String label;
  final String? password;
}
