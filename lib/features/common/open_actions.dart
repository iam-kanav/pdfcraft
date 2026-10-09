import 'dart:io';

import 'package:file_picker/file_picker.dart';
import '../../core/file_picking.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/native/platform_bridge.dart';
import '../../core/services.dart';
import '../convert/create_pdf_screen.dart';
import '../viewer/viewer_screen.dart';
import 'dialogs.dart';

/// Opens a PDF in the viewer.
Future<void> openDocument(BuildContext context, String path, {int? initialPage, String? password}) async {
  if (!File(path).existsSync()) {
    showSnack(context, 'This file no longer exists', error: true);
    AppServices.instance.library.removeFromRecents(path);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ViewerScreen(path: path, initialPage: initialPage, password: password)),
  );
}

/// Lets the user pick PDFs from the device (system picker) and imports them into the library.
Future<List<String>> pickPdfsFromDevice(BuildContext context, {bool multiple = false, bool import = true}) async {
  final result = await pickLocalFiles(type: FileType.custom, extensions: const ['pdf'], multiple: multiple);
  final out = <String>[];
  for (final f in result) {
    out.add(import ? await AppServices.instance.files.import(f.path, name: f.name) : f.path);
  }
  return out;
}

Future<void> pickAndOpenPdf(BuildContext context) async {
  final paths = await pickPdfsFromDevice(context);
  if (paths.isEmpty || !context.mounted) return;
  await openDocument(context, paths.first);
}

/// Handles files received via "Open with" or "Share".
Future<void> handleIncomingFiles(BuildContext context, List<IncomingFile> files) async {
  final pdfs = files.where((f) => f.isPdf).toList();
  final images = files.where((f) => f.isImage).toList();
  final services = AppServices.instance;
  if (pdfs.isNotEmpty) {
    final imported = <String>[];
    for (final f in pdfs) {
      imported.add(await services.files.import(f.path, name: f.name));
    }
    if (!context.mounted) return;
    await openDocument(context, imported.first);
  } else if (images.isNotEmpty) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CreatePdfScreen(initialImages: images.map((e) => e.path).toList())),
    );
  } else if (files.isNotEmpty) {
    showSnack(context, 'Unsupported file type: ${files.first.name}', error: true);
  }
}

Future<void> shareFiles(List<String> paths, {String? text}) async {
  await SharePlus.instance.share(ShareParams(files: [for (final f in paths) XFile(f)], text: text));
}

Future<void> saveCopyToDownloads(BuildContext context, String path) async {
  final name = p.basename(path);
  final ext = p.extension(path).toLowerCase();
  final mime = switch (ext) {
    '.pdf' => 'application/pdf',
    '.png' => 'image/png',
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.txt' => 'text/plain',
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.html' => 'text/html',
    '.md' => 'text/markdown',
    '.zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
  final where = await runWithProgress(context, 'Saving…', () => PlatformBridge.instance.saveToDownloads(path, name, mime: mime));
  if (where != null && context.mounted) showSnack(context, 'Saved to $where');
}
