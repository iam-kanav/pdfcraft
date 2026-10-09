import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class Bookmark {
  Bookmark({required this.page, required this.label, DateTime? created}) : created = created ?? DateTime.now();

  /// 1-based page number.
  final int page;
  String label;
  final DateTime created;

  Map<String, Object?> toJson() => {'page': page, 'label': label, 'created': created.millisecondsSinceEpoch};

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
    page: j['page'] as int,
    label: j['label'] as String? ?? 'Page ${j['page']}',
    created: DateTime.fromMillisecondsSinceEpoch(j['created'] as int? ?? 0),
  );
}

/// Per-document metadata tracked by the app (not stored inside the PDF).
class DocRecord {
  DocRecord({
    required this.path,
    this.lastOpened,
    this.starred = false,
    this.lastPage = 1,
    List<Bookmark>? bookmarks,
    this.pageCount,
  }) : bookmarks = bookmarks ?? [];

  String path;
  DateTime? lastOpened;
  bool starred;
  int lastPage;
  int? pageCount;
  final List<Bookmark> bookmarks;

  Map<String, Object?> toJson() => {
    'path': path,
    'lastOpened': lastOpened?.millisecondsSinceEpoch,
    'starred': starred,
    'lastPage': lastPage,
    'pageCount': pageCount,
    'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
  };

  factory DocRecord.fromJson(Map<String, dynamic> j) => DocRecord(
    path: j['path'] as String,
    lastOpened: j['lastOpened'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['lastOpened'] as int),
    starred: j['starred'] as bool? ?? false,
    lastPage: j['lastPage'] as int? ?? 1,
    pageCount: j['pageCount'] as int?,
    bookmarks: [for (final b in (j['bookmarks'] as List? ?? const [])) Bookmark.fromJson((b as Map).cast<String, dynamic>())],
  );
}

/// JSON-backed store of recents, stars, reading positions and bookmarks.
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.file);

  final File file;
  final Map<String, DocRecord> _records = {};
  Timer? _saveTimer;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final r in (data['records'] as List? ?? const [])) {
          final rec = DocRecord.fromJson((r as Map).cast<String, dynamic>());
          _records[rec.path] = rec;
        }
      }
    } catch (e) {
      debugPrint('Library load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  DocRecord record(String path) => _records.putIfAbsent(path, () => DocRecord(path: path));

  DocRecord? peek(String path) => _records[path];

  /// Recently opened documents that still exist, newest first.
  List<DocRecord> get recents {
    final list = _records.values.where((r) => r.lastOpened != null && File(r.path).existsSync()).toList()
      ..sort((a, b) => b.lastOpened!.compareTo(a.lastOpened!));
    return list;
  }

  List<DocRecord> get starred =>
      _records.values.where((r) => r.starred && File(r.path).existsSync()).toList()
        ..sort((a, b) => (b.lastOpened ?? DateTime(0)).compareTo(a.lastOpened ?? DateTime(0)));

  bool isStarred(String path) => _records[path]?.starred ?? false;

  void markOpened(String path, {int? pageCount}) {
    final r = record(path);
    r.lastOpened = DateTime.now();
    if (pageCount != null) r.pageCount = pageCount;
    _changed();
  }

  void setLastPage(String path, int page) {
    final r = record(path);
    if (r.lastPage == page) return;
    r.lastPage = page;
    _scheduleSave();
  }

  void toggleStar(String path) {
    final r = record(path);
    r.starred = !r.starred;
    _changed();
  }

  void setStarred(String path, bool value) {
    record(path).starred = value;
    _changed();
  }

  void removeFromRecents(String path) {
    final r = _records[path];
    if (r == null) return;
    r.lastOpened = null;
    _changed();
  }

  void clearRecents() {
    for (final r in _records.values) {
      r.lastOpened = null;
    }
    _changed();
  }

  void addBookmark(String path, int page, String label) {
    final r = record(path);
    r.bookmarks.removeWhere((b) => b.page == page);
    r.bookmarks.add(Bookmark(page: page, label: label));
    r.bookmarks.sort((a, b) => a.page.compareTo(b.page));
    _changed();
  }

  void removeBookmark(String path, int page) {
    record(path).bookmarks.removeWhere((b) => b.page == page);
    _changed();
  }

  void renameBookmark(String path, int page, String label) {
    for (final b in record(path).bookmarks) {
      if (b.page == page) b.label = label;
    }
    _changed();
  }

  bool isBookmarked(String path, int page) => _records[path]?.bookmarks.any((b) => b.page == page) ?? false;

  /// Keeps metadata attached when a file or folder is renamed/moved.
  void moved(String from, String to) {
    final updates = <String, DocRecord>{};
    for (final e in _records.entries) {
      if (e.key == from || e.key.startsWith('$from/')) {
        final newPath = to + e.key.substring(from.length);
        e.value.path = newPath;
        updates[e.key] = e.value;
      }
    }
    for (final e in updates.entries) {
      _records.remove(e.key);
      _records[e.value.path] = e.value;
    }
    if (updates.isNotEmpty) _changed();
  }

  void deleted(String path) {
    _records.removeWhere((k, _) => k == path || k.startsWith('$path/'));
    _changed();
  }

  void _changed() {
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    final data = jsonEncode({'version': 1, 'records': _records.values.map((r) => r.toJson()).toList()});
    final tmp = File('${file.path}.tmp');
    await file.parent.create(recursive: true);
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(file.path);
  }
}
