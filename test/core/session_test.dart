import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfcraft/core/session/document_session.dart';
import 'package:pdfcraft/features/viewer/tts_controller.dart';

void main() {
  test('DocumentSession applies edits with undo/redo and password tracking', () async {
    final tmp = Directory.systemTemp.createTempSync('session');
    final doc = File(p.join(tmp.path, 'doc.pdf'))..writeAsStringSync('v1');
    final s = DocumentSession(path: doc.path, tempDir: Directory(p.join(tmp.path, 'work')));
    var notified = 0;
    s.addListener(() => notified++);

    await s.apply('Edit 1', (input, out) async => File(out).writeAsString('${File(input).readAsStringSync()}+e1'));
    expect(doc.readAsStringSync(), 'v1+e1');
    expect(s.revision, 1);
    expect(s.undoLabel, 'Edit 1');

    await s.apply('Protect', (input, out) async => File(out).writeAsString('locked'), newPassword: () => 'secret');
    expect(s.password, 'secret');

    await s.undo();
    expect(doc.readAsStringSync(), 'v1+e1');
    expect(s.password, isNull);
    await s.redo();
    expect(doc.readAsStringSync(), 'locked');
    expect(s.password, 'secret');

    // A failing operation leaves the document untouched.
    await expectLater(s.apply('Bad', (i, o) async => throw StateError('boom')), throwsStateError);
    expect(doc.readAsStringSync(), 'locked');
    expect(s.isBusy, isFalse);
    expect(notified, greaterThan(4));
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('TTS sentence splitting keeps offsets', () {
    const text = 'First sentence. Second one!\nThird line without stop';
    final chunks = splitSentences(1, text);
    expect(chunks.map((c) => c.text), ['First sentence.', 'Second one!', 'Third line without stop']);
    for (final c in chunks) {
      expect(text.substring(c.start, c.end).trim().replaceAll('\n', ''), c.text);
    }
    final long = List.filled(100, 'word').join(' ');
    expect(splitSentences(1, long, maxLength: 50).every((c) => c.text.length <= 50), isTrue);
  });
}
