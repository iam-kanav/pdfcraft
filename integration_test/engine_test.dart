import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfcraft/core/models/doc_structure.dart';
import 'package:pdfcraft/core/models/raw_page_content.dart';
import 'package:pdfcraft/core/native/pdf_engine.dart';
import 'package:pdfcraft/core/pdf_render.dart';
import 'package:pdfcraft/core/services.dart';
import 'package:pdfcraft/features/convert/convert_service.dart';
import 'package:pdfcraft/features/convert/ocr_service.dart';
import 'package:pdfcraft/features/reflow/analyzer/reflow_analyzer.dart';
import 'package:pdfcraft/features/viewer/viewer_state.dart';
import 'package:pdfrx/pdfrx.dart';

import 'samples.dart';

/// Display-space rects of [query] on page [pageIndex].
Future<List<Rect>> findRects(String path, int pageIndex, String query, {String? password}) async {
  final doc = await openPdf(path, password: password);
  try {
    final page = doc.pages[pageIndex];
    final text = await page.loadStructuredText();
    final out = <Rect>[];
    await for (final m in text.allMatches(query, caseInsensitive: false)) {
      out.addAll(lineRectsForRange(m, page));
    }
    return out;
  } finally {
    await doc.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final engine = PdfEngine.instance;
  late Directory dir;
  late Samples samples;
  late String sample;

  String out(String name) => p.join(dir.path, name);

  setUpAll(() async {
    await pdfrxFlutterInitialize();
    await AppServices.init();
    dir = Directory(p.join(AppServices.instance.tempDir.path, 'itest_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);
    samples = Samples(dir);
    sample = await samples.textDoc();
  });

  test('info reports pages, sizes and metadata', () async {
    final info = await engine.info(sample);
    expect(info.pageCount, 3);
    expect(info.encrypted, isFalse);
    expect(info.title, 'Sample');
    expect(info.pages.first.width, closeTo(595.28, 0.5));
    expect(info.pages.first.height, closeTo(841.89, 0.5));
  });

  test('organize: reorder, rotate, duplicate, insert blank, delete', () async {
    final o = out('organized.pdf');
    final n = await engine.organize(sample, o, const [
      PageSpec.page(2),
      PageSpec.page(0, rotate: 90),
      PageSpec.page(0),
      PageSpec.blank(),
    ]);
    expect(n, 4);
    final info = await engine.info(o);
    expect(info.pageCount, 4);
    expect(info.pages[1].rotation, 90);
    expect(info.pages[1].width, closeTo(841.89, 0.5)); // rotated → landscape display size
    final texts = await pageTexts(o);
    expect(texts[0], contains('page 3'));
    expect(texts[1], contains('page 1'));
    expect(texts[2], contains('page 1'));
    expect(texts[3].trim(), isEmpty);
  });

  test('merge pages from another file', () async {
    final other = await samples.textDoc(name: 'other.pdf', pages: 2);
    final o = out('merged.pdf');
    await engine.organize(sample, o, [
      for (var i = 0; i < 3; i++) PageSpec.page(i),
      PageSpec.fromFile(other, 0),
      PageSpec.fromFile(other, 1),
    ]);
    expect((await engine.info(o)).pageCount, 5);
  });

  test('split into ranges', () async {
    final outs = await engine.split(sample, out('split'), 'part', const [(1, 1), (2, 3)]);
    expect(outs.length, 2);
    expect((await engine.info(outs[0])).pageCount, 1);
    expect((await engine.info(outs[1])).pageCount, 2);
    expect((await pageTexts(outs[1]))[0], contains('page 2'));
  });

  test('crop changes the visible page size', () async {
    final o = out('cropped.pdf');
    await engine.crop(sample, o, {0: const Rect.fromLTWH(50, 50, 300, 400)});
    final info = await engine.info(o);
    expect(info.pages[0].width, closeTo(300, 0.5));
    expect(info.pages[0].height, closeTo(400, 0.5));
    expect(info.pages[1].width, closeTo(595.28, 0.5));
  });

  test('compress produces a valid smaller-or-equal file', () async {
    final o = out('compressed.pdf');
    final r = await engine.compress(sample, o, dpi: 72, quality: 0.5);
    expect(File(o).existsSync(), isTrue);
    expect(r.after, lessThanOrEqualTo(r.before + 1024));
    expect((await engine.info(o)).pageCount, 3);
    expect((await pageTexts(o))[0], contains('Hello World'));
  });

  test('annotations: add every type, list, move, update, delete, flatten', () async {
    final o = out('annotated.pdf');
    final hello = await findRects(sample, 0, 'Hello World');
    expect(hello, isNotEmpty);
    final png = File(out('sig.png'))..writeAsBytesSync(samples.testImage(w: 120, h: 40));
    final ids = await engine.addAnnotations(sample, o, [
      {
        'type': 'highlight',
        'page': 0,
        'rects': hello.map(rectToList).toList(),
        'color': 0xFFFFD400,
        'opacity': 0.4,
        'contents': 'important',
      },
      {'type': 'underline', 'page': 0, 'rects': hello.map(rectToList).toList(), 'color': 0xFF2563EB},
      {'type': 'strikeout', 'page': 0, 'rects': hello.map(rectToList).toList(), 'color': 0xFFE11D48},
      {
        'type': 'ink',
        'page': 0,
        'paths': [
          [100, 500, 150, 520, 200, 510, 250, 540],
        ],
        'color': 0xFFE11D48,
        'strokeWidth': 3,
      },
      {
        'type': 'square',
        'page': 1,
        'rect': [100, 100, 200, 160],
        'color': 0xFF16A34A,
        'strokeWidth': 2,
      },
      {
        'type': 'circle',
        'page': 1,
        'rect': [250, 100, 350, 160],
        'color': 0xFF16A34A,
        'fillColor': 0xFFFFD400,
      },
      {
        'type': 'arrow',
        'page': 1,
        'points': [100, 300, 300, 350],
        'color': 0xFF000000,
        'strokeWidth': 2,
      },
      {
        'type': 'freetext',
        'page': 1,
        'rect': [100, 400, 350, 450],
        'text': 'Typed comment',
        'fontSize': 14,
        'color': 0xFF000000,
      },
      {'type': 'note', 'page': 2, 'x': 400, 'y': 100, 'contents': 'Sticky note text'},
      {
        'type': 'stamp',
        'page': 2,
        'rect': [100, 600, 250, 650],
        'imagePath': png.path,
      },
      {
        'type': 'link',
        'page': 2,
        'rect': [100, 700, 300, 720],
        'url': 'https://example.com',
      },
      {
        'type': 'link',
        'page': 2,
        'rect': [100, 730, 300, 750],
        'targetPage': 0,
      },
    ]);
    expect(ids.length, 12);
    var list = await engine.listAnnotations(o);
    final types = list.map((a) => a['type']).toList();
    expect(
      types,
      containsAll([
        'Highlight',
        'Underline',
        'StrikeOut',
        'Ink',
        'Square',
        'Circle',
        'Line',
        'FreeText',
        'Text',
        'Stamp',
        'Link',
      ]),
    );
    final note = list.firstWhere((a) => a['type'] == 'Text');
    expect(note['contents'], 'Sticky note text');
    expect((list.firstWhere((a) => a['type'] == 'Link' && a['url'] != null))['url'], 'https://example.com');
    expect((list.firstWhere((a) => a['type'] == 'Link' && a['url'] == null))['targetPage'], 0);
    // FreeText text is part of the rendered page appearance.
    final square = list.firstWhere((a) => a['type'] == 'Square');
    final squareRect = listToRect(square['rect'] as List);
    expect(squareRect.left, closeTo(99, 2));
    expect(squareRect.top, closeTo(99, 2));

    // Move the square and change a note.
    final o2 = out('annotated2.pdf');
    await engine.updateAnnotation(
      o,
      o2,
      page: 1,
      id: square['id'] as String,
      rect: const Rect.fromLTWH(300, 300, 120, 80),
      contents: 'moved',
    );
    final o3 = out('annotated3.pdf');
    await engine.updateAnnotation(o2, o3, page: 2, id: note['id'] as String, contents: 'Edited note');
    list = await engine.listAnnotations(o3);
    final moved = list.firstWhere((a) => a['id'] == square['id']);
    expect(listToRect(moved['rect'] as List).left, closeTo(300, 1));
    expect(moved['contents'], 'moved');
    expect(list.firstWhere((a) => a['id'] == note['id'])['contents'], 'Edited note');

    // Delete
    final o4 = out('annotated4.pdf');
    final deleted = await engine.deleteAnnotations(o3, o4, [(page: 1, id: square['id'] as String)]);
    expect(deleted, 1);
    expect((await engine.listAnnotations(o4)).length, list.length - 1);

    // Flatten: annotations disappear, FreeText text becomes page text.
    final o5 = out('flattened.pdf');
    await engine.flatten(o4, o5);
    final after = await engine.listAnnotations(o5);
    expect(after.every((a) => a['type'] == 'Link'), isTrue);
    expect((await pageTexts(o5))[1], contains('Typed comment'));
  });

  test('forms: list, fill, verify, flatten', () async {
    final form = await samples.formDoc();
    final fields = await engine.listFields(form);
    expect(fields.map((f) => f['name']), containsAll(['name', 'agree']));
    expect(fields.firstWhere((f) => f['name'] == 'name')['type'], 'text');
    expect(fields.firstWhere((f) => f['name'] == 'agree')['type'], 'checkbox');
    final o = out('form_filled.pdf');
    await engine.fillForm(form, o, {'name': 'Ada Lovelace', 'agree': true});
    final filled = await engine.listFields(o);
    expect(filled.firstWhere((f) => f['name'] == 'name')['value'], 'Ada Lovelace');
    expect(filled.firstWhere((f) => f['name'] == 'agree')['value'], true);
    // Unicode value falls back to an embedded font.
    final o2 = out('form_unicode.pdf');
    await engine.fillForm(o, o2, {'name': 'Zoë Ελένη'});
    expect((await engine.listFields(o2)).firstWhere((f) => f['name'] == 'name')['value'], 'Zoë Ελένη');
    final o3 = out('form_flat.pdf');
    await engine.fillForm(o, o3, const {}, flatten: true);
    expect(await engine.listFields(o3), isEmpty);
    expect((await pageTexts(o3))[0], contains('Ada Lovelace'));
  });

  test('edit existing text: replace and delete a text block', () async {
    final blocks = await engine.getTextBlocks(sample, 0);
    final hello = blocks.firstWhere((b) => (b['text'] as String).contains('Hello World'));
    final o = out('text_edited.pdf');
    await engine.editTextBlocks(sample, o, 0, [
      {'id': hello['id'], 'text': 'Goodbye Moon, rewritten paragraph.'},
    ]);
    var text = (await pageTexts(o))[0];
    expect(text, contains('Goodbye Moon'));
    expect(text, isNot(contains('Hello World')));
    expect(text, contains('SECRET123')); // other blocks untouched
    expect(text, contains('Chapter 1 Heading'));
    final blocks2 = await engine.getTextBlocks(o, 0);
    final closing = blocks2.firstWhere((b) => (b['text'] as String).contains('Closing remarks'));
    final o2 = out('text_deleted.pdf');
    await engine.editTextBlocks(o, o2, 0, [
      {'id': closing['id'], 'text': ''},
    ]);
    text = (await pageTexts(o2))[0];
    expect(text, isNot(contains('Closing remarks')));
    expect(text, contains('Goodbye Moon'));
  });

  test('images: list, move, replace, delete', () async {
    final imgs = await engine.getImageObjects(sample, 0);
    expect(imgs.length, 1);
    final r = listToRect(imgs[0]['rect'] as List);
    expect(r.width, closeTo(200, 2));
    final o = out('img_moved.pdf');
    await engine.editImage(sample, o, page: 0, id: 0, action: 'move', rect: const Rect.fromLTWH(300, 500, 100, 66));
    final moved = listToRect((await engine.getImageObjects(o, 0))[0]['rect'] as List);
    expect(moved.left, closeTo(300, 1));
    expect(moved.top, closeTo(500, 1));
    expect(moved.width, closeTo(100, 1));
    final png = File(out('replacement.png'))..writeAsBytesSync(samples.testImage(w: 100, h: 100));
    final o2 = out('img_replaced.pdf');
    await engine.editImage(o, o2, page: 0, id: 0, action: 'replace', imagePath: png.path);
    final replaced = await engine.getImageObjects(o2, 0);
    expect(replaced.length, 1);
    expect(replaced[0]['pw'], 100);
    final o3 = out('img_deleted.pdf');
    await engine.editImage(o2, o3, page: 0, id: 0, action: 'delete');
    expect(await engine.getImageObjects(o3, 0), isEmpty);
  });

  test('add text, image and shapes as page content', () async {
    final png = File(out('add.png'))..writeAsBytesSync(samples.testImage());
    final o = out('content_added.pdf');
    await engine.addContent(sample, o, [
      {
        'type': 'text',
        'page': 1,
        'x': 72,
        'y': 600,
        'text': 'Inserted line of text',
        'fontSize': 14,
        'color': 0xFF000000,
      },
      {
        'type': 'image',
        'page': 1,
        'rect': [72, 650, 172, 716],
        'imagePath': png.path,
      },
      {
        'type': 'rect',
        'page': 1,
        'rect': [300, 600, 400, 650],
        'strokeColor': 0xFFE11D48,
        'strokeWidth': 2,
      },
      {
        'type': 'arrow',
        'page': 1,
        'points': [300, 700, 450, 750],
        'strokeColor': 0xFF000000,
      },
    ]);
    expect((await pageTexts(o))[1], contains('Inserted line of text'));
    expect((await engine.getImageObjects(o, 1)).length, 1);
    final added = (await findRects(o, 1, 'Inserted'));
    expect(added.first.left, closeTo(72, 2));
  });

  test('true redaction removes underlying text, keeps the rest', () async {
    final rects = await findRects(sample, 0, 'SECRET123');
    expect(rects, isNotEmpty);
    final o = out('redacted.pdf');
    final r = await engine.redact(sample, o, {0: rects.map((e) => e.inflate(1)).toList()}, removeMetadata: true);
    expect(r['glyphs'], greaterThanOrEqualTo(9));
    final text = (await pageTexts(o))[0];
    expect(text, isNot(contains('SECRET')));
    expect(text, contains('The account number is'));
    expect(text, contains('and must be hidden'));
    expect((await pageTexts(o))[1], contains('SECRET123')); // other pages untouched
    // Image redaction: cover part of the image.
    final img = listToRect((await engine.getImageObjects(sample, 0))[0]['rect'] as List);
    final o2 = out('redacted_img.pdf');
    final r2 = await engine.redact(sample, o2, {
      0: [Rect.fromLTWH(img.left + 10, img.top + 10, 60, 40)],
    });
    expect(r2['images'], 1);
    expect((await engine.getImageObjects(o2, 0)).length, 1);
    final info = await engine.info(o);
    expect(info.title, isNull);
  });

  test('watermark, page numbers, and removing them', () async {
    final o = out('wm.pdf');
    await engine.watermark(sample, o, text: 'DRAFT COPY', opacity: 0.3);
    expect((await pageTexts(o))[0], contains('DRAFT COPY'));
    final o2 = out('wm_numbers.pdf');
    await engine.pageNumbers(o, o2, format: 'Page {n} of {N}');
    final texts = await pageTexts(o2);
    expect(texts[0], contains('Page 1 of 3'));
    expect(texts[2], contains('Page 3 of 3'));
    final o3 = out('wm_removed.pdf');
    final removed = await engine.removeArtifacts(o2, o3, kinds: ['Watermark']);
    expect(removed, 3);
    final t3 = await pageTexts(o3);
    expect(t3[0], isNot(contains('DRAFT COPY')));
    expect(t3[0], contains('Page 1 of 3'));
    expect(t3[0], contains('Hello World'));
    final o4 = out('numbers_removed.pdf');
    await engine.removeArtifacts(o3, o4, kinds: ['Footer']);
    expect((await pageTexts(o4))[0], isNot(contains('Page 1 of 3')));
  });

  test('security: protect with passwords and permissions, open, remove', () async {
    final o = out('protected.pdf');
    await engine.protect(
      sample,
      o,
      userPassword: 'open123',
      ownerPassword: 'owner456',
      permissions: {'print': false, 'copy': false, 'modify': false},
    );
    await expectLater(
      engine.info(o),
      throwsA(isA<PdfEngineException>().having((e) => e.isPasswordError, 'password', isTrue)),
    );
    final info = await engine.info(o, password: 'open123');
    expect(info.encrypted, isTrue);
    expect(info.keyLength, 256);
    expect(info.permissions['print'], isFalse);
    expect(info.permissions['copy'], isFalse);
    // PDFium (the viewer) opens it with the password too.
    expect((await pageTexts(o, password: 'open123'))[0], contains('Hello World'));
    // Editing keeps it protected.
    final o2 = out('protected_edit.pdf');
    await engine.addContent(o, o2, [
      {'type': 'text', 'page': 0, 'x': 72, 'y': 760, 'text': 'Edited while protected'},
    ], password: 'owner456');
    await expectLater(engine.info(o2), throwsA(isA<PdfEngineException>()));
    expect((await engine.info(o2, password: 'owner456')).encrypted, isTrue);
    // Removing security requires the permissions password.
    final o3 = out('unprotected.pdf');
    await engine.removeSecurity(o, o3, password: 'owner456');
    final info3 = await engine.info(o3);
    expect(info3.encrypted, isFalse);
  });

  test('metadata editing', () async {
    final o = out('meta.pdf');
    await engine.setMetadata(sample, o, {
      'title': 'New Title',
      'author': 'Someone',
      'subject': 'Testing',
      'keywords': 'a, b',
    });
    final info = await engine.info(o);
    expect(info.title, 'New Title');
    expect(info.author, 'Someone');
    expect(info.keywords, 'a, b');
  });

  test('extract positioned content and analyze it for smart reading', () async {
    final pages = await engine.extractPages(sample, pages: [0]);
    expect(pages.single.lines, isNotEmpty);
    final heading = pages.single.lines.firstWhere((l) => l.text.contains('Chapter 1'));
    expect(heading.fontSize, closeTo(24, 1));
    expect(heading.isBold, isTrue);
    expect(pages.single.images.length, 1);
    final doc = await ConvertService.pdfToStructure(sample);
    expect(doc.headings.map((h) => h.text), contains('Chapter 1 Heading'));
    expect(doc.plainText, contains('Hello World page 2'));
  });

  test('smart reading keeps colors, fonts, decorations, links and alignment', () async {
    final path = await samples.formattedDoc();
    final raw = (await engine.extractPages(path)).single;
    RawTextSpan spanWith(String text) => raw.lines.expand((l) => l.spans).firstWhere((s) => s.text.contains(text));
    final red = spanWith('red words');
    expect(red.color, isNotNull);
    expect((red.color! >> 16) & 0xFF, greaterThan(180)); // red channel
    expect(spanWith('underlined').underline, isTrue);
    expect(spanWith('struck').strike, isTrue);
    expect(spanWith('monospaced').family, 'mono');
    expect(spanWith('This paragraph').family, 'serif');
    expect(spanWith('Visit').link, 'https://example.com/docs');
    expect(spanWith('This paragraph').color, isNull); // black ink = default

    final doc = analyzeDocument([raw]);
    final title = doc.blocks.whereType<HeadingBlock>().first;
    expect(title.text, 'Formatting Showcase');
    expect(title.align, BlockAlign.center);
    expect(title.spans.first.color, isNotNull);
    final paragraphs = doc.blocks.whereType<ParagraphBlock>().toList();
    final body = paragraphs.firstWhere((p) => p.text.startsWith('This paragraph'));
    expect(body.spans.any((s) => s.underline && s.text.contains('underlined')), isTrue);
    expect(body.spans.any((s) => s.strike && s.text.contains('struck')), isTrue);
    expect(body.spans.any((s) => s.fontFamily == 'mono'), isTrue);
    final signed = paragraphs.firstWhere((p) => p.text.contains('Signed'));
    expect(signed.align, BlockAlign.end);
    final link = paragraphs.firstWhere((p) => p.text.contains('Visit'));
    expect(link.spans.first.link, 'https://example.com/docs');
  });

  test('OCR layer makes invisible words searchable', () async {
    final blank = out('blank_ocr.pdf');
    await engine.organize(sample, blank, const [PageSpec.blank()]);
    final o = out('ocr_layer.pdf');
    final n = await engine.addOcrLayer(blank, o, {
      0: [
        (text: 'Recognized', rect: const Rect.fromLTWH(72, 100, 90, 14)),
        (text: 'words', rect: const Rect.fromLTWH(170, 100, 40, 14)),
      ],
    });
    expect(n, 2);
    final text = (await pageTexts(o))[0];
    expect(text, contains('Recognized'));
    expect(text, contains('words'));
    final r = await findRects(o, 0, 'Recognized');
    expect(r.first.left, closeTo(72, 3));
  });

  test('on-device ML Kit OCR reads rendered text', () async {
    final ocr = OcrService();
    final doc = await openPdf(sample);
    try {
      final result = await ocr.recognizePage(doc.pages[0]);
      expect(result.text, contains('Hello World'));
      final word = result.words.firstWhere((w) => w.text.contains('Hello'));
      final truth = await findRects(sample, 0, 'Hello');
      expect((word.rect.left - truth.first.left).abs(), lessThan(8));
    } finally {
      await doc.dispose();
      await ocr.close();
    }
  });

  test('export to Word, text, HTML, Markdown and images', () async {
    final exportDir = out('exports');
    for (final f in ExportFormat.values) {
      final path = await ConvertService.exportPdf(sample, f, exportDir, dpi: 72);
      expect(File(path).lengthSync(), greaterThan(100), reason: f.name);
    }
    final txt = Directory(exportDir).listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.txt'));
    expect(txt.readAsStringSync(), contains('Hello World page 1'));
  });

  test('document to PDF conversion (text and markdown)', () async {
    final md = File(out('notes.md'))..writeAsStringSync('# Title\n\nSome **bold** text.\n\n- one\n- two\n');
    final bytes = await ConvertService.documentToPdf(md.path);
    final pdf = File(out('notes.pdf'))..writeAsBytesSync(bytes);
    final text = (await pageTexts(pdf.path)).join();
    expect(text, contains('Title'));
    expect(text, contains('bold'));
  });
}
