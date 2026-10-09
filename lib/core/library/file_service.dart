import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/format.dart';

enum SortField { name, date, size }

class FileEntry {
  FileEntry({
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.childCount = 0,
  });

  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;
  final int childCount;

  String get name => p.basename(path);
  String get extension => p.extension(path).toLowerCase();
  bool get isPdf => extension == '.pdf';

  static FileEntry? fromEntity(FileSystemEntity e) {
    try {
      final stat = e.statSync();
      if (stat.type == FileSystemEntityType.notFound) return null;
      final isDir = stat.type == FileSystemEntityType.directory;
      var count = 0;
      if (isDir) {
        try {
          count = Directory(e.path).listSync().where((c) => !p.basename(c.path).startsWith('.')).length;
        } catch (_) {}
      }
      return FileEntry(path: e.path, isDirectory: isDir, size: stat.size, modified: stat.modified, childCount: count);
    } catch (_) {
      return null;
    }
  }
}

/// Supported document types shown in the file browser.
const kDocumentExtensions = {'.pdf'};

/// Local document library rooted at the app's "PDFCraft" folder.
class FileService {
  FileService(this.root);

  final Directory root;

  Future<void> ensureRoot() async {
    await root.create(recursive: true);
    for (final d in ['Scans', 'Converted']) {
      await Directory(p.join(root.path, d)).create(recursive: true);
    }
  }

  Directory get scansDir => Directory(p.join(root.path, 'Scans'));
  Directory get convertedDir => Directory(p.join(root.path, 'Converted'));

  bool isInLibrary(String path) => p.isWithin(root.path, path) || p.equals(root.path, path);

  Future<List<FileEntry>> list(
    Directory dir, {
    SortField sort = SortField.date,
    bool descending = true,
    Set<String> extensions = kDocumentExtensions,
  }) async {
    final entries = <FileEntry>[];
    if (!await dir.exists()) return entries;
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      final entry = FileEntry.fromEntity(e);
      if (entry == null) continue;
      if (!entry.isDirectory && !extensions.contains(entry.extension)) continue;
      entries.add(entry);
    }
    return sortEntries(entries, sort, descending);
  }

  static List<FileEntry> sortEntries(List<FileEntry> entries, SortField sort, bool descending) {
    int cmp(FileEntry a, FileEntry b) {
      final r = switch (sort) {
        SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortField.date => a.modified.compareTo(b.modified),
        SortField.size => a.size.compareTo(b.size),
      };
      return descending ? -r : r;
    }

    final dirs = entries.where((e) => e.isDirectory).toList()
      ..sort(sort == SortField.size ? (a, b) => a.name.compareTo(b.name) : cmp);
    final files = entries.where((e) => !e.isDirectory).toList()..sort(cmp);
    return [...dirs, ...files];
  }

  /// Recursively finds documents whose name contains [query] (case-insensitive).
  Future<List<FileEntry>> search(String query, {Directory? under}) async {
    final q = query.toLowerCase().trim();
    final results = <FileEntry>[];
    if (q.isEmpty) return results;
    final base = under ?? root;
    if (!await base.exists()) return results;
    await for (final e in base.list(recursive: true, followLinks: false)) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      if (!name.toLowerCase().contains(q)) continue;
      final entry = FileEntry.fromEntity(e);
      if (entry == null) continue;
      if (!entry.isDirectory && !kDocumentExtensions.contains(entry.extension)) continue;
      results.add(entry);
    }
    return sortEntries(results, SortField.name, false);
  }

  /// A path in [dir] named [name], adding " (2)", " (3)"… if needed.
  static String uniquePath(String dir, String name) {
    final clean = sanitizeFileName(name);
    final ext = p.extension(clean);
    final stem = p.basenameWithoutExtension(clean);
    var candidate = p.join(dir, clean);
    var i = 2;
    while (File(candidate).existsSync() || Directory(candidate).existsSync()) {
      candidate = p.join(dir, '$stem ($i)$ext');
      i++;
    }
    return candidate;
  }

  Future<Directory> createFolder(Directory parent, String name) async {
    final path = uniquePath(parent.path, name);
    return Directory(path).create(recursive: true);
  }

  /// Renames keeping the extension for files when the user omits it. Returns the new path.
  Future<String> rename(String path, String newName) async {
    final isDir = await FileSystemEntity.isDirectory(path);
    var name = sanitizeFileName(newName);
    if (!isDir && p.extension(name).isEmpty) name += p.extension(path);
    final target = p.join(p.dirname(path), name);
    if (p.equals(target, path)) return path;
    if (await File(target).exists() || await Directory(target).exists()) {
      throw FileSystemException('An item named "$name" already exists', target);
    }
    final entity = isDir ? Directory(path) : File(path);
    final renamed = await entity.rename(target);
    return renamed.path;
  }

  Future<String> move(String path, Directory dest) async {
    final isDir = await FileSystemEntity.isDirectory(path);
    if (isDir && (p.equals(dest.path, path) || p.isWithin(path, dest.path))) {
      throw FileSystemException('Cannot move a folder into itself', path);
    }
    final target = uniquePath(dest.path, p.basename(path));
    try {
      return (await (isDir ? Directory(path) : File(path)).rename(target)).path;
    } on FileSystemException {
      if (isDir) rethrow;
      await File(path).copy(target);
      await File(path).delete();
      return target;
    }
  }

  Future<String> copy(String path, Directory dest, {String? name}) async {
    final target = uniquePath(dest.path, name ?? p.basename(path));
    await File(path).copy(target);
    return target;
  }

  Future<String> duplicate(String path) async {
    final stem = p.basenameWithoutExtension(path);
    return copy(path, Directory(p.dirname(path)), name: '$stem copy${p.extension(path)}');
  }

  Future<void> delete(String path) async {
    if (await FileSystemEntity.isDirectory(path)) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
  }

  /// Copies an external file into the library (root or [into]). Returns the new path.
  /// If an identical file with the same name (or a numbered variant) already exists, it is reused.
  Future<String> import(String source, {Directory? into, String? name}) async {
    final dest = into ?? root;
    await dest.create(recursive: true);
    final fileName = sanitizeFileName(name ?? p.basename(source));
    final existing = await _findIdentical(source, dest, fileName);
    if (existing != null) return existing;
    return copy(source, dest, name: fileName);
  }

  Future<String?> _findIdentical(String source, Directory dest, String fileName) async {
    final src = File(source);
    final size = await src.length();
    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    final candidates = [p.join(dest.path, fileName), for (var i = 2; i < 20; i++) p.join(dest.path, '$stem ($i)$ext')];
    List<int>? srcBytes;
    for (final c in candidates) {
      final f = File(c);
      if (!await f.exists() || await f.length() != size) continue;
      srcBytes ??= await src.readAsBytes();
      final other = await f.readAsBytes();
      var same = true;
      for (var i = 0; i < other.length; i++) {
        if (other[i] != srcBytes[i]) {
          same = false;
          break;
        }
      }
      if (same) return c;
    }
    return null;
  }

  /// Path for a new output document (e.g. "Report_compressed.pdf") next to the library root.
  String outputPath(String desiredName, {Directory? dir}) => uniquePath((dir ?? root).path, desiredName);
}
