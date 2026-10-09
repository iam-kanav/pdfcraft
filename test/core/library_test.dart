import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfcraft/core/library/file_service.dart';
import 'package:pdfcraft/core/library/library_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pdfcraft_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('LibraryStore persists recents, stars, bookmarks and follows moves', () async {
    final docA = File(p.join(tmp.path, 'a.pdf'))..writeAsStringSync('%PDF-1.4');
    final docB = File(p.join(tmp.path, 'b.pdf'))..writeAsStringSync('%PDF-1.4');
    final store = LibraryStore(File(p.join(tmp.path, 'lib.json')));
    await store.load();
    store.markOpened(docA.path, pageCount: 3);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    store.markOpened(docB.path);
    store.toggleStar(docA.path);
    store.addBookmark(docA.path, 2, 'Intro');
    store.setLastPage(docA.path, 3);
    expect(store.recents.map((r) => r.path), [docB.path, docA.path]);
    expect(store.starred.single.path, docA.path);
    await store.save();

    final reloaded = LibraryStore(File(p.join(tmp.path, 'lib.json')));
    await reloaded.load();
    expect(reloaded.isStarred(docA.path), isTrue);
    expect(reloaded.peek(docA.path)!.bookmarks.single.label, 'Intro');
    expect(reloaded.peek(docA.path)!.lastPage, 3);
    expect(reloaded.peek(docA.path)!.pageCount, 3);

    final moved = p.join(tmp.path, 'renamed.pdf');
    docA.renameSync(moved);
    reloaded.moved(docA.path, moved);
    expect(reloaded.isStarred(moved), isTrue);
    reloaded.removeFromRecents(docB.path);
    expect(reloaded.recents.map((r) => r.path), [moved]);
    reloaded.deleted(moved);
    expect(reloaded.peek(moved), isNull);
  });

  test('FileService: folders, rename, move, duplicate, import dedupe, search, sort', () async {
    final root = Directory(p.join(tmp.path, 'PDFCraft'));
    final fs = FileService(root);
    await fs.ensureRoot();
    expect(fs.scansDir.existsSync(), isTrue);
    final src = File(p.join(tmp.path, 'Report.pdf'))..writeAsStringSync('%PDF-1.4 report');
    final imported = await fs.import(src.path);
    expect(p.basename(imported), 'Report.pdf');
    // Identical content is reused, different content gets a numbered name.
    expect(await fs.import(src.path), imported);
    final other = File(p.join(tmp.path, 'x', 'Report.pdf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('%PDF-1.4 something else');
    expect(p.basename(await fs.import(other.path)), 'Report (2).pdf');

    final folder = await fs.createFolder(root, 'Work');
    final renamed = await fs.rename(imported, 'Q3 Report');
    expect(p.basename(renamed), 'Q3 Report.pdf');
    await expectLater(fs.rename(renamed, 'Report (2).pdf'), throwsA(isA<FileSystemException>()));
    final moved = await fs.move(renamed, folder);
    expect(p.dirname(moved), folder.path);
    await expectLater(fs.move(folder.path, folder), throwsA(isA<FileSystemException>()));
    final dup = await fs.duplicate(moved);
    expect(p.basename(dup), 'Q3 Report copy.pdf');

    final results = await fs.search('q3');
    expect(results.map((e) => e.name), containsAll(['Q3 Report.pdf', 'Q3 Report copy.pdf']));
    final listing = await fs.list(root, sort: SortField.name, descending: false);
    expect(listing.first.isDirectory, isTrue); // folders first
    await fs.delete(folder.path);
    expect(folder.existsSync(), isFalse);
  });

  test('uniquePath numbering', () {
    File(p.join(tmp.path, 'a.pdf')).writeAsStringSync('x');
    File(p.join(tmp.path, 'a (2).pdf')).writeAsStringSync('x');
    expect(p.basename(FileService.uniquePath(tmp.path, 'a.pdf')), 'a (3).pdf');
    expect(p.basename(FileService.uniquePath(tmp.path, 'b.pdf')), 'b.pdf');
  });
}
