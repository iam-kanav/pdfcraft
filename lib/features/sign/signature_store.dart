import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/services.dart';

enum SignatureKind { signature, initials }

class SavedSignature {
  SavedSignature(this.file, this.kind);

  final File file;
  final SignatureKind kind;
}

/// Saved signatures/initials as transparent PNG files.
class SignatureStore {
  SignatureStore(this.dir);

  factory SignatureStore.shared() => SignatureStore(AppServices.instance.signaturesDir);

  final Directory dir;

  String _prefix(SignatureKind k) => k == SignatureKind.signature ? 'sig_' : 'ini_';

  List<SavedSignature> list(SignatureKind kind) {
    if (!dir.existsSync()) return [];
    final files = dir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith(_prefix(kind)) && f.path.endsWith('.png')).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return [for (final f in files) SavedSignature(f, kind)];
  }

  Future<SavedSignature> save(List<int> png, SignatureKind kind) async {
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, '${_prefix(kind)}${DateTime.now().millisecondsSinceEpoch}.png'));
    await f.writeAsBytes(png, flush: true);
    return SavedSignature(f, kind);
  }

  Future<void> delete(SavedSignature s) => s.file.delete();
}
