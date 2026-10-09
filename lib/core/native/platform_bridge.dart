import 'dart:async';

import 'package:flutter/services.dart';

class IncomingFile {
  IncomingFile({required this.path, required this.name, this.mime});

  final String path;
  final String name;
  final String? mime;

  bool get isPdf => mime == 'application/pdf' || name.toLowerCase().endsWith('.pdf');
  bool get isImage => (mime ?? '').startsWith('image/');
}

/// Android integration exposed by MainActivity/PlatformBridge.kt.
class PlatformBridge {
  PlatformBridge._();

  static final instance = PlatformBridge._();
  static const _channel = MethodChannel('pdfcraft/platform');
  static const _events = EventChannel('pdfcraft/intents');

  List<IncomingFile> _parse(Object? payload) {
    if (payload is! Map) return const [];
    return [
      for (final f in (payload['files'] as List? ?? const []))
        IncomingFile(path: (f as Map)['path'] as String, name: f['name'] as String, mime: f['mime'] as String?),
    ];
  }

  /// Files the app was launched with ("Open with" / "Share to").
  Future<List<IncomingFile>> takeInitialFiles() async => _parse(await _channel.invokeMethod('takeInitialIntent'));

  /// Files delivered while the app is running.
  Stream<List<IncomingFile>> get incomingFiles =>
      _events.receiveBroadcastStream().map(_parse).where((l) => l.isNotEmpty);

  /// Copies a file into Downloads/PDFCraft. Returns a user-facing location.
  Future<String> saveToDownloads(String path, String name, {String mime = 'application/pdf'}) async =>
      (await _channel.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name, 'mime': mime}))!;

  Future<bool> hasAllFilesAccess() async => (await _channel.invokeMethod<bool>('hasAllFilesAccess')) ?? false;

  Future<void> requestAllFilesAccess() => _channel.invokeMethod('requestAllFilesAccess');

  Future<List<({String path, int size, DateTime modified})>> scanDevicePdfs() async {
    final r = await _channel.invokeMethod<List>('scanDevicePdfs') ?? const [];
    return [
      for (final m in r)
        (
          path: (m as Map)['path'] as String,
          size: m['size'] as int,
          modified: DateTime.fromMillisecondsSinceEpoch(m['modified'] as int),
        ),
    ];
  }

  Future<void> print(String path, String name) => _channel.invokeMethod('print', {'path': path, 'name': name});
}
