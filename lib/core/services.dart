import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/reflow/reading_settings.dart';
import 'app_settings.dart';
import 'library/file_service.dart';
import 'library/library_store.dart';
import 'pdf_render.dart';
import 'session/document_session.dart';

/// Process-wide services, created once at startup.
class AppServices {
  AppServices._({
    required this.files,
    required this.library,
    required this.settings,
    required this.reading,
    required this.thumbnails,
    required this.tempDir,
    required this.signaturesDir,
  });

  static late AppServices instance;

  final FileService files;
  final LibraryStore library;
  final AppSettings settings;
  final ReadingSettings reading;
  final ThumbnailCache thumbnails;
  final Directory tempDir;
  final Directory signaturesDir;

  static Future<AppServices> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    final prefs = await SharedPreferences.getInstance();
    final files = FileService(Directory(p.join(docs.path, 'PDFCraft')));
    await files.ensureRoot();
    final library = LibraryStore(File(p.join(support.path, 'library.json')));
    await library.load();
    final reading = ReadingSettings();
    await reading.load();
    final tempDir = Directory(p.join(cache.path, 'work'));
    await tempDir.create(recursive: true);
    final signaturesDir = Directory(p.join(support.path, 'signatures'));
    await signaturesDir.create(recursive: true);
    instance = AppServices._(
      files: files,
      library: library,
      settings: AppSettings(prefs),
      reading: reading,
      thumbnails: ThumbnailCache(Directory(p.join(cache.path, 'thumbs'))),
      tempDir: tempDir,
      signaturesDir: signaturesDir,
    );
    return instance;
  }

  /// A standalone editing session (for tools used outside the viewer).
  DocumentSession newSession(String path, {String? password}) => DocumentSession(
    path: path,
    password: password,
    tempDir: Directory(p.join(tempDir.path, 'session_${DateTime.now().microsecondsSinceEpoch}')),
  );

  /// A fresh temp file path.
  String tempPath(String name) {
    final dir = Directory(p.join(tempDir.path, DateTime.now().microsecondsSinceEpoch.toString()));
    dir.createSync(recursive: true);
    return p.join(dir.path, name);
  }
}
