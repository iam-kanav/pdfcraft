import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'services.dart';
import 'util/format.dart';

/// A picked file materialized as a local path (content URIs are copied to the cache).
class PickedFile {
  PickedFile(this.path, this.name);

  final String path;
  final String name;
}

/// Opens the system picker and returns local copies of the chosen files.
Future<List<PickedFile>> pickLocalFiles({FileType type = FileType.any, List<String>? extensions, bool multiple = false}) async {
  final picked = multiple
      ? await FilePicker.pickFiles(type: type, allowedExtensions: extensions)
      : [?await FilePicker.pickFile(type: type, allowedExtensions: extensions)];
  final out = <PickedFile>[];
  for (final f in picked) {
    final local = f.path;
    if (local != null && File(local).existsSync()) {
      out.add(PickedFile(local, f.name));
      continue;
    }
    final target = AppServices.instance.tempPath(sanitizeFileName(f.name.isEmpty ? 'file' : p.basename(f.name)));
    await File(target).writeAsBytes(await f.readAsBytes(), flush: true);
    out.add(PickedFile(target, f.name));
  }
  return out;
}

Future<PickedFile?> pickLocalFile({FileType type = FileType.any, List<String>? extensions}) async {
  final r = await pickLocalFiles(type: type, extensions: extensions);
  return r.isEmpty ? null : r.first;
}
